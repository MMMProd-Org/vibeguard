# vibeguard

[![CI](https://github.com/MMMProd-Org/vibeguard/actions/workflows/ci.yml/badge.svg)](https://github.com/MMMProd-Org/vibeguard/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) ![Claude Code + Codex](https://img.shields.io/badge/works%20with-Claude%20Code%20%2B%20Codex-blue)

**A safety net for when you let an AI write code on your machine.**

You are vibe coding — letting Claude Code or Codex run commands and edit files for you. It is fast and fun, until the AI does something you did not want: it force pushes over a day of work, deletes the wrong folder, or changes files outside your project. vibeguard quietly stops those mistakes before they happen.

Works with **Claude Code** and **Codex**. Any project, any language. No setup headaches.

> Think of it as a **seatbelt**: it protects you from the common crashes. It is not a bulletproof vault.

---

## Install (about a minute)

```bash
git clone https://github.com/MMMProd-Org/vibeguard
cd your-project
/path/to/vibeguard/install.sh
```

Done — vibeguard is now watching. It plugs into Claude Code and Codex for you, and it **never deletes your existing settings** (it saves a backup first). Running it again is safe and changes nothing.

You just need `jq` and `git` installed first. On a Mac: `brew install jq`. On Linux: `sudo apt install jq`.

## What it stops

| If the AI tries to… | vibeguard |
| --- | --- |
| Force push and overwrite your history | 🚫 blocks it |
| Throw away your changes with a hard reset | 🚫 blocks it |
| Push straight to your main branch | 🚫 blocks it |
| Delete a folder with a recursive force delete | 🚫 blocks it |
| Skip your git safety checks | 🚫 blocks it |
| Make files world-writable | 🚫 blocks it |
| Edit files **outside** your project folder | 🚫 blocks it |

When something is blocked, vibeguard prints a short, plain reason — so you and the AI both know what happened and why.

## What's inside

vibeguard installs three small guards. Each one checks an action **before** it runs, and blocks it if it looks dangerous:

- **Destructive-git guard** — `hooks/block-force-push.sh`. Stops the AI from throwing away your work: force-pushing over your history, wiping changes with a hard reset, pushing directly to `main`/`master`, or force-deleting a folder.
- **Risky-command guard** — `hooks/pre-tool-use-danger.sh`. Stops common footguns in shell commands: blindly staging every file, skipping your git safety checks, force-cleaning the working tree, or making files world-writable.
- **Stay-in-your-project guard** — `hooks/pre-tool-use-scope.sh`. Stops the AI from writing files **outside** your project folder. Optionally, with a `.session-scope.json` file, you can narrow it to specific folders (see the next section).

And the supporting pieces:

- `install.sh` — wires the guards into Claude Code and Codex for you. It backs up anything it changes and is safe to re-run.
- `scripts/do-release.sh` — a small helper for maintainers to publish a GitHub release.
- `scripts/agent-issue.sh` — files **de-duplicated** GitHub issues for out-of-scope findings an agent surfaces (optional helper; see below).
- `scripts/merge-state.sh` — prints a read-only JSON snapshot of a PR's merge readiness (CI, review, unresolved bot threads) plus a recommended next action (optional helper; see below).
- `advanced/` — notes on optional, heavier features (automatic pull-request review, isolated workspaces) that are **not** installed by default.

## Optional guardrails

The core above is everything a solo vibe-coder needs. Everything below is **off by default** — turn on only what fits your workflow. Each is a seatbelt: fail-open, never a false block.

| If you want to… | Turn on |
| --- | --- |
| Narrow writes to specific folders inside your project | add a `.session-scope.json` |
| Run several AI agents at once (one worktree each) | `install.sh --with-worktree-lock` |
| Block a merge until a review bot's threads are resolved | `install.sh --with-merge-triage` |
| Block a push that bypasses your git hooks | `install.sh --with-hookspath-guard` |
| Make pull requests start as drafts | `install.sh --with-draft-mode` |
| Require a code-review receipt before every push | `install.sh --with-review-receipt` |
| Let an agent file findings without spamming issues | `scripts/agent-issue.sh` (helper) |
| Block a push when a husky pre-push hook went missing | `install.sh --with-husky-guard` |
| Get a paper trail before merging bot-reviewed PRs | `install.sh --with-merge-ack` |
| Get a read-only snapshot of a PR's merge state | `scripts/merge-state.sh` (helper) |

<a id="want-tighter-control-optional"></a>
<details>
<summary><strong>Narrow writes to specific folders inside your project</strong></summary>

Out of the box, the scope guard blocks writes **outside** your project (the git and command guards above always run too). If you also want to limit writes to certain folders *inside* your project, create a file named `.session-scope.json`:

```json
{ "scopePaths": ["src/", "tests/"] }
```

Now the AI can only write inside `src/` and `tests/`. Everything else is blocked.

</details>

<a id="running-several-ai-agents-at-once-optional"></a>
<details>
<summary><strong>Run several AI agents at once (one worktree each)</strong></summary>

If you run more than one agent across separate git worktrees, install the
**worktree session-lock** so each agent stays pinned to its own worktree and
cannot wander into another one's:

```bash
/path/to/vibeguard/install.sh --with-worktree-lock
```

It records a small lock file when a session starts, and blocks shell commands
whose working directory has drifted outside the locked worktree. It is off by
default because a single agent in a single repo does not need it.

</details>

<a id="using-a-code-review-bot-optional"></a>
<details>
<summary><strong>Block a merge until a review bot's threads are resolved</strong></summary>

If you open pull requests and let a review bot (CodeRabbit, Qodo, Copilot,
Greptile, Sourcery, ...) comment on them, install the **merge-triage gate** so a
PR cannot be merged while the bot still has **unresolved** review conversations:

```bash
/path/to/vibeguard/install.sh --with-merge-triage
```

When you ask the AI to merge a PR, the gate checks the PR's review threads. If a
bot left feedback you have not resolved yet, the merge is blocked until you
triage and resolve those conversations on GitHub. It is **advisory and
fail-open**: if you use no review bot, or `gh` is unavailable, it does nothing.

- Pick which bots count with `VIBEGUARD_BOT_PATTERN` (a regex).
- Bypass once with `VIBEGUARD_SKIP_TRIAGE=1` before your merge command.

</details>

<a id="worried-about-your-hooks-being-silently-bypassed-optional"></a>
<details>
<summary><strong>Block a push that bypasses your git hooks</strong></summary>

If an agent (or a stray command) redirects your repo's hooks somewhere harmless
and then pushes, your pre-push checks are skipped without a trace. Install the
**hooksPath push guard** to block a `git push` whenever the repo's **local**
`core.hooksPath` has been pointed away from its default (or husky):

```bash
/path/to/vibeguard/install.sh --with-hookspath-guard
```

It reads the repo's live config at push time, so it catches the two-step bypass
(`git config core.hooksPath ...` and then a later `git push`) that a
single-command check cannot see. It looks at the **local** setting only, so a
legitimate global hooks setup (e.g. git-templates) is left alone. Off by
default, and (like the other opt-ins) wired for **Claude Code** only.

</details>

<a id="want-pull-requests-to-start-as-drafts-optional"></a>
<details>
<summary><strong>Make pull requests start as drafts</strong></summary>

If you open PRs with the `gh` CLI and want a review-first flow, install the
**draft-mode gate**. It makes `gh pr create` require `--draft` (so a PR enters
GitHub as a Draft -- a not-ready-for-review signal -- so review bots / humans can
look before you mark it ready), and makes
`gh pr ready` require an explicit `PR_READY_ACK=1` acknowledgement:

```bash
/path/to/vibeguard/install.sh --with-draft-mode
```

It is opinionated and assumes a GitHub PR workflow, so it is **off by default**.
It only inspects `gh` in command position (a literal `rg "gh pr create"` is fine)
and, like the other opt-ins, is wired for **Claude Code** only.

</details>

<a id="want-a-code-review-receipt-before-every-push-optional"></a>
<details>
<summary><strong>Require a code-review receipt before every push</strong></summary>

If you want a hard stop against pushing code straight from dev without a review
pass, install the **review-receipt gate**. It intercepts a push and blocks it
until a fresh receipt proves a code-review ran (plus a simplify/distill pass, or
an explicit not-applicable reason) over the *current* diff:

```bash
/path/to/vibeguard/install.sh --with-review-receipt
```

The receipt is a small local file (`.git/agent-review-gate/latest.env`) tied to a
hash of the exact diff, so it is invalidated the moment the code changes or after
24h -- you cannot mint one, keep editing, and still push. To mint it after
reviewing, run the command the block prints (swap in `--simplify-na "<reason>"`
when a simplify pass genuinely does not apply):

```bash
.claude/hooks/check-agent-review-gate.sh --write --review "<summary>" --simplify "<summary>"
```

It is opinionated, **off by default**, and wired for **Claude Code** only. It
fails open on anything that is not a clearly-detected push, and exposes an
audit-visible bypass (`SKIP_REVIEW_GATE=1`) for the rare case the gate is wrong.

</details>

<a id="want-an-agent-to-file-findings-without-spamming-issues-optional"></a>
<details>
<summary><strong>Let an agent file findings without spamming issues</strong></summary>

When an AI agent notices something out of scope while working, `scripts/agent-issue.sh`
files it as a GitHub issue **de-duplicated by location** -- the same finding never opens
two issues. It fingerprints the finding (a `loc-hash` over the `type` / `file` / `line`
frontmatter of the body) and, if an open `agent-finding` issue already carries that hash,
comments on it instead of filing a new one:

```bash
scripts/agent-issue.sh "<title>" "agent-finding" <body-file.md> <story-id>
```

The body file needs a small YAML frontmatter (`type:`, plus a `files:` block of `- path:` /
`lines:` entries -- those are what the hash is built from). It caps runaway filing at 4 issues
per story (`--meta` groups beyond that) and **degrades gracefully**: if `gh` is missing or not
signed in, the finding is saved under `backlog/pending/` instead of being lost. Local dedup
state lives in `.agent-backlog/` (counters, locks); a ready `.gitignore` scaffold ships there.

This is a **helper you invoke**, not an install-time hook -- there is nothing to wire up.

</details>

<a id="worried-you-deleted-a-git-hook-you-rely-on-optional"></a>
<details>
<summary><strong>Block a push when a husky pre-push hook went missing</strong></summary>

If your repo uses [husky](https://typicode.github.io/husky/) for a `pre-push` hook,
install the **husky-guard** so a push is blocked when `.husky/` exists but
`.husky/pre-push` has gone missing (deleted, or never restored after a branch
switch) -- the checks you expect at push time would otherwise silently not run:

```bash
/path/to/vibeguard/install.sh --with-husky-guard
```

It checks the working-tree root of the pushing repo (so a push from a linked worktree is judged by its own checkout),
honours `git -C <path> push`, and is **off by default**, Claude-only. If the repo
does not use husky, or `pre-push` is present, nothing changes. Like the other
opt-ins it is a seatbelt: an obfuscated command degrades to a skipped check, never
a false block.

</details>

<a id="want-a-paper-trail-before-merging-bot-reviewed-prs-optional"></a>
<details>
<summary><strong>Get a paper trail before merging bot-reviewed PRs</strong></summary>

If you use a review bot (CodeRabbit, Qodo, Copilot, ...) and want confirmation
you have seen its latest feedback before a PR merge, install the **merge-ack gate**.
It blocks a `gh pr merge` until a fresh local acknowledgement matches the current
bot review threads on that PR:

```bash
/path/to/vibeguard/install.sh --with-merge-ack
```

Run `.claude/hooks/check-merge-ack.sh <PR>` to write the ack -- it hashes the current thread IDs
and saves the result locally. The next merge on that PR goes through. If the bot opens a new review thread afterwards, the thread ID set changes, the hash no longer matches, and the gate re-blocks. Replies or edits inside an existing thread do not change the thread ID set and will not re-block.

It is **off by default** and wired for **Claude Code** only. Like the other opt-ins,
it is a seatbelt -- fail-open: if `gh` is unavailable or the PR cannot be resolved,
the merge is allowed through.

</details>

<a id="want-a-read-only-snapshot-of-a-prs-merge-state-optional"></a>
<details>
<summary><strong>Get a read-only snapshot of a PR's merge state</strong></summary>

`scripts/merge-state.sh <PR>` prints a stable JSON snapshot of a pull request's merge
readiness -- `mergeable` state, CI `pass`/`fail`/`pending`, review decision, and the count
of unresolved review-bot threads -- plus an ordered list of `blockers` and a single
recommended `next_action` (`fix_ci`, `wait_ci`, `resolve_threads`, `ready`, ...):

```bash
scripts/merge-state.sh 42               # PR in the current repo
scripts/merge-state.sh 42 -R owner/repo
```

It reads through `gh` (owner/repo auto-detected, no hardcoded default) and never blocks,
mutates, or merges -- it only reports, so it is safe to run anytime. An optional
`.vibeguard/merge-policy.json` (or `$VIBEGUARD_MERGE_POLICY`) can rename actions, disable
gates, or override the bot pattern; a malformed policy is ignored. Like `agent-issue.sh`,
this is a **helper you invoke**, not an install-time hook.

</details>

## Turning it off

Everything vibeguard adds lives in `.claude/hooks/`, and anything it changed has a backup next to it (`*.vibeguard-bak.*`). To switch it off, remove the vibeguard lines from `.claude/settings.json`.

## Good to know

vibeguard checks each command **before** it runs and blocks the dangerous ones. It cannot stop an AI that is deliberately trying to get around it — it is a seatbelt, not a vault. Use it as one layer of safety, not your only one. One specific gap: the branch check looks for `main`/`master` named in the command, so a plain push while you are already on `main` is not caught — keep your own branch protection as well.

## Roadmap — what is here, what is next

vibeguard ships a small, zero-config **core** today. Heavier, opt-in guardrails for
teams already running a pull-request + merge-queue workflow are planned for **v2**
(tracked in [`advanced/`](advanced/README.md)).

| Guardrail | Status |
| --- | --- |
| Destructive-git guard (force-push, hard-reset, recursive force-delete, and pushes that name a protected branch) | shipped |
| Risky-command guard (stage-all, skip-git-checks, force-clean, world-writable) | shipped |
| Stay-in-your-project scope guard (+ optional `.session-scope.json`) | shipped |
| Worktree session-lock — one agent per worktree (multi-agent collision guard) | shipped (opt-in) |
| PR merge-triage — block a merge until reviewer-bot threads are resolved | shipped (opt-in) |
| Generic bot-review support (CodeRabbit, Qodo, Copilot, Greptile, Sourcery, Vercel, Cursor, custom) | shipped (opt-in) |
| hooksPath push guard — block a push when the local `core.hooksPath` bypasses your hooks | shipped (opt-in) |
| Draft-mode gate — `gh pr create` must be `--draft`; `gh pr ready` needs an explicit ack | shipped (opt-in) |
| Review-receipt gate — require a local code-review receipt before push | shipped (opt-in) |
| Agent issue backlog -- file de-duplicated GitHub issues for out-of-scope findings | shipped (helper script) |
| husky pre-push presence guard -- block a push when `.husky/pre-push` is missing | shipped (opt-in) |
| Merge-ack gate -- block a PR merge until local ack matches current bot threads | shipped (opt-in) |
| Merge-state snapshot -- read-only JSON of a PR's merge readiness + recommended next action | shipped (helper script) |
| Merge-queue CI guardrails (`merge_group`) | v2, opt-in |

The v2 guardrails are **not** installed by default: they assume a GitHub PR workflow
and would get in a solo vibe-coder's way. See [`advanced/`](advanced/README.md) for the
full spec and the de-coupling each one still needs.

## License

MIT — free to use. See [LICENSE](LICENSE).
