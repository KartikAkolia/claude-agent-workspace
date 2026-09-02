# Raspberry Pi 5 host — Claude Code + Headroom setup

This documents the Claude Code CLI environment on the Raspberry Pi 5 host
(`raspberrypi`, `192.168.0.166`, Debian `forky/sid`, `aarch64`, user `pi`) —
the same box that runs AdGuardHome (see `docs/handoff.md`'s 2026-08-27 entry).
It is the third host-specific setup record, alongside:

- `docs/headroom-setup-plan.md` — the Windows 11 machine (`winget` / PowerShell).
- `docs/debian-host-claude-setup.md` — the `dell-optiplex` Debian desktop
  (`apt` / x86-64, user `kartik`).

Don't conflate the three. Same repo, same overall shape (Claude Code CLI +
`uv` + Headroom + Serena), but different arch and different install mechanics.
Everything below was verified against this host's actual state
(`command -v`, `uv tool list`, `headroom doctor`, `systemctl --user`), not
assumed.

## 1. Host facts

| | |
|---|---|
| Model | Raspberry Pi 5 Model B Rev 1.0 (Cortex-A76 ×4, 8 GB RAM) |
| OS | Debian GNU/Linux `forky/sid`, kernel `6.18.x-rpt-rpi-2712`, `aarch64` |
| User / home | `pi` / `/home/pi` |
| Also runs | AdGuardHome (DNS, port 853/DoH), Docker daemon |
| `sudo` | password required; one `NOPASSWD` rule only (a sysctl) — apt installs need Kartik's password |
| Root FS | NVMe (`/dev/nvme0n1p2`), ~205 GB free |
| `loginctl` linger | `Linger=yes` for `pi` — `--user` services run without an active login and survive reboot |

No AVX2 (ARM NEON only). Headroom's ONNX / embedding-backed relevance
features degrade to non-ML paths here; that is expected and not a failure,
same as the Windows plan's Phase 3 note.

## 2. Core tooling

All user-scope, all on `PATH` via `/home/pi/.local/bin` (already in the login
`PATH`, no profile edit needed).

| Tool | Version | Install |
|---|---|---|
| `claude` (Claude Code) | 2.1.258 | `curl -fsSL https://claude.ai/install.sh \| bash` — native build, `~/.local/bin/claude` |
| `uv` | 0.12.9 | `curl -LsSf https://astral.sh/uv/install.sh \| sh` — provides `uv` + `uvx`, needed by both MCP servers below |
| `node` | v24.19.0 | pre-existing (system) |
| `headroom` | 0.37.0 | `uv tool install` — see §4 |

## 3. Serena MCP server (semantic code navigation)

Serena is wired **project-scoped**, not user-scoped, via a tracked
`.mcp.json` at the repo root (`/home/pi/claude-agent-workspace/.mcp.json`):

```json
{
  "mcpServers": {
    "serena": {
      "command": "uvx",
      "args": [
        "--from", "git+https://github.com/oraios/serena",
        "serena", "start-mcp-server",
        "--context", "ide-assistant",
        "--project", "/home/pi/claude-agent-workspace",
        "--open-web-dashboard", "false"
      ]
    }
  }
}
```

`uvx` fetches Serena on first run (no separate install). Verified: MCP
`initialize` handshake succeeds, 22 tools exposed
(`find_symbol`, `find_referencing_symbols`, `replace_symbol_body`, …), Python
language server (`pyright`) starts. On first Claude Code start after this file
appears, the session prompts once to trust the new server.

This deliberately differs from `dell-optiplex`, where Serena is registered at
user scope in `~/.claude.json` (the default that `headroom wrap claude`
installs). Here Headroom is wrapped with `--code-memory none` so it does **not**
manage Serena, and the project `.mcp.json` owns it instead — scoped to this
repo, version-controlled, nothing leaks into other projects.

## 4. Headroom (local compression proxy)

### 4.1 Install — slim, not `[all]`

`headroom-ai[all]` pulls `torch` / `transformers` / `onnxruntime` /
`sentence-transformers` (~6.4 GB) for relevance features that are inert on
this ARM host. Installed the slim extra set instead:

```sh
uv tool install --python 3.13 "headroom-ai[proxy,code,mcp,reports]"
```

- `proxy` — the FastAPI/uvicorn proxy server (without this, `headroom wrap`
  fails with `No module named 'fastapi'` — the error hit on the first attempt
  here, when plain `headroom-ai` was installed).
- `code` — tree-sitter AST-aware compression (`--code-aware`).
- `mcp` — `headroom mcp serve`, the in-session `headroom_retrieve` tool.
- `reports` — `headroom perf` / dashboard summaries.

Confirmed: `uv tool list` shows `headroom-ai v0.37.0`; `headroom --version`
prints `0.37.0`. The venv at `~/.local/share/uv/tools/headroom-ai` dropped from
**6.4 GB** (`[all]`) to **677 MB** — `torch`, `sentence-transformers` and
`ast-grep-cli` are gone; `fastapi`, `uvicorn` and `tree_sitter` are present.
(`transformers` / `onnxruntime` still come in as transitive deps of the
tokenizer stack but are not exercised on this ARM host.)

### 4.2 Persistent systemd `--user` service

Rather than running `headroom wrap claude` per shell, Headroom is installed as
a persistent `--user` service (same model as `dell-optiplex`), so every
terminal `claude` session on this host is proxied automatically:

```sh
headroom install apply \
  --preset persistent-service \
  --runtime python \
  --scope provider \
  --providers manual --target claude \
  --port 8787 \
  --backend anthropic \
  --code-aware \
  --no-telemetry
```

- `--scope provider` writes an `env` block into `~/.claude/settings.json`.
  **Do not use `--scope user`** — it only writes shell-rc blocks and silently
  skips Claude Code's own settings (the bug hit on `dell-optiplex`, see
  `docs/handoff.md` 2026-08-27). Result here:

  ```json
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
    "ENABLE_TOOL_SEARCH": "true"
  }
  ```

  `ENABLE_TOOL_SEARCH` is added by `headroom install apply` as well — it turns
  on Claude Code's on-demand tool loading, which the base-URL gate would
  otherwise suppress (see §5).
- `--backend anthropic` — upstream is `https://api.anthropic.com` directly.
  This Pi has no CLIProxyAPI instance; if one is added later, re-apply with
  `--backend` pointed at it plus `--env ANTHROPIC_TARGET_API_URL=…` /
  `ANTHROPIC_TARGET_API_HEADERS=…`, as on `dell-optiplex`.
- No `--memory` — cross-agent memory stays off (nothing else to share with).

What it created:

- `~/.config/systemd/user/headroom-default.service` (`Type=simple`,
  `Restart=on-failure`, `WantedBy=default.target`), symlinked into
  `default.target.wants/` — so with `Linger=yes` it starts on boot.
- `~/.headroom/deploy/default/run-headroom.sh` — the `ExecStart` wrapper;
  exports `HEADROOM_PORT/HOST/MODE/BACKEND/TELEMETRY` then
  `exec headroom install agent run --profile default`.

Manage it with `headroom install {status,restart,stop,start,remove}` or
`systemctl --user {status,restart,stop} headroom-default.service`.

### 4.3 `headroom` MCP server in-session

The project `.mcp.json` also registers the Headroom MCP server, which exposes
`headroom_retrieve` — Claude calls it to pull back full content sitting behind
a compression marker when it needs the detail:

```json
"headroom": {
  "command": "headroom",
  "args": ["mcp", "serve"]
}
```

Verified with an MCP `initialize` handshake: `serverInfo.name = "headroom"`,
version `1.29.1`. `headroom unwrap claude` removes any user-scope copy of this
server; the project `.mcp.json` entry is independent of the wrap lifecycle.

## 5. Known tradeoffs of a custom `ANTHROPIC_BASE_URL`

Claude Code 2.1.258 gates three features on the base URL being the stock
endpoint. `headroom doctor` reports all three as warnings, not errors:

- **Remote Control (`/rc`)** is disabled outright — Headroom cannot override
  this client-side gate. For a session that needs `/rc`, run `claude` without
  the proxy (`headroom install stop`, or unset `ANTHROPIC_BASE_URL` for that
  shell).
- **On-demand tool loading** would also be suppressed; the `ENABLE_TOOL_SEARCH`
  env var written in §4.2 restores it (upstream issue #746).
- **1M context window** is off by default behind the same gate (upstream
  #1158); opt back in per session with `headroom wrap claude --1m` if needed.

Same behaviour as `dell-optiplex`; accepted here for the compression benefit.

The Claude **desktop app** ("Code" tab) bypasses the proxy entirely
(unsupported upstream — terminal / VS Code CLI only). Desktop-app sessions on
this host are not and cannot be compressed by Headroom.

## 6. Verification — results as run

| Check | Result |
|---|---|
| `claude --version` / `uv --version` / `headroom --version` | `2.1.258` / `0.12.9` / `0.37.0` |
| `headroom install status` | profile `default`, `persistent-service`, scope `provider`, port 8787, **Status: running, Healthy: yes** |
| `systemctl --user is-active headroom-default.service` | `active` (and `is-enabled` → `enabled`) |
| `~/.claude/settings.json` | `env.ANTHROPIC_BASE_URL = http://127.0.0.1:8787` present |
| `curl -s http://127.0.0.1:8787/livez` / `/readyz` | `200` / `200` |
| `headroom doctor` | **0 failures, 4 warnings** — `codex` unrouted, shell-env not exported, no spend budget, `/rc` gate. All expected/informational. |
| `headroom doctor` savings row | `✓ pass` — small non-zero lifetime saving already recorded, proxy is serving real traffic |
| `headroom mcp serve` MCP handshake | `initialize` OK, `serverInfo` = `headroom 1.29.1` |

Still requires a human action: the **trust prompt** for the `serena` and
`headroom` servers on the next `claude` start in this repo (project `.mcp.json`
servers are approved once, interactively).

## 7. Repo linting toolchain

Linting is mandatory before any commit here — `.githooks/pre-commit` and
`.github/workflows/lint.yml` both run the same scripts, so a missing tool means
a broken hook or a red CI check. What the pipeline actually invokes
(`./lint-markdown.sh` → `mdl`, `check-markdown-links.py`, `validate-config.sh`):

| Tool | Purpose | State on this Pi |
|---|---|---|
| `python3` | `check-markdown-links.py` (dead cross-refs), `validate-config.sh` JSON | present (`/usr/bin/python3`, 3.13) |
| `shellcheck` | shell-script lint (`*.sh` kept clean per README) | present (`/usr/bin/shellcheck`) |
| `shfmt` | shell formatting helper (not in the enforced pipeline) | installed `v3.14.0` via `GOBIN=~/.local/bin go install mvdan.cc/sh/v3/cmd/shfmt@latest` |
| `ruby` | `validate-config.sh` YAML parse + prerequisite for `mdl` | installed `3.3.8` (`sudo apt install ruby`) |
| `mdl` | markdown style (`.mdlrc` / `.mdl_style.rb`) | installed `0.18.1` (`gem install --user-install mdl`) → `~/.local/share/gem/ruby/3.3.0/bin` |

Also done: `git config core.hooksPath .githooks` (the hook was not wired up on
this clone), and a self-healing line appended to `~/.bashrc` that puts the Ruby
user-gem bin dir on `PATH`:

```sh
command -v ruby >/dev/null 2>&1 && export PATH="$(ruby -e 'puts Gem.user_dir')/bin:$PATH"
```

Verified: `./lint-markdown.sh` exits `0` across the whole repo (`mdl` +
`check-markdown-links.py` + `validate-config.sh`), and a fresh interactive
shell resolves `mdl` via the `~/.bashrc` line — so the pre-commit hook finds
it.

## 8. Rollback

```sh
headroom install remove          # stop + delete the service, revert managed config
uv tool uninstall headroom-ai    # remove the CLI entirely
```

`headroom install remove` restores `~/.claude/settings.json` to its
pre-`apply` state (removes the injected `env.ANTHROPIC_BASE_URL`). The
project `.mcp.json` (Serena, Headroom MCP) is separate — delete those entries
by hand if you want them gone.

## Status

Done and verified end to end on 2026-09-02 (see §6 for the actual command
output).

- **§2 core tooling** — `claude` 2.1.258, `uv` 0.12.9, `headroom` 0.37.0, all
  user-scope on `PATH`.
- **§3 Serena** — project-scoped `.mcp.json` written; MCP `initialize`
  handshake verified (22 tools, `pyright` LS starts).
- **§4.1 slim install** — done. `headroom-ai[proxy,code,mcp,reports]`, venv
  6.4 GB → 677 MB.
- **§4.2 persistent service** — done. `headroom-default.service` is `active` +
  `enabled`; `ANTHROPIC_BASE_URL` (+ `ENABLE_TOOL_SEARCH`) written to
  `~/.claude/settings.json`; `/livez` + `/readyz` return `200`;
  `headroom doctor` clean (0 failures).
- **§4.3 Headroom MCP entry** — done. Added to `.mcp.json`; handshake verified.

Sequencing note: the earlier manual `headroom wrap claude --code-memory none`
(used to smoke-test the proxy) was torn down first with `headroom unwrap
claude` — it held port 8787 and ran off the pre-slim venv. The persistent
service replaces it; `headroom wrap` is no longer needed per shell on this
host.

Open, by design:

- The one-time **trust prompt** for `serena` + `headroom` on the next `claude`
  start in this repo.
- **Linting** — done. `ruby` 3.3.8 + `mdl` 0.18.1 + `shfmt` 3.14.0 installed,
  `shellcheck` already present (8 shell scripts clean), `core.hooksPath` wired,
  `~/.bashrc` PATH line added. `./lint-markdown.sh` passes clean repo-wide.
  See §7.
- No spend budget on the proxy (`headroom doctor` warns). Set one with
  `headroom proxy --budget N` / `HEADROOM_BUDGET` if wanted.
