# Dashboard archive

`productivity/dashboard.html` and its supporting files, retired 2026-09-03 (Fjord `ROADMAP.md`
Phase 4) once Fjord's read-only doc reader replaced it as the workspace's entry point. Kept here
rather than deleted outright, in case Kartik wants to revert someday.

Not rendered by Fjord — its `productivity` content collection only globs top-level `*.md` files in
`productivity/`, and everything here lives one level down in this subdirectory.

## Contents

- `dashboard.html` — the kanban board itself (dark mode, drag-and-drop, board/list views).
- `dashboard-baseline.test.js`, `dashboard-interactions.test.js`, `dashboard-start-editing.test.js`,
  `escapeHtml.test.js` — its `node --test` suite.
- `test-helpers/` — the dependency-free DOM stub and source-extraction helpers the tests run against.
- `dashboard-usage-guide.md` — the original usage guide.
- `backups/` — a pre-refactor snapshot from 2026-08-20, predating the `createCard`/`createListItem`
  merge (see `docs/dashboard-card-listitem-merge-roadmap.md`).

## Reverting

Move this directory's contents back up into `productivity/` (undoing the `git mv` that created this
archive — check `git log --follow productivity/dashboard-archive/dashboard.html` for the exact
commit) and re-run the test suite with `node --test productivity/*.test.js` to confirm nothing
bit-rotted in the meantime. `productivity/CLAUDE.md` and `productivity/TASKS.md` were never moved,
so they're unaffected either way.
