---
name: engineering-debug
description: Structured debugging session - reproduce, isolate, diagnose, and fix. Trigger with an error message or stack trace, "this works in staging but not prod," "something broke after the deploy," or when behavior diverges from expected and the cause isn't obvious.
---

# Structured Debugging

Work the problem in order. Do not jump to a fix before the cause is confirmed — a fix for the wrong cause wastes a cycle and can mask the real bug.

## 1. Reproduce

Get a reliable, minimal reproduction before anything else. If it can't be reproduced, the "fix" can't be verified.
- Exact steps/input that trigger it, and the exact expected vs. actual output.
- Note what environment it happens in (prod only? specific input? specific timing/concurrency?) — that scoping is itself a diagnostic clue.

## 2. Isolate

Narrow down where the divergence starts, not just where it surfaces.
- `git log`/`git blame` on the affected file(s) to find what changed recently, if this is a regression ("worked before").
- If "works in staging but not prod": diff the environments — config, env vars, data, versions — before assuming it's a code bug.
- Bisect: comment out / stub sections, or use `git bisect`, to shrink the search space rather than reading the whole call path.

## 3. Diagnose

Form a specific, falsifiable hypothesis ("X is null because Y") before changing code. Confirm it with a log line, breakpoint, or minimal test — don't confirm by "fixing" and seeing if it goes away.

## 4. Fix

Fix the actual cause, not the symptom. If the fix is a defensive check/try-catch around a value that "shouldn't" be null, that's usually a sign the diagnosis stopped one layer too early.

## 5. Verify

Re-run the exact reproduction from step 1 and confirm the expected output. Check for regressions in adjacent behavior the fix could plausibly affect.

## Reporting

State the root cause in one sentence before describing the fix — the reader should be able to tell whether the fix actually addresses the cause.
