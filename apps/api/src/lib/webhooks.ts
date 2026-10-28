/**
 * Webhooks (migration 0036): signed POSTs to endpoints the account owner
 * registers, for what happens to their account — so an agent can react
 * instead of polling. Gated by the plan's `agentWebhooks` flag.
 *
 * WIRE FORMAT — Standard Webhooks (https://www.standardwebhooks.com):
 *
 *   POST <endpoint url>
 *   content-type:      application/json
 *   webhook-id:        msg_…            (the delivery id; stable across retries)
 *   webhook-timestamp: 1730000000       (unix seconds of THIS attempt)
 *   webhook-signature: v1,<base64(HMAC-SHA256(key, "<id>.<timestamp>.<body>"))>
 *
 *   body: {"type":"video.ready","timestamp":"…","data":{…}}
 *
 * The key is the base64 after `whsec_` in the endpoint's secret, which the
 * user sees once. Payloads stay minimal: ids, titles, URLs — never a viewer's
 * name, IP, country or referrer; text a viewer wrote is marked untrusted.
 *
 * DELIVERY — an outbox. An event writes one webhook_deliveries row per
 * subscribed endpoint and is attempted at once (ctx.waitUntil). A failure is
 * retried by the five-minute cron (index.ts → processWebhookOutbox) with exponential
 * backoff — 5 min, 20 min, 80 min, ~5 h, then 12 h — for MAX_DELIVERY_ATTEMPTS
 * in all (~31 h). An endpoint that keeps failing (DISABLE_AFTER_FAILURES in a
 * row, over at least a day) is switched off and says why in Settings.
 *
 * SSRF: endpoint URLs go through checkOutboundUrl (https, public DNS names
 * only, never an IP literal or our own zone) when saved AND before every
 * attempt; redirects are not followed; 10 s timeout.
 */

import type { Env, VideoMetadata } from "../types";
import { generateId } from "./id";
import { planForUser } from "./entitlement";
import { appBaseURL, shareBaseURL } from "./origins";
import { checkOutboundUrl } from "./outbound-url";

export const WEBHOOK_EVENTS = ["video.ready", "comment.created", "share.viewed", "project.saved", "upload.failed"] as const;
export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];
/** Sent only by "Send test" — never subscribable, never retried. */
export const WEBHOOK_TEST_EVENT = "webhook.test";

export const WEBHOOK_EVENT_INFO: Record<WebhookEvent, string> = {
  "video.ready": "A shared video (or a new version of one) finished uploading and its link plays.",
  "comment.created": "Someone commented on one of your videos (the text is untrusted).",
  "share.viewed": "A share link got a new viewer — at most once per video per 10 minutes.",
  "project.saved": "A cloud project was saved.",
  "upload.failed": "A share upload failed or was refused.",
};

export const MAX_WEBHOOK_ENDPOINTS = 10;
export const MAX_DELIVERY_ATTEMPTS = 7;
/** Consecutive failed attempts that switch an endpoint off… */
export const DISABLE_AFTER_FAILURES = 25;
/** …provided the streak has lasted at least this long (a short outage
 *  during a burst of events must not disable anything). */
export const DISABLE_AFTER_STREAK_MS = 24 * 3600_000;
export const SHARE_VIEWED_DEBOUNCE_SEC = 600;
export const WEBHOOK_TIMEOUT_MS = 10_000;
/** A claimed delivery is invisible to other senders this long. */
const CLAIM_LEASE_MS = 2 * 60_000;
const RETRY_BASE_MS = 5 * 60_000;
const RETRY_MAX_MS = 12 * 3600_000;
/** Deliveries are kept this long for the Settings history, then swept. */
export const WEBHOOK_DELIVERY_RETENTION_DAYS = 30;

const USER_AGENT = "CaptureCat-Webhooks/1.0 (+https://capturecat.so/docs/webhooks)";

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

// ---------------------------------------------------------------------------
// Secrets and signatures
// ---------------------------------------------------------------------------

/** `whsec_` + base64 of 32 random bytes. */
export function mintWebhookSecret(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `whsec_${bytesToBase64(bytes)}`;
}

/** AES-GCM key for secrets at rest, derived (HKDF-SHA-256) from
 *  BETTER_AUTH_SECRET — already "treat as permanent", so no new secret. */
async function atRestKey(env: Pick<Env, "BETTER_AUTH_SECRET">): Promise<CryptoKey> {
  if (!env.BETTER_AUTH_SECRET) throw new Error("BETTER_AUTH_SECRET is not set");
  const base = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.BETTER_AUTH_SECRET), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: new TextEncoder().encode("capturecat/webhooks"),
      info: new TextEncoder().encode("endpoint-secret/v1"),
    },
    base,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export async function encryptWebhookSecret(env: Pick<Env, "BETTER_AUTH_SECRET">, secret: string, aad: string): Promise<string> {
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const ct = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(aad) },
      await atRestKey(env),
      new TextEncoder().encode(secret),
    ),
  );
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv);
  out.set(ct, iv.length);
  return bytesToBase64(out);
}

export async function decryptWebhookSecret(env: Pick<Env, "BETTER_AUTH_SECRET">, stored: string, aad: string): Promise<string> {
  const bytes = base64ToBytes(stored);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: bytes.slice(0, 12), additionalData: new TextEncoder().encode(aad) },
    await atRestKey(env),
    bytes.slice(12),
  );
  return new TextDecoder().decode(plain);
}

const aadFor = (endpointId: string, uid: string) => `webhook:${endpointId}:${uid}`;

async function hmacKey(secret: string): Promise<CryptoKey> {
  const raw = base64ToBytes(secret.startsWith("whsec_") ? secret.slice("whsec_".length) : secret);
  return crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

/** The `webhook-signature` header value: `v1,<base64 HMAC-SHA256>` over
 *  `${id}.${timestamp}.${body}`. */
export async function signWebhook(secret: string, id: string, timestamp: number, body: string): Promise<string> {
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(secret), new TextEncoder().encode(`${id}.${timestamp}.${body}`));
  return `v1,${bytesToBase64(new Uint8Array(mac))}`;
}

/**
 * The receiver's check, as Standard Webhooks specifies it (any of the
 * space-separated v1 signatures matches; the timestamp is within
 * `toleranceSec` of now). For tests and the docs' reference.
 */
export async function verifyWebhookSignature(
  secret: string,
  headers: { id: string; timestamp: string; signature: string },
  body: string,
  nowSec: number = Math.floor(Date.now() / 1000),
  toleranceSec = 300,
): Promise<boolean> {
  const ts = Number(headers.timestamp);
  if (!Number.isInteger(ts) || Math.abs(nowSec - ts) > toleranceSec) return false;
  const key = await hmacKey(secret);
  const data = new TextEncoder().encode(`${headers.id}.${ts}.${body}`);
  for (const part of headers.signature.split(" ")) {
    const [version, sig] = part.split(",", 2);
    if (version !== "v1" || !sig) continue;
    let mac: Uint8Array;
    try {
      mac = base64ToBytes(sig);
    } catch {
      continue;
    }
    if (await crypto.subtle.verify("HMAC", key, mac, data)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// The retry state machine (pure)
// ---------------------------------------------------------------------------

/** Wait after the `failedAttempts`-th failed attempt: 5 min × 4^(n-1), at
 *  most 12 h — 5 min, 20 min, 80 min, 5 h 20 min, 12 h, 12 h. */
export function retryDelayMs(failedAttempts: number): number {
  return Math.min(RETRY_BASE_MS * 4 ** Math.max(0, failedAttempts - 1), RETRY_MAX_MS);
}

export type DeliveryStatus = "pending" | "delivered" | "failed" | "cancelled";

/** Where a delivery goes after its `attempt`-th attempt (1-based). */
export function nextDeliveryState(
  attempt: number,
  ok: boolean,
  nowMs: number,
  maxAttempts: number = MAX_DELIVERY_ATTEMPTS,
): { status: DeliveryStatus; nextAttemptAt: string | null } {
  if (ok) return { status: "delivered", nextAttemptAt: null };
  if (attempt >= maxAttempts) return { status: "failed", nextAttemptAt: null };
  return { status: "pending", nextAttemptAt: new Date(nowMs + retryDelayMs(attempt)).toISOString() };
}

export interface EndpointHealth {
  active: boolean;
  failureCount: number;
  failingSince: string | null;
  disabledReason: string | null;
}

/** An endpoint's health after one attempt. Success resets the streak. */
export function endpointAfterAttempt(ep: EndpointHealth, ok: boolean, nowMs: number): EndpointHealth {
  if (ok) return { active: ep.active, failureCount: 0, failingSince: null, disabledReason: ep.active ? null : ep.disabledReason };
  const failureCount = ep.failureCount + 1;
  const failingSince = ep.failingSince ?? new Date(nowMs).toISOString();
  const disable =
    ep.active && failureCount >= DISABLE_AFTER_FAILURES && nowMs - Date.parse(failingSince) >= DISABLE_AFTER_STREAK_MS;
  return {
    active: disable ? false : ep.active,
    failureCount,
    failingSince,
    disabledReason: disable
      ? `Switched off after ${failureCount} failed deliveries in a row since ${failingSince.slice(0, 10)}.`
      : ep.disabledReason,
  };
}

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

interface EndpointRow {
  id: string;
  user_id: string;
  url: string;
  description: string | null;
  secret: string;
  events: string;
  active: number;
  created_at: string;
  updated_at: string;
  created_by_token: string | null;
  last_success_at: string | null;
  last_failure_at: string | null;
  failure_count: number;
  failing_since: string | null;
  disabled_reason: string | null;
}

export interface WebhookEndpointSummary {
  id: string;
  url: string;
  description: string | null;
  events: WebhookEvent[];
  active: boolean;
  createdAt: string;
  updatedAt: string;
  /** "agent" when an MCP client created it (create_webhook). */
  createdBy: "settings" | "agent";
  lastSuccessAt: string | null;
  lastFailureAt: string | null;
  failureCount: number;
  disabledReason: string | null;
}

export function parseEvents(raw: string | null | undefined): WebhookEvent[] {
  try {
    const parsed: unknown = JSON.parse(raw ?? "[]");
    return Array.isArray(parsed)
      ? [...new Set(parsed.filter((e): e is WebhookEvent => (WEBHOOK_EVENTS as readonly string[]).includes(e as string)))]
      : [];
  } catch {
    return [];
  }
}

function toSummary(row: EndpointRow): WebhookEndpointSummary {
  return {
    id: row.id,
    url: row.url,
    description: row.description,
    events: parseEvents(row.events),
    active: row.active === 1,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    createdBy: row.created_by_token ? "agent" : "settings",
    lastSuccessAt: row.last_success_at,
    lastFailureAt: row.last_failure_at,
    failureCount: row.failure_count,
    disabledReason: row.disabled_reason,
  };
}

async function endpointRow(db: D1Database, id: string): Promise<EndpointRow | null> {
  return db.prepare(`SELECT * FROM webhook_endpoints WHERE id = ?`).bind(id).first<EndpointRow>();
}

export async function listWebhookEndpoints(db: D1Database, uid: string): Promise<WebhookEndpointSummary[]> {
  const { results } = await db
    .prepare(`SELECT * FROM webhook_endpoints WHERE user_id = ? ORDER BY created_at DESC`)
    .bind(uid)
    .all<EndpointRow>();
  return (results ?? []).map(toSummary);
}

export async function getWebhookEndpoint(db: D1Database, uid: string, id: string): Promise<WebhookEndpointSummary | null> {
  const row = await endpointRow(db, id);
  return row && row.user_id === uid ? toSummary(row) : null;
}

export type CreateEndpointResult =
  | { ok: true; endpoint: WebhookEndpointSummary; secret: string }
  | { ok: false; status: 400; error: string };

/** Normalise and check an event list (non-empty, known names). */
export function normaliseEvents(events: readonly string[]): WebhookEvent[] | null {
  const out = [...new Set(events)].filter((e): e is WebhookEvent => (WEBHOOK_EVENTS as readonly string[]).includes(e));
  return out.length > 0 && out.length === new Set(events).size ? out : null;
}

export async function createWebhookEndpoint(
  env: Pick<Env, "DB" | "BETTER_AUTH_SECRET">,
  input: { uid: string; url: string; events: readonly string[]; description?: string | null; createdByToken?: string | null },
  now: Date = new Date(),
): Promise<CreateEndpointResult> {
  const checked = checkOutboundUrl(input.url.trim(), { label: "url" });
  if (!checked.ok) return { ok: false, status: 400, error: checked.error };
  const events = normaliseEvents(input.events);
  if (!events) return { ok: false, status: 400, error: `events must be one or more of: ${WEBHOOK_EVENTS.join(", ")}` };
  const count = await env.DB.prepare(`SELECT COUNT(*) AS n FROM webhook_endpoints WHERE user_id = ?`)
    .bind(input.uid)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_WEBHOOK_ENDPOINTS) {
    return { ok: false, status: 400, error: `At most ${MAX_WEBHOOK_ENDPOINTS} webhook endpoints. Delete one first.` };
  }
  const id = `we_${generateId(20)}`;
  const secret = mintWebhookSecret();
  const nowIso = now.toISOString();
  const row: EndpointRow = {
    id,
    user_id: input.uid,
    url: checked.url.toString(),
    description: input.description?.trim() ? input.description.trim().slice(0, 100) : null,
    secret: await encryptWebhookSecret(env, secret, aadFor(id, input.uid)),
    events: JSON.stringify(events),
    active: 1,
    created_at: nowIso,
    updated_at: nowIso,
    created_by_token: input.createdByToken ?? null,
    last_success_at: null,
    last_failure_at: null,
    failure_count: 0,
    failing_since: null,
    disabled_reason: null,
  };
  await env.DB.prepare(
    `INSERT INTO webhook_endpoints (id, user_id, url, description, secret, events, active, created_at, updated_at, created_by_token)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7, ?7, ?8)`,
  )
    .bind(row.id, row.user_id, row.url, row.description, row.secret, row.events, nowIso, row.created_by_token)
    .run();
  return { ok: true, endpoint: toSummary(row), secret };
}

export type UpdateEndpointResult =
  | { ok: true; endpoint: WebhookEndpointSummary }
  | { ok: false; status: 400 | 404; error: string };

/** Switch on/off, change events, url or description. Switching ON clears the
 *  failure streak — the owner says the endpoint is fixed. */
export async function updateWebhookEndpoint(
  db: D1Database,
  uid: string,
  id: string,
  patch: { active?: boolean; events?: readonly string[]; url?: string; description?: string | null },
  now: Date = new Date(),
): Promise<UpdateEndpointResult> {
  const row = await endpointRow(db, id);
  if (!row || row.user_id !== uid) return { ok: false, status: 404, error: "No webhook endpoint with that id" };
  let url = row.url;
  if (patch.url !== undefined) {
    const checked = checkOutboundUrl(patch.url.trim(), { label: "url" });
    if (!checked.ok) return { ok: false, status: 400, error: checked.error };
    url = checked.url.toString();
  }
  let events = row.events;
  if (patch.events !== undefined) {
    const normalised = normaliseEvents(patch.events);
    if (!normalised) return { ok: false, status: 400, error: `events must be one or more of: ${WEBHOOK_EVENTS.join(", ")}` };
    events = JSON.stringify(normalised);
  }
  const description =
    patch.description === undefined ? row.description : patch.description?.trim() ? patch.description.trim().slice(0, 100) : null;
  const active = patch.active === undefined ? row.active === 1 : patch.active;
  const reenabled = active && row.active !== 1;
  await db
    .prepare(
      `UPDATE webhook_endpoints
          SET url = ?1, events = ?2, description = ?3, active = ?4, updated_at = ?5,
              failure_count = CASE WHEN ?6 THEN 0 ELSE failure_count END,
              failing_since = CASE WHEN ?6 THEN NULL ELSE failing_since END,
              disabled_reason = CASE WHEN ?6 THEN NULL ELSE disabled_reason END
        WHERE id = ?7 AND user_id = ?8`,
    )
    .bind(url, events, description, active ? 1 : 0, now.toISOString(), reenabled ? 1 : 0, id, uid)
    .run();
  const fresh = await endpointRow(db, id);
  return { ok: true, endpoint: toSummary(fresh!) };
}

/** Delete the endpoint and its delivery history (the user's own config, not
 *  their content). */
export async function deleteWebhookEndpoint(db: D1Database, uid: string, id: string): Promise<boolean> {
  const row = await endpointRow(db, id);
  if (!row || row.user_id !== uid) return false;
  await db.batch([
    db.prepare(`DELETE FROM webhook_deliveries WHERE endpoint_id = ?`).bind(id),
    db.prepare(`DELETE FROM webhook_endpoints WHERE id = ? AND user_id = ?`).bind(id, uid),
  ]);
  return true;
}

// ---------------------------------------------------------------------------
// Deliveries
// ---------------------------------------------------------------------------

interface DeliveryRow {
  id: string;
  endpoint_id: string;
  user_id: string;
  event: string;
  payload: string;
  attempt: number;
  next_attempt_at: string | null;
  status: DeliveryStatus;
  response_code: number | null;
  error: string | null;
  created_at: string;
  last_attempt_at: string | null;
  delivered_at: string | null;
}

export interface WebhookDeliverySummary {
  id: string;
  event: string;
  status: DeliveryStatus;
  attempt: number;
  responseCode: number | null;
  error: string | null;
  createdAt: string;
  lastAttemptAt: string | null;
  nextAttemptAt: string | null;
  deliveredAt: string | null;
}

function toDeliverySummary(r: DeliveryRow): WebhookDeliverySummary {
  return {
    id: r.id,
    event: r.event,
    status: r.status,
    attempt: r.attempt,
    responseCode: r.response_code,
    error: r.error,
    createdAt: r.created_at,
    lastAttemptAt: r.last_attempt_at,
    nextAttemptAt: r.status === "pending" ? r.next_attempt_at : null,
    deliveredAt: r.delivered_at,
  };
}

export async function listWebhookDeliveries(
  db: D1Database,
  uid: string,
  endpointId: string,
  limit = 20,
): Promise<WebhookDeliverySummary[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM webhook_deliveries WHERE endpoint_id = ?1 AND user_id = ?2 ORDER BY created_at DESC, id DESC LIMIT ?3`,
    )
    .bind(endpointId, uid, limit)
    .all<DeliveryRow>();
  return (results ?? []).map(toDeliverySummary);
}

export interface AttemptOutcome {
  ok: boolean;
  status: number | null;
  error: string | null;
}

/** One signed POST. Never throws. */
export async function sendWebhook(
  url: string,
  secret: string,
  delivery: { id: string; payload: string },
  nowMs: number,
  fetchImpl: typeof fetch = fetch,
): Promise<AttemptOutcome> {
  const checked = checkOutboundUrl(url, { label: "url" });
  if (!checked.ok) return { ok: false, status: null, error: checked.error };
  const timestamp = Math.floor(nowMs / 1000);
  try {
    const res = await fetchImpl(checked.url.toString(), {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(WEBHOOK_TIMEOUT_MS),
      headers: {
        "content-type": "application/json",
        "user-agent": USER_AGENT,
        "webhook-id": delivery.id,
        "webhook-timestamp": String(timestamp),
        "webhook-signature": await signWebhook(secret, delivery.id, timestamp, delivery.payload),
      },
      body: delivery.payload,
    });
    await res.body?.cancel().catch(() => {});
    if (res.status >= 200 && res.status < 300) return { ok: true, status: res.status, error: null };
    return {
      ok: false,
      status: res.status,
      error: res.status >= 300 && res.status < 400 ? `HTTP ${res.status} (redirects are not followed)` : `HTTP ${res.status}`,
    };
  } catch (err) {
    const name = err instanceof Error ? err.name : "";
    return {
      ok: false,
      status: null,
      error: name === "TimeoutError" || name === "AbortError" ? `No response within ${WEBHOOK_TIMEOUT_MS / 1000} s` : "Could not connect",
    };
  }
}

/**
 * Claim one due delivery, POST it, record the outcome and the endpoint's
 * health. Null when someone else holds it (or it is not due / final).
 */
export async function attemptDelivery(
  env: Pick<Env, "DB" | "BETTER_AUTH_SECRET">,
  deliveryId: string,
  now: Date = new Date(),
  fetchImpl: typeof fetch = fetch,
): Promise<AttemptOutcome | null> {
  const nowMs = now.getTime();
  const nowIso = now.toISOString();
  const claimed = await env.DB.prepare(
    `UPDATE webhook_deliveries
        SET attempt = attempt + 1, last_attempt_at = ?1, next_attempt_at = ?2
      WHERE id = ?3 AND status = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= ?1)
      RETURNING *`,
  )
    .bind(nowIso, new Date(nowMs + CLAIM_LEASE_MS).toISOString(), deliveryId)
    .first<DeliveryRow>();
  if (!claimed) return null;

  const isTest = claimed.event === WEBHOOK_TEST_EVENT;
  const finish = (status: DeliveryStatus, outcome: AttemptOutcome, nextAttemptAt: string | null) =>
    env.DB.prepare(
      `UPDATE webhook_deliveries
          SET status = ?1, next_attempt_at = ?2, response_code = ?3, error = ?4,
              delivered_at = CASE WHEN ?1 = 'delivered' THEN ?5 ELSE delivered_at END
        WHERE id = ?6`,
    )
      .bind(status, nextAttemptAt, outcome.status, outcome.error ? outcome.error.slice(0, 300) : null, nowIso, claimed.id)
      .run();

  const ep = await endpointRow(env.DB, claimed.endpoint_id);
  if (!ep || ep.user_id !== claimed.user_id || (!ep.active && !isTest)) {
    const outcome = { ok: false, status: null, error: "Endpoint was switched off or deleted" };
    await finish("cancelled", outcome, null);
    return outcome;
  }
  if (!isTest && !(await planForUser(env, claimed.user_id)).features.agentWebhooks) {
    const outcome = { ok: false, status: null, error: "Webhooks aren't included in the account's plan" };
    await finish("cancelled", outcome, null);
    return outcome;
  }

  let secret: string;
  try {
    secret = await decryptWebhookSecret(env, ep.secret, aadFor(ep.id, ep.user_id));
  } catch {
    const outcome = { ok: false, status: null, error: "The endpoint's secret can't be read — delete it and add it again" };
    await finish("failed", outcome, null);
    return outcome;
  }

  const outcome = await sendWebhook(ep.url, secret, claimed, nowMs, fetchImpl);
  const next = nextDeliveryState(claimed.attempt, outcome.ok, nowMs, isTest ? 1 : MAX_DELIVERY_ATTEMPTS);
  await finish(next.status, outcome, next.nextAttemptAt);

  // A test says nothing about the streak: it may be sent to a switched-off
  // endpoint precisely to check it before switching it back on.
  if (!isTest) {
    const health = endpointAfterAttempt(
      { active: ep.active === 1, failureCount: ep.failure_count, failingSince: ep.failing_since, disabledReason: ep.disabled_reason },
      outcome.ok,
      nowMs,
    );
    await env.DB.prepare(
      `UPDATE webhook_endpoints
          SET active = ?1, failure_count = ?2, failing_since = ?3, disabled_reason = ?4,
              last_success_at = CASE WHEN ?5 THEN ?6 ELSE last_success_at END,
              last_failure_at = CASE WHEN ?5 THEN last_failure_at ELSE ?6 END
        WHERE id = ?7`,
    )
      .bind(health.active ? 1 : 0, health.failureCount, health.failingSince, health.disabledReason, outcome.ok ? 1 : 0, nowIso, ep.id)
      .run();
  }
  return outcome;
}

async function insertDelivery(db: D1Database, endpointId: string, uid: string, event: string, payload: string, nowIso: string) {
  const id = `msg_${generateId(24)}`;
  await db
    .prepare(
      `INSERT INTO webhook_deliveries (id, endpoint_id, user_id, event, payload, attempt, next_attempt_at, status, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, 'pending', ?6)`,
    )
    .bind(id, endpointId, uid, event, payload, nowIso)
    .run();
  return id;
}

/** At most one `key` event per `windowSec`, sliding (not clock-aligned):
 *  the row remembers when the last one went out. */
async function debounceAllows(db: D1Database, key: string, windowSec: number, nowSec: number): Promise<boolean> {
  const row = await db
    .prepare(
      `INSERT INTO rate_limits (key, window_start, count) VALUES (?1, ?2, 1)
       ON CONFLICT(key) DO UPDATE SET window_start = ?2, count = 1
         WHERE rate_limits.window_start <= ?2 - ?3
       RETURNING window_start`,
    )
    .bind(key, nowSec, windowSec)
    .first<{ window_start: number }>();
  return row !== null;
}

/**
 * Record `event` for every active endpoint of `uid` subscribed to it, then
 * attempt each delivery at once. Returns the delivery ids (empty when the
 * user has no such endpoint, their plan lacks webhooks, or it was
 * debounced). Callers run it in the background: see `queueWebhookEvent`.
 */
export async function emitWebhookEvent(
  env: Pick<Env, "DB" | "BETTER_AUTH_SECRET">,
  uid: string,
  event: WebhookEvent,
  data: Record<string, unknown>,
  opts: { debounceKey?: string; debounceSec?: number; now?: Date; fetchImpl?: typeof fetch } = {},
): Promise<string[]> {
  const now = opts.now ?? new Date();
  const { results } = await env.DB.prepare(`SELECT id, events FROM webhook_endpoints WHERE user_id = ? AND active = 1`)
    .bind(uid)
    .all<{ id: string; events: string }>();
  const targets = (results ?? []).filter((r) => parseEvents(r.events).includes(event));
  if (targets.length === 0) return [];
  if (!(await planForUser(env, uid)).features.agentWebhooks) return [];
  if (opts.debounceKey) {
    const allowed = await debounceAllows(
      env.DB,
      `wh:${event}:${opts.debounceKey}`,
      opts.debounceSec ?? SHARE_VIEWED_DEBOUNCE_SEC,
      Math.floor(now.getTime() / 1000),
    );
    if (!allowed) return [];
  }
  const nowIso = now.toISOString();
  const payload = JSON.stringify({ type: event, timestamp: nowIso, data });
  const ids: string[] = [];
  for (const target of targets) ids.push(await insertDelivery(env.DB, target.id, uid, event, payload, nowIso));
  await Promise.all(ids.map((id) => attemptDelivery(env, id, now, opts.fetchImpl).catch((err) => console.error("webhooks: attempt failed", err))));
  return ids;
}

/**
 * Fire-and-forget form for request handlers: never throws, never delays the
 * response. `waitUntil` is the Worker's ctx.waitUntil (see backgroundOf).
 */
export function queueWebhookEvent(
  waitUntil: ((promise: Promise<unknown>) => void) | undefined,
  env: Pick<Env, "DB" | "BETTER_AUTH_SECRET">,
  uid: string,
  event: WebhookEvent,
  data: Record<string, unknown>,
  opts: { debounceKey?: string } = {},
): void {
  const work = emitWebhookEvent(env, uid, event, data, opts).catch((err: unknown) =>
    console.error(`webhooks: ${event} for ${uid} failed`, err instanceof Error ? err.message : err),
  );
  waitUntil?.(work);
}

/** ctx.waitUntil of a Hono context, or undefined where there is none (a
 *  test calling app.request without an ExecutionContext). */
export function backgroundOf(c: {
  readonly executionCtx: { waitUntil(promise: Promise<unknown>): void };
}): ((promise: Promise<unknown>) => void) | undefined {
  try {
    const ctx = c.executionCtx;
    return (promise) => ctx.waitUntil(promise);
  } catch {
    return undefined;
  }
}

/** "Send test": one webhook.test delivery to this endpoint, attempted now,
 *  never retried. */
export async function sendTestWebhook(
  env: Pick<Env, "DB" | "BETTER_AUTH_SECRET">,
  uid: string,
  endpointId: string,
  now: Date = new Date(),
  fetchImpl: typeof fetch = fetch,
): Promise<{ delivery: WebhookDeliverySummary } | null> {
  const ep = await endpointRow(env.DB, endpointId);
  if (!ep || ep.user_id !== uid) return null;
  const nowIso = now.toISOString();
  const payload = JSON.stringify({
    type: WEBHOOK_TEST_EVENT,
    timestamp: nowIso,
    data: { endpointId, message: "A test event from CaptureCat. If you can read this, your endpoint works." },
  });
  const id = await insertDelivery(env.DB, endpointId, uid, WEBHOOK_TEST_EVENT, payload, nowIso);
  await attemptDelivery(env, id, now, fetchImpl);
  const row = await env.DB.prepare(`SELECT * FROM webhook_deliveries WHERE id = ?`).bind(id).first<DeliveryRow>();
  return { delivery: toDeliverySummary(row!) };
}

/**
 * The five-minute cron: attempt every due delivery (oldest first), a few at a time.
 * Deliveries stuck behind a crashed sender come back when their lease ends.
 */
export async function processWebhookOutbox(
  env: Pick<Env, "DB" | "BETTER_AUTH_SECRET">,
  now: Date = new Date(),
  limit = 100,
  fetchImpl: typeof fetch = fetch,
): Promise<{ attempted: number; delivered: number }> {
  const { results } = await env.DB.prepare(
    `SELECT id FROM webhook_deliveries
      WHERE status = 'pending' AND next_attempt_at IS NOT NULL AND next_attempt_at <= ?1
      ORDER BY next_attempt_at LIMIT ?2`,
  )
    .bind(now.toISOString(), limit)
    .all<{ id: string }>();
  const ids = (results ?? []).map((r) => r.id);
  let attempted = 0;
  let delivered = 0;
  const CONCURRENCY = 6;
  for (let i = 0; i < ids.length; i += CONCURRENCY) {
    const outcomes = await Promise.all(
      ids.slice(i, i + CONCURRENCY).map((id) => attemptDelivery(env, id, now, fetchImpl).catch(() => null)),
    );
    for (const o of outcomes) {
      if (!o) continue;
      attempted++;
      if (o.ok) delivered++;
    }
  }
  return { attempted, delivered };
}

// ---------------------------------------------------------------------------
// Payloads (minimal: ids, titles, URLs — no viewer data)
// ---------------------------------------------------------------------------

export function videoEventData(env: Env, doc: VideoMetadata, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    videoId: doc.videoId,
    title: doc.fileName,
    shareUrl: `${shareBaseURL(env)}/share/${doc.videoId}`,
    privacy: doc.isPrivate ? "private" : "public",
    ...extra,
  };
}

/**
 * `project.saved` data. Every path that saves a cloud project calls
 * `queueWebhookEvent(…, ownerUid, "project.saved", projectSavedData(…))`
 * after a successful save — the PUT …/project route does, and so should the
 * MCP editing tools (src/mcp/project-tools.ts).
 */
export function projectSavedData(
  env: Env,
  p: { projectId: string; name: string; revision: number; savedAt: string; by: "user" | "agent" },
): Record<string, unknown> {
  return {
    projectId: p.projectId,
    name: p.name,
    revision: p.revision,
    savedAt: p.savedAt,
    savedBy: p.by,
    editorUrl: `${appBaseURL(env)}/app/editor/${p.projectId}`,
  };
}
