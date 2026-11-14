/**
 * Apple Push Notification service client (token-based auth, HTTP/2 JSON API).
 *
 * Used by POST /api/devices/:deviceId/request-broadcast (routes/devices.ts):
 * a Mac asks a phone whose CaptureCat app may be closed to start streaming.
 *
 * Auth is a provider token: an ES256 JWT (header `kid` = APNS_KEY_ID, claims
 * `iss` = APNS_TEAM_ID and `iat`) signed with WebCrypto from the .p8 key in
 * the APNS_KEY secret (PKCS#8, P-256). Apple throttles providers that mint a
 * fresh token per request (TooManyProviderTokenUpdates) and rejects tokens
 * older than an hour, so one token is cached in module scope and reused for
 * 50 minutes; a 403 Expired/InvalidProviderToken drops it early.
 *
 * Host per device token: api.push.apple.com for production builds,
 * api.sandbox.push.apple.com for development builds (the app reports which).
 *
 * TRANSPORT NOTE: APNs speaks HTTP/2 only. A deployed Worker's fetch
 * negotiates it; local workerd on macOS does not (cloudflare/workerd#4841), so
 * `wrangler dev` cannot deliver a push — tests mock fetch. A transport error
 * is therefore always "try again", never evidence that a token is dead.
 */

import type { Env } from "../types";

export const DEFAULT_APNS_TOPIC = "so.capturecat.ios";
export const APNS_PRODUCTION_HOST = "api.push.apple.com";
export const APNS_SANDBOX_HOST = "api.sandbox.push.apple.com";
export type ApnsEnvironment = "sandbox" | "production";

/** Provider tokens are reused this long (Apple: refresh after 20, before 60). */
const PROVIDER_TOKEN_TTL_MS = 50 * 60 * 1000;

export interface ApnsConfig {
  keyPem: string;
  keyId: string;
  teamId: string;
  topic: string;
}

/** The APNs settings, or null when any of the three secrets is missing. */
export function apnsConfig(env: Env): ApnsConfig | null {
  const keyPem = env.APNS_KEY?.trim();
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  if (!keyPem || !keyId || !teamId) return null;
  return { keyPem, keyId, teamId, topic: env.APNS_TOPIC?.trim() || DEFAULT_APNS_TOPIC };
}

// ---------------------------------------------------------------------------
// Provider token (ES256 JWT)
// ---------------------------------------------------------------------------

let providerTokenCache: { cacheKey: string; token: string; mintedAt: number } | null = null;

/** Test hook: forget the cached provider token. */
export function resetApnsProviderTokenCache(): void {
  providerTokenCache = null;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlJson(value: unknown): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

/** PKCS#8 DER bytes from the .p8 PEM. `wrangler secret put` keeps real
 *  newlines; .dev.vars tends to hold escaped `\n` — both are accepted. */
function pkcs8FromPem(pem: string): Uint8Array {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (ch) => ch.charCodeAt(0));
}

async function mintProviderToken(config: ApnsConfig, nowMs: number): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8FromPem(config.keyPem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signingInput = `${base64UrlJson({ alg: "ES256", kid: config.keyId })}.${base64UrlJson({
    iss: config.teamId,
    iat: Math.floor(nowMs / 1000),
  })}`;
  // WebCrypto's ECDSA signature is already the raw r‖s (64 bytes) JWS wants.
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput)),
  );
  return `${signingInput}.${base64Url(signature)}`;
}

/** The cached provider token, minted when absent, stale or for other keys. */
export async function apnsProviderToken(config: ApnsConfig, nowMs = Date.now()): Promise<string> {
  const cacheKey = `${config.teamId}:${config.keyId}:${config.keyPem}`;
  if (
    providerTokenCache &&
    providerTokenCache.cacheKey === cacheKey &&
    nowMs - providerTokenCache.mintedAt < PROVIDER_TOKEN_TTL_MS
  ) {
    return providerTokenCache.token;
  }
  const token = await mintProviderToken(config, nowMs);
  providerTokenCache = { cacheKey, token, mintedAt: nowMs };
  return token;
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

export interface ApnsAlert {
  deviceToken: string;
  environment: ApnsEnvironment;
  /** The JSON payload (`aps` + custom keys). */
  payload: Record<string, unknown>;
  pushType?: "alert" | "background";
  priority?: 5 | 10;
  /** Unix seconds; 0 = deliver once or drop. */
  expiration?: number;
  collapseId?: string;
}

export type ApnsResult =
  | { ok: true; apnsId: string | null }
  /** The token is dead for this app: forget it. */
  | { ok: false; kind: "dead_token"; status: number; reason: string | null }
  /** Anything else — transport, throttling, our own credentials. Retryable;
   *  the token is NOT to be forgotten. */
  | { ok: false; kind: "failed"; status: number | null; reason: string | null };

/** Reasons that mean "this token no longer reaches this app". 410 is always
 *  dead (reason Unregistered / ExpiredToken). */
const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered"]);
/** Reasons that mean our provider token must be re-minted. */
const PROVIDER_TOKEN_REASONS = new Set(["ExpiredProviderToken", "InvalidProviderToken"]);

export async function sendApnsAlert(config: ApnsConfig, alert: ApnsAlert): Promise<ApnsResult> {
  const host = alert.environment === "production" ? APNS_PRODUCTION_HOST : APNS_SANDBOX_HOST;
  let token: string;
  try {
    token = await apnsProviderToken(config);
  } catch (err) {
    // A malformed APNS_KEY: our configuration, not the device's problem.
    console.error("apns: could not sign a provider token", err instanceof Error ? err.message : err);
    return { ok: false, kind: "failed", status: null, reason: "ProviderTokenUnavailable" };
  }
  let response: Response;
  try {
    const headers: Record<string, string> = {
      authorization: `bearer ${token}`,
      "apns-topic": config.topic,
      "apns-push-type": alert.pushType ?? "alert",
      "apns-priority": String(alert.priority ?? 10),
      "content-type": "application/json",
    };
    if (alert.expiration !== undefined) headers["apns-expiration"] = String(alert.expiration);
    if (alert.collapseId) headers["apns-collapse-id"] = alert.collapseId;
    response = await fetch(`https://${host}/3/device/${alert.deviceToken}`, {
      method: "POST",
      headers,
      body: JSON.stringify(alert.payload),
    });
  } catch (err) {
    console.error("apns: transport error", err instanceof Error ? err.message : err);
    return { ok: false, kind: "failed", status: null, reason: null };
  }

  if (response.ok) return { ok: true, apnsId: response.headers.get("apns-id") };

  let reason: string | null = null;
  try {
    const body = (await response.json()) as { reason?: unknown };
    if (typeof body.reason === "string") reason = body.reason;
  } catch {
    // APNs always sends a JSON reason on errors; a proxy might not.
  }
  if (response.status === 410 || (reason !== null && DEAD_TOKEN_REASONS.has(reason))) {
    return { ok: false, kind: "dead_token", status: response.status, reason };
  }
  if (response.status === 403 && reason !== null && PROVIDER_TOKEN_REASONS.has(reason)) {
    providerTokenCache = null;
  }
  console.error("apns: push refused", { status: response.status, reason, host });
  return { ok: false, kind: "failed", status: response.status, reason };
}
