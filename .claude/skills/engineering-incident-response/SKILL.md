---
name: engineering-incident-response
description: Run an incident response workflow - triage, communicate, and write postmortem. Trigger with "we have an incident," "production is down," an alert that needs severity assessment, a status update mid-incident, or when writing a blameless postmortem after resolution.
---

# Incident Response

## Triage

Assess severity first, before diagnosing root cause — severity determines who needs to be pulled in and how urgently, and that call shouldn't wait on a full diagnosis.
- Scope: how many users/systems affected, is it growing?
- Is there a known safe mitigation (rollback, flag flip, restart) available right now, independent of finding root cause?
- Assign a severity level per whatever scale this org/team uses; if none exists, state impact and urgency explicitly rather than inventing a label.

## During the incident

- Prefer mitigating (stop the bleeding) over diagnosing root cause under time pressure, unless mitigation requires understanding the cause first.
- Status updates: what's known, what's being done, what's still unknown, next update time. Keep it factual — no speculation presented as fact.
- Log a timeline as you go (what was observed, what was tried, when) — reconstructing it afterward from memory is unreliable and this is the raw material for the postmortem.

## Blameless postmortem

Written after resolution, focused on the system and process, not individual blame.

```markdown
# Postmortem: <title>

## Summary
What happened, impact, duration.

## Timeline
Chronological, timestamped. What was observed, decided, and done.

## Root Cause
The actual mechanism, not just the trigger. ("A deploy triggered it" is a trigger; what made the system unable to handle that deploy safely is the cause.)

## Impact
Who/what was affected, how badly, for how long.

## What Went Well / What Went Poorly
Honest on both sides — postmortems that only list failures miss what's worth reinforcing.

## Action Items
Concrete, owned, with a rough timeframe. Distinguish "prevents recurrence" from "reduces detection/mitigation time" — both are valid but shouldn't be conflated.
```
