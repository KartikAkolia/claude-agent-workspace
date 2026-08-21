---
name: engineering-deploy-checklist
description: Pre-deployment verification checklist. Use when about to ship a release, deploying a change with database migrations or feature flags, verifying CI status and approvals before going to production, or documenting rollback triggers ahead of time.
---

# Pre-Deployment Checklist

Run through this before a release goes to production. The goal is catching what's easy to forget under release-day pressure, not re-litigating whether the change itself is correct.

## Checklist

- **CI status** — all required checks green, not just "the important ones." Confirm via the actual CI tool/`gh pr checks`, not by assumption.
- **Approvals** — required reviewers have actually approved, not just commented.
- **Database migrations** — reversible? Tested against a copy of real-shaped data? Does it lock tables in a way that matters at current traffic? Migration and code deploy ordering (does old code need to tolerate the new schema, or vice versa, during the rollout window?).
- **Feature flags** — new behavior behind a flag, defaulted off, with a documented plan for who flips it on and when.
- **Rollback plan** — stated *before* deploying, not improvised after: what specifically indicates a rollback is needed (which metric/alert, what threshold), and what the rollback procedure actually is (revert deploy? flip a flag? both?).
- **Monitoring/alerts** — dashboards or alerts that would surface a problem exist and are being watched during the rollout window.
- **Communication** — who needs to know the deploy is happening (on-call, dependent teams) and who needs to know if it goes wrong.

## Output format

Present as a literal checklist the user can tick through, with any "no" or "unknown" answers called out explicitly rather than glossed over — an unanswered checklist item is a risk, not a formality.
