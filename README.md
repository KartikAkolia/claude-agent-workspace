# Github

Kartik's personal Claude Code / Cowork workspace: shared `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md` conventions across every project under this folder, plus five read-only ChrisTitusTech reference clones. See `SPEC.md` for what this project is and `AGENTS.md` for how to work in it.

## Quick start: replicating this Claude Code setup on a fresh Debian host

```sh
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code CLI
curl -LsSf https://astral.sh/uv/install.sh | sh        # uv, needed by the two local MCP servers
uv tool install headroom-ai                             # headroom (compression proxy + memory)
sudo apt install shellcheck shfmt devscripts bind9-dnsutils \
  quickshell qt6-declarative-dev-tools cmake ninja-build hugo podman
```

That covers the CLI itself, both local MCP servers (`headroom`, `serena` — the latter needs nothing beyond `uv`), and the apt packages this repo's custom skills (`bash-scripting`, `linux-sysadmin`/`homelab-admin`, `quickshell`, `hugo`) expect to find on `PATH`.

Full breakdown — exact versions, which packages come from third-party apt repos (`gh`), which MCP connectors are cloud/account-based rather than local packages (Gmail, Google Drive, Microsoft 365, etc.), the two enabled plugins, and a skill-by-skill dependency table — is in [`docs/debian-host-claude-setup.md`](docs/debian-host-claude-setup.md).

## Where to find more

- `AGENTS.md` — non-negotiables, repository map, working conventions.
- `SPEC.md` — what this project is, architecture, acceptance criteria.
- `ROADMAP.md` / `TASKS.md` — phased plan and active-phase detail.
- `docs/handoff.md` — continuity notes across sessions.
- `docs/headroom-setup-plan.md` — the Windows 11 host's equivalent setup (different machine, `winget`-based).
- `docs/debian-host-claude-setup.md` — this Debian host's equivalent setup (`apt`-based).
