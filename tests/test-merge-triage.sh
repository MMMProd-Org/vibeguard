#!/usr/bin/env bash
# Proves the opt-in merge-triage gate: blocks a merge only on UNRESOLVED bot
# review threads; fail-open everywhere else (advisory).
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-merge-triage.sh}"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }
# feed <command> [env...] : run hook with a Bash payload, return exit code.
feed(){ local cmd="$1"; shift; printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" | env "$@" bash "$HOOK" >/dev/null 2>&1; }

MERGE="gh pr merge 5"
UNRES_BOT='[{"resolved":false,"author":"coderabbit[bot]"}]'
RES_BOT='[{"resolved":true,"author":"coderabbit[bot]"}]'
UNRES_HUMAN='[{"resolved":false,"author":"alice"}]'
EMPTY='[]'

feed "gh pr view 5";                                         ok $? 0 "non-merge command -> allow"
printf '%s' "$(jq -nc '{tool_name:"Edit",tool_input:{command:"x"}}')" | bash "$HOOK" >/dev/null 2>&1; ok $? 0 "non-Bash tool -> allow"
feed "$MERGE" VIBEGUARD_TRIAGE_THREADS_JSON="$EMPTY";      ok $? 0 "merge + no bot threads -> allow (no-op)"
feed "$MERGE" VIBEGUARD_TRIAGE_THREADS_JSON="$UNRES_BOT";  ok $? 2 "merge + unresolved bot thread -> BLOCK"
feed "$MERGE" VIBEGUARD_TRIAGE_THREADS_JSON="$RES_BOT";    ok $? 0 "merge + resolved bot thread -> allow"
feed "$MERGE" VIBEGUARD_TRIAGE_THREADS_JSON="$UNRES_HUMAN"; ok $? 0 "merge + unresolved NON-bot thread -> allow (bots only)"
feed "$MERGE" VIBEGUARD_SKIP_TRIAGE=1 VIBEGUARD_TRIAGE_THREADS_JSON="$UNRES_BOT"; ok $? 0 "bypass VIBEGUARD_SKIP_TRIAGE=1 -> allow"
feed "$MERGE" VIBEGUARD_BOT_PATTERN="alice" VIBEGUARD_TRIAGE_THREADS_JSON="$UNRES_HUMAN"; ok $? 2 "custom pattern matches 'alice' -> BLOCK"
feed "$MERGE" VIBEGUARD_BOT_PATTERN="coderabbit" VIBEGUARD_TRIAGE_THREADS_JSON="$UNRES_HUMAN"; ok $? 0 "custom pattern excludes human -> allow"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
