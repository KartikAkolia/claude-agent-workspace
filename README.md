# Github

Kartik's personal Claude Code / Cowork workspace: shared `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md` conventions across every project under this folder, plus five read-only ChrisTitusTech reference clones. See `SPEC.md` for what this project is and `AGENTS.md` for how to work in it.

## Quick start: replicating this Claude Code setup on a fresh Debian host

```sh
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code CLI
curl -LsSf https://astral.sh/uv/install.sh | sh        # uv, needed by the two local MCP servers
uv tool install headroom-ai                             # headroom (compression proxy + memory)
sudo apt install shellcheck shfmt devscripts bind9-dnsutils rsync \
  quickshell qt6-declarative-dev-tools cmake ninja-build hugo podman
gem install --user-install mdl                          # markdown linting (lint-markdown.sh, pre-commit hook)
```

That covers the CLI itself, both local MCP servers (`headroom`, `serena` — the latter needs nothing beyond `uv`), the apt packages this repo's custom skills (`bash-scripting`, `linux-sysadmin`/`homelab-admin`, `quickshell`, `hugo`) expect to find on `PATH`, and `mdl` for this repo's own markdown tooling (see below). `gh` isn't in that one-liner — it comes from GitHub's own apt repo, not Debian's default archive; see the full breakdown for the exact steps.

## This repo's own tooling

Two scripts at the repo root, both `shellcheck`-clean:

- `lint-markdown.sh` — runs `mdl` plus `check-markdown-links.py` (catches local cross-references to files that no longer exist) across every tracked markdown file, skipping the five read-only reference clones. The same two checks run in `.githooks/pre-commit` against staged markdown, so `git commit` blocks on either a style violation or a broken local link. Hooks come from `.githooks/`, not `.git/hooks/` — set once per clone with `git config core.hooksPath .githooks`.
- `refresh-reference-clone.sh <owner/repo> <branch> <local-dir>` — resyncs one of the five static ChrisTitusTech mirrors from its GitHub upstream tarball via `gh api`, diffing before it touches anything and only writing if upstream actually moved. See `AGENTS.md` non-negotiable #1 for the one narrow exception it represents to "never write into the reference clones."

Full breakdown — exact versions, which packages come from third-party apt repos (`gh`), which MCP connectors are cloud/account-based rather than local packages (Gmail, Google Drive, Microsoft 365, etc.), the two enabled plugins, and a skill-by-skill dependency table — is in [`docs/debian-host-claude-setup.md`](docs/debian-host-claude-setup.md).

## Where to find more

- `AGENTS.md` — non-negotiables, repository map, working conventions.
- `SPEC.md` — what this project is, architecture, acceptance criteria.
- `ROADMAP.md` / `TASKS.md` — phased plan and active-phase detail.
- `docs/handoff.md` — continuity notes across sessions.
- `docs/headroom-setup-plan.md` — the Windows 11 host's equivalent setup (different machine, `winget`-based).
- `docs/debian-host-claude-setup.md` — the `dell-optiplex` Debian desktop's equivalent setup (`apt`-based, x86-64, user `kartik`).
- `docs/raspberry-pi-host-setup.md` — the Raspberry Pi 5 host's equivalent setup (Debian `aarch64`, user `pi`; slim Headroom install + persistent `systemd --user` service).
