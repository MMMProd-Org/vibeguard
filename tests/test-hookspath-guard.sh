#!/usr/bin/env bash
# Proves the opt-in hookspath-guard: blocks `git push` only when the target
# repo's live LOCAL core.hooksPath is redirected off a husky-safe value; allows
# otherwise (incl. a legit GLOBAL hooksPath); fail-closed on missing jq.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-hookspath-guard.sh}"
BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }
# feed <command> [env...] : run hook with a Bash payload, return exit code.
# Uses an absolute bash path so a PATH override (jq-absent case) still starts bash.
feed(){ local cmd="$1"; shift; printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" | env "$@" "$BASH_BIN" "$HOOK" >/dev/null 2>&1; }

mkrepo(){ local d; d=$(mktemp -d); git init -q "$d"; printf '%s' "$d"; }
R=$(mkrepo)

feed "ls -la";                                   ok $? 0 "non-git command -> allow"
feed "git -C $R status";                         ok $? 0 "git non-push -> allow"
feed "";                                         ok $? 0 "empty command -> allow"

feed "git -C $R push";                           ok $? 0 "push + local hooksPath unset -> allow"

git -C "$R" config core.hooksPath ".husky"
feed "git -C $R push origin main";               ok $? 0 "push + hooksPath=.husky -> allow"

git -C "$R" config core.hooksPath ".husky/_"
feed "git -C $R push";                           ok $? 0 "push + hooksPath=.husky/_ -> allow"

git -C "$R" config core.hooksPath "/tmp/evil-no-hooks"
feed "git -C $R push";                           ok $? 2 "push + local hooksPath=/tmp/evil -> BLOCK"

git -C "$R" config core.hooksPath ".husky/../tmp/no-hooks"
feed "git -C $R push";                           ok $? 2 "push + traversal (.husky/..) -> BLOCK"

# Regression: a legit GLOBAL hooksPath (no LOCAL one) must NOT false-positive.
R2=$(mkrepo)
GCFG=$(mktemp)
git config --file "$GCFG" core.hooksPath "/home/dev/.git-templates/hooks"
feed "git -C $R2 push" GIT_CONFIG_GLOBAL="$GCFG";  ok $? 0 "global hooksPath, no local -> allow (no false-positive)"

# quoted -C path must dequote and resolve (else a quoted -C silently bypassed).
git -C "$R" config core.hooksPath "/tmp/evil-no-hooks"
feed "git -C '$R' push";                        ok $? 2 "quoted -C + redirected hooksPath -> BLOCK (dequoted)"
git -C "$R" config core.hooksPath ".husky"
feed "git -C \"$R\" push";                       ok $? 0 "double-quoted -C + safe hooksPath -> allow (dequoted)"

# non-git target -> graceful allow
NG=$(mktemp -d)
feed "git -C $NG push";                          ok $? 0 "push targeting non-git dir -> allow (no-op)"

# fail-closed: jq absent -> BLOCK (mirrors danger.sh)
feed "git -C $R push" PATH="/nonexistent";       ok $? 2 "jq absent -> BLOCK (fail-closed)"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
