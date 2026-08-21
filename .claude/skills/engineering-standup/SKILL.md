---
name: engineering-standup
description: Generate a standup update from recent activity. Use when preparing for daily standup, summarizing yesterday's commits and PRs and ticket moves, formatting work into yesterday/today/blockers, or structuring rough notes into a shareable update.
---

# Standup Update

Pull from actual recent activity rather than asking the user to reconstruct it from memory, when that activity is available:
- `git log --author=<user> --since=yesterday --oneline` for commits.
- `gh pr list --author @me` / `gh pr status` for PRs opened, reviewed, merged.
- Any ticket/issue tracker the user references — ask which one if unclear, don't assume.

## Format

```markdown
**Yesterday:** What was completed or meaningfully progressed. Specific enough to be useful (which PR/ticket), not "worked on backend stuff."
**Today:** What's planned, in priority order.
**Blockers:** Anything actually stopping progress — waiting on a review, a decision, an external dependency. Omit this line entirely if there are none; don't pad it.
```

Keep each line to what a teammate skimming a channel actually needs — link to the PR/ticket rather than re-explaining its contents inline.
