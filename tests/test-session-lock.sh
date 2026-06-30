#!/usr/bin/env bash
# Proves the opt-in SessionStart worktree-lock acquisition + stale handling.
# Every run pins CLAUDE_PROJECT_DIR to the throwaway repo so the hook can never
# touch the real project's lock.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_PATH:-$VG/hooks/session-start.sh}"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }

HOST=$(hostname 2>/dev/null || echo unknown)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD="2020-01-01T00:00:00Z"

mkrepo(){ local r; r="$(cd "$(mktemp -d)" && pwd -P)"; git init -q "$r"; printf '%s' "$r"; }
run(){ local repo="$1"; ( cd "$repo" && printf '{}' | env CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" >/dev/null 2>&1 ); }
writelock(){ local repo="$1" pid="$2" host="$3" started="$4"; mkdir -p "$repo/.claude"
  printf '{"lock_id":"t","pid":%s,"host":"%s","started_at":"%s","project_dir":"%s"}' "$pid" "$host" "$started" "$repo" > "$repo/.claude/.session-lock.json"; }

# 1. fresh repo, no lock -> acquire, exit 0, lock written
R1=$(mkrepo)
run "$R1"; ok $? 0 "fresh worktree -> acquire lock (ALLOW)"
[ -f "$R1/.claude/.session-lock.json" ] && ok 0 0 "lock file created" || ok 1 0 "lock file created"
ok "$(jq -r '.project_dir' "$R1/.claude/.session-lock.json")" "$R1" "lock project_dir == worktree"
lid=$(jq -r '.lock_id' "$R1/.claude/.session-lock.json")
case "$lid" in [0-9]*:*:[0-9]*) ok 0 0 "lock_id format pid:host:epoch";; *) ok 1 0 "lock_id format: $lid";; esac

# 1b. lock pid must be the hook's PPID (the live session), NOT the ephemeral hook $$.
#     Direct invocation (no pipe/subshell) so the hook's PPID == this test's $$.
RP=$(mkrepo)
# session-start resolves the worktree from CLAUDE_PROJECT_DIR, so no cd is needed;
# a direct (non-subshell) invocation makes the hook's PPID == this test's $$.
env CLAUDE_PROJECT_DIR="$RP" bash "$HOOK" </dev/null >/dev/null 2>&1
ok "$(jq -r '.pid' "$RP/.claude/.session-lock.json")" "$$" "lock pid == hook PPID (session proc, not dead hook pid)"

# 2. live lock owned by another (this test's pid, alive) -> BLOCK
R2=$(mkrepo); writelock "$R2" "$$" "$HOST" "$NOW"
run "$R2"; ok $? 2 "live lock (alive pid + host match) -> BLOCK"

# 3. stale by age (started long ago) -> overwrite -> ALLOW
R3=$(mkrepo); writelock "$R3" "$$" "$HOST" "$OLD"
run "$R3"; ok $? 0 "stale by age -> overwrite (ALLOW)"

# 4. stale by dead pid (host match) -> overwrite -> ALLOW
R4=$(mkrepo); writelock "$R4" "999999" "$HOST" "$NOW"
run "$R4"; ok $? 0 "stale by dead pid -> overwrite (ALLOW)"

# 5. host mismatch -> treated stale -> overwrite -> ALLOW
R5=$(mkrepo); writelock "$R5" "$$" "nohost-xyz-$$" "$NOW"
run "$R5"; ok $? 0 "host mismatch -> overwrite (ALLOW)"

# 6. corrupted JSON -> fail-closed BLOCK
R6=$(mkrepo); mkdir -p "$R6/.claude"; echo '{ not json' > "$R6/.claude/.session-lock.json"
run "$R6"; ok $? 2 "corrupted JSON lock -> BLOCK"

# 7. non-numeric pid -> fail-closed BLOCK
R7=$(mkrepo); mkdir -p "$R7/.claude"
printf '{"lock_id":"t","pid":"abc","host":"%s","started_at":"%s","project_dir":"%s"}' "$HOST" "$NOW" "$R7" > "$R7/.claude/.session-lock.json"
run "$R7"; ok $? 2 "non-numeric pid -> BLOCK (no fail-open bypass)"

# 8. outside any git tree AND no CLAUDE_PROJECT_DIR -> no-op ALLOW, no lock written
NG="$(cd "$(mktemp -d)" && pwd -P)"
( cd "$NG" && printf '{}' | env -u CLAUDE_PROJECT_DIR bash "$HOOK" >/dev/null 2>&1 ); ok $? 0 "outside git + no project dir -> no-op (ALLOW)"
[ -f "$NG/.claude/.session-lock.json" ] && ok 1 0 "no lock outside git" || ok 0 0 "no lock outside git"

# 9. non-integer TTL override -> fail-closed BLOCK
RT=$(mkrepo)
( cd "$RT" && printf '{}' | env CLAUDE_PROJECT_DIR="$RT" WORKTREE_SESSION_LOCK_TTL_SECONDS=abc bash "$HOOK" >/dev/null 2>&1 ); ok $? 2 "non-integer TTL -> BLOCK (fail-closed)"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
