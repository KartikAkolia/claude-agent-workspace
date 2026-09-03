# Github

Kartik's personal Claude Code / Cowork workspace: shared `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md` conventions across every project under this folder, plus five read-only ChrisTitusTech reference clones. It also hosts a couple of small projects that grew out of that setup — `fjord/`, a read-only Astro reader for this repo's own docs, and `job-search/`, working notes from an `it-job-search` skill session. See `SPEC.md` for what this project is and `AGENTS.md` for how to work in it.

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

`lint-markdown.sh` is the repo's one lint entry point (the name predates what it's grown into — kept as-is since the pre-commit hook and CI both call it by name). It runs, across every tracked file outside the five read-only reference clones:

- `mdl` plus `check-markdown-links.py` (catches local cross-references to files that no longer exist) on markdown.
- `validate-config.sh` on JSON/YAML — just confirms it parses, catching a typo in `.claude/settings.json` or similar before it silently breaks hook/tool wiring at runtime.
- `lint-bash.sh` (`shellcheck` + `shfmt -d` + `bash -n`) on every bash script, found by shebang rather than a `.sh` extension since not all of them have one (`.githooks/pre-commit`).
- `lint-python.sh` (`ruff check` + `ruff format --check`, run via `uvx` so nothing needs a system-wide install) on every `.py` file.

`.githooks/pre-commit` runs the same four checks against whatever's staged, so `git commit` blocks on a style violation, a broken local link, invalid config, or a lint finding. Hooks come from `.githooks/`, not `.git/hooks/` — set once per clone with `git config core.hooksPath .githooks`.

`refresh-reference-clone.sh <owner/repo> <branch> <local-dir>` resyncs one of the five static ChrisTitusTech mirrors from its GitHub upstream tarball via `gh api`, diffing before it touches anything and only writing if upstream actually moved. See `AGENTS.md` non-negotiable #1 for the one narrow exception it represents to "never write into the reference clones."

## CI

Three GitHub Actions workflows under `.github/workflows/`, none of them a blocking merge gate (private repos need a paid GitHub tier for branch-protection rulesets — see `SPEC.md`'s Testing & CI section):

- `lint.yml` — re-runs `lint-markdown.sh` on every push/PR, a backstop for a `--no-verify` bypass or a commit made on a machine without the hook wired up.
- `gitleaks.yml` — secret scanning on every push/PR.
- `fjord-ci.yml` — `astro check` plus `astro build` for `fjord/`, path-filtered so it only runs when `fjord/**` actually changes.

`dependabot.yml` adds weekly npm update checks scoped to `/fjord` (the only subfolder with a `package.json` that isn't a read-only reference clone or an untracked separate repo).

Full breakdown — exact versions, which packages come from third-party apt repos (`gh`), which MCP connectors are cloud/account-based rather than local packages (Gmail, Google Drive, Microsoft 365, etc.), the two enabled plugins, and a skill-by-skill dependency table — is in [`docs/debian-host-claude-setup.md`](docs/debian-host-claude-setup.md).

## Where to find more

- `AGENTS.md` — non-negotiables, repository map, working conventions.
- `SPEC.md` — what this project is, architecture, acceptance criteria.
- `ROADMAP.md` / `TASKS.md` — phased plan and active-phase detail.
- `docs/handoff.md` — continuity notes across sessions.
- `docs/headroom-setup-plan.md` — the Windows 11 host's equivalent setup (different machine, `winget`-based).
- `docs/debian-host-claude-setup.md` — the `dell-optiplex` Debian desktop's equivalent setup (`apt`-based, x86-64, user `kartik`).
- `docs/raspberry-pi-host-setup.md` — the Raspberry Pi 5 host's equivalent setup (Debian `aarch64`, user `pi`; slim Headroom install + persistent `systemd --user` service).
- `fjord/AGENTS.md` / `fjord/SPEC.md` — the Astro doc-reader subproject: what it renders, its own read-only non-negotiables, deployment on hold pending Kartik's review.
- `job-search/README.md` — Kartik's personal IT job-search working notes (target roles, gap analysis, CV state, action plan); the reusable domain research backing it lives in `.claude/skills/it-job-search/references/`.
