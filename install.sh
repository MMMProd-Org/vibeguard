#!/usr/bin/env bash
set -euo pipefail
#
# vibeguard install - merge-safe, idempotent, cross-agent (Claude Code + Codex).
# Usage: ./install.sh [--with-worktree-lock] [TARGET_REPO]   (default: current dir)
#
# Guarantees:
#   - NEVER clobbers an existing .claude/settings.json (append-only jq merge + backup).
#   - Idempotent: re-running adds nothing if hooks already registered.
#   - Registers the SAME core hooks for Claude (settings.json) AND Codex (.codex bridge).
#
# --with-worktree-lock (opt-in, Claude only): also installs the worktree
#   session-lock (session-start.sh + pre-tool-use-pwd-guard.sh). Off by default
#   because it is pointless for a single agent in a single repo and would get in
#   a solo vibe-coder's way.

VG_SRC="$(cd "$(dirname "$0")" && pwd)"

# Parse an optional --with-worktree-lock flag + an optional positional TARGET.
WITH_LOCK=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --with-worktree-lock) WITH_LOCK=1 ;;
    -h|--help) echo "Usage: ./install.sh [--with-worktree-lock] [TARGET_REPO]"; exit 0 ;;
    -*) echo "vibeguard: unknown option $arg" >&2; exit 1 ;;
    *) TARGET="$arg" ;;
  esac
done
TARGET="${TARGET:-$PWD}"

command -v jq  >/dev/null 2>&1 || { echo "vibeguard: jq required (apt/brew install jq)" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "vibeguard: git required" >&2; exit 1; }
[ -d "$TARGET/.git" ] || echo "vibeguard: WARN $TARGET is not a git repo - installing anyway." >&2

# "<hook-file>:<event>:<matcher>"  (matcher may contain | but never :; empty for SessionStart)
# Core hooks: installed for Claude AND Codex.
HOOKS=(
  "block-force-push.sh:PreToolUse:Bash"
  "pre-tool-use-scope.sh:PreToolUse:Edit|Write|NotebookEdit|MultiEdit|apply_patch"
  "pre-tool-use-danger.sh:PreToolUse:Bash"
)

# Claude hook list: opt-in worktree-lock hooks are prepended so pwd-guard lands
# FIRST in the PreToolUse:Bash group (it must run before the Bash guards).
CLAUDE_HOOKS=()
if [ "$WITH_LOCK" = "1" ]; then
  CLAUDE_HOOKS+=("pre-tool-use-pwd-guard.sh:PreToolUse:Bash" "session-start.sh:SessionStart:")
fi
CLAUDE_HOOKS+=( "${HOOKS[@]}" )

# register_hook <json-file> <command> <event> <matcher>
# Append-only + idempotent: rewrites the file only when the merge changes it.
# An empty matcher (SessionStart) produces an entry with no matcher key.
register_hook() {
  local file="$1" cmd="$2" ev="$3" m="$4" pos="${5:-append}" tmp
  tmp="$(mktemp)"
  if ! jq --arg cmd "$cmd" --arg ev "$ev" --arg m "$m" --arg pos "$pos" '
    .hooks //= {} | .hooks[$ev] //= [] |
    if ([.hooks[$ev][]?.hooks[]?.command] | any(. == $cmd)) then .
    else
      ( if $m == "" then {hooks:[{type:"command", command:$cmd}]}
        else {matcher:$m, hooks:[{type:"command", command:$cmd}]} end ) as $entry |
      if $pos == "prepend" then .hooks[$ev] = ([$entry] + .hooks[$ev])
      else .hooks[$ev] += [$entry] end
    end
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    echo "vibeguard: $file is not valid JSON - fix or remove it, then re-run." >&2
    exit 1
  fi
  if cmp -s "$file" "$tmp"; then rm -f "$tmp"; else mv "$tmp" "$file"; fi
}

mkdir -p "$TARGET/.claude/hooks"
# install_file <src> <dst>: never silently clobber a differing file.
# identical -> skip (true idempotence); differs -> back up first (settings.json policy).
install_file() {
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then chmod +x "$dst"; return 0; fi
    cp "$dst" "$dst.vibeguard-bak.$(date +%s 2>/dev/null || echo bak).$$"
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
}
# Copy every hook file Claude will wire (core + opt-in lock).
for spec in "${CLAUDE_HOOKS[@]}"; do
  f="${spec%%:*}"
  install_file "$VG_SRC/hooks/$f" "$TARGET/.claude/hooks/$f"
done

# Claude: merge into .claude/settings.json (back up once, only if it changes)
SETTINGS="$TARGET/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
SNAP="$(mktemp)"; cp "$SETTINGS" "$SNAP"
for spec in "${CLAUDE_HOOKS[@]}"; do
  f="${spec%%:*}"; rest="${spec#*:}"; event="${rest%%:*}"; matcher="${rest##*:}"
  pos="append"; [ "$f" = "pre-tool-use-pwd-guard.sh" ] && pos="prepend"
  register_hook "$SETTINGS" 'bash "${CLAUDE_PROJECT_DIR:?CLAUDE_PROJECT_DIR unset}/.claude/hooks/'"$f"'"' "$event" "$matcher" "$pos"
done
cmp -s "$SNAP" "$SETTINGS" || cp "$SNAP" "$SETTINGS.vibeguard-bak.$(date +%s 2>/dev/null || echo bak).$$"
rm -f "$SNAP"

# Codex: bridge run.sh + merge into .codex/hooks.json (core hooks only; the
# worktree-lock is Claude-only for now). Back up once, only if it changes.
mkdir -p "$TARGET/.codex/hooks"
install_file "$VG_SRC/codex/run.sh" "$TARGET/.codex/hooks/run.sh"
CX="$TARGET/.codex/hooks.json"
[ -f "$CX" ] || echo '{"hooks":{}}' > "$CX"
CXSNAP="$(mktemp)"; cp "$CX" "$CXSNAP"
for spec in "${HOOKS[@]}"; do
  f="${spec%%:*}"; rest="${spec#*:}"; event="${rest%%:*}"; matcher="${rest##*:}"
  register_hook "$CX" "bash .codex/hooks/run.sh $f" "$event" "$matcher"
done
cmp -s "$CXSNAP" "$CX" || cp "$CXSNAP" "$CX.vibeguard-bak.$(date +%s 2>/dev/null || echo bak).$$"
rm -f "$CXSNAP"

LOCK_NOTE=""
[ "$WITH_LOCK" = "1" ] && LOCK_NOTE=" + worktree session-lock (Claude)"
echo "vibeguard: installed ${#HOOKS[@]} core hook(s)$LOCK_NOTE into $TARGET (Claude + Codex). Backups: *.vibeguard-bak.*"
