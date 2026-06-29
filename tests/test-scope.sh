#!/usr/bin/env bash
# Proves P0-3 anti-brick + preserved enforcement for the OPT-IN scope hook.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-scope.sh}"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }
feed(){ local proj="$1" fp="$2"; shift 2
  printf '%s' "$(jq -nc --arg p "$fp" '{tool_name:"Write",tool_input:{file_path:$p}}')" \
    | env "$@" CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1; }

P="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$P/src"
feed "$P" "$P/foo.txt";          ok $? 0 "no-scope + inside project -> ALLOW (anti-brick)"
feed "$P" "/tmp/vg-outside-$$.t"; ok $? 2 "no-scope + outside project -> BLOCK (protection kept)"
feed "$P" "$P/x.txt" VIBEGUARD_SCOPE_STRICT=1; ok $? 2 "STRICT=1 + no-scope -> BLOCK (fail-closed restored)"

PS="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$PS/src" "$PS/other"
echo '{"scopePaths":["src/"]}' > "$PS/.session-scope.json"
feed "$PS" "$PS/src/a.ts";   ok $? 0 "scope[src/] + write src/ -> ALLOW"
feed "$PS" "$PS/other/b.ts"; ok $? 2 "scope[src/] + write other/ -> BLOCK (enforced)"

# B2-portable symlink-escape canonicalization (regression for QODO #1: macOS readlink -f)
SL="$(cd "$(mktemp -d)" && pwd -P)"; OUT="$(cd "$(mktemp -d)" && pwd -P)"
ln -s "$OUT" "$SL/escape"                                 # symlink dir inside project -> outside
feed "$SL" "$SL/escape/evil.txt"; ok $? 2 "symlink parent -> outside project -> BLOCK (canonicalized)"
touch "$SL/real.txt"; ln -s "$SL/real.txt" "$SL/inside"   # symlink inside project -> inside
feed "$SL" "$SL/inside";          ok $? 0 "symlink -> inside project -> ALLOW (canonicalized)"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
