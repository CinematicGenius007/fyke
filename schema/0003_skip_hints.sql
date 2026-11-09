-- Fyke schema, version 3: when a publisher asks not to be polled.
--
-- `<skipHours>` and `<skipDays>` arrive only in a full feed body, but polls that end
-- in `304` must obey them too, so they are stored with the feed. Bit n of
-- `skip_hours` is UTC hour n. Bit n of `skip_days` is weekday n, counting from Sunday.

ALTER TABLE feeds ADD COLUMN skip_hours INTEGER NOT NULL DEFAULT 0;
ALTER TABLE feeds ADD COLUMN skip_days INTEGER NOT NULL DEFAULT 0;

PRAGMA user_version = 3;
