import { defineConfig } from "astro/config";

// Fjord: read-only Astro reader for this repo's own docs. No site/deploy
// config yet — deployment is on hold per fjord/SPEC.md until Kartik reviews
// in-scope docs for sensitive content.
export default defineConfig({
  output: "static",
  outDir: "./dist",
  markdown: {
    shikiConfig: {
      // Dark-only theme (Nord Terminal direction, no light/dark toggle).
      theme: "nord",
      wrap: true,
    },
  },
});
