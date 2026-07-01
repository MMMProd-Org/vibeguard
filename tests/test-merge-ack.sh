#!/usr/bin/env bash
# Proves the opt-in merge-ack: writer mints an ack hashing current bot threads;
# verifier/hook gate a merge on a fresh matching ack. Fail-OPEN everywhere else.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="${CHECK_PATH:-$VG/hooks/check-merge-ack.sh}"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-merge-ack.sh}"
BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }
mkrepo(){ local d; d=$(mktemp -d); git init -q "$d"; ( cd "$d" && git commit -q --allow-empty -m init ); printf '%s' "$d"; }
THREADS='[{"id":11,"author":"qodo-code-review[bot]"},{"id":7,"author":"Copilot"},{"id":3,"author":"some-human"}]'

R1=$(mkrepo)
( cd "$R1" && VIBEGUARD_ACK_THREADS_JSON="$THREADS" "$BASH_BIN" "$CHECK" 42 "fix:2" >/dev/null 2>&1 )
ok "$([ -f "$R1/.agent-backlog/triaged-prs/42.ack" ] && echo yes || echo no)" yes "writer creates ack file"
ok "$(grep -c '^comments_hash: [0-9a-f]\{64\}$' "$R1/.agent-backlog/triaged-prs/42.ack" 2>/dev/null || echo 0)" 1 "ack has a 64-hex comments_hash"
ok "$(grep -c '^ts_epoch: [0-9]\{1,\}$' "$R1/.agent-backlog/triaged-prs/42.ack" 2>/dev/null || echo 0)" 1 "ack has numeric ts_epoch"
ok "$(sed -nE 's/^threads_triaged: ([0-9]+)$/\1/p' "$R1/.agent-backlog/triaged-prs/42.ack")" 2 "threads_triaged counts only the 2 bot threads"

runv(){ local dir="$1" pr="$2"; ( cd "$dir" && VIBEGUARD_ACK_THREADS_JSON="$THREADS" "$BASH_BIN" "$CHECK" --verify "$pr" >/dev/null 2>&1 ); }
R2=$(mkrepo)
runv "$R2" 42; ok $? 2 "verify: bot threads + no ack -> block(2)"
( cd "$R2" && VIBEGUARD_ACK_THREADS_JSON="$THREADS" "$BASH_BIN" "$CHECK" 42 >/dev/null 2>&1 )
runv "$R2" 42; ok $? 0 "verify: fresh ack + matching hash -> allow(0)"
python3 -c 'import io,re,sys; p=sys.argv[1]; s=io.open(p).read(); io.open(p,"w").write(re.sub(r"^ts_epoch: .*$","ts_epoch: 1",s,flags=re.M))' "$R2/.agent-backlog/triaged-prs/42.ack"
runv "$R2" 42; ok $? 2 "verify: ack older than TTL -> block(2)"
R3=$(mkrepo)
( cd "$R3" && VIBEGUARD_ACK_THREADS_JSON="$THREADS" "$BASH_BIN" "$CHECK" 42 >/dev/null 2>&1 )
MORE='[{"id":11,"author":"qodo-code-review[bot]"},{"id":7,"author":"Copilot"},{"id":99,"author":"coderabbitai[bot]"}]'
( cd "$R3" && VIBEGUARD_ACK_THREADS_JSON="$MORE" "$BASH_BIN" "$CHECK" --verify 42 >/dev/null 2>&1 ); ok $? 2 "verify: new bot thread -> hash mismatch -> block(2)"
NONE='[{"id":3,"author":"some-human"}]'
R4=$(mkrepo)
( cd "$R4" && VIBEGUARD_ACK_THREADS_JSON="$NONE" "$BASH_BIN" "$CHECK" --verify 42 >/dev/null 2>&1 ); ok $? 0 "verify: zero bot threads -> allow(0)"

feed(){ local dir="$1" cmd="$2"; shift 2; printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" | ( cd "$dir" && VIBEGUARD_ACK_THREADS_JSON="$THREADS" env "$@" "$BASH_BIN" "$HOOK" >/dev/null 2>&1 ); }
RH=$(mkrepo)
feed "$RH" "ls -la";                                     ok $? 0 "hook: non-merge command -> allow"
feed "$RH" "gh pr merge 42" VIBEGUARD_SKIP_MERGE_ACK=1;       ok $? 0 "hook: SKIP bypass -> allow"
feed "$RH" "gh pr merge 42";                                   ok $? 2 "hook: merge, bot threads, no ack -> BLOCK"
( cd "$RH" && VIBEGUARD_ACK_THREADS_JSON="$THREADS" "$BASH_BIN" "$CHECK" 42 >/dev/null 2>&1 )
feed "$RH" "gh pr merge 42";                                   ok $? 0 "hook: merge with fresh ack -> allow"
feed "$RH" "gh pr merge 42 -R MMMProd-Org/vibeguard";         ok $? 0 "hook: -R honored, same PR ack -> allow"
RLIT=$(mkrepo)
feed "$RLIT" "echo gh pr merge 42";                            ok $? 0 "hook: literal mention in a no-ack repo -> allow (gh not in cmd position)"
feed "$RLIT" "gh pr merge 42";                                 ok $? 2 "hook: real merge, bot threads, no ack -> BLOCK"

TGT=$(mkrepo)
( cd "$VG" && bash install.sh --with-merge-ack "$TGT" >/dev/null 2>&1 )
ok "$([ -f "$TGT/.claude/hooks/pre-tool-use-merge-ack.sh" ] && echo yes || echo no)" yes "install copies the hook"
ok "$([ -f "$TGT/.claude/hooks/check-merge-ack.sh" ] && echo yes || echo no)" yes "install copies the checker helper"
ok "$(grep -c 'pre-tool-use-merge-ack.sh' "$TGT/.claude/settings.json" 2>/dev/null || echo 0)" 1 "hook registered in settings"

echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
