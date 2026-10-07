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
import { orgRoutes } from "./routes/org";
import { hubRoutes } from "./routes/hub";
import { storageRoutes } from "./routes/storage";
import { deleteStoredObject } from "./lib/storage";
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
import { ssoRoutes } from "./routes/sso";
import { cloudProjectRoutes } from "./routes/cloud-projects";
import { cloudProjectHistoryRoutes } from "./routes/cloud-project-history";
import { stalePendingObjects } from "./lib/cloud-projects-db";
import { sweepCloudProjectHistory } from "./lib/project-history-db";
import { planForUser } from "./lib/entitlement";
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
    allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    // If-Match: the web editor's project.json saves name the revision they
    // were based on (PUT /api/cloud-projects/:id/project → 409 on conflict).
    // X-CC-*: the optional history headers of a save (docs/project-history.md
    // §6) — without them in the preflight a browser could not send any.
    allowHeaders: [
      "Content-Type",
      "Authorization",
      "If-Match",
      "X-CC-Client",
      "X-CC-Client-Id",
      "X-CC-Source",
      "X-CC-Change",
      "X-CC-Checkpoint",
      "X-CC-Merged-From",
    ],
    exposeHeaders: ["ETag"],
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
  // Stripe webhooks: no per-IP limit at all. Stripe delivers every event
  // from a handful of shared IPs, so the credential limiter here 429'd
  // legitimate bursts — which any customer can cause by toggling their
  // subscription in the portal — and Stripe retries a 429 later and out of
  // order, i.e. a throttled cancellation lands late. Each delivery is
  // authenticated by its HMAC signature (cheap to refuse) and is idempotent.
  if (path === "/api/auth/stripe/webhook") {
    return next();
  }
  // Identity-provider round trips: the OIDC callback and SAML ACS/SLO posts
  // arrive from a whole company behind one egress IP (or from the IdP
  // itself). They carry a state-bound code, not a guessable credential, so
  // they get the read-side ceiling rather than the credential one.
  if (path.startsWith("/api/auth/sso/callback") || path.startsWith("/api/auth/sso/saml2/")) {
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
// Cloud projects (web editor): the cheap per-IP outer layer. The editor
// refreshes presigned media URLs and autosaves (debounced), and one Mac sync
// is ~3 writes; the per-uid D1 limits inside the router are the real bound.
// One pattern only: Hono's `/*` also matches the bare `/api/cloud-projects`
// (the list), so registering both would count that request twice.
app.use("/api/cloud-projects/*", rateLimit({ limit: 300, windowSec: 60, prefix: "cloudproj" }));
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
// Bring-your-own S3 bucket for share videos (migration 0029).
app.route("/api", storageRoutes);
app.route("/api", orgRoutes);
// Enterprise SSO overview + domain verification for org admins; the sign-in
// and provider CRUD endpoints themselves are Better Auth's under /api/auth.
app.route("/api", ssoRoutes);
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
// Cloud projects for the web editor (app.capturecat.so/editor): Mac upload
// (manifest → presigned PUTs → verified finalize), presigned media GETs, and
// project.json saves with If-Match optimistic concurrency. Owner writes; org
// members read. See src/routes/cloud-projects.ts.
app.route("/api", cloudProjectRoutes);
// Their history: versions list/preview, name, restore, delete, free up.
// Members read, name and restore; the owner deletes. See
// src/routes/cloud-project-history.ts and docs/project-history.md.
app.route("/api", cloudProjectHistoryRoutes);

// Catch-all — block everything else
app.all("*", (c) => c.json({ error: "Not found" }, 404));

/**
 * Hourly housekeeping:
 *  - abandoned uploads: rows stuck in "pending" for > 2 h are deleted along
 *    with any bytes that made it to R2 (a presigned PUT can succeed without
 *    /complete ever being called — those objects are billed but invisible
 *    to the storage quota);
 *  - rate_limits rows whose window ended over a day ago;
 *  - cloud-project history retention + orphaned manifests (0027).
 */
async function sweep(env: Env): Promise<void> {
  const cutoff = new Date(Date.now() - 2 * 3600 * 1000).toISOString();
  const stale = await env.DB.prepare(
    "SELECT video_id, r2_key, storage_id FROM shared_videos WHERE status = 'pending' AND created_at < ? LIMIT 200"
  ).bind(cutoff).all<{ video_id: string; r2_key: string; storage_id: string | null }>();
  for (const row of stale.results ?? []) {
    // A custom bucket (0029) is reached through its own S3 API.
    await deleteStoredObject(env, row.storage_id, row.r2_key).catch(() => {});
    await env.DB.prepare("DELETE FROM video_versions WHERE video_id = ? AND status = 'pending'")
      .bind(row.video_id).run();
    await env.DB.prepare("DELETE FROM shared_videos WHERE video_id = ? AND status = 'pending'")
      .bind(row.video_id).run();
  }
  const staleVersions = await env.DB.prepare(
    "SELECT video_id, version_number, r2_key, storage_id FROM video_versions WHERE status = 'pending' AND created_at < ? LIMIT 200"
  ).bind(cutoff).all<{ video_id: string; version_number: number; r2_key: string; storage_id: string | null }>();
  for (const row of staleVersions.results ?? []) {
    await deleteStoredObject(env, row.storage_id, row.r2_key).catch(() => {});
    await env.DB.prepare(
      "DELETE FROM video_versions WHERE video_id = ? AND version_number = ? AND status = 'pending'"
    ).bind(row.video_id, row.version_number).run();
  }
  // Cloud-project objects presigned but never verified by /finalize: the PUT
  // may have landed (billed, invisible to the quota) — delete bytes + row.
  // A verified (ready) object is never touched here.
  for (const obj of await stalePendingObjects(env.DB, cutoff)) {
    await env.R2.delete(obj.r2Key).catch(() => {});
    await env.DB.prepare(
      "DELETE FROM cloud_project_objects WHERE project_id = ? AND sha256 = ? AND status = 'pending'"
    ).bind(obj.projectId, obj.sha256).run();
  }
  // Disconnected buckets kept only so their videos could play: once no
  // video or version points at one, its credentials have no reason to stay.
  await env.DB.prepare(
    `DELETE FROM storage_buckets
      WHERE active = 0
        AND NOT EXISTS (SELECT 1 FROM video_versions vv WHERE vv.storage_id = storage_buckets.id)
        AND NOT EXISTS (SELECT 1 FROM shared_videos sv WHERE sv.storage_id = storage_buckets.id)`
  ).run();
  await env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?")
    .bind(Math.floor(Date.now() / 1000) - 86_400).run();
  // Cloud-project history retention under each owner's CURRENT plan (a
  // downgrade trims here), then orphaned manifests. Saves prune a few
  // versions inline; this catches up the rest.
  await sweepCloudProjectHistory(env, Date.now(), async (uid) => (await planForUser(env, uid)).limits).catch(
    (err) => console.error("history sweep failed", err),
  );
}

export default {
  fetch: app.fetch,
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(sweep(env));
  },
};

// Durable Object classes must be exported from the Worker entrypoint.
export { ShareJobsDO } from "./share-jobs";
