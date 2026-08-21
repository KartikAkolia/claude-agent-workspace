---
name: engineering-documentation
description: Write and maintain technical documentation. Trigger with "write docs for," "document this," "create a README," "write a runbook," "onboarding guide," or when the user needs help with any form of technical writing - API docs, architecture docs, or operational runbooks.
---

# Technical Documentation

Match the document type to what the reader actually needs to do with it — a README gets someone started, a runbook gets someone through an incident at 3am, an architecture doc gets a new engineer oriented. Pick the structure below that fits, don't force every doc into the same template.

## README
- What this is, in one or two sentences.
- Quick start: the fewest copy-pasteable commands that get it running.
- Where to find more (architecture doc, contributing guide) rather than duplicating that content inline.

## Runbook
- Written for someone under time pressure who doesn't have full context: lead with the fix/command, not background.
- Numbered, copy-pasteable steps. Explicit expected output at each step so the reader can tell if it worked.
- A clearly marked escalation path for when the runbook doesn't resolve it.

## Architecture doc
- What the system does and why it's shaped this way, not just a component diagram.
- Boundaries and contracts between components (what each owns, what it exposes).
- Known trade-offs and their consequences — link to the relevant ADR (see the `engineering-architecture` skill) rather than re-arguing the decision.

## API docs
- Every endpoint/function: inputs, outputs, error cases, and a real example — not just a type signature.
- Document what's NOT obvious from the signature: side effects, rate limits, auth requirements, idempotency.

## Style, regardless of type
- Actionable over descriptive: prefer "run X" to "X should be run."
- Concise over comprehensive: cut anything the reader could infer from the code itself.
- Keep it current: a wrong doc is worse than no doc — if you're not confident a claim is still true, verify against the actual code/config before writing it down.
