# vibeguard advanced (v2 roadmap — mostly shipped as opt-ins, some still deferred)

These guardrails are kept out of the **default** beginner install (several ship as opt-in flags). They
target users who already run a GitHub pull-request workflow with a merge queue
and bot reviewers (CodeRabbit, Qodo, Copilot, Greptile, Sourcery, Vercel, Cursor) — not the
zero-config vibe-coder audience the core is built for.

They are tracked here so the roadmap and the de-coupling work are explicit.

> **Update:** several of these have since shipped as opt-in installs / helpers
> (see the main README): the worktree session-lock (`--with-worktree-lock`), a
> **lite** PR merge-triage gate (`--with-merge-triage`, native thread resolution),
> draft-mode (`--with-draft-mode`), review-receipt (`--with-review-receipt`),
> husky-guard (`--with-husky-guard`), a local hashed **merge-ack**
> (`--with-merge-ack`, a terminal-first hash-based ack — not a cryptographic
> signature), and the **merge-state
> engine** as a read-only helper (`scripts/merge-state.sh`). The rows still marked
> deferred below (merge-triage full, bot-thread lib, merge-queue CI) remain v2.

## Advanced components (roadmap — shipped + still deferred)

| Component | What it does | Why it is advanced |
| --- | --- | --- |
| PR merge-triage (full) | Policy-routing + hash-based-ack version (a policy generator, an ack store, and a byte-identical bot-pattern hash) | Heavyweight, **still deferred**. The lite native-resolution gate shipped instead, and the terminal-first hash-based ack (a local sha256 acknowledgement, not a cryptographic signature) shipped separately as `--with-merge-ack` (#15). Only the full policy-routing engine remains. |
| bot-thread fetch (lib) | Single source of truth for the reviewer-bot login pattern + thread hashing | Only useful as the shared library for the triage chain |
| merge-state engine | Read-only merge-state dump + next-action recommendation + JSON policy | **shipped** as `scripts/merge-state.sh` (read-only helper, opt-in like `agent-issue.sh`; PRs #16–#18). Delivered lean as three slices — dump / next-action + blockers / optional policy — instead of a ~1000-line engine. |
| draft-mode + review-receipt gates | Forces PRs to enter as Draft and requires a local review receipt before push | **shipped** as opt-ins `--with-draft-mode` (#11) and `--with-review-receipt` (#12); off by default because opinionated. |
| agent backlog | Files de-duplicated GitHub issues for out-of-scope findings | **shipped** as `scripts/agent-issue.sh` (helper; see main README) |
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

Partially shipped. Most rows now ship as opt-in installs or helpers (see the rows
marked **shipped** and the main README). The remaining deferred rows —
merge-triage (full), bot-thread fetch (lib), and merge-queue CI — stay the v2 spec.
