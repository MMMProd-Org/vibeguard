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

# Act only on a git push. Detection matches `git push`, `git -C <path> push`,
# `git -c k=v push`. Repo targeting is RESOLVED only for `git -C <path>`; the
# --git-dir/--work-tree forms are detected and fail-closed below (refuse, never
# check the wrong repo). Known limitation: a literal "git push" inside a string
# argument (rg "git push") may match -- bash cannot truly tokenise a command.
grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+([^[:space:]]+[[:space:]]+)*push([[:space:]]|$|;|&|\|)' <<<"$CMD" || exit 0

# Repo targeting via --git-dir/--work-tree is not resolved here. Rather than
# check the current directory (the wrong repo) and hand out a free pass,
# fail-closed: the push names a repo whose hooks config we cannot verify.
if grep -qE '(^|[[:space:]])--(git-dir|work-tree)([[:space:]]|=)' <<<"$CMD"; then
  echo "BLOCKED : git push via --git-dir/--work-tree; vibeguard cannot resolve that target to verify core.hooksPath." >&2
  echo "Run the push from inside the repo (plain 'git push') so its hooks config can be checked." >&2
  exit 2
fi

# Resolve the target repo: honour `git -C <path>`, stripping ONE layer of the
# surrounding matching quotes the shell would remove (so `git -C '/repo' push`
# resolves to /repo). Else the current directory.
CVAL=$(sed -nE 's/.*git[[:space:]]+(.*[[:space:]]+)?-C[[:space:]]+([^[:space:]]+).*/\2/p' <<<"$CMD" | head -1 || true)
CVAL="${CVAL#\'}"; CVAL="${CVAL%\'}"
CVAL="${CVAL#\"}"; CVAL="${CVAL%\"}"
if [ -n "$CVAL" ]; then HAS_C=1; TARGET_REPO="$CVAL"; else HAS_C=0; TARGET_REPO="."; fi

# Resolve the target as a git work tree. An explicit `-C` target that does NOT
# resolve (e.g. a path with spaces the word-based parse truncated) is fail-closed
# -- an explicit, unverifiable target must not get a free pass. With NO explicit
# target (plain push) a non-repo cwd is a graceful no-op: nothing to protect.
if ! git -C "$TARGET_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$HAS_C" = 1 ]; then
    echo "BLOCKED : git push -C target '$TARGET_REPO' could not be resolved to a git repo." >&2
    echo "If the path has spaces/quotes, run the push from inside the repo so its hooks config can be checked." >&2
    exit 2
  fi
  exit 0
fi

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
