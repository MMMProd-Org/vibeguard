#!/usr/bin/env bash
# Proves P0-2: install.sh MERGES (never clobbers) settings.json + idempotent + cross-agent.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got '$1' want '$2')"; fi; }

T="$(mktemp -d)"
git -C "$T" init -q
mkdir -p "$T/.claude"
# pre-existing USER settings with a custom hook that MUST survive
cat > "$T/.claude/settings.json" <<'JSON'
{"model":"opus","hooks":{"PostToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"echo USER_HOOK"}]}]}}
JSON

bash "$VG/install.sh" "$T" >/dev/null 2>&1

echo "=== P0-2 merge-not-clobber ==="
ok "$(jq -r '.model' "$T/.claude/settings.json")" "opus" "user .model preserved"
ok "$(jq -r '[.hooks.PostToolUse[].hooks[].command]|any(.=="echo USER_HOOK")' "$T/.claude/settings.json")" "true" "USER_HOOK preserved"
ok "$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command]|map(select(test("block-force-push")))|length' "$T/.claude/settings.json")" "1" "vibeguard hook added"
ok "$(ls "$T/.claude/"settings.json.vibeguard-bak.* >/dev/null 2>&1 && echo yes)" "yes" "backup created"

echo "=== all 3 hooks registered with correct matchers ==="
ok "$(jq -r '[.hooks.PreToolUse[]?|select((.hooks[]?.command//"")|test("pre-tool-use-scope"))|.matcher]|.[0]' "$T/.claude/settings.json")" "Edit|Write|NotebookEdit|MultiEdit|apply_patch" "scope hook matcher = exact Edit|Write|NotebookEdit|MultiEdit|apply_patch"
ok "$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command]|any(test("pre-tool-use-danger"))' "$T/.claude/settings.json")" "true" "danger hook registered"
ok "$([ -f "$T/.claude/hooks/pre-tool-use-danger.sh" ] && echo yes)" "yes" "danger hook file copied"
ok "$([ -f "$T/.claude/hooks/pre-tool-use-scope.sh" ] && echo yes)" "yes" "scope hook file copied"

echo "=== idempotence (2e run) ==="
nbak_before="$(ls "$T/.claude/"settings.json.vibeguard-bak.* 2>/dev/null | wc -l | tr -d ' ')"
bash "$VG/install.sh" "$T" >/dev/null 2>&1
ok "$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command]|map(select(test("block-force-push")))|length' "$T/.claude/settings.json")" "1" "no duplicate after re-run"
ok "$(ls "$T/.claude/"settings.json.vibeguard-bak.* 2>/dev/null | wc -l | tr -d ' ')" "$nbak_before" "re-run creates no new backup (idempotent)"

echo "=== cross-agent (Codex bridge) ==="
ok "$([ -x "$T/.codex/hooks/run.sh" ] && echo yes)" "yes" ".codex/hooks/run.sh installed+exec"
ok "$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command]|any(test("run.sh block-force-push"))' "$T/.codex/hooks.json")" "true" "Codex hook registered"

echo "=== fresh repo (no settings) ==="
T2="$(mktemp -d)"; git -C "$T2" init -q
bash "$VG/install.sh" "$T2" >/dev/null 2>&1
ok "$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command]|any(test("block-force-push"))' "$T2/.claude/settings.json")" "true" "fresh repo: hook installed"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
