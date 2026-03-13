-- Full-text search index for store values
CREATE VIRTUAL TABLE IF NOT EXISTS store_fts USING fts5(
    namespace,
    key,
    content,
    content='store',
    content_rowid='rowid'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS store_fts_insert AFTER INSERT ON store BEGIN
    INSERT INTO store_fts(rowid, namespace, key, content) VALUES (new.rowid, new.namespace, new.key, new.value_json);
END;

CREATE TRIGGER IF NOT EXISTS store_fts_delete AFTER DELETE ON store BEGIN
    INSERT INTO store_fts(store_fts, rowid, namespace, key, content) VALUES ('delete', old.rowid, old.namespace, old.key, old.value_json);
END;

CREATE TRIGGER IF NOT EXISTS store_fts_update AFTER UPDATE ON store BEGIN
    INSERT INTO store_fts(store_fts, rowid, namespace, key, content) VALUES ('delete', old.rowid, old.namespace, old.key, old.value_json);
    INSERT INTO store_fts(rowid, namespace, key, content) VALUES (new.rowid, new.namespace, new.key, new.value_json);
END;
