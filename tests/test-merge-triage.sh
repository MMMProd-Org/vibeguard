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

# gh path (no network): a fake gh that always fails -> fail-open everywhere.
FAKEBIN=$(mktemp -d); printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/gh"; chmod +x "$FAKEBIN/gh"
feed "gh pr merge" PATH="$FAKEBIN:$PATH";        ok $? 0 "merge w/o PR number + gh failing -> fail-open (not exit 1)"
feed "gh pr merge 9" PATH="$FAKEBIN:$PATH";      ok $? 0 "merge + gh repo/api failing -> fail-open allow"

# PR parsing (QODO: wrong-pr / repo-override). Fake gh logs its args, then fails
# (hook fail-opens after). With -R the repo comes from the command, so the gate
# reaches the graphql call and we can assert the PR/repo it queried.
GHLOG=$(mktemp); FB=$(mktemp -d)
printf '#!/bin/sh\necho "$@" >> "%s"\nexit 1\n' "$GHLOG" > "$FB/gh"; chmod +x "$FB/gh"
feed "gh pr merge 42 -R owner/repo -t 'fix 99'" PATH="$FB:$PATH" >/dev/null 2>&1
grep -q 'pr=42' "$GHLOG"  && ok 0 0 "parses PR 42 after merge (not the 99 in -t)" || ok 1 0 "PR parse: $(cat "$GHLOG")"
grep -q 'pr=99' "$GHLOG"  && ok 1 0 "must NOT use 99 as PR" || ok 0 0 "ignores 99 from subject"
grep -q 'repo=repo' "$GHLOG" && ok 0 0 "honors -R owner/repo override" || ok 1 0 "repo override: $(cat "$GHLOG")"

# flags reordered: -R owner/repo BEFORE the PR number must still parse PR 42
: > "$GHLOG"
feed "gh pr merge -R owner/repo 42" PATH="$FB:$PATH" >/dev/null 2>&1
grep -q 'pr=42' "$GHLOG" && ok 0 0 "PR after -R owner/repo still parsed (not stopped on '/')" || ok 1 0 "reordered: $(cat "$GHLOG")"

# a pull/N inside a -t subject must NOT be picked up as the PR
: > "$GHLOG"
feed "gh pr merge -R owner/repo 42 -t 'see pull/99'" PATH="$FB:$PATH" >/dev/null 2>&1
grep -q 'pr=42' "$GHLOG" && ok 0 0 "subject pull/99 ignored, positional 42 used" || ok 1 0 "subj: $(cat "$GHLOG")"
# a real /pull/N url (no positional) is used
: > "$GHLOG"
feed "gh pr merge -R owner/repo https://github.com/owner/repo/pull/7" PATH="$FB:$PATH" >/dev/null 2>&1
grep -q 'pr=7' "$GHLOG" && ok 0 0 "pull/N url parsed as PR" || ok 1 0 "url: $(cat "$GHLOG")"


# branch-name positional: `gh pr merge feature-x` must resolve feature-x's OWN pr,
# not the current branch's (else the gate checks the wrong PR -> false-negative).
GBR=$(mktemp); FBR=$(mktemp -d)
printf '#!/bin/sh\ncase "$*" in\n*"pr view feature-x"*) echo 50 ;;\n*"pr view"*) echo 77 ;;\n*"api graphql"*) echo "$@" >> "%s"; exit 1 ;;\n*) exit 1 ;;\nesac\n' "$GBR" > "$FBR/gh"; chmod +x "$FBR/gh"
feed "gh pr merge feature-x -R owner/repo" PATH="$FBR:$PATH" >/dev/null 2>&1
grep -q 'pr=50' "$GBR" && ok 0 0 "branch-name merge resolves ITS pr (50)" || ok 1 0 "branch resolve: $(cat "$GBR")"
grep -q 'pr=77' "$GBR" && ok 1 0 "branch merge must NOT use current-branch pr (77)" || ok 0 0 "ignores wrong current-branch pr on branch merge"
: > "$GBR"
feed "gh pr merge -R owner/repo" PATH="$FBR:$PATH" >/dev/null 2>&1
grep -q 'pr=77' "$GBR" && ok 0 0 "no positional still uses current-branch pr (77)" || ok 1 0 "no-arg regression: $(cat "$GBR")"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
