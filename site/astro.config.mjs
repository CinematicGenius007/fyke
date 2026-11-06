import { defineConfig } from "astro/config";
import rehypeDocs from "./src/plugins/rehype-docs.mjs";

// SITE_URL and SITE_BASE let the owner host the site anywhere, including under
// a sub-path such as https://example.github.io/weir/.
const site = process.env.SITE_URL || undefined;
const base = process.env.SITE_BASE || "/";
const repo = process.env.SITE_REPO || "https://github.com/CinematicGenius007/rss_";

export default defineConfig({
  site,
  base,
  trailingSlash: "always",
  build: { format: "directory" },
  markdown: {
    syntaxHighlight: false,
    rehypePlugins: [[rehypeDocs, { base, repo }]],
  },
});
