# Claude Code plugins for this repo

Five additions requested on 2026-10-16, set up for every host this repo runs on: macOS, `dell-optiplex` (Debian x86-64), the AdGuardHome Pi (Debian aarch64) and Windows (Git Bash). Four are Claude Code plugins enabled at project scope, so they are declared in the committed `.claude/settings.json` and every clone picks them up. The fifth, Headroom, is not a plugin but a local proxy, and is opt-in per host.

| Addition | Kind | Plugin id | Local runtime it needs |
| --- | --- | --- | --- |
| [frontend-design](https://claude.com/marketplace/plugins/frontend-design) | Skill (Anthropic) | `frontend-design@claude-plugins-official` | none |
| [Playwright MCP](https://playwright.dev/docs/getting-started-mcp) | stdio MCP (Microsoft) | `playwright@claude-plugins-official` | Node.js 20+ (`npx`), a browser |
| [MemPalace](https://github.com/mempalace/mempalace) | MCP + hooks + skills + commands | `mempalace@mempalace` | Python 3.9+, `mempalace` package, `bash` |
| [OmniRoute](https://github.com/projectsaibg/omniroute-claude-plugin) | HTTP MCP pointing at a local gateway | `omniroute@omniroute-claude-plugin` | Node.js, `omniroute` running on `localhost:20128` |
| [Headroom](https://docs.headroomlabs.ai/docs/vscode-claude-code) | Compression proxy via `ANTHROPIC_BASE_URL` | none | Python 3.10+, `headroom-ai[proxy]` |

Playwright uses the official-marketplace plugin rather than a `.mcp.json` entry. It runs the same `npx @playwright/mcp@latest` command Playwright's own docs give, and keeps `.mcp.json` empty.

## Enabling the plugins (once per repo, any OS)

Run from the repo root. These write `extraKnownMarketplaces` and `enabledPlugins` into `.claude/settings.json`, which is committed, so this is a one-time step for the repo, not per host:

```bash
claude plugin marketplace add MemPalace/mempalace --scope project
claude plugin marketplace add projectsaibg/omniroute-claude-plugin --scope project
claude plugin install frontend-design@claude-plugins-official --scope project
claude plugin install playwright@claude-plugins-official --scope project
claude plugin install mempalace@mempalace --scope project
claude plugin install omniroute@omniroute-claude-plugin --scope project
```

After that, a fresh clone on another host prompts to trust the two extra marketplaces on first launch. To turn a plugin off on one host only, set it to `false` under `enabledPlugins` in that host's gitignored `.claude/settings.local.json`. A `false` in `~/.claude/settings.json` is overridden by the project file.

## Per-host runtimes

The plugins only declare the integrations. Each host still needs the runtimes from the table. The commands are listed per OS below. Only the macOS ones have been run so far (2026-10-16).

### macOS

```bash
brew bundle                                   # Brewfile now includes node
uv tool install mempalace
uv tool install --python 3.12 "headroom-ai[proxy]"
npm install -g omniroute
```

The `--python 3.12` is needed because uv otherwise picks the system Python 3.9, and `headroom-ai` publishes wheels for 3.10 and up only.

### Debian (`dell-optiplex`) and the Pi (aarch64)

Node 20+ is required. Debian 13 (trixie) ships `nodejs` 20.x in its main repo, but Debian 12 ships 18, which is too old, so on bookworm install Node from NodeSource instead. `uv` installs to `~/.local/bin` without sudo:

```bash
sudo apt install nodejs npm                   # trixie; check `node --version` >= 20
curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install mempalace
uv tool install --python 3.12 "headroom-ai[proxy]"
npm install -g --prefix ~/.local omniroute    # avoids a root-owned global prefix
```

Google publishes no Chrome build for Linux arm64, so on the Pi Playwright's default `chrome` channel has nothing to drive. Pi also runs without a display. Override the plugin's server there with a local-scope entry that uses Firefox headless, and disable the plugin copy in `.claude/settings.local.json`:

```bash
claude mcp add --scope local playwright -- npx -y @playwright/mcp@latest --browser=firefox --headless
```

Then, in a session, ask Claude to call the server's `browser_install` tool once. That downloads the Firefox build matching the `playwright-core` version `@playwright/mcp` pins. A separate `npx playwright install` can fetch a different build that the server won't find. Firefox's system libraries may still need `sudo apt` installs. This Pi variant is written from Playwright's documented flags and has not been run on the Pi yet.

### Windows (Git Bash)

```bash
winget install OpenJS.NodeJS.LTS
winget install astral-sh.uv
uv tool install mempalace
uv tool install --python 3.12 "headroom-ai[proxy]"
npm install -g omniroute
```

MemPalace's hooks run as `bash "${CLAUDE_PLUGIN_ROOT}/hooks/…sh"`, so Git Bash's `bash.exe` must be on `PATH`, which it already is for Claude Code on Windows. Current Claude Code docs give `npx` directly as the Playwright command with no `cmd /c` wrapper. If the server shows "Connection closed" on Windows anyway, add a local-scope override that uses `cmd /c npx -y @playwright/mcp@latest`.

## After install: per-plugin setup

**MemPalace.** Run `/mempalace:init` once in a session to create the palace and onboard. To index this repo's past sessions, run `mempalace mine ~/.claude/projects/ --mode convos`. The palace is local: config at `~/.mempalace/config.json`, ChromaDB plus an SQLite knowledge graph, and the embedding model downloads about 300 MB on first use. The plugin's Stop hook saves every 15 messages, PreCompact saves before compaction, and SessionEnd does one last save in the background.

**OmniRoute.** The plugin only points Claude Code at `http://localhost:20128/api/mcp/stream`. Nothing works until `omniroute` is running in its own terminal. Two things were observed on the macOS test start (2026-10-16):

- The MCP endpoint answers `401` without credentials. Create an API key in the dashboard at `http://localhost:20128`, then follow the plugin README's instruction to add an `Authorization: Bearer <token>` header. Do that in a local copy of the plugin, never in a committed file.
- It binds `0.0.0.0` with no API-key requirement by default. Start it as `OMNIROUTE_SERVER_HOST=127.0.0.1 omniroute` (or set `REQUIRE_API_KEY=true`) so other devices on the LAN can't spend through your configured providers.

The marketplace repo is a single-commit third-party wrapper, with one star and a placeholder `repository` field. Its whole content was read before enabling: one `mcpServers` URL, no hooks, commands or code.

**Headroom.** This reverses the 2026-10-11 retirement, which is recorded in `docs/archival.md`. Headroom works by setting `ANTHROPIC_BASE_URL` to its local proxy. While that setting is in place and the proxy isn't running, every Claude request fails instead of going direct. For that reason it is not enabled on any host by default. To use it for this repo only, from a terminal in the repo root:

```bash
headroom wrap vscode-claude --settings-file .claude/settings.local.json
```

Then reload the VS Code window and keep that terminal open. Check it with `curl http://127.0.0.1:8787/health`. To undo, run `headroom unwrap vscode-claude --settings-file .claude/settings.local.json`. For the terminal CLI instead of VS Code, `headroom wrap claude` starts the proxy and launches `claude` together. The project-local `--settings-file` target is untested. Headroom's docs only show the default user-level file.
