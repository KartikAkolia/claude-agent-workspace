# ROADMAP.md

`SPEC.md` is the durable contract; this defines ordered phases. `TASKS.md` holds active-phase detail only.

## Phase 0: Documentation and decisions

Status: complete (2026-08-29)

### Objective

Turn Kartik's request into a concrete, decided scope before any code exists — content boundaries, dashboard-retirement plan, dev workflow, deployment stance — captured in this project's own `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md`, plus a pointer from the root repo's own docs.

### Outcomes

`fjord/AGENTS.md`, `fjord/SPEC.md`, `fjord/ROADMAP.md`, `fjord/TASKS.md` written. Root `AGENTS.md` Repository Map and root `ROADMAP.md`/`TASKS.md` updated with a pointer to this sub-project, matching the precedent set for `personal-website`/Loopwire in root `ROADMAP.md`'s Candidate Next Step 3.

### Exit Criteria

All open questions from Kartik's original request answered and recorded here rather than left implicit; no placeholder sections left in this project's own docs.

### Completion Evidence

This file and its siblings, on disk, cross-referenced from the root repo.

## Phase 1: Visual direction (moodboards)

Status: complete (2026-08-29)

### Objective

Give Kartik concrete visual directions to react to before any component code is written, per his explicit request that moodboards drive the final look here.

### Outcomes

Four Nord-palette moodboards as one Artifact canvas: two "Nord classic" reading-focused layout directions, and two more that borrow structural/layout conventions popular in Linux tiling-window-manager rice culture (dense terminal-styled panels, glassy/rounded floating cards, bento-grid dashboards) while staying strictly within the Nord color palette — not swapping to another community palette like Catppuccin or Gruvbox.

### Exit Criteria

Kartik picks a direction (or specifies a hybrid) before Phase 2 starts.

### Completion Evidence

**Kartik's pick (2026-08-29): Direction 2 — "Nord Terminal"** (`fjord/moodboards/fjord-moodboard-2-nord-terminal.html`), stated explicitly and verbatim. Locked into `SPEC.md`'s Architecture (Styling) and Functional Requirements (Theming) sections. The other three directions remain on disk as a visual record of the decision, not carried forward.

**Delivery note (2026-08-29):** the intended delivery — Claude Design's interactive canvas, published as an Artifact — wasn't available this session: neither Node.js nor Bun is installed anywhere on this machine (checked `PATH`, a login shell, and every common version-manager location), which the canvas-seeding step requires, and the Chrome extension for browser automation wasn't connected either. Delivered instead as four standalone HTML files (no dependencies, open directly in any browser) under `fjord/moodboards/`: `fjord-moodboard-1-nord-classic.html`, `-2-nord-terminal.html`, `-3-nord-glass.html`, `-4-nord-bento.html`. Revisit the live-canvas path once Node or Bun is available, or the Chrome extension is connected (`/chrome`).

## Phase 2: Astro project scaffold

Status: complete (2026-08-29)

### Objective

Stand up the actual Astro project: `package.json`, `astro.config.mjs` (static output), content collections via the `glob()` loader pointed at the real source paths (no copying — see `SPEC.md`), a base layout, Nord CSS tokens matching the chosen moodboard, and a `dev` script Kartik can leave running.

### Outcomes

`npm run dev` boots without error. No page content/routing yet beyond a placeholder — this phase proves the pipeline, not the reading UI.

### Exit Criteria

`npm run dev` runs; content collections resolve every in-scope file with no schema/parse errors (`astro check` clean); editing a doc elsewhere in the repo triggers HMR in the running dev server, confirmed live.

### Completion Evidence

Node.js was the actual blocker flagged after Phase 1 — resolved this session: Node v24.20.0 (via `nvm`, satisfies `website-master`'s own `>=24 <25` requirement) and the `browser-use` CLI (via `uv tool install`) were both installed at Kartik's explicit request ("install the relevant tools for this extension and plugin to work") and verified working before scaffolding started.

Built: `package.json` (scripts: `dev`/`build`/`preview`/`check`), `astro.config.mjs` (`output: "static"`, Shiki `theme: "nord"`, no `site`/deploy config — still on hold), `tsconfig.json` (`astro/tsconfigs/strict`), `src/content.config.ts` (four collections — `root`, `docs`, `productivity`, `templates` — each a flat, non-recursive `glob({ pattern: "*.md", base: ... })` pointed at the real repo paths per `SPEC.md`; the flat pattern is what excludes `productivity/dashboard.html`, its `*.test.js` files, and `backups/` without an explicit exclude list), and `src/pages/index.astro` as the Phase 2 placeholder (Nord Terminal color tokens, lists every resolved doc per group — not the real reading UI, that's Phase 3).

Verified live, not assumed:
- `npx astro check` → **0 errors, 0 warnings, 0 hints** (content synced, types generated).
- `npm run dev` → Astro 7's dev daemon booted clean at `http://localhost:4321` (pid confirmed via `astro dev status`) and was left running per Kartik's stated preference (2026-08-29) for live preview.
- Doc counts fetched from the live page matched the real filesystem exactly: root 7, `docs/` 20, `productivity/` 3, `claude-agent-templates/` 9 — **39 total** (corrects the earlier "36" placeholder count carried in root `ROADMAP.md`'s Phase 3 entry; recount at that phase per its own note).
- Live HMR proven, not just claimed: added a temporary `docs/fjord-hmr-test.md`, confirmed the running dev server's `docs/` count moved 20 → 21 and the new title appeared within 2 seconds with no server restart; then removed it and confirmed the count returned to 20 and the entry disappeared, live. An earlier append-only edit to `docs/handoff.md` (an in-place comment marker, not a new file) was also made and then fully reverted to its original content, verified via `diff` — file left exactly as found.

## Phase 3: Reading experience

Status: complete (2026-08-29)

### Objective

Build the actual read-only UI: index page (grouped by source location), per-doc reading pages, navigation, Nord theming applied per the Phase 1 pick.

### Outcomes

Every in-scope doc (36 as of 2026-08-29, recount at phase start since the repo's docs change often) readable from the index with correct rendering (headings, code blocks, tables, links).

### Exit Criteria

Manual QA pass: every in-scope doc opens and renders correctly; navigation works; theme is visually consistent across pages.

### Completion Evidence

Built the Nord Terminal reading UI faithfully off the chosen moodboard (`fjord/moodboards/fjord-moodboard-2-nord-terminal.html`): `src/components/ReaderPage.astro` (the one page template every route renders — dwm-style status bar with group tabs, source pane, file-list pane with real on-disk file sizes, preview pane rendering the actual markdown via Astro's `render()`, status line with a live word count), plus three thin route files (`src/pages/index.astro`, `src/pages/[group]/index.astro`, `src/pages/[group]/[slug].astro`) and two small libs (`src/lib/groups.ts`, `src/lib/sortEntries.ts` — priority-orders AGENTS/SPEC/ROADMAP/TASKS/README/CLAUDE/GEMINI where a group has them, alphabetical otherwise — and `src/lib/fileMeta.ts`). `content.config.ts` was also updated with an explicit `generateId` so doc ids/URLs keep their real, exact filename casing (`AGENTS`, not the default slugified `agents`) instead of silently diverging from the actual on-disk names.

Verified live, not assumed:
- `astro check` → 0 errors, 0 warnings, 0 hints (11 files) after the UI was built.
- Every one of the four groups' index route and at least one doc route spot-checked directly against the running dev server, all `200`: `/`, `/root/`, `/root/SPEC/`, `/docs/`, `/docs/handoff/`, `/productivity/`, `/productivity/dashboard-usage-guide/`, `/templates/`, `/templates/agent-scaffold-guide/`. A deliberately bad route (`/docs/does-not-exist/`) correctly `404`s.
- Shiki's `nord` code-block theme confirmed rendering (`class="astro-code nord"`) on a doc with real code fences (`docs/laptop-vfio-passthrough.md`, 18 code blocks).
- **A real bug was caught and fixed by actually running `npm run build`, not by assuming dev-mode success would carry over**: `src/lib/fileMeta.ts` originally resolved the project root via `import.meta.url`, which is correct in dev (Vite serves modules from their source location) but wrong once `astro build` bundles that module into a `dist/.prerender/` chunk — the build failed with `ENOENT` trying to stat a doc at the wrong path. Fixed by switching to `process.cwd()` (stable across dev/build/preview since Astro is always invoked from `fjord/`). Re-ran `npm run build` after the fix: **44 pages built successfully** (39 docs + 4 group index pages + 1 root index — matches the real file count exactly).
- HMR re-verified after the Phase 2 daemon needed a restart mid-session (a content-config change — the new `generateId` — left its file watchers stale; `astro dev stop` + `npm run dev` resolved it cleanly, worth knowing for later config edits). Post-restart, and again after the `fileMeta.ts` fix, both add-a-doc and remove-a-doc were round-tripped live against `docs/`: count went 20 → 21 → 20, the new route 200'd then 404'd again, with no dev-server restart needed for either step.
- Scratch edits made along the way to real repo docs (`docs/handoff.md`, `AGENTS.md`) while testing HMR were fully reverted and confirmed via `diff`/`git diff` against the committed state — nothing left behind.

Known limitation, not fixed this phase (acceptable for "plain reading and review," per `SPEC.md`'s non-goals): in-content markdown links between source docs (e.g. a doc linking to another file by its repo-relative path) are rendered as plain links, not rewritten to Fjord's own `/group/id/` routes. Revisit only if it becomes an actual friction point in use.

## Phase 4: Dashboard retirement

Status: not started — gated on Phase 3 completion plus a fresh go-ahead from Kartik

### Objective

Retire `productivity/dashboard.html` and its associated test/backup files outright, per Kartik's explicit choice (2026-08-29, option (c) — no kanban reimplementation). `TASKS.md`/`ROADMAP.md`-style files simply render as read-only docs like any other, same as everything else in scope.

### Outcomes

`productivity/dashboard.html`, its `.test.js` files, `dashboard-usage-guide.md`, and `backups/` removed (or archived, per Kartik's preference at the time — ask, don't assume, per root `AGENTS.md` non-negotiable 3). Root `AGENTS.md`'s dashboard-protection language and `ROADMAP.md` Phase 3 entry updated to reflect retirement.

### Exit Criteria

Fjord's read-only rendering of the workspace's docs is confirmed working (Phase 3 done) **and** Kartik gives an explicit go-ahead at this point specifically — the earlier "(c)" answer authorized the decision, not the exact moment of deletion, per the root `AGENTS.md`'s stance on hard-to-reverse actions.

### Completion Evidence

Kartik's explicit go recorded here, plus confirmation the files are gone (or archived) and nothing else references them.

## Phase 5: Polish and the deployment decision

Status: not started

### Objective

Accessibility/visual polish once the reading UI is live and used for a while; revisit the deployment question Kartik is holding open (2026-08-29) — sensitive-content review of in-scope docs — whenever he raises it.

### Outcomes

TBD — depends on what Phase 3 usage surfaces and Kartik's deployment call.

### Exit Criteria

TBD.

### Completion Evidence

TBD.
