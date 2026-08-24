# Handoff

Continuing Kartik's Cowork setup and titus-ai/Claude Code integration work. Read the files below before doing anything else, they carry the context this note doesn't repeat.

## Where things stand (as of 2026-08-21)

All six roadmap phases are complete: Cowork setup, ChrisTitusTech pattern research/templates, the productivity dashboard, VS Code integration (CLI + extension + Engineering skills), the root-level `AGENTS.md` scaffold on this repo, and version control (pushed to `github.com/KartikAkolia/claude-agent-workspace`, private). See `ROADMAP.md` for the authoritative phase-by-phase record and `docs/vscode-integration-plan.md` for VS Code specifics.

### This session's work: Serena fix + Engineering skill porting

1. **Serena MCP server** — diagnosed a `node is not installed or isn't in PATH` error seen in pasted logs as transient (stale PATH in a long-running parent process), not a real missing dependency. Confirmed via fresh log output that later spawns succeeded and the bash LSP started cleanly. Ran Serena onboarding, writing 5 memories under `.serena/memories/` (`core`, `tech_stack`, `suggested_commands`, `conventions`, `task_completion`).

2. **Doc reconciliation** — fixed contradictions across `ROADMAP.md`, `TASKS.md`, and `docs/vscode-integration-plan.md` (Phase 4 status, the GitHub/Notion/Asana connector decision). Kartik confirmed: connectors declined for now (revisit only if a real need comes up), and this `Github` root itself is the AGENTS.md scaffolding target — no separate repo needed.

3. **Engineering skill porting** — Kartik wanted Cowork's 10 Engineering-plugin skills available in Claude Code CLI. Real skill instructions weren't accessible from this session (separate product/catalog), so Kartik supplied the real skill descriptions via `docs/cowork-skills-2026-08-21.md`, then approved a hybrid approach:
   - `engineering:code-review` — skipped porting; Claude Code already has an equivalent native `code-review` skill active in-session.
   - `engineering:tech-debt` — trialed the official `code-simplifier` and `pr-review-toolkit` plugins first (installed project-scope from `claude-plugins-official`), but neither does codebase-wide audit/prioritization (they act on code already pointed at, not a survey) — so this one was custom-built too.
   - The remaining 8, plus `tech-debt`, got custom `SKILL.md` files written under `Github\.claude\skills\`: `engineering-architecture`, `engineering-debug`, `engineering-deploy-checklist`, `engineering-documentation`, `engineering-incident-response`, `engineering-standup`, `engineering-system-design`, `engineering-testing-strategy`, `engineering-tech-debt`. These are recreations based on each skill's one-line trigger description, not literal copies of Cowork's actual instructions.

4. **Testing pass** — ran dummy/dry-run tests of all 10 skills against the real reference-clone repos (`linutil-main`, `winutil-main`, `dwm-titus-main`), read-only throughout per `AGENTS.md`'s non-negotiable rule against writing into those folders:
   - `engineering-tech-debt`: real grep audit across all 3 repos, found one genuine `TODO` (`dwm-titus-main/dwm.c:1040`); also surfaced that its `XXX` pattern false-positived on `mktemp ...XXXXXX` template strings.
   - `engineering-standup`: real `git log` against this repo's own history, correct output.
   - `code-review` (native, not custom): live background run against `linutil-main/core/src/inner.rs` — correctly reported no diff in scope rather than doing an unscoped audit, and respected the read-only boundary.
   - The remaining 7 custom skills were manually dry-run walked through using real grounding material (install.sh flags, CI workflows, config/*.json structure) since they weren't yet live-invocable in-session (new project skills need a restart to register). All 7 held up — grounded, non-generic output.
   - **Fix applied following the test**: `engineering-tech-debt`'s grep step now requires a comment-marker prefix (or excludes runs of >3 consecutive `X`s) for the `XXX` marker instead of matching it bare, removing the `mktemp` false-positive noise.

5. **Serena `html` language server fix** — `get_symbols_overview` on `productivity/dashboard.html` was failing with `Cannot extract symbols from file productivity/dashboard.html. Active language servers: ['bash']`. Root cause: `.serena/project.yml`'s `language_servers` list had only `bash`, so no server could parse non-bash files. Added `html` to that list. Confirmed on disk, but re-tested `get_symbols_overview` on the same file immediately after and it still failed with the identical error — Serena starts its language servers once at project activation, not per-call, so the fix won't take effect until the MCP connection restarts. Same restart dependency as item 3 below, not a separate outstanding bug.

### Restart required (resolved)

The 9 custom skills and the `pr-review-toolkit` plugin's components (e.g. `review-pr`) were written/installed but confirmed NOT live-invocable via the `Skill` tool in the session that created them — Claude Code needed a restart to register new project-scope skills. Confirmed post-restart on 2026-08-21: all 9 `engineering-*` skills plus `pr-review-toolkit:review-pr` now appear in the session's skill list, and `get_symbols_overview` on `productivity/dashboard.html` now succeeds (returns real functions/variables/classes/fields) instead of erroring with `Active language servers: ['bash']`.

### Restart required (resolved, cont'd)

Added `powershell` to `.serena/project.yml`'s `language_servers` list (was `[bash, html]`, now `[bash, html, powershell]`) so `get_symbols_overview` can parse `.ps1` files. Confirmed post-restart on 2026-08-21: Serena's project activation now reports `Active language servers: bash, html, powershell`, and `get_symbols_overview` on `winutil-main/Compile.ps1` (this repo itself has no `.ps1` files; tested read-only against a reference clone) returns real symbols instead of erroring. Committed and pushed as `ad9aaa9`.

### This session's work (2026-08-21, cont'd): ROADMAP decisions + doc restructuring

1. **ROADMAP.md candidate items closed out** — Kartik decided on the two still-open candidates from the prior session's proposal list: item 3 (scaffold a new project from `claude-agent-templates/`) marked `Status: deferred`, no specific project named yet; item 4 (revisit declined GitHub/Notion/Asana connectors) marked `Status: declined`, reaffirmed, no new need surfaced. Both now carry explicit status lines instead of open-ended prose.

2. **Root-level markdown restructured into `docs/`** — Kartik wanted the loose root-level markdown files given real structure. Invoked `engineering-documentation` and `engineering-architecture` skills to frame the options (no other skill/plugin/connector in the catalog applied — this was a local filesystem reorg, not a code/PR/external-service task). Key constraint: `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `SPEC.md`, `ROADMAP.md`, `TASKS.md` are auto-discovered by CLI tools (Claude Code, Codex, Gemini CLI) specifically because they sit at repo root — moving them risks reintroducing the `/init`-prompt problem Phase 5 solved. Presented three options; Kartik picked **Option A**: create `docs/`, move only the four non-scaffold files (`handoff.md`, `headroom-setup-plan.md`, `vscode-integration-plan.md`, `cowork-skills-2026-08-21.md`) into it via `git mv`, leave the six scaffold files at root untouched. Used Serena's `replace_in_files` (dry-run first, then applied) to bulk-update every cross-reference across 9 files (`AGENTS.md`, `SPEC.md`, `ROADMAP.md`, `TASKS.md`, `.serena/memories/core.md`, `.serena/memories/conventions.md`, `.claude/skills/productivity-update/SKILL.md`, plus the two moved files referencing each other) to the new `docs/` paths. Verified with a follow-up grep that no stray root-level path references remained. Committed and pushed as `1eac197`.

### This session's work (2026-08-21, cont'd): `createCard`/`createListItem` merge (Option B) implemented

1. **VS Code reload note declined** — Kartik declined the last open loose end (reloading VS Code to pick up Headroom's Phase 5 wrap). Updated `ROADMAP.md` and `docs/headroom-setup-plan.md` from "still open" to "declined, no longer tracked."

2. **Merge planning doc** — read `createCard`/`createListItem` and their supporting "start editing" helpers in full before proposing anything. Confirmed the two render functions are structurally different by design (innerHTML+delegation vs. createElement+per-element listeners), not accidental duplication — but found genuine duplication one level down: four near-identical "start editing" wrapper pairs, plus a dead `section` parameter on `createListItem`. Wrote `docs/dashboard-card-listitem-merge-roadmap.md` with three options (A: full unification, B: extract only the duplicated helpers, C: decline and document permanently), each with changes/benefits/disadvantages, plus a phased testing plan (Phase 0 baseline → Phase 1 unit tests → Phase 2 interaction tests → Phase 3 manual QA, gated). Recommended Option B; Kartik chose it and said "start on Option B."

3. **Implemented Option B**, following the phased plan with a gate between phases (didn't start phase *N+1* until phase *N*'s tests passed):
   - **Phase 0** (`productivity/dashboard-baseline.test.js`): wrote baseline characterization tests for `createCard`/`createListItem` against a hand-rolled, dependency-free DOM stub (`productivity/test-helpers/dom-stub.js` — no jsdom, per `SPEC.md`'s no-build-deps non-goal) and a generalized function-extraction helper (`productivity/test-helpers/extract-source.js`, extending the pattern already established by `escapeHtml.test.js`). Ran green against the pre-change code first.
   - **Extraction**: collapsed the four wrapper pairs into four shared, `styleCss`-parameterized functions (`startEditingItemTitle`, `startEditingItemNote`, `startEditingItemSubtask`, `startAddingItemSubtask`), updated all 12 call sites (7 in `createCard`, 5 in `createListItem`), removed `createListItem`'s dead `section` parameter and its call site's extra argument. One real behavioral difference surfaced while merging: the list-view add-subtask wrapper had a defensive `if (!task.subtasks) task.subtasks = []` guard the board-view one lacked — kept for both in the unified function (harmless superset, documented in the roadmap doc).
   - **Phase 1** (`productivity/dashboard-start-editing.test.js`): unit tests for the four unified helpers, each invoked with two different `styleCss` strings standing in for board/list call sites, confirming identical commit/cancel behavior.
   - **Phase 2** (`productivity/dashboard-interactions.test.js`): full click → edit → commit chains through the actual edited call sites in both views (not just the helpers in isolation) — the deepest regression check, since it's what would catch a wiring mistake at a specific call site.
   - All 48 tests pass: `node --test productivity/dashboard-baseline.test.js productivity/dashboard-start-editing.test.js productivity/dashboard-interactions.test.js productivity/escapeHtml.test.js`.
   - Updated `docs/dashboard-card-listitem-merge-roadmap.md` and `ROADMAP.md` (candidate item 5) with the implementation summary and a Phase 3 manual QA checklist.

4. **Phase 3 (manual browser QA): done (2026-08-21, Kartik).** Ran directly in a browser — checklist (drag-and-drop reordering in both views, view-switch mid-edit, empty-board state, long title wrapping, dark/light theme toggle) all passed, no issues found. All 4 phases of the merge are now complete.

### This session's work (2026-08-24): dwm-titus ported to Debian and installed on the homelab host

Kartik wanted ChrisTitusTech's `dwm-titus` (Fedora-only upstream, `install.sh` hard-rejects other distros) running on his Debian homelab box at 192.168.0.222. Full package mapping (Fedora dnf → Debian apt, by profile), build/install steps, and the non-package assets (Meslo font, Nordic theme, Nord wallpapers, Herdr skipped) are documented in `docs/dwm-titus-debian-port.md` — read that file directly rather than this summary if picking this back up. Confirmed working by Kartik on 2026-08-24: dwm launches from the lightdm/slick-greeter session picker. Outstanding: `mangohud` blocked by a transient sid dependency gap, `deepin-gtk-theme`/`adw-gtk3` have no Debian package, Herdr wasn't installed because its pinned installer checksum in `dwm-titus`'s own `scripts/install-herdr` didn't match what herdr.dev currently serves (flagged, not bypassed, Kartik confirmed skipping it is fine).

### This session's work (2026-08-24, cont'd): NetworkManager/IPv6/sleep plan drafted, execution deferred

Kartik wants NetworkManager actually managing networking on the homelab host (currently installed but `enp3s0` is unmanaged — deferred to ifupdown per Debian's default `managed=false`), IPv6 disabled, and sleep-related settings disabled so the box never drops off the network. Investigated current state and cross-checked the fix against the Debian wiki, NetworkManager's own docs, and Red Hat's guidance; full plan (exact commands, why each choice was made, sources) is in `docs/homelab-networkmanager-plan.md`. **Not executed** — the NetworkManager handover step briefly cycles the only NIC this SSH session depends on, which conflicts with `homelab-admin`'s safety rule against changing networking without rollback/out-of-band access, so Kartik asked to save it for a future session instead. Resume by reading that doc, confirming local/console access to `dell-optiplex` first, then running the three steps in order.

### This session's work (2026-08-24, cont'd): icon theme support added to `theme-apply.sh`

Kartik installed `papirus-icon-theme` and asked to switch to it; discovered `scripts/theme-apply.sh` had zero icon-theme handling and destructively overwrites `~/.gtkrc-2.0` every run, so patched the script (following its existing `gtk_theme` pattern) rather than hand-editing config files. Full details in the "Follow-up (2026-08-24)" section of `docs/dwm-titus-debian-port.md`. Key point if resuming this: the script exists in three places on the host (source clone, data-dir copy, and the actually-invoked `/usr/local/bin/theme-apply.sh`) — all three had to be updated, the git clone alone has no runtime effect. Verified working; no `themes.toml` changes made (icon theme currently only has a dark/light default, no per-theme override set).

## Files to read first

- `AGENTS.md` — non-negotiables (never write into the 5 reference clones, verify before claiming done, ask before decisions only Kartik can make), repo map, sources of truth.
- `ROADMAP.md` / `TASKS.md` — phase status (all 6 phases complete, no active phase) and possible future work. Stays at root; not moved into `docs/`.
- `docs/` — new as of 2026-08-21: holds the four non-scaffold markdown files (this one, `headroom-setup-plan.md`, `vscode-integration-plan.md`, `cowork-skills-2026-08-21.md`). `CLAUDE.md`/`AGENTS.md`/`GEMINI.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md` remain at root by design, for CLI tool auto-discovery.
- `docs/vscode-integration-plan.md` — authoritative, phase-by-phase status of the VS Code integration specifically, including exactly what was ported/skipped/covered-by-plugin for the Engineering skills.
- `Github\.claude\skills\` — the 9 custom `SKILL.md` files from this session.
- `docs/cowork-skills-2026-08-21.md` — Kartik's own record of Cowork's actual skill catalog/descriptions; do not overwrite, only read.

## Open items for Kartik

1. ~~`createCard`/`createListItem` merge (Option B).~~ Done, confirmed 2026-08-21 — all 4 phases complete: 48 automated tests passing (Phases 0–2), and Kartik ran the Phase 3 manual browser QA checklist with no issues found.
2. ~~Post-restart check: confirm the 9 new skills and `pr-review-toolkit` actually trigger.~~ Done, confirmed 2026-08-21.
3. ~~Post-restart check: confirm `get_symbols_overview` on `productivity/dashboard.html` now succeeds.~~ Done, confirmed 2026-08-21.
4. ~~Post-restart check: confirm `get_symbols_overview` on a `.ps1` file now succeeds now that `powershell` is in `.serena/project.yml`'s `language_servers` list.~~ Done, confirmed 2026-08-21.
5. ~~ROADMAP.md candidate items 3 and 4: decide deferred vs. declined.~~ Done, confirmed 2026-08-21 — item 3 deferred, item 4 declined.
6. ~~Restructure root-level markdown into a folder.~~ Done, confirmed 2026-08-21 — `docs/` created, 4 non-scaffold files moved, all cross-references updated.
7. **New (2026-08-24):** NetworkManager/IPv6/sleep setup on the homelab host — planned in `docs/homelab-networkmanager-plan.md`, deferred pending confirmation of local/console access to `dell-optiplex` before the risky step (handing `enp3s0` from ifupdown to NetworkManager).

## Notes

Plugins, connectors, and skills from Cowork are account-level and separate from Claude Code CLI's own catalog — nothing transfers automatically between the two products. `Github\productivity\CLAUDE.md` (Cowork's memory) and the per-repo `CLAUDE.md` files are unrelated files that share a name, don't conflate them. Same applies to the two unrelated `TASKS.md` files (this repo's active-phase tracker vs. `productivity\TASKS.md`'s kanban board).
