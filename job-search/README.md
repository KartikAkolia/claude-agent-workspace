# Kartik's IT Job Search

Working notes from an `it-job-search` skill session, 2026-08-30. Personal job-search
data — kept out of the skill's own `references/` directory on purpose (that stays
domain-general research, not personal data), per the skill's own safety rules.

## Candidate snapshot

Source: `~/Documents/CV-KartikAkolia.pdf` (scanned via Brother DCP-L2665DW + Simple
Scan, same session).

- BTEC Level 3 National Extended Diploma in Information Technology, Chelmsford
  College — **completed**.
- No formal work history — confirmed directly with Kartik, never had a job before.
- Substantial self-directed home lab: rootless Docker + systemd services, Nginx
  Proxy Manager reverse proxy with Let's Encrypt (SSL Labs A+), k3s Kubernetes
  cluster, AdGuard Home encrypted DNS (DoT/DoH), UFW + SSH hardening + fail2ban,
  Cloudflare-fronted public domain (kartikpassbolt.org), Uptime Kuma monitoring,
  Vaultwarden, Trilium Notes documentation. Genuinely strong practical evidence for
  a self-taught candidate — this is not the gap.
- The original scan (`~/Documents/CV-KartikAkolia.pdf`) was a **marked-up draft**.
  A clean digital copy now exists — see CV Digital Copy below — with most of the
  scan's handwritten edits applied; a few are still open, left for Kartik.

## Target roles & constraints (confirmed with Kartik 2026-08-30)

- Titles considered: **1st Line IT Support**, **IT Support Technician**, **Junior
  Systems Administrator**.
- Starting University of Greenwich (BSc Hons Computer Science, Year 0, course
  P12069) **full-time from 2026-09-14** — looking for **part-time** work only,
  compatible with that.
- Location: **London only**. Can't drive — public transport commute only.
- No LinkedIn profile yet.
- Will hold a degree in ~4 years on completing the Greenwich course.

## Gap analysis (live UK market check, 2026-08-30)

Reference data in the skill's `.claude/skills/it-job-search/references/role-requirements.md` is BLS/CompTIA —
**US labour market**, explicitly flagged there as directional-only outside the US.
Everything below is a live check against the actual UK/London market instead.

- **Junior Systems Administrator**: every current London posting found is
  full-time. Structurally a career-track role, not an entry/part-time one. Dropped
  as an active target while at Greenwich full-time; realistic later (placement
  year, or post-graduation).
- **1st Line IT Support / IT Support Technician**: checked live postings across
  Indeed UK, Jobsite, Glassdoor UK, CV-Library, Jooble (7-day window). Overwhelming
  majority full-time, on-site, and most list prior customer-facing/helpdesk
  experience as a preference even where labelled "entry-level."
- **Apprenticeships** (the usual no-experience on-ramp): structurally incompatible
  — fixed 2-year on-the-job programmes, can't run alongside full-time enrolment.
- **Zero work history** is the actual screening barrier, independent of the
  part-time/London/no-driving constraints — it applies before technical skill is
  even evaluated for public-facing service-desk roles.
- Net honest conclusion: no clean list of currently-open, genuinely-matching
  postings exists right now. Sending Kartik at generic listings would just produce
  rejections unrelated to his actual ability.

## The one strong lead

**University of Greenwich's own Student JobShop** (`jobs.gre.ac.uk`, category
`cat=604`) runs a recurring **IT Service Desk Analyst** role: capped 20 hrs/week,
evenings/weekends/holidays, built specifically for enrolled students with no prior
work history. Nothing open as of 2026-08-30 (checked directly), but it's a
recurring category, not a one-off, and structurally the best fit found — zero
commute (on his own campus), designed for exactly this situation.

Also available at Greenwich: **Student Ambassador** scheme (~250-300 ambassadors,
up to 20 hrs/week combined with JobShop work) — doesn't require IT-specific or
prior work experience, an alternative/parallel first-job route.

## Recommended action plan, in order

1. **Register with Greenwich's Student JobShop + Student Ambassador scheme in week
   one of term** (from 2026-09-14). Get into their system before a role appears
   rather than waiting for a live listing.
2. **Consider a non-IT part-time job as the bridge, not a detour** — retail/
   hospitality shifts are far more available part-time in London on public
   transport than IT-titled roles right now, and any customer-facing job removes
   the single biggest screening filter (an actual reference, an actual "yes I've
   worked" line) before going for 1st-line support again.
3. **Build a LinkedIn profile** — currently doesn't exist; needed regardless of
   which path above is taken.
4. **Apply the pending handwritten edits to the CV** before it goes anywhere near
   an application (see Open Items below) — Phase 3 tailoring per posting comes
   after this, once there's an actual posting to tailor against.

## CV digital copy

`~/Documents/CV/CV-KartikAkolia.docx` — a clean native Word transcription of the
scanned CV (built 2026-08-30 with `python-docx`, since neither `pandoc` nor
`python3-docx` were installed system-wide and this session has no sudo; built in a
throwaway venv instead). Opens natively in Word or Google Docs (upload/File → Open)
— no Google Drive write access in this session to place it there directly.

Applied from the scan's handwritten annotations and from facts confirmed with
Kartik during the session:

- Header: `kartikpassbolt.org (home lab)` → `kartikpassbolt.org (live production)`
- Profile: "reverse proxy stack" → "reverse proxy stack (Nginx Proxy Manager)"
- Education subtitle: "expected completion 26 June 2026" → "Completed 26 June 2026"
- Removed the VBA/Excel-macros Education bullet and the "VBA (Excel macros)" skills
  entry; removed "SQLite (Uptime Kuma, Vaultwarden)" from Databases — per "Keep
  SQL, Remove Excel Macros VBA"
- Additional: "Current Chelmsford College student..." → "Completed BTEC Level 3 at
  Chelmsford College..." (tense fix)
- Additional: "Available from 26 June 2026..." → "Available now, part-time,
  alongside full-time study at the University of Greenwich (BSc Hons Computer
  Science, from September 2026)"
- Full paragraph justification applied to Profile and Home Lab intro (per "Justify
  this"); clean Word heading/bullet styling throughout (per "Format this")

**Left open — Kartik is finishing these himself, not guessed at:**

- "Complete the checklist again" — unclear what checklist this refers to.
- "Add/check certs" — no certifications currently listed on the CV; worth deciding
  whether to pursue CompTIA A+ (maps to entry IT-support titles per
  `.claude/skills/it-job-search/references/role-requirements.md`) once time allows
  alongside Year 0.
- "Add Docker" next to Containerisation — Docker's already listed there, unclear
  what else was meant.
- Whether "Kubernetes (k3s)" should stay in the Containerisation skills line — scan
  showed marks possibly meaning strikethrough, not clear enough to act on.

## Tracker

Empty — nothing to track yet. Populate once an actual application goes out.

| Role | Company | Applied | Status | Notes |
|---|---|---|---|---|
| — | — | — | — | — |

## Sources

- BLS Occupational Outlook Handbook, Computer and IT Occupations:
  <https://www.bls.gov/ooh/computer-and-information-technology/> (US data, context
  only)
- CompTIA, "State of the Tech Workforce 2026":
  <https://www.comptia.org/en-us/resources/research/state-of-the-tech-workforce-2026/>
  (US data, context only)
- CompTIA certification roadmap:
  <https://www.comptia.org/en-us/blog/plot-your-next-move-with-the-new-comptia-career-roadmap/>
- University of Greenwich Student JobShop vacancies:
  <https://jobs.gre.ac.uk/vacancies.aspx?cat=604>
- University of Greenwich careers/part-time jobs overview:
  <https://www.gre.ac.uk/careers/find-a-job>
- Live UK job-board checks (2026-08-30, 7-day window): Indeed UK, Jobsite,
  Glassdoor UK, CV-Library, Jooble — searched for 1st line IT support, IT support
  apprenticeship, and junior systems administrator, London, part-time/flexible.
