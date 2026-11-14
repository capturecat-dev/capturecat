-- "iPhone over Wi-Fi": CaptureCat for iPhone and iPad streams its screen to
-- CaptureCat for Mac over the local network (routes/devices.ts,
-- lib/wireless-link.ts, lib/apns.ts; wire contract:
-- apps/macos/CaptureCat/Shared/WirelessDeviceProtocol.swift).
--
-- Additive only, and nothing older reads these tables, so this is safe to
-- apply before the Worker that uses it is deployed (and MUST be: the new
-- desktop_auth_requests.client column is written by /api/desktop/authorize).

-- One device link key per account: a random 256-bit TLS-PSK secret every
-- native app signed in to the account fetches (GET /api/wireless/link), so a
-- Mac and an iPhone on the same account trust each other with no pairing.
-- The key is AES-GCM encrypted at rest under a key HKDF-derived from
-- STORAGE_CREDENTIALS_KEY with its own info label (never the raw storage key),
-- user_id bound in as additional data. `key_id` is the PUBLIC fingerprint the
-- Mac advertises in Bonjour TXT: lowercase hex of the first 8 bytes of
-- SHA-256("capturecat-wireless-link-v1" || key). Rotation ("Forget my
-- devices") overwrites the row.
CREATE TABLE IF NOT EXISTS wireless_links (
  user_id         TEXT PRIMARY KEY REFERENCES "user" ("id") ON DELETE CASCADE,
  key_ciphertext  TEXT NOT NULL,              -- base64(iv || AES-GCM ciphertext)
  key_id          TEXT NOT NULL,              -- 16 lowercase hex
  created_at      TEXT NOT NULL               -- ISO-8601; when THIS key was minted
);

-- The account's native devices: what the Mac lists, and the APNs token that
-- lets a Mac wake a phone whose app is closed ("Stream to <Mac>").
-- device_id is minted by the app (a UUID, stored lowercase). platform is
-- 'ios' | 'mac' and apns_env 'sandbox' | 'production', validated by the API
-- rather than a CHECK so a later value never needs a table rebuild.
-- apns_token is lowercase hex and NEVER returned by any endpoint; a token
-- belongs to one row at a time (registering it elsewhere clears it here).
CREATE TABLE IF NOT EXISTS user_devices (
  user_id         TEXT NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE,
  device_id       TEXT NOT NULL,
  platform        TEXT NOT NULL,
  name            TEXT NOT NULL,
  model           TEXT,
  system_version  TEXT,
  app_version     TEXT,
  apns_token      TEXT,                       -- NULL = this device can't be pushed
  apns_env        TEXT,                       -- NULL when apns_token is NULL
  created_at      TEXT NOT NULL,              -- ISO-8601
  updated_at      TEXT NOT NULL,              -- ISO-8601
  last_seen_at    TEXT NOT NULL,              -- ISO-8601; bumped by every PUT
  PRIMARY KEY (user_id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_user_devices_seen ON user_devices (user_id, last_seen_at);
CREATE INDEX IF NOT EXISTS idx_user_devices_apns ON user_devices (apns_token) WHERE apns_token IS NOT NULL;

-- Which native app started a sign-in, so the consent page and its errors name
-- it ("CaptureCat for Mac" / "CaptureCat for iPhone and iPad"). Every row
-- before this one came from the Mac.
ALTER TABLE desktop_auth_requests ADD COLUMN client TEXT NOT NULL DEFAULT 'mac';
