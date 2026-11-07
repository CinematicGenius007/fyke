import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import rehypeDocs from "./src/plugins/rehype-docs.mjs";

// The public address defaults to the project's own domain. SITE_URL and SITE_BASE
// let the site be hosted elsewhere, including under a sub-path such as
// https://example.github.io/weir/.
const site = process.env.SITE_URL || "https://weir.cinematicgenius007.com";
const base = process.env.SITE_BASE || "/";
const repo = process.env.SITE_REPO || "https://github.com/CinematicGenius007/rss_";

export default defineConfig({
  site,
  base,
  integrations: [sitemap({ filter: (page) => !page.endsWith("/404/") })],
  trailingSlash: "always",
  // One stylesheet of about 20 kB: inlining it saves a blocking request.
  build: { format: "directory", inlineStylesheets: "always" },
  markdown: {
    syntaxHighlight: false,
    rehypePlugins: [[rehypeDocs, { base, repo }]],
  },
});
