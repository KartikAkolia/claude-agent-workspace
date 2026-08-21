Personal Windows setup connecting two Claude surfaces (Cowork cloud sessions + Claude Code CLI/VS Code extension) around a shared documentation convention (ChrisTitusTech's AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md + CLAUDE.md/GEMINI.md pointers). Not software: no build system, no runtime, no APIs — see SPEC.md for the full contract.

Root: `C:\Users\Kartik\Downloads\Github`. Windows 11 Pro, winget preferred for package installs.

Non-negotiables (AGENTS.md):
- Never write into `dwm-titus-main/`, `linutil-main/`, `titus-ai-main/`, `website-master/`, `winutil-main/` — ChrisTitusTech's read-only reference clones, not this project's own code.
- Never fabricate what's installed/configured/delivered — verify by reading the actual file or tool output first.
- Ask before decisions only Kartik can make (which repo gets scaffolding, which connectors to wire up, forcing a structural merge).

Structure:
- `claude-agent-templates/` — blank, reusable AGENTS/SPEC/ROADMAP/TASKS/CLAUDE/GEMINI templates + research notes. Copy out to a real project before filling in; keep blank here.
- `productivity/` — Cowork's kanban dashboard (`dashboard.html`) plus its own `TASKS.md`/`CLAUDE.md` under an unrelated convention (see `mem:conventions`).
- Five ChrisTitusTech reference clones — read-only research material.
- `vscode-integration-plan.md` — authoritative status of VS Code integration specifically.
- `handoff.md` — continuity note for Cowork sessions across gaps.

See `mem:tech_stack`, `mem:suggested_commands`, `mem:conventions`, `mem:task_completion`.