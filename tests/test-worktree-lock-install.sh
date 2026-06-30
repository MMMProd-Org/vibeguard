#!/usr/bin/env bash
# Proves the opt-in --with-worktree-lock install wiring: ordering invariant,
# SessionStart shape, Codex exclusion, self-heal, co-location safety, idempotence.
set -uo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS $3"; else FAIL=$((FAIL+1)); echo "  FAIL $3 (got $1 want $2)"; fi; }
mkrepo(){ local r; r="$(cd "$(mktemp -d)" && pwd -P)"; git init -q "$r"; printf '%s' "$r"; }
bash_order(){ jq -r '[.hooks.PreToolUse[]|select(.matcher=="Bash").hooks[].command|capture("hooks/(?<n>[^\"]+)").n]|join(",")' "$1/.claude/settings.json"; }

# fresh install with lock: pwd-guard FIRST, session-start as matcher-less SessionStart
R=$(mkrepo); bash "$VG/install.sh" --with-worktree-lock "$R" >/dev/null 2>&1
case "$(bash_order "$R")" in pre-tool-use-pwd-guard.sh,*) ok 0 0 "fresh: pwd-guard first in Bash";; *) ok 1 0 "fresh order: $(bash_order "$R")";; esac
ok "$(jq -r '.hooks.SessionStart[0]|has("matcher")' "$R/.claude/settings.json")" "false" "SessionStart entry has no matcher"
ok "$(jq -r '.hooks.SessionStart[0].hooks[0].command|capture("hooks/(?<n>[^\"]+)").n' "$R/.claude/settings.json")" "session-start.sh" "SessionStart wires session-start.sh"
ok "$(jq -r '[.hooks|to_entries[].value[]?.hooks[]?.command]|map(select(test("pwd-guard|session-start")))|length' "$R/.codex/hooks.json")" "0" "Codex gets NO lock hooks (Claude-only)"

# core-only install does NOT wire the lock
R2=$(mkrepo); bash "$VG/install.sh" "$R2" >/dev/null 2>&1
ok "$(jq -r '.hooks.SessionStart // "none"' "$R2/.claude/settings.json")" "none" "no flag -> no SessionStart"
case "$(bash_order "$R2")" in *pwd-guard*) ok 1 0 "no flag should not wire pwd-guard";; *) ok 0 0 "no flag -> no pwd-guard";; esac

# upgrade: core first, then add lock -> pwd-guard still first
R3=$(mkrepo); bash "$VG/install.sh" "$R3" >/dev/null 2>&1; bash "$VG/install.sh" --with-worktree-lock "$R3" >/dev/null 2>&1
case "$(bash_order "$R3")" in pre-tool-use-pwd-guard.sh,*) ok 0 0 "upgrade: pwd-guard first";; *) ok 1 0 "upgrade order: $(bash_order "$R3")";; esac

# self-heal: manually move pwd-guard last, re-run -> back to first
python3 - "$R3/.claude/settings.json" <<'PY'
import json,sys
f=sys.argv[1]; d=json.load(open(f)); pre=d["hooks"]["PreToolUse"]
bash=[e for e in pre if e.get("matcher")=="Bash"]; other=[e for e in pre if e.get("matcher")!="Bash"]
pg=[e for e in bash if "pwd-guard" in e["hooks"][0]["command"]]; rest=[e for e in bash if "pwd-guard" not in e["hooks"][0]["command"]]
d["hooks"]["PreToolUse"]=other+rest+pg; json.dump(d,open(f,"w"))
PY
bash "$VG/install.sh" --with-worktree-lock "$R3" >/dev/null 2>&1
case "$(bash_order "$R3")" in pre-tool-use-pwd-guard.sh,*) ok 0 0 "self-heal: misordered -> pwd-guard first again";; *) ok 1 0 "self-heal order: $(bash_order "$R3")";; esac

# co-location safety: graft a user hook beside pwd-guard, re-run -> user hook kept
python3 - "$R3/.claude/settings.json" <<'PY'
import json,sys
f=sys.argv[1]; d=json.load(open(f))
for e in d["hooks"]["PreToolUse"]:
    if e.get("matcher")=="Bash" and "pwd-guard" in e["hooks"][0]["command"]:
        e["hooks"].append({"type":"command","command":"echo USERHOOK"})
json.dump(d,open(f,"w"))
PY
bash "$VG/install.sh" --with-worktree-lock "$R3" >/dev/null 2>&1
grep -q USERHOOK "$R3/.claude/settings.json" && ok 0 0 "co-located user hook preserved (never clobbers)" || ok 1 0 "co-located user hook clobbered"

# idempotence (cmp -s is POSIX; md5sum is absent on stock macOS)
cp "$R/.claude/settings.json" "$R/.snap"
bash "$VG/install.sh" --with-worktree-lock "$R" >/dev/null 2>&1
if cmp -s "$R/.snap" "$R/.claude/settings.json"; then ok 0 0 "re-run is idempotent (no settings change)"; else ok 1 0 "re-run is idempotent (no settings change)"; fi

echo ""; echo "=== RESULTS: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
