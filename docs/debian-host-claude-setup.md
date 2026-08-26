# Replicating This Claude Code Setup on a Debian Host

This documents the current Claude Code CLI environment on this Debian host (`dell-optiplex`, running `forky/sid`) — packages, MCP connectors, plugins, and the extra tooling specific skills need to actually work rather than just being present as prose. It's the Debian counterpart to `docs/headroom-setup-plan.md`, which covers the separate Windows 11 machine; don't conflate the two, they're different hosts with different install mechanics (`winget`/PowerShell there, `apt`/bash here).

Everything below was verified against this host's actual installed state (`dpkg -l`, `command -v`, `uv tool list`, `headroom doctor`), not assumed from what a typical setup would include. Where a tool is *not* installed here, that's stated explicitly rather than glossed over.

## 1. Base OS

```text
$ cat /etc/os-release
PRETTY_NAME="Debian GNU/Linux forky/sid"
```

This host tracks Debian testing/unstable, not stable. A couple of packages below (`quickshell` in particular, and the current `shfmt`/`ripgrep`-class versions) are recent enough that they may not exist yet in Debian 13 (trixie) stable's default archive — check `apt-cache policy <pkg>` on the target host before assuming parity, and fall back to backports or a manual install if a package isn't there.

## 2. Claude Code CLI itself

Installed via the official native installer, not npm (this host has no `node`/`npm` at all — nothing in this setup needs it):

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

Confirmed: `claude --version` → `2.1.246`, binary at `~/.local/bin/claude` (symlinked into `~/.local/share/claude/versions/2.1.246`).

## 3. `uv` — required for both local MCP servers

Both MCP servers configured on this host (headroom, serena) are Python tools run through `uv`. Installed via the official installer:

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Confirmed: `uv --version` → `0.12.5`, `uvx --version` → `0.12.5`, both at `~/.local/bin/`.

## 4. Headroom (local compression proxy + memory)

```sh
uv tool install headroom-ai
```

Confirmed: `uv tool list` shows `headroom-ai v0.36.5 - headroom`. Registered as a `stdio` MCP server in `~/.claude.json`'s top-level `mcpServers`:

```json
"headroom": {
  "type": "stdio",
  "command": "/home/kartik/.local/bin/headroom",
  "args": ["mcp", "serve"]
}
```

It's already wrapping this session: `headroom doctor` reports the proxy running (`http://127.0.0.1:8787`), version-matched, with real lifetime savings. Follow `docs/headroom-setup-plan.md`'s Phase 2–6 (the actual `headroom wrap claude` step, `--code-memory none` decision, etc.) for the full first-run walkthrough — the mechanics are identical on Linux, only the install command above differs from the Windows/`winget` path.

## 5. Serena (semantic code navigation MCP)

No separate install step — `uvx` fetches it on demand. Registered in `~/.claude.json`:

```json
"serena": {
  "type": "stdio",
  "command": "uvx",
  "args": ["--from", "serena-agent", "serena", "start-mcp-server", "--project-from-cwd", "--context", "claude-code", "--open-web-dashboard", "False"]
}
```

This is the same server Headroom's own `headroom wrap claude` installs at user scope by default (see `docs/headroom-setup-plan.md`'s Phase 4 and Open Decision 1) — nothing further to install here beyond `uv` from step 3.

## 6. claude.ai-account connectors — no packages needed

Cloudflare Developer Platform, Context7, Gmail, Google Calendar, Google Drive, and Microsoft 365 are **not** locally-installed MCP servers — they don't appear in `~/.claude.json`'s `mcpServers` at all. They're cloud-hosted connectors tied to the Claude account this CLI session is authenticated against, enabled under Settings → Connectors on `claude.ai` and then just available here automatically. Replicating this on another host is an account-level step (log into the same Claude account, confirm each connector is enabled there), not a Debian package.

Note: Google Calendar, Google Drive, and Microsoft 365 show only `authenticate`/`complete_authentication` tools in a fresh session here, meaning they're enabled but not yet OAuth-authenticated in this particular session — that's expected and per-session, not a setup gap.

## 7. Plugins

Two plugins from the official marketplace, enabled at the project level (`/home/kartik/Github/.claude/settings.json`):

```json
{"enabledPlugins":{"code-simplifier@claude-plugins-official":true,"pr-review-toolkit@claude-plugins-official":true}}
```

To replicate, inside a Claude Code session:

```text
/plugin marketplace add anthropics/claude-plugins-official
/plugin install code-simplifier@claude-plugins-official
/plugin install pr-review-toolkit@claude-plugins-official
```

`code-simplifier` and `pr-review-toolkit` back the "execute a fix" half of the `engineering-tech-debt` skill and the independent-review step in `pr-readiness` — both skills assume these are installed rather than re-documenting the review logic themselves.

## 8. Skill tooling — what each custom skill under `.claude/skills/` actually needs installed

Most of this repo's custom skills (`ai-project-manager`, `engineering-architecture`, `engineering-debug`, `engineering-deploy-checklist`, `engineering-incident-response`, `engineering-standup`, `engineering-system-design`, `engineering-tech-debt`, `engineering-testing-strategy`, `productivity-update`, `wayfinder`) are process/methodology skills — they lean on `git`/`gh` (already covered) and produce markdown, no extra host packages. The ones that do need something specific:

| Skill | Needs | apt package | Status on this host |
| --- | --- | --- | --- |
| `bash-scripting` | `shellcheck`, `shfmt`, `checkbashisms` | `shellcheck`, `shfmt`, `devscripts` | installed (`0.11.0`, `3.13.1`, `2.26.11`) |
| `linux-sysadmin` / `homelab-admin` | `dig`, `ss`, `journalctl`, `systemctl`, standard net tools | `bind9-dnsutils` (rest ship with base Debian + `iproute2`/`systemd`) | installed |
| `pr-readiness` | `gh` CLI, plus the two plugins from §7 | official GitHub CLI apt repo (see below) | installed (`2.98.0`) |
| `hugo` | `hugo` binary | `hugo` | **not installed** — install before using this skill on a real Hugo project |
| `quickshell` | `quickshell` runtime; `qmllint` for the linting workflow | `quickshell`; `qt6-declarative-dev-tools` (provides `/usr/lib/qt6/bin/qmllint`, not on `PATH` by default) | `quickshell` installed (`0.3.0`); `qmllint` available via the Qt package but not symlinked onto `PATH` |
| `quickshell` (source builds only) | `cmake`, a build generator | `cmake`, `ninja-build` | `cmake` installed (`4.3.4`); `ninja-build` **not installed** |
| `python-ai` | `uv` (already covered in §3) for `uv run pytest`/`ruff`/`mypy` — these are per-project deps `uv` resolves from each project's own lockfile, not host packages | — | `uv` installed; no host-level Python linters needed beyond it |

`gh` is **not** from Debian's default archive — it's from GitHub's own apt repo:

```sh
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt update && sudo apt install gh
```

`gh` also needs `gh auth login` (or the `GH_TOKEN`-based workaround this host actually uses — see the memory note on git push auth and `docs/handoff.md`'s PAM/keyring section) before `pr-readiness` or any `gh`-backed workflow can authenticate.

## 9. Present but not required by any current skill

Installed on this host, useful, but nothing above depends on them: `podman` (container runtime — used ad hoc, e.g. testing CI workflows locally), `fzf`, `rsync`. Not installed and not currently a gap: `docker` (podman covers the same need), `node`/`npm`, `jq`, `ansible`, `tmux`, `fd`, `bat`, `ninja-build`. Worth revisiting only if a skill starts actually needing one of these — `jq` in particular is a likely near-term add if any future CI or scripting work leans on JSON parsing (already recommended, unrelated to this list, for `Debian-titus`'s Thorium download step).

## 10. Quick reference: one-shot apt install

Everything from §8/§9 that comes from Debian's default archive, in one line (does not include `gh`'s separate third-party repo from §8, or `uv`/`claude`/`headroom` from §2–4, which aren't apt packages):

```sh
sudo apt install shellcheck shfmt devscripts bind9-dnsutils \
  quickshell qt6-declarative-dev-tools cmake ninja-build hugo podman
```

## 11. Verification checklist

- `claude --version`, `uv --version`, `headroom --version` all print version numbers.
- `headroom doctor` reports the proxy running and version-matched (0 failures; warnings for unrouted `codex`/no budget are expected and informational, per `docs/headroom-setup-plan.md`'s Phase 3 note).
- Inside a Claude Code session, the skills/connectors/plugins listed above all appear in their respective system reminders (skills list, deferred MCP tools, available agents).
- `shellcheck --version`, `shfmt --version`, `gh --version` all resolve.
- For `quickshell` work specifically: `quickshell --version` resolves, and `/usr/lib/qt6/bin/qmllint --help` runs (even though it's not on `PATH` by default).
