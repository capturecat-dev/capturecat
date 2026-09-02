# Google and Apple sign-in setup (Better Auth)

Sign-in runs entirely through Better Auth's `socialProviders`. Configuration
lives in [`src/lib/auth.ts`](../src/lib/auth.ts); the desktop bridge that wraps
it is [`src/routes/desktop.ts`](../src/routes/desktop.ts).

**Providers are registered conditionally.** A half-configured environment still
boots — set Google up first and ship, add Apple later. With exactly one provider
configured the desktop flow skips the chooser and goes straight to it; with none
it returns a 503 saying so, rather than a generic failure.

Both providers are **confidential clients**: the code exchange happens on the
Worker, never in the macOS app. That is why the desktop app has no client secret
in it and no custom URL scheme.

---

## 1. Google

Google Cloud Console → **APIs & Services** → **Credentials**.

1. **Create credentials** → **OAuth client ID**
2. Application type: **Web application** — *not* "Desktop app". The Worker holds
   the secret, so this is a web client. Picking "Desktop app" yields a client
   with no secret and the exchange fails.
3. **Authorised redirect URIs** — byte-exact, one per environment:

   ```
   https://api.capturecat.so/api/auth/callback/google
   http://localhost:8787/api/auth/callback/google
   ```

   The path is `{basePath}/callback/{provider}`, and `basePath` is `/api/auth`.
4. Copy the client id and secret:

   ```
   GOOGLE_CLIENT_ID=000000000000-xxxx.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=GOCSPX-…
   ```

Google works fine against `localhost`, so this is the one to set up first.

---

## 2. Apple

Apple Developer → **Certificates, Identifiers & Profiles**.

1. **Identifiers** → **App IDs** — you already have `so.capturecat.CaptureCat`.
   Enable the **Sign in with Apple** capability on it.
2. **Identifiers** → **Services IDs** → create one (e.g. `so.capturecat.auth`).
   *This* is `APPLE_CLIENT_ID`.

   > Pasting the app bundle id (`so.capturecat.CaptureCat`) here is the single
   > most common mistake — Apple answers `invalid_client` with no further
   > explanation. The bundle id goes in `appBundleIdentifier`, which is already
   > hard-coded in `src/lib/auth.ts`.
3. Configure the Services ID:
   - Primary App ID: the app id from step 1
   - Domains: `api.capturecat.so`
   - Return URLs: `https://api.capturecat.so/api/auth/callback/apple`
4. **Keys** → create a key with **Sign in with Apple** enabled. Download the
   `AuthKey_XXXXXXXXXX.p8` — Apple lets you download it exactly once.
   - The key id is `APPLE_KEY_ID`
   - Your team id (top-right of the portal) is `APPLE_TEAM_ID`
5. Flatten the `.p8` onto one line for the env var:

   ```sh
   awk 'BEGIN{ORS="\\n"} {print}' AuthKey_XXXXXXXXXX.p8
   ```

   ```
   APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n…\n-----END PRIVATE KEY-----\n"
   ```

   `src/lib/auth.ts` un-escapes the `\n` before `importPKCS8`. CaptureCat mints the
   client secret JWT itself and caches it until a minute before expiry — there
   is no long-lived Apple secret to rotate by hand.

### Apple cannot be tested against localhost

Apple rejects `http://` and `localhost` Return URLs outright. Either test Apple
against the deployed Worker, or front local dev with a named tunnel and register
that hostname as a second Return URL. This is why provider registration is
conditional — leave Apple unset locally and the chooser simply won't offer it.

---

## 3. Secrets

Local: copy `.dev.vars.example` → `.dev.vars` and fill in. Deployed:

```sh
wrangler secret put GOOGLE_CLIENT_ID
wrangler secret put GOOGLE_CLIENT_SECRET
wrangler secret put APPLE_CLIENT_ID
wrangler secret put APPLE_TEAM_ID
wrangler secret put APPLE_KEY_ID
wrangler secret put APPLE_PRIVATE_KEY
```

`BETTER_AUTH_URL` is a `[vars]` entry in `wrangler.toml` for production and is
overridden in `.dev.vars` for local runs — OAuth callbacks come back to whatever
it names, so it must match the redirect URIs registered above.

`BETTER_AUTH_SECRET` (`openssl rand -base64 32`) signs session cookies **and** is
the HMAC key the bearer plugin validates raw session tokens with. Rotating it
logs out every user and invalidates every Keychain-stored desktop token at once.

---

## 4. Verifying

The desktop app opens `/api/desktop/authorize` with **no** `provider`, so the
server decides what is on offer. Check each state with the flow's real
parameters (any base64url string works as a challenge for these):

```sh
Q="redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fcapturecat-auth%2Fcallback\
&code_challenge=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')\
&code_challenge_method=S256&state=abc123"

curl -si "http://localhost:8787/api/desktop/authorize?$Q" | head -1
```

| configured | response |
| --- | --- |
| neither | `503` — "No sign-in providers are configured." |
| one | `302` straight to that provider, chooser skipped |
| both | `200` chooser page listing exactly the configured providers |

`CaptureCat --auth-selftest` covers the client half (PKCE, the loopback listener, the
Keychain, and the authorize URL's shape — including that it names no provider).

---

## Common failures

| Symptom | Cause |
| --- | --- |
| Apple returns `invalid_client` | `APPLE_CLIENT_ID` is the app bundle id instead of the Services ID |
| `state_security_mismatch` on callback | The `Set-Cookie` from `signInSocial` was not forwarded onto the 302 — `desktop.ts` does this deliberately; see `setCookieValues` |
| Google `redirect_uri_mismatch` | The registered URI differs from `{BETTER_AUTH_URL}/api/auth/callback/google` by so much as a trailing slash |
| "This sign-in provider is not available right now" (502) | The provider is registered but the upstream call failed — check the secret values |
| "That sign-in provider is not configured" (503) | Its env vars are missing, so it was never registered |
