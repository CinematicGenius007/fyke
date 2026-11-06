-- rss_ schema, version 4: finding the fetches that share a stored body.
--
-- Housekeeping and unsubscribing look up `fetch_log` by body hash while holding the
-- writer lock, so that lookup must not scan the table.

CREATE INDEX fetch_log_raw ON fetch_log (raw_sha256) WHERE raw_sha256 IS NOT NULL;

PRAGMA user_version = 4;
