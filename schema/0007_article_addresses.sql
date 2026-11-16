-- Normalized address parts keep host-only rules off the article-body scan.
-- The functions are pure adapters around url.zig, registered by store before migration.
ALTER TABLE entries ADD COLUMN article_host TEXT;
ALTER TABLE entries ADD COLUMN article_path TEXT;
UPDATE entries SET article_host=article_host(url),article_path=article_path(url);
CREATE INDEX entries_article_host ON entries(article_host,sort_at DESC,id DESC);
CREATE INDEX feeds_folder ON feeds(folder_id,id);
CREATE INDEX folders_parent ON folders(parent_id,id);
PRAGMA user_version = 7;
