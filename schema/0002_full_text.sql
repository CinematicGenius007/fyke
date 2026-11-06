-- rss_ schema, version 2: articles fetched from their web pages.
--
-- Many feeds carry only a summary. The daemon fetches the page and replaces the
-- entry's content with what it extracts, so that search, readers and agents all
-- benefit with no change. `content_hash` keeps describing the feed's version, so a
-- publisher's edit is still noticed, and it clears `full_status` to fetch again.

ALTER TABLE entries ADD COLUMN full_status TEXT
  CHECK (full_status IN ('done', 'failed', 'skipped'));  -- NULL means not attempted
ALTER TABLE entries ADD COLUMN full_attempted_at INTEGER;

CREATE INDEX entries_need_full ON entries (sort_at DESC) WHERE full_status IS NULL;

PRAGMA user_version = 2;
