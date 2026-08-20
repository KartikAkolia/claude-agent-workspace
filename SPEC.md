# SPEC.md

What this project is and how it's built, not how to work on it (see `AGENTS.md`).

## Product Definition

Kartik's personal setup connecting two separate Claude surfaces, Cowork (this cloud session) and Claude Code CLI plus its VS Code extension (running locally on his Windows 11 machine), around one shared documentation convention: ChrisTitusTech's AGENTS.md/SPEC.md/ROADMAP.md/TASKS.md pattern, plus CLAUDE.md/GEMINI.md pointer files. The goal is that either surface, opened cold, can read the same files and understand what's going on without Kartik re-explaining it.

## Goals / Non-Goals

- Goals: give any future Cowork session, or any `claude` invocation anywhere in this folder tree, consistent and accurate context. Keep the reference material (ChrisTitusTech's own repos) separate from and unmodified by Kartik's own configuration.
- Non-goals: this isn't software with users other than Kartik. It doesn't track or modify the ChrisTitusTech repos' own development. It doesn't replace `productivity/`'s kanban task tracking, that's a separate system for a separate purpose.

## Architecture

A single Windows folder (`C:\Users\Kartik\Downloads\Github`) connected to this Cowork session as its one accessible root. Five subfolders of read-only reference material, one `claude-agent-templates/` folder of reusable blank scaffolding, one `productivity/` folder running Cowork's dashboard skill, and this root-level scaffold describing the meta-project itself. Continuity across Cowork sessions runs through `handoff.md`. Continuity for the `claude` CLI runs through this `AGENTS.md`, reached via the `CLAUDE.md` pointer at the folder root.

## Functional Requirements

- A Cowork session picking up mid-project reads `handoff.md`, then this `AGENTS.md`/`SPEC.md`, and has enough context to continue without re-deriving decisions already made.
- Running `claude` from anywhere under this folder tree finds this `CLAUDE.md`, follows it to `AGENTS.md`, and gets the same context instead of the generic `/init` prompt.
- The reference clones stay untouched regardless of what work happens elsewhere in the tree.

## Interfaces / Contracts

File layout as described in `AGENTS.md`'s Repository Map. No APIs, no build system, no runtime; this is documentation and configuration, not code.

Version control: private GitHub repo at `github.com/KartikAkolia/claude-agent-workspace`, default branch `master`. Includes the full folder tree, the five reference codebases included by Kartik's explicit choice rather than excluded.

## Testing & CI

None. Validation is manual: confirm on-disk state directly, never report something done without having verified it.

## Acceptance Criteria / Definition of Done

Opening `claude` anywhere in this folder tree surfaces real project context, not a generic `/init`-generated file. A new Cowork session reading `handoff.md` plus these files can state accurately what's done, what's declined, and what's still open, matching `vscode-integration-plan.md`'s status log.
