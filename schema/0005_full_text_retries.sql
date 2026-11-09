-- Fyke schema, version 5: retrying articles that could not be fetched.
--
-- A timeout or a 503 says nothing about the page, so such an entry keeps `full_status`
-- NULL and waits for `full_retry_at`. `full_attempts` counts tries that failed this way.
-- Recent entries settled before this version may have failed for such a reason, and
-- the two cases cannot be told apart, so they get another try.

ALTER TABLE entries ADD COLUMN full_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE entries ADD COLUMN full_retry_at INTEGER;

UPDATE entries SET full_status = NULL, full_attempted_at = NULL
WHERE full_status IN ('failed', 'skipped') AND sort_at >= (unixepoch() - 30 * 86400) * 1000;

PRAGMA user_version = 5;
