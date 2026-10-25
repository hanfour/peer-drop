-- 0005_groups: group chat room membership/invite indexes, and widen reports
-- (reporter_account_id goes nullable, add reporter_device_id / group_id /
-- group_seq, CHECK that at least one reporter is set) so a group message can
-- be reported by an anonymous (device-only) member too.
-- ONE-SHOT: the reports rebuild copies with the pre-0005 column list, so
-- re-running it after new columns hold data would drop that data. Production
-- relies on wrangler's d1_migrations table to apply this file exactly once.
CREATE TABLE IF NOT EXISTS group_members (
  account_id TEXT NOT NULL,
  group_id   TEXT NOT NULL,
  joined_at  INTEGER NOT NULL,
  PRIMARY KEY (account_id, group_id)
);
CREATE INDEX IF NOT EXISTS group_members_group ON group_members(group_id);
CREATE TABLE IF NOT EXISTS group_invites (
  invite_code TEXT PRIMARY KEY,
  group_id    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS group_invites_group ON group_invites(group_id);
-- reports: SQLite needs a table rebuild to relax NOT NULL and add a CHECK
CREATE TABLE reports_new (
  id TEXT PRIMARY KEY,
  reporter_account_id TEXT NULL,
  reporter_device_id TEXT NULL,
  sender_hash TEXT NULL,
  inbox_item_id TEXT NULL,
  diary_id TEXT NULL,
  diary_seq INTEGER NULL,
  group_id TEXT NULL,
  group_seq INTEGER NULL,
  reason TEXT NOT NULL,
  excerpt TEXT NULL,
  created_at INTEGER NOT NULL,
  CHECK (reporter_account_id IS NOT NULL OR reporter_device_id IS NOT NULL)
);
INSERT INTO reports_new (id, reporter_account_id, sender_hash, inbox_item_id, diary_id, diary_seq, reason, excerpt, created_at)
  SELECT id, reporter_account_id, sender_hash, inbox_item_id, diary_id, diary_seq, reason, excerpt, created_at FROM reports;
DROP TABLE reports;
ALTER TABLE reports_new RENAME TO reports;
CREATE INDEX IF NOT EXISTS reports_sender ON reports(sender_hash, created_at);
CREATE INDEX IF NOT EXISTS reports_group ON reports(group_id, created_at);
