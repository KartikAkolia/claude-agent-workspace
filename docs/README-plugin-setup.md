# Plugin setup status (2026-10-16)

Status of the five Claude Code additions requested on 2026-10-16: frontend-design, Playwright MCP, MemPalace, OmniRoute and Headroom. The full per-OS install guide is [`claude-plugins-setup.md`](claude-plugins-setup.md). This file records what was actually done and what is still left for Kartik.

## Enabling the plugins (not yet done)

The plugins are not switched on yet. Claude Code's auto mode blocked editing `.claude/settings.json` and running `claude plugin` commands, because both change Claude's own config. Run these from the repo root (same on every OS):

```bash
claude plugin marketplace add MemPalace/mempalace --scope project
claude plugin marketplace add projectsaibg/omniroute-claude-plugin --scope project
claude plugin install frontend-design@claude-plugins-official --scope project
claude plugin install playwright@claude-plugins-official --scope project
claude plugin install mempalace@mempalace --scope project
claude plugin install omniroute@omniroute-claude-plugin --scope project
```

This writes the plugins into the committed `.claude/settings.json`, so other machines get them from the repo. Each machine still needs the local software installed.

## Installed on the Mac

Each tool reported its version or ran on 2026-10-16.

- **Node 26.12.0** via Homebrew, also added to the `Brewfile`. Playwright and OmniRoute need it.
- **MemPalace**, installed with `uv tool`.
- **Headroom 0.41.0**. It needs Python 3.10 or newer, so it runs on Python 3.12 rather than the system 3.9.
- **OmniRoute 3.8.51**, via npm. A test start served its dashboard on port 20128, and it was stopped again.

## Things to know

- **Playwright** uses the official Anthropic-marketplace plugin rather than an entry in `.mcp.json`. It runs the same command Playwright's own docs give.
- **OmniRoute** needs more setup before it connects. Its MCP endpoint refused connections without an API key (HTTP 401), so create a key in its dashboard first. By default it accepts connections from the whole network with no key; start it with `OMNIROUTE_SERVER_HOST=127.0.0.1 omniroute` to keep it to this machine. The plugin repo has one commit and one star. All of it was read before enabling: it only points Claude at that local address, with no hooks or code.
- **Headroom** undoes the 2026-10-11 retirement, noted in `docs/handoff.md`. It is installed but not switched on anywhere. While it is configured, if the proxy isn't running, every Claude request fails rather than going direct. To use it for this repo only, run `headroom wrap vscode-claude --settings-file .claude/settings.local.json` and keep that terminal open. That repo-only form is untested; Headroom's docs only show the global settings file.
- **MemPalace**: run `/mempalace:init` once after enabling it. It adds hooks that save each session automatically, and these run through `bash`. On Windows that means Git Bash.
- **Other machines**: the Debian desktop, the Pi and Windows were not touched. Their install steps in the guide come from upstream docs and haven't been run. The Pi has no Chrome build and no display, so the guide covers using Firefox headless there instead.

## Files changed

A new `docs/claude-plugins-setup.md`, plus `Brewfile`, a link in `README.md`, and a dated entry and open item 32 in `docs/handoff.md`. Markdown lint, the link check and the Brewfile syntax check passed. The code review found one problem in the Pi browser-install step, which was fixed; the review was not rerun after that small prose fix. Nothing was committed.
