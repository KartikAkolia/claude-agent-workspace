---
name: engineering-testing-strategy
description: Design test strategies and test plans. Trigger with "how should we test," "test strategy for," "write tests for," "test plan," "what tests do we need," or when the user needs help with testing approaches, coverage, or test architecture.
---

# Testing Strategy

## Match test type to what it verifies

- **Unit tests**: a single function/module's logic in isolation, especially edge cases and branching logic. Cheap to write and run — default here for pure logic.
- **Integration tests**: that components actually work together (real DB, real API contracts between services) — use where the risk is in the seams, not the logic.
- **End-to-end tests**: a full user-facing flow works — expensive and slower, reserve for the paths that would be most damaging to break silently.

## Prioritize by risk, not by ease

Coverage priority should track: how bad is it if this breaks, and how likely is it to break (complexity, change frequency, past bug history) — not just what's easiest to test. A rarely-changed, low-complexity utility needs less test investment than a frequently-changed function handling money or auth, even if the utility is easier to test.

## Test plan format

```markdown
## Test Plan: <feature/change>

### Scope
What's being tested, what's explicitly out of scope.

### Cases
| Scenario | Type | Priority | Notes |
|----------|------|----------|-------|
| Happy path | unit/integration/e2e | high | |
| Edge case: ... | | | |
| Failure mode: ... | | | |

### Out of scope
What's deliberately not covered here and why (e.g., covered elsewhere, not worth the cost at current risk level).
```

## When reviewing existing test coverage

Look for tests that pass regardless of whether the code is correct (asserting on mocks instead of real behavior, or not asserting on the meaningful output at all) — coverage percentage alone doesn't mean the tests would actually catch a regression.
