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
| `DELETE /api/cloud-projects/:id` | owner | rows + every R2 object |

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
  used and dropped objects credited; finalize re-decides on verified bytes
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
