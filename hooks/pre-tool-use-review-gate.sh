#!/usr/bin/env bash
# vibeguard pre-tool-use-review-gate.sh - opt-in review-receipt push gate.
#
# OPT-IN (install.sh --with-review-receipt, Claude only). PreToolUse:Bash.
# Intercepts a git-push on ANY branch/worktree and blocks it until a fresh
# code-review + simplify receipt exists for the current diff. This closes the
# "pushed straight from dev without a review pass" gap even on branches made
# before any in-repo pre-push hook existed.
#
# It delegates to check-agent-review-gate.sh, installed as its SIBLING in the
# same hooks dir; that script computes the review surface, hashes it, and writes
# / verifies the receipt (.git/agent-review-gate/latest.env). Fail-CLOSED there
# on a missing sha256 / git.
#
# Fail-open by design here: anything that is not a clearly-detected git-push
# inside a git worktree exits 0 (allow). Only a real gate block exits 2
# (PreToolUse block -> stderr is fed back to the agent as the reason).
#
# Audit-visible bypass: set SKIP_REVIEW_GATE=1 before the push command.
#
# SCOPE (seatbelt, not vault): push detection matches `push` as the git
# SUBCOMMAND after optional wrappers / global options (`git -C <r> push`,
# `git -c k=v push`), so a standard invocation cannot slip past ungated. It does
# NOT defeat deliberate command obfuscation (a quoted name, command
# substitution) -> that degrades to a MISSED check (allow), never a wrong block.
# A literal `git push` still in command position (`echo git push`) errs the safe
# way: treated as a push (over-block), never let through.
set -uo pipefail

payload="$(cat 2>/dev/null || true)"

# Kill-switch (visible in env/command -> audit trail).
[ "${SKIP_REVIEW_GATE:-}" = "1" ] && exit 0

# --- Extract the command string (prefer jq; permissive fallback). ---
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi
[ -n "$cmd" ] || cmd="$payload"

# --- Only act on a real `git ... push` (push as the subcommand after optional
# global options), so `git -C <repo> push` / `git -c k=v push` are caught and a
# `git help push` / `rg "git push"` is not. Reuses the hookspath-guard tokenizer.
git_subcommand() {
  local after tok skip=0 inq=""
  after=$(sed -nE 's/.*(^|[^[:alnum:]_-])git[[:space:]]+(.*)$/\2/p' <<<"$1" | head -1 || true)
  [ -n "$after" ] || return 0
  # shellcheck disable=SC2086  # intentional word-split to tokenize the segment
  for tok in $after; do
    if [ -n "$inq" ]; then case "$tok" in *"$inq") inq="" ;; esac; continue; fi
    if [ "$skip" = 1 ]; then
      skip=0
      case "$tok" in
        \"*\"|\'*\') : ;;
        \"*) inq='"' ;;
        \'*) inq="'" ;;
      esac
      continue
    fi
    case "$tok" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) skip=1; continue ;;
      --*=*) continue ;;
      -*) continue ;;
      *) printf '%s' "$tok"; return 0 ;;
    esac
  done
  [ -n "$inq" ] && printf '?'
  return 0
}

# Find the segment that IS a real push and gate the repo IT targets: `git -C
# <repo> push` gates <repo>, not the cwd (else a receipt for the wrong worktree
# could wave the push through -- QODO). --git-dir/--work-tree cannot be resolved
# safely -> fail-closed. Same repo-resolution as pre-tool-use-hookspath-guard.sh.
PUSH_SEG=""
joined=${cmd//$'\\'$'\n'/ }
while IFS= read -r seg; do
  case "$(git_subcommand "$seg")" in
    push|"?") PUSH_SEG="$seg"; break ;;
  esac
done < <(printf '%s\n' "$joined" | tr '|;&' '\n')
[ -n "$PUSH_SEG" ] || exit 0   # no real push -> allow

if grep -qE '(^|[[:space:]])--(git-dir|work-tree)([[:space:]]|=)' <<<"$PUSH_SEG"; then
  echo "AGENT REVIEW GATE: git push via --git-dir/--work-tree cannot be resolved to check a receipt." >&2
  echo "Run the push from inside the repo (plain 'git push') so its diff can be verified." >&2
  exit 2
fi

# Resolve `git -C <path>` (strip one layer of matching quotes, expand ~/$HOME the
# shell would); with no -C, gate the push's cwd.
CVAL=$(sed -nE 's/.*git[[:space:]]+(.*[[:space:]]+)?-C[[:space:]]+([^[:space:]]+).*/\2/p' <<<"$PUSH_SEG" | head -1 || true)
CVAL="${CVAL#\'}"; CVAL="${CVAL%\'}"
CVAL="${CVAL#\"}"; CVAL="${CVAL%\"}"
if [ -n "$CVAL" ]; then
  case "$CVAL" in
    \~)          CVAL="$HOME" ;;
    \~/*)        CVAL="$HOME/${CVAL#\~/}" ;;
    '${HOME}')   CVAL="$HOME" ;;
    '${HOME}/'*) CVAL="$HOME/${CVAL#'${HOME}/'}" ;;
    '$HOME')     CVAL="$HOME" ;;
    '$HOME/'*)   CVAL="$HOME/${CVAL#'$HOME/'}" ;;
  esac
  TARGET="$CVAL"; HAS_C=1
else
  TARGET=""
  if command -v jq >/dev/null 2>&1; then
    TARGET="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
  fi
  [ -n "$TARGET" ] || TARGET="$(pwd)"
  HAS_C=0
fi

# Resolve the target to a git worktree root. An explicit -C target that does not
# resolve is fail-closed; a non-repo cwd (no -C) is a graceful no-op.
ROOT="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  if [ "$HAS_C" = 1 ]; then
    echo "AGENT REVIEW GATE: git push -C target '$TARGET' could not be resolved to a git repo." >&2
    echo "If the path has spaces/quotes, run the push from inside the repo so its diff can be verified." >&2
    exit 2
  fi
  exit 0
fi

# --- The checker lives next to this hook (installed as a sibling). ---
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HOOK_DIR/check-agent-review-gate.sh"
[ -e "$GATE" ] || exit 0   # checker not installed -> fail-open

# Run the gate in check mode. Feed /dev/null so its pre-push ref parser sees an
# empty, non-tty stream and performs the full review-surface check (it must NOT
# read this hook's JSON payload as if it were git's ref list).
out="$(cd "$ROOT" && bash "$GATE" </dev/null 2>&1)" && rc=0 || rc=$?

[ "$rc" -eq 0 ] && exit 0

# Blocked: surface the gate's reason + the exact receipt command to the agent.
{
  printf '%s\n\n' "$out"
  printf 'AGENT REVIEW GATE: push intercepted before it ran.\n'
  printf 'Do code review + simplify on the current diff, then mint the receipt:\n'
  printf '  bash "%s" --write --review "<review summary>" --simplify "<simplify summary>"\n' "$GATE"
  printf 'If simplify is not applicable:\n'
  printf '  bash "%s" --write --review "<summary>" --simplify-na "<reason>"\n' "$GATE"
  printf 'Then retry the push.\n'
  printf 'Audit-visible bypass (only if this hook itself is wrong): set SKIP_REVIEW_GATE=1 before the push.\n'
} >&2
exit 2
