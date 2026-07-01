#!/usr/bin/env bash
set -euo pipefail
#
# vibeguard install - merge-safe, idempotent, cross-agent (Claude Code + Codex).
# Usage: ./install.sh [--with-worktree-lock] [--] [TARGET_REPO]   (default: current dir)
#
# Guarantees:
#   - NEVER clobbers an existing .claude/settings.json (jq merge that adds hooks,
#     reordering only the ordering-critical pwd-guard to the front; + backup).
#   - Idempotent: re-running adds nothing if hooks already registered.
#   - Registers the SAME core hooks for Claude (settings.json) AND Codex (.codex bridge).
#
# --with-worktree-lock (opt-in, Claude only): also installs the worktree
#   session-lock (session-start.sh + pre-tool-use-pwd-guard.sh). Off by default
#   because it is pointless for a single agent in a single repo and would get in
#   a solo vibe-coder's way.

VG_SRC="$(cd "$(dirname "$0")" && pwd)"

# Parse optional opt-in flags (--with-worktree-lock / --with-merge-triage /
# --with-hookspath-guard) + at most one positional TARGET.
# `--` ends option parsing (so a TARGET path may start with `-`); extra
# positionals are a hard error rather than a silent last-wins.
WITH_LOCK=0
WITH_TRIAGE=0
WITH_HOOKSPATH=0
WITH_DRAFT=0
TARGET=""
TARGET_SET=0
END_OPTS=0
while [ $# -gt 0 ]; do
  if [ "$END_OPTS" = "0" ]; then
    case "$1" in
      --) END_OPTS=1; shift; continue ;;
      --with-worktree-lock) WITH_LOCK=1; shift; continue ;;
      --with-merge-triage) WITH_TRIAGE=1; shift; continue ;;
      --with-hookspath-guard) WITH_HOOKSPATH=1; shift; continue ;;
      --with-draft-mode) WITH_DRAFT=1; shift; continue ;;
      -h|--help) echo "Usage: ./install.sh [--with-worktree-lock] [--with-merge-triage] [--with-hookspath-guard] [--with-draft-mode] [--] [TARGET_REPO]"; exit 0 ;;
      -*) echo "vibeguard: unknown option $1" >&2; exit 1 ;;
    esac
  fi
  if [ "$TARGET_SET" = "1" ]; then
    echo "vibeguard: too many arguments (one TARGET_REPO only): $1" >&2; exit 1
  fi
  TARGET="$1"; TARGET_SET=1; shift
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
# Opt-in PR merge-triage gate (Claude only). Appended: it gates `gh pr merge`
# and has no ordering dependency on the other Bash guards.
if [ "$WITH_TRIAGE" = "1" ]; then
  CLAUDE_HOOKS+=("pre-tool-use-merge-triage.sh:PreToolUse:Bash")
fi
# Opt-in state-aware hooksPath push guard (Claude only). Appended: it gates
# `git push` and has no ordering dependency on the other Bash guards.
if [ "$WITH_HOOKSPATH" = "1" ]; then
  CLAUDE_HOOKS+=("pre-tool-use-hookspath-guard.sh:PreToolUse:Bash")
fi
# Opt-in PR draft-review gate (Claude only). Appended: it gates `gh pr create`
# / `gh pr ready` and has no ordering dependency on the other Bash guards.
if [ "$WITH_DRAFT" = "1" ]; then
  CLAUDE_HOOKS+=("pre-tool-use-draft-mode.sh:PreToolUse:Bash")
fi

# register_hook <json-file> <command> <event> <matcher> [append|prepend]
# Idempotent: rewrites the file only when the merge changes it.
#   - append  : add once if the command is absent (leave position as-is).
#   - prepend : ensure the command is FIRST in the event list, self-healing an
#     existing-but-misordered entry (the pwd-guard ordering invariant). Re-running
#     is a no-op once it is already first.
# An empty matcher (SessionStart) produces an entry with no matcher key.
register_hook() {
  local file="$1" cmd="$2" ev="$3" m="$4" pos="${5:-append}" tmp
  tmp="$(mktemp)"
  if ! jq --arg cmd "$cmd" --arg ev "$ev" --arg m "$m" --arg pos "$pos" '
    .hooks //= {} | .hooks[$ev] //= [] |
    ( if $m == "" then {hooks:[{type:"command", command:$cmd}]}
      else {matcher:$m, hooks:[{type:"command", command:$cmd}]} end ) as $entry |
    if $pos == "prepend" then
      # Remove only the matching hook OBJECT from each entry (preserving any
      # co-located hooks + matcher), drop entries left empty, then prepend a
      # fresh single-hook entry. Never clobbers unrelated hooks.
      ( .hooks[$ev]
        | map(.hooks |= map(select(.command != $cmd)))
        | map(select((.hooks | length) > 0)) ) as $cleaned |
      .hooks[$ev] = ([$entry] + $cleaned)
    else
      if ([.hooks[$ev][]?.hooks[]?.command] | any(. == $cmd)) then .
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
[ "$WITH_LOCK" = "1" ] && LOCK_NOTE="$LOCK_NOTE + worktree session-lock (Claude)"
[ "$WITH_TRIAGE" = "1" ] && LOCK_NOTE="$LOCK_NOTE + merge-triage (Claude)"
[ "$WITH_HOOKSPATH" = "1" ] && LOCK_NOTE="$LOCK_NOTE + hookspath-guard (Claude)"
[ "$WITH_DRAFT" = "1" ] && LOCK_NOTE="$LOCK_NOTE + draft-mode (Claude)"
echo "vibeguard: installed ${#HOOKS[@]} core hook(s)$LOCK_NOTE into $TARGET (Claude + Codex). Backups: *.vibeguard-bak.*"
