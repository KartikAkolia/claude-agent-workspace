---
name: engineering-tech-debt
description: Identify, categorize, and prioritize technical debt. Trigger with "tech debt," "technical debt audit," "what should we refactor," "code health," or when the user asks about code quality, refactoring priorities, or maintenance backlog.
---

# Tech Debt Audit

This skill covers finding, categorizing, and prioritizing debt into a backlog. It is not the tool for executing a refactor once an item is picked — for that, this project has the `code-simplifier` and `pr-review-toolkit` plugins installed (see below), which act on code you point them at rather than surveying a codebase.

## 1. Find candidates

- `grep`/`Grep` for `TODO`, `FIXME`, `HACK` markers left by past authors. For `XXX`, don't match it bare — it collides with `mktemp`-style template strings (`tmp.XXXXXX`) and similar placeholder runs. Require a comment-marker prefix instead, e.g. `(#|//|/\*|--|<!--)\s*XXX\b`, or exclude runs of more than 3 consecutive `X`s with a pattern like `(?<!X)XXX(?!X)`.
- `git log --since=<period> --name-only` for churn — files that change often are either actively evolving (fine) or a recurring pain point (debt) — check which by reading a few of the actual commit messages touching them.
- Test coverage gaps around business-critical logic.
- Dependency staleness — packages far behind current major version, especially ones with known CVEs.
- Structural smells: duplicated logic across files, functions/files that have grown far past what a reader can hold in their head at once.

## 2. Categorize

For each candidate, classify by what it actually costs:
- **Correctness risk** — could cause a real bug (missing error handling, untested critical path).
- **Velocity drag** — doesn't cause bugs but makes changes slow or risky (tangled dependencies, unclear ownership, poor test coverage making refactors scary).
- **Security** — outdated dependency with a CVE, missing input validation, etc.

Don't lump "code I'd have written differently" in with these — stylistic preference isn't debt unless it's actually causing one of the above costs.

## 3. Prioritize

Impact × effort, not just impact alone — a high-impact item that takes a quarter competes differently against three medium-impact items fixable this week. State both explicitly rather than a single vague priority label.

## Output format

```markdown
## Tech Debt Audit: <scope>

| Item | Category | Impact | Effort | Priority |
|------|----------|--------|--------|----------|
| ... | correctness/velocity/security | high/med/low | high/med/low | |

### Recommended next
The 1-3 items worth doing first, with reasoning — a direct recommendation, not just a sorted table.
```

## Executing a fix once prioritized

Once a specific item is chosen, hand it to `code-simplifier` (single-file/module simplification) or `pr-review-toolkit`'s `review-pr` (diff-level review across comments, tests, error handling, type design) rather than doing the audit and the fix in the same pass — keeping them separate keeps the audit honest and not biased toward whatever's easiest to fix immediately.
