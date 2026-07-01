#!/usr/bin/env bash
# Proves scripts/merge-state.sh: read-only PR merge-state dump as stable JSON.
# Stubs gh on PATH (no network). Contract:
#   - missing dep (gh/jq), bad PR arg, unresolvable repo, pr-view failure -> error + exit != 0
#   - a review-thread fetch failure is fail-soft: unresolved_bot_threads=null, dump still emitted
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${SCRIPT_PATH:-$VG/scripts/merge-state.sh}"
BASH=$(command -v bash)
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got [$1] want [$2])"; fi; }
oknz(){ if [ "$1" -ne 0 ]; then PASS=$((PASS+1)); echo "  PASS $2"; else FAIL=$((FAIL+1)); echo "  FAIL $2 (got 0, want nonzero)"; fi; }

# ---- fixture builders ----
pv(){ jq -nc --argjson ci "$1" --arg m "${2:-MERGEABLE}" --arg s "${3:-CLEAN}" --arg rd "${4:-APPROVED}" \
  '{number:5,title:"t",headRefName:"feat/x",baseRefName:"main",mergeable:$m,mergeStateStatus:$s,reviewDecision:$rd,statusCheckRollup:$ci}'; }
node(){ jq -nc --argjson r "$1" --arg a "$2" '{isResolved:$r,comments:{nodes:[{author:{login:$a}}]}}'; }
threads(){ jq -nc --argjson n "$1" '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$n}}}}}'; }
# mkgh <pvfile|-> <thfile|-> <repoview:ok|fail> : fake gh dir. "-" = that subcommand exits 1.
mkgh(){
  local d pv="$1" th="$2" rv="${3:-ok}"; d=$(mktemp -d)
  { echo '#!/bin/sh'; echo 'case "$*" in'
    if [ "$rv" = ok ]; then echo '  *"repo view"*) echo "owner/repo" ;;'; else echo '  *"repo view"*) exit 1 ;;'; fi
    if [ "$pv" = "-" ]; then echo '  *"pr view"*) exit 1 ;;'; else printf '  *"pr view"*) cat %q ;;\n' "$pv"; fi
    if [ "$th" = "-" ]; then echo '  *"api graphql"*) exit 1 ;;'; else printf '  *"api graphql"*) cat %q ;;\n' "$th"; fi
    echo '  *) exit 1 ;;'; echo 'esac'
  } >"$d/gh"; chmod +x "$d/gh"; echo "$d"
}
run(){ PATH="$1:$PATH" bash "$SCRIPT" "${@:2}" 2>/dev/null; }

PVF=$(mktemp); THF=$(mktemp)

# 1. nominal: 2 pass checks, no threads
pv '[{"conclusion":"SUCCESS"},{"state":"SUCCESS"}]' >"$PVF"; threads '[]' >"$THF"
D=$(mkgh "$PVF" "$THF"); OUT=$(run "$D" 5); RC=$?
ok "$RC" 0 "nominal -> exit 0"
ok "$(printf '%s' "$OUT"|jq -r '.pr')" 5 "nominal: pr=5"
ok "$(printf '%s' "$OUT"|jq -r '.base')" main "nominal: base=main"
ok "$(printf '%s' "$OUT"|jq -r '.merge_state')" CLEAN "nominal: merge_state=CLEAN"
ok "$(printf '%s' "$OUT"|jq -r '.ci.pass')" 2 "nominal: ci.pass=2"
ok "$(printf '%s' "$OUT"|jq -r '.unresolved_bot_threads')" 0 "nominal: 0 unresolved threads"

# 2. mixed CI: 1 pass / 1 fail / 1 pending
pv '[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"},{"status":"IN_PROGRESS","conclusion":""}]' >"$PVF"
D=$(mkgh "$PVF" "$THF"); OUT=$(run "$D" 5)
ok "$(printf '%s' "$OUT"|jq -r '.ci.pass')" 1 "mixed: ci.pass=1"
ok "$(printf '%s' "$OUT"|jq -r '.ci.fail')" 1 "mixed: ci.fail=1"
ok "$(printf '%s' "$OUT"|jq -r '.ci.pending')" 1 "mixed: ci.pending=1"

# 3. threads: 2 unresolved bot, 1 resolved bot, 1 unresolved human -> count 2
pv '[]' >"$PVF"
threads "[$(node false 'coderabbit[bot]'),$(node false 'qodo-merge-pro[bot]'),$(node true 'copilot[bot]'),$(node false 'alice')]" >"$THF"
D=$(mkgh "$PVF" "$THF"); OUT=$(run "$D" 5)
ok "$(printf '%s' "$OUT"|jq -r '.unresolved_bot_threads')" 2 "threads: 2 unresolved bot (resolved+human excluded)"

# 4. custom BOT_PATTERN matches 'alice' only
threads "[$(node false 'alice'),$(node false 'bob')]" >"$THF"
D=$(mkgh "$PVF" "$THF"); OUT=$(VIBEGUARD_BOT_PATTERN='alice' bash -c 'PATH="'"$D"':$PATH" bash "'"$SCRIPT"'" 5' 2>/dev/null)
ok "$(printf '%s' "$OUT"|jq -r '.unresolved_bot_threads')" 1 "custom BOT_PATTERN -> alice only"

# 5. -R supplies repo when gh repo view fails
pv '[{"conclusion":"SUCCESS"}]' >"$PVF"; threads '[]' >"$THF"
Dn=$(mkgh "$PVF" "$THF" fail)
RC=0; run "$Dn" 5 >/dev/null 2>&1 || RC=$?; ok "$RC" 3 "no -R and repo view fails -> exit 3"
OUT=$(run "$Dn" 5 -R owner/repo); RC=$?; ok "$RC" 0 "-R supplies repo when repo view fails"

# 6. graphql fetch fails but pr view ok -> unresolved_bot_threads:null, still exit 0
Dg=$(mkgh "$PVF" -)
OUT=$(run "$Dg" 5); RC=$?
ok "$RC" 0 "graphql fail -> still exit 0 (dump useful)"
ok "$(printf '%s' "$OUT"|jq -r '.unresolved_bot_threads')" null "graphql fail -> unresolved_bot_threads:null"

# 7. pr view fails -> error
Dp=$(mkgh - "$THF"); RC=0; run "$Dp" 5 >/dev/null 2>&1 || RC=$?; ok "$RC" 2 "pr view fails -> exit 2"

# 8. bad / missing PR arg -> error
RC=0; run "$D" abc >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "non-numeric PR -> exit 1"
RC=0; run "$D"     >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "missing PR -> exit 1"

# 9. gh absent -> error ; jq absent -> error (isolated PATH)
# gh absent (jq present) exercises the gh dep-check specifically; jq absent hits the jq one.
Dga=$(mktemp -d); ln -s "$(command -v jq)" "$Dga/jq"; RC=0; PATH="$Dga" "$BASH" "$SCRIPT" 5 >/dev/null 2>&1 || RC=$?; ok "$RC" 4 "gh absent (jq present) -> exit 4"
Dgh=$(mktemp -d); cp "$D/gh" "$Dgh/gh"; RC=0; PATH="$Dgh" "$BASH" "$SCRIPT" 5 >/dev/null 2>&1 || RC=$?; ok "$RC" 4 "jq absent -> exit 4"

# strict arg validation (QODO1/QODO2/Copilot): extra positional, bad -R, unknown flag, --help
RC=0; run "$D" 5 6      >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "extra positional arg -> exit 1"
RC=0; run "$D" -R 5     >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "-R 5 (no slash) -> invalid repo exit 1"
RC=0; run "$D" 5 -R foo >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "-R foo (no slash) -> invalid repo exit 1"
RC=0; run "$D" -R       >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "-R missing value -> exit 1"
RC=0; run "$D" 5 -R /repo        >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "-R /repo (empty owner) -> exit 1"
RC=0; run "$D" 5 -R owner/       >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "-R owner/ (empty repo) -> exit 1"
RC=0; run "$D" 5 -R owner/repo/x >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "-R owner/repo/x (extra slash) -> exit 1"
RC=0; run "$D" 5 -R=       >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "-R= (explicit empty) -> exit 1"
RC=0; run "$D" 5 --repo=   >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "--repo= (explicit empty) -> exit 1"
RC=0; run "$D" 5 --bogus >/dev/null 2>&1 || RC=$?; ok "$RC" 1 "unknown option -> exit 1"
RC=0; run "$D" --help   >/dev/null 2>&1 || RC=$?; ok "$RC" 0 "--help -> exit 0 (not an error)"

# paginate: gh --paginate concatenates pages; jq -rs must flatten both -> count 2
pv '[]' >"$PVF"
{ threads "[$(node false 'coderabbit[bot]')]"; threads "[$(node false 'qodo[bot]')]"; } >"$THF"
Dpg=$(mkgh "$PVF" "$THF"); OUT=$(run "$Dpg" 5)
ok "$(printf '%s' "$OUT"|jq -r '.unresolved_bot_threads')" 2 "paginate: threads across 2 pages both counted"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
