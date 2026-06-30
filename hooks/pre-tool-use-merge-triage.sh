#!/usr/bin/env bash
set -euo pipefail
#
# vibeguard pre-tool-use-merge-triage.sh - opt-in PR merge-triage gate.
#
# OPT-IN (install.sh --with-merge-triage). PreToolUse:Bash. Blocks a PR merge
# attempt when the PR still has UNRESOLVED review threads opened by a review bot,
# so a bot's feedback is not merged past unseen. Resolve the conversation(s) on
# GitHub (after triaging), then re-run.
#
# Fail-OPEN by design (advisory, vibe-coder friendly): missing jq/gh, a gh/API
# failure, an unresolvable PR/repo, or no bot threads -> ALLOW. Never bricks.
#   - bypass:    VIBEGUARD_SKIP_TRIAGE=1
#   - bot regex: VIBEGUARD_BOT_PATTERN (default below)
#   - test hook: VIBEGUARD_TRIAGE_THREADS_JSON = compact [{"resolved":bool,"author":str}]

PAYLOAD=""
[ -t 0 ] || PAYLOAD=$(cat 2>/dev/null || true)

[ "${VIBEGUARD_SKIP_TRIAGE:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0   # advisory gate: no jq -> allow

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL" = "Bash" ] || exit 0
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

# Only act on a PR merge attempt.
case "$CMD" in
  *"gh pr merge"*) : ;;
  *) exit 0 ;;
esac

BOT_PATTERN="${VIBEGUARD_BOT_PATTERN:-coderabbit|qodo|copilot|sourcery|vercel|cursor|greptile|github-code-quality}"

# Obtain the review-thread list as compact [{resolved,author}].
if [ -n "${VIBEGUARD_TRIAGE_THREADS_JSON:-}" ]; then
  LIST="$VIBEGUARD_TRIAGE_THREADS_JSON"
else
  command -v gh >/dev/null 2>&1 || exit 0                       # gh absent -> allow
  PR=$(printf '%s' "$CMD" | grep -oE '[0-9]+' | head -1)
  [ -n "$PR" ] || PR=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")
  [ -n "$PR" ] || exit 0                                        # no PR -> allow
  REPO=$(gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null || echo "")
  [ -n "$REPO" ] || exit 0                                      # no repo -> allow
  OWNER=${REPO%%/*}; NAME=${REPO##*/}
  RAW=$(gh api graphql -f owner="$OWNER" -f repo="$NAME" -F pr="$PR" -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100){ nodes{ isResolved comments(first:1){ nodes{ author{ login } } } } }
        } } }' 2>/dev/null) || exit 0                           # gh/API failure -> allow
  LIST=$(printf '%s' "$RAW" | jq -c '[.data.repository.pullRequest.reviewThreads.nodes[]? | {resolved:.isResolved, author:(.comments.nodes[0].author.login // "")}]' 2>/dev/null || echo "[]")
fi

UNRESOLVED=$(printf '%s' "$LIST" | jq -r --arg re "$BOT_PATTERN" '[.[] | select(.resolved==false) | select((.author//"")|test($re;"i"))] | length' 2>/dev/null || echo 0)
case "$UNRESOLVED" in ''|*[!0-9]*) UNRESOLVED=0 ;; esac

if [ "$UNRESOLVED" -gt 0 ]; then
  echo "BLOCKED: PR has ${UNRESOLVED} unresolved bot review thread(s)." >&2
  echo "A review bot left feedback that is not resolved yet. Triage it, resolve the" >&2
  echo "conversation(s) on GitHub, then re-run the merge." >&2
  echo "Bypass (audit-visible): VIBEGUARD_SKIP_TRIAGE=1 <your merge command>" >&2
  exit 2
fi
exit 0
