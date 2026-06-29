#!/usr/bin/env bash
set -euo pipefail
#
# .codex/hooks/run.sh — Codex -> Claude hook bridge.
#
# WHY THIS EXISTS
#   Codex CLI implements the Claude Code hook wire-protocol: same stdin JSON
#   (tool_name / tool_input / hook_event_name / cwd), same "exit 2 blocks +
#   stderr is the reason" semantics, same event names (PreToolUse / PostToolUse
#   / Stop / SessionStart), and it normalizes tool names to Claude's
#   (Read/Edit/Write/Bash). So the EXISTING .claude/hooks/*.sh scripts run
#   unchanged under Codex — we reuse them verbatim (single source of truth, no
#   drift between the two agents).
#
#   ONE difference must be bridged: Codex does NOT set CLAUDE_PROJECT_DIR for
#   project hooks (only PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT for plugin hooks).
#   Several hooks are fail-closed on an unset CLAUDE_PROJECT_DIR — most
#   importantly pre-tool-use-scope.sh (LOCK-V4-15: empty/invalid dir => BLOCK
#   exit 2). Without this bridge, EVERY Edit/Write under Codex would be blocked.
#
#   Codex runs project hooks with cwd = repo root; `git rev-parse --show-toplevel`
#   is the robust resolver (handles worktrees too). We inject it, then exec the
#   real Claude hook with stdin/args passed straight through.
#
# USAGE (from .codex/hooks.json):
#   bash .codex/hooks/run.sh <hook-script-name.sh>
#
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export CLAUDE_PROJECT_DIR="$ROOT"

# Defensive: $1 comes from .codex/hooks.json (trusted) but harden anyway —
# only a bare hook script name, no path segments or traversal.
case "${1:-}" in
  ""|*/*|*..*) echo "BLOCKED : Codex hook bridge — nom de hook invalide: '${1:-}'" >&2; exit 2 ;;
esac

HOOK="$ROOT/.claude/hooks/$1"
if [ ! -f "$HOOK" ]; then
  echo "BLOCKED : Codex hook bridge — hook introuvable: $HOOK" >&2
  exit 2
fi

# stdin (the PreToolUse/etc. JSON payload) flows through exec untouched.
exec bash "$HOOK" "${@:2}"
