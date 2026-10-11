# Raspberry Pi 5 host — Claude Code setup

This documents the Claude Code CLI environment on the Raspberry Pi 5 host
(`raspberrypi`, `192.168.0.166`, Debian `forky/sid`, `aarch64`, user `pi`) —
the same box that runs AdGuardHome (see `docs/handoff.md`'s 2026-08-27 entry).
It sits alongside `docs/debian-host-claude-setup.md`, the `dell-optiplex`
Debian desktop (`apt` / x86-64, user `kartik`).

Don't conflate the two. Same repo, same overall shape (Claude Code CLI +
`uv`), but different arch and different install mechanics. Everything below
was verified against this host's actual state (`command -v`, `uv tool list`),
not assumed.

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

## 2. Core tooling

All user-scope, all on `PATH` via `/home/pi/.local/bin` (already in the login
`PATH`, no profile edit needed).

| Tool | Version | Install |
|---|---|---|
| `claude` (Claude Code) | 2.1.258 | `curl -fsSL https://claude.ai/install.sh \| bash` — native build, `~/.local/bin/claude` |
| `uv` | 0.12.9 | `curl -LsSf https://astral.sh/uv/install.sh \| sh` — provides `uv` + `uvx` |
| `node` | v24.19.0 | pre-existing (system) |

## 3. Verification — results as run

| Check | Result |
|---|---|
| `claude --version` / `uv --version` | `2.1.258` / `0.12.9` |

## 4. Repo linting toolchain

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

## Status

Done and verified on 2026-09-02 (see §3 for the actual command output).

- **§2 core tooling** — `claude` 2.1.258 and `uv` 0.12.9, both user-scope on
  `PATH`.
- **§4 linting** — `ruby` 3.3.8 + `mdl` 0.18.1 + `shfmt` 3.14.0 installed,
  `shellcheck` already present (8 shell scripts clean), `core.hooksPath` wired,
  `~/.bashrc` PATH line added. `./lint-markdown.sh` passes clean repo-wide.
