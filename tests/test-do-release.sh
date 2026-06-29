#!/usr/bin/env bash
# do-release arg-validation smoke (no real git/gh ops; bad input dies before fetch).
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
S="$VG/scripts/do-release.sh"
PASS=0; FAIL=0
nz(){ if [ "$1" -ne 0 ]; then PASS=$((PASS+1)); echo "  PASS $2 (exit $1)"; else FAIL=$((FAIL+1)); echo "  FAIL $2 (expected non-zero, got 0)"; fi; }
echo "=== do-release smoke ==="
bash "$S" >/dev/null 2>&1;            nz $? "missing version -> non-zero"
bash "$S" notaversion >/dev/null 2>&1; nz $? "invalid version -> non-zero"
bash "$S" 1.2.3 >/dev/null 2>&1;       nz $? "version without v-prefix -> non-zero"
echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
