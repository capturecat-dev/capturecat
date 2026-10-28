/**
 * /api/screenshot — the gated screenshot-rendering API (a URL-to-image API).
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
 * GATING is by plan row on BOTH doors (lib/screenshot/params.ts screenshotGate):
 *   • API KEY: `screenshotApi` (403 upgrade_required).
 *   • SESSION (the signed-in app / dashboard): `webCapture`.
 *   Both consume `maxScreenshotsPerMonth` atomically in D1 (429 quota_exceeded).
 *   `store=true` additionally needs `imageUpload`, is checked against the
 *   storage cap with the rendered byte count, and is recorded in
 *   stored_objects so it counts like every other byte the user keeps.
 * The per-IP Cache API rate limit is registered in index.ts like every other
 * route family.
 *
 * ERRORS are shaped { error: { code, message } }.
 */

import { Hono, type Context } from "hono";
import type { Env, Variables } from "../types";
import { webOrigins } from "../lib/origins";
import { getAuth } from "../lib/auth";
import { resolveEntitlement } from "../lib/entitlement";
import { planForEntitlement } from "../lib/plans";
import { deleteStoredObject, listStoredObjects } from "../lib/db";
import { screenshotGate, type RawParams } from "../lib/screenshot/params";
import { mintKey, parseKeyToken, verifySecret } from "../lib/screenshot/keys";
import { takeScreenshot } from "../lib/screenshot/take";

export const screenshotRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

type ErrBody = { error: { code: string; message: string } };
const errBody = (code: string, message: string): ErrBody => ({ error: { code, message } });

interface Caller {
  uid: string;
  claims: { tester: boolean; blocked: boolean };
  /** How the caller authenticated — decides WHICH plan flag opens the door
   *  (see screenshotGate in lib/screenshot/params.ts). */
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
  // A cookie session can be ridden cross-site (top-level navigation carries a
  // SameSite=Lax cookie): the render is billed, quota is consumed, and
  // store=true writes to R2 under the victim. Session callers must POST from
  // an allowed web origin; GET stays for API-key clients only.
  if (caller.via === "session") {
    const origin = c.req.header("Origin");
    if (c.req.method !== "POST" || !origin || !webOrigins(c.env).includes(origin)) {
      return c.json(
        errBody("forbidden", "Session-authenticated calls must be POSTed from the CaptureCat web app; use an access key for API clients."),
        403,
      );
    }
  }

  // Gate, params, quota, render, store: lib/screenshot/take.ts, shared with
  // the MCP take_screenshot tool so an agent token meets the same rules.
  const out = await takeScreenshot(c.env, { uid: caller.uid, claims: caller.claims, door: caller.via }, raw);
  if (out.quota) {
    c.header("X-Screenshot-Quota-Limit", String(out.quota.cap));
    c.header("X-Screenshot-Quota-Remaining", String(Math.max(0, out.quota.cap - out.quota.used)));
  }
  if (!out.ok) return c.json({ error: out.error }, out.status);
  if (out.kind === "stored") return c.json(out.stored);

  return c.body(out.bytes, 200, {
    "Content-Type": out.contentType,
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
  const ent = await resolveEntitlement(c.env.DB, caller.uid, caller.claims);
  if (ent === "blocked") return c.json(errBody("account_blocked", "This account is blocked."), 403);
  const plan = await planForEntitlement(c.env.DB, ent);
  const gate = screenshotGate({ tier: ent.tier, features: plan.features, door: "key" });
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

/**
 * Stored screenshots (store=true) — session only, so a user can see what is
 * counting against their storage and free it.
 */
screenshotRoutes.get("/screenshot/stored", async (c) => {
  const caller = await requireSession(c);
  if (!caller) return c.json(errBody("unauthorized", "Sign in to list stored screenshots."), 401);
  const objects = await listStoredObjects(c.env.DB, caller.uid, "screenshot");
  return c.json({
    objects: objects.map((o) => ({
      key: o.r2Key,
      bytes: o.bytes,
      createdAt: o.createdAt,
    })),
  });
});

screenshotRoutes.delete("/screenshot/stored/:hash", async (c) => {
  const caller = await requireSession(c);
  if (!caller) return c.json(errBody("unauthorized", "Sign in to delete stored screenshots."), 401);
  const hash = c.req.param("hash");
  if (!/^[A-Za-z0-9._-]{1,120}$/.test(hash)) return c.json(errBody("bad_request", "Invalid key."), 400);
  // Keys are always screenshots/{uid}/{hash}.{fmt}; the uid in the key is
  // the caller's, so a user can never address another user's object.
  const key = `screenshots/${caller.uid}/${hash}`;
  const owned = await deleteStoredObject(c.env.DB, caller.uid, key);
  if (!owned) return c.json(errBody("not_found", "No such stored screenshot."), 404);
  await c.env.R2.delete(key).catch(() => {});
  return c.json({ ok: true, key });
});
