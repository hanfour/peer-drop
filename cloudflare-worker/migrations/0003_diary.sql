-- 0003_diary: exchange-diary membership/invite indexes, and widen reports
-- (sender_hash / inbox_item_id go nullable, add diary_id / diary_seq) so a
-- diary event can be reported the same way a note inbox item can.
CREATE TABLE IF NOT EXISTS diary_members (
  account_id TEXT NOT NULL,
  diary_id   TEXT NOT NULL,
  joined_at  INTEGER NOT NULL,
  PRIMARY KEY (account_id, diary_id)
);
CREATE INDEX IF NOT EXISTS diary_members_diary ON diary_members(diary_id);
CREATE TABLE IF NOT EXISTS diary_invites (
  invite_code TEXT PRIMARY KEY,
  diary_id    TEXT NOT NULL
);
-- reports: sender_hash / inbox_item_id become nullable, add diary_id / diary_seq (SQLite needs a table rebuild for this)
CREATE TABLE reports_new (
  id TEXT PRIMARY KEY,
  reporter_account_id TEXT NOT NULL,
  sender_hash TEXT NULL,
  inbox_item_id TEXT NULL,
  diary_id TEXT NULL,
  diary_seq INTEGER NULL,
  reason TEXT NOT NULL,
  excerpt TEXT NULL,
  created_at INTEGER NOT NULL
);
INSERT INTO reports_new (id, reporter_account_id, sender_hash, inbox_item_id, reason, excerpt, created_at)
  SELECT id, reporter_account_id, sender_hash, inbox_item_id, reason, excerpt, created_at FROM reports;
DROP TABLE reports;
ALTER TABLE reports_new RENAME TO reports;
CREATE INDEX IF NOT EXISTS reports_sender ON reports(sender_hash, created_at);
