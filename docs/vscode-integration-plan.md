# Bringing This Session's Setup into VS Code

## Context

Everything set up so far, the Engineering and Productivity plugins, the connectors, the AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md templates, the productivity dashboard, lives inside this Cowork session. None of it automatically appears in VS Code. Cowork and Claude Code (the CLI and its VS Code extension) are separate products that happen to share some underlying mechanics, so the honest starting point is knowing which pieces genuinely carry over and which need to be rebuilt on the Claude Code side.

Two systems, not one: Cowork's plugins (Engineering, Productivity) and the connectors searched through `SearchMcpRegistry` in this chat belong to Cowork's own catalog. Claude Code CLI has its own separate MCP configuration (`claude mcp add`) and its own skills/plugins system. A connector being live here doesn't make it live in VS Code, and a `/engineering:*` skill working here doesn't mean it exists as a `claude` command. Each piece below is either "reconnect this the Claude Code way" or "this doesn't transfer, here's the equivalent."

## Phase 1: Install Claude Code on Windows

Two separate installs, both needed:

The VS Code extension gives you the graphical panel, inline diffs, and @-mentions inside the editor. Requires VS Code 1.94.0 or higher and a paid Claude subscription (Pro, Max, Team, or Enterprise, no API key needed). Install it by pressing `Ctrl+Shift+X` in VS Code, searching "Claude Code," and clicking Install, or by opening `vscode:extension/anthropic.claude-code` directly. First launch prompts a browser sign-in.

The standalone CLI is what actually runs `claude` in VS Code's integrated terminal, the extension bundles its own copy for the chat panel only, it won't respond to `claude` typed at a terminal prompt. Install it with:

```powershell
winget install Anthropic.ClaudeCode
```

Confirm both are working: open VS Code, look for the Spark icon in the editor toolbar (extension), then open an integrated terminal and run `claude --version` (CLI).

## Phase 2: Carry the AGENTS.md pattern into your repos

The templates already sitting in `Github\claude-agent-templates\` map directly onto Claude Code's own conventions, with one naming detail to get right. Claude Code's native per-repo entry point is `CLAUDE.md`, not `AGENTS.md` directly. The pattern from titus-ai's own repos handles this with a one-line pointer:

```
@AGENTS.md
```

Drop that as `CLAUDE.md` at the repo root, keep the real content in `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md` exactly as templated. Claude Code reads the `@file` import and pulls AGENTS.md in automatically at session start, so you get the same "how to work here" instructions whether you're driving Claude Code, Codex, or Gemini against the same repo, one shared source, three pointer files.

Do this for each real repo, not just once: `dwm-titus`, `linutil`, `website`, `winutil`, and `titus-ai` already have this exact structure (that's where the templates came from), so for your own projects, copy the six template files from `claude-agent-templates\` in, fill in the brackets, and add the one-line `CLAUDE.md`.

## Phase 3: Reconnect the connectors that matter, the Claude Code way

Of what's connected or available in this Cowork session, GitHub, Notion, and Asana have official Claude Code MCP integrations with real documented commands. Run these from a terminal inside the relevant repo (or add `--scope user` to make a server available across every project instead of just one):

```powershell
# GitHub — needs a fine-grained personal access token from
# https://github.com/settings/personal-access-tokens
claude mcp add --transport http github https://api.githubcopilot.com/mcp/ `
  --header "Authorization: Bearer YOUR_GITHUB_PAT"

# Notion
claude mcp add --transport http notion https://mcp.notion.com/mcp

# Asana
claude mcp add --transport sse asana https://mcp.asana.com/sse
```

For a server you want your whole team to share, add `--scope project` instead of the default local scope. That writes the (non-secret) connection details to `.mcp.json` at the repo root, which you commit, so anyone who clones the repo and runs Claude Code gets the same server offered automatically.

Slack, Linear, and Jira/Confluence (Atlassian Rovo) don't have a documented one-line `claude mcp add` example the way GitHub/Notion/Asana do, but they're MCP servers like any other; if you want them in Claude Code too, the general syntax is `claude mcp add --transport http <name> <url>`, and their setup pages (or the Anthropic connector directory at claude.ai/directory) will have the URL and any auth header needed. Treat this as a "when you actually need it" task rather than something to front-load.

Gmail and Google Calendar are already connected in this Cowork chat but weren't found to have a documented Claude Code MCP path in the research for this plan, worth a quick check against the connector directory before assuming one exists.

## Phase 4: Engineering plugin skills — rebuild, don't expect a transfer

`/engineering:architecture`, `/engineering:code-review`, `/engineering:documentation` (the skill that structured this very document), and the rest are Cowork-specific, they won't appear as `claude` commands just because the plugin is installed here. Two honest paths forward, and this is a genuine judgment call rather than something with one right answer:

Recreate the ones you actually use as Claude Code skills. Claude Code supports the same `SKILL.md` convention titus-ai uses for its own skill library (a folder with a `SKILL.md`, optional `references/` and `scripts/`), placed under `.claude/skills/<name>/` in a repo for project scope or `~/.claude/skills/<name>/` for every project. If code review or architecture-decision-record writing is something you lean on daily, this is worth the twenty minutes it takes to port.

Or skip formalizing it, and just prompt Claude Code directly ("review this PR for security and correctness issues," "write an ADR comparing these two approaches"). The skill mostly encodes structure Claude already knows reasonably well without it; formalizing it as a reusable `SKILL.md` pays off when you find yourself typing the same long instructions repeatedly, not before.

## Phase 5: The productivity dashboard stays where it is

`dashboard.html`, `TASKS.md`, and the `CLAUDE.md` inside `Github\productivity\` are a Cowork productivity-skill artifact, a browser-based kanban board, not a VS Code feature. Two things worth flagging rather than quietly leaving ambiguous:

That `CLAUDE.md` (inside `productivity\`) and the `CLAUDE.md` you're about to create per-repo in Phase 2 are unrelated files that happen to share a name, one is Cowork's productivity-skill memory (people, projects, your research preferences), the other is Claude Code's per-repo working instructions. Nothing to reconcile between them, just don't confuse one for the other if you're browsing folders later.

There's no VS Code-native equivalent worth building for the dashboard itself, it's not something Claude Code needs or reads. Keep opening it in a browser tab alongside VS Code, that's the intended workflow, no migration needed here.

## Verification checklist

Before considering this done: `claude --version` runs in VS Code's integrated terminal. The Spark icon opens the extension panel and you're signed in. Opening any of the five ChrisTitusTech-pattern repos in VS Code and asking Claude a question about the codebase gets an answer that reflects the AGENTS.md conventions (a sign the `@AGENTS.md` import is being read). `claude mcp list` shows github/notion/asana (whichever you actually configured) as connected, not failed. If you added any server with `--scope project`, `.mcp.json` exists at the repo root and is staged for commit.

## Open decisions for you

Resolved (2026-08-21): Phase 3 connectors (GitHub, Notion, Asana) are declined for now, not wired up. Revisit only if a real need for one of them comes up; see Status below.

Resolved (2026-08-21): Phase 2's target repo is this `Github` root (already scaffolded via Phase 5). Phase 4 (porting Engineering-plugin skills into `.claude/skills/`) is done, see Status below for what was ported vs. skipped vs. covered by an installed plugin.

## Status

Phase 1: done (2026-08-20). `winget install Anthropic.ClaudeCode` (CLI) and the "Claude Code for VS Code" extension (v2.1.238, Anthropic) are both installed and confirmed working, `claude` launches and is signed in inside VS Code's integrated terminal, and the extension's own welcome message fired. Note: the extension auto-installs its own bundled MCP servers (GitHub, Context7, Markitdown seen in Extensions panel), separate from and unrelated to the Phase 3 GitHub/Notion/Asana connectors, which stay declined.

Phase 2: satisfied (2026-08-21). Kartik confirmed the target repo for AGENTS.md scaffolding is this `Github` root itself, which already carries the pattern via ROADMAP.md's Phase 5 (completed 2026-08-20). No separate action taken under this plan.

Phase 3: partially reopened (2026-08-24). Notion/Asana remain declined. GitHub is now connected: `claude mcp add --transport http github https://api.githubcopilot.com/mcp/ --header "Authorization: Bearer <PAT>"` using a fine-grained PAT Kartik supplied, added at **local** scope (not `project`) deliberately — `project` scope would have committed the PAT into a shared `.mcp.json`, so it stays private to Kartik's own config for this repo. Confirmed `✔ Connected` via `claude mcp list`.

Phase 4: done (2026-08-21). Skipped porting `engineering:code-review` — Claude Code already has an equivalent native `code-review` skill active in-session, so porting it would be redundant. Trialed `code-simplifier@claude-plugins-official` and `pr-review-toolkit@claude-plugins-official` (installed, project scope) against `engineering:tech-debt`; neither actually produces a categorized/prioritized debt audit (they act on code already pointed at, not a codebase-wide survey), so `tech-debt` was custom-built too. Wrote 9 custom `SKILL.md` files under `Github\.claude\skills\`: `engineering-architecture`, `engineering-debug`, `engineering-deploy-checklist`, `engineering-documentation`, `engineering-incident-response`, `engineering-standup`, `engineering-system-design`, `engineering-testing-strategy`, `engineering-tech-debt`. These are recreations based on each skill's one-line Cowork trigger description (the actual Cowork skill instructions weren't accessible from this session), not literal copies.

Phase 4 addendum (2026-08-24): titus-ai's own `.agents/skills/` library (separate from the Cowork-recreated `engineering-*` skills above) had never been searched for portable skills. Read all 14 and ported 7 to `Github\.claude\skills\`, this time copying the actual titus-ai `SKILL.md` content (readable in this session, unlike the earlier Cowork source) rather than reconstructing from a description: `ai-project-manager`, `wayfinder` (plus its SPEC/MAP/ANSWERS templates), `pr-readiness` (plus its `contributor-forks.md` reference, and its `codex review --uncommitted` step swapped for Claude Code's own `/code-review` / `pr-review-toolkit:review-pr`), `bash-scripting`, `homelab-admin`, `linux-sysadmin`, `python-ai` (confirmed relevant to Kartik's Debian homelab and Python AI work). Skipped `forgejo-maintainer` and `podman-operator` (homelab runs neither yet), `rust-cli` (no Rust CLI work), and `hugo`/`mdbook`/`quickshell`/`youtube-thumbnail` (tied to ChrisTitusTech's own Hugo site, mdBook manuscripts, QML/Hyprland shell, and YouTube channel, not Kartik's Astro site or Windows setup). Every ported skill dropped its Codex-only `agents/openai.yaml`; `ai-project-manager` was pointed at this repo's own `claude-agent-templates/` instead of duplicating its `assets/project-docs/` templates.

Also reopened Phase 3's declined GitHub MCP connector at Kartik's request; see that phase's status line above for the outcome.

Phase 4 addendum 2 (2026-08-24): Kartik asked to add `hugo` and `quickshell` anyway despite neither matching his current stack (Astro site, Windows machine) — ported both verbatim, including quickshell's `references/` (build-and-run, docs-map, linting) and its `scripts/quickshell-qmllint` helper (made executable, byte-identical to titus-ai's copy).

Phase 5: no action needed.
