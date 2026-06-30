#!/usr/bin/env bash
# Proves the opt-in draft-mode gate: `gh pr create` needs --draft, `gh pr ready` needs
# PR_READY_ACK=1; everything else (other gh verbs, literal mentions) is allowed;
# fail-closed on missing jq.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-draft-mode.sh}"
BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }
feed(){ local cmd="$1"; shift; printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" | env "$@" "$BASH_BIN" "$HOOK" >/dev/null 2>&1; }

feed "ls -la";                                ok $? 0 "non-gh command -> allow"
feed "gh pr view 5";                          ok $? 0 "other gh verb (pr view) -> allow"
feed 'rg "gh pr create" .';                       ok $? 0 "literal mention in a search -> allow"

feed "gh pr create -t title -b body";            ok $? 2 "gh pr create without --draft -> BLOCK"
feed "gh pr create --draft -t title";            ok $? 0 "gh pr create --draft -> allow"
feed "sudo gh pr create -t t";                   ok $? 2 "wrapper sudo gh pr create no --draft -> BLOCK"
feed "FOO=1 gh pr create -t t";                  ok $? 2 "env-prefix gh pr create no --draft -> BLOCK"
feed "echo hi; gh pr create -t t";               ok $? 2 "multi-cmd gh pr create no --draft -> BLOCK"
feed "echo hi && gh pr create --draft";          ok $? 0 "multi-cmd gh pr create --draft -> allow"

feed "gh pr ready 5";                          ok $? 2 "gh pr ready without ACK -> BLOCK"
feed "PR_READY_ACK=1 gh pr ready 5";           ok $? 0 "gh pr ready with PR_READY_ACK=1 -> allow"
feed "gh pr ready 5 --undo";                   ok $? 0 "gh pr ready --undo (back to draft) -> allow"

# newline is a real separator: a create on a later line must still be inspected.
feed "$(printf 'echo prep\ngh pr create -t t')";   ok $? 2 "newline-separated gh pr create no --draft -> BLOCK"
feed "$(printf 'echo prep\ngh pr create --draft')"; ok $? 0 "newline-separated gh pr create --draft -> allow"
# a flag inside a trailing comment is not a real flag bash passes.
feed "gh pr create -t t # --draft";              ok $? 2 "--draft only in a comment -> BLOCK"
feed "gh pr create --draft # ready note";        ok $? 0 "real --draft + trailing comment -> allow"

feed "gh pr create -t t" PATH="/nonexistent";    ok $? 2 "jq absent -> BLOCK (fail-closed)"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
