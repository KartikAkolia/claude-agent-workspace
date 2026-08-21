---
name: productivity-update
description: Sync productivity/TASKS.md from current activity and triage stale items. Use when the user says "sync my tasks," "update my tasks," "what's stale," "pull in new tasks," or after a work session produced deliverables not yet reflected on the board.
---

# Task Sync & Triage

Claude Code CLI port of Cowork's `productivity:update` skill. Scope is narrower than Cowork's version by necessity — see "Not available" below. Don't imply parity with the Cowork version when reporting results.

## Which file

Always `productivity/TASKS.md` (the kanban board: Active / Waiting On / Someday / Done). Never the root-level `TASKS.md` — that one tracks this repo's own active development phase, a completely different convention (see `AGENTS.md`). If it's ambiguous which one the user means, ask rather than guess.

## What this pulls from

No Gmail/Calendar/Notion/Asana connector is wired up in this project (declined, see `vscode-integration-plan.md`) — so unlike Cowork's `--comprehensive` scan across email/chat/calendar, the only real sources here are:
- The current conversation: explicit asks, mentioned deliverables, things the user said they'd do.
- `git log` in whichever repo is active, for completed work that isn't yet reflected as Done.
- Cross-checking existing Active/Waiting On tasks against real evidence (a referenced file, PR, or deliverable actually existing on disk) to catch tasks that are done but not yet moved.

## Process

1. Read `productivity/TASKS.md` as it currently stands.
2. Scan the current conversation for actionable items not already on the board — add candidates to Active in the task's own words, not paraphrased into something vaguer.
3. For each Active/Waiting On task, check whether its implied evidence (a file, PR, commit) actually exists now. If a task implies "deliver X" and X exists on disk, flag it as a candidate to move to Done — propose, don't move silently.
4. Report proposed additions and moves; apply only what the user confirms. Don't silently rewrite the board — matches `AGENTS.md`'s rule against guessing on decisions only the user can make.

## Output format

```markdown
## Task Sync: <date>

### New (proposed)
- ...

### Move to Done (proposed, evidence found)
- <task> — evidence: <file/PR/commit>

### Stale (no visible progress — flagging, not moving)
- <task> — last touched <when, if knowable>
```

## Not available (state this plainly, don't fake it)

No email/chat/calendar scan — those connectors are declined for this project. No persistent cross-session task memory beyond what's actually written in `TASKS.md` and the current conversation; Cowork's own memory system is a separate product and doesn't transfer here.
