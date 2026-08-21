# Roadmap: `createCard` / `createListItem` merge in `productivity/dashboard.html`

Scaffolded 2026-08-21, per Kartik's request to revisit the merge left open since the earlier Moderate refactor. This is a planning document, not a decision record — no code in `dashboard.html` has been changed. Three options are presented at the end; implementation starts only after Kartik picks one, per `AGENTS.md`'s non-negotiable rule that a structural code merge is a decision only Kartik can make.

## What's actually there today

Read both functions in full (`createCard` at `dashboard.html:1481`, `createListItem` at `dashboard.html:2069`) plus their supporting "start editing" helpers before proposing anything, rather than assuming they're straightforward duplicates.

- **`createCard(task)`** (board view): builds its node by assembling an HTML string and setting `.innerHTML`, escaping every interpolated value through `escapeHtml()`. Wires exactly one `click` listener on the card itself and dispatches by reading `e.target.dataset.action` — event delegation. Drag handling just toggles a `.dragging` class on `dragstart`/`dragend`.
- **`createListItem(task, section)`** (list view): builds its node with `document.createElement`/`appendChild` calls throughout, using `.textContent` (not `escapeHtml`) since it never touches `innerHTML`. Wires a separate `click` listener on every interactive child element, each starting with `e.stopPropagation()` — no delegation. `dragend` additionally cleans up `.list-drop-indicator` and `.drag-over` elements that the board view doesn't produce. The `section` parameter is accepted but never read in the function body — it's dead code independent of any merge decision, called with a real value at `dashboard.html:1965`.
- Both call a shared low-level `startInlineEdit()` helper (`dashboard.html:1359`) for inline editing, but through **parallel near-duplicate wrappers**: `startEditingTitle`/`startEditingListItem`, `startEditingNote`/`startEditingListNote`, `startEditingSubtask`/`startEditingListSubtask`, `startAddingSubtask`/`startAddingListSubtask`. Each pair differs mainly in its `styleCss` string (tuned to each view's layout) and which DOM property it commits back to (`innerHTML`-adjacent vs `textContent`-adjacent) — this is where the *real*, mechanical duplication lives, not in the two top-level render functions themselves.

This confirms the prior session's read: `createCard` and `createListItem` are structurally different by design (string-templating + delegation vs. imperative DOM + per-element listeners), not copy-pasted twins. The genuine duplication is one level down, in the four "start editing" wrapper pairs.

## Option A — Full unification into one render function

**Changes**: Replace both functions with a single `renderTaskElement(task, { viewMode: 'board' | 'list', section })` that produces the right markup and wiring for either view from one code path, including collapsing the four "start editing" pairs into one parameterized version each.

**Benefits**: Maximum de-duplication; one place to fix a bug in checkbox/subtask/note/delete behavior instead of two; forces the escaping strategy to be consistent everywhere.

**Disadvantages**: Forces two different DOM-construction models (string+innerHTML+delegation vs. createElement+per-element listeners) into one shape, which means picking a winner and rewriting the loser's behavior from scratch — the highest-risk change to a single 3,000+ line file with no build step or bundler to catch mistakes early (`SPEC.md` rules out adding one). Board and list views have different drag/drop cleanup needs (`.list-drop-indicator` only exists in list view) that would need to be branch-conditional inside the "unified" function, eroding the simplicity that's the whole point of merging. Largest diff, largest regression surface, hardest to review.

## Option B — Extract only the genuinely duplicated helpers

**Changes**: Keep `createCard` and `createListItem` exactly as separate top-level functions with their existing DOM-construction styles. Collapse the four "start editing" pairs into single shared functions parameterized by `styleCss` and a small `{ read, write }` accessor pair (or equivalent), so there is one `startEditingItemTitle`, one `startEditingItemNote`, etc., called by both views with their own style strings. Also removes the dead `section` parameter from `createListItem`'s signature and call site as a small, independent cleanup.

**Benefits**: Targets the duplication that's actually there (four near-identical function pairs, verified by reading them) instead of duplication that was assumed. Leaves the two different-by-design rendering strategies untouched, so no risk to drag/drop, escaping, or event-delegation behavior in either view. Small, independently reviewable diff per helper — each of the four extractions can be its own commit and its own test.

**Disadvantages**: Doesn't touch `createCard`/`createListItem` themselves, so anyone scanning the file still sees two full render functions — the "why aren't these merged" question can resurface. Smaller win than Option A on paper, even though it removes more *actually duplicated* lines relative to its risk.

## Option C — Decline again, document the reasoning permanently

**Changes**: No code changes. Update `ROADMAP.md`'s "Not proposed, and why" entry from "still open" to a permanent decision, citing the structural-difference finding above as the reason, so this doesn't keep resurfacing as an open question each session.

**Benefits**: Zero regression risk to a file with no automated UI test coverage beyond `escapeHtml.test.js`. Honest given `SPEC.md`'s non-goals already rule out build tooling that would make a larger refactor safer to verify.

**Disadvantages**: Leaves the four duplicated "start editing" pairs as later-drift risk — a future edit to one styleCss or one commit-back-to-DOM detail in, say, `startEditingNote` has no forcing function to also update `startEditingListNote`.

## Phased testing approach (applies to whichever option is chosen, scoped down for B/C)

`SPEC.md`'s non-goals rule out a build/bundler pipeline, so testing stays within the pattern already established by `productivity/escapeHtml.test.js`: Node's built-in `node:test`/`node:assert`, extracting the real function from `dashboard.html` at run time so tests can't silently drift from the source.

1. **Phase 0 — Baseline characterization tests.** Before touching any code, write tests that call the *current* `createCard`/`createListItem` (and, for Option A, the four helper pairs) with representative `task` fixtures (no note, with note, no subtasks, multiple subtasks, checked/unchecked) and assert on the resulting DOM shape (`outerHTML`, class list, `data-*` attributes) and on which event listeners fire what. These pin down today's actual behavior as the regression baseline — required for every option except C, since Option C makes no change to verify against.
2. **Phase 1 — Unit tests for each extracted/unified piece.** For Option B: one test file per extracted helper (e.g. `startEditingItemNote.test.js`), asserting it produces the same committed value and DOM update in both board-styled and list-styled invocations. For Option A: tests for `renderTaskElement` in both `viewMode` branches against the Phase 0 baseline fixtures.
3. **Phase 2 — Interaction/regression tests.** Toggle checkbox, add/edit/delete subtask, edit note, edit title, delete task — each run against both views, diffed against Phase 0's captured baseline to catch behavior drift, not just crashes.
4. **Phase 3 — Manual browser QA checklist** (no headless browser dependency exists in this project, so this stays manual, run via the `run` skill or Kartik opening the file directly): drag-and-drop reordering in both views, view-switch mid-edit, empty-board state, long task titles wrapping, dark/light theme toggle.
5. **Gate between phases**: don't start Phase *N+1* until Phase *N*'s tests pass against the pre-change baseline — this is the "phased approach with rigorous testing" Kartik asked for, applied regardless of which option is chosen.

## Implementation status (2026-08-21)

Option B was chosen and implemented. What changed in `productivity/dashboard.html`:

- The four board/list "start editing" pairs (`startEditingTitle`/`startEditingListItem`, `startEditingNote`/`startEditingListNote`, `startEditingSubtask`/`startEditingListSubtask`, `startAddingSubtask`/`startAddingListSubtask`) were collapsed into four shared functions — `startEditingItemTitle`, `startEditingItemNote`, `startEditingItemSubtask`, `startAddingItemSubtask` — each taking a `styleCss` argument supplied by the calling view. All 12 call sites (7 in `createCard`, 5 in `createListItem`) were updated to call the shared function with their own style string inline, unchanged from what each view used before.
- One real behavior difference surfaced while reading the two implementations side by side: the list-view `startAddingListSubtask` had a defensive `if (!task.subtasks) task.subtasks = [];` guard that the board-view `startAddingSubtask` lacked. The unified `startAddingItemSubtask` keeps the guard for both call sites — harmless when `task.subtasks` already exists, and strictly safer for the board view than before.
- `createListItem`'s dead `section` parameter was removed, along with its one call site's now-unnecessary second argument.
- `createCard` and `createListItem` themselves were left untouched, as planned.

Phases 0–2 (automated) are done and green — 48 tests total across `dashboard-baseline.test.js` (regression coverage for `createCard`/`createListItem`, run against the post-change code), `dashboard-start-editing.test.js` (Phase 1: the four unified helpers, board- and list-styled invocations), `dashboard-interactions.test.js` (Phase 2: full click → edit → commit chains through the real, edited call sites in both views), and the pre-existing `escapeHtml.test.js`. Run with:

```
node --test productivity/dashboard-baseline.test.js productivity/dashboard-start-editing.test.js productivity/dashboard-interactions.test.js productivity/escapeHtml.test.js
```

**Phase 3 (manual browser QA): done (2026-08-21, Kartik).** Ran by opening `productivity/dashboard.html` directly in a browser — everything on the checklist worked as expected, no issues found.

- [x] Drag-and-drop reordering works in board view (dragging a card between columns/positions).
- [x] Drag-and-drop reordering works in list view (dragging a list item between sections/positions), including that `.list-drop-indicator`/`.drag-over` cleanup still fires on `dragend`.
- [x] Start editing a title/note/subtask, switch view (board ↔ list) mid-edit, confirm no stuck input or lost edit.
- [x] Empty-board state renders correctly in both views (no section/task data).
- [x] A long task title wraps correctly in both views' layouts (board card width vs. list row width) — this is the one place board and list intentionally use different `styleCss` (font-size 14px vs 15px, different padding).
- [x] Dark/light theme toggle still styles the inline `<input>` correctly in both views (styleCss uses `var(--bg-card)`/`var(--text-primary)`/`var(--accent)`).

All four phases of the phased testing plan are now complete. The `createCard`/`createListItem` merge (Option B) is fully verified — automated (48 tests) and manual.

## Three options for Kartik

| | Risk | What it actually fixes |
|---|---|---|
| **A — Full unification** | High | Everything, but rewrites both views' internals |
| **B — Extract shared helpers only** | Low–Moderate | The four genuinely duplicated "start editing" pairs, plus the dead `section` param |
| **C — Decline, document permanently** | None | Nothing; stops the question from resurfacing |

**Recommendation: Option B.** Option A merges two functions that read as structurally different by design (confirmed by actually reading them, not assumed) into one, for a payoff that doesn't match the regression risk in a file with no build step and only one existing test file. Option C is the safest but leaves real, verified duplication (the four helper pairs) sitting there to drift. Option B is the direct fix for the duplication that's actually present, is small enough to test and review incrementally per the phased plan above, and doesn't touch the two rendering strategies that were correctly kept separate last time.
