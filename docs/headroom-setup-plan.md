# Headroom Setup on Windows 11

## Context

Headroom is a local compression proxy that sits between your coding agents and the LLM provider: it shrinks tool outputs, logs, and file reads before they reach the model, and it keeps a shared, deduplicated memory across whichever agents you run. It's a Python/Rust project (repo: `headroomlabs-ai/headroom`), installed as a CLI, not something winget carries directly.

It maps onto your setup more directly than a generic tool would. You already run Claude Code CLI and the VS Code extension (confirmed working per `docs/vscode-integration-plan.md`), and you already maintain a shared-instructions pattern across agents with `AGENTS.md` as the source of truth and `CLAUDE.md`/`GEMINI.md` as one-line pointers into it. Headroom's cross-agent memory and its `headroom learn` correction-mining work the same way in spirit: one shared context instead of per-agent silos. This plan wires Headroom into what you have running today (Claude Code CLI, Claude Code in VS Code) and treats everything else (Codex, Gemini, Copilot, Docker) as later phases, only if you end up actively using those tools.

This document is the plan, not a completed install. I can't run PowerShell on your machine from this session, so every command below is something you run yourself; I've written it as a checklist you can work through and mark up.

## Phase 1: Prerequisites

Confirm Python is on your machine and pinned to a version Headroom's prebuilt wheels support (3.10 through 3.13; 3.13 specifically if you want the dashboard's dollar-savings figure to work, since the pricing library it uses, LiteLLM, doesn't install on 3.14+):

```powershell
python --version
```

If it's missing or on the wrong version:

```powershell
winget install Python.Python.3.13
```

Headroom's release pipeline now publishes a prebuilt `win_amd64` wheel (built with `maturin-action` against the MSVC toolchain GitHub's Windows runners already ship), so a plain `pip install` or `uv tool install` should not need a local Rust or Visual Studio Build Tools install on Windows in the common case. Keep Phase 8's troubleshooting section in mind if the install falls back to building from source instead of pulling that wheel; that's the one path where a local toolchain matters.

## Phase 2: Install the `uv` tool runner (recommended) or use `pip`

Headroom's own docs recommend `uv tool install` for the CLI specifically, since it runs in an isolated environment and won't collide with any Python packages you already have. If you don't have `uv`:

```powershell
winget install astral-sh.uv
```

Then install Headroom:

```powershell
uv tool install --python 3.13 "headroom-ai[all]"
```

If `uv tool update-shell` hasn't already put its tool directory on PATH, run it once:

```powershell
uv tool update-shell
```

Prefer staying inside `pip` instead? That works too, and still gives you the `headroom` CLI:

```powershell
pip install "headroom-ai[all]"
```

Either way, confirm:

```powershell
headroom --version
```

## Phase 3: Health check before touching any agent

```powershell
headroom doctor
```

This confirms content routing (JSON/code/text compressors) is wired up correctly before you point a live agent at it. If it reports the ONNX-backed features (content detection, embedding relevance) fell back to non-ONNX paths, that's expected on hosts without AVX2 and not a failure, Headroom degrades gracefully rather than erroring.

## Phase 4: Wrap Claude Code CLI

```powershell
headroom wrap claude
```

This starts a local proxy and launches a `claude` session configured to route through it. Two side effects worth knowing before you run it:

It installs **Serena** (semantic code navigation) as an MCP server registered at **user scope**, meaning it becomes available in every Claude Code project you open, not just this one, until you run `headroom unwrap claude`. If you'd rather it stay scoped to sessions where you explicitly want it, add `--code-memory none` to skip Serena entirely:

```powershell
headroom wrap claude --code-memory none
```

Separately, Headroom can inject a "prefer Serena's symbol tools" instructions block into your project's `CLAUDE.md`, but only if you explicitly opt in with `--serena-instructions` (or `HEADROOM_SERENA_INSTRUCTIONS=1`); it's off by default and leaves `CLAUDE.md` untouched otherwise. Given your `CLAUDE.md` is a deliberate one-line `@AGENTS.md` pointer in every repo, leave this flag off unless you specifically want that block appended, it would land inside the pointer file rather than in `AGENTS.md` itself.

Undo at any point with:

```powershell
headroom unwrap claude
```

## Phase 5: Wrap Claude Code inside VS Code

You already have the "Claude Code for VS Code" extension installed and confirmed signed in. The CLI wrap in Phase 4 covers `claude` typed into a terminal; the extension's chat panel is a separate integration point:

```powershell
headroom wrap vscode-claude
```

Reload the VS Code window once after running it, then keep the wrapper's terminal running while you use the Claude Code panel. The proxy log printed at startup, or `headroom dashboard` in a second terminal, shows requests and savings live. Your Anthropic sign-in and selected model stay exactly as they are, Headroom sits transparently in front of the traffic.

Stop with `Ctrl+C` in the wrapper terminal; restore prior settings fully with:

```powershell
headroom unwrap vscode-claude
```

## Phase 6: Verify it's actually saving tokens

After running a normal Claude Code session or two through the wrapped proxy:

```powershell
headroom perf
headroom dashboard
```

`dashboard` opens a live view (requires the proxy from Phase 4/5 still running); `perf` gives you a point-in-time summary. If the numbers look flat, `headroom doctor` again is the first thing to check, it will flag a routing or detection problem before you go looking elsewhere.

## Phase 7: Cross-agent memory, later, not now

Headroom's shared memory store deduplicates context across Claude, Codex, Gemini, and Grok, which is the same idea behind your `AGENTS.md`/`CLAUDE.md`/`GEMINI.md` convention, one source of truth instead of per-agent drift. But per your own `docs/vscode-integration-plan.md`, Codex and Gemini aren't active parts of your workflow yet, the `GEMINI.md` in your repo root is a template pointer, not evidence of a running Gemini CLI. Wiring up `headroom wrap codex` or `headroom wrap grok` now would be setup with nothing to connect to. Treat this the same way you already treated the Slack/Linear/Jira connectors in the VS Code plan: revisit once one of those CLIs is something you're actually running day to day, not before.

## Phase 8: `headroom learn`, decide the target deliberately

`headroom learn` mines your past sessions for corrections and writes them to an agent-native instructions file. By default that's `CLAUDE.local.md` (gitignored, personal, not shared). You can point it elsewhere:

```powershell
headroom learn --verbosity        # dry run, shows what it would change, writes nothing
headroom learn --target AGENTS.md --apply   # writes into your actual source of truth
```

Given your convention treats `AGENTS.md` as the one file every agent ultimately reads (via the `@AGENTS.md` import from `CLAUDE.md`), a personal `CLAUDE.local.md` sitting alongside it is a second, unlinked file nothing else points to. Worth deciding explicitly rather than leaving on the default: either target `AGENTS.md` directly so learned corrections land in the file that's actually load-bearing, or keep the default `CLAUDE.local.md` if you'd rather review learned corrections yourself before folding anything into `AGENTS.md` by hand. Start with the dry run either way; nothing here needs deciding before you've seen what it would actually propose.

## Phase 9: Skipping for now, and why

**Docker deployment** (`headroom deploy`, which prefers Docker when available, or `docker pull ghcr.io/headroomlabs-ai/headroom:latest` directly): this adds a Docker Desktop and WSL2 dependency for no benefit over the native `uv tool install` path above, given you're running Claude Code natively on Windows already. Worth revisiting only if you specifically want one Headroom instance shared between WSL-side and Windows-side agents, or if Phase 8's troubleshooting section leads you here as a fallback.

**GitHub Copilot CLI / VS Code Copilot wrapping**: not part of your current stack per your own VS Code plan (you declined the connector work and aren't running Copilot). Skip unless that changes.

**Corporate SSL-inspection workarounds** (installing Rust locally, `HEADROOM_TLS_STRICT=0`): only relevant if Phase 2's install fails outright. Covered in the troubleshooting section below rather than as its own phase, since it shouldn't be needed on a normal home or personal machine.

## Verification checklist

Work through this after Phases 1 through 6:

- `headroom --version` prints a version number.
- `headroom doctor` reports healthy content routing, no unresolved errors.
- `headroom wrap claude` starts cleanly, and a normal `claude` session in that terminal behaves exactly as before (same sign-in, same model), just proxied.
- `headroom wrap vscode-claude` survives a VS Code window reload, and the Claude Code panel still responds normally.
- `headroom dashboard` or `headroom perf` shows non-zero token savings after a real session, not just an idle proxy.
- `headroom unwrap claude` and `headroom unwrap vscode-claude` both cleanly restore your prior configuration, tested at least once so you know the rollback path works before you rely on it day to day.

## Troubleshooting appendix

**`CERTIFICATE_VERIFY_FAILED` / "unable to get local issuer certificate" during install**: your network is doing SSL inspection (a corporate MITM proxy with its own CA), and the build backend is trying to fetch Rust over a connection your TLS stack doesn't trust. Install Rust first so nothing needs to fetch it mid-build:

```powershell
winget install Rustlang.Rustup
rustup default stable
```

Restart your shell, then retry the Phase 2 install. Alternatively, force the prebuilt wheel and skip any source build entirely: `pip install --only-binary headroom-ai headroom-ai`.

**"Basic Constraints of CA cert not marked critical"**: a different failure from the one above, this means your corporate CA *is* trusted, but Python 3.13's stricter TLS mode (`VERIFY_X509_STRICT`) is rejecting it on a technicality some inspection proxies (Zscaler-style) get wrong. Fix: `HEADROOM_TLS_STRICT=0 headroom proxy --port 8787`. On Windows the corporate root also needs to be in the **machine** certificate store, not just the user store, for the separate Rust-side ONNX download to trust it.

**Build-from-source errors mentioning `esaxx-rs`, `tokenizers`, or `ort-sys`**: the project's own CI notes an unresolved upstream Windows linkage conflict between two of Headroom's Rust dependencies (conflicting MSVC C runtime settings, `/MT` vs `/MD`) that can surface if your install falls back to compiling from source instead of using the prebuilt wheel from Phase 1. This shouldn't come up in the normal case, but if it does, `docker pull ghcr.io/headroomlabs-ai/headroom:latest` sidesteps it entirely, and it's worth a quick check of open issues on `github.com/headroomlabs-ai/headroom` for current status before spending time on a local fix.

## Open decisions for you

1. **Serena at user scope** (Phase 4): keep it available across all your Claude Code projects (default), or scope it out with `--code-memory none`. Your call, no wrong answer, just worth deciding rather than defaulting into it.
2. **Serena instructions in `CLAUDE.md`** (Phase 4): recommend leaving `--serena-instructions` off, given your pointer-file convention. Revisit only if you want that guidance block explicitly.
3. **`headroom learn` target** (Phase 8): default `CLAUDE.local.md` vs `--target AGENTS.md`. Recommend running the dry run first, then deciding once you've seen what it actually finds.
4. **Docker vs native** (Phase 9): native is the right default for your setup today; nothing here needs deciding unless your usage changes.
5. **Output token shaping** (`HEADROOM_OUTPUT_SHAPER=1`, mentioned in the repo's README): off by default, worth trying once Phases 1 through 6 are confirmed working, it trims what the model writes back, not just what you send it, and Opus-class output tokens cost five times input.

## Status

Done through Phase 6, plus Phase 8's dry run applied. Phase 7 and Phase 9 are intentionally deferred/skipped as the plan itself recommends. Evidence below, not just "done."

- **Phase 1 (prerequisites)**: done. Python 3.13.15 confirmed on PATH; `uv` installed.
- **Phase 2 (install)**: done. `headroom --version` reports 0.36.2, installed via `uv tool install` at `~/.local/bin/headroom.exe`.
- **Phase 3 (doctor)**: passes. Latest run: `0 failure(s), 4 warning(s)` — all four are expected/informational, not fixable by config: `codex` unrouted (Codex isn't part of this workflow, per Phase 7), no spend budget configured, the Claude "remote control" client-side gate that's disabled whenever any custom `ANTHROPIC_BASE_URL` is set (not Headroom-specific), and Claude Desktop bypassing the proxy (unsupported upstream, terminal/VS Code CLI only).
- **Phase 4 (wrap Claude Code CLI)**: done. `.claude/.headroom_wrap_marker.json` shows a live wrap (pid 2468, port 8787); this session itself is routed through it and `headroom_stats`/`headroom perf` show real compression on it. **Open decision 1** resolved as-is: Serena installed at user scope (default, in `~/.claude.json`'s top-level `mcpServers`), available across all projects. **Open decision 2** resolved: `--serena-instructions` was not used — `CLAUDE.md` has no injected Serena block, staying a clean `@AGENTS.md` pointer as intended.
- **Phase 5 (wrap VS Code Claude Code)**: done. `headroom wrap vscode-claude` ran and wrote the proxy config into `~/.claude/settings.json` (global user scope): `ANTHROPIC_BASE_URL: http://127.0.0.1:8787/p/Github`. **Kartik still needs to reload the VS Code window himself** to pick this up — that step can't be done from this session.
- **Phase 6 (verify savings)**: done. `headroom perf` this session: 92 requests, 4,665,320 → 4,579,696 tokens, 698,615 tokens saved (13.2% reduction), cache hit rate 93.8%. Non-zero, consistent with a live, working proxy rather than an idle one.
- **Phase 7 (cross-agent memory)**: correctly not started. Codex and Gemini aren't active parts of the workflow yet (per `docs/vscode-integration-plan.md`); revisit once one of those CLIs is in daily use.
- **Phase 8 (`headroom learn`)**: dry run completed, findings applied. **Open decision 3** resolved: after seeing the dry-run output, Kartik chose `--target AGENTS.md --apply` over the default `CLAUDE.local.md`, since `AGENTS.md` is the actual load-bearing file every agent reads. `headroom learn --target AGENTS.md --apply` ran and appended a `<!-- headroom:learn:start -->…<!-- headroom:learn:end -->` block to `AGENTS.md` documenting two learned patterns (Git Bash `tasklist`/`wmic` quirks, and three Headroom CLI quirks: `doctor`'s exit-code-1-on-warnings-only behavior, `learn --verbosity` being a separate feature from correction mining, and `headroom config` not being a valid subcommand).
- **Phase 9 (Docker/Copilot/SSL workarounds)**: correctly skipped, nothing applicable. **Open decision 4** resolved as-is: native install is the right fit, no Docker needed.
- **Open decision 5 (`HEADROOM_OUTPUT_SHAPER`)**: tried, and live. Added to `.claude/settings.local.json`'s `env` block for future sessions, and separately pushed live to the already-running proxy this session (`headroom wrap vscode-claude` with the var set, which reuses the running proxy and hot-syncs runtime knobs via `/admin/runtime-env` — confirmed via `curl http://127.0.0.1:8787/health` showing `"HEADROOM_OUTPUT_SHAPER":"1"` under `runtime_env`). Re-ran `headroom doctor` afterward: still `0 failure(s)`, no new warnings introduced. One caveat worth knowing: the `wrap selfheal` command that runs as this project's `SessionStart` hook only recovers a stale `ANTHROPIC_BASE_URL` — it does not push runtime-env knobs to the proxy. So the settings.local.json env var travels with the project, but actually *activating* the shaper on a fresh proxy start still requires running a `headroom wrap <tool>` command (not just relying on the hook) with the var set in that shell.

**Still open**: reload VS Code to pick up Phase 5 (Kartik's step). Everything else in this checklist through Phase 8 is verified against actual tool output, not assumed.
