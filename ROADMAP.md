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
Confirmed in `handoff.md` (2026-08-20) and this session's available skills list.

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

### Exit Criteria
Dashboard opens locally, reads and writes `TASKS.md` on disk, autosaves.

### Completion Evidence
`productivity/dashboard-usage-guide.md`.

## Phase 4: VS Code integration

Status: in progress, see `vscode-integration-plan.md` for the authoritative phase-by-phase status

### Objective
Bring Cowork's setup into Claude Code CLI and its VS Code extension.

### Outcomes so far
CLI and VS Code extension both installed and confirmed working (2026-08-20). GitHub/Notion/Asana connector wiring declined. Repo-level AGENTS.md scaffolding and Engineering-skill porting both on hold pending a real target repo.

### Exit Criteria
See `vscode-integration-plan.md`'s verification checklist.

### Completion Evidence
Terminal screenshots confirming `claude` launches signed in inside VS Code (2026-08-20); Extensions panel confirming "Claude Code for VS Code" v2.1.238 installed and enabled.

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
