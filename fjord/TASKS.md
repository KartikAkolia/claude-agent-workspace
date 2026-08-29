# TASKS.md

Implementation detail for the active phase only. See `ROADMAP.md` for phase order.
Replace this file's contents when the phase completes, don't accumulate history.

## Active Phase: none — Phase 3 complete, Phase 4 gated on a fresh go-ahead

Phases 0–3 are all complete — see `ROADMAP.md` for each phase's Completion Evidence. The reading UI (Nord Terminal direction: dwm-style status bar, ranger/lf-style source/file-list/preview panes) is live at `http://localhost:4321`, sourcing all 39 in-scope docs across `root`/`docs`/`productivity`/`claude-agent-templates` with no copies, verified against a running dev server (not assumed) and a clean production build (`npm run build`, 44 pages, 0 failures).

The dev server is running in the background per Kartik's stated preference to leave it up for live preview — no restart needed to continue browsing it.

Phase 4 (`productivity/dashboard.html` retirement) is next per `ROADMAP.md`, but per `AGENTS.md` non-negotiable 6 it needs a **fresh, explicit go-ahead from Kartik at this specific point** — his earlier "(c) retire outright" answer authorized the decision, not the moment of deletion. This file intentionally holds no Phase 4 task breakdown yet.

Phase 5 (polish + the deployment decision) remains untouched and on hold.

## Phase Completion

1. Record delivered behavior here or in a changelog if one gets started.
2. Update `ROADMAP.md` status and evidence.
3. Replace this file with the next phase's tasks once there is one.
