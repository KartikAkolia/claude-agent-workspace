// The four in-scope content collections (src/content.config.ts) plus the
// display metadata Phase 3's reading UI needs for them. `base` mirrors the
// exact base path each collection's glob() loader uses, so file-size lookups
// (lib/fileMeta.ts) resolve to the same real, on-disk file.
export const GROUPS = [
  { key: "root", label: "root/", base: "../" },
  { key: "docs", label: "docs/", base: "../docs" },
  { key: "productivity", label: "productivity/", base: "../productivity" },
  { key: "templates", label: "claude-agent-templates/", base: "../claude-agent-templates" },
] as const;

export type GroupKey = (typeof GROUPS)[number]["key"];

// Shown struck-through in the source pane, matching AGENTS.md non-negotiable
// 3 — Fjord excludes these from content entirely, but naming them keeps the
// scope decision visible rather than silent.
export const EXCLUDED = [
  "dwm-titus-main/",
  "linutil-main/",
  "titus-ai-main/",
  "website-master/",
  "winutil-main/",
];
