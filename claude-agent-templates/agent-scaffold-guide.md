# How ChrisTitusTech Scaffolds Repos for AI Agents

Read across four of his repos: dwm-titus (C window manager), linutil (Rust TUI), website (Astro site), winutil (PowerShell toolkit). Here's the pattern, and templates you can drop into your own projects.

## AGENTS.md: the recurring template

Every repo's AGENTS.md has nearly identical bones, regardless of language:

A pointer to SPEC.md up top. AGENTS.md explicitly defers "what this project is" to SPEC.md and only covers "how to work here." Then a repository map (short annotated list of top-level dirs and what owns what), a sources-of-truth rule for when code and docs disagree, language and tooling conventions, git hygiene rules, literal validation commands to run, and a completion checklist.

linutil states the conflict rule directly: "If documentation and code disagree, do not silently choose one. Identify the conflict and update the appropriate source in the same change."

Tone across all four is terse and imperative. No explanatory prose, no "you might want to." winutil's version is the most agent-aware and has the most personality. It opens with:

> Working code only. Finish the job. Plausibility is not correctness.

It also has a "Non-Negotiables" section and a live "Project Learnings" section the agent is meant to edit itself: "When the user corrects an agent approach, add or tighten one concrete rule here before ending the session." dwm-titus and linutil don't do this. It's the most interesting piece of the four repos: a memory file the agent maintains across sessions.

## CLAUDE.md and GEMINI.md: pure pointer files

Confirmed: no project content, just redirects. In website and winutil, GEMINI.md reads:

> Read AGENTS.md in the repository root for operating instructions before doing anything else.

CLAUDE.md says the same thing in website; in winutil it's just `@AGENTS.md`, Claude Code's native file-inclusion syntax. One source of truth, several pointer files so each agent CLI's default file-discovery convention finds instructions immediately. No content gets duplicated or drifts out of sync.

## SPEC.md vs. AGENTS.md

The line is consistent: SPEC.md is what and why, AGENTS.md is how. winutil states it directly: "AGENTS.md in the repository root points here for these facts, and separately covers how an agent should behave while working in this repo. This file does not change based on who's reading it."

SPEC.md holds product definition, goals and non-goals, architecture, data model, functional requirements per subsystem, platform contracts, and a definition of done. It's the durable, versioned contract, updated only when requirements intentionally change. AGENTS.md holds the repo map, conventions, validation commands, git discipline, and behavioral rules. It changes more often since process shifts faster than product scope.

## ROADMAP.md vs. TASKS.md

Only dwm-titus and website have both. linutil and winutil skip them entirely and rely on SPEC.md's definition-of-done section.

ROADMAP.md is ordered phases, each with objective, outcomes, and exit criteria, plus completion evidence once a phase finishes. Long horizon, one phase can span weeks. Completed phases stay in the file as a dated record rather than getting deleted. dwm-titus: "A phase may advance only when its exit criteria are validated and remaining limitations are recorded."

TASKS.md exists only in dwm-titus. It scopes itself to the single active phase: fine-grained, numbered items (CONN-001, NET-001 style) with checkboxes and an acceptance block. It's disposable by design: "Replace its task set when a phase completes instead of accumulating historical checklists."

So ROADMAP is durable and strategic, TASKS is ephemeral and tactical, replaced wholesale at each phase boundary. Completed work migrates out of TASKS.md into CHANGELOG.md rather than piling up.

## Cross-referencing conventions

Every file names its siblings and restates the read order, so an agent landing on any single file still gets the map. Validation commands are always literal and copy-pasteable, never described in prose. Git discipline repeats near-verbatim in every AGENTS.md: check status first, preserve unrelated changes, no destructive git operations without authorization, never expose secrets. winutil's AGENTS.md is the only one with an explicit "when to ask vs. proceed" rule and a communication-style section, a sign it's the most iterated of the four.

## What this means for your own repos

Four template files are included alongside this guide: `AGENTS.md`, `SPEC.md`, `ROADMAP.md`, `TASKS.md`, plus the one-line `CLAUDE.md` and `GEMINI.md` pointers. Drop them into a repo and fill in the brackets.

For a small or single-maintainer project, skip ROADMAP.md and TASKS.md and rely on SPEC.md's definition-of-done section alone, the way linutil and winutil do. Add the phase-tracking files only once there's genuinely multi-session work to plan across.
