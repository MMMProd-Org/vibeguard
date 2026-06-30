#!/usr/bin/env bash
# Proves the opt-in worktree pwd-guard: pins a session to its locked worktree.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_PATH:-$VG/hooks/pre-tool-use-pwd-guard.sh}"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }

# run <project_dir> <cwd> : feed empty payload, run hook from <cwd>, return exit.
run(){ local proj="$1" cwd="$2"; ( cd "$cwd" && printf '{}' | env CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" >/dev/null 2>&1 ); }
mklock(){ local proj="$1" pdir="$2"; mkdir -p "$proj/.claude"; jq -nc --arg pd "$pdir" '{lock_id:"t",pid:1,host:"h",started_at:"2026-01-01T00:00:00Z",project_dir:$pd}' > "$proj/.claude/.session-lock.json"; }

P="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$P/src"
run "$P" "$P";                       ok $? 0 "no lock file -> ALLOW (no enforcement)"
mklock "$P" "$P"
run "$P" "$P";                       ok $? 0 "lock + cwd == project_dir -> ALLOW"
run "$P" "$P/src";                   ok $? 0 "lock + cwd is subdir -> ALLOW"

O="$(cd "$(mktemp -d)" && pwd -P)"
run "$P" "$O";                       ok $? 2 "lock + cwd outside worktree -> BLOCK (drift)"

# corrupted locks -> fail-closed
PC="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$PC/.claude"
echo '{ not json' > "$PC/.claude/.session-lock.json"
run "$PC" "$PC";                     ok $? 2 "corrupted JSON lock -> BLOCK (fail-closed)"
mklock "$PC" ""
run "$PC" "$PC";                     ok $? 2 "empty project_dir in lock -> BLOCK (fail-closed)"

# outside any git tree + no CLAUDE_PROJECT_DIR -> no-op ALLOW
NG="$(cd "$(mktemp -d)" && pwd -P)"
( cd "$NG" && printf '{}' | env -u CLAUDE_PROJECT_DIR bash "$HOOK" >/dev/null 2>&1 ); ok $? 0 "outside git + no project dir -> ALLOW"

# canonicalization parity (QODO: non-portable readlink -f): lock project_dir is a
# symlink to the real worktree; cwd at the real dir must still match.
RReal="$(cd "$(mktemp -d)" && pwd -P)"
SLBASE="$(cd "$(mktemp -d)" && pwd -P)"; ln -s "$RReal" "$SLBASE/link"
mklock "$RReal" "$SLBASE/link"
run "$RReal" "$RReal";               ok $? 0 "lock project_dir via symlink, cwd real -> ALLOW (canonicalized)"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
