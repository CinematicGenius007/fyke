-- Fyke schema, version 1.
--
-- This file is the source of truth for the data model and is written to be read
-- by people and agents. Conventions:
--   * All timestamps are INTEGER unix milliseconds, UTC. Columns end in _at.
--   * Tables are STRICT. Flexible payloads are JSON text in columns ending _json.
--   * `content_blocks_json` and `body_blocks_json` hold the block format defined in
--     docs/architecture.md ("Content model").
--   * Feed-derived text is untrusted. See docs/architecture.md ("Security").
--
-- The daemon sets these on every connection:
--   PRAGMA journal_mode = WAL;
--   PRAGMA foreign_keys = ON;
--   PRAGMA synchronous = NORMAL;

-- ---------------------------------------------------------------------------
-- Subscriptions
-- ---------------------------------------------------------------------------

CREATE TABLE folders (
  id         INTEGER PRIMARY KEY,
  parent_id  INTEGER REFERENCES folders(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  position   INTEGER NOT NULL DEFAULT 0,
  UNIQUE (parent_id, name)
) STRICT;

CREATE TABLE feeds (
  id               INTEGER PRIMARY KEY,
  folder_id        INTEGER REFERENCES folders(id) ON DELETE SET NULL,
  url              TEXT NOT NULL UNIQUE,      -- current fetch URL; updated on permanent redirect
  site_url         TEXT,
  title            TEXT,                      -- from the feed
  title_override   TEXT,                      -- set by the user, wins over title
  description      TEXT,
  format           TEXT CHECK (format IN ('rss090', 'rss091', 'rss10', 'rss20', 'atom03', 'atom10', 'json10', 'json11')),
  status           TEXT NOT NULL DEFAULT 'active'
                   CHECK (status IN ('active', 'paused', 'gone')),  -- gone = HTTP 410 or user-confirmed dead
  allow_private_network INTEGER NOT NULL DEFAULT 0,                 -- opt-in SSRF exception for LAN feeds

  -- HTTP cache validators, echoed back on the next request.
  etag             TEXT,
  last_modified    TEXT,

  -- Scheduler state.
  poll_seconds     INTEGER NOT NULL DEFAULT 3600,
  next_fetch_at    INTEGER NOT NULL DEFAULT 0,
  last_fetch_at    INTEGER,
  last_success_at  INTEGER,
  error_count      INTEGER NOT NULL DEFAULT 0,  -- consecutive failures, drives backoff
  last_error       TEXT,

  created_at       INTEGER NOT NULL
) STRICT;

CREATE INDEX feeds_due ON feeds (next_fetch_at) WHERE status = 'active';

-- One row per fetch attempt. Answers "why is this feed broken" without logs.
CREATE TABLE fetch_log (
  id           INTEGER PRIMARY KEY,
  feed_id      INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  started_at   INTEGER NOT NULL,
  duration_ms  INTEGER NOT NULL,
  http_status  INTEGER,                        -- NULL when no response was received
  bytes        INTEGER NOT NULL DEFAULT 0,
  raw_sha256   TEXT,                           -- body stored at raw/<aa>/<sha256>.gz
  new_entries  INTEGER NOT NULL DEFAULT 0,
  updated_entries INTEGER NOT NULL DEFAULT 0,
  error        TEXT
) STRICT;

CREATE INDEX fetch_log_feed ON fetch_log (feed_id, started_at DESC);

-- ---------------------------------------------------------------------------
-- Entries
-- ---------------------------------------------------------------------------

CREATE TABLE entries (
  id                  INTEGER PRIMARY KEY,
  feed_id             INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  identity            TEXT NOT NULL,           -- see docs/rss-primer.md ("Entry identity")
  url                 TEXT,
  canonical_url       TEXT,                    -- tracking params stripped, for cross-feed dedupe
  title               TEXT,
  author              TEXT,
  language            TEXT,
  published_at        INTEGER,                 -- as claimed by the feed; may be missing or wrong
  updated_at          INTEGER,                 -- as claimed by the feed
  first_seen_at       INTEGER NOT NULL,        -- as observed by us; never changes
  sort_at             INTEGER NOT NULL,        -- min(published_at, first_seen_at), or first_seen_at
  content_blocks_json TEXT NOT NULL DEFAULT '[]',
  content_text        TEXT NOT NULL DEFAULT '',-- plain text of the blocks, for search and agents
  content_hash        TEXT NOT NULL,           -- detects edits
  revision            INTEGER NOT NULL DEFAULT 1,
  simhash             INTEGER,                 -- 64-bit near-duplicate fingerprint
  duplicate_of        INTEGER REFERENCES entries(id) ON DELETE SET NULL,
  UNIQUE (feed_id, identity)
) STRICT;

CREATE INDEX entries_timeline ON entries (sort_at DESC, id DESC);
CREATE INDEX entries_feed_timeline ON entries (feed_id, sort_at DESC, id DESC);
CREATE INDEX entries_canonical ON entries (canonical_url);

CREATE TABLE enclosures (
  id        INTEGER PRIMARY KEY,
  entry_id  INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  url       TEXT NOT NULL,
  mime_type TEXT,
  bytes     INTEGER,
  UNIQUE (entry_id, url)
) STRICT;

-- Kept apart from entries so that refetching never touches user state and
-- marking something read never rewrites the search index.
CREATE TABLE entry_state (
  entry_id    INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
  read_at     INTEGER,
  starred_at  INTEGER,
  hidden_at   INTEGER,
  dwell_ms    INTEGER NOT NULL DEFAULT 0       -- time open in a reader; a ranking signal
) STRICT, WITHOUT ROWID;

CREATE INDEX entry_state_starred ON entry_state (starred_at) WHERE starred_at IS NOT NULL;

CREATE TABLE tags (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE
) STRICT;

CREATE TABLE entry_tags (
  entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  tag_id   INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  source   TEXT NOT NULL DEFAULT 'user',       -- 'user' or 'runner:<id>'
  PRIMARY KEY (entry_id, tag_id, source)
) STRICT, WITHOUT ROWID;

CREATE TABLE notes (
  id         INTEGER PRIMARY KEY,
  entry_id   INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  author     TEXT NOT NULL DEFAULT 'user',     -- 'user' or the name of an agent
  body       TEXT NOT NULL,
  created_at INTEGER NOT NULL
) STRICT;

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

CREATE VIRTUAL TABLE entries_fts USING fts5 (
  title, author, content_text,
  content = 'entries', content_rowid = 'id',
  tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TRIGGER entries_fts_insert AFTER INSERT ON entries BEGIN
  INSERT INTO entries_fts (rowid, title, author, content_text)
  VALUES (new.id, new.title, new.author, new.content_text);
END;

CREATE TRIGGER entries_fts_delete AFTER DELETE ON entries BEGIN
  INSERT INTO entries_fts (entries_fts, rowid, title, author, content_text)
  VALUES ('delete', old.id, old.title, old.author, old.content_text);
END;

CREATE TRIGGER entries_fts_update AFTER UPDATE OF title, author, content_text ON entries BEGIN
  INSERT INTO entries_fts (entries_fts, rowid, title, author, content_text)
  VALUES ('delete', old.id, old.title, old.author, old.content_text);
  INSERT INTO entries_fts (rowid, title, author, content_text)
  VALUES (new.id, new.title, new.author, new.content_text);
END;

-- Little-endian f32 array. Compared by brute-force scan until that is too slow.
CREATE TABLE embeddings (
  entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  model    TEXT NOT NULL,
  dims     INTEGER NOT NULL,
  vector   BLOB NOT NULL,
  PRIMARY KEY (entry_id, model)
) STRICT, WITHOUT ROWID;

-- ---------------------------------------------------------------------------
-- Aggregation. See docs/aggregator.md.
-- ---------------------------------------------------------------------------

-- A way of reaching a model or agent. Never contains secrets: config_json names
-- an environment variable or Keychain item instead.
CREATE TABLE runners (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  kind        TEXT NOT NULL CHECK (kind IN ('http', 'exec', 'acp')),
  config_json TEXT NOT NULL,
  enabled     INTEGER NOT NULL DEFAULT 1
) STRICT;

-- A declarative aggregation: which entries, which stages, which runner, how often.
CREATE TABLE lenses (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  spec_json   TEXT NOT NULL,
  enabled     INTEGER NOT NULL DEFAULT 1,
  next_run_at INTEGER
) STRICT;

CREATE TABLE stories (
  id            INTEGER PRIMARY KEY,
  lens_id       INTEGER NOT NULL REFERENCES lenses(id) ON DELETE CASCADE,
  title         TEXT,
  first_seen_at INTEGER NOT NULL,
  last_seen_at  INTEGER NOT NULL,
  score         REAL NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX stories_rank ON stories (lens_id, score DESC);

CREATE TABLE story_entries (
  story_id   INTEGER NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
  entry_id   INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  similarity REAL NOT NULL,
  PRIMARY KEY (story_id, entry_id)
) STRICT, WITHOUT ROWID;

CREATE INDEX story_entries_entry ON story_entries (entry_id);

-- Durable work queue. A crash leaves jobs 'running' with an expired lease,
-- and the daemon re-queues them on start.
CREATE TABLE jobs (
  id            INTEGER PRIMARY KEY,
  lens_id       INTEGER REFERENCES lenses(id) ON DELETE CASCADE,
  runner_id     INTEGER REFERENCES runners(id) ON DELETE SET NULL,
  stage         TEXT NOT NULL,                 -- enrich, cluster, rank, synthesize
  status        TEXT NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued', 'running', 'done', 'failed', 'cancelled')),
  input_json    TEXT NOT NULL,
  attempts      INTEGER NOT NULL DEFAULT 0,
  run_after     INTEGER NOT NULL DEFAULT 0,
  lease_until   INTEGER,
  error         TEXT,
  input_tokens  INTEGER,
  output_tokens INTEGER,
  created_at    INTEGER NOT NULL,
  finished_at   INTEGER
) STRICT;

CREATE INDEX jobs_ready ON jobs (run_after) WHERE status = 'queued';

-- Anything a model or agent produced. Every artifact records who made it and
-- from what, so AI output is never mistaken for source material.
CREATE TABLE artifacts (
  id               INTEGER PRIMARY KEY,
  kind             TEXT NOT NULL CHECK (kind IN ('summary', 'story_summary', 'digest', 'answer')),
  lens_id          INTEGER REFERENCES lenses(id) ON DELETE SET NULL,
  story_id         INTEGER REFERENCES stories(id) ON DELETE CASCADE,
  entry_id         INTEGER REFERENCES entries(id) ON DELETE CASCADE,
  job_id           INTEGER REFERENCES jobs(id) ON DELETE SET NULL,
  producer         TEXT NOT NULL,              -- runner name, or agent name via artifacts.put
  model            TEXT,
  prompt_sha256    TEXT,
  title            TEXT,
  body_blocks_json TEXT NOT NULL,
  created_at       INTEGER NOT NULL
) STRICT;

CREATE INDEX artifacts_recent ON artifacts (kind, created_at DESC);
CREATE INDEX artifacts_entry ON artifacts (entry_id) WHERE entry_id IS NOT NULL;
CREATE INDEX artifacts_story ON artifacts (story_id) WHERE story_id IS NOT NULL;

-- Citations. A digest with no rows here failed validation and is not stored.
CREATE TABLE artifact_sources (
  artifact_id INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
  entry_id    INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  PRIMARY KEY (artifact_id, entry_id)
) STRICT, WITHOUT ROWID;

-- ---------------------------------------------------------------------------
-- Change feed
-- ---------------------------------------------------------------------------

-- Append-only and pruned by age. Clients resume with events.subscribe(since_seq),
-- so a GUI that reconnects misses nothing.
CREATE TABLE events (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  at           INTEGER NOT NULL,
  type         TEXT NOT NULL,                  -- e.g. entry.new, feed.error, artifact.new
  subject_id   INTEGER,
  payload_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

PRAGMA user_version = 1;
