import { Hono } from "hono";
import { cors } from "hono/cors";
import type { Env } from "./types";
import { getAuth } from "./lib/auth";
import { desktopRoutes } from "./routes/desktop";
import { webOrigins } from "./lib/origins";
import { adminRoutes } from "./routes/admin";
import { planRoutes } from "./routes/plans";
import { uploadRoutes } from "./routes/upload";
import { jobRoutes } from "./routes/jobs";
import { hubRoutes } from "./routes/hub";
import { videoRoutes } from "./routes/video";
import { analyticsRoutes } from "./routes/analytics";
import { deleteRoutes } from "./routes/delete";
import { playlistRoutes } from "./routes/playlists";
import { profileRoutes } from "./routes/profile";
import { releaseRoutes } from "./routes/releases";
import { attestRoutes } from "./routes/attest";
import { aiRoutes } from "./routes/ai";
import { betaRoutes } from "./routes/beta";
import { screenshotRoutes } from "./routes/screenshot";
import { rateLimit } from "./middleware/rate-limit";

const app = new Hono<{ Bindings: Env }>();

// Stripe webhooks are now served by the Better Auth Stripe plugin at
// POST /api/auth/stripe/webhook — see src/lib/stripe.ts. The old
// POST /webhooks/stripe route is deleted; nothing may read the request body
// before the Better Auth handler runs (the webhook endpoint reads it itself).

// ---------------------------------------------------------------------------
// CORS
// ---------------------------------------------------------------------------

// The auth surface needs its own policy: `credentials: true` for the browser
// leg, and `set-auth-token` exposed so a browser client can read the bearer
// token off a sign-in response. Better Auth's OAuth legs are top-level
// navigations (no CORS involved) and Stripe's webhook POST carries no Origin,
// so neither is affected by this.
app.use(
  "/api/auth/*",
  cors({
    origin: (origin, c) => webOrigins(c.env).includes(origin) ? origin : null,
    allowMethods: ["GET", "POST", "OPTIONS"],
    allowHeaders: ["Content-Type", "Authorization"],
    exposeHeaders: ["set-auth-token"],
    credentials: true,
    maxAge: 600,
  })
);

// Everything else — unchanged.
app.use(
  "/api/*",
  cors({
    origin: (origin, c) => webOrigins(c.env).includes(origin) ? origin : null,
    allowMethods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allowHeaders: ["Content-Type", "Authorization"],
    // REQUIRED: without this the browser will not send the session cookie to
    // /api/me, /api/videos, /api/video or /api/admin, so a cookie-authenticated
    // web client gets 401 on every one of them even though requireAuth now
    // accepts cookies.
    credentials: true,
    maxAge: 86400,
  })
);

// ---------------------------------------------------------------------------
// Rate limits per route type (per-IP, Cache API backed)
// ---------------------------------------------------------------------------
// Better Auth ships its own limiter, but it is memory-backed and therefore
// per-isolate on Workers — this cheap outer layer is what actually bounds
// credential-stuffing and sign-in spam.
// ---------------------------------------------------------------------------
// Admin plugin deny-list — DEFENCE IN DEPTH, not decoration
// ---------------------------------------------------------------------------
// The `admin` plugin mounts fifteen endpoints. These five are refused before
// they reach Better Auth, because each is a primitive we never want reachable
// even from a compromised admin session:
//
//   update-user        its body is `data: z.record(z.any(), z.any())` passed
//                      straight to internalAdapter.updateUser — an UNTYPED
//                      write over the user row. It bypasses every
//                      `input: false` guard, so it can set `tester`,
//                      `blocked`, `role` or `emailVerified` directly. This is
//                      the privilege-escalation primitive in the plugin.
//   create-user        same untyped `data` bag, on insert.
//   set-user-password  emailAndPassword is disabled, so this does not "reset"
//                      anything — it CREATES a password credential on a
//                      social-only account, known to whoever called it.
//   impersonate-user   issues a real session as another user. Nothing in the
//                      product needs it and the blast radius is total.
//   remove-user        hard-deletes the row; entitlement changes are reversible
//                      and this is not.
//
// ban-user/unban-user are also denied: `user.blocked` is the single blocking
// mechanism (resolveTier() and GET /api/me derive the "blocked" tier from it,
// and the desktop client depends on that). Two mechanisms would drift.
const DENIED_ADMIN_ENDPOINTS = [
  "/api/auth/admin/update-user",
  "/api/auth/admin/create-user",
  "/api/auth/admin/set-user-password",
  "/api/auth/admin/impersonate-user",
  "/api/auth/admin/remove-user",
  "/api/auth/admin/ban-user",
  "/api/auth/admin/unban-user",
];
app.use("/api/auth/admin/*", async (c, next) => {
  if (DENIED_ADMIN_ENDPOINTS.includes(new URL(c.req.url).pathname)) {
    return c.json({ error: "Not found" }, 404);
  }
  await next();
});

// `get-session` is exempted from the credential limit and given its own,
// far higher ceiling.
//
// The 30/60s exists to bound credential-stuffing and sign-in spam, which is
// about endpoints that CREATE credentials. get-session only reads one — and
// since the web apps verify server-side, every authenticated page render and
// every tRPC batch is one of these calls. A navigation-heavy admin session
// reaches 30 in well under a minute, and then the whole auth surface 429s.
//
// Do NOT reach for `session.cookieCache` to reduce these: it is off on purpose
// (see lib/auth.ts) because it would let a revoked session keep working.
const sessionLimiter = rateLimit({ limit: 600, windowSec: 60, prefix: "session" });
const credentialLimiter = rateLimit({ limit: 30, windowSec: 60, prefix: "auth" });

app.use("/api/auth/*", async (c, next) => {
  // Hono runs EVERY matching middleware, so registering a narrower limiter
  // before this wildcard does not exempt anything — both would apply and the
  // stricter one still wins. The branch has to be explicit.
  const path = new URL(c.req.url).pathname;
  if (path === "/api/auth/get-session") {
    return sessionLimiter(c, next);
  }
  return credentialLimiter(c, next);
});
// Desktop loopback/PKCE bridge: 20 per minute per IP.
app.use("/api/desktop/*", rateLimit({ limit: 20, windowSec: 60, prefix: "desktop" }));
// Uploads: 10 per minute per IP (auth-gated too). Job progress reports are a
// different animal — one upload legitimately sends dozens of small updates a
// minute — so /api/upload/jobs/* gets its own, higher ceiling. The branch must
// be explicit: Hono runs every matching middleware, so a second narrower
// limiter would not exempt anything.
const uploadLimiter = rateLimit({ limit: 10, windowSec: 60, prefix: "upload" });
const jobsLimiter = rateLimit({ limit: 120, windowSec: 60, prefix: "jobs" });
app.use("/api/upload/*", async (c, next) => {
  const path = new URL(c.req.url).pathname;
  if (path.startsWith("/api/upload/jobs")) {
    return jobsLimiter(c, next);
  }
  return uploadLimiter(c, next);
});
// Video streaming: 120 per minute per IP (generous for seeking)
app.use("/api/video/*", rateLimit({ limit: 120, windowSec: 60, prefix: "video" }));
// Screenshot API: renders are expensive (each one is billed browser time), so
// the take endpoint gets a tight per-IP ceiling; key management is cheap D1
// work and gets its own, looser one. The branch is explicit for the same
// reason as /api/upload above — Hono runs EVERY matching middleware, so a
// second narrower limiter would stack with, not replace, this one.
const screenshotTakeLimiter = rateLimit({ limit: 10, windowSec: 60, prefix: "shot" });
const screenshotKeysLimiter = rateLimit({ limit: 30, windowSec: 60, prefix: "shotkeys" });
app.use("/api/screenshot/*", async (c, next) => {
  const path = new URL(c.req.url).pathname;
  if (path.startsWith("/api/screenshot/keys")) {
    return screenshotKeysLimiter(c, next);
  }
  return screenshotTakeLimiter(c, next);
});
// Public beta waitlist sign-up: 5 per minute per IP. This is the outer bound on
// sign-up spam; the route itself adds a honeypot + Turnstile + email dedupe.
app.use("/api/beta", rateLimit({ limit: 5, windowSec: 60, prefix: "beta" }));

// ---------------------------------------------------------------------------
// Better Auth
// ---------------------------------------------------------------------------
// Must be registered BEFORE the app.all("*") catch-all, and nothing may
// consume the request body first — /api/auth/stripe/webhook reads it itself in
// order to verify the Stripe signature over the exact raw bytes.
//
// POST is mandatory, not optional: Apple's callback arrives as
// response_mode=form_post, and the Stripe webhook is a POST.
//
// Serves: /sign-in/social, /callback/{google,apple}, /get-session, /sign-out,
// /one-time-token/*, /subscription/* and /stripe/webhook — all under
// basePath "/api/auth".
app.on(["POST", "GET"], "/api/auth/*", (c) => getAuth(c.env).handler(c.req.raw));

// Health check — no rate limit
app.get("/api/health", (c) => c.json({ status: "ok" }));

// Desktop loopback + PKCE bridge (RFC 8252 / RFC 7636) plus GET /api/me.
// Serves /api/desktop/{authorize,complete,failed,token,revoke} — the native
// macOS sign-in flow. See src/routes/desktop.ts for why Better Auth's own
// provider plugins cannot express a random-port loopback redirect.
app.route("/api", desktopRoutes);
// Admin directory + entitlement writes for the web dashboard. Gated by the
// `user.role === "admin"` check inside the router.
app.route("/api", adminRoutes);
// Public pricing — reads the live Stripe price so the marketing page cannot
// advertise a number the checkout does not charge.
app.route("/api", planRoutes);

app.route("/api", uploadRoutes);
app.route("/api", jobRoutes);
app.route("/api", hubRoutes);
app.route("/api", videoRoutes);
// Viewer analytics (ingest is public + rate limited, reads are owner-only).
app.route("/api", analyticsRoutes);
app.route("/api", deleteRoutes);
app.route("/api", playlistRoutes);
app.route("/api", profileRoutes);
app.route("/api", releaseRoutes);
app.route("/api", attestRoutes);
app.route("/api", aiRoutes);
// Public beta waitlist ingest (honeypot + Turnstile + email dedupe inside).
app.route("/api", betaRoutes);
// Gated screenshot-rendering API (session OR hashed access key; pro-plan
// feature gate + monthly D1 quota inside). Engine is Browser Rendering's REST
// endpoint — see src/lib/screenshot/renderer.ts for the cost rationale.
app.route("/api", screenshotRoutes);

// Catch-all — block everything else
app.all("*", (c) => c.json({ error: "Not found" }, 404));

export default app;

// Durable Object classes must be exported from the Worker entrypoint.
export { ShareJobsDO } from "./share-jobs";
