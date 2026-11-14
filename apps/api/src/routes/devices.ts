/**
 * "iPhone over Wi-Fi": the account's native devices and the link key they
 * share (migration 0042). Wire contract for the clients:
 * apps/macos/CaptureCat/Shared/WirelessDeviceProtocol.swift.
 *
 *   GET    /api/wireless/link                      → { key, keyId, createdAt }
 *   POST   /api/wireless/link/rotate               → same shape, fresh key ("Forget my devices")
 *   PUT    /api/devices/:deviceId                  → register / refresh this device → public device
 *   GET    /api/devices                            → { devices: [public device] }
 *   DELETE /api/devices/:deviceId                  → { deleted: true } (the app's sign-out)
 *   POST   /api/devices/:deviceId/request-broadcast → { sent: true } (APNs alert to that phone)
 *
 * NATIVE APPS ONLY: every route is requireBearer → refuseAgentCredentials →
 * requireAuth. A browser cookie session never reaches them (an XSS on a web
 * origin must not be able to read the link key), and neither does an agent
 * token. Not plan-gated: Free accounts get it too. APNs device tokens are
 * write-only — no response ever contains one.
 */

import { Hono, type Context } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireBearer } from "../middleware/bearer-only";
import { refuseAgentCredentials } from "../middleware/session-only";
import { userRateLimit } from "../lib/entitlement";
import {
  WirelessUnavailableError,
  getOrCreateWirelessLink,
  rotateWirelessLink,
  type WirelessLink,
} from "../lib/wireless-link";
import { apnsConfig, sendApnsAlert, type ApnsEnvironment } from "../lib/apns";
import { cleanLabel } from "../lib/comments";

export const devicesRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/** The newest this many devices per account are kept; older ones are pruned. */
export const MAX_DEVICES_PER_USER = 50;
const DEVICE_NAME_MAX = 100;
const MAC_NAME_MAX = 60;
/** A broadcast request is only worth delivering while the Mac still waits. */
const BROADCAST_REQUEST_TTL_SEC = 120;

const PLATFORMS = new Set(["ios", "mac"]);
const APNS_ENVIRONMENTS = new Set(["sandbox", "production"]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const APNS_TOKEN_RE = /^[0-9a-f]{64,200}$/i;
/** e.g. "iPhone18,1", "Mac16,10", "iPad16,3". */
const MODEL_RE = /^[A-Za-z0-9][A-Za-z0-9 ,._()-]{0,63}$/;
/** e.g. "26.1", "1.0 (12)". Printable ASCII. */
const VERSION_RE = /^[\x20-\x7E]{1,32}$/;
/** The Mac's id as its Bonjour TXT carries it (`id=`, lowercase). */
const MAC_ID_RE = /^[a-z0-9][a-z0-9._:-]{0,63}$/;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function invalid(message: string) {
  return { error: message, code: "invalid_request" } as const;
}

/**
 * User-visible text for a notification or a list row: lib/comments.ts's
 * cleanLabel (no C0/C1 controls — newlines included — no bidi
 * overrides/isolates that could reorder the surrounding text, whitespace
 * collapsed), then at most `max` characters. Empty → null.
 */
export function cleanDisplayText(value: string, max: number): string | null {
  const clipped = Array.from(cleanLabel(value)).slice(0, max).join("").trim();
  return clipped === "" ? null : clipped;
}

function parseDeviceId(raw: string): string | null {
  return UUID_RE.test(raw) ? raw.toLowerCase() : null;
}

async function jsonObject(c: { req: { json: () => Promise<unknown> } }): Promise<Record<string, unknown> | null> {
  try {
    const body = await c.req.json();
    return body !== null && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** undefined / null / "" → null; otherwise must match `re`. */
function optionalText(value: unknown, re: RegExp): { ok: true; value: string | null } | { ok: false } {
  if (value === undefined || value === null) return { ok: true, value: null };
  if (typeof value !== "string") return { ok: false };
  const trimmed = value.trim();
  if (trimmed === "") return { ok: true, value: null };
  return re.test(trimmed) ? { ok: true, value: trimmed } : { ok: false };
}

interface DeviceRow {
  device_id: string;
  platform: string;
  name: string;
  model: string | null;
  system_version: string | null;
  app_version: string | null;
  apns_token: string | null;
  apns_env: string | null;
  last_seen_at: string;
}

const DEVICE_COLUMNS = `device_id, platform, name, model, system_version, app_version, apns_token, apns_env, last_seen_at`;

/** The only device shape any response carries — never the APNs token. */
function publicDevice(row: DeviceRow, pushConfigured: boolean) {
  return {
    deviceId: row.device_id,
    platform: row.platform,
    name: row.name,
    model: row.model,
    systemVersion: row.system_version,
    appVersion: row.app_version,
    canPush: pushConfigured && row.platform === "ios" && row.apns_token !== null && row.apns_env !== null,
    lastSeenAt: row.last_seen_at,
  };
}

function linkResponse(c: Context<{ Bindings: Env; Variables: Variables }>, link: WirelessLink) {
  // A secret: never let an intermediary or the client's URL cache keep it.
  c.header("Cache-Control", "no-store");
  return c.json({ key: link.key, keyId: link.keyId, createdAt: link.createdAt });
}

const WIRELESS_UNAVAILABLE = {
  error: "Wireless device linking isn't available on this server.",
  code: "wireless_unavailable",
} as const;

// ---------------------------------------------------------------------------
// The account's link key
// ---------------------------------------------------------------------------

devicesRoutes.get(
  "/wireless/link",
  requireBearer,
  refuseAgentCredentials,
  requireAuth,
  userRateLimit({ limit: 30, windowSec: 60, scope: "wireless" }),
  async (c) => {
    try {
      return linkResponse(c, await getOrCreateWirelessLink(c.env, c.get("user").uid));
    } catch (err) {
      if (err instanceof WirelessUnavailableError) return c.json(WIRELESS_UNAVAILABLE, 503);
      throw err;
    }
  },
);

devicesRoutes.post(
  "/wireless/link/rotate",
  requireBearer,
  refuseAgentCredentials,
  requireAuth,
  userRateLimit({ limit: 30, windowSec: 60, scope: "wireless" }),
  async (c) => {
    try {
      return linkResponse(c, await rotateWirelessLink(c.env, c.get("user").uid));
    } catch (err) {
      if (err instanceof WirelessUnavailableError) return c.json(WIRELESS_UNAVAILABLE, 503);
      throw err;
    }
  },
);

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

/**
 * Register or refresh the calling device (every app launch / sign-in).
 * Body: { platform: "ios"|"mac", name, model?, systemVersion?, appVersion?,
 *         apnsToken?, apnsEnvironment? }
 * `apnsToken` absent = keep the stored one; null = forget it; a hex string =
 * replace it (then `apnsEnvironment` is required). A token is held by one
 * device row at a time: registering it here clears it anywhere else.
 */
devicesRoutes.put(
  "/devices/:deviceId",
  requireBearer,
  refuseAgentCredentials,
  requireAuth,
  userRateLimit({ limit: 30, windowSec: 60, scope: "devices" }),
  async (c) => {
    const uid = c.get("user").uid;
    const deviceId = parseDeviceId(c.req.param("deviceId"));
    if (!deviceId) return c.json(invalid("deviceId must be a UUID."), 400);
    const body = await jsonObject(c);
    if (!body) return c.json(invalid("Send a JSON object."), 400);

    const platform = body.platform;
    if (typeof platform !== "string" || !PLATFORMS.has(platform)) {
      return c.json(invalid('platform must be "ios" or "mac".'), 400);
    }
    const name = typeof body.name === "string" ? cleanDisplayText(body.name, DEVICE_NAME_MAX) : null;
    if (!name) return c.json(invalid("name is required."), 400);
    const model = optionalText(body.model, MODEL_RE);
    if (!model.ok) return c.json(invalid("model is malformed."), 400);
    const systemVersion = optionalText(body.systemVersion, VERSION_RE);
    if (!systemVersion.ok) return c.json(invalid("systemVersion is malformed."), 400);
    const appVersion = optionalText(body.appVersion, VERSION_RE);
    if (!appVersion.ok) return c.json(invalid("appVersion is malformed."), 400);

    // APNs: undefined = keep, null = clear, string = set.
    let apnsChange: { token: string; env: ApnsEnvironment } | null | undefined;
    if (body.apnsToken === undefined) {
      apnsChange = undefined;
    } else if (body.apnsToken === null) {
      apnsChange = null;
    } else {
      if (typeof body.apnsToken !== "string" || !APNS_TOKEN_RE.test(body.apnsToken)) {
        return c.json(invalid("apnsToken must be 64-200 hex characters."), 400);
      }
      if (platform !== "ios") return c.json(invalid("apnsToken is only accepted from iOS devices."), 400);
      if (typeof body.apnsEnvironment !== "string" || !APNS_ENVIRONMENTS.has(body.apnsEnvironment)) {
        return c.json(invalid('apnsEnvironment must be "sandbox" or "production".'), 400);
      }
      apnsChange = { token: body.apnsToken.toLowerCase(), env: body.apnsEnvironment as ApnsEnvironment };
    }

    const now = new Date().toISOString();
    const db = c.env.DB;
    const statements: D1PreparedStatement[] = [];
    if (apnsChange) {
      statements.push(
        db
          .prepare(
            `UPDATE user_devices SET apns_token = NULL, apns_env = NULL, updated_at = ?1
              WHERE apns_token = ?2 AND NOT (user_id = ?3 AND device_id = ?4)`,
          )
          .bind(now, apnsChange.token, uid, deviceId),
      );
    }
    statements.push(
      db
        .prepare(
          `INSERT INTO user_devices
             (user_id, device_id, platform, name, model, system_version, app_version,
              apns_token, apns_env, created_at, updated_at, last_seen_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?10)
           ON CONFLICT(user_id, device_id) DO UPDATE SET
             platform = excluded.platform,
             name = excluded.name,
             model = excluded.model,
             system_version = excluded.system_version,
             app_version = excluded.app_version,
             apns_token = CASE WHEN ?11 = 1 THEN excluded.apns_token ELSE user_devices.apns_token END,
             apns_env = CASE WHEN ?11 = 1 THEN excluded.apns_env ELSE user_devices.apns_env END,
             updated_at = excluded.updated_at,
             last_seen_at = excluded.last_seen_at`,
        )
        .bind(
          uid,
          deviceId,
          platform,
          name,
          model.value,
          systemVersion.value,
          appVersion.value,
          apnsChange ? apnsChange.token : null,
          apnsChange ? apnsChange.env : null,
          now,
          apnsChange === undefined ? 0 : 1,
        ),
    );
    statements.push(
      db
        .prepare(
          `DELETE FROM user_devices
            WHERE user_id = ?1 AND device_id NOT IN (
              SELECT device_id FROM user_devices WHERE user_id = ?1
               ORDER BY last_seen_at DESC, device_id LIMIT ?2)`,
        )
        .bind(uid, MAX_DEVICES_PER_USER),
    );
    await db.batch(statements);

    const row = await db
      .prepare(`SELECT ${DEVICE_COLUMNS} FROM user_devices WHERE user_id = ? AND device_id = ?`)
      .bind(uid, deviceId)
      .first<DeviceRow>();
    if (!row) return c.json({ error: "Could not save this device.", code: "server_error" }, 500);
    return c.json(publicDevice(row, apnsConfig(c.env) !== null));
  },
);

devicesRoutes.get(
  "/devices",
  requireBearer,
  refuseAgentCredentials,
  requireAuth,
  userRateLimit({ limit: 30, windowSec: 60, scope: "devices" }),
  async (c) => {
    const { results } = await c.env.DB.prepare(
      `SELECT ${DEVICE_COLUMNS} FROM user_devices WHERE user_id = ? ORDER BY last_seen_at DESC, device_id`,
    )
      .bind(c.get("user").uid)
      .all<DeviceRow>();
    const pushConfigured = apnsConfig(c.env) !== null;
    return c.json({ devices: (results ?? []).map((row) => publicDevice(row, pushConfigured)) });
  },
);

devicesRoutes.delete(
  "/devices/:deviceId",
  requireBearer,
  refuseAgentCredentials,
  requireAuth,
  userRateLimit({ limit: 30, windowSec: 60, scope: "devices" }),
  async (c) => {
    const deviceId = parseDeviceId(c.req.param("deviceId"));
    if (!deviceId) return c.json(invalid("deviceId must be a UUID."), 400);
    const res = await c.env.DB.prepare(`DELETE FROM user_devices WHERE user_id = ? AND device_id = ?`)
      .bind(c.get("user").uid, deviceId)
      .run();
    if (!res.meta.changes) return c.json({ error: "No such device.", code: "not_found" }, 404);
    return c.json({ deleted: true });
  },
);

// ---------------------------------------------------------------------------
// Ask a phone to start streaming
// ---------------------------------------------------------------------------

/**
 * Body: { macId, macName }. Sends the phone (which must be the caller's) a
 * time-sensitive alert; tapping it opens the app on the Start Broadcast sheet
 * for that Mac. iOS requires that tap — there is no silent start.
 *
 *   200 { sent: true }
 *   404 not_found            not one of the caller's devices
 *   503 push_not_configured  the APNs secrets are not set on this server
 *   409 push_unavailable     no APNs token (or APNs says it is dead — then it
 *                            is forgotten): open the app on the phone instead
 *   502 push_failed          transport/APNs trouble; retryable
 */
devicesRoutes.post(
  "/devices/:deviceId/request-broadcast",
  requireBearer,
  refuseAgentCredentials,
  requireAuth,
  userRateLimit({ limit: 10, windowSec: 60, scope: "device-push" }),
  async (c) => {
    const uid = c.get("user").uid;
    const deviceId = parseDeviceId(c.req.param("deviceId"));
    if (!deviceId) return c.json(invalid("deviceId must be a UUID."), 400);
    const body = await jsonObject(c);
    if (!body) return c.json(invalid("Send a JSON object."), 400);
    const macId = typeof body.macId === "string" ? body.macId.trim().toLowerCase() : "";
    if (!MAC_ID_RE.test(macId)) return c.json(invalid("macId is malformed."), 400);
    const macName = typeof body.macName === "string" ? cleanDisplayText(body.macName, MAC_NAME_MAX) : null;
    if (!macName) return c.json(invalid("macName is required."), 400);

    const row = await c.env.DB.prepare(`SELECT ${DEVICE_COLUMNS} FROM user_devices WHERE user_id = ? AND device_id = ?`)
      .bind(uid, deviceId)
      .first<DeviceRow>();
    if (!row) return c.json({ error: "No such device.", code: "not_found" }, 404);

    const config = apnsConfig(c.env);
    if (!config) {
      return c.json({ error: "Notifications aren't set up on this server.", code: "push_not_configured" }, 503);
    }
    const pushUnavailable = {
      error: "This device can't be woken up. Open CaptureCat on it instead.",
      code: "push_unavailable",
    } as const;
    if (row.platform !== "ios" || !row.apns_token || (row.apns_env !== "sandbox" && row.apns_env !== "production")) {
      return c.json(pushUnavailable, 409);
    }

    const result = await sendApnsAlert(config, {
      deviceToken: row.apns_token,
      environment: row.apns_env,
      pushType: "alert",
      priority: 10,
      expiration: Math.floor(Date.now() / 1000) + BROADCAST_REQUEST_TTL_SEC,
      collapseId: "broadcast-request",
      payload: {
        aps: {
          alert: {
            title: `Stream to ${macName}`,
            body: `Tap to share your screen with CaptureCat on ${macName}.`,
          },
          category: "CC_BROADCAST_REQUEST",
          "interruption-level": "time-sensitive",
        },
        cc: { type: "requestBroadcast", macId, macName },
      },
    });

    if (result.ok) return c.json({ sent: true });
    if (result.kind === "dead_token") {
      // Only the token we just used: a fresh registration that raced this
      // push must survive.
      await c.env.DB.prepare(
        `UPDATE user_devices SET apns_token = NULL, apns_env = NULL, updated_at = ?1
          WHERE user_id = ?2 AND device_id = ?3 AND apns_token = ?4`,
      )
        .bind(new Date().toISOString(), uid, deviceId, row.apns_token)
        .run();
      return c.json(pushUnavailable, 409);
    }
    return c.json({ error: "The notification couldn't be sent. Try again.", code: "push_failed" }, 502);
  },
);
