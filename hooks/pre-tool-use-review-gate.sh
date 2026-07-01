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

# --- Only act on a push. ---
if ! printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|[;&|`]|\$\()git[[:space:]]+push([[:space:]]|$)'; then
  exit 0
fi

# --- Resolve the working directory of the push. ---
cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$(pwd)"

# Must be inside a git worktree; otherwise nothing to gate -> allow.
ROOT="$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || exit 0

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
