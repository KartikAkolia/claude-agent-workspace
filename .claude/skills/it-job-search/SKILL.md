---
name: it-job-search
description: Plan and run an IT/tech job search — target-role definition, resume and LinkedIn tailoring, ATS optimization, certification gap analysis, application tracking, interview prep, and offer negotiation. Trigger with "help me find an IT job," "tailor my resume for this posting," "am I ATS-ready," "which IT cert should I get," "prep me for a technical interview," "help me negotiate this offer," or whenever the user is job hunting in tech/IT.
---

# IT Job Search

A tech job search is a small project with phases, gates, and outward-facing steps — treat
it that way rather than answering each question in isolation. Structure follows
`ai-project-manager`'s phase-and-checkpoint discipline; sourcing and content quality
follow `docs/personal-research-guidelines.md`; writing quality follows
`engineering-documentation`'s "actionable over descriptive, concise over comprehensive"
standard. Market/cert/ATS/interview/negotiation facts referenced below are pre-researched
and cited in `references/` — read the relevant reference file before asserting a market
figure, cert requirement, or negotiation norm from memory.

## Workflow

1. **Intake.** Before doing anything else, establish: target job title(s) (1–3, not a
   vague field), seniority/experience level, location or remote constraints, timeline/
   urgency, and what already exists (current resume, LinkedIn profile, certs, prior
   applications). Don't guess these — every later phase depends on them, and this repo's
   AGENTS.md rule against guessing on decisions only the user can make applies here too.
2. **Target & gap analysis.** Compare the user's actual skills/experience/certs against
   what the target role(s) typically require — cross-reference
   `references/role-requirements.md` for BLS/CompTIA data, and the target role's own
   posting(s) where available. Name concrete gaps (a specific cert, a portfolio project,
   a category of missing experience), not vague "learn more X." If a target role is a
   poor match for the user's actual background, say so rather than proceeding as if it
   fits.
3. **Resume & LinkedIn tailoring.** Tailor per job posting, not as a generic rewrite —
   see `references/resume-ats.md` for what actually moves ATS match rate and reads well
   to a human. Extract the posting's own keyword/skill/title phrasing, check coverage,
   fix formatting that breaks ATS parsing (tables, headers/footers, non-standard fonts).
   Never write a claim, metric, or credential the user hasn't confirmed is true.
4. **Application tracking.** Maintain a tracker (a markdown table or a file the user
   already uses) with status columns — e.g. Applied / Interviewing / Offer / Rejected /
   Withdrawn — so search progress is visible instead of re-derived each session. Update
   status only on evidence (a confirmation email, a scheduled interview, an explicit
   user statement), the same "propose, don't silently move" discipline
   `productivity-update` uses for its own board.
5. **Interview prep.** Pull the likely process shape for the role type from
   `references/interview-prep.md`, and build behavioral answers in STAR format from the
   user's own real work history — never invent a scenario or outcome. Match technical
   prep depth to what the actual target role calls for (don't run algorithm-heavy prep
   for a support/sysadmin role, or skip it for one that needs it).
6. **Offer & negotiation.** Use `references/negotiation.md` (SHRM guidance) to frame
   total compensation, not just base salary, and draft a counter script. This step is
   outward-facing and hard to reverse once sent — draft for the user's review and send;
   never message a recruiter or employer directly on the user's behalf.

Phases don't have to run in one sitting — pick up wherever the user actually is (e.g.
skip straight to interview prep if resume/tracking are already handled elsewhere).

## Research discipline

Any market, salary, certification, or hiring-practice claim not already covered in
`references/` must be sourced live per `docs/personal-research-guidelines.md`: official
bodies (BLS, CompTIA, SHRM), established industry publications with editorial oversight,
or named vendors treated as vendor-sourced rather than neutral. Exclude uncited,
generic-sounding, or unverifiable claims. Cite the source and distinguish fact from
analysis/opinion, the same standard already applied in `references/`.

## Safety rules

- Never fabricate resume, LinkedIn, or interview-answer content — every claim traces to
  something the user actually did.
- Never send an application, message a recruiter, or reply to an offer on the user's
  behalf without their explicit review and send-approval.
- Never assume salary targets, location constraints, or target roles the user hasn't
  confirmed.
- Never present a generic web claim as fact without a source; flag uncertainty rather
  than smoothing over it.
- Keep the user's own resume drafts, tracker, and target-role decisions in the user's own
  files — this skill's `references/` stay domain-general research, not the user's
  personal data.

## Validation

- Tailored resume/LinkedIn content traces to both the actual posting and the user's
  actual, confirmed experience.
- Tracker reflects real, evidenced application status, not assumed status.
- Interview prep matches the process shape and depth the target role actually calls for.
- Any cited market/cert/salary/negotiation claim traces to an authoritative source, per
  `references/` or a live lookup under the same standard.
- Nothing outward-facing (application, message, negotiation reply) was sent without the
  user's explicit approval.
