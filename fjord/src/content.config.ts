import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";

// Fjord never copies source docs into its own tree (see AGENTS.md
// non-negotiable 2) — every collection's `base` points at the real,
// live location elsewhere in the repo. `base` is relative to this
// project's root (`fjord/`), matching Astro's own glob() examples
// (Context7-verified 2026-08-29).
//
// Every pattern below is a flat, non-recursive "*.md" on purpose: it's
// what naturally excludes productivity/dashboard-archive/ (the retired
// dashboard.html, its *.test.js files, and backups/ — archived 2026-09-03,
// see ROADMAP.md Phase 4) without an explicit exclude list, since none of
// it sits at the top level of productivity/. Per SPEC.md's Architecture
// section.

// Default id generation kebab-cases and lowercases filenames (github-slugger).
// Preserve the real, exact filename instead — Fjord displays and links to
// docs by their actual on-disk name (AGENTS.md, not agents.md).
const generateId = ({ entry }: { entry: string }) => entry.replace(/\.md$/, "");

const root = defineCollection({
  loader: glob({ pattern: "*.md", base: "../", generateId }),
});

const docs = defineCollection({
  loader: glob({ pattern: "*.md", base: "../docs", generateId }),
});

const productivity = defineCollection({
  loader: glob({ pattern: "*.md", base: "../productivity", generateId }),
});

const templates = defineCollection({
  loader: glob({ pattern: "*.md", base: "../claude-agent-templates", generateId }),
});

export const collections = { root, docs, productivity, templates };
