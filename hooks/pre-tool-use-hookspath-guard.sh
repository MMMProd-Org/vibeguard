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
# ponytail: --global / --worktree redirects are out of scope (louder, all-repos;
# checking global would brick every legit global-hooks user).
#
# Extracted from the upstream bash-guard push-state check. The husky-presence
# and review-receipt parts are intentionally NOT ported here (separate opt-ins).
# Fail-CLOSED (no jq / bad input JSON -> block), mirroring pre-tool-use-danger.sh:
# this is a security guard, not an advisory reminder.

command -v jq >/dev/null 2>&1 || { echo "BLOCKED : jq missing." >&2; exit 2; }
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || { echo "BLOCKED : invalid input JSON." >&2; exit 2; }
[ -z "$CMD" ] && exit 0

# Act only on a git push. Covers `git push`, `git -C <path> push`,
# `git -c k=v push`, `git --git-dir=... push`.
# Known limitation: a literal "git push" inside a string argument (rg "git push",
# sed 's/git push//') may match -- real shell tokenisation is not feasible in
# bash. A conservative footgun trade-off (same as the upstream guard).
printf '%s\n' "$CMD" | grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+([^[:space:]]+[[:space:]]+)*push([[:space:]]|$|;|&|\|)' || exit 0

# Resolve the target repo: honour `git -C <path>`, else the current directory.
TARGET_REPO=$(printf '%s\n' "$CMD" | sed -nE 's/.*git[[:space:]]+(.*[[:space:]]+)?-C[[:space:]]+([^[:space:]]+).*/\2/p' | head -1)
# Strip ONE layer of surrounding matching quotes the shell would remove, so
# `git -C '/repo' push` resolves to /repo (else a quoted -C path silently
# became "non-repo" and skipped the check).
TARGET_REPO="${TARGET_REPO#\'}"; TARGET_REPO="${TARGET_REPO%\'}"
TARGET_REPO="${TARGET_REPO#\"}"; TARGET_REPO="${TARGET_REPO%\"}"
[ -z "$TARGET_REPO" ] && TARGET_REPO="."

# Not a git repo -> the push is not ours to judge, allow (graceful no-op).
# Residual (documented, seatbelt-not-vault): a -C path containing SPACES is
# truncated by the word-based parse above and reads as non-repo here -> allowed.
# Closing it needs real shell tokenisation; an agent deliberately quoting a
# spaced path to evade is out of scope (the danger guard's same trade-off).
# Same status for repo targeting via --git-dir/--work-tree (uncommon for the
# vibe-coder audience): only `git -C <path>` is parsed; other forms fall back
# to the current directory. Footgun prevention, not an adversarial sandbox.
git -C "$TARGET_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Live LOCAL core.hooksPath. A runtime `git config core.hooksPath X` writes here
# by default; --local excludes a legit global setup so it cannot false-positive.
HOOKS_PATH=$(git -C "$TARGET_REPO" config --local --get core.hooksPath 2>/dev/null || true)

# Strict EXACT allow-list. Unset = default .git/hooks (fine). The husky values
# are the only redirected paths considered safe. Exact match means a traversal
# such as `.husky/../tmp/no-hooks` is NOT on the list -> blocked by default
# (no explicit `..` case needed).
case "$HOOKS_PATH" in
  ""|".husky"|".husky/"|".husky/_"|".husky/_/") exit 0 ;;
esac

echo "BLOCKED : git push with core.hooksPath=$HOOKS_PATH (expected: unset, .husky, or .husky/_)." >&2
echo "Redirecting core.hooksPath silently bypasses your pre-push hooks. Reset it with:" >&2
echo "  git -C $TARGET_REPO config --unset core.hooksPath" >&2
exit 2
