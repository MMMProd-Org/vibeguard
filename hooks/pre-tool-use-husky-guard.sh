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
# It resolves the PRIMARY repo root (via --git-common-dir) so the check holds from
# any linked worktree, and honours `git -C <path> push` (with ~/$HOME expansion).
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
  local SEG="$1" CVAL TARGET_REPO COMMON_DIR PRIMARY_ROOT
  case "$(git_subcommand "$SEG")" in
    push|"?") : ;;
    *) return 0 ;;
  esac

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

  # PRIMARY repo root = parent of --git-common-dir (so the check holds from a
  # linked worktree too). Best-effort: anything unresolved -> allow (fail-open).
  COMMON_DIR=$(git -C "$TARGET_REPO" rev-parse --git-common-dir 2>/dev/null || true)
  [ -n "$COMMON_DIR" ] || return 0
  case "$COMMON_DIR" in
    /*) ;;
    *) COMMON_DIR="$(cd "$TARGET_REPO" 2>/dev/null && cd "$COMMON_DIR" 2>/dev/null && pwd)" || return 0 ;;
  esac
  [ -n "$COMMON_DIR" ] || return 0
  PRIMARY_ROOT="$(dirname "$COMMON_DIR")"

  # husky set up but pre-push gone -> block. (husky v9 sources the user file via
  # .husky/_/pre-push, so the user-facing file needs no executable bit.)
  if [ -d "$PRIMARY_ROOT/.husky" ] && [ ! -f "$PRIMARY_ROOT/.husky/pre-push" ]; then
    echo "BLOCKED : git push, but $PRIMARY_ROOT/.husky/pre-push is missing." >&2
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
