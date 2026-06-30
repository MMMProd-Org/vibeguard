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

## Turning it off

Everything vibeguard adds lives in `.claude/hooks/`, and anything it changed has a backup next to it (`*.vibeguard-bak.*`). To switch it off, remove the vibeguard lines from `.claude/settings.json`.

## Good to know

vibeguard checks each command **before** it runs and blocks the dangerous ones. It cannot stop an AI that is deliberately trying to get around it — it is a seatbelt, not a vault. Use it as one layer of safety, not your only one. One specific gap: the branch check looks for `main`/`master` named in the command, so a plain push while you are already on `main` is not caught — keep your own branch protection as well.

## What is coming next

More advanced, optional features (automatic pull-request review, isolated workspaces) are planned and described in [`advanced/`](advanced/README.md).

## License

MIT — free to use. See [LICENSE](LICENSE).
