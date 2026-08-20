# Handoff

Continuing Kartik's Cowork setup and titus-ai/Claude Code integration work from a prior session that got compacted. Read the files below before doing anything else, they carry the context this note doesn't repeat.

## Where things stand

Cowork setup is done: Engineering and Productivity plugins installed, writing voice skipped (offer still open whenever Kartik wants it). Windows package research, the AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md templates, the productivity dashboard, and a phased VS Code integration plan have all been delivered and saved to Kartik's `Github` folder on his machine (Windows 11 Professional, winget preferred for installs).

## Files to read first

- `Github\claude-agent-templates\` — the six ChrisTitusTech-pattern templates (AGENTS.md, SPEC.md, ROADMAP.md, TASKS.md, CLAUDE.md, GEMINI.md), plus `titus-ai-windows-setup.md` and `titus-ai-windows-packages-research.md` (sourced winget package list).
- `Github\productivity\` — `dashboard.html` (kanban board, refactored and dark-mode enabled), `TASKS.md`, `CLAUDE.md` (Cowork's memory file: who Kartik is, his research standards), `dashboard-usage-guide.md`, and `backups\` (pre-refactor dashboard backup).
- `Github\vscode-integration-plan.md` — five-phase plan for bringing this setup into VS Code (install Claude Code CLI + extension, carry AGENTS.md pattern into repos via `CLAUDE.md` → `@AGENTS.md`, reconnect connectors via `claude mcp add`, decide on porting Engineering skills, leave the dashboard as a browser tool). Not yet started.

## Two open decisions, unresolved

1. **dashboard.html refactor**: `createCard` (board view) and `createListItem` (list view) were deliberately NOT merged during the Moderate refactor, they're structurally different (innerHTML+delegated-click vs createElement+per-element-listeners), not true duplicate logic, and forcing a merge was judged to hurt clarity for less benefit than originally estimated. Kartik hasn't said whether he still wants that merge attempted anyway.
2. **VS Code connector priority**: the plan lists GitHub, Notion, and Asana as the three connectors with documented one-line `claude mcp add` commands. Kartik hasn't confirmed those are actually the right three to wire up first versus something else in his stack (Slack, Jira, a database).

## Notes

Plugins, connectors, and skills are account-level and already active, nothing needs reinstalling. `Github\productivity\CLAUDE.md` (Cowork's memory) and the per-repo `CLAUDE.md` files from Phase 2 of the VS Code plan share a name but are unrelated files, don't conflate them.
