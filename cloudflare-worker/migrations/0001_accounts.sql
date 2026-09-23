-- 0001_accounts: anonymous accounts bound to the device's Ed25519 signing key.
CREATE TABLE IF NOT EXISTS accounts (
  account_id    TEXT PRIMARY KEY,
  signing_key   BLOB NOT NULL UNIQUE,
  identity_key  BLOB NOT NULL UNIQUE,
  nickname      TEXT UNIQUE COLLATE NOCASE,
  mailbox_id    TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS account_devices (
  account_id    TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  device_id     TEXT NOT NULL,
  platform      TEXT NOT NULL,
  bound_at      INTEGER NOT NULL,
  PRIMARY KEY (account_id, device_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS account_devices_device ON account_devices(device_id);
