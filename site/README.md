# Site

The Weir website, built with Astro. It renders the documents in `../docs/` and does not keep a copy, so editing a document edits the site.

```bash
cd site
npm install
npm run dev        # http://localhost:4321
npm run build      # static files in dist/
```

Settings that depend on where the site is hosted come from the environment:

| Variable | Meaning | Default |
|---|---|---|
| `SITE_URL` | Public address, for example `https://example.com` | none |
| `SITE_BASE` | Sub-path, for example `/weir/` | `/` |
| `SITE_REPO` | Repository address used by links and the clone command | `https://github.com/CinematicGenius007/rss_` |

The project's name and the names the page quotes, such as the data folder, are in `src/site.ts`.

After changing `src/plugins/rehype-docs.mjs`, run `npm run clean`, because Astro caches rendered Markdown.

The page has no trackers and loads nothing from other sites. The only thing it stores is the reader's choice of day or night edition, in local storage.
