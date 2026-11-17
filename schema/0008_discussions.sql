-- The page where readers discuss an entry, from RSS <comments> or an Atom
-- rel="replies" link. Entries stored before this keep NULL until the feed changes them.
ALTER TABLE entries ADD COLUMN discussion_url TEXT;

PRAGMA user_version = 8;
