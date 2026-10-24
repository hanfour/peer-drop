-- 0004_account_settings: the smallest possible per-account settings store.
-- One row per account that ever changed a setting. No row means every
-- setting is at its default. No timestamps, no history, no IP: changes to a
-- setting are deliberately not recorded anywhere.
-- Re-applicable: IF NOT EXISTS, and nothing here touches existing data.
-- note_push: 1 = push a nudge when a note arrives (default), 0 = never push.
CREATE TABLE IF NOT EXISTS account_settings (
  account_id TEXT PRIMARY KEY,
  note_push  INTEGER NOT NULL DEFAULT 1
);
