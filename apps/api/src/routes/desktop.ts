/**
 * Desktop loopback + PKCE authorization-code bridge (RFC 8252 + RFC 7636).
 *
 * WHY THIS EXISTS. Better Auth has no plugin that fits a native desktop app:
 *  • the OAuth/OIDC provider plugin matches `redirect_uri` by exact string
 *    equality, but RFC 8252 §7.3 requires accepting ANY port on a loopback
 *    redirect — and a random port cannot be pre-registered;
 *  • the device-authorization plugin (RFC 8628) is a user-code + polling flow,
 *    not loopback;
 *  • a `capturecat://` custom scheme is what the ergonomics push toward and is
 *    exactly what we refuse to ship: on macOS any app can register a scheme
 *    and intercept the callback, and there is no PKCE binding to stop it.
 *
 * So this is a thin bridge we own. It enforces loopback validation and S256
 * PKCE, and delegates code minting / expiry / single-use to Better Auth's
 * oneTimeToken plugin — the "code" handed to the loopback listener IS a
 * one-time token, redeemable only with the matching `code_verifier`.
 *
 * Defence in depth on the code:
 *   1. the attacker cannot claim the port (the app binds it before opening the
 *      browser, and it is unpredictable per run);
 *   2. redemption needs the `code_verifier`, which never leaves the app;
 *   3. single use twice over — our atomic `consumed` flip AND Better Auth's
 *      consumeVerificationValue;
 *   4. bound to the exact `redirect_uri` (including port) that requested it;
 *   5. two-minute lifetime;
 *   6. `state` is verified by the client before redemption.
 */

import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { getAuth, hasAppleConfig, hasGoogleConfig } from "../lib/auth";
import { requireAuth } from "../middleware/auth";
import { resolveTier } from "../lib/entitlement";

export const desktopRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/** Authorization requests live 10 minutes; the code inside lives 2. */
const REQUEST_TTL_SEC = 600;

/** The one path a loopback redirect may use. */
const CALLBACK_PATH = "/capturecat-auth/callback";

const PROVIDERS = new Set(["apple", "google"]);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function nowSec(): number {
  return Math.floor(Date.now() / 1000);
}

function base64Url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const byte of view) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Base64Url(value: string): Promise<string> {
  return base64Url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

/** Length-independent, constant-time string comparison. */
function timingSafeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let diff = left.length === right.length ? 0 : 1;
  const width = Math.max(left.length, right.length);
  for (let i = 0; i < width; i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

const BASE64URL = /^[A-Za-z0-9\-_]+$/;

/**
 * RFC 8252 §7.3 + §8.3 loopback validation.
 *
 * `localhost` is rejected on purpose: it resolves through DNS and is therefore
 * rebindable, which is why §8.3 recommends the literal loopback IP. Any port
 * is accepted — that is the whole point of a loopback redirect — but it must
 * be unprivileged, and the URI may carry no query or fragment of its own.
 */
function isValidLoopbackRedirect(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol !== "http:") return false;
  // URL normalises the IPv6 literal to "[::1]".
  if (url.hostname !== "127.0.0.1" && url.hostname !== "[::1]" && url.hostname !== "::1") {
    return false;
  }
  if (url.pathname !== CALLBACK_PATH) return false;
  if (url.search !== "" || url.hash !== "") return false;
  const port = Number(url.port);
  return Number.isInteger(port) && port >= 1024 && port <= 65535;
}

function htmlPage(title: string, message: string, accent: string): string {
  const escape = (text: string) =>
    text.replace(/[&<>"']/g, (ch) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch] as string,
    );
  return `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(title)}</title><style>
:root{color-scheme:light dark}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font:400 15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f5f5f7;color:#1d1d1f}
@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}}
.card{text-align:center;padding:40px 48px}
.dot{width:44px;height:44px;border-radius:50%;background:${accent};margin:0 auto 20px}
h1{font-size:19px;margin:0 0 8px;font-weight:600}p{margin:0;opacity:.65}
</style></head><body><div class="card"><div class="dot"></div>
<h1>${escape(title)}</h1><p>${escape(message)}</p></div></body></html>`;
}

function errorPage(message: string) {
  return htmlPage("Sign-in failed", message, "#ff3b30");
}

/**
 * Provider chooser, served when the desktop app starts a flow WITHOUT naming a
 * provider — which is now what it always does. The app ships one "Sign In"
 * button and the choice is made here, so adding or retiring a provider is a
 * server deploy rather than a macOS release.
 *
 * Each button re-enters `/desktop/authorize` with the SAME PKCE challenge,
 * redirect URI and state, so choosing a provider is just the second half of one
 * flow — no extra server state, no schema change, and every parameter is
 * re-validated on the way through. Carrying the challenge in these URLs is
 * fine: `code_challenge` is the public SHA-256 half of PKCE, and the verifier
 * never leaves the app.
 */
function chooserPage(params: {
  redirectUri: string;
  codeChallenge: string;
  method: string;
  clientState: string | null;
  providers: Array<{ id: string; label: string; mark: string }>;
}): string {
  const escape = (text: string) =>
    text.replace(/[&<>"']/g, (ch) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch] as string,
    );
  const href = (provider: string) => {
    const query = new URLSearchParams({
      provider,
      redirect_uri: params.redirectUri,
      code_challenge: params.codeChallenge,
      code_challenge_method: params.method,
    });
    if (params.clientState !== null) query.set("state", params.clientState);
    return escape(`/api/desktop/authorize?${query.toString()}`);
  };
  const buttons = params.providers
    .map(
      (p) =>
        `<a class="btn" href="${href(p.id)}"><span class="mark">${p.mark}</span>${escape(p.label)}</a>`,
    )
    .join("\n");
  return `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in to CaptureCat</title><style>
:root{color-scheme:light dark}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font:400 15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f5f5f7;color:#1d1d1f}
@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}
.btn{background:#2c2c2e;border-color:#3a3a3c;color:#f5f5f7}}
.card{text-align:center;padding:40px 48px;max-width:320px}
h1{font-size:19px;margin:0 0 8px;font-weight:600}
p{margin:0 0 24px;opacity:.65}
.btn{display:flex;align-items:center;justify-content:center;gap:8px;text-decoration:none;
background:#fff;border:1px solid #d2d2d7;border-radius:10px;padding:11px 16px;margin-bottom:10px;
color:#1d1d1f;font-weight:500;font-size:14px}
.btn:hover{border-color:#86868b}
.mark{font-size:16px;line-height:1}
</style></head><body><div class="card">
<h1>Sign in to CaptureCat</h1><p>${
    params.providers.length > 1 ? "Choose how you&#39;d like to continue." : "Continue to your account."
  }</p>
${buttons}
</div></body></html>`;
}

/**
 * All Set-Cookie values as separate strings. workerd implements
 * `Headers.getSetCookie()`, but @cloudflare/workers-types does not declare it
 * yet — hence the cast, with a single-value fallback so this can never throw.
 * Splitting a folded header on commas is deliberately NOT done: `Expires`
 * dates contain commas.
 */
function setCookieValues(headers: Headers): string[] {
  const withGetter = headers as unknown as { getSetCookie?: () => string[] };
  if (typeof withGetter.getSetCookie === "function") {
    return withGetter.getSetCookie();
  }
  const single = headers.get("set-cookie");
  return single ? [single] : [];
}

// ---------------------------------------------------------------------------
// GET /desktop/authorize — start the flow
// ---------------------------------------------------------------------------

desktopRoutes.get("/desktop/authorize", async (c) => {
  const provider = c.req.query("provider") ?? "";
  const redirectUri = c.req.query("redirect_uri") ?? "";
  const codeChallenge = c.req.query("code_challenge") ?? "";
  const method = c.req.query("code_challenge_method") ?? "";
  const clientState = c.req.query("state") ?? null;

  // An EMPTY provider is the normal case now — the app has a single "Sign In"
  // button and the choice happens on the chooser page below. A NON-empty but
  // unknown provider is still an error: it means something built a URL by hand.
  if (provider !== "" && !PROVIDERS.has(provider)) {
    return c.html(errorPage("Unsupported sign-in provider."), 400);
  }
  // S256 only. `plain` would make the challenge equal to the verifier, which
  // defeats the entire point of PKCE on a shared machine.
  if (method !== "S256") {
    return c.html(errorPage("Unsupported code challenge method."), 400);
  }
  if (codeChallenge.length !== 43 || !BASE64URL.test(codeChallenge)) {
    return c.html(errorPage("Malformed code challenge."), 400);
  }
  if (!isValidLoopbackRedirect(redirectUri)) {
    return c.html(errorPage("The sign-in redirect address was rejected."), 400);
  }
  if (clientState !== null && (clientState.length > 128 || !BASE64URL.test(clientState))) {
    return c.html(errorPage("Malformed state."), 400);
  }

  // Every parameter is validated by this point, so the chooser can safely echo
  // them back into its links. Nothing is written to the database until a
  // provider is actually picked — an abandoned chooser leaves no row behind.
  if (provider === "") {
    // Only offer what is actually configured. `socialProviders` is registered
    // conditionally (a half-configured environment must still boot), so an
    // unconditional chooser would show a button that 502s — which is the normal
    // state while setting the second provider up, and exactly when a confusing
    // error is least welcome.
    const available = [
      hasAppleConfig(c.env) ? { id: "apple", label: "Continue with Apple", mark: "&#63743;" } : null,
      hasGoogleConfig(c.env) ? { id: "google", label: "Continue with Google", mark: "G" } : null,
    ].filter((p): p is { id: string; label: string; mark: string } => p !== null);

    if (available.length === 0) {
      return c.html(errorPage("No sign-in providers are configured."), 503);
    }
    // Exactly one configured provider: skip the chooser entirely rather than
    // asking someone to "choose" from a list of one.
    if (available.length === 1) {
      const query = new URLSearchParams({
        provider: available[0].id,
        redirect_uri: redirectUri,
        code_challenge: codeChallenge,
        code_challenge_method: method,
      });
      if (clientState !== null) query.set("state", clientState);
      return c.redirect(`/api/desktop/authorize?${query.toString()}`, 302);
    }
    return c.html(
      chooserPage({ redirectUri, codeChallenge, method, clientState, providers: available }),
    );
  }

  // A provider the app named but that is not configured would reach
  // signInSocial and fail as a generic 502; say so plainly instead.
  if (
    (provider === "apple" && !hasAppleConfig(c.env)) ||
    (provider === "google" && !hasGoogleConfig(c.env))
  ) {
    return c.html(errorPage("That sign-in provider is not configured."), 503);
  }

  const auth = getAuth(c.env);
  const origin = new URL(c.env.BETTER_AUTH_URL).origin;
  const rid = crypto.randomUUID();
  const created = nowSec();

  // Nothing else sweeps this table — do it opportunistically here, where the
  // write is already happening.
  try {
    await c.env.DB.prepare(`DELETE FROM desktop_auth_requests WHERE expires_at < ?`)
      .bind(created)
      .run();
  } catch (err) {
    console.error("desktop: sweep failed", err);
  }

  try {
    await c.env.DB.prepare(
      `INSERT INTO desktop_auth_requests
         (id, code_challenge, redirect_uri, client_state, provider, consumed, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7)`,
    )
      .bind(rid, codeChallenge, redirectUri, clientState, provider, created, created + REQUEST_TTL_SEC)
      .run();
  } catch (err) {
    console.error("desktop: could not record authorization request", err);
    return c.html(errorPage("Could not start sign-in. Please try again."), 500);
  }

  let result: { headers: Headers; response: unknown };
  try {
    result = await auth.api.signInSocial({
      body: {
        provider: provider as "apple" | "google",
        callbackURL: `${origin}/api/desktop/complete?rid=${rid}`,
        errorCallbackURL: `${origin}/api/desktop/failed?rid=${rid}`,
      },
      returnHeaders: true,
    });
  } catch (err) {
    console.error("desktop: signInSocial failed", err);
    return c.html(
      errorPage("This sign-in provider is not available right now."),
      502,
    );
  }

  const url = (result.response as { url?: string } | null)?.url;
  if (!url) {
    return c.html(errorPage("The provider did not return an authorization URL."), 502);
  }

  const redirect = c.redirect(url, 302);
  // CRITICAL: signInSocial sets the OAuth state cookie on ITS response. If it
  // is not forwarded onto our 302 the browser never gets it and the callback
  // dies with `state_security_mismatch`.
  for (const cookie of setCookieValues(result.headers)) {
    redirect.headers.append("Set-Cookie", cookie);
  }
  return redirect;
});

// ---------------------------------------------------------------------------
// GET /desktop/complete — provider callback landed, mint the code
// ---------------------------------------------------------------------------

desktopRoutes.get("/desktop/complete", async (c) => {
  const rid = c.req.query("rid") ?? "";
  if (!rid) return c.html(errorPage("Missing sign-in request id."), 400);

  const row = await c.env.DB.prepare(
    `SELECT redirect_uri, client_state, ott_hash, expires_at
       FROM desktop_auth_requests WHERE id = ?`,
  )
    .bind(rid)
    .first<{
      redirect_uri: string;
      client_state: string | null;
      ott_hash: string | null;
      expires_at: number;
    }>();

  if (!row) return c.html(errorPage("This sign-in request is unknown."), 400);
  if (row.expires_at <= nowSec()) {
    return c.html(errorPage("This sign-in request expired. Please try again from CaptureCat."), 400);
  }
  // A code was already minted for this request — refuse to mint a second.
  if (row.ott_hash) {
    return c.html(errorPage("This sign-in request was already completed."), 400);
  }

  const auth = getAuth(c.env);
  const session = await auth.api.getSession({ headers: c.req.raw.headers });
  if (!session) {
    return c.html(errorPage("Sign-in did not complete. Please try again from CaptureCat."), 401);
  }

  // Only this handler can mint a code: the plugin is configured with
  // `disableClientRequest: true`, which rejects any request that arrives over
  // HTTP, and `auth.api.*` populates `headers` rather than `request`.
  let code: string;
  try {
    const minted = await auth.api.generateOneTimeToken({ headers: c.req.raw.headers });
    code = minted.token;
  } catch (err) {
    console.error("desktop: could not mint one-time token", err);
    return c.html(errorPage("Could not finish sign-in. Please try again."), 500);
  }

  // Bind the code to this PKCE request, atomically. A concurrent replay of
  // /complete loses the race and changes nothing.
  const bind = await c.env.DB.prepare(
    `UPDATE desktop_auth_requests SET ott_hash = ?1 WHERE id = ?2 AND ott_hash IS NULL`,
  )
    .bind(await sha256Base64Url(code), rid)
    .run();

  if (!bind.meta.changes) {
    return c.html(errorPage("This sign-in request was already completed."), 400);
  }

  const target = new URL(row.redirect_uri);
  target.searchParams.set("code", code);
  if (row.client_state) target.searchParams.set("state", row.client_state);
  return c.redirect(target.toString(), 302);
});

// ---------------------------------------------------------------------------
// GET /desktop/failed — Better Auth's errorCallbackURL
// ---------------------------------------------------------------------------

desktopRoutes.get("/desktop/failed", async (c) => {
  const rid = c.req.query("rid");
  if (rid) {
    // Burn the request so the abandoned row cannot be completed later.
    await c.env.DB.prepare(`UPDATE desktop_auth_requests SET consumed = 1 WHERE id = ?`)
      .bind(rid)
      .run()
      .catch((err) => console.error("desktop: failed-cleanup", err));
  }
  const reason = c.req.query("error") ?? "";
  return c.html(
    errorPage(
      reason
        ? `The provider reported: ${reason}. Please try again from CaptureCat.`
        : "Sign-in was not completed. Please try again from CaptureCat.",
    ),
    400,
  );
});

// ---------------------------------------------------------------------------
// POST /desktop/token — code + verifier -> session token
// ---------------------------------------------------------------------------

desktopRoutes.post("/desktop/token", async (c) => {
  let body: { code?: unknown; code_verifier?: unknown; redirect_uri?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_request" }, 400);
  }

  const code = typeof body.code === "string" ? body.code : "";
  const verifier = typeof body.code_verifier === "string" ? body.code_verifier : "";
  const redirectUri = typeof body.redirect_uri === "string" ? body.redirect_uri : "";

  // RFC 7636 §4.1: 43–128 characters from the unreserved set.
  if (!code || verifier.length < 43 || verifier.length > 128 || !BASE64URL.test(verifier)) {
    return c.json({ error: "invalid_request" }, 400);
  }

  // Burn the request atomically: one statement, so two concurrent redemptions
  // cannot both win.
  const burned = await c.env.DB.prepare(
    `UPDATE desktop_auth_requests
        SET consumed = 1
      WHERE ott_hash = ?1 AND consumed = 0 AND expires_at > ?2
      RETURNING code_challenge, redirect_uri`,
  )
    .bind(await sha256Base64Url(code), nowSec())
    .first<{ code_challenge: string; redirect_uri: string }>();

  if (!burned) {
    return c.json({ error: "invalid_grant" }, 400);
  }

  // PKCE: base64url(SHA256(verifier)) must equal the stored challenge.
  if (!timingSafeEqual(await sha256Base64Url(verifier), burned.code_challenge)) {
    console.error("desktop: PKCE verification failed");
    return c.json({ error: "invalid_grant" }, 400);
  }

  // Bind the code to the exact port that asked for it.
  if (!timingSafeEqual(redirectUri, burned.redirect_uri)) {
    return c.json({ error: "invalid_grant" }, 400);
  }

  const auth = getAuth(c.env);
  let verified: { session: { token: string; expiresAt: Date | string }; user: Record<string, unknown> };
  try {
    verified = (await auth.api.verifyOneTimeToken({ body: { token: code } })) as typeof verified;
  } catch (err) {
    console.error("desktop: one-time token redemption failed", err);
    return c.json({ error: "invalid_grant" }, 400);
  }

  const expiresAt =
    verified.session.expiresAt instanceof Date
      ? verified.session.expiresAt.toISOString()
      : String(verified.session.expiresAt);

  // `disableSetSessionCookie` is on, so no cookie / set-auth-token header is
  // emitted here — the RAW session token is returned in the body and the app
  // stores it in the Keychain.
  return c.json({
    token: verified.session.token,
    expiresAt,
    user: {
      id: verified.user.id,
      email: verified.user.email ?? null,
      name: verified.user.name ?? null,
      image: verified.user.image ?? null,
    },
  });
});

// ---------------------------------------------------------------------------
// POST /desktop/revoke — sign out from the desktop app
// ---------------------------------------------------------------------------

desktopRoutes.post("/desktop/revoke", async (c) => {
  const header = c.req.header("Authorization");
  if (!header?.startsWith("Bearer ")) {
    return c.json({ error: "Missing or invalid Authorization header" }, 401);
  }
  try {
    await getAuth(c.env).api.signOut({ headers: c.req.raw.headers });
  } catch (err) {
    // An already-dead session is a successful sign-out from the client's
    // point of view — it has dropped the credential either way.
    console.error("desktop: sign-out", err);
  }
  return c.json({ ok: true });
});

// ---------------------------------------------------------------------------
// GET /me — identity + resolved entitlement for the signed-in caller
// ---------------------------------------------------------------------------
//
// The desktop export gate needs the resolved TIER, which no Better Auth
// endpoint exposes: /api/auth/get-session carries tester/blocked but not paid,
// and /api/auth/subscription/list applies Better Auth's own
// isActiveOrTrialing() — which excludes `past_due` and would therefore lock
// out a subscriber in dunning that this API still treats as paid.
desktopRoutes.get("/me", requireAuth, async (c) => {
  const user = c.get("user");
  const tier = await resolveTier(c.env.DB, user.uid, user.claims);

  return c.json({
    uid: user.uid,
    email: user.email ?? null,
    tier: tier === "blocked" ? "free" : tier,
    tester: user.claims?.tester === true,
    blocked: tier === "blocked",
    // Better Auth slides the session expiry forward on use without changing
    // the token. Handing the current value back lets the desktop app refresh
    // its Keychain copy instead of expiring a session that is still alive.
    sessionExpiresAt: c.get("session")?.expiresAt ?? null,
  });
});
