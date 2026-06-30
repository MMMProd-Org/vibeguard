#!/usr/bin/env bash
set -euo pipefail
#
# vibeguard pre-tool-use-draft-mode.sh - opt-in PR draft-review gate.
#
# OPT-IN (install.sh --with-draft-mode). PreToolUse:Bash. Two CLI gates for a
# review-first pull-request workflow:
#   1. `gh pr create` must pass --draft, so a PR enters GitHub as a Draft and review
#      bots / humans can look before contract CI burns on it.
#   2. `gh pr ready` (mark a draft ready) must be acknowledged with PR_READY_ACK=1,
#      a deliberate "I checked the reviews + local gates" step.
#
# Opinionated: it assumes a GitHub PR workflow and WOULD get in a plain push's
# way, so it is off by default. Only `gh` in command position is inspected (not a
# read-only `rg "gh pr create"`). Fail-CLOSED on missing jq / bad input JSON.
#
# NOTE: vibeguard's own Claude flow creates PRs via the GitHub MCP tools, which
# this Bash hook never sees; this gate targets the `gh` CLI path (Codex / humans).

command -v jq >/dev/null 2>&1 || { echo "BLOCKED : jq missing." >&2; exit 2; }
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || { echo "BLOCKED : invalid input JSON." >&2; exit 2; }
[ -z "$CMD" ] && exit 0

# `gh` only when it is in shell command position (after optional wrappers), so a
# literal mention inside a string/search is not gated.
CMD_FLAT=$(printf '%s\n' "$CMD" | tr '\n' ' ')
GH_WRAPPER_RE='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+|env([[:space:]]+(-[^[:space:]]+|--[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+))*|time([[:space:]]+-[^[:space:]]+)*|command([[:space:]]+--)?|sudo([[:space:]]+(-[^[:space:]]+|--[^[:space:]]+))*|timeout([[:space:]]+(-[^[:space:]]+|--[^[:space:]]+|[0-9]+[smhd]?))*|if|then|do|while|until|!)[[:space:]]+'
GH_BIN_RE='([^[:space:]]*/)?(\\)?gh'
GH_COMMAND_RE="^[[:space:]]*([({][[:space:]]*)*(${GH_WRAPPER_RE})*${GH_BIN_RE}[[:space:]]+"

while IFS= read -r SEG; do
  echo "$SEG" | grep -qE "$GH_COMMAND_RE" || continue

  # 1. `gh pr create` must be --draft.
  if echo "$SEG" | grep -qE "${GH_COMMAND_RE}[^|;&]*pr[[:space:]]+create([[:space:]]|$)"; then
    if ! echo "$SEG" | grep -qE '(^|[[:space:]])--draft([[:space:]]|$)'; then
      echo "BLOCKED : gh pr create without --draft." >&2
      echo "Draft-review mode: open the PR as a Draft so review bots / humans can look" >&2
      echo "before CI runs, then mark it ready once reviews are settled." >&2
      exit 2
    fi
  fi

  # 2. `gh pr ready` must be acknowledged (skip an explicit --undo back to draft).
  if echo "$SEG" | grep -qE "${GH_COMMAND_RE}[^|;&]*pr[[:space:]]+ready([[:space:]]|$)"; then
    echo "$SEG" | grep -qE '(^|[[:space:]])--undo([[:space:]]|$)' && continue
    if ! echo "$SEG" | grep -qE '(^|[[:space:]])PR_READY_ACK=1([[:space:]]|$)'; then
      echo "BLOCKED : gh pr ready without PR_READY_ACK=1." >&2
      echo "Before marking ready, confirm the review bots are settled and your local" >&2
      echo "checks pass, then re-run explicitly: PR_READY_ACK=1 gh pr ready <PR>." >&2
      exit 2
    fi
  fi
done < <(printf '%s\n' "$CMD_FLAT" | tr '|;&' '\n')

exit 0
