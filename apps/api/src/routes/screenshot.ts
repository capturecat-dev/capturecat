/**
 * /api/screenshot — the gated screenshot-rendering API (screenshotone-style).
 *
 *   GET|POST /screenshot/take     render a URL (query params or JSON body)
 *   POST     /screenshot/keys     mint an access key   (session auth only)
 *   GET      /screenshot/keys     list keys, hashes redacted (session only)
 *   DELETE   /screenshot/keys/:id revoke a key         (session auth only)
 *
 * AUTH — two doors into /take, one identity out:
 *   • a Better Auth session (the app / dashboard), via requireAuth's logic; or
 *   • an access key (`access_key` param or `X-Access-Key` header) minted by
 *     /screenshot/keys — stored hashed, verified constant-time (lib/screenshot/keys.ts).
 * Key management is session-ONLY on purpose: a leaked key must not be able to
 * mint or revoke keys.
 *
 * GATING forks on the door used:
 *   • API KEY: the plan row's `screenshotApi` feature (403 upgrade_required)
 *     → `maxScreenshotsPerMonth` consumed atomically in D1 (429 quota_exceeded).
 *   • SESSION (the signed-in app / dashboard): allowed on EVERY plan — the
 *     desktop app's URL capture renders here now and was free when it was
 *     local WKWebView — metered per UTC DAY via sessionDailyScreenshotCap.
 * The per-IP Cache API rate limit is registered in index.ts like every other
 * route family.
 *
 * ERRORS are screenshotone-shaped: { error: { code, message } }.
 */

import { Hono, type Context } from "hono";
import type { Env, Variables } from "../types";
import { getAuth } from "../lib/auth";
import { resolveTier } from "../lib/entitlement";
import { planForTier } from "../lib/plans";
import { createPresignedDownloadUrl } from "../lib/presign";
import {
  parseScreenshotParams,
  screenshotGate,
  sessionDailyScreenshotCap,
  type RawParams,
} from "../lib/screenshot/params";
import { mintKey, parseKeyToken, verifySecret } from "../lib/screenshot/keys";
import { consumeQuota } from "../lib/screenshot/quota";
import { RestRenderer, cacheKey, CONTENT_TYPES } from "../lib/screenshot/renderer";

export const screenshotRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

type ErrBody = { error: { code: string; message: string } };
const errBody = (code: string, message: string): ErrBody => ({ error: { code, message } });

interface Caller {
  uid: string;
  claims: { tester: boolean; blocked: boolean };
  /** How the caller authenticated — the gate + quota policy fork on this
   *  (see sessionDailyScreenshotCap in lib/screenshot/params.ts). */
  via: "session" | "key";
}

/** Session OR access key → a caller identity, else null. Never throws. */
async function resolveCaller(
  c: { env: Env; req: { raw: Request; query: (k: string) => string | undefined; header: (k: string) => string | undefined } },
  bodyKey: string | null,
): Promise<Caller | null> {
  // 1. Access key — checked FIRST so an API client that also happens to carry
  //    a stale cookie gets deterministic key semantics.
  const token = c.req.header("X-Access-Key") ?? c.req.query("access_key") ?? bodyKey ?? null;
  if (token) {
    const parsed = parseKeyToken(token);
    if (!parsed) return null;
    const row = await c.env.DB
      .prepare(
        `SELECT k.user_id, k.key_hash, u.tester, u.blocked
         FROM screenshot_api_keys k JOIN "user" u ON u.id = k.user_id
         WHERE k.id = ?1 AND k.revoked_at IS NULL`,
      )
      .bind(parsed.id)
      .first<{ user_id: string; key_hash: string; tester: number | null; blocked: number | null }>();
    if (!row) return null;
    if (!(await verifySecret(parsed.secret, row.key_hash))) return null;
    return {
      uid: row.user_id,
      claims: { tester: row.tester === 1, blocked: row.blocked === 1 },
      via: "key",
    };
  }

  // 2. Better Auth session — same lookup requireAuth performs. (The CSRF
  //    origin check requireAuth adds for cookie writes is not needed here: a
  //    cross-site GET that renders a screenshot the attacker cannot read is
  //    inert, and the response is an image, not a state change.)
  try {
    const session = await getAuth(c.env).api.getSession({ headers: c.req.raw.headers });
    if (!session) return null;
    return {
      uid: session.user.id,
      claims: {
        tester: session.user.tester === true,
        blocked: session.user.blocked === true,
      },
      via: "session",
    };
  } catch (e) {
    console.error("screenshot: session lookup failed", e instanceof Error ? e.message : e);
    return null;
  }
}

async function handleTake(
  c: Context<{ Bindings: Env; Variables: Variables }>,
  raw: RawParams,
) {
  const caller = await resolveCaller(c, typeof raw.access_key === "string" ? raw.access_key : null);
  if (!caller) {
    return c.json(errBody("unauthorized", "A valid session or access key is required."), 401);
  }

  // Tier + plan (features AND limits in one lookup).
  const tier = await resolveTier(c.env.DB, caller.uid, caller.claims);
  if (tier === "blocked") {
    return c.json(errBody("account_blocked", "This account is blocked."), 403);
  }
  const plan = await planForTier(c.env.DB, tier);
  // POLICY (2026-08-10): the screenshotApi feature gate applies to API-KEY
  // callers only. A session (the signed-in app / dashboard) renders on every
  // plan — URL capture was a free local feature before it moved to Chromium
  // and must not silently become pro-only — but on a per-day allowance
  // instead of the plan's monthly quota. Full rationale next to
  // sessionDailyScreenshotCap in lib/screenshot/params.ts.
  if (caller.via === "key") {
    const gate = screenshotGate({ tier, features: plan.features });
    if (!gate.ok) {
      return c.json({ error: gate.error }, gate.status);
    }
  }

  // `engine` — chromium is the only implemented engine. A "kitesurf" beta
  // engine was floated but does not exist in Cloudflare's current REST docs;
  // refuse unknown values loudly rather than silently rendering on chromium.
  const engine = typeof raw.engine === "string" && raw.engine.trim() !== "" ? raw.engine.trim() : "chromium";
  if (engine !== "chromium") {
    return c.json(
      errBody("engine_unavailable", `Unknown engine "${engine}". Supported: chromium.`),
      400,
    );
  }

  const parsed = parseScreenshotParams(raw, c.env.SCREENSHOT_URL_BLOCKLIST);
  if (!parsed.ok) {
    return c.json({ error: parsed.error }, 400);
  }
  const params = parsed.params;

  if (!c.env.CF_ACCOUNT_ID || !c.env.BROWSER_RENDERING_TOKEN) {
    return c.json(errBody("not_configured", "Screenshot rendering is not configured."), 503);
  }

  // Quota BEFORE rendering: refused requests consume nothing, and the SQL's
  // conditional upsert means a race can never spend the last unit twice.
  // Sessions meter per UTC day (separate 8-digit counter key in the same
  // table); keys keep the plan's monthly cap.
  const cap = caller.via === "session" ? sessionDailyScreenshotCap(tier) : plan.limits.maxScreenshotsPerMonth;
  const period = caller.via === "session" ? ("day" as const) : ("month" as const);
  const quota = await consumeQuota(c.env.DB, caller.uid, cap, new Date(), period).catch(
    (e) => {
      // Fail closed — a broken meter must not become unmetered renders.
      console.error("screenshot: quota check failed", e instanceof Error ? e.message : e);
      return { allowed: false, used: 0, cap };
    },
  );
  c.header("X-Screenshot-Quota-Limit", String(quota.cap));
  c.header("X-Screenshot-Quota-Remaining", String(Math.max(0, quota.cap - quota.used)));
  if (!quota.allowed) {
    return c.json(
      errBody(
        "quota_exceeded",
        period === "day"
          ? `Daily web-capture allowance (${quota.cap}) exhausted. It resets at midnight UTC.`
          : `Monthly screenshot quota (${quota.cap}) exhausted.`,
      ),
      429,
    );
  }

  const renderer = new RestRenderer(c.env.CF_ACCOUNT_ID, c.env.BROWSER_RENDERING_TOKEN);
  const result = await renderer.render(params);
  if ("error" in result) {
    return c.json({ error: { code: result.error.code, message: result.error.message } }, result.error.status);
  }

  if (params.store) {
    // Persist under a deterministic options-hash key (repeat call = overwrite,
    // not accretion) and answer JSON with a presigned URL — the same S3-API
    // serving convention upload.ts uses, so no new public route exists.
    const hash = await cacheKey(params);
    const key = `screenshots/${caller.uid}/${hash}.${params.format}`;
    await c.env.R2.put(key, result.bytes, {
      httpMetadata: { contentType: CONTENT_TYPES[params.format] },
    });
    const url = await createPresignedDownloadUrl({
      r2Endpoint: c.env.R2_ENDPOINT,
      accessKeyId: c.env.R2_ACCESS_KEY_ID,
      secretAccessKey: c.env.R2_SECRET_ACCESS_KEY,
      bucket: "capturecat",
      key,
      expiresIn: 3600,
    });
    return c.json({ cache_key: hash, key, url, expires_in: 3600, format: params.format });
  }

  return c.body(result.bytes, 200, {
    "Content-Type": result.contentType,
    "Cache-Control": "no-store",
  });
}

screenshotRoutes.get("/screenshot/take", async (c) => {
  const raw: RawParams = {};
  for (const [k, v] of new URL(c.req.url).searchParams) raw[k] = v;
  return handleTake(c, raw);
});

screenshotRoutes.post("/screenshot/take", async (c) => {
  let raw: RawParams;
  try {
    raw = await c.req.json<RawParams>();
  } catch {
    return c.json(errBody("invalid_request", "Body must be JSON."), 400);
  }
  if (typeof raw !== "object" || raw === null) {
    return c.json(errBody("invalid_request", "Body must be a JSON object."), 400);
  }
  return handleTake(c, raw);
});

// ---------------------------------------------------------------------------
// Key management — SESSION auth only (a leaked key must not manage keys).
// ---------------------------------------------------------------------------

async function requireSession(c: { env: Env; req: { raw: Request } }): Promise<Caller | null> {
  try {
    const session = await getAuth(c.env).api.getSession({ headers: c.req.raw.headers });
    if (!session) return null;
    return {
      uid: session.user.id,
      claims: {
        tester: session.user.tester === true,
        blocked: session.user.blocked === true,
      },
      via: "session",
    };
  } catch {
    return null;
  }
}

const MAX_ACTIVE_KEYS = 5;

screenshotRoutes.post("/screenshot/keys", async (c) => {
  const caller = await requireSession(c);
  if (!caller) return c.json(errBody("unauthorized", "Sign in to manage access keys."), 401);
  if (caller.claims.blocked) return c.json(errBody("account_blocked", "This account is blocked."), 403);

  // Only entitled users can mint — a free user's key would 403 on every /take
  // anyway, but refusing here keeps the failure at the obvious place.
  const tier = await resolveTier(c.env.DB, caller.uid, caller.claims);
  if (tier === "blocked") return c.json(errBody("account_blocked", "This account is blocked."), 403);
  const plan = await planForTier(c.env.DB, tier);
  const gate = screenshotGate({ tier, features: plan.features });
  if (!gate.ok) return c.json({ error: gate.error }, gate.status);

  const active = await c.env.DB
    .prepare(`SELECT COUNT(*) AS n FROM screenshot_api_keys WHERE user_id = ?1 AND revoked_at IS NULL`)
    .bind(caller.uid)
    .first<{ n: number }>();
  if ((active?.n ?? 0) >= MAX_ACTIVE_KEYS) {
    return c.json(errBody("too_many_keys", `At most ${MAX_ACTIVE_KEYS} active keys. Revoke one first.`), 400);
  }

  let label: string | null = null;
  try {
    const body = await c.req.json<{ label?: unknown }>();
    if (typeof body.label === "string" && body.label.trim()) label = body.label.trim().slice(0, 60);
  } catch {
    // Empty body is fine — label is optional.
  }

  const minted = await mintKey();
  await c.env.DB
    .prepare(
      `INSERT INTO screenshot_api_keys (id, user_id, key_hash, label, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5)`,
    )
    .bind(minted.id, caller.uid, minted.keyHash, label, new Date().toISOString())
    .run();

  // The plaintext token appears in this response and NOWHERE else.
  return c.json({ id: minted.id, key: minted.token, label });
});

screenshotRoutes.get("/screenshot/keys", async (c) => {
  const caller = await requireSession(c);
  if (!caller) return c.json(errBody("unauthorized", "Sign in to manage access keys."), 401);
  const { results } = await c.env.DB
    .prepare(
      `SELECT id, label, created_at, revoked_at FROM screenshot_api_keys
       WHERE user_id = ?1 ORDER BY created_at DESC`,
    )
    .bind(caller.uid)
    .all<{ id: string; label: string | null; created_at: string; revoked_at: string | null }>();
  return c.json({
    keys: (results ?? []).map((r) => ({
      id: r.id,
      label: r.label,
      createdAt: r.created_at,
      revokedAt: r.revoked_at,
    })),
  });
});

screenshotRoutes.delete("/screenshot/keys/:id", async (c) => {
  const caller = await requireSession(c);
  if (!caller) return c.json(errBody("unauthorized", "Sign in to manage access keys."), 401);
  const id = c.req.param("id");
  const result = await c.env.DB
    .prepare(
      `UPDATE screenshot_api_keys SET revoked_at = ?1
       WHERE id = ?2 AND user_id = ?3 AND revoked_at IS NULL`,
    )
    .bind(new Date().toISOString(), id, caller.uid)
    .run();
  if ((result.meta?.changes ?? 0) === 0) {
    return c.json(errBody("not_found", "No active key with that id."), 404);
  }
  return c.json({ id, revoked: true });
});
