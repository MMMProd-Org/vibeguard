#!/usr/bin/env bash
set -uo pipefail
#
# vibeguard pre-tool-use-merge-ack.sh - opt-in PR merge-ack gate.
#
# OPT-IN (install.sh --with-merge-ack). PreToolUse:Bash. On a gh pr merge attempt,
# DELEGATES to its sibling check-merge-ack.sh --verify: block (exit 2) only when the
# PR has bot review threads AND no fresh ack (<=TTL) whose hash matches them.
# Otherwise allow. Fail-OPEN: not a merge, SKIP, no jq/gh, unresolved PR, checker
# absent, or any checker exit != 2 -> allow. Seatbelt, not a vault.
#   bypass: VIBEGUARD_SKIP_MERGE_ACK=1 ; mint ack: check-merge-ack.sh <PR>

PAYLOAD=""; [ -t 0 ] || PAYLOAD=$(cat 2>/dev/null || true)
[ "${VIBEGUARD_SKIP_MERGE_ACK:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL" = "Bash" ] || exit 0
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0
_sub=$(printf '%s' "$CMD" | awk '{
  i=1
  while ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
  while ($i=="sudo"||$i=="env"||$i=="command"||$i=="nohup"||$i=="nice") i++
  if ($i!="gh" && $i !~ /\/gh$/) { print ""; exit }
  i++
  while ($i ~ /^-/) i++
  print $i" "$(i+1)
}')
case "$_sub" in "pr merge") : ;; *) exit 0 ;; esac
[ -n "${VIBEGUARD_ACK_THREADS_JSON:-}" ] || command -v gh >/dev/null 2>&1 || exit 0

REPO=$(printf '%s' "$CMD" | grep -oE '(-R|--repo)[=[:space:]]?[^[:space:]]+/[^[:space:]]+' | head -1 | sed -E 's/^(-R|--repo)[=[:space:]]?//' || true)
after=$(printf '%s' "$CMD" | sed -E 's/^.*pr merge[[:space:]]*//')
PR=""; BRANCH=""; skip_next=0
# shellcheck disable=SC2086
for tok in $after; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$tok" in
    -b|--body|-F|--body-file|--author-email|--match-head-commit|-R|--repo|-t|--subject|--merge-method) skip_next=1; continue ;;
    -*) continue ;;
    */*) continue ;;
    *[!0-9]*) BRANCH="$tok"; break ;;
    *) PR="$tok"; break ;;
  esac
done
[ -n "$PR" ] || PR=$(printf '%s' "$after" | grep -oE 'pull/[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
if [ -z "$PR" ] && [ -n "$BRANCH" ] && command -v gh >/dev/null 2>&1; then
  PR=$(gh pr view "$BRANCH" ${REPO:+-R "$REPO"} --json number -q '.number' 2>/dev/null || echo "")
fi
[ -n "$PR" ] || PR=$(gh pr view ${REPO:+-R "$REPO"} --json number -q '.number' 2>/dev/null || echo "")
[ -n "$PR" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HOOK_DIR/check-merge-ack.sh"
[ -e "$CHECK" ] || exit 0
rc=0; bash "$CHECK" --verify "$PR" ${REPO:+-R "$REPO"} </dev/null >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then
  echo "BLOCKED: PR #$PR has bot review thread(s) not covered by a fresh triage ack." >&2
  echo "Triage the bot feedback, then mint the ack:" >&2
  echo "  bash \"$CHECK\" $PR" >&2
  echo "Re-run the merge after. Bypass (audit-visible): VIBEGUARD_SKIP_MERGE_ACK=1 <merge cmd>" >&2
  exit 2
fi
exit 0
