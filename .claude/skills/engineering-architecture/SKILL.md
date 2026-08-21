---
name: engineering-architecture
description: Create or evaluate an architecture decision record (ADR). Use when choosing between technologies (e.g., Kafka vs SQS), documenting a design decision with trade-offs and consequences, reviewing a system design proposal, or designing a new component from requirements and constraints.
---

# Architecture Decision Records

Help the user choose between options and record the decision so future readers understand why, not just what.

## When to produce a full ADR vs. a quick recommendation

A quick recommendation (a few sentences, main trade-off, no file written) is enough for reversible, low-blast-radius choices. Write a full ADR when the decision is expensive to reverse, affects multiple teams/services, or the user explicitly asks to document it.

## ADR workflow

1. **Frame the decision** — one sentence: what is being decided, and what triggered the need to decide now.
2. **List real options** — not a strawman vs. the obvious winner. Each option gets its actual trade-offs, not just its downsides.
3. **State the constraints** — what's non-negotiable (latency budget, existing infra, team expertise, cost ceiling) that rules options in or out before comparing them on preference.
4. **Recommend one option** — with the reasoning, not just the choice. Match this project's preference for a direct recommendation over a neutral list when one option is clearly better.
5. **Record consequences** — what this decision makes easier, what it makes harder or forecloses, and what would trigger revisiting it.

## ADR template

```markdown
# ADR-NNN: <short title>

Status: proposed | accepted | superseded by ADR-XXX
Date: YYYY-MM-DD

## Context
What problem forces this decision. What constraints apply.

## Options Considered
| Option | Pros | Cons |
|--------|------|------|
| A      |      |      |
| B      |      |      |

## Decision
Which option, and the deciding factor(s).

## Consequences
What this enables, what it costs or forecloses, what would trigger revisiting this ADR.
```

## Evaluating an existing proposal

When asked to review someone else's design/ADR rather than write one: check the options list is genuinely comparative (not pre-decided), check constraints are stated before the comparison rather than discovered after, and check consequences cover downsides honestly, not just upsides.
