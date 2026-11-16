-- Saved selections and immutable writing instructions.

CREATE TABLE views (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL,
  rule_json   TEXT NOT NULL,
  revision    INTEGER NOT NULL DEFAULT 1,
  position    INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX views_position ON views(position, id);

CREATE TABLE recipes (
  id            INTEGER PRIMARY KEY,
  name          TEXT NOT NULL,
  revision      INTEGER NOT NULL DEFAULT 1,
  -- Non-null only for recipes whose original text can be restored.
  builtin_text  TEXT,
  created_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE recipe_revisions (
  recipe_id   INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  revision    INTEGER NOT NULL,
  text        TEXT NOT NULL,
  note        TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (recipe_id, revision)
) STRICT, WITHOUT ROWID;

-- The built-in recipe is ordinary immutable text with a stable identity.
INSERT INTO recipes(id, name, builtin_text, created_at)
VALUES (
  1,
  'Morning brief',
  'Write a concise morning brief. Group related developments, explain why they matter, and cite the source articles.',
  0
);
INSERT INTO recipe_revisions
SELECT id, 1, builtin_text, 'Built-in recipe', 0
FROM recipes;

-- Later is independent of read and starred state.
ALTER TABLE entry_state ADD COLUMN later_at INTEGER;

CREATE INDEX entry_state_later ON entry_state(later_at) WHERE later_at IS NOT NULL;
-- Immutable writing provenance. All timestamps are UTC milliseconds.
ALTER TABLE artifacts ADD COLUMN recipe_id INTEGER REFERENCES recipes(id);
ALTER TABLE artifacts ADD COLUMN recipe_revision INTEGER;
ALTER TABLE artifacts ADD COLUMN template_version INTEGER;
ALTER TABLE artifacts ADD COLUMN view_id INTEGER REFERENCES views(id) ON DELETE SET NULL;
-- Snapshot of the selection; later view edits do not change provenance.
ALTER TABLE artifacts ADD COLUMN rule_json TEXT;
ALTER TABLE artifacts ADD COLUMN writer TEXT;
ALTER TABLE artifacts ADD COLUMN input_count INTEGER NOT NULL DEFAULT 0;
-- Matching articles omitted by the bounded writer input budget.
ALTER TABLE artifacts ADD COLUMN omitted_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE artifacts ADD COLUMN question TEXT;
-- Recipe trials retain provenance but are excluded from the brief listing.
ALTER TABLE artifacts ADD COLUMN preview INTEGER NOT NULL DEFAULT 0;
ALTER TABLE artifacts ADD COLUMN citations_json TEXT;

CREATE UNIQUE INDEX artifacts_job ON artifacts(job_id) WHERE job_id IS NOT NULL;

CREATE TABLE routines (
  id             INTEGER PRIMARY KEY,
  name           TEXT NOT NULL,
  view_id        INTEGER REFERENCES views(id) ON DELETE SET NULL,
  schedule_json  TEXT NOT NULL,
  actions_json   TEXT NOT NULL,
  enabled        INTEGER NOT NULL DEFAULT 1,
  revision       INTEGER NOT NULL DEFAULT 1,
  created_at     INTEGER NOT NULL,
  last_run_at    INTEGER,  -- arrival watermark for the next captured selection
  next_run_at    INTEGER   -- UTC occurrence computed from local civil time
) STRICT;

CREATE INDEX routines_due ON routines(next_run_at) WHERE enabled=1;

CREATE TABLE routine_runs (
  id            INTEGER PRIMARY KEY,
  routine_id    INTEGER NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  job_id        INTEGER REFERENCES jobs(id),
  started_at    INTEGER NOT NULL,
  finished_at   INTEGER,
  status        TEXT NOT NULL DEFAULT 'running',
  -- Captured entry ids keep retries independent of later view edits.
  matches_json  TEXT NOT NULL,
  results_json  TEXT NOT NULL DEFAULT '[]'
) STRICT;

CREATE UNIQUE INDEX routine_no_overlap ON routine_runs(routine_id) WHERE status='running';

CREATE INDEX routine_runs_recent ON routine_runs(routine_id,started_at DESC);

CREATE INDEX entries_arrived ON entries(first_seen_at,id);

CREATE INDEX jobs_recent ON jobs(created_at DESC,id DESC);

PRAGMA user_version = 6;
