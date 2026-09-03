# SPEC.md

What Fjord is and how it's built, not how to work on it (see `AGENTS.md`).

## Product Definition

Fjord is a read-only Astro website for Kartik to browse and read this repo's own documentation in a clean, Nord-themed reading UI, in place of opening raw `.md` files or `productivity/dashboard.html`. It runs locally via `npm run dev`, left running while docs elsewhere in the repo are edited, and reflects those edits without a manual rebuild.

## Goals / Non-Goals

**Goals:**

- Browse and read every doc in scope (see Interfaces) from one navigable UI.
- Source content live from its real location in this repo — no copies, no sync step that could drift from the original.
- Apply the Nord color palette consistently, in the layout direction chosen from the Phase 1 moodboards.
- Support a long-running `npm run dev` session with live reload as docs change elsewhere in the repo.
- Follow Astro's architectural principles as demonstrated in `website-master` (content collections, static output, component-based layout, TypeScript) — same *style* of setup, deliberately different *scope*.

**Non-goals:**

- No editing or write-back to source docs. Fjord is read-only; `dashboard.html`'s editable kanban is retired, not reimplemented here or anywhere else, per Kartik's explicit choice (2026-08-29).
- No deployment/hosting for now. On hold (Kartik, 2026-08-29) pending a review of whether any in-scope doc contains sensitive homelab/network detail. Revisit only when he raises it.
- No content from the five reference clones (`dwm-titus-main/`, `linutil-main/`, `titus-ai-main/`, `website-master/`, `winutil-main/`) — excluded by explicit instruction.
- No CMS, no server runtime, no database. Static output only.
- No porting of `website-master`'s blog-specific machinery (shortcodes, taxonomy, legacy URL redirects, RSS/YouTube integration, reCAPTCHA livestream chat) — none of it applies to a personal doc reader.
- No full browser/Lighthouse CI pipeline like `website-master`'s `validate` script — Fjord is a personal local tool, not a public production site. A lighter validation scope is defined per-phase in `ROADMAP.md`/`TASKS.md`.

## Architecture

- **Framework**: Astro, static output (`output: "static"`, matching `website-master`), TypeScript.
- **Content sourcing**: Astro content collections using the `glob()` loader. Verified against Astro's official docs via Context7 (2026-08-29) that `base` accepts any filesystem path, including paths outside the project root — so collections point directly at:

   - repo root: `*.md` (`AGENTS.md`, `SPEC.md`, `ROADMAP.md`, `TASKS.md`, `README.md`, `CLAUDE.md`, `GEMINI.md`)
   - `../docs/*.md`
   - `../productivity/*.md` — `CLAUDE.md` and `TASKS.md` only; the retired dashboard bundle (`dashboard.html` and everything that supported it) lives one level down in `dashboard-archive/`, archived rather than deleted 2026-09-03 (`ROADMAP.md` Phase 4), so it's excluded by the same flat, non-recursive pattern with no exclude list needed
   - `../claude-agent-templates/*.md` (verified 2026-08-29: 9 files, all flat — no nested subdirectory currently exists there, correcting this line's earlier assumption)

  No transform/copy step is needed — unlike `website-master`'s `scripts/prepare-content.mjs` (which exists for shortcodes, taxonomy slugs, and legacy-URL tables that don't apply here), Astro's built-in markdown renderer (Shiki for code blocks) is sufficient.
- **Live reload**: Astro's content layer watches each collection's `base` directory in dev mode; edits to any in-scope file elsewhere in the repo trigger HMR without restarting `npm run dev`.
- **Styling**: Nord palette — Polar Night (`#2E3440`–`#3B4252`), Snow Storm (`#D8DEE9`–`#ECEFF4`), Frost (`#8FBCBB`/`#88C0D0`/`#81A1C1`/`#5E81AC`), Aurora accents (`#BF616A`/`#D08770`/`#EBCB8B`/`#A3BE8C`/`#B48EAD`). **Direction: "Nord Terminal"** (Kartik's pick, 2026-08-29, from `fjord/moodboards/fjord-moodboard-2-nord-terminal.html`) — dark-only, Polar Night (`#2E3440`) background throughout, dense information layout, `JetBrains Mono` for everything (no separate serif/UI-sans pairing), a dwm/i3-style thin top status bar (workspace-tag pills for the four source groups: root/docs/productivity/templates, current group highlighted), a ranger/lf-style multi-pane file browser (source list → file list → preview pane), thin `#434C5E` box-drawing-style borders, Frost cyan (`#88C0D0`) for selection/links, Aurora yellow (`#EBCB8B`) for prompt-style accents, Aurora green (`#A3BE8C`) for status indicators.
- **Deployment**: none configured. Held open per Kartik's explicit hold (2026-08-29).

## Functional Requirements

- **Index page**: lists every in-scope doc, grouped by source location (root / `docs/` / `productivity/` / `claude-agent-templates/`).
- **Doc page**: renders one markdown file — syntax-highlighted code blocks, readable typography, a way back to the index.
- **Navigation**: moving between docs without losing place or requiring a full manual reload; simple enough to match "plain reading and review," not a full docs-search product.
- **Theming**: Nord Terminal direction applied consistently across index and doc pages — dark-only (no light-mode toggle), monospace throughout, dense multi-pane layout. See Architecture's Styling entry for the specifics.

## Interfaces / Contracts

- **Content sources** (read-only, absolute/relative paths outside `fjord/`): listed under Architecture above. Fjord never writes to these paths — see `AGENTS.md` non-negotiable 1–2.
- **No API, no backend.** Fully static output.
- **No config schema beyond `astro.config.mjs`** and the content-collection definitions in `src/content.config.ts` (Astro 5 convention).

## Testing & CI

Scoped down from `website-master`'s full pipeline (Playwright, Lighthouse, axe) since Fjord is a personal local tool:

- `astro check` for type/content-schema errors.
- A smoke check that every in-scope doc renders without a build error (catches a bad frontmatter parse or a broken collection path early).
- Manual QA in the browser for visual/theme correctness, same pattern as `productivity/dashboard.html`'s Phase 3 manual QA in `docs/dashboard-card-listitem-merge-roadmap.md`.

No Playwright/Lighthouse/axe setup unless deployment later gets approved and a public-facing bar becomes relevant.
