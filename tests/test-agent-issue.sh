#!/usr/bin/env bash
# Proves scripts/agent-issue.sh: files a de-duplicated GitHub issue, dedups by
# loc-hash, caps per story, and degrades gracefully (fallback file) when gh is
# unavailable. gh is mocked via a fake on PATH whose behaviour is env-controlled.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${SCRIPT_PATH:-$VG/scripts/agent-issue.sh}"
BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }

# fake gh on PATH (behaviour via FAKE_GH_AUTH / FAKE_GH_LIST / FAKE_GH_CREATE).
FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then [ "${FAKE_GH_AUTH:-ok}" = "ok" ]; exit $?; fi
if [ "$1" = "issue" ]; then
  case "$2" in
    list)   printf '%s' "${FAKE_GH_LIST:-[]}"; exit 0 ;;
    create) if [ "${FAKE_GH_CREATE:-ok}" = "ok" ]; then echo "https://example/issues/99"; exit 0; else echo boom >&2; exit 1; fi ;;
    comment) exit 0 ;;
  esac
fi
[ "$1" = "api" ] && exit 0
exit 0
GH
chmod +x "$FAKEBIN/gh"

mkbody(){ printf '%s\n' "---" "type: bug" "files:" "  - path: src/foo.js" "    lines: 10-20" "---" "a finding"; }

# run <dir> <story> [env...] -- runs agent-issue.sh in <dir> with a valid body.
run(){ local d="$1" story="$2"; shift 2; ( cd "$d" && env PATH="$FAKEBIN:$PATH" "$@" "$BASH_BIN" "$SCRIPT" "a title" "agent-finding" body.md "$story" >/dev/null 2>&1 ); }

# 1. usage: invalid story id
D=$(mktemp -d); mkbody > "$D/body.md"
run "$D" "bad id!";                                   ok $? 1  "invalid story-id -> usage error (1)"

# 2. degrade: gh not authenticated -> fallback (20) + a backlog/pending file
D=$(mktemp -d); mkbody > "$D/body.md"
run "$D" story1 FAKE_GH_AUTH=fail;                    ok $? 20 "gh not authenticated -> fallback (20)"
ls "$D"/backlog/pending/*.md >/dev/null 2>&1;         ok $? 0  "fallback wrote a backlog/pending/*.md"

# 3. validation: missing frontmatter -> fallback (20)
D=$(mktemp -d); printf 'just text\n' > "$D/body.md"
run "$D" story1;                                      ok $? 20 "no frontmatter -> fallback (20)"

# 4. validation: missing type -> fallback (20)
D=$(mktemp -d); printf '%s\n' "---" "sev: high" "---" x > "$D/body.md"
run "$D" story1;                                      ok $? 20 "frontmatter without type -> fallback (20)"

# 5. file new issue: list empty, create ok -> 0, count=1
D=$(mktemp -d); mkbody > "$D/body.md"
run "$D" story1 FAKE_GH_LIST='[]';                    ok $? 0  "fresh finding -> filed (0)"
ok "$(cat "$D/.agent-backlog/session-story1.count" 2>/dev/null)" 1 "count file == 1 after filing"

# 6. dedup: list returns an existing issue -> 10, count NOT written
D=$(mktemp -d); mkbody > "$D/body.md"
run "$D" story1 FAKE_GH_LIST='[{"number":42}]';       ok $? 10 "duplicate loc-hash -> comment on existing (10)"
if [ -f "$D/.agent-backlog/session-story1.count" ]; then r=0; else r=1; fi; ok "$r" 1 "no count file written on duplicate"

# 7. cap: pre-seeded count at MAX -> 30 (before gh)
D=$(mktemp -d); mkbody > "$D/body.md"; mkdir -p "$D/.agent-backlog"; printf '4' > "$D/.agent-backlog/session-story1.count"
run "$D" story1;                                      ok $? 30 "count at cap -> CAP_OVERFLOW (30)"

# 8. meta mode: --meta files + records .meta
D=$(mktemp -d); mkbody > "$D/body.md"
( cd "$D" && env PATH="$FAKEBIN:$PATH" FAKE_GH_LIST='[]' "$BASH_BIN" "$SCRIPT" --meta "t" "agent-finding" body.md story1 >/dev/null 2>&1 )
ok $? 0 "meta mode -> filed (0)"
if [ -f "$D/.agent-backlog/session-story1.meta" ]; then r=0; else r=1; fi; ok "$r" 0 "meta mode wrote the .meta marker"

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
