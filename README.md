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
- `advanced/` — notes on optional, heavier features (automatic pull-request review, isolated workspaces) that are **not** installed by default.

## Want tighter control? (optional)

Out of the box, the scope guard blocks writes **outside** your project (the git and command guards above always run too). If you also want to limit writes to certain folders *inside* your project, create a file named `.session-scope.json`:

```json
{ "scopePaths": ["src/", "tests/"] }
```

Now the AI can only write inside `src/` and `tests/`. Everything else is blocked.

## Running several AI agents at once? (optional)

If you run more than one agent across separate git worktrees, install the
**worktree session-lock** so each agent stays pinned to its own worktree and
cannot wander into another one's:

```bash
/path/to/vibeguard/install.sh --with-worktree-lock
```

It records a small lock file when a session starts, and blocks shell commands
whose working directory has drifted outside the locked worktree. It is off by
default because a single agent in a single repo does not need it.

## Using a code-review bot? (optional)

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

## Worried about your hooks being silently bypassed? (optional)

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

## Want pull requests to start as drafts? (optional)

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

## Want a code-review receipt before every push? (optional)

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
reviewing, run the command the block prints:

```bash
.claude/hooks/check-agent-review-gate.sh --write --review "<summary>" --simplify-na "<reason>"
```

It is opinionated, **off by default**, and wired for **Claude Code** only. It
fails open on anything that is not a clearly-detected push, and exposes an
audit-visible bypass (`SKIP_REVIEW_GATE=1`) for the rare case the gate is wrong.

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
| Merge-queue CI guardrails (`merge_group`) | v2, opt-in |

The v2 guardrails are **not** installed by default: they assume a GitHub PR workflow
and would get in a solo vibe-coder's way. See [`advanced/`](advanced/README.md) for the
full spec and the de-coupling each one still needs.

## License

MIT — free to use. See [LICENSE](LICENSE).
