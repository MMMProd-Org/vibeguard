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
  # Repo FIRST: honor -R/--repo owner/repo (incl. the glued -Rowner/repo form),
  # else the current repo. Parsing it first lets the PR scan skip the repo value
  # and the PR fallback query the right repo.
  REPO=$(printf '%s' "$CMD" | grep -oE '(-R|--repo)[=[:space:]]?[^[:space:]]+/[^[:space:]]+' | head -1 | sed -E 's/^(-R|--repo)[=[:space:]]?//' || true)
  [ -n "$REPO" ] || REPO=$(gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null || echo "")
  [ -n "$REPO" ] || exit 0                                      # no repo -> allow
  OWNER=${REPO%%/*}; NAME=${REPO##*/}
  # PR number, derived ONLY from the tail after `gh pr merge` (so a number or a
  # pull/N inside a -t/-b subject elsewhere is not picked up). First the leading
  # positional numeric token (skipping flags and the owner/repo value), then a
  # /pull/N url in that same tail, then gh pr view.
  after=$(printf '%s' "$CMD" | sed -E 's/^.*gh pr merge[[:space:]]*//')
  PR=""; BRANCH=""
  # shellcheck disable=SC2086  # intentional word-split to tokenize the command
  for tok in $after; do
    case "$tok" in -*) continue ;; */*) continue ;; *[!0-9]*) BRANCH="$tok"; break ;; *) PR="$tok"; break ;; esac
  done
  [ -n "$PR" ] || PR=$(printf '%s' "$after" | grep -oE 'pull/[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  # A positional branch name (by-branch, not by-number) resolves to ITS PR, not
  # the current branch's -- else the gate checks the wrong PR's threads (false-neg).
  # ponytail: slash-free names only; a team/branch form is skipped as an owner/repo
  # token above and falls through to the current-branch lookup (rare, acceptable).
  if [ -z "$PR" ] && [ -n "$BRANCH" ]; then
    PR=$(gh pr view "$BRANCH" -R "$REPO" --json number -q '.number' 2>/dev/null || echo "")
  fi
  [ -n "$PR" ] || PR=$(gh pr view -R "$REPO" --json number -q '.number' 2>/dev/null || echo "")
  [ -n "$PR" ] || exit 0                                        # no PR -> allow
  # Fetch ALL review threads. gh --paginate auto-follows $endCursor (GraphQL caps
  # page size at 100), so PRs with >100 threads are not silently truncated.
  RAW=$(gh api graphql --paginate -f owner="$OWNER" -f repo="$NAME" -F pr="$PR" -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100, after:$endCursor){
            pageInfo{ hasNextPage endCursor }
            nodes{ isResolved comments(first:1){ nodes{ author{ login } } } } }
        } } }' 2>/dev/null) || exit 0                           # gh/API failure -> allow
  LIST=$(printf '%s' "$RAW" | jq -cs '[.[].data.repository.pullRequest.reviewThreads.nodes[]? | {resolved:.isResolved, author:(.comments.nodes[0].author.login // "")}]' 2>/dev/null || echo "[]")
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
