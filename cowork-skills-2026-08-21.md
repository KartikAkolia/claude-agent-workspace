# Cowork skills available in this session (2026-08-21)

This is a snapshot of every skill this Cowork session currently has access to, pulled from its live skill list, not a fixed catalog. Skills get added, removed, or updated at the account or plugin level, so treat this as accurate for today rather than permanent.

## Engineering plugin

- **engineering:architecture** — Create or evaluate an architecture decision record (ADR). Use when choosing between technologies (e.g., Kafka vs SQS), documenting a design decision with trade-offs and consequences, reviewing a system design proposal, or designing a new component from requirements and constraints.
- **engineering:code-review** — Review code changes for security, performance, and correctness. Trigger with a PR URL or diff, "review this before I merge," "is this code safe?," or when checking a change for N+1 queries, injection risks, missing edge cases, or error handling gaps.
- **engineering:debug** — Structured debugging session: reproduce, isolate, diagnose, and fix. Trigger with an error message or stack trace, "this works in staging but not prod," "something broke after the deploy," or when behavior diverges from expected and the cause isn't obvious.
- **engineering:deploy-checklist** — Pre-deployment verification checklist. Use when about to ship a release, deploying a change with database migrations or feature flags, verifying CI status and approvals before going to production, or documenting rollback triggers ahead of time.
- **engineering:documentation** — Write and maintain technical documentation. Trigger with "write docs for," "document this," "create a README," "write a runbook," "onboarding guide," or when the user needs help with any form of technical writing: API docs, architecture docs, or operational runbooks.
- **engineering:incident-response** — Run an incident response workflow: triage, communicate, and write postmortem. Trigger with "we have an incident," "production is down," an alert that needs severity assessment, a status update mid-incident, or when writing a blameless postmortem after resolution.
- **engineering:standup** — Generate a standup update from recent activity. Use when preparing for daily standup, summarizing yesterday's commits and PRs and ticket moves, formatting work into yesterday/today/blockers, or structuring rough notes into a shareable update.
- **engineering:system-design** — Design systems, services, and architectures. Trigger with "design a system for," "how should we architect," "system design for," "what's the right architecture for," or when the user needs help with API design, data modeling, or service boundaries.
- **engineering:tech-debt** — Identify, categorize, and prioritize technical debt. Trigger with "tech debt," "technical debt audit," "what should we refactor," "code health," or when the user asks about code quality, refactoring priorities, or maintenance backlog.
- **engineering:testing-strategy** — Design test strategies and test plans. Trigger with "how should we test," "test strategy for," "write tests for," "test plan," "what tests do we need," or when the user needs help with testing approaches, coverage, or test architecture.

## Cowork plugin management

- **cowork-plugin-management:cowork-plugin-customizer** — Customize a Claude Code plugin for a specific organization's tools and workflows. Use when: customize plugin, set up plugin, configure plugin, tailor plugin, adjust plugin settings, customize plugin connectors, customize plugin skill, tweak plugin, modify plugin configuration.
- **cowork-plugin-management:create-cowork-plugin** — Guide users through creating a new plugin from scratch in a Cowork session. Use when users want to create, build, make, develop, scaffold, start, or design a plugin. Requires Cowork mode with access to the outputs directory for delivering the final `.plugin` file.
- **cowork-plugin** — Create a new Cowork plugin from scratch, or customize an installed plugin for a specific organization. Same trigger set as above (customize plugin, set up plugin, configure plugin, etc., plus create/build/make/develop/scaffold a plugin).

## Productivity plugin

- **productivity:memory-management** — Two-tier memory system that makes Claude a workplace collaborator: decodes shorthand, acronyms, nicknames, and internal language. `CLAUDE.md` for working memory, a `memory/` directory for the full knowledge base.
- **productivity:start** — Initialize the productivity system and open the dashboard. Use when setting up the plugin for the first time, bootstrapping working memory from an existing task list, or decoding shorthand.
- **productivity:task-management** — Simple task management using a shared `TASKS.md` file. Reference when the user asks about their tasks, wants to add or complete tasks, or needs help tracking commitments.
- **productivity:update** — Sync tasks and refresh memory from current activity. Use when pulling new assignments into `TASKS.md`, triaging stale or overdue tasks, filling memory gaps, or running a comprehensive scan for todos buried in chat and email.

## Design and artifacts

- **design** — Create a design canvas: a multi-artboard visual design published as an Artifact running Claude Design's canvas editor. Good for UI mockups, screen flows, landing pages, marketing and social graphics, and print pieces (posters, flyers, brochures, memos, reports).
- **dataviz** — Use before creating any chart, graph, plot, dashboard, or data visualization in any medium (HTML/React artifact, inline SVG, matplotlib/plotly/d3/Recharts, an uploaded image, a Slack chart). Covers chart-color formulas, mark specs, stat tiles, and dashboard layout.
- **artifact-design** — Design guidance and fundamentals for Artifacts. Load before writing any artifact, including Markdown ones.
- **artifact-diagramming** — Diagramming know-how for Artifacts: when a diagram earns its place, how to draw one that shows the real mechanism, and inline-SVG mechanics that stay legible in both light and dark themes.
- **artifact-capabilities** — Runtime capabilities a published Artifact page can be granted (live or connected data, state shared across viewers, handing the viewer a file to save, self-updating pages). Load whenever an artifact needs that kind of runtime behavior.

## Document creation

- **docx** — Create, read, edit, or manipulate Word documents (`.docx`) or Word templates (`.dotx`): tables of contents, headings, page numbers, letterheads, find-and-replace, tracked changes, comments.
- **pdf** — Anything involving PDF files: reading/extracting text or tables, merging, splitting, rotating, watermarking, creating new PDFs, filling forms, encrypting/decrypting, extracting images, OCR on scanned PDFs.
- **pptx** — Anything involving `.pptx` or `.potx` files: creating, reading, editing decks; templates, layouts, speaker notes, comments.
- **xlsx** — Anything where a spreadsheet is the primary input or output: `.xlsx`, `.xlsm`, `.xltx`, `.csv`, `.tsv`. Opening, editing, creating, cleaning messy tabular data, formulas, formatting, charts.

## Other

- **explain-usage** — Explain where this session's tokens went, with one simple chart in plain language.
- **setup-cowork** — Guided Cowork setup: install a matching plugin, try a skill, connect tools. Use for onboarding or personalizing Cowork.
- **claude-in-chrome** — Automates the Chrome browser: clicking, filling forms, screenshots, console logs, navigation, opened in new tabs within the existing Chrome session. Requires site-level permissions.
- **morning** — Render the user's morning brief as a styled HTML artifact, or set it up as a recurring weekday task.
- **skill-creator** — Create new skills, modify and improve existing ones, run evals, and benchmark skill performance.
