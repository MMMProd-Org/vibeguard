#!/usr/bin/env bash
set -euo pipefail
#
# vibeguard install — merge-safe, idempotent, cross-agent (Claude Code + Codex).
# Usage: ./install.sh [TARGET_REPO]   (default: current dir)
#
# Guarantees:
#   - NEVER clobbers an existing .claude/settings.json (append-only jq merge + backup).
#   - Idempotent: re-running adds nothing if hooks already registered.
#   - Registers the SAME hooks for Claude (settings.json) AND Codex (.codex bridge).

VG_SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$PWD}"

command -v jq  >/dev/null 2>&1 || { echo "vibeguard: jq required (apt/brew install jq)" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "vibeguard: git required" >&2; exit 1; }
command -v gh  >/dev/null 2>&1 || echo "vibeguard: WARN gh not found — PR-triage hooks degrade; core guardrails still work." >&2
[ -d "$TARGET/.git" ] || echo "vibeguard: WARN $TARGET is not a git repo — installing anyway." >&2

# "<hook-file>:<event>:<matcher>"  (matcher may contain | but never :)
HOOKS=(
  "block-force-push.sh:PreToolUse:Bash"
  "pre-tool-use-scope.sh:PreToolUse:Edit|Write|NotebookEdit|MultiEdit|apply_patch"
  "pre-tool-use-danger.sh:PreToolUse:Bash"
)

# register_hook <json-file> <command> <event> <matcher>
# Append-only + idempotent jq merge: never rewrites an existing entry.
register_hook() {
  local file="$1" cmd="$2" ev="$3" m="$4" tmp
  tmp="$(mktemp)"
  jq --arg cmd "$cmd" --arg ev "$ev" --arg m "$m" '
    .hooks //= {} | .hooks[$ev] //= [] |
    if ([.hooks[$ev][]?.hooks[]?.command] | any(. == $cmd)) then .
    else .hooks[$ev] += [{matcher:$m, hooks:[{type:"command", command:$cmd}]}] end
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

mkdir -p "$TARGET/.claude/hooks"
for spec in "${HOOKS[@]}"; do
  f="${spec%%:*}"
  cp "$VG_SRC/hooks/$f" "$TARGET/.claude/hooks/$f"
  chmod +x "$TARGET/.claude/hooks/$f"
done

# Claude: backup then merge into .claude/settings.json
SETTINGS="$TARGET/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.vibeguard-bak.$(date +%s 2>/dev/null || echo bak)"
for spec in "${HOOKS[@]}"; do
  f="${spec%%:*}"; rest="${spec#*:}"; event="${rest%%:*}"; matcher="${rest##*:}"
  register_hook "$SETTINGS" 'bash "${CLAUDE_PROJECT_DIR:?CLAUDE_PROJECT_DIR unset}/.claude/hooks/'"$f"'"' "$event" "$matcher"
done

# Codex: bridge run.sh + backup then merge into .codex/hooks.json
mkdir -p "$TARGET/.codex/hooks"
cp "$VG_SRC/codex/run.sh" "$TARGET/.codex/hooks/run.sh"
chmod +x "$TARGET/.codex/hooks/run.sh"
CX="$TARGET/.codex/hooks.json"
[ -f "$CX" ] || echo '{"hooks":{}}' > "$CX"
cp "$CX" "$CX.vibeguard-bak.$(date +%s 2>/dev/null || echo bak)"
for spec in "${HOOKS[@]}"; do
  f="${spec%%:*}"; rest="${spec#*:}"; event="${rest%%:*}"; matcher="${rest##*:}"
  register_hook "$CX" "bash .codex/hooks/run.sh $f" "$event" "$matcher"
done

echo "vibeguard: installed ${#HOOKS[@]} hook(s) into $TARGET (Claude + Codex). Backups: *.vibeguard-bak.*"
