No language/framework/build system in this project itself — SPEC.md is explicit: "no APIs, no build system, no runtime; this is documentation and configuration, not code."

Only executable artifact in scope (excluding the read-only reference clones) is `productivity/dashboard.html`: plain HTML/JS kanban board, no bundler/framework, reads and writes `productivity/TASKS.md` on disk directly, autosaves.

Version control: git, private GitHub repo `github.com/KartikAkolia/claude-agent-workspace`, default branch `master`, `gh` CLI already authenticated on Kartik's machine.

MCP tooling in active use: Serena (code intelligence, launched via `uvx --from serena-agent serena start-mcp-server`), Headroom (context compression, `headroom.EXE mcp serve`).

The five reference clones (dwm-titus, linutil, titus-ai, website, winutil) have their own real tech stacks (Rust, shell, etc.) — irrelevant to this project's own stack, relevant only if reading them as research material.