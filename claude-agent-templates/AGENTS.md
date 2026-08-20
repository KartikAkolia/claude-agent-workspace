# AGENTS.md

Read this before every task. `SPEC.md` is the product contract; this file covers how to work here.

## Non-Negotiables (rules that override the rest)

1. Never edit generated/build output directly; change the source and rebuild.
2. Never fabricate paths, output, or results, read or run to verify.
3. Ask when two interpretations would produce materially different diffs.

## Repository Map

- `<dir>`: `<what it owns>`
- `<dir>`: `<what it owns>`

## Sources of Truth

- `SPEC.md`: product scope, architecture, acceptance criteria. Update it only when requirements intentionally change.
- `ROADMAP.md`: ordered phases. `TASKS.md`: active-phase work only.

If code and docs disagree, resolve it in the same change instead of silently picking one.

## Conventions

`<language, style, and naming rules; add a per-stack section if the repo is polyglot>`

## Change Discipline

- Inspect `git status` before editing; preserve unrelated changes.
- Small, reviewable commits. No destructive git operations without authorization.
- Never expose secrets or credentials.

## Validation

`<exact, copy-pasteable commands, narrowest scope first, then broaden>`

## Completion Criteria

- Matches `SPEC.md`. Tests and lint pass. Docs updated. Report what was skipped or untested.

## Project Learnings

`<append one durable rule here per user correction; prune rules that no longer matter>`
