# vibeguard

[![CI](https://github.com/MMMProd-Org/vibeguard/actions/workflows/ci.yml/badge.svg)](https://github.com/MMMProd-Org/vibeguard/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)


**Portable guardrails for AI coding agents.** Works with **Claude Code** and **Codex**, in **any project**, whatever your language. Made for vibe coders who just want their agent to stop doing scary things.

> Best-effort footgun prevention — **not a security sandbox**. It catches common mistakes; it does not contain a determined or adversarial agent.

## Why

Letting an AI agent run shell commands and edit files is great until it force-pushes over your work, wipes a folder, or rewrites files outside the project. vibeguard installs small pre-flight checks ("hooks") that stop the most common disasters **before** they run.

## What you get (this release)

| Guardrail | What it stops |
| --- | --- |
| **force-push / destructive git** | force pushes, hard resets, direct pushes to the main branch, recursive-force file deletions |
| **dangerous commands** | hook-skipping commit/push flags, blind `git add` of everything, force `git clean`, world-writable permission changes, recursive-force deletes |
| **scope guard** (opt-in) | writing files **outside your project folder** is always blocked; restricting writes to specific subfolders is opt-in |

All three run on **both** Claude Code and Codex (same scripts, one thin Codex bridge).

## Install

```bash
git clone https://github.com/<you>/vibeguard
cd <your-project>
/path/to/vibeguard/install.sh        # or: bash /path/to/vibeguard/install.sh .
```

The installer:
- copies the hooks into your project's `.claude/hooks/`,
- **merges** them into `.claude/settings.json` without overwriting your existing settings (a timestamped backup is made),
- registers the same hooks for Codex (`.codex/`),
- is **idempotent** — running it twice changes nothing.

Requires `jq` and `git` (`apt install jq` / `brew install jq`). `gh` (GitHub CLI) is optional and only used by advanced PR features.

## Scope guard is opt-in

By default the scope guard only blocks writes **outside** your project — your agent can work freely inside it. To restrict writes to specific folders, create a `.session-scope.json`:

```json
{ "scopePaths": ["src/", "tests/"] }
```

To make a missing scope file fail closed (strict mode): set `VIBEGUARD_SCOPE_STRICT=1`.

## Uninstall / rollback

Hooks live in `.claude/hooks/`. Backups are saved next to the files as `*.vibeguard-bak.*`. Remove the hook entries from `.claude/settings.json` (or restore a backup) to disable.

## Status

Early release. Ships the guardrails above with tests. More hooks (worktree isolation, PR-merge triage) are being de-coupled from their origin project and will land opt-in.

Advanced (PR-merge triage, worktree isolation, backlog) is deferred and specced in [`advanced/`](advanced/README.md).
