#!/usr/bin/env bash
set -euo pipefail
#
# vibeguard pre-tool-use-husky-guard.sh - opt-in husky pre-push presence guard.
#
# OPT-IN (install.sh --with-husky-guard). PreToolUse:Bash. Blocks a `git push`
# when the repo HAS husky set up (a .husky/ directory) but its `.husky/pre-push`
# hook is MISSING -- closing the deleted-pre-push footgun where the checks you
# rely on at push time silently do not run. No .husky, or pre-push present -> allow.
#
# It checks the WORKING-TREE ROOT of the pushing repo (git runs non-bare hooks from
# there, and husky's core.hooksPath=.husky is relative), so a push from a linked
# worktree is judged by its OWN checkout, not the primary's. Honours `git -C <path>`.
#
# SCOPE (seatbelt, not a vault -- see README): fail-OPEN. A missing pre-push is a
# mistake, not an attack, so anything this cannot cleanly resolve (an unreadable
# target, a quoted/obfuscated command, --git-dir/--work-tree) degrades to a MISSED
# check (allow), never a wrong block. Repo-wide enforcement is still the actual
# .husky/pre-push hook for non-Claude agents and manual pushes.

command -v jq >/dev/null 2>&1 || exit 0   # no jq -> can't parse input; fail-open
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$CMD" ] && exit 0

# Join backslash-newline continuations, then iterate shell-separated segments.
JOINED=${CMD//$'\\'$'\n'/ }

# git_subcommand <segment> : the first non-option token after `git` (skipping
# global options + their values), or nothing. Reused from the hookspath guard so
# only a real `git [globals] push` counts (not `git help push` / `rg "git push"`).
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

# check_segment <segment> : exit 2 to BLOCK; return 0 to allow.
check_segment() {
  local SEG="$1" CVAL TARGET_REPO ROOT
  # Only a plainly-parsed `push` proceeds. An ambiguous subcommand ('?', from an
  # unparseable quoted option value) fails OPEN -> allow (never a false block).
  case "$(git_subcommand "$SEG")" in
    push) : ;;
    *) return 0 ;;
  esac

  # --git-dir/--work-tree retarget the repo in a way we do not resolve here; fail
  # OPEN (allow) rather than check the wrong repo and risk a false block.
  if grep -qE '(^|[[:space:]])--(git-dir|work-tree)([[:space:]]|=)' <<<"$SEG"; then
    return 0
  fi

  # Resolve `git -C <path>` (strip one layer of matching quotes; expand ~/$HOME the
  # shell would); with no -C, check the cwd repo.
  CVAL=$(sed -nE 's/.*git[[:space:]]+(.*[[:space:]]+)?-C[[:space:]]+([^[:space:]]+).*/\2/p' <<<"$SEG" | head -1 || true)
  CVAL="${CVAL#\'}"; CVAL="${CVAL%\'}"; CVAL="${CVAL#\"}"; CVAL="${CVAL%\"}"
  if [ -n "$CVAL" ]; then
    case "$CVAL" in
      \~)          CVAL="$HOME" ;;
      \~/*)        CVAL="$HOME/${CVAL#\~/}" ;;
      '$HOME')     CVAL="$HOME" ;;
      '$HOME/'*)   CVAL="$HOME/${CVAL#'$HOME/'}" ;;
      '${HOME}')   CVAL="$HOME" ;;
      '${HOME}/'*) CVAL="$HOME/${CVAL#'${HOME}/'}" ;;
    esac
    TARGET_REPO="$CVAL"
  else
    TARGET_REPO="."
  fi

  # The pre-push hook that actually runs is resolved from the WORKING-TREE ROOT of
  # the pushing repo/worktree (git runs non-bare hooks there; husky's relative
  # core.hooksPath=.husky resolves there too). Check THAT root, so a push from a
  # worktree is judged by its own checkout. Unresolved target -> allow (fail-open).
  ROOT=$(git -C "$TARGET_REPO" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$ROOT" ] || return 0

  # husky set up but pre-push gone -> block. (husky v9 sources the user file via
  # .husky/_/pre-push, so the user-facing file needs no executable bit.)
  if [ -d "$ROOT/.husky" ] && [ ! -f "$ROOT/.husky/pre-push" ]; then
    echo "BLOCKED : git push, but $ROOT/.husky/pre-push is missing." >&2
    echo "This repo uses husky; the pre-push hook that guards your push is gone." >&2
    echo "Restore .husky/pre-push before pushing (or remove .husky/ if husky is unused)." >&2
    exit 2
  fi
  return 0
}

# Process substitution (NOT a pipe) so check_segment's exit 2 exits the hook.
while IFS= read -r SEG; do
  check_segment "$SEG"
done < <(printf '%s\n' "$JOINED" | tr '|;&' '\n')

exit 0
