# ROADMAP.md

`SPEC.md` is the durable contract; this defines ordered phases. `TASKS.md` holds active-phase detail only.

## Phase 1: Cowork setup

Status: complete

### Objective

Get Cowork itself usable for this work: plugins, connectors, skills.

### Outcomes

Engineering and Productivity plugins installed. Writing-voice skill offered, not yet taken up, open whenever Kartik wants it.

### Exit Criteria

Plugins active at account level.

### Completion Evidence

Confirmed in `docs/handoff.md` (2026-08-20) and this session's available skills list.

## Phase 2: ChrisTitusTech pattern research and templates

Status: complete

### Objective

Understand how ChrisTitusTech scaffolds repos for AI agents, and produce reusable templates.

### Outcomes

`claude-agent-templates/` delivered: six template files, `agent-scaffold-guide.md`, Windows/winget package research (`titus-ai-windows-setup.md`, `titus-ai-windows-packages-research.md`).

### Exit Criteria

Templates match the pattern found across `dwm-titus`, `linutil`, `website`, `winutil`.

### Completion Evidence

`claude-agent-templates/agent-scaffold-guide.md`, cross-checked against the reference clones on 2026-08-20.

## Phase 3: Productivity dashboard

Status: complete

### Objective

Give Kartik a working local task dashboard tied to Cowork's productivity skill.

### Outcomes

`productivity/dashboard.html` (kanban, dark mode), `TASKS.md`, `CLAUDE.md` (Cowork memory), usage guide, pre-refactor backup kept.

**Retired 2026-09-03** (`fjord/ROADMAP.md` Phase 4): `dashboard.html` and its supporting test/usage-guide/backup files archived, not deleted, under `productivity/dashboard-archive/`, once Fjord's read-only doc reader took over as the workspace's entry point. `TASKS.md` and `CLAUDE.md` stayed live in `productivity/`, untouched.

### Exit Criteria

Dashboard opens locally, reads and writes `TASKS.md` on disk, autosaves.

### Completion Evidence

`productivity/dashboard-archive/dashboard-usage-guide.md` (moved here 2026-09-03 when the dashboard was retired, see this phase's Outcomes above).

## Phase 4: VS Code integration

Status: complete (2026-08-21). See `docs/vscode-integration-plan.md` for the authoritative phase-by-phase status.

### Objective

Bring Cowork's setup into Claude Code CLI and its VS Code extension.

### Outcomes

CLI and VS Code extension both installed and confirmed working (2026-08-20). GitHub/Notion/Asana connector wiring declined by choice (confirmed 2026-08-21). Repo-level AGENTS.md scaffolding satisfied by this repo's own Phase 5 scaffold — Kartik confirmed this `Github` root is the scaffolding target. Engineering-plugin skills ported (2026-08-21): `code-review` skipped (already covered by a native Claude Code skill), `code-simplifier`/`pr-review-toolkit` installed project-scope as a trial for `tech-debt` (insufficient alone), 9 custom `SKILL.md` files written under `.claude/skills/` for the rest (architecture, debug, deploy-checklist, documentation, incident-response, standup, system-design, testing-strategy, tech-debt).

### Exit Criteria

See `docs/vscode-integration-plan.md`'s verification checklist.

### Completion Evidence

Terminal screenshots confirming `claude` launches signed in inside VS Code (2026-08-20); Extensions panel confirming "Claude Code for VS Code" v2.1.238 installed and enabled. `claude plugin list` shows `code-simplifier@claude-plugins-official` and `pr-review-toolkit@claude-plugins-official` installed at project scope; `Github\.claude\skills\` contains the 9 custom skill folders, each with a `SKILL.md`. All 9 confirmed live-invocable and producing grounded (non-generic) output in a dedicated test pass on 2026-08-21 — see `docs/handoff.md`.

## Phase 5: Root-level project scaffold

Status: complete (2026-08-20)

### Objective

Give this folder tree itself the AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md/CLAUDE.md/GEMINI.md convention, filled in with real content instead of left as a blank template, so `claude` run anywhere in this tree has accurate context instead of triggering a generic `/init`.

### Outcomes

This file and its siblings, written to the `Github` folder root.

### Exit Criteria

Files written to `C:\Users\Kartik\Downloads\Github\` root, confirmed on disk. `claude` launched from that root picks up real context instead of prompting `/init`.

### Completion Evidence

Kartik confirmed via terminal screenshot (2026-08-20): `claude` launched from `~\Downloads\Github` shows no home-directory warning and no `/init` prompt, meaning the `CLAUDE.md` → `AGENTS.md` chain resolved correctly.

## Phase 6: Version control

Status: complete (2026-08-20)

### Objective

Put the whole folder under git and back it up to a private GitHub repo, using the `gh` CLI already authenticated on Kartik's machine.

### Outcomes

Private repo created at `github.com/KartikAkolia/claude-agent-workspace`, full folder tree pushed (2,889 objects, 37.66 MiB), including the five reference codebases by Kartik's explicit choice.

### Exit Criteria

`git push` succeeds, repo visible on GitHub as private.

### Completion Evidence

Terminal output (2026-08-20): `gh repo create claude-agent-workspace --private --source=. --remote=origin --push` succeeded, `✓ Pushed commits to https://github.com/KartikAkolia/claude-agent-workspace.git`. Default branch is `master`.

## Candidate Next Steps (none started — proposed 2026-08-21)

All 6 phases above are complete; no phase is currently active (see `TASKS.md`). The items below are candidates surfaced by re-reading every doc in this tree plus this session's skill-testing findings, not decided work — each needs Kartik's go-ahead before becoming a phase, per `AGENTS.md`'s rule against guessing on decisions only he can make.

### 1. Test coverage for `escapeHtml()` in `productivity/dashboard.html`

Status: done (2026-08-21). `productivity/escapeHtml.test.js` — 8 cases (each special char, combined-order regression guard, XSS payload, null/undefined/empty, non-string coercion, no double-escape-detection), using Node's built-in `node:test`/`node:assert` so no dependency was added. Extracts the real function from `dashboard.html` at run time rather than duplicating it, so the test can't silently drift out of sync. Run with `node --test productivity/escapeHtml.test.js`; all 8 pass. Verified the ordering test actually catches regressions (not just passing trivially) by confirming a reordered version of the function produces corrupted output (`&amp;lt;` instead of `&lt;`).

### 2. Port a Claude Code equivalent of Cowork's `productivity:update`

Status: done (2026-08-21). `.claude/skills/productivity-update/SKILL.md` written, matching the 9 Engineering skills' convention. Scoped honestly rather than claiming parity with Cowork's version: no Gmail/Calendar/Notion/Asana connector exists in this project (declined), so it works from the current conversation, `git log`, and on-disk evidence only — not a full email/chat/calendar scan. Confirmed live-invocable immediately, no restart needed (unlike the 9 Engineering skills, which needed one). Live-tested against the real `productivity/TASKS.md`: correctly reported nothing to sync (board's one Done item already evidenced, Active/Waiting On/Someday all empty, and this session's own repo-dev work correctly excluded as belonging to the root `TASKS.md` convention instead, not this kanban board).

### 3. Scaffold a new project from `claude-agent-templates/`

Status: mostly complete (2026-08-26, was "started" as of 2026-08-21). Kartik's personal website — named "Loopwire" this session — is scaffolded, built, and deployed live at `https://loopwire.kartikpassbolt.org` (Cloudflare Workers + static assets, custom domain via Namecheap/Cloudflare). `website-master`'s Astro conventions were used as a read-only structural reference only, never written to, per the non-negotiable in this file. Its own `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md` under `Github/personal-website/` are the source of truth for phase detail from here — Phases 1–4 complete, Phase 5 (AI hooking) built then removed (Anthropic billing blocker, no working payment method), Phase 5's Dashboard sub-effort not started (blocked on a data-source decision only Kartik can make). See `docs/handoff.md` for the same-day build-to-deploy summary.

### 4. Revisit declined connectors (GitHub, Notion, Asana)

Status: declined (2026-08-21, Kartik's call, reaffirmed this session). Originally declined 2026-08-21 (`docs/vscode-integration-plan.md` Phase 3), explicitly gated on "revisit only if a real need comes up." No new need has surfaced. Not recommended to act on.

### 5. `createCard`/`createListItem` merge in `productivity/dashboard.html`

Status: done (2026-08-21, Kartik's call — see `docs/dashboard-card-listitem-merge-roadmap.md`). Option B implemented: the four board/list "start editing" wrapper pairs were collapsed into four shared, `styleCss`-parameterized functions; `createListItem`'s dead `section` parameter was removed. `createCard`/`createListItem` themselves were left separate, as planned. All 4 phases complete — Phases 0–2 automated (48 tests passing across `productivity/dashboard-baseline.test.js`, `dashboard-start-editing.test.js`, `dashboard-interactions.test.js`, and `escapeHtml.test.js`), Phase 3 manual browser QA run by Kartik with no issues found.

### 6. Fjord: Nord-themed docs/README viewer, replacing `productivity/dashboard.html`

Status: halted (2026-08-29), Kartik's call. Kartik asked for a web interface to browse and read this repo's documentation, following `website-master`'s Astro setup style but scoped down to a personal read-only reader, Nord palette, replacing `dashboard.html` as the workspace's entry point outright (his explicit choice — no kanban reimplementation). Scaffolded as `fjord/` with its own `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md`, same pattern as `personal-website`/Loopwire (Candidate Next Step 3) — that sub-project's docs are the source of truth for phase detail from here. Phase 0 (documentation/decisions), Phase 1 (Nord-palette moodboards — "Nord Terminal" direction picked), Phase 2 (Astro scaffold), and Phase 3 (the actual reading UI — dwm-style status bar, ranger/lf-style source/file-list/preview panes, all 39 in-scope docs live and verified via a running dev server plus a clean `npm run build`) are all complete and committed (`98b3ea3`). Node.js and the `browser-use` CLI were installed on this machine this session (Kartik's explicit request), which also unblocked Phase 2.

Kartik then paused Fjord outright to fork its same structure for a separate, University-focused idea (not this homelab repo) with different content, to begin in a future session — explicitly not this one. Phase 4 (`dashboard.html` retirement) stays not started, gated on a fresh, explicit go-ahead per Fjord's own `AGENTS.md` non-negotiable 6, and now additionally paused by the halt. Deployment remains on hold, Kartik's call, pending a review of whether any in-scope doc holds sensitive homelab/network detail. Do not resume Fjord work without Kartik explicitly raising it again.

The University fork itself started 2026-08-29, same day — see Candidate Next Step 7 below.

### 7. Estuary: University of Greenwich pre-course study e-reader, forked from Fjord

Status: in progress (2026-08-29), Kartik's call. Fjord's own Nord Terminal visual language carried over (palette, JetBrains Mono, dwm-style chrome), reinterpreted as a book/chapter e-reader instead of Fjord's file-browser panes, for Kartik to study ahead of University of Greenwich course P12069 (BSc Hons Computer Science, Sandwich, Year 0, starting 2026-09-14) across its seven Year 0 modules. Scaffolded as `estuary/` with its own `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md`, same pattern as `fjord`/`personal-website`/Loopwire — that sub-project's docs are the source of truth for phase detail from here.

Six build/deploy approaches were presented to Kartik (new directory vs. repurposing `fjord/` in place; Cloudflare Workers vs. Pages as the eventual target — `website-master`'s own docs say Pages, but `docs/handoff.md` records Loopwire's actual live setup is Workers + static assets; shell-first vs. content-first build order). Kartik picked: new directory (`estuary/`, his own naming), shell-first, deployment target/domain held open for now. Content is original research (University module descriptions plus supporting authoritative sources per `docs/personal-research-guidelines.md`), not a mirror of anything in this repo — unlike Fjord, no `glob()` sourcing from elsewhere.

### Not proposed, and why

- **Splitting `dashboard.html` into modules**: it's a single 3,003-line file, which would normally flag as a structural smell, but `SPEC.md`'s own non-goals rule out build tooling for this project — splitting it would fight a deliberate design choice, not fix a real problem. Not recommended.
- **Headroom Phase 7/9** (cross-agent memory, Docker): both explicitly deferred in `docs/headroom-setup-plan.md` until Codex/Gemini are in daily use or a multi-instance need arises. No change.
- **Reloading VS Code to pick up Headroom's Phase 5 wrap** (`docs/headroom-setup-plan.md`): declined (2026-08-21, Kartik's call). No longer tracked as an open loose end.
