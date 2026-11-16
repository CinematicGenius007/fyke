# Schema

The numbered SQL files are append-only migrations, applied by the daemon's writer
connection in `store.zig`. `schema.describe` includes every migration. Other
connections use `query_only`; clients never migrate or write the database.

Version 6 adds reader definitions and writer provenance:

- `views` holds a normalized rule, sidebar position and a revision used for
  compare-and-swap updates.
- `recipes` points to the current revision. `recipe_revisions` holds immutable
  Markdown, a note and a timestamp. Recipe 1 is the built-in Morning brief;
  resetting it appends a revision rather than overwriting history.
- `entry_state.later_at` is independent of read and starred timestamps. Ingest
  never changes reading state.
- `routines` holds a saved view, local civil-time schedule, explicit actions and
  a last-run watermark. `routine_runs` holds captured entry IDs and per-action
  results. A partial unique index prevents simultaneous runs of one routine.
- The existing `jobs` table is the durable queue. `stage` is `brief`, `answer` or
  `routine` for reader jobs. Inputs snapshot recipes and rules, and routine jobs
  snapshot their captured matches. Running jobs are recovered when the sole
  daemon restarts. `artifacts_job` permits at most one artifact per job.
- Artifacts hold `recipe_id`, `recipe_revision`, `template_version`, `view_id`,
  `rule_json`, `writer`, `input_count`, `omitted_count` and `question`.
  `preview` excludes recipe trials from brief listings. `citations_json` preserves
  validated writer output. Blocks and `artifact_sources` are saved in the same
  transaction as the artifact, its event and job completion.

Rules are parameter-bound queries over entries, reading state, the recursive
folder tree and FTS5. Version 7 materializes normalized article hosts and paths through deterministic
SQLite functions backed by `url.zig`. Ingest inserts and updates maintain
these fields in the same statement as article content. Host-only selectors use the host/timeline index; path comparisons
match complete segments. These functions perform no I/O. Missing article addresses cannot match address
conditions. Counts and keyset pages share the same predicate; FTS words are
quoted individually before binding, so they cannot introduce query syntax.

Indexes cover sidebar ordering, recent jobs and artifacts, arriving entries,
later state, due routines and routine history. Article hosts and timelines share an index; folder parent and feed folder
indexes support descendant scopes. Sidebar counts are computed together, and
bulk marks use parameter-bound set updates.
