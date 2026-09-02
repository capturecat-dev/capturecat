-- Security layer: per-uid rate limiting + App Attest key registry.

-- Fixed-window per-uid rate limiting (key = "<scope>:<uid>").
CREATE TABLE IF NOT EXISTS rate_limits (
  key TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL DEFAULT 0
);

-- One outstanding App Attest challenge per uid (short TTL, single use).
CREATE TABLE IF NOT EXISTS attest_challenges (
  uid TEXT PRIMARY KEY,
  nonce TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

-- Registered App Attest keys (public key stored as base64 DER SPKI).
CREATE TABLE IF NOT EXISTS attest_keys (
  key_id TEXT PRIMARY KEY,
  uid TEXT NOT NULL,
  public_key TEXT NOT NULL,
  counter INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_attest_keys_uid ON attest_keys(uid);

-- Uids exempt from assertion enforcement (Intel Macs, macOS < 14).
CREATE TABLE IF NOT EXISTS attest_exemptions (
  uid TEXT PRIMARY KEY,
  reason TEXT,
  created_at TEXT
);
