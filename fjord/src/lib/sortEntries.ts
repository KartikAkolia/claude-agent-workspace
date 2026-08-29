// Root repo convention (see AGENTS.md) puts AGENTS.md first as the entry
// point, then SPEC/ROADMAP/TASKS, then README, then the CLAUDE/GEMINI
// pointer files. Where a group has these files (root/, claude-agent-templates/),
// list them in that order; everything else (including groups that don't
// follow the convention, like docs/ and productivity/) falls back to
// alphabetical.
const PRIORITY = ["AGENTS", "SPEC", "ROADMAP", "TASKS", "README", "CLAUDE", "GEMINI"];

export function sortEntries<T extends { id: string }>(entries: T[]): T[] {
  return [...entries].sort((a, b) => {
    const ai = PRIORITY.indexOf(a.id);
    const bi = PRIORITY.indexOf(b.id);
    if (ai === -1 && bi === -1) return a.id.localeCompare(b.id);
    if (ai === -1) return 1;
    if (bi === -1) return -1;
    return ai - bi;
  });
}
