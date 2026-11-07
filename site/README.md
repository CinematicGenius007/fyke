# Site

The Weir website, built with Astro. It renders the documents in `../docs/` and does not keep a copy, so editing a document edits the site.

```bash
cd site
pnpm install
pnpm dev            # http://localhost:4321
pnpm build          # static files in dist/
```

Settings that depend on where the site is hosted come from the environment:

| Variable | Meaning | Default |
|---|---|---|
| `SITE_URL` | Public address, used for canonical links, the sitemap and social-card addresses | `https://weir.cinematicgenius007.com` |
| `SITE_BASE` | Sub-path, for example `/weir/` | `/` |
| `SITE_REPO` | Repository address used by links and the clone command | `https://github.com/CinematicGenius007/rss_` |

The project's name and the names the page quotes, such as the data folder, are in `src/site.ts`.

Search and answer engines read, from every page: a title, a description, a canonical link, social-card tags (`public/og.png`, 1200 by 630) and structured data (`SoftwareApplication` and `FAQPage` on the home page, `TechArticle` and `BreadcrumbList` on documents). `/sitemap-index.xml`, `/robots.txt`, `/llms.txt` and `/llms-full.txt` are generated at build time. A document's description is its first paragraph. The home page's questions are in `src/pages/index.astro` and must stay true of the code.

After changing `src/plugins/rehype-docs.mjs`, run `pnpm clean`, because Astro caches rendered Markdown.

## Hosting

The output is plain files in `dist/`. For Cloudflare, connect the repository, set the root directory to `site`, the build command to `pnpm install && pnpm build` and the output directory to `dist`, then add the custom domain. `wrangler.jsonc` serves the same folder with `wrangler deploy`. Any static host works the same way.

The page has no trackers and loads nothing from other sites. The only thing it stores is the reader's choice of day or night edition, in local storage.
