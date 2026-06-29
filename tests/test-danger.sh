#!/usr/bin/env bash
# vibeguard danger-hook smoke (generated). Full pattern set is proven against
# the upstream bash-guard test; this is a standalone subset for vibeguard CI.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-danger.sh}"
PASS=0; FAIL=0
ck(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }
feed(){ printf "%s" "$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')" | bash "$HOOK" >/dev/null 2>&1; }
echo "=== danger hook smoke ==="
feed "ls -la"; ck $? 0 "benign-ls"
feed "git status"; ck $? 0 "allow-status"
feed "git log --oneline -1"; ck $? 0 "allow-log"
feed "git add file.txt"; ck $? 0 "allow-add-file"
feed "git push --force origin f"; ck $? 2 "block-force-push"
feed "rm -rf /tmp/x"; ck $? 2 "block-rm-recursive"
printf "not json" | bash "$HOOK" >/dev/null 2>&1; ck $? 2 "invalid-json"
echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
