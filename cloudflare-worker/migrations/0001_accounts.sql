-- 0001_accounts: anonymous accounts bound to the device's Ed25519 signing key.
CREATE TABLE IF NOT EXISTS accounts (
  account_id    TEXT PRIMARY KEY,
  signing_key   BLOB NOT NULL UNIQUE,
  -- Not UNIQUE (deviation from the original draft, made in T4): the
  -- account's signing_key is the sole cross-device binding key (see
  -- account_devices below), so ITS uniqueness is load-bearing. identity_key
  -- has no such role in any route in this spec — nothing looks an account
  -- up by it — and enforcing global uniqueness on it only produces a
  -- SQLITE_CONSTRAINT_UNIQUE 500 whenever two independent accounts happen
  -- to be registered with the same identity key (observed in T4's own test
  -- suite: two different device ids that merely share a first+last
  -- character byte-collide under the test fixture's 2-byte identityKey
  -- derivation). Keeping NOT NULL only.
  identity_key  BLOB NOT NULL,
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
