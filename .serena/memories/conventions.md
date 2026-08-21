Markdown throughout. Prose over bullet lists except where content is genuinely list-like. No filler, no unverified "done" claims.

Doc roles (don't blur these):
- `SPEC.md` — product contract; update only when the actual goal changes.
- `ROADMAP.md` — ordered phases across both Cowork and Claude Code CLI work.
- `TASKS.md` (root) — active-phase detail only; replaced, not accumulated, when a phase completes.
- `docs/vscode-integration-plan.md` — authoritative status of VS Code integration specifically, phase by phase.

Two `TASKS.md` files coexist under unrelated conventions: root-level (this project's phase tracking, replaced per phase) vs `productivity/TASKS.md` (Active/Waiting On/Someday/Done kanban convention for Cowork's dashboard). Don't conflate.

Two `CLAUDE.md` files coexist under unrelated conventions: root-level (`@AGENTS.md` pointer, read by Claude Code CLI) vs `productivity/CLAUDE.md` (Cowork's own memory file — who Kartik is, his research standards). Don't conflate.

If a doc and the actual on-disk or on-device state disagree, resolve it in the same session: verify against the real file or command output, then fix whichever doc is wrong.