# AGENTS.md

Read this before every task. `SPEC.md` is the product contract; this file covers how to work here.

## Non-Negotiables (rules that override the rest)

1. Never write into `dwm-titus-main/`, `linutil-main/`, `titus-ai-main/`, `website-master/`, or `winutil-main/`. They are ChrisTitusTech's reference clones, read-only research material, not this project's own code.
2. Never fabricate what's installed, configured, or delivered. Verify by reading the actual file or the actual tool output before reporting something done.
3. Ask before a decision only Kartik can make (which repo gets scaffolding, which connectors to wire up, whether to force a structural code merge). Don't guess and proceed on those.

## Repository Map

- `claude-agent-templates/`: blank AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md/CLAUDE.md/GEMINI.md templates, plus the research notes they were distilled from (`agent-scaffold-guide.md`, `titus-ai-windows-setup.md`, `titus-ai-windows-packages-research.md`). Reusable scaffolding for Kartik's own future repos, kept blank on purpose. Copy these out to a real project before filling them in, don't fill them in here.
- `productivity/`: Cowork's productivity-skill artifact. A kanban dashboard (`dashboard.html`), its own `TASKS.md` (Active/Waiting On/Someday/Done convention, unrelated to this file's `TASKS.md`), and Cowork's memory file (`CLAUDE.md`, unrelated to Claude Code's per-repo `CLAUDE.md` despite the shared name).
- `dwm-titus-main/`, `linutil-main/`, `titus-ai-main/`, `website-master/`, `winutil-main/`: ChrisTitusTech's own repos, downloaded as research material for the AGENTS.md convention. Read-only reference. Do not edit.
- `vscode-integration-plan.md`: the five-phase plan for bringing this setup into VS Code, with a running status log of what's actually done, declined, or on hold.
- `handoff.md`: continuity note for Cowork sessions. Read this and the files it points to before resuming work after a session gap.

## Sources of Truth

- `SPEC.md`: what this project is and its acceptance criteria. Update only when the actual goal changes.
- `ROADMAP.md`: ordered phases across both Cowork and Claude Code CLI work. `TASKS.md`: active-phase detail only.
- `vscode-integration-plan.md`: the authoritative status of VS Code integration specifically, phase by phase.

If a doc and the actual on-disk or on-device state disagree, resolve it in the same session: verify against the real file or command output, then fix whichever doc is wrong.

## Conventions

Markdown throughout. Prose over bullet lists except where content is genuinely list-like. No filler, no unverified claims about what's "done."

## Change Discipline

- Check what's already on disk before writing (list the folder, don't assume).
- Never overwrite `productivity/dashboard.html`, `productivity/TASKS.md`, or anything inside the five reference clones without being explicitly asked.
- Small, targeted file writes. No destructive operations on Kartik's machine without explicit approval.

## Validation

Confirm a write succeeded via the tool's own result, not by re-reading unless something looks wrong. Confirm delivery two ways when a file matters to Kartik: an in-conversation copy and the on-disk copy in this folder, and report both.

## Completion Criteria

- Matches `SPEC.md`. Every claim about what's installed or configured is verified, not assumed. Report what was skipped or left for Kartik to run himself, most commonly anything needing his terminal or his credentials.

## Project Learnings

- Kartik prefers a direct recommendation over a neutral list of options when one choice is clearly better.
- This Cowork session has no shell access to Kartik's machine, only file read/write on the connected folder and browser automation. Don't propose running installs or CLI commands as something Cowork itself can execute.
- Two `TASKS.md` files and two `CLAUDE.md` files coexist in this folder tree under different, unrelated conventions. Don't conflate them when reading or writing.
