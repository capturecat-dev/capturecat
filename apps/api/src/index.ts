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
import { siteAnalyticsRoutes } from "./routes/site-analytics";
import { screenshotRoutes } from "./routes/screenshot";
import { ssoRoutes } from "./routes/sso";
import { cloudProjectRoutes } from "./routes/cloud-projects";
import { cloudProjectHistoryRoutes } from "./routes/cloud-project-history";
import { stalePendingObjects } from "./lib/cloud-projects-db";
import { sweepCloudProjectHistory } from "./lib/project-history-db";
import { planForUser } from "./lib/entitlement";
import { rateLimit } from "./middleware/rate-limit";
import { agentTokenRoutes } from "./routes/agent-tokens";
import { mcpRoutes } from "./mcp/routes";
import { AGENT_AUDIT_RETENTION_DAYS } from "./lib/agent-tokens";
import { agentApprovalRoutes } from "./routes/agent-approvals";
import { webhookRoutes } from "./routes/webhooks";
import { oauthRoutes } from "./routes/oauth";
import { WEBHOOK_DELIVERY_RETENTION_DAYS, processWebhookOutbox } from "./lib/webhooks";

const app = new Hono<{ Bindings: Env }>();

// ---------------------------------------------------------------------------
// mcp.capturecat.so — the remote MCP endpoint's own host, and NOTHING else
// ---------------------------------------------------------------------------
// The same Worker answers on api.capturecat.so and mcp.capturecat.so (two
// custom domains in wrangler.toml). On the MCP host only the MCP endpoint
// and its well-known card exist: Better Auth, the session API, uploads and
// admin are a JSON 404 there. Registered FIRST so no route or middleware
// below — /api/auth/* included — ever sees a request for that host.
// api.capturecat.so/mcp stays as an alias (and is what `wrangler dev` serves).
// The two RFC 9728 paths are the protected-resource metadata an MCP client
// reads to find the OAuth server (routes/oauth.ts); the authorization server
// itself lives on api.capturecat.so.
const MCP_HOST = "mcp.capturecat.so";
const MCP_HOST_PATHS = new Set([
  "/mcp",
  "/.well-known/mcp/server-card.json",
  "/.well-known/oauth-protected-resource",
  "/.well-known/oauth-protected-resource/mcp",
]);
app.use("*", async (c, next) => {
  const url = new URL(c.req.url);
  if (url.hostname === MCP_HOST && !MCP_HOST_PATHS.has(url.pathname)) {
    return c.json({ error: "Not found" }, 404);
  }
  await next();
});

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

// Remote MCP: bearer-token only (never cookies), so any origin may call it —
// browser-based MCP clients included — without credentials.
app.use(
  "/mcp",
  cors({
    origin: "*",
    allowMethods: ["POST", "GET", "DELETE", "OPTIONS"],
    allowHeaders: ["Authorization", "Content-Type", "Mcp-Protocol-Version", "Mcp-Session-Id"],
    exposeHeaders: ["WWW-Authenticate"],
    credentials: false,
    maxAge: 86400,
  })
);

// OAuth for the MCP server (routes/oauth.ts): the discovery documents and
// the token, registration and revocation endpoints are called by MCP clients
// — browser-based ones included — with no cookies, so any origin may.
// /oauth/authorize is a top-level navigation and needs no CORS.
app.use(
  "/.well-known/oauth-*",
  cors({ origin: "*", allowMethods: ["GET", "OPTIONS"], credentials: false, maxAge: 86400 }),
);
app.use(
  "/oauth/*",
  cors({
    origin: "*",
    allowMethods: ["GET", "POST", "OPTIONS"],
    allowHeaders: ["Authorization", "Content-Type", "Mcp-Protocol-Version"],
    credentials: false,
    maxAge: 86400,
  }),
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
// Agent-token management (session only): cheap D1 work, minting has its own
// per-user limit in the router. /mcp itself is limited per TOKEN, not per
// IP — see src/mcp/routes.ts for why.
app.use("/api/agent-tokens/*", rateLimit({ limit: 60, windowSec: 60, prefix: "agenttokens" }));
// Approvals, webhooks and the OAuth consent API (session only): cheap D1 work.
app.use("/api/agent-approvals/*", rateLimit({ limit: 60, windowSec: 60, prefix: "agentapprovals" }));
app.use("/api/webhooks/*", rateLimit({ limit: 60, windowSec: 60, prefix: "webhooks" }));
app.use("/api/oauth/*", rateLimit({ limit: 60, windowSec: 60, prefix: "oauthapi" }));
// OAuth: only the consent redirect is limited per IP — it is a browser
// navigation from the user's own address. /oauth/token, /oauth/revoke and
// /oauth/register are called server-to-server by Claude.ai, ChatGPT & co.
// from a few SHARED egress IPs, so a per-IP limit there would throttle every
// user of a platform together (the Stripe-webhook lesson above). Token and
// revoke requests are authenticated by high-entropy secrets and cheap to
// refuse; registration has its own generous per-IP D1 cap (routes/oauth.ts)
// and unused registrations are swept after 30 days.
app.use("/oauth/authorize", rateLimit({ limit: 60, windowSec: 60, prefix: "oauth" }));
// Public beta waitlist sign-up: 5 per minute per IP. This is the outer bound on
// sign-up spam; the route itself adds a honeypot + Turnstile + email dedupe.
app.use("/api/beta", rateLimit({ limit: 5, windowSec: 60, prefix: "beta" }));
// Anonymous site visit/download events: a person browsing sends a handful a
// minute at most; this only bounds a script replaying them.
app.use("/api/site/*", rateLimit({ limit: 30, windowSec: 60, prefix: "site" }));

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
// Anonymous acquisition events from the marketing site (no cookie, no id).
app.route("/api", siteAnalyticsRoutes);
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
// Scoped tokens for cloud agents (session-only management + audit log).
app.route("/api", agentTokenRoutes);
// "Ask me first": the owner approves or denies an agent's request to make a
// video more visible or to post a comment (session only).
app.route("/api", agentApprovalRoutes);
// Webhook endpoints (session only; agents use the MCP tools).
app.route("/api", webhookRoutes);
// OAuth 2.1 for the MCP server: discovery, /oauth/*, and the consent page's
// session API under /api/oauth/*.
app.route("/", oauthRoutes);
// The remote MCP server (agent tokens): https://mcp.capturecat.so/mcp, and
// /mcp on this host as an alias. See src/mcp/.
app.route("/", mcpRoutes);

// Catch-all — block everything else
app.all("*", (c) => c.json({ error: "Not found" }, 404));

/**
 * Hourly housekeeping:
 *  - abandoned uploads: rows stuck in "pending" for > 2 h are deleted along
 *    with any bytes that made it to R2 (a presigned PUT can succeed without
 *    /complete ever being called — those objects are billed but invisible
 *    to the storage quota);
 *  - rate_limits rows whose window ended over a day ago;
 *  - site_events older than 13 months (0030);
 *  - agent_audit_log rows older than 90 days (0033);
 *  - decided/expired approvals after 90 days (0034); spent or expired OAuth
 *    codes, dead refresh tokens and expired OAuth access tokens (0035);
 *    webhook deliveries after 30 days (0036);
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
  // Agent audit rows (0033): 90 days is enough to answer "what did my
  // agent do last month", and the table is written on every tool call.
  await env.DB.prepare("DELETE FROM agent_audit_log WHERE at < ?")
    .bind(new Date(Date.now() - AGENT_AUDIT_RETENTION_DAYS * 86_400_000).toISOString()).run();
  await sweepAgentPhase2(env).catch((err) => console.error("agent sweep failed", err));
  await env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?")
    .bind(Math.floor(Date.now() / 1000) - 86_400).run();
  // Site acquisition events (0030) are kept 13 months: a year-on-year view,
  // then gone.
  await env.DB.prepare("DELETE FROM site_events WHERE created_at < ?")
    .bind(new Date(Date.now() - 395 * 86_400_000).toISOString()).run();
  // Cloud-project history retention under each owner's CURRENT plan (a
  // downgrade trims here), then orphaned manifests. Saves prune a few
  // versions inline; this catches up the rest.
  await sweepCloudProjectHistory(env, Date.now(), async (uid) => (await planForUser(env, uid)).limits).catch(
    (err) => console.error("history sweep failed", err),
  );
}

/** Housekeeping for approvals, OAuth and webhooks (migrations 0034–0036). */
async function sweepAgentPhase2(env: Env): Promise<void> {
  const now = Date.now();
  const iso = (msAgo: number) => new Date(now - msAgo).toISOString();
  const DAY = 86_400_000;
  // Approvals: kept 90 days for the record (the audit log names them too).
  await env.DB.prepare("DELETE FROM agent_approvals WHERE created_at < ?").bind(iso(AGENT_AUDIT_RETENTION_DAYS * DAY)).run();
  // Codes live 10 minutes; a day later nothing can still need one.
  await env.DB.prepare("DELETE FROM oauth_codes WHERE expires_at < ?").bind(iso(DAY)).run();
  // Refresh tokens: expired, rotated or revoked for over a day.
  await env.DB.prepare(
    "DELETE FROM oauth_refresh_tokens WHERE expires_at < ?1 OR (used_at IS NOT NULL AND used_at < ?1) OR (revoked_at IS NOT NULL AND revoked_at < ?1)",
  ).bind(iso(DAY)).run();
  // OAuth access tokens (1 h) are agent_tokens rows; keep them as long as
  // the audit rows that name them, then drop them.
  await env.DB.prepare("DELETE FROM agent_tokens WHERE oauth_client_id IS NOT NULL AND expires_at < ?")
    .bind(iso(AGENT_AUDIT_RETENTION_DAYS * DAY)).run();
  // Revoked grants with nothing left under them.
  await env.DB.prepare(
    `DELETE FROM oauth_grants WHERE revoked_at IS NOT NULL AND revoked_at < ?
       AND NOT EXISTS (SELECT 1 FROM agent_tokens t WHERE t.oauth_grant_id = oauth_grants.id)`,
  ).bind(iso(DAY)).run();
  // Registered clients nobody ever finished signing in with.
  await env.DB.prepare(
    `DELETE FROM oauth_clients WHERE kind = 'dcr' AND last_used_at IS NULL AND created_at < ?
       AND NOT EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id = oauth_clients.client_id)`,
  ).bind(iso(30 * DAY)).run();
  await env.DB.prepare("DELETE FROM webhook_deliveries WHERE created_at < ? AND status != 'pending'")
    .bind(iso(WEBHOOK_DELIVERY_RETENTION_DAYS * DAY)).run();
}

// Two cron triggers (wrangler.toml): the five-minute one drives the webhook
// outbox's retries; the hourly one ("17 * * * *") runs the sweep. Not
// exported: a Worker entry module's named exports are its entrypoints.
const WEBHOOK_CRON = "*/5 * * * *";

export default {
  fetch: app.fetch,
  async scheduled(event: ScheduledController, env: Env, ctx: ExecutionContext) {
    if (event.cron === WEBHOOK_CRON) {
      ctx.waitUntil(
        processWebhookOutbox(env).then(
          (r) => r.attempted > 0 && console.log(`webhooks: ${r.delivered}/${r.attempted} delivered`),
          (err) => console.error("webhook outbox failed", err),
        ),
      );
      return;
    }
    ctx.waitUntil(sweep(env));
  },
};

// Durable Object classes must be exported from the Worker entrypoint.
export { ShareJobsDO } from "./share-jobs";
