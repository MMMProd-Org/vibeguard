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
HOUT=$(run "$D" --help); ok "$(printf '%s' "$HOUT" | grep -c usage)" 1 "--help prints usage to stdout"

# paginate: gh --paginate concatenates pages; jq -rs must flatten both -> count 2
pv '[]' >"$PVF"
{ threads "[$(node false 'coderabbit[bot]')]"; threads "[$(node false 'qodo[bot]')]"; } >"$THF"
Dpg=$(mkgh "$PVF" "$THF"); OUT=$(run "$Dpg" 5)
ok "$(printf '%s' "$OUT"|jq -r '.unresolved_bot_threads')" 2 "paginate: threads across 2 pages both counted"


# ================= PR-b: next_action + blockers + reason =================
na(){ printf '%s' "$1" | jq -r '.next_action'; }
bl(){ printf '%s' "$1" | jq -rc '.blockers'; }
rs(){ printf '%s' "$1" | jq -r '.reason'; }

# ready: clean, approved, ci pass, no threads
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE CLEAN APPROVED >"$PVF"; threads '[]' >"$THF"
D=$(mkgh "$PVF" "$THF"); OUT=$(run "$D" 5)
ok "$(na "$OUT")" ready "next_action: clean -> ready"
ok "$(bl "$OUT")" '[]' "blockers: clean -> []"
ok "$(rs "$OUT")" "clean, mergeable" "reason: clean"

# fix_ci wins over pending; both listed as blockers
pv '[{"conclusion":"FAILURE"},{"status":"IN_PROGRESS","conclusion":""}]' MERGEABLE CLEAN APPROVED >"$PVF"
D=$(mkgh "$PVF" "$THF"); OUT=$(run "$D" 5)
ok "$(na "$OUT")" fix_ci "next_action: failing check -> fix_ci"
ok "$(bl "$OUT")" '["fix_ci","wait_ci"]' "blockers: fail+pending -> [fix_ci,wait_ci]"
ok "$(rs "$OUT")" "1 failing check(s)" "reason: fix_ci count"

# wait_ci only
pv '[{"status":"IN_PROGRESS","conclusion":""}]' MERGEABLE CLEAN APPROVED >"$PVF"
D=$(mkgh "$PVF" "$THF"); OUT=$(run "$D" 5); ok "$(na "$OUT")" wait_ci "next_action: pending -> wait_ci"

# resolve_conflicts is highest priority even with failing ci
pv '[{"conclusion":"FAILURE"}]' CONFLICTING DIRTY APPROVED >"$PVF"
D=$(mkgh "$PVF" "$THF"); OUT=$(run "$D" 5)
ok "$(na "$OUT")" resolve_conflicts "next_action: dirty -> resolve_conflicts (over fix_ci)"

# draft / behind / unknown
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE DRAFT APPROVED >"$PVF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5); ok "$(na "$OUT")" mark_ready "next_action: draft -> mark_ready"
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE BEHIND APPROVED >"$PVF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5); ok "$(na "$OUT")" update_branch "next_action: behind -> update_branch"
pv '[{"conclusion":"SUCCESS"}]' UNKNOWN UNKNOWN APPROVED >"$PVF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5); ok "$(na "$OUT")" wait_mergeability "next_action: unknown -> wait_mergeability"

# resolve_threads (ci clean, threads>0) vs verify_threads (fetch null)
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE CLEAN APPROVED >"$PVF"
threads "[$(node false 'coderabbit[bot]')]" >"$THF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5); ok "$(na "$OUT")" resolve_threads "next_action: unresolved thread -> resolve_threads"
OUT=$(run "$(mkgh "$PVF" -)" 5); ok "$(na "$OUT")" verify_threads "next_action: null threads -> verify_threads"

# co-blockers: pending + threads -> next=wait_ci, both listed
pv '[{"status":"QUEUED","conclusion":""}]' MERGEABLE CLEAN APPROVED >"$PVF"
threads "[$(node false 'qodo[bot]')]" >"$THF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5)
ok "$(na "$OUT")" wait_ci "co-blockers: pending+threads -> next=wait_ci"
ok "$(bl "$OUT")" '["wait_ci","resolve_threads"]' "co-blockers: [wait_ci,resolve_threads]"

# review states (ci clean, no threads)
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE CLEAN REVIEW_REQUIRED >"$PVF"; threads '[]' >"$THF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5); ok "$(na "$OUT")" request_review "next_action: review required"
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE CLEAN CHANGES_REQUESTED >"$PVF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5); ok "$(na "$OUT")" address_changes "next_action: changes requested"


# BLOCKED must never read as ready (branch protection not satisfied, no visible cause)
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE BLOCKED APPROVED >"$PVF"; threads '[]' >"$THF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5)
ok "$(na "$OUT")" resolve_block "next_action: BLOCKED (no visible cause) -> resolve_block (NOT ready)"
# a specific, actionable cause still wins over the generic block; block is listed last
pv '[{"conclusion":"FAILURE"}]' MERGEABLE BLOCKED APPROVED >"$PVF"
OUT=$(run "$(mkgh "$PVF" "$THF")" 5)
ok "$(na "$OUT")" fix_ci "BLOCKED + failing ci -> fix_ci (specific cause wins)"
ok "$(bl "$OUT")" '["fix_ci","resolve_block"]' "blockers: BLOCKED listed after the specific cause"


# ================= PR-c: optional decision policy (.vibeguard/merge-policy.json / $VIBEGUARD_MERGE_POLICY) =================
mkpol(){ local p; p=$(mktemp); printf '%s' "$1" >"$p"; echo "$p"; }

# action_labels renames the action token in next_action + blockers; reason stays
pv '[{"conclusion":"FAILURE"}]' MERGEABLE CLEAN APPROVED >"$PVF"; threads '[]' >"$THF"; D=$(mkgh "$PVF" "$THF")
POL=$(mkpol '{"action_labels":{"fix_ci":"ci_red"}}')
OUT=$(VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5)
ok "$(na "$OUT")" ci_red "policy: action_labels renames next_action"
ok "$(bl "$OUT")" '["ci_red"]' "policy: blockers renamed"
ok "$(rs "$OUT")" "1 failing check(s)" "policy: reason unchanged by rename"

# disabled_gates removes a gate before next_action is chosen
pv '[{"conclusion":"SUCCESS"}]' UNKNOWN UNKNOWN APPROVED >"$PVF"; threads '[]' >"$THF"; D=$(mkgh "$PVF" "$THF")
POL=$(mkpol '{"disabled_gates":["wait_mergeability"]}')
OUT=$(VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5)
ok "$(na "$OUT")" ready "policy: disabled gate -> ready"
ok "$(bl "$OUT")" '[]' "policy: disabled gate absent from blockers"

# bot_pattern override via policy
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE CLEAN APPROVED >"$PVF"; threads "[$(node false 'alice')]" >"$THF"; D=$(mkgh "$PVF" "$THF")
POL=$(mkpol '{"bot_pattern":"alice"}')
OUT=$(VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5)
ok "$(printf '%s' "$OUT"|jq -r '.unresolved_bot_threads')" 1 "policy: bot_pattern counts alice"
# explicit env VIBEGUARD_BOT_PATTERN wins over policy bot_pattern
OUT=$(VIBEGUARD_BOT_PATTERN='nobody' VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5)
ok "$(printf '%s' "$OUT"|jq -r '.unresolved_bot_threads')" 0 "env bot_pattern wins over policy"

# disable ONE gate while another remains (regression: filter must not drop all)
pv '[{"conclusion":"FAILURE"},{"status":"IN_PROGRESS","conclusion":""}]' MERGEABLE CLEAN APPROVED >"$PVF"; threads '[]' >"$THF"; D=$(mkgh "$PVF" "$THF")
POL=$(mkpol '{"disabled_gates":["wait_ci"]}')
OUT=$(VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5)
ok "$(na "$OUT")" fix_ci "policy: disable one gate, another remains -> fix_ci"
ok "$(bl "$OUT")" '["fix_ci"]' "policy: only the disabled gate removed"
# rename + disable combined
POL=$(mkpol '{"action_labels":{"fix_ci":"ci_red"},"disabled_gates":["wait_ci"]}')
OUT=$(VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5)
ok "$(na "$OUT")" ci_red "policy: rename+disable -> ci_red"
ok "$(bl "$OUT")" '["ci_red"]' "policy: rename+disable blockers=[ci_red]"

# invalid policy JSON -> fail-soft to defaults, exit 0
pv '[{"conclusion":"FAILURE"}]' MERGEABLE CLEAN APPROVED >"$PVF"; threads '[]' >"$THF"; D=$(mkgh "$PVF" "$THF")
BADPOL=$(mkpol 'not json {{{')
OUT=$(VIBEGUARD_MERGE_POLICY="$BADPOL" run "$D" 5); RC=$?
ok "$RC" 0 "invalid policy -> exit 0 (fail-soft)"
ok "$(na "$OUT")" fix_ci "invalid policy -> defaults (fix_ci)"

# no policy -> defaults unchanged
OUT=$(run "$D" 5); ok "$(na "$OUT")" fix_ci "no policy -> default next_action"

# valid-but-wrong-SHAPE policy must fail-soft to defaults (never brick, never silent mis-gate)
pv '[{"conclusion":"FAILURE"}]' MERGEABLE CLEAN APPROVED >"$PVF"; threads '[]' >"$THF"; D=$(mkgh "$PVF" "$THF")
for bad in '[]' '42' '"x"' 'true' '{"action_labels":[]}' '{"disabled_gates":5}'; do
  POL=$(mkpol "$bad"); OUT=$(VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5); RC=$?
  ok "$RC" 0 "wrong-shape policy $bad -> exit 0 (no brick)"
  ok "$(na "$OUT")" fix_ci "wrong-shape policy $bad -> defaults (fix_ci)"
done
# disabled_gates as a STRING must NOT silently disable via substring match
POL=$(mkpol '{"disabled_gates":"fix_ci"}')
OUT=$(VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5)
ok "$(na "$OUT")" fix_ci "disabled_gates string -> NOT disabled (fix_ci, not ready)"
# action_labels must not collapse a real gate onto reserved "ready"
pv '[{"conclusion":"SUCCESS"}]' MERGEABLE BLOCKED APPROVED >"$PVF"; D=$(mkgh "$PVF" "$THF")
POL=$(mkpol '{"action_labels":{"resolve_block":"ready"}}')
OUT=$(VIBEGUARD_MERGE_POLICY="$POL" run "$D" 5)
ok "$(na "$OUT")" resolve_block "action_labels ready-collision dropped -> resolve_block"
ok "$(bl "$OUT")" '["resolve_block"]' "ready-collision: blockers not relabeled to ready"
# auto-detect <repo-root>/.vibeguard/merge-policy.json (no env var)
AREPO=$(mktemp -d); git -C "$AREPO" init -q >/dev/null 2>&1; mkdir -p "$AREPO/.vibeguard"
printf '%s' '{"action_labels":{"fix_ci":"ci_red"}}' >"$AREPO/.vibeguard/merge-policy.json"
pv '[{"conclusion":"FAILURE"}]' MERGEABLE CLEAN APPROVED >"$PVF"; D=$(mkgh "$PVF" "$THF")
OUT=$( cd "$AREPO" && PATH="$D:$PATH" bash "$SCRIPT" 5 2>/dev/null )
ok "$(na "$OUT")" ci_red "auto-detect .vibeguard/merge-policy.json"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
