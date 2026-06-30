#!/usr/bin/env bash
set -euo pipefail
#
# vibeguard pre-tool-use-hookspath-guard.sh - opt-in state-aware push guard.
#
# OPT-IN (install.sh --with-hookspath-guard). PreToolUse:Bash. Blocks a
# `git push` when the TARGET repo's LIVE core.hooksPath is redirected away from
# a husky-safe value -- closing the 2-command bypass that a regex guard cannot
# see: `git config core.hooksPath /tmp/x` (allowed, separate tool call) then a
# later `git push` (the hooks are already silently bypassed). The regex danger
# guard only sees one command at a time; this one reads the repo's live config.
#
# Scope: the LOCAL (repo) core.hooksPath only. A pre-existing GLOBAL hooksPath is
# the user's own legit setup (e.g. git-templates) and must NOT false-positive; a
# runtime bypass writes to local config by default, so local is what we check.
# --global / --worktree redirects are out of scope (louder, all-repos; checking
# global would brick every legit global-hooks user).
#
# Extracted from the upstream bash-guard push-state check. The husky-presence
# and review-receipt parts are intentionally NOT ported here (separate opt-ins).
# Fail-CLOSED (no jq / bad input JSON -> block), mirroring pre-tool-use-danger.sh:
# this is a security guard, not an advisory reminder.

command -v jq >/dev/null 2>&1 || { echo "BLOCKED : jq missing." >&2; exit 2; }
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || { echo "BLOCKED : invalid input JSON." >&2; exit 2; }
[ -z "$CMD" ] && exit 0

# Per-segment so a `-C` in one simple command is never paired with a `push` in
# another (e.g. `git -C /safe status; git push` must check the CWD repo, not
# /safe). First join backslash-newline line continuations (so `git \<nl>push` is
# seen as one command), then iterate the segments split on shell separators.
JOINED=${CMD//$'\\'$'\n'/ }

# check_segment <segment> : exit 2 to BLOCK; return 0 to allow this segment.
check_segment() {
  local SEG="$1" CVAL TARGET_REPO HAS_C HOOKS_PATH
  # only a git push (no separators inside a segment, so [^[:space:]] is safe).
  grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+([^[:space:]]+[[:space:]]+)*push([[:space:]]|$)' <<<"$SEG" || return 0

  # --git-dir/--work-tree targeting is not resolved here. Rather than check the
  # wrong repo, fail-closed: the push names a repo whose hooks we cannot verify.
  if grep -qE '(^|[[:space:]])--(git-dir|work-tree)([[:space:]]|=)' <<<"$SEG"; then
    echo "BLOCKED : git push via --git-dir/--work-tree; vibeguard cannot resolve that target to verify core.hooksPath." >&2
    echo "Run the push from inside the repo (plain 'git push') so its hooks config can be checked." >&2
    exit 2
  fi

  # Resolve `git -C <path>`, stripping ONE layer of surrounding matching quotes
  # the shell would remove (so `git -C '/repo' push` resolves to /repo).
  CVAL=$(sed -nE 's/.*git[[:space:]]+(.*[[:space:]]+)?-C[[:space:]]+([^[:space:]]+).*/\2/p' <<<"$SEG" | head -1 || true)
  CVAL="${CVAL#\'}"; CVAL="${CVAL%\'}"
  CVAL="${CVAL#\"}"; CVAL="${CVAL%\"}"
  if [ -n "$CVAL" ]; then HAS_C=1; TARGET_REPO="$CVAL"; else HAS_C=0; TARGET_REPO="."; fi

  # Expand a leading ~ or $HOME the shell WOULD expand at exec time; without this
  # a legit `git -C ~/repo push` looks unresolvable and is wrongly fail-closed.
  # Safe prefix substitution only (the hook shares the command's $HOME) -- never
  # eval. Other vars / ~user stay literal -> unresolved -> blocked.
  if [ "$HAS_C" = 1 ]; then
    case "$TARGET_REPO" in
      \~)           TARGET_REPO="$HOME" ;;
      \~/*)         TARGET_REPO="$HOME/${TARGET_REPO#\~/}" ;;
      '${HOME}')    TARGET_REPO="$HOME" ;;
      '${HOME}/'*)  TARGET_REPO="$HOME/${TARGET_REPO#'${HOME}/'}" ;;
      '$HOME')      TARGET_REPO="$HOME" ;;
      '$HOME/'*)    TARGET_REPO="$HOME/${TARGET_REPO#'$HOME/'}" ;;
    esac
  fi

  # Resolve the target as a git work tree. An explicit `-C` target that does NOT
  # resolve (e.g. a spaced path the word-based parse truncated) is fail-closed.
  # With NO explicit target a non-repo cwd is a graceful no-op: nothing to protect.
  if ! git -C "$TARGET_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ "$HAS_C" = 1 ]; then
      echo "BLOCKED : git push -C target '$TARGET_REPO' could not be resolved to a git repo." >&2
      echo "If the path has spaces/quotes, run the push from inside the repo so its hooks config can be checked." >&2
      exit 2
    fi
    return 0
  fi

  # Live LOCAL core.hooksPath. A runtime `git config core.hooksPath X` writes here
  # by default; --local excludes a legit global setup so it cannot false-positive.
  HOOKS_PATH=$(git -C "$TARGET_REPO" config --local --get core.hooksPath 2>/dev/null || true)
  # Strict EXACT allow-list. Unset = default .git/hooks. Exact match means a
  # traversal (.husky/../tmp) is NOT listed -> blocked by default.
  case "$HOOKS_PATH" in
    ""|".husky"|".husky/"|".husky/_"|".husky/_/") return 0 ;;
  esac
  echo "BLOCKED : git push with core.hooksPath=$HOOKS_PATH (expected: unset, .husky, or .husky/_)." >&2
  echo "Redirecting core.hooksPath silently bypasses your pre-push hooks. Reset it with:" >&2
  echo "  git -C $TARGET_REPO config --unset core.hooksPath" >&2
  exit 2
}

# Process substitution (NOT a pipe) so check_segment's `exit 2` exits the hook,
# not a subshell. tr maps each separator to a newline; read splits on newlines.
while IFS= read -r SEG; do
  check_segment "$SEG"
done < <(printf '%s\n' "$JOINED" | tr '|;&' '\n')

exit 0
