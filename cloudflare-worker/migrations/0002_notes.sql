-- 0002_notes: server-side blocks (by sender hash) and report archive for passing notes.
CREATE TABLE IF NOT EXISTS blocks (
  account_id   TEXT NOT NULL,
  sender_hash  TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  PRIMARY KEY (account_id, sender_hash)
);
CREATE TABLE IF NOT EXISTS reports (
  id                  TEXT PRIMARY KEY,
  reporter_account_id TEXT NOT NULL,
  sender_hash         TEXT NOT NULL,
  inbox_item_id       TEXT NOT NULL,
  reason              TEXT NOT NULL,
  excerpt             TEXT NULL,
  created_at          INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS reports_sender ON reports(sender_hash, created_at);
