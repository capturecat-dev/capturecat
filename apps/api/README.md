# CaptureCat API

Cloudflare Worker powering video uploads, streaming, and sharing. Built with [Hono](https://hono.dev/) + Cloudflare R2 + Cloudflare D1 + [Better Auth](https://better-auth.com/).

## Architecture

```
POST /api/upload/video          → Presigned PUT URL for R2
POST /api/upload/video/:id/complete → Verify upload, mark ready
GET  /api/video/:id             → Stream video (supports byte-range)
DELETE /api/video/:id           → Delete video + metadata
GET  /api/health                → Health check
```

- **Storage**: Cloudflare R2 (S3-compatible) — objects at `videos/{videoId}.mp4`
- **Metadata**: Cloudflare D1 (SQLite) — `shared_videos` plus the Better Auth tables (`user`, `session`, `account`, `verification`) and `subscription`, schema in `migrations/`
- **Billing**: Stripe via the `@better-auth/stripe` plugin — see [`docs/stripe-setup.md`](docs/stripe-setup.md)
- **Auth**: Better Auth, social-only (Google + Apple). Sessions live in D1.
  Native clients send `Authorization: Bearer <session.token>` and the bearer
  plugin resolves it — no JWT, no client-held claim. `tester`/`blocked` are
  server-owned `user` columns declared `input: false`, so no client payload can
  set them; paid status is read from `subscription` on every request
- **Presigned URLs**: Generated server-side using `@aws-sdk/s3-request-presigner` — the client never gets direct R2 credentials

## Local Development

### Prerequisites

- Node.js 18+
- npm
- A Cloudflare account with an R2 bucket named `capturecat`
- A Google Cloud OAuth client (type **Web application**); for Apple, a Services
  ID + a Sign in with Apple key

### Setup

```bash
cd apps/api
npm install
```

### Configure local secrets

Create a `.dev.vars` file (gitignored) with your secrets:

```bash
cp .dev.vars.example .dev.vars
# Then fill in the values
```

Required variables:

```env
BETTER_AUTH_SECRET=            # openssl rand -base64 32
BETTER_AUTH_URL=http://localhost:8787
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
R2_ACCESS_KEY_ID=your_r2_api_token_key_id
R2_SECRET_ACCESS_KEY=your_r2_api_token_secret
R2_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com
APP_TOKEN=capturecat-v1-9f3a7c2e
```

To get R2 credentials: Cloudflare Dashboard → R2 → Manage R2 API Tokens → Create API Token.

### Run locally

```bash
npx wrangler d1 migrations apply capturecat --local   # create local D1 schema (first run + after new migrations)
npm run dev
```

This starts the Worker on `http://localhost:8787`. The macOS app points here in DEBUG builds.

## Database (D1)

The Worker uses a D1 database named `CaptureCat` (binding `DB`). Schema lives in versioned
migrations under `migrations/`.

### One-time setup

```bash
# 1. Create the database and copy the printed database_id into wrangler.toml
npx wrangler d1 create capturecat

# 2. Apply the schema
npx wrangler d1 migrations apply capturecat --remote
```

### Applying migrations

```bash
npx wrangler d1 migrations apply capturecat --local    # dev
npx wrangler d1 migrations apply capturecat --remote   # prod
```

`migrations/0003_better_auth.sql` holds the Better Auth core schema. Its
`CREATE TABLE` bodies are the verbatim output of Better Auth's own migration
compiler for this repo's exact plugin set — do not hand-edit column names or
types. If Better Auth is upgraded and adds columns, regenerate with
`npx @better-auth/cli generate` and add a NEW numbered migration; wrangler's
numbered migrations stay the single source of truth. Do not use Better Auth's
runtime migration endpoint in production.

There was no Firebase→Better Auth data migration: there were zero Firebase
users. `shared_videos.uid` and the `attest_*.uid` columns simply hold a Better
Auth `user.id` now instead of a Firebase uid, so those tables were left alone.

## Production Deployment

### Set secrets (one-time)

```bash
npx wrangler secret put APP_TOKEN

# Better Auth. BETTER_AUTH_SECRET signs session cookies AND is the HMAC key the
# bearer plugin validates raw session tokens with — rotating it logs out every
# user and invalidates every Keychain-stored desktop token. Treat as permanent.
openssl rand -base64 32 | npx wrangler secret put BETTER_AUTH_SECRET
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put APPLE_CLIENT_ID      # the SERVICES ID, e.g. so.capturecat.auth
npx wrangler secret put APPLE_TEAM_ID        # E52HU87CX9
npx wrangler secret put APPLE_KEY_ID         # the 10 chars from the .p8 filename
cat AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APPLE_PRIVATE_KEY
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
npx wrangler secret put R2_ENDPOINT
```

### Deploy

```bash
npm run deploy
```

Deploys to `api.capturecat.so` (configured as a custom domain in `wrangler.toml`).

`wrangler.toml` sets `compatibility_flags = ["nodejs_compat"]`. Better Auth
needs `AsyncLocalStorage`; without the flag the Worker throws at the **first
request**, not at build time — so `wrangler deploy --dry-run` would still pass
while the deployed Worker was broken. Do not remove it.

Sign in with Apple cannot be tested against `wrangler dev`: Apple rejects
`http://` and `localhost` Return URLs outright. Exercise Apple against the
deployed Worker (or a named tunnel registered as a second Return URL). Google
works locally — add `http://localhost:8787/api/auth/callback/google` to the
same OAuth client's Authorized redirect URIs.

## Project Structure

```
migrations/
  0001_initial_schema.sql  # D1 schema (shared_videos, stripe_customers)
  0003_better_auth.sql     # Better Auth core tables + subscription + desktop auth
  0004_drop_firebase_stripe_customers.sql  # retires stripe_customers
src/
  index.ts           # Hono app entry, route mounting, CORS, rate limiting
  types.ts           # Env bindings, AuthUser, VideoMetadata types
  routes/
    desktop.ts       # Desktop loopback + PKCE bridge, and GET /api/me
    upload.ts        # Presigned URL generation + upload completion
    video.ts         # Video streaming with byte-range support
    delete.ts        # Video deletion
    account-delete.ts  # DELETE /api/me — account deletion (lib/account-deletion.ts)
                     # (Stripe webhooks are NOT here — the Better Auth Stripe
                     #  plugin serves POST /api/auth/stripe/webhook)
  middleware/
    auth.ts          # Bearer token → Better Auth session
  lib/
    db.ts            # D1 data layer (prepared statements)
    stripe.ts        # Better Auth Stripe plugin config, plans, paid-status policy
    auth.ts          # Better Auth instance (providers, plugins, session config)
    presign.ts       # R2 presigned URL generation via S3-compatible API
```

## Desktop sign-in (loopback + PKCE)

The macOS app never sees a custom URL scheme. On macOS any application can
register `capturecat://` and LaunchServices will hand it the callback, so a scheme
is a hijackable credential channel with no way to bind the response to the app
that asked for it. Instead the app follows RFC 8252 §7.3: it binds an ephemeral
loopback port itself, then opens the system default browser.

Better Auth has no plugin that expresses this — its OAuth/OIDC provider plugin
matches `redirect_uri` by exact string equality, and a random port cannot be
pre-registered. `src/routes/desktop.ts` is therefore ours; it enforces the
loopback and PKCE rules and delegates code minting/expiry/single-use to the
`oneTimeToken` plugin.

```
app                    Worker                         provider
 |  bind 127.0.0.1:P     |                               |
 |--- open browser ----> GET /api/desktop/authorize      |
 |                       | store code_challenge + P      |
 |                       | auth.api.signInSocial         |
 |                       |--- 302 (+ state cookie) ----> |
 |                                                       | user signs in
 |                       GET /api/auth/callback/{p} <----|
 |                       | Better Auth creates a session |
 |                       GET /api/desktop/complete       |
 |                       | mint one-time token = "code"  |
 |  <--- 302 http://127.0.0.1:P/capturecat-auth/callback?code=…&state=…
 |                                                       |
 |--- POST /api/desktop/token {code, code_verifier, redirect_uri}
 |  <--- { token, expiresAt, user }   → macOS Keychain   |
```

Rules enforced by `/api/desktop/authorize`:

- `code_challenge_method` must be `S256`; `plain` is rejected.
- `redirect_uri` must be `http://127.0.0.1:<1024-65535>/capturecat-auth/callback`
  with no query or fragment. **`localhost` is rejected** — it resolves through
  DNS and is rebindable (RFC 8252 §8.3).
- The `Set-Cookie` from `signInSocial` is forwarded onto our 302. Miss this and
  the provider callback dies with `state_security_mismatch`.

The `code` is single-use twice over (our atomic `consumed` flip plus Better
Auth's `consumeVerificationValue`), lives two minutes, is bound to the exact
port that requested it, and is worthless without the `code_verifier` — which
never leaves the app's memory.

`GET /api/me` returns `{ uid, email, tier, tester, blocked }` for a bearer
token. The desktop export gate needs the *resolved* tier, which no Better Auth
endpoint exposes: `/api/auth/get-session` carries `tester`/`blocked` but not
paid status, and `/api/auth/subscription/list` applies Better Auth's
`isActiveOrTrialing()`, which excludes `past_due` and would lock out a
subscriber in dunning that this API still treats as paid.

`POST /api/desktop/revoke` (bearer) signs the session out server-side; the app
clears the Keychain first so revocation can never be blocked by a flaky network.

## iPhone over Wi-Fi (devices, link key, APNs)

CaptureCat for iPhone and iPad (bundle id `so.capturecat.ios`) streams the
iPhone screen to CaptureCat for Mac over the local network. It signs in
through the loopback + PKCE bridge above, adding `client=ios` to
`/api/desktop/authorize` (absent or `mac` = the Mac; anything else is a 400):
the consent page and its errors then name "CaptureCat for iPhone and iPad".
`GET /api/desktop/connect/:rid` returns `app: { name, platform }`.

Routes: `src/routes/devices.ts`; schema: `migrations/0042_devices_wireless.sql`;
the clients' wire contract: `apps/macos/CaptureCat/Shared/WirelessDeviceProtocol.swift`.

| Endpoint | What |
|---|---|
| `GET /api/wireless/link` | `{ key, keyId, createdAt }` — the account's device link key (base64url, 32 bytes, no padding), created on first call; concurrent first calls converge on one key |
| `POST /api/wireless/link/rotate` | same shape, fresh key ("Forget my devices") |
| `PUT /api/devices/:deviceId` | register/refresh this device (`deviceId` = UUID, stored lowercase): `{ platform: "ios"\|"mac", name, model?, systemVersion?, appVersion?, apnsToken?, apnsEnvironment? }` → the public device |
| `GET /api/devices` | `{ devices: [{ deviceId, platform, name, model, systemVersion, appVersion, canPush, lastSeenAt }] }`, newest first |
| `DELETE /api/devices/:deviceId` | `{ deleted: true }` (404 `not_found` if absent) — the app calls it on sign-out |
| `POST /api/devices/:deviceId/request-broadcast` | `{ macId, macName }` → APNs alert to that phone → `{ sent: true }` |

- **Native apps only.** Every route chains `requireBearer` →
  `refuseAgentCredentials` → `requireAuth`. A request without
  `Authorization: Bearer …` is 401 `bearer_required`, and the `Cookie` header
  is stripped before the session lookup — Better Auth's bearer plugin falls
  back to the cookie when a bearer value does not verify, so without that an
  XSS on a web origin could send `Bearer junk` plus the browser's cookie and
  read the link key. Agent tokens are 403. Not plan-gated (Free included).
- **Link key at rest.** AES-GCM (lib/storage.ts `sealSecret`) under a key
  HKDF-SHA256-derived from `STORAGE_CREDENTIALS_KEY` with info
  `capturecat-wireless-link-v1/at-rest` — never the raw key, which bucket
  credentials use — with the user id as additional data. Without that secret
  both link routes answer 503 `wireless_unavailable`; nothing is stored in
  clear. `keyId` = lowercase hex of the first 8 bytes of
  SHA-256("capturecat-wireless-link-v1" ‖ key) (`WirelessLink.keyID(for:)`;
  key bytes 0x00…0x1f → `8f40509a77686376`). A row that no longer opens (the
  secret was replaced) is swapped for a fresh key, which devices treat as a
  rotation.
- **APNs tokens are write-only.** No response contains one. `apnsToken`
  absent = keep the stored token, `null` = forget it, 64–200 hex = replace it
  (then `apnsEnvironment` `sandbox`\|`production` is required; iOS only). A
  token is held by one device row at a time. `canPush` = iOS + a token + APNs
  configured on this server. The newest 50 devices per account are kept.
- **request-broadcast.** The device must be the caller's (else 404
  `not_found`). 503 `push_not_configured` without the APNs secrets; 409
  `push_unavailable` when the device has no token, or when APNs answers 410 /
  `BadDeviceToken` / `Unregistered` (the token is then forgotten); 502
  `push_failed` for anything else, transport errors included — retryable,
  the token is kept. The alert: title "Stream to <macName>", body "Tap to
  share your screen with CaptureCat on <macName>.", category
  `CC_BROADCAST_REQUEST`, `interruption-level: time-sensitive`,
  `apns-push-type: alert`, priority 10, expiry now + 120 s, collapse id
  `broadcast-request`, custom key `cc: { type: "requestBroadcast", macId, macName }`
  (`macName` cleaned of control/bidi characters, ≤ 60 characters; `macId`
  lowercased).
- **APNs client** (`lib/apns.ts`): token auth, an ES256 JWT (`kid` =
  `APNS_KEY_ID`, `iss` = `APNS_TEAM_ID`, `iat`) signed with WebCrypto and
  reused for 50 minutes; `api.push.apple.com` for production device tokens,
  `api.sandbox.push.apple.com` for development builds. APNs is HTTP/2 only:
  a deployed Worker negotiates it, local workerd on macOS does not
  (cloudflare/workerd#4841), so pushes cannot be tried from `wrangler dev`.
- **Limits.** Per uid: 30/min for the link and device routes, 10/min for
  request-broadcast. Per IP: 60/min on `/api/wireless/*`, 120/min on
  `/api/devices/*`.
- **Account deletion.** `wireless_links` and `user_devices` reference
  `user(id) ON DELETE CASCADE`.

Go-live, in this order:

1. `npx wrangler d1 migrations apply capturecat --remote` (0042) **before**
   deploying: `/api/desktop/authorize` writes the new
   `desktop_auth_requests.client` column, so every sign-in — the Mac's
   included — fails on a Worker that runs ahead of the migration.
2. `npm run deploy`. `STORAGE_CREDENTIALS_KEY` is already required for custom
   storage; the link routes are 503 without it.
3. The owner adds the APNs secrets (an APNs auth key from the Apple developer
   account, team E52HU87CX9). Until then request-broadcast answers 503
   `push_not_configured` and `canPush` is false; everything else works.

   ```bash
   cat AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APNS_KEY
   npx wrangler secret put APNS_KEY_ID      # the 10 chars from the .p8 filename
   npx wrangler secret put APNS_TEAM_ID     # E52HU87CX9
   ```

   `APNS_TOPIC` (a var, default `so.capturecat.ios`) only needs setting if
   the iOS bundle id ever changes.

## Account deletion (`DELETE /api/me`)

App Store Guideline 5.1.1(v): an account made in an app can be deleted in
that app. The iOS app (Account → Delete Account) and the web dashboard
(Settings → Delete account) call `DELETE /api/me`; it is also how support
deletes an account now (no more emailing contact@). Route:
`src/routes/account-delete.ts`; logic: `src/lib/account-deletion.ts`;
schema: `migrations/0043_account_deletion.sql`; tests:
`src/routes/account-delete.test.ts`.

| Status | Body | Meaning |
| --- | --- | --- |
| 200 | `{ deleted: true, jobId, cancelledSubscriptions, cleanup: "pending" }` | Gone. Every session (the caller's too) is dead. |
| 401 | `{ error }` | No session — also what a retry gets after a lost 200. Clients treat 401 here as "already deleted" and sign out. |
| 403 | `{ error: "Origin not allowed" }` / `{ error: "Account blocked" }` / `{ code: "agent_token_forbidden" }` | Cookie without a trusted Origin (CSRF), a blocked account (support decides), an agent token. |
| 409 | `{ code: "team_has_members", team: { id, name, otherMembers } }` | The user owns a team with other members and no co-owner. |
| 502 | `{ code: "billing_unavailable" }` | Stripe could not cancel the subscription — nothing was deleted. |

Auth is `requireAuth`, exactly like `GET /api/me`: a bearer session (apps)
or the session cookie with a trusted `Origin` (web). Agent credentials are
refused first. 5 requests per 10 minutes per user. `X-CC-Client: ios|mac|web`
names the client in the audit row.

How it runs:

1. **Checks.** A team the user owns that has other members and no other
   owner → 409 (the owner promotes someone or removes them on the Team page
   first); a team whose only member is the user is deleted with them. Then
   **Stripe**: every live subscription — the customer's, plus any id D1 knows
   (`subscription`, `plan_grants`) — is cancelled **immediately** with the
   existing Stripe client (no proration refund, no further charges). Any
   Stripe failure → 502, nothing changes. The Stripe customer itself is kept:
   it holds the invoices we must keep for tax (privacy policy §6).
2. **One D1 batch** (a transaction): the R2 keys the user's rows point at are
   copied into `account_deletion_objects`, then every row is deleted, ending
   with `user`. From here the account does not exist: sessions, shares,
   agent/OAuth tokens, webhooks and push tokens are all dead.
3. **Background**: the queued R2 objects (1000 per call; whole prefixes
   listed page by page), Cloudflare custom hostnames, metadata cache entries
   and the user's ShareJobsDO rows are removed — first in `waitUntil` right
   after the response, then by the hourly cron sweep until the queue is
   empty. Each finished item leaves the queue, so an interrupted run resumes;
   a failing outside call is retried once per run, up to 48 runs.

What happens to each table / bucket:

| Data | What happens |
| --- | --- |
| `user`, `session`, `account` | deleted (sign-out everywhere; Google/Apple links gone) |
| `shared_videos`, `video_versions`, `video_views`, `video_events`, `video_reactions`, `video_transcripts`, comments on their videos (anyone's) | deleted; files in **CaptureCat R2** (`videos/{id}.mp4`, `videos/{id}/…`, `thumbs/{id}`) deleted in the background |
| Their comments on other people's videos | deleted; one with replies from others is redacted in place ("Deleted account" / "This comment was deleted.", no avatar, no annotation) so the thread survives |
| `video_playlists`, `playlist_videos` | deleted |
| `cloud_projects` + objects/files/versions/manifests | deleted; `cloud-projects/{uid}/…` in R2 deleted (prefix listing also catches never-finalized uploads) |
| Other people's cloud projects they edited | kept; `updated_by`, `actor_uid`, `named_by` cleared |
| `stored_objects`, `screenshot_api_keys`, `screenshot_usage` | deleted; `screenshots/{uid}/…` in R2 deleted |
| `storage_buckets` (bring-your-own bucket) | **credentials deleted. Objects in the customer's own bucket are never deleted** — the module never calls the S3 API |
| `custom_domains` | deleted; the Cloudflare custom hostname removed in the background |
| Teams: sole-member `organization` (+ `member`, `invitation`, `ssoProvider`, `org-logos/{id}`) | deleted; any leftover `org_id` on videos/projects/playlists cleared |
| Teams with other members | the user's `member` row goes; the team stays (409 if they are its only owner) |
| `invitation` sent by them / addressed to their email | deleted |
| `agent_tokens`, `agent_audit_log`, `agent_approvals`, `oauth_grants`, `oauth_codes`, `oauth_refresh_tokens`, `webhook_endpoints`, `webhook_deliveries` | deleted (registered `oauth_clients` are shared and stay) |
| `user_devices` (APNs tokens), `wireless_links` | deleted |
| `attest_keys`, `attest_challenges`, `attest_exemptions` | deleted |
| `subscription`, `plan_grants` | deleted after Stripe cancelled them; later webhooks for them find no row and are ignored |
| `beta_signups` with their email | deleted |
| `video_reports` | ones they filed: `reporter_uid` cleared (the hashed reporter stays); open ones about their videos closed as `account_deleted` |
| `moderation_actions` | kept — the admins' audit trail (a now-meaningless uid, no PII) |
| ShareJobsDO (per-user upload progress) | purged in the background (`purgeAll`) |
| `rate_limits` | not touched; keyed by uid, swept within a day |
| `site_events`, `desktop_auth_requests`, `verification` | not user-keyed; expire on their own |
| Stripe customer, invoices | kept in Stripe (tax records) |

The audit record is the `account_deletions` row: deleted user id, client,
time, how many subscriptions were cancelled, counts of what was removed, and
`email_hmac` = HMAC-SHA256(`BETTER_AUTH_SECRET`, `account-deletion:` +
lowercased email) — enough for support to answer "was the account for this
address deleted?" without keeping the address. No name, no email.

Go-live: apply `0043_account_deletion.sql` (`npx wrangler d1 migrations apply
capturecat --remote`) **before** deploying the Worker — the route writes the
new tables in its batch, so a Worker ahead of the migration answers 500 and
deletes nothing (the batch is all-or-nothing). See
`docs/account-deletion-deploy.md` at the repo root.

## Security layers (added 2026-08-02)

Three layers protect paid features and metered resources:

1. **Server-side entitlements** (`src/lib/entitlement.ts`)
   - `requireEntitlement({minTier})` chains after `requireAuth` on every
     privileged route. The D1 `subscription` row (written only by the Better
     Auth Stripe plugin's webhook) is authoritative for paid status — statuses
     `active`/`trialing`/`past_due` count as paid, defined once as
     `PAID_SUBSCRIPTION_STATUSES` in `src/lib/stripe.ts`. `past_due` is kept
     deliberately, to preserve the dunning grace period; that is intentionally
     more permissive than Better Auth's own `isActiveOrTrialing()`.
   - Every request reads the table, so a cancellation revokes on the very next
     API call — there is no cached claim that can go stale.
   - `tester`/`blocked` are server-owned columns on the `user` row, declared
     `input: false` so no client payload can set them.
   - `userRateLimit({limit, windowSec, scope})` — per-uid fixed window in the
     D1 `rate_limits` table. Exceeding fails closed (429).
   - `POST /api/auth/stripe/webhook` remains the ONLY writer of paid status.

2. **Server-side AI** (`src/routes/ai.ts`)
   - `POST /api/ai/generate` proxies Gemini with the Worker-held key.
   - Setup: `wrangler secret put GEMINI_API_KEY`. Tester+ tier, 20 req/min/uid.
   - The macOS app scrubs the legacy plaintext `gemini_api_key` from
     UserDefaults on launch; no client-side key path remains.

3. **App Attest** (`src/routes/attest.ts`, `src/lib/app-attest.ts`)
   - App ID `E52HU87CX9.so.capturecat.CaptureCat`; full verification:
     CBOR decode → x5c chain to the pinned Apple App Attestation Root CA →
     nonce (SHA256(authData‖SHA256(challenge)) vs cert ext
     1.2.840.113635.100.8.2) → keyId = SHA256(pubkey) = credentialId →
     RP ID hash, counter 0, aaguid (`appattest` / `appattestdevelop`).
   - Assertions: `X-CaptureCat-Key-Id` + `X-CaptureCat-Assertion` headers, ES256 over
     SHA256(authenticatorData‖SHA256(raw body)), strict counter monotonicity.
   - Rollout via `ATTEST_MODE` var: `report` (default — verify + log only)
     → watch logs for legit clients failing → `enforce` (401 without valid
     assertion, except uids in `attest_exemptions` — add Intel/macOS<14
     users there manually).

Go-live checklist:
1. `wrangler d1 migrations apply capturecat --remote` (adds `rate_limits`,
   `attest_challenges`, `attest_keys`, `attest_exemptions`).
2. `wrangler secret put GEMINI_API_KEY` (optional until an AI feature ships).
3. Deploy. Keep `ATTEST_MODE = "report"` for at least a week of real traffic.
4. Flip to `enforce` only after report logs are clean.

## Custom share domains (Cloudflare for SaaS)

A Pro customer's `share.acme.com` is a **Cloudflare custom hostname** on the
capturecat.so zone. `POST /api/domains` records the domain and registers the
hostname (HTTP validation); `POST /api/domains/:domain/verify` checks the
customer's CNAME and refreshes Cloudflare's hostname + certificate status. A
domain only routes when all three are green (`domainIsLive` in lib/db.ts) and
its owner's plan still includes custom domains — `GET /api/domains/resolve`
is what the web Worker asks.

One-time zone setup (idempotent):

```bash
CF_API_TOKEN=… CF_ZONE_ID=… ./scripts/setup-saas.sh
npx wrangler secret put CF_SAAS_API_TOKEN     # SSL and Certificates: Edit
# then set CF_ZONE_ID in wrangler.toml [vars] and deploy
```

The script creates the originless `customers.capturecat.so` record (AAAA
`100::`, proxied) and makes it the SaaS fallback origin. It does **not** add a
Workers route, and refuses to run while a `*/*` route exists: a `*/*` route to
the web Worker took `api.` and `admin.` down with Cloudflare 1019 on
2026-09-30 (it collided with their Workers Custom Domains). Routing customer
hostnames to the web Worker needs a design proven on a non-production zone
first; the web Worker answers any `api.`/`admin.` request that reaches it with
421 and never re-fetches it (apps/web/src/server.ts), so no route can make it
recurse.

## Cloud projects (web editor)

The web editor at `app.capturecat.so/editor/<projectId>` edits the same
project the Mac app does. The Mac uploads the bundle ("Open in Web Editor"),
the browser loads it through short-lived presigned GETs, and project.json
saves use optimistic concurrency; the Mac can pull the web's edits back
("Pull Web Edits"). Routes: `src/routes/cloud-projects.ts`; rules (paths,
types, sizes, document check, keys): `src/lib/cloud-projects.ts`; SQL:
`src/lib/cloud-projects-db.ts`; schema: `migrations/0026_cloud_projects.sql`.

| Endpoint | Who | What |
|---|---|---|
| `GET /api/cloud-projects` | signed in | your projects + `storage {usedBytes, limitBytes}`; `?orgId=` lists a team's (members only) |
| `PUT /api/cloud-projects/:id` | owner (or new id) | stage a manifest `{name, orgId?, files:[{path, sha256, bytes, contentType, source?}]}` → `missing[]` with one presigned PUT per object the cloud lacks |
| `POST /api/cloud-projects/:id/finalize` | owner | verify every new object (R2 size **and** streamed SHA-256), accept it into the quota atomically, commit the manifest, collect unreferenced objects. `409 objects_missing` = upload first; `202` = large upload, call again |
| `GET /api/cloud-projects/:id` | owner, org members | `document` (raw project.json text, byte-exact), `revision` (+ `ETag`), `files[]` with presigned GETs, `urlsExpireAt` |
| `GET /api/cloud-projects/:id/files` | owner, org members | fresh presigned GETs only |
| `PUT /api/cloud-projects/:id/project` | owner, org members | body = project.json; **`If-Match: "<revision>"` required** (428 without). Stale → `409 revision_conflict` with the current `revision` + `document` |
| `DELETE /api/cloud-projects/:id` | owner | rows + every R2 object (version snapshots included) |

**History** (migration 0027; contract: `docs/project-history.md` §6 at the
repo root). Every save extends or opens a VERSION — a gzipped snapshot of
project.json plus the media manifest it was saved against — in the same D1
batch as the revision CAS. Versions pin their media (never collected, never
credit, still counted); version documents are not counted but are capped per
project (1000 / 256 MB). Retention is the owner's plan (`maxHistoryDays` /
`maxNamedVersions`: Pro 30/25, Business 365/500, Free 0/0); saves prune a few
inline and the hourly cron sweeps the rest. Routes in
`src/routes/cloud-project-history.ts` (rules: `src/lib/project-history.ts`,
SQL: `src/lib/project-history-db.ts`):

| Endpoint | Who | What |
|---|---|---|
| `GET /api/cloud-projects/:id/head` | owner, org members | revision + `headVersionId` (poll) |
| `GET /api/cloud-projects/:id/versions?before=&limit=` | owner, org members | history newest first, retention, pinned / freeable media bytes |
| `GET /api/cloud-projects/:id/versions/:vid` | owner, org members | that version's document + presigned media from its manifest |
| `GET /api/cloud-projects/:id/revisions/:rev/document` | owner, org members | a retained revision's document (merge base) |
| `PATCH /api/cloud-projects/:id/versions/:vid` | owner, org members | `{label}` name / un-name (cap: owner's plan) |
| `POST /api/cloud-projects/:id/versions/:vid/restore` | owner, org members | `If-Match` required; new revision + `restore` version; re-commits its media (no quota effect) |
| `DELETE /api/cloud-projects/:id/versions/:vid` | owner | never the head |
| `POST /api/cloud-projects/:id/history/free-up` | owner | delete the unnamed versions pinning removed media |

- **Auth.** `requireAuth` — the session cookie (web; non-GET needs a trusted
  `Origin`) or a bearer token (desktop). The owner does everything; if the
  owner put the project in an org (plan `teams` + membership, like
  `POST /video/:id/org`) its members may **read** it and **save edits** to
  project.json (revision-checked like the owner's; a growing document is
  charged to the OWNER's quota under the OWNER's plan). Media, org moves and
  delete stay owner-only — media is the owner's storage. Strangers get 404 on
  reads and on writes to an existing project; claiming another account's id
  via `PUT` is 403 `not_owner`. App Attest is deliberately not chained (the
  browser cannot attest).
- **Storage.** Media is content-addressed per owner + project:
  `cloud-projects/<uid>/<id>/objects/<sha256>` (an unchanged recording is
  never re-uploaded). project.json lives in R2, one object per save attempt
  (`…/doc/<revision>-<nonce>.json`), not in D1: D1 caps a value at 2 MB and
  the document grows with the recording. A save writes its object first and
  then compare-and-swaps the row on `revision`, so a race or crash never
  leaves the row pointing at a torn document (the nonce keeps two racing
  saves off the same key).
- **Quota.** Verified objects and each project's document are summed by
  `STORAGE_SUM_SQL` with shares and screenshots — one pool per user. Staging
  runs `checkUploadAllowance` (plan `cloudShare` + `maxTotalStorageBytes`;
  the plan's share-upload `maxFileSizeBytes` is LIFTED to the 5 GiB single-PUT
  ceiling for project media — a cloud project carries the raw recording the
  web editor renders from, not an exported mp4) with other projects' outstanding presigns counted as
  used and dropped objects credited (unless a version pins them — then they
  stay and keep counting); finalize re-decides on verified bytes
  inside one conditional UPDATE and deletes what does not fit. A document
  save that grows is quota-checked; one that shrinks always succeeds.
  Per-kind ceilings (video 5 GiB, image 64 MB, audio 1 GB, JSON 512 MB) and
  an extension → content-type allowlist (no SVG/HTML) apply regardless of
  plan. Images browsers cannot decode (HEIC/HEIF/TIFF/BMP) never arrive: the
  Mac converts them to PNG (JPEG q0.95 above 64 MB) during sync and records
  the original reference as the file's `source`.
- **Bucket CORS.** The browser reads media straight from R2 (`web-editor-media`:
  GET/HEAD + Range) and the web recorder uploads to the presigned PUTs
  (`web-recorder-upload`: PUT + Content-Type), so the bucket needs
  `r2-cors.json` applied (again after any change to it):
  `npx wrangler r2 bucket cors set capturecat --file r2-cors.json`.
- **Deploy order.** Apply `migrations/0026_cloud_projects.sql` to remote D1
  BEFORE deploying this Worker: the shared storage sum reads the new tables,
  so share uploads fail if the code runs ahead of the migration.
- **Presigns.** PUTs are signed for the exact key, `Content-Type` and
  `Content-Length`, 15 minutes; GETs carry a signed `response-content-type`,
  15 minutes. The hourly cron deletes objects presigned but never verified
  within 2 h.
- **Limits.** Per-IP 300/min on `/api/cloud-projects/*`; per-uid 30/min for
  stage/finalize/delete and 120/min for document saves.

Go-live: apply `0026_cloud_projects.sql` **before** deploying (the shared
storage sum reads its tables, so share uploads fail on a Worker that runs
ahead of the migration). The browser fetches media straight from R2, so the
`capturecat` bucket needs a CORS rule: origins `https://app.capturecat.so`
(plus the local dev web origin when testing), methods `GET, HEAD`, headers
`Range`, exposed `Content-Length, Content-Range, Content-Type, ETag`.

Tests: `npm test` runs `src/routes/cloud-projects.test.ts` against the real
migrations and SQL through Node's built-in SQLite (`src/test-support/`,
Node ≥ 22.5); the session and S3 presigner are mocked and R2 is in-memory.
The Mac side has `CaptureCat --cloud-sync-test`.

## Enterprise SSO

Better Auth's SSO plugin (`/api/auth/sso/*`) does registration, sign-in and
callbacks. Registration and provider edits are gated on the caller's plan
`sso` flag in `lib/auth.ts` (the Business plan; seeded inactive by migration
0025 — Stripe-sync and activate it in the admin console). `routes/sso.ts`
adds what an org admin needs on top: `GET /api/sso/overview` (providers,
verification state, the DNS TXT record to publish, the redirect / ACS /
metadata URLs to paste into the IdP) and
`POST /api/sso/providers/:id/verify` (TXT check over DNS-over-HTTPS). Sign-in
is refused until the domain is verified. The desktop sign-in chooser offers
"Use single sign-on" once any verified provider exists.

## Changelog

`routes/changelog.ts` + migration 0037 (`changelog_entries`). The owner writes
entries in the admin console (admin.capturecat.so → **Changelog**: draft,
publish now / on a date / scheduled, unpublish, delete) through
`/api/admin/changelog*` behind the admin guard; the public reads are
`GET /api/changelog?limit&cursor` (published only, newest first, keyset-paged)
and `GET /api/changelog/:slug`. capturecat.so renders them at `/changelog`,
`/changelog/<slug>`, `/changelog.md` and `/changelog.xml` with one escaped
Markdown renderer (`apps/web/src/lib/changelog/markdown.tsx`) that the admin
preview also uses. Bodies are stored as written: safety lives in that renderer
(no raw HTML, http(s) links only), not in the API.
