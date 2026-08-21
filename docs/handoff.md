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

Added `powershell` to `.serena/project.yml`'s `language_servers` list (was `[bash, html]`, now `[bash, html, powershell]`) so `get_symbols_overview` can parse `.ps1` files. Confirmed post-restart on 2026-08-21: Serena's project activation now reports `Active language servers: bash, html, powershell`, and `get_symbols_overview` on `winutil-main/Compile.ps1` (this repo itself has no `.ps1` files; tested read-only against a reference clone) returns real symbols instead of erroring.

## Files to read first

- `AGENTS.md` — non-negotiables (never write into the 5 reference clones, verify before claiming done, ask before decisions only Kartik can make), repo map, sources of truth.
- `ROADMAP.md` / `TASKS.md` — phase status (all 6 phases complete, no active phase) and possible future work.
- `docs/vscode-integration-plan.md` — authoritative, phase-by-phase status of the VS Code integration specifically, including exactly what was ported/skipped/covered-by-plugin for the Engineering skills.
- `Github\.claude\skills\` — the 9 custom `SKILL.md` files from this session.
- `docs/cowork-skills-2026-08-21.md` — Kartik's own record of Cowork's actual skill catalog/descriptions; do not overwrite, only read.

## Open items for Kartik

1. **dashboard.html refactor**: `createCard` (board view) and `createListItem` (list view) were deliberately not merged during the earlier Moderate refactor — structurally different, not true duplicate logic. Still open whether Kartik wants that merge attempted anyway.
2. ~~Post-restart check: confirm the 9 new skills and `pr-review-toolkit` actually trigger.~~ Done, confirmed 2026-08-21.
3. ~~Post-restart check: confirm `get_symbols_overview` on `productivity/dashboard.html` now succeeds.~~ Done, confirmed 2026-08-21.
4. ~~Post-restart check: confirm `get_symbols_overview` on a `.ps1` file now succeeds now that `powershell` is in `.serena/project.yml`'s `language_servers` list.~~ Done, confirmed 2026-08-21.
5. No further roadmap work is queued — check with Kartik for next direction.

## Notes

Plugins, connectors, and skills from Cowork are account-level and separate from Claude Code CLI's own catalog — nothing transfers automatically between the two products. `Github\productivity\CLAUDE.md` (Cowork's memory) and the per-repo `CLAUDE.md` files are unrelated files that share a name, don't conflate them. Same applies to the two unrelated `TASKS.md` files (this repo's active-phase tracker vs. `productivity\TASKS.md`'s kanban board).
