import fs from "node:fs";
import path from "node:path";

// `import.meta.url`-relative resolution looked right in dev but breaks once
// Vite bundles this module into a dist/ chunk during `astro build` — the
// chunk's own location shifts, silently pointing PROJECT_ROOT at the wrong
// directory (caught by running a real `npm run build`, not assumed).
// `process.cwd()` is stable across dev/build/preview: Astro is always
// invoked from `fjord/` (see AGENTS.md/README usage), the same root every
// collection's glob() `base` in content.config.ts is resolved relative to.
const PROJECT_ROOT = process.cwd();

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  return `${(bytes / 1024).toFixed(1)}K`;
}

// Reads the real file's size directly off disk — never fabricated/estimated.
export function fileSize(base: string, id: string): string {
  const abs = path.resolve(PROJECT_ROOT, base, `${id}.md`);
  const { size } = fs.statSync(abs);
  return formatSize(size);
}

export function wordCount(body: string | undefined): number {
  if (!body) return 0;
  return body.trim().split(/\s+/).filter(Boolean).length;
}
