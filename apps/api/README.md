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
