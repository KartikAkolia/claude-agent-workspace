# TASKS.md

Implementation detail for the active phase only. See `ROADMAP.md` for phase order.
Replace this file's contents when the phase completes, don't accumulate history.

## Active Phase: none — Phase 4 complete (2026-09-03)

Phases 0–4 are all complete — see `ROADMAP.md` for each phase's Completion Evidence. Phase 4 (dashboard retirement) resumed 2026-09-03 after the 2026-08-29 halt, on Kartik's explicit go-ahead ("Let's pick up from where we left off and work on Phase 4"). Kartik chose Option B (dashboard bundle only, not the whole `productivity/` folder) plus archival over deletion.

`productivity/dashboard.html` and everything that supported it (`dashboard-baseline.test.js`, `dashboard-interactions.test.js`, `dashboard-start-editing.test.js`, `escapeHtml.test.js`, `test-helpers/`, `dashboard-usage-guide.md`, `backups/`) now live at `productivity/dashboard-archive/`, moved via `git mv` so history is preserved, with a `README.md` there explaining what it is and how to revert. `productivity/CLAUDE.md` and `productivity/TASKS.md` were left untouched and still render in Fjord's `productivity` collection. `npx astro check` (0 errors/warnings/hints) and `npm run build` (46 pages) both verified clean after the move.

Root `AGENTS.md` (repo map + the dashboard-protection line in Change Discipline) and root `ROADMAP.md`'s Phase 3 entry updated to reflect the retirement. Fjord's own `AGENTS.md`, `SPEC.md`, and `src/content.config.ts` updated to describe the archive rather than the old exclude-by-filename list.

Phase 5 (polish + the deployment decision) remains untouched and on hold — no further phase should proceed here without Kartik raising it.

## Phase Completion

1. Record delivered behavior here or in a changelog if one gets started.
2. Update `ROADMAP.md` status and evidence.
3. Replace this file with the next phase's tasks once there is one.
