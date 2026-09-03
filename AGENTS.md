# AGENTS.md

Read this before every task. `SPEC.md` is the product contract; this file covers how to work here.

## Non-Negotiables (rules that override the rest)

1. Never hand-edit `dwm-titus-main/`, `linutil-main/`, `titus-ai-main/`, `website-master/`, or `winutil-main/`. They are ChrisTitusTech's reference clones, read-only research material, not this project's own code. The one exception: an explicit, Kartik-authorized wholesale resync of a mirror with its GitHub upstream (via `refresh-reference-clone.sh`), which replaces a mirror's content outright rather than editing it — still never mix your own changes into one.
2. Never fabricate what's installed, configured, or delivered. Verify by reading the actual file or the actual tool output before reporting something done.
3. Ask before a decision only Kartik can make (which repo gets scaffolding, which connectors to wire up, whether to force a structural code merge). Don't guess and proceed on those.
4. Before defaulting to generic Read/Edit/Bash/Grep, check whether Serena, a Skill, or Context7 fits better — and use it, for the whole task, not just the turn right after being asked. Specifically: Serena's `find_symbol` / `find_referencing_symbols` / `replace_symbol_body` for navigating or editing this repo's own code, instead of grep-and-edit string-matching; a matching `.claude/skills/engineering-*` skill (e.g. `engineering-debug` for bug hunts) before ad hoc reasoning; Context7 before relying on training knowledge for library/API/CLI-flag behavior. This has been asked for directly and then dropped mid-task twice already (2026-08-21, 2026-08-27 — see `feedback_use_all_tools.md`), so it's a standing rule here, not a one-turn favor. `.claude/hooks/suggest-serena.py` (wired via `.claude/settings.json`) backs this up mechanically for the Bash-grep case by injecting a reminder — it never blocks, so it doesn't replace actually checking.

## Repository Map

- `claude-agent-templates/`: blank AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md/CLAUDE.md/GEMINI.md templates, plus the research notes they were distilled from (`agent-scaffold-guide.md`, `titus-ai-windows-setup.md`, `titus-ai-windows-packages-research.md`). Reusable scaffolding for Kartik's own future repos, kept blank on purpose. Copy these out to a real project before filling them in, don't fill them in here.
- `productivity/`: Cowork's productivity-skill artifact. Its kanban dashboard (`dashboard.html` and everything that supported it — tests, `test-helpers/`, the usage guide, `backups/`) was retired 2026-09-03 (`fjord/ROADMAP.md` Phase 4) and archived, not deleted, under `productivity/dashboard-archive/` (see that folder's own `README.md` for what's there and how to revert). `TASKS.md` (Active/Waiting On/Someday/Done convention, unrelated to this file's `TASKS.md`) and Cowork's memory file (`CLAUDE.md`, unrelated to Claude Code's per-repo `CLAUDE.md` despite the shared name) stayed live at Kartik's choice — Fjord's `productivity` collection still renders both.
- `fjord/`: a read-only Astro site (Nord palette) for browsing this repo's own documentation, having replaced `productivity/dashboard.html` as the workspace's entry point once built and once its Phase 4 retired the dashboard. Has its own `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md` — that project's docs are the source of truth for its phases from here on, same pattern as `personal-website`/Loopwire had. Started 2026-08-29, halted the same day once Phases 0–3 were done — Kartik forked its structure into `estuary/` (below) rather than continuing it — then resumed 2026-09-03 for Phase 4 specifically.
- `estuary/`: a static Astro e-reader site, forked from Fjord's Nord Terminal visual language, for Kartik to study ahead of University of Greenwich course P12069 (BSc Hons Computer Science, Year 0, starting 2026-09-14). Original authored content, not a mirror of anything in this repo. Has its own `AGENTS.md`/`SPEC.md`/`ROADMAP.md`/`TASKS.md`, same pattern as `fjord`/`personal-website`/Loopwire. Started 2026-08-29. Unlike `fjord`, it's its own git repo (`KartikAkolia/estuary`, private), not committed into this monorepo — the folder is present here for convenience but is gitignored from this repo, same pattern as `personal-website/`. Deployed publicly via Cloudflare Workers as `estuary.kartikpassbolt.org` (Kartik authorized deployment and confirmed the subdomain 2026-08-29).
- `dwm-titus-main/`, `linutil-main/`, `titus-ai-main/`, `website-master/`, `winutil-main/`: ChrisTitusTech's own repos, downloaded as research material for the AGENTS.md convention. Read-only reference. Do not edit by hand; `refresh-reference-clone.sh <owner/repo> <branch> <local-dir>` resyncs one from its upstream tarball when asked.
- `docs/vscode-integration-plan.md`: the five-phase plan for bringing this setup into VS Code, with a running status log of what's actually done, declined, or on hold.
- `docs/handoff.md`: continuity note for Cowork sessions. Read this and the files it points to before resuming work after a session gap.

## Sources of Truth

- `SPEC.md`: what this project is and its acceptance criteria. Update only when the actual goal changes.
- `ROADMAP.md`: ordered phases across both Cowork and Claude Code CLI work. `TASKS.md`: active-phase detail only.
- `docs/vscode-integration-plan.md`: the authoritative status of VS Code integration specifically, phase by phase.

If a doc and the actual on-disk or on-device state disagree, resolve it in the same session: verify against the real file or command output, then fix whichever doc is wrong.

## Conventions

Markdown throughout. Prose over bullet lists except where content is genuinely list-like. No filler, no unverified claims about what's "done."

## Change Discipline

- Check what's already on disk before writing (list the folder, don't assume).
- Never overwrite `productivity/TASKS.md`, `productivity/dashboard-archive/` (the retired dashboard, kept for possible revert — see `fjord/ROADMAP.md` Phase 4), or anything inside the five reference clones without being explicitly asked.
- Small, targeted file writes. No destructive operations on Kartik's machine without explicit approval.

## Validation

Confirm a write succeeded via the tool's own result, not by re-reading unless something looks wrong. Confirm delivery two ways when a file matters to Kartik: an in-conversation copy and the on-disk copy in this folder, and report both.

## Completion Criteria

- Matches `SPEC.md`. Every claim about what's installed or configured is verified, not assumed. Report what was skipped or left for Kartik to run himself, most commonly anything needing his terminal or his credentials.

## Project Learnings

- Kartik prefers a direct recommendation over a neutral list of options when one choice is clearly better.
- This Cowork session has no shell access to Kartik's machine, only file read/write on the connected folder and browser automation. Don't propose running installs or CLI commands as something Cowork itself can execute.
- Two `TASKS.md` files and two `CLAUDE.md` files coexist in this folder tree under different, unrelated conventions. Don't conflate them when reading or writing.

<!-- headroom:learn:start -->

## Headroom Learned Patterns

*Auto-generated by `headroom learn` on 2026-08-21 — do not edit manually*

### Environment — Git Bash on Windows

*~1,500 tokens/session saved*

- Windows CLI utilities like `tasklist` need double-slash flags in Git Bash (e.g. `tasklist //FI "IMAGENAME eq foo.exe" //FO CSV`), not `/FI` — a single slash gets parsed as a path and fails with 'Invalid argument/option'.
- `wmic` is not available in this Git Bash environment (`command not found`) — use `tasklist //FI ...` instead for process lookups.

### Headroom CLI Quirks

*~1,200 tokens/session saved*

- `headroom doctor` exits with code 1 even when there are 0 failures (only warnings) — check the printed "N failure(s), M warning(s)" line, not the shell exit code, before treating it as an error.
- `headroom learn` takes no `--verbosity` flag on its own; run `headroom learn` directly for a dry run (add `--apply` to write changes) rather than probing flags first.
- `headroom config` is not a valid subcommand.

<!-- headroom:learn:end -->
