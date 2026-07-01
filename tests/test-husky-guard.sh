#!/usr/bin/env bash
# Proves the opt-in husky-guard: blocks a push when the repo has .husky/ but
# .husky/pre-push is missing; allows a repo without husky, one with pre-push, and
# non-push / literal-mention commands; checks the pushing worktree's own root;
# fail-OPEN on jq-absent.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-husky-guard.sh}"
BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }
feed(){ local cmd="$1"; shift; env "$@" "$BASH_BIN" "$HOOK" >/dev/null 2>&1 <<<"$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"; }
feed_cwd(){ local dir="$1" cmd="$2"; printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" | ( cd "$dir" && "$BASH_BIN" "$HOOK" >/dev/null 2>&1 ); }
mkrepo(){ local d; d=$(mktemp -d); git init -q "$d"; printf '%s' "$d"; }

NOHUSKY=$(mkrepo)
OKREPO=$(mkrepo);  mkdir -p "$OKREPO/.husky";  : > "$OKREPO/.husky/pre-push"
BADREPO=$(mkrepo); mkdir -p "$BADREPO/.husky"   # husky present, pre-push MISSING

feed "ls -la";                              ok $? 0 "non-git command -> allow"
feed "";                                    ok $? 0 "empty command -> allow"
feed_cwd "$NOHUSKY" "git push";               ok $? 0 "push, repo without husky -> allow"
feed_cwd "$OKREPO" "git push";                ok $? 0 "push, .husky/pre-push present -> allow"
feed_cwd "$BADREPO" "git push";               ok $? 2 "push, .husky but pre-push missing -> BLOCK"

feed "git -C $BADREPO push";                ok $? 2 "git -C <repo missing pre-push> push -> BLOCK"
feed "git -C $OKREPO push";                 ok $? 0 "git -C <repo with pre-push> push -> allow"
feed "git -C \"$BADREPO\" push";            ok $? 2 "quoted -C <repo missing pre-push> -> BLOCK (dequoted)"

feed_cwd "$BADREPO" "git help push";        ok $? 0 "git help push (push is an arg) -> allow"
feed_cwd "$BADREPO" 'rg \"git push\" .';      ok $? 0 "literal push mention in a search -> allow"
feed_cwd "$BADREPO" "echo prep && git push";  ok $? 2 "multi-cmd real push in bad repo -> BLOCK"
feed_cwd "$BADREPO" "echo git push";           ok $? 0 "literal echo git-push (git not in cmd position) -> allow"

# a push from a linked WORKTREE is judged by the WORKTREE's own checkout.
PRIMARY=$(mkrepo)
git -C "$PRIMARY" config user.email t@t; git -C "$PRIMARY" config user.name t
printf x > "$PRIMARY/f"; git -C "$PRIMARY" add f; git -C "$PRIMARY" commit -qm base >/dev/null 2>&1
WT2="${PRIMARY}-wt"; git -C "$PRIMARY" worktree add -q "$WT2" >/dev/null 2>&1
mkdir -p "$WT2/.husky"   # husky present IN THE WORKTREE, pre-push missing
feed_cwd "$WT2" "git push";                   ok $? 2 "push from a worktree, worktree missing pre-push -> BLOCK"
: > "$WT2/.husky/pre-push"
feed_cwd "$WT2" "git push";                   ok $? 0 "push from a worktree, worktree has pre-push -> allow"
mkdir -p "$PRIMARY/.husky"   # primary has husky, no pre-push
WT3="${PRIMARY}-wt3"; git -C "$PRIMARY" worktree add -q "$WT3" >/dev/null 2>&1
feed_cwd "$WT3" "git push";                   ok $? 0 "worktree without husky -> allow (primary bad .husky irrelevant)"

feed "git -C $BADREPO push" PATH="/nonexistent";  ok $? 0 "jq absent -> allow (fail-open)"

# fail-open contract: --git-dir/--work-tree targeting + ambiguous quoting must NOT
# block, even in a husky repo missing pre-push.
feed_cwd "$BADREPO" "git --git-dir=$BADREPO/.git push";  ok $? 0 "--git-dir push in bad repo -> allow (fail-open)"
feed_cwd "$BADREPO" "git --work-tree=$BADREPO push";     ok $? 0 "--work-tree push in bad repo -> allow (fail-open)"
feed "git -C \"oops push";                              ok $? 0 "ambiguous unclosed-quote -C -> allow (fail-open)"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
