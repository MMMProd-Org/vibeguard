# vibeguard advanced (deferred — v2)

These guardrails are **intentionally not shipped** in the beginner install. They
target users who already run a GitHub pull-request workflow with a merge queue
and bot reviewers (CodeRabbit, Qodo, Copilot, Greptile, Sourcery, Vercel, Cursor) — not the
zero-config vibe-coder audience the core is built for.

They are tracked here so the roadmap and the de-coupling work are explicit.

> **Update:** the worktree session-lock has since shipped as an opt-in install
> (`install.sh --with-worktree-lock`) — see the main README. The components
> below remain deferred. (A **lite** PR merge-triage gate has shipped as an
> opt-in install `--with-merge-triage` — it blocks a merge while a review bot has
> unresolved threads, using GitHub's native thread resolution instead of the
> heavier policy/ack system, which stays deferred.)

## Deferred components

| Component | What it does | Why it is advanced |
| --- | --- | --- |
| PR merge-triage (full) | Policy-routing + signed-ack version (a policy generator, an ack store, and a byte-identical bot-pattern hash) | Heavyweight; the lite native-resolution gate shipped instead (see note above) |
| bot-thread fetch (lib) | Single source of truth for the reviewer-bot login pattern + thread hashing | Only useful as the shared library for the triage chain |
| merge-state engine | Read-only merge-state dump + next-action recommendation + JSON policy | ~1000 lines; the engine behind a project-specific merge workflow |
| draft-mode + review-receipt gates | Forces PRs to enter as Draft and requires a local review receipt before push | Opinionated team workflow; would block a beginner's normal push |
| agent backlog | Files de-duplicated GitHub issues for out-of-scope findings | Needs a GitHub issues workflow + label conventions |
| merge-queue CI | A `merge_group` CI check that re-runs the guards on the merge queue (secret scan over the queued range, repo-hygiene file gates) | Only meaningful with a GitHub merge queue; the core ships a simpler `ci.yml` instead |

## De-coupling required before any of this ships

- Resolve owner/repo from `gh` instead of a hardcoded default; parametrise the
  merge-queue ruleset name and the agent id.
- Provide the `.agent-backlog/` scaffold and degrade gracefully when `gh` is
  absent (the core guardrails must keep working offline).
- macOS portability: `sha256sum` -> `shasum -a 256`, GNU `date -d` -> BSD
  `date -j` — and the acknowledgement hash MUST be computed identically by the
  writer and the reader, or verification breaks silently.
- Fix the known over-match where the merge-triage guard flags an in-place stream
  edit appearing anywhere in a command (finding tracked from the extraction
  session).
- Ship (or inline) the reviewer-comment triage guidance the merge-triage guard
  points users to.

## Status

Not shipped. No code here yet — this file is the spec for the v2 effort.
