#!/usr/bin/env bash
set -uo pipefail
#
# vibeguard scripts/merge-state.sh - read-only PR merge-state dump (helper, not a hook).
#
# Prints a stable JSON snapshot of a PR's merge readiness on stdout:
#   { pr, title, head, base, mergeable, merge_state, review_decision,
#     ci:{pass,fail,pending}, unresolved_bot_threads }
# It NEVER blocks, mutates, or merges anything -- it only reads via `gh`.
#
#   merge-state.sh <PR> [-R owner/repo]
#
# owner/repo comes from `gh` (or -R); no hardcoded default. Errors (missing gh/jq,
# unresolvable repo, `gh pr view` failure, bad PR arg) print to stderr + exit != 0.
# A review-thread fetch failure is fail-soft: unresolved_bot_threads=null, dump still emitted.
#
#   bot regex: VIBEGUARD_BOT_PATTERN (default below)

BOT_PATTERN="${VIBEGUARD_BOT_PATTERN:-coderabbit|qodo|copilot|sourcery|vercel|cursor|greptile|github-code-quality}"

usage(){ echo "usage: $0 <PR> [-R owner/repo]" >&2; }

# ---- args: a positional numeric PR + optional -R/--repo owner/repo ----
PR=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo)
      REPO="${2:-}"
      case "$REPO" in ''|-*) echo "merge-state: $1 requires an owner/repo value." >&2; exit 1 ;; esac
      shift 2 ;;
    -R*)       REPO="${1#-R}"; REPO="${REPO#=}"; shift ;;  # glued -Rowner/repo or -R=owner/repo
    --repo=*)  REPO="${1#--repo=}"; shift ;;
    -h|--help) usage; exit 0 ;;                            # --help is not an error (exit 0)
    -*)        echo "merge-state: unknown option '$1'." >&2; usage; exit 1 ;;
    *) if [ -n "$PR" ]; then echo "merge-state: unexpected extra argument '$1' (one PR only)." >&2; usage; exit 1; fi
       PR="$1"; shift ;;
  esac
done
# A non-empty repo must be exactly owner/repo: one slash, both parts non-empty
# (else -R swallowed the PR, or 'owner/repo/extra' would silently parse to owner+extra).
if [ -n "$REPO" ]; then
  case "$REPO" in
    */*/*|/*|*/) echo "merge-state: invalid repo '$REPO' (expected owner/repo)." >&2; exit 1 ;;
    */*)         : ;;
    *)           echo "merge-state: invalid repo '$REPO' (expected owner/repo)." >&2; exit 1 ;;
  esac
fi
case "$PR" in ''|*[!0-9]*) usage; exit 1 ;; esac

command -v jq >/dev/null 2>&1 || { echo "merge-state: jq required." >&2; exit 4; }
command -v gh >/dev/null 2>&1 || { echo "merge-state: gh required." >&2; exit 4; }

[ -n "$REPO" ] || REPO=$(gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null || true)
[ -n "$REPO" ] || { echo "merge-state: cannot resolve owner/repo (pass -R owner/repo)." >&2; exit 3; }
OWNER=${REPO%%/*}; NAME=${REPO##*/}

PV=$(gh pr view "$PR" -R "$REPO" \
  --json number,title,headRefName,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup \
  2>/dev/null) || { echo "merge-state: 'gh pr view' failed for #$PR in $REPO." >&2; exit 2; }
[ -n "$PV" ] || { echo "merge-state: empty pr view for #$PR." >&2; exit 2; }

# Count UNRESOLVED review threads opened by a review bot. --paginate follows
# $endCursor (GraphQL caps pages at 100) so >100 threads are not truncated.
count_bot_threads(){
  local owner="$1" name="$2" pr="$3" raw
  raw=$(gh api graphql --paginate -f owner="$owner" -f repo="$name" -F pr="$pr" -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
        reviewThreads(first:100, after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{ isResolved comments(first:1){ nodes{ author{ login } } } } } } } }' 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -rs --arg re "$BOT_PATTERN" '
    [ .[].data.repository.pullRequest.reviewThreads.nodes[]?
      | select(.isResolved==false)
      | select((.comments.nodes[0].author.login // "")|test($re;"i")) ] | length' 2>/dev/null || return 1
}
if THREADS=$(count_bot_threads "$OWNER" "$NAME" "$PR"); then :; else THREADS=null; fi
case "$THREADS" in ''|*[!0-9]*) THREADS=null ;; esac

printf '%s' "$PV" | jq --argjson t "$THREADS" '
  def bucket:
    (.conclusion // "") as $c | (.state // "") as $s |
    if   ($c=="SUCCESS" or $c=="NEUTRAL" or $c=="SKIPPED" or $s=="SUCCESS") then "pass"
    elif ($c=="FAILURE" or $c=="TIMED_OUT" or $c=="CANCELLED" or $c=="ACTION_REQUIRED"
          or $c=="STARTUP_FAILURE" or $c=="STALE" or $s=="FAILURE" or $s=="ERROR") then "fail"
    else "pending" end;
  { pr: .number, title: .title, head: .headRefName, base: .baseRefName,
    mergeable: .mergeable, merge_state: .mergeStateStatus,
    review_decision: (.reviewDecision // ""),
    ci: (reduce (.statusCheckRollup[]?) as $x ({pass:0,fail:0,pending:0}; .[($x|bucket)] += 1)),
    unresolved_bot_threads: $t }'
