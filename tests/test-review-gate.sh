#!/usr/bin/env bash
# Proves the opt-in review-receipt gate. Two pieces:
#   - check-agent-review-gate.sh : writes/verifies a receipt over the current
#     diff surface (fresh <=24h, surface + path set must match).
#   - pre-tool-use-review-gate.sh : intercepts `git push`, delegates to the
#     checker, blocks (exit 2) when no fresh matching receipt exists.
# Fail-closed in the checker on missing tools; fail-open in the hook on a
# non-push / non-repo; SKIP_REVIEW_GATE=1 is an audit-visible bypass.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
CHK="${CHK_PATH:-$VG/hooks/check-agent-review-gate.sh}"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-review-gate.sh}"
BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }

# a repo with one base commit; $1=surface -> leave an uncommitted change.
mkrepo(){
  local d surface="${1:-}"; d=$(mktemp -d)
  git init -q "$d"; git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'base\n' > "$d/f.txt"; git -C "$d" add f.txt; git -C "$d" commit -qm base >/dev/null 2>&1
  [ "$surface" = "surface" ] && printf 'change\n' >> "$d/f.txt"
  printf '%s' "$d"
}
# run the checker inside a repo dir.
chk(){ local d="$1"; shift; ( cd "$d" && "$BASH_BIN" "$CHK" "$@" </dev/null >/dev/null 2>&1 ); }
mint(){ chk "$1" --write --review "senior review pass: ok" --simplify-na "1-line change"; }
# feed the hook a push payload with a chosen cwd (+ optional env).
push(){ local d="$1" cmd="${2:-git push origin HEAD}"; shift; shift 2>/dev/null
  printf '%s' "$(jq -nc --arg c "$cmd" --arg d "$d" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')" \
    | env "$@" "$BASH_BIN" "$HOOK" >/dev/null 2>&1; }

echo "-- checker --"
CLEAN=$(mkrepo)
chk "$CLEAN";                         ok $? 0 "check: no review surface -> allow"
S=$(mkrepo surface)
chk "$S";                             ok $? 1 "check: surface + no receipt -> block"
mint "$S";                            ok $? 0 "write: mint receipt over surface -> ok"
chk "$S";                             ok $? 0 "check: fresh matching receipt -> allow"
printf 'more\n' >> "$S/f.txt"
chk "$S";                             ok $? 1 "check: surface changed after receipt -> block"
chk "$S" --write --simplify-na "x";   ok $? 2 "write: missing --review -> usage error"
chk "$S" --write --review "r";        ok $? 2 "write: neither simplify nor -na -> usage error"
( cd "$S" && PATH=/nonexistent "$BASH_BIN" "$CHK" </dev/null >/dev/null 2>&1 )
                                      ok $? 2 "checker: required tool missing -> fail-closed"

# base resolution: a master-default repo (no main) anchors to master, not the
# root commit (else a clean repo is wrongly seen as an unreviewed surface).
M=$(mktemp -d); git init -q "$M"; git -C "$M" symbolic-ref HEAD refs/heads/master
git -C "$M" config user.email t@t; git -C "$M" config user.name t
printf '1\n' > "$M/a"; git -C "$M" add a; git -C "$M" commit -qm c1 >/dev/null 2>&1
printf '2\n' > "$M/a"; git -C "$M" add a; git -C "$M" commit -qm c2 >/dev/null 2>&1
chk "$M";                             ok $? 0 "check: clean master-default repo -> allow (base=master, not root)"

echo "-- hook --"
H=$(mkrepo surface)
push "$H" "ls -la";                   ok $? 0 "hook: non-push command -> allow"
push "$H";                            ok $? 2 "hook: push + surface + no receipt -> BLOCK"
mint "$H" >/dev/null 2>&1
push "$H";                            ok $? 0 "hook: push + fresh receipt -> allow"
printf 'z\n' >> "$H/f.txt"
push "$H" "git push origin HEAD" SKIP_REVIEW_GATE=1
                                      ok $? 0 "hook: SKIP_REVIEW_GATE=1 -> allow (bypass)"
NG=$(mktemp -d)
push "$NG";                           ok $? 0 "hook: push from non-repo cwd -> allow (fail-open)"
push "$H" 'rg "git push" .';          ok $? 0 "hook: literal 'git push' in a search -> allow"
CL=$(mkrepo)
push "$CL";                           ok $? 0 "hook: push + clean repo (no surface) -> allow"

echo "-- hook: push target resolution --"
HC=$(mkrepo surface); A=$(mkrepo)
push "$A" "git -C $HC push origin HEAD";  ok $? 2 "hook: git -C <surface repo> push (cwd clean) -> BLOCK (gates target not cwd)"
push "$HC" "git -c user.name=x push";     ok $? 2 "hook: git -c k=v push (global opt before push) -> detected, BLOCK"
push "$HC" "git help push";               ok $? 0 "hook: git help push (push is an arg) -> allow"
push "$A" "git --git-dir=$HC/.git push";  ok $? 2 "hook: push via --git-dir -> fail-closed BLOCK"
NG2=$(mktemp -d)
push "$A" "git -C $NG2 push";             ok $? 2 "hook: git -C <non-repo> push -> fail-closed BLOCK"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
