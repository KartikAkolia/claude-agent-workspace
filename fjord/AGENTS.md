# AGENTS.md

Read this before every task in `fjord/`. `SPEC.md` is the product contract; this file covers how to work here. This project follows the root repo's own `AGENTS.md` conventions (phased docs, explicit-ask on structural decisions) — read that first for the workspace-wide rules; this file only covers what's specific to Fjord.

## What Fjord Is

A read-only Astro site for browsing and reading this repo's own documentation — the root-level docs, `docs/`, `productivity/`'s non-dashboard files, and `claude-agent-templates/` — in a clean, Nord-themed reading UI. It replaces `productivity/dashboard.html` as the workspace's entry point. See `SPEC.md` for the full contract.

## Non-Negotiables (rules that override the rest)

1. Fjord is read-only. It renders the real files living elsewhere in this repo — never writes back to them, never edits them, no write-back/editing feature without Kartik explicitly asking for one. The one deliberate difference from `productivity/dashboard.html`'s editable kanban.
2. Never duplicate or copy the source docs into `fjord/`'s own tree. Content is read live from its real on-disk location (root `*.md`, `docs/`, `productivity/*.md` excluding the archived dashboard bundle, `claude-agent-templates/*.md`) via Astro's content-collection `glob()` loader, per `SPEC.md`'s architecture section.
3. The five reference clones (`dwm-titus-main/`, `linutil-main/`, `titus-ai-main/`, `website-master/`, `winutil-main/`) are excluded from Fjord's content entirely, per the root `AGENTS.md`'s non-negotiable that they're read-only research material — don't add them to a content collection even as a "browse-only" convenience without asking first.
4. `website-master` is reference-only for Astro setup style (content collections, static output, component layout, TypeScript, a dev script), not for scope. Do not port its shortcode/taxonomy/legacy-redirect/RSS/YouTube machinery. Never hand-edit `website-master/` itself.
5. No deployment until Kartik says so — on hold pending a review of whether any in-scope doc contains sensitive homelab/network detail. Don't add hosting config, a live URL, or a `deploy` script without his explicit go-ahead.
6. Ask before a decision only Kartik can make (palette variant, layout direction, when to actually delete the archived dashboard). Don't guess and proceed on those.

`productivity/dashboard.html`'s retirement (archived, not deleted, to `productivity/dashboard-archive/`) is recorded in `ROADMAP.md` Phase 4, not repeated here.

## Repository Map

- `SPEC.md`: what Fjord is, its architecture, functional requirements.
- `ROADMAP.md`: ordered phases for this sub-project.
- `TASKS.md`: active-phase detail only.
- (Phase 2 onward) `src/`, `astro.config.mjs`, `package.json`: the Astro project itself, once scaffolded.

## Sources of Truth

- `SPEC.md`: update only when the actual goal changes.
- `ROADMAP.md` / `TASKS.md`: phase order and active-phase detail, same convention as the root repo.
- The root repo's `AGENTS.md`: workspace-wide rules (reference-clone protection, verification discipline, tool-usage rules) apply here too.

## Conventions

Astro + TypeScript, matching `website-master`'s stack choice. Markdown throughout for docs. No filler, no unverified claims about what's "done" — same standard as the root repo.

## Change Discipline

- Check what's already on disk in `fjord/` before writing.
- Small, targeted file writes, one reviewable phase at a time.
- Never touch the source docs Fjord renders (see non-negotiable 1).

## Validation

Confirm a write succeeded via the tool's own result. Once the Astro project exists (Phase 2+), `npm run dev` booting without error and rendering every in-scope doc is the baseline check before each phase is called done.

## Completion Criteria

Matches `SPEC.md`. Every claim about what's built or working is verified by actually running it, not assumed.

## Project Learnings

- Kartik delegated the project name to the agent — settled on "Fjord": a calm, navigable channel, fits a documentation-reading tool, stays inside the Nord/Nordic naming family without colliding with the "Nord" palette name itself.
- Kartik wants moodboards to drive the final visual direction before any component code is written — not optional here even though the root instructions call moodboards optional in general.
