/**
 * "iPhone over Wi-Fi" server side (migration 0042) through the REAL Worker
 * entry: the account's device link key (/api/wireless/link), the device
 * registry (/api/devices) and the Mac's "wake this phone" APNs push.
 *
 * Mocked: Better Auth's session lookup — `Authorization: Bearer <uid>` is
 * that user's native-app session, and the cookie `cc_session=<uid>` is a
 * browser session. Like Better Auth's bearer plugin, a bearer value that does
 * not verify FALLS BACK to the cookie — which is exactly the hole
 * requireBearer must close. `fetch` is stubbed: APNs is never reached (and
 * could not be from local workerd anyway — it needs HTTP/2).
 */
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";

type FetchCall = { url: string; init: RequestInit & { headers: Record<string, string> } };
const apns = vi.hoisted(() => ({
  calls: [] as { url: string; init: RequestInit & { headers: Record<string, string> } }[],
  respond: (() => new Response(null, { status: 200, headers: { "apns-id": "test-apns-id" } })) as () =>
    | Response
    | Promise<Response>,
}));

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => ({
  hasAppleConfig: () => true,
  hasGoogleConfig: () => true,
  getAuth: (env: Env) => {
    const lookup = (uid: string | null | undefined) =>
      uid
        ? env.DB.prepare(`SELECT id, email, tester, blocked FROM "user" WHERE id = ?`)
            .bind(uid)
            .first<{ id: string; email: string; tester: number; blocked: number }>()
        : Promise.resolve(null);
    return {
      api: {
        getSession: async ({ headers }: { headers: Headers }) => {
          const bearer = /^Bearer\s+(\S+)$/i.exec(headers.get("Authorization") ?? "")?.[1];
          const cookie = /(?:^|;\s*)cc_session=([^;]+)/.exec(headers.get("Cookie") ?? "")?.[1];
          const user = (await lookup(bearer)) ?? (await lookup(cookie));
          return user
            ? {
                session: { expiresAt: new Date(Date.now() + 86_400_000) },
                user: { id: user.id, email: user.email, tester: user.tester === 1, blocked: user.blocked === 1 },
              }
            : null;
        },
      },
    };
  },
}));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });
vi.stubGlobal(
  "fetch",
  vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    apns.calls.push({ url: String(input), init: init as FetchCall["init"] });
    return apns.respond();
  }),
);

const { default: worker } = await import("../index");
const { resetApnsProviderTokenCache } = await import("../lib/apns");
const { wirelessKeyId, base64UrlDecode } = await import("../lib/wireless-link");
const { decryptSecret } = await import("../lib/storage");

const API = "https://api.capturecat.so";
const ALICE = "alice";
const BOB = "bob";
const PHONE = "6f1c2c3e-8d4b-4c47-9f0e-2a7b9d1e5c11";
const PHONE_UPPER = PHONE.toUpperCase();
const MAC = "0b8f0a77-3c2d-4e1f-8a9b-7c6d5e4f3a21";
const TOKEN = "a1".repeat(32); // 64 hex
const TOKEN_2 = "b2".repeat(40); // 80 hex
const KEY_ID = "TESTKEY123";
const TEAM_ID = "TESTTEAM12";
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

let db: TestD1;
let env: Env;
let apnsPem: string;
let apnsPublicKey: CryptoKey;

function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function b64urlToBytes(value: string): Uint8Array {
  return base64UrlDecode(value);
}

beforeAll(async () => {
  // A throwaway APNs auth key, shaped exactly like Apple's .p8 (PKCS#8 P-256).
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  apnsPem = `-----BEGIN PRIVATE KEY-----\n${b64(pkcs8).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`;
  apnsPublicKey = pair.publicKey;
});

beforeEach(() => {
  db = createTestD1();
  env = {
    DB: db,
    BETTER_AUTH_URL: API,
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    STORAGE_CREDENTIALS_KEY: b64(crypto.getRandomValues(new Uint8Array(32))),
    APNS_KEY: apnsPem,
    APNS_KEY_ID: KEY_ID,
    APNS_TEAM_ID: TEAM_ID,
  } as unknown as Env;
  const now = new Date().toISOString();
  for (const [id, blocked] of [[ALICE, 0], [BOB, 0], ["blocked", 1]] as const) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked, role, username)
       VALUES (?, ?, ?, 1, ?, ?, 0, ?, 'user', ?)`,
      id, id, `${id}@test.local`, now, now, blocked, id,
    );
  }
  apns.calls.length = 0;
  apns.respond = () => new Response(null, { status: 200, headers: { "apns-id": "test-apns-id" } });
  resetApnsProviderTokenCache();
});

function req(
  method: string,
  path: string,
  init: { as?: string | null; cookie?: string; authorization?: string; body?: unknown } = {},
) {
  const headers: Record<string, string> = { "CF-Connecting-IP": "203.0.113.9" };
  const as = init.as === undefined ? ALICE : init.as;
  if (init.authorization) headers.Authorization = init.authorization;
  else if (as) headers.Authorization = `Bearer ${as}`;
  if (init.cookie) headers.Cookie = init.cookie;
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  return worker.fetch(
    new Request(`${API}${path}`, {
      method,
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    }),
    env,
    ctx,
  );
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- asserted field by field
async function ok<T = any>(res: Response | Promise<Response>, status = 200): Promise<T> {
  const r = await res;
  const body = await r.json();
  expect(r.status, JSON.stringify(body)).toBe(status);
  return body as T;
}

const registerPhone = (as = ALICE, body: Record<string, unknown> = {}, deviceId = PHONE) =>
  req("PUT", `/api/devices/${deviceId}`, {
    as,
    body: {
      platform: "ios",
      name: "Mike's iPhone",
      model: "iPhone18,1",
      systemVersion: "26.1",
      appVersion: "1.0 (3)",
      apnsToken: TOKEN,
      apnsEnvironment: "sandbox",
      ...body,
    },
  });

const askToStream = (deviceId = PHONE, body: Record<string, unknown> = { macId: "mac-1234", macName: "Studio" }, as = ALICE) =>
  req("POST", `/api/devices/${deviceId}/request-broadcast`, { as, body });

/** The spec, independently of lib/wireless-link.ts: lowercase hex of the
 *  first 8 bytes of SHA-256("capturecat-wireless-link-v1" ‖ key bytes). */
async function keyIdFromSpec(key: Uint8Array): Promise<string> {
  const prefix = new TextEncoder().encode("capturecat-wireless-link-v1");
  const data = new Uint8Array([...prefix, ...key]);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return [...digest.slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------

describe("keyId", () => {
  it("matches WirelessLink.keyID(for:) for key bytes 0x00..0x1f", async () => {
    const key = Uint8Array.from({ length: 32 }, (_, i) => i);
    const fromSpec = await keyIdFromSpec(key);
    const fromLib = await wirelessKeyId(key);
    console.log(`wireless keyId vector (key = 0x00..0x1f): ${fromLib}`);
    // Also produced by the Swift implementation (CryptoKit) on 2026-11-13.
    expect(fromLib).toBe("8f40509a77686376");
    expect(fromLib).toBe(fromSpec);
  });
});

describe("native apps only", () => {
  const endpoints: [string, string, unknown?][] = [
    ["GET", "/api/wireless/link"],
    ["POST", "/api/wireless/link/rotate"],
    ["GET", "/api/devices"],
    ["PUT", `/api/devices/${PHONE}`, { platform: "ios", name: "iPhone" }],
    ["DELETE", `/api/devices/${PHONE}`],
    ["POST", `/api/devices/${PHONE}/request-broadcast`, { macId: "m", macName: "Mac" }],
  ];

  it("a browser cookie session gets 401 on every endpoint", async () => {
    for (const [method, path, body] of endpoints) {
      const res = await req(method, path, { as: null, cookie: `cc_session=${ALICE}`, body });
      expect(res.status, `${method} ${path}`).toBe(401);
      expect(await res.json()).toMatchObject({ code: "bearer_required" });
    }
    expect(db.query(`SELECT COUNT(*) AS n FROM wireless_links`)[0]).toMatchObject({ n: 0 });
  });

  it("a junk bearer can't smuggle the cookie's session through", async () => {
    // Sanity: the mocked session store really does fall back to the cookie.
    expect((await req("GET", "/api/me", { authorization: "Bearer junk", cookie: `cc_session=${ALICE}` })).status).toBe(200);
    for (const [method, path, body] of endpoints) {
      const res = await req(method, path, { authorization: "Bearer junk", cookie: `cc_session=${ALICE}`, body });
      expect(res.status, `${method} ${path}`).toBe(401);
    }
    expect(db.query(`SELECT COUNT(*) AS n FROM wireless_links`)[0]).toMatchObject({ n: 0 });
  });

  it("refuses agent tokens", async () => {
    for (const token of [`cc_pat_${"A".repeat(40)}`, `cc_oat_${"b".repeat(40)}`]) {
      for (const [method, path, body] of endpoints) {
        const res = await req(method, path, { authorization: `Bearer ${token}`, body });
        expect(res.status, `${method} ${path}`).toBe(403);
        expect(await res.json()).toMatchObject({ code: "agent_token_forbidden" });
      }
    }
  });

  it("no credentials is 401, an unknown bearer is 401, a blocked account is 403", async () => {
    expect((await req("GET", "/api/wireless/link", { as: null })).status).toBe(401);
    expect((await req("GET", "/api/wireless/link", { as: "nobody" })).status).toBe(401);
    expect((await req("GET", "/api/wireless/link", { as: "blocked" })).status).toBe(403);
  });

  it("a bearer request that also carries cookies still works (cookies are ignored, the body survives)", async () => {
    const put = await req("PUT", `/api/devices/${PHONE}`, {
      as: ALICE,
      cookie: `cc_session=${BOB}; __cf_bm=x`,
      body: { platform: "ios", name: "With cookies", apnsToken: TOKEN, apnsEnvironment: "sandbox" },
    });
    expect(await ok(put)).toMatchObject({ deviceId: PHONE, name: "With cookies", canPush: true });
    const withCookie = await req("GET", "/api/devices", { as: ALICE, cookie: `cc_session=${BOB}; __cf_bm=x` });
    expect((await ok(withCookie)).devices).toHaveLength(1);
    expect(db.query(`SELECT user_id FROM user_devices`)).toEqual([{ user_id: ALICE }]);
  });
});

describe("GET /api/wireless/link", () => {
  it("creates the account's key once, sealed at rest, and returns the same one after", async () => {
    const res = await req("GET", "/api/wireless/link");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    const first = await ok(res);
    expect(Object.keys(first).sort()).toEqual(["createdAt", "key", "keyId"]);
    expect(first.key).toMatch(/^[A-Za-z0-9_-]{43}$/); // 32 bytes, base64url, no padding
    expect(b64urlToBytes(first.key).byteLength).toBe(32);
    expect(first.keyId).toMatch(/^[0-9a-f]{16}$/);
    expect(first.keyId).toBe(await keyIdFromSpec(b64urlToBytes(first.key)));
    expect(Number.isNaN(Date.parse(first.createdAt))).toBe(false);

    const second = await ok(req("GET", "/api/wireless/link"));
    expect(second).toEqual(first);

    const rows = db.query<{ user_id: string; key_ciphertext: string; key_id: string }>(`SELECT * FROM wireless_links`);
    expect(rows).toHaveLength(1);
    expect(rows[0].user_id).toBe(ALICE);
    expect(rows[0].key_id).toBe(first.keyId);
    expect(rows[0].key_ciphertext).not.toContain(first.key);
    // Not sealed with the RAW storage key (that one is the bucket credentials').
    await expect(decryptSecret(env, rows[0].key_ciphertext, `wireless_links:${ALICE}`)).rejects.toThrow();
  });

  it("concurrent first calls converge on ONE key", async () => {
    const bodies = await Promise.all(Array.from({ length: 8 }, () => ok(req("GET", "/api/wireless/link"))));
    expect(new Set(bodies.map((b) => b.key)).size).toBe(1);
    expect(new Set(bodies.map((b) => b.keyId)).size).toBe(1);
    expect(db.query(`SELECT COUNT(*) AS n FROM wireless_links`)[0]).toMatchObject({ n: 1 });
    expect((await ok(req("GET", "/api/wireless/link"))).key).toBe(bodies[0].key);
  });

  it("every account has its own key", async () => {
    const alice = await ok(req("GET", "/api/wireless/link", { as: ALICE }));
    const bob = await ok(req("GET", "/api/wireless/link", { as: BOB }));
    expect(bob.key).not.toBe(alice.key);
    expect(bob.keyId).not.toBe(alice.keyId);
  });

  it("a ciphertext copied onto another account's row won't open there: that account gets a fresh key", async () => {
    const alice = await ok(req("GET", "/api/wireless/link", { as: ALICE }));
    const [row] = db.query<{ key_ciphertext: string; key_id: string; created_at: string }>(
      `SELECT key_ciphertext, key_id, created_at FROM wireless_links WHERE user_id = ?`,
      ALICE,
    );
    db.query(
      `INSERT INTO wireless_links (user_id, key_ciphertext, key_id, created_at) VALUES (?, ?, ?, ?)`,
      BOB, row.key_ciphertext, row.key_id, row.created_at,
    );
    const bob = await ok(req("GET", "/api/wireless/link", { as: BOB }));
    expect(bob.key).not.toBe(alice.key);
    expect(bob.keyId).toBe(await keyIdFromSpec(b64urlToBytes(bob.key)));
    // And it is stable from then on.
    expect((await ok(req("GET", "/api/wireless/link", { as: BOB }))).key).toBe(bob.key);
  });

  it("answers 503 wireless_unavailable without STORAGE_CREDENTIALS_KEY, and stores nothing", async () => {
    delete (env as { STORAGE_CREDENTIALS_KEY?: string }).STORAGE_CREDENTIALS_KEY;
    expect(await ok(req("GET", "/api/wireless/link"), 503)).toMatchObject({ code: "wireless_unavailable" });
    expect(await ok(req("POST", "/api/wireless/link/rotate"), 503)).toMatchObject({ code: "wireless_unavailable" });
    expect(db.query(`SELECT COUNT(*) AS n FROM wireless_links`)[0]).toMatchObject({ n: 0 });
  });
});

describe("POST /api/wireless/link/rotate", () => {
  it("replaces the key; GET returns the new one", async () => {
    const before = await ok(req("GET", "/api/wireless/link"));
    const rotated = await ok(req("POST", "/api/wireless/link/rotate"));
    expect(Object.keys(rotated).sort()).toEqual(["createdAt", "key", "keyId"]);
    expect(rotated.key).not.toBe(before.key);
    expect(rotated.keyId).not.toBe(before.keyId);
    expect(rotated.keyId).toBe(await keyIdFromSpec(b64urlToBytes(rotated.key)));
    expect(Date.parse(rotated.createdAt)).toBeGreaterThanOrEqual(Date.parse(before.createdAt));
    expect(await ok(req("GET", "/api/wireless/link"))).toEqual(rotated);
    expect(db.query(`SELECT COUNT(*) AS n FROM wireless_links`)[0]).toMatchObject({ n: 1 });
  });

  it("works before any key exists", async () => {
    const rotated = await ok(req("POST", "/api/wireless/link/rotate"));
    expect(await ok(req("GET", "/api/wireless/link"))).toEqual(rotated);
  });
});

describe("devices", () => {
  it("registers a phone and returns the public shape — never the token", async () => {
    const res = await registerPhone(ALICE, {}, PHONE_UPPER);
    const text = await res.text();
    expect(res.status, text).toBe(200);
    expect(text).not.toContain(TOKEN);
    const device = JSON.parse(text);
    expect(device).toEqual({
      deviceId: PHONE, // stored lowercase
      platform: "ios",
      name: "Mike's iPhone",
      model: "iPhone18,1",
      systemVersion: "26.1",
      appVersion: "1.0 (3)",
      canPush: true,
      lastSeenAt: expect.any(String),
    });

    const listRes = await req("GET", "/api/devices");
    const listText = await listRes.text();
    expect(listText).not.toContain(TOKEN);
    expect(listText).not.toMatch(/apns/i);
    expect(JSON.parse(listText)).toEqual({ devices: [device] });
    expect(db.query(`SELECT apns_token, apns_env FROM user_devices`)[0]).toEqual({ apns_token: TOKEN, apns_env: "sandbox" });
  });

  it("lists only the caller's devices, newest first", async () => {
    await ok(registerPhone(ALICE));
    db.query(`UPDATE user_devices SET last_seen_at = '2026-01-01T00:00:00.000Z'`);
    await ok(req("PUT", `/api/devices/${MAC}`, { body: { platform: "mac", name: "Studio", model: "Mac16,10" } }));
    await ok(registerPhone(BOB, { apnsToken: TOKEN_2 }, "11111111-2222-4333-8444-555555555555"));
    const { devices } = await ok(req("GET", "/api/devices"));
    expect(devices.map((d: { deviceId: string }) => d.deviceId)).toEqual([MAC, PHONE]);
    expect(devices[0]).toMatchObject({ platform: "mac", canPush: false, systemVersion: null, appVersion: null });
  });

  it("a refresh without apnsToken keeps the token; null forgets it; a new one replaces it", async () => {
    await ok(registerPhone());
    const seen = db.query<{ last_seen_at: string }>(`SELECT last_seen_at FROM user_devices`)[0].last_seen_at;
    await new Promise((r) => setTimeout(r, 5));
    const refreshed = await ok(req("PUT", `/api/devices/${PHONE}`, { body: { platform: "ios", name: "Renamed", appVersion: "1.1" } }));
    expect(refreshed).toMatchObject({ name: "Renamed", appVersion: "1.1", model: null, canPush: true });
    expect(Date.parse(refreshed.lastSeenAt)).toBeGreaterThan(Date.parse(seen));
    expect(db.query(`SELECT apns_token FROM user_devices`)[0]).toEqual({ apns_token: TOKEN });

    await ok(registerPhone(ALICE, { apnsToken: TOKEN_2.toUpperCase(), apnsEnvironment: "production" }));
    expect(db.query(`SELECT apns_token, apns_env FROM user_devices`)[0]).toEqual({ apns_token: TOKEN_2, apns_env: "production" });

    const cleared = await ok(registerPhone(ALICE, { apnsToken: null }));
    expect(cleared.canPush).toBe(false);
    expect(db.query(`SELECT apns_token, apns_env FROM user_devices`)[0]).toEqual({ apns_token: null, apns_env: null });
  });

  it("a token lives on one device row: registering it elsewhere clears the old row", async () => {
    await ok(registerPhone(ALICE));
    // The phone signed out of Alice without reaching the API, then into Bob.
    await ok(registerPhone(BOB, {}, "22222222-3333-4444-8555-666666666666"));
    const rows = db.query<{ user_id: string; apns_token: string | null }>(
      `SELECT user_id, apns_token FROM user_devices ORDER BY user_id`,
    );
    expect(rows).toEqual([
      { user_id: ALICE, apns_token: null },
      { user_id: BOB, apns_token: TOKEN },
    ]);
    expect(await ok(askToStream(PHONE), 409)).toMatchObject({ code: "push_unavailable" });
    expect(apns.calls).toHaveLength(0);
  });

  it("validates input", async () => {
    const put = (body: Record<string, unknown>, id = PHONE) => req("PUT", `/api/devices/${id}`, { body });
    const base = { platform: "ios", name: "iPhone" };
    const bad: [Record<string, unknown>, string?][] = [
      [base, "not-a-uuid"],
      [{ ...base, platform: "android" }],
      [{ ...base, platform: undefined }],
      [{ ...base, name: undefined }],
      [{ ...base, name: " \n\t " }],
      [{ ...base, name: 42 }],
      [{ ...base, model: "<script>" }],
      [{ ...base, systemVersion: "x".repeat(33) }],
      [{ ...base, appVersion: "1.0\n" + "x" }],
      [{ ...base, apnsToken: "zz".repeat(32), apnsEnvironment: "sandbox" }],
      [{ ...base, apnsToken: "ab".repeat(31), apnsEnvironment: "sandbox" }], // 62 hex
      [{ ...base, apnsToken: "a".repeat(201), apnsEnvironment: "sandbox" }],
      [{ ...base, apnsToken: TOKEN }], // no environment
      [{ ...base, apnsToken: TOKEN, apnsEnvironment: "staging" }],
      [{ platform: "mac", name: "Studio", apnsToken: TOKEN, apnsEnvironment: "sandbox" }],
    ];
    for (const [body, id] of bad) {
      const res = await put(body, id);
      expect(res.status, JSON.stringify(body)).toBe(400);
      expect(await res.json()).toMatchObject({ code: "invalid_request" });
    }
    const notJson = await req("PUT", `/api/devices/${PHONE}`, { body: [1, 2] });
    expect(notJson.status).toBe(400);
    expect(db.query(`SELECT COUNT(*) AS n FROM user_devices`)[0]).toMatchObject({ n: 0 });
  });

  it("cleans the display name", async () => {
    const device = await ok(
      req("PUT", `/api/devices/${PHONE}`, { body: { platform: "ios", name: `  Mike's\n\u202Eenohp  📱 ${"x".repeat(200)}` } }),
    );
    expect(device.name).not.toMatch(/[\n\u202E]/);
    expect(device.name.startsWith("Mike's enohp 📱 x")).toBe(true);
    expect(Array.from(device.name as string).length).toBeLessThanOrEqual(100);
  });

  it("keeps the newest 50 devices per account", async () => {
    for (let i = 0; i < 50; i++) {
      const id = `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`;
      db.query(
        `INSERT INTO user_devices (user_id, device_id, platform, name, created_at, updated_at, last_seen_at)
         VALUES (?, ?, 'ios', 'old', ?, ?, ?)`,
        ALICE, id, `2026-01-01T00:00:${String(i).padStart(2, "0")}.000Z`, "x", `2026-01-01T00:00:${String(i).padStart(2, "0")}.000Z`,
      );
    }
    await ok(registerPhone());
    const ids = db.query<{ device_id: string }>(`SELECT device_id FROM user_devices WHERE user_id = ?`, ALICE).map((r) => r.device_id);
    expect(ids).toHaveLength(50);
    expect(ids).toContain(PHONE);
    expect(ids).not.toContain("00000000-0000-4000-8000-000000000000"); // the least recently seen
  });

  it("DELETE removes only the caller's device", async () => {
    await ok(registerPhone(ALICE));
    expect(await ok(req("DELETE", `/api/devices/${PHONE}`, { as: BOB }), 404)).toMatchObject({ code: "not_found" });
    expect(await ok(req("DELETE", `/api/devices/${PHONE_UPPER}`))).toEqual({ deleted: true });
    expect(await ok(req("DELETE", `/api/devices/${PHONE}`), 404)).toMatchObject({ code: "not_found" });
    expect((await ok(req("GET", "/api/devices"))).devices).toEqual([]);
    expect((await req("DELETE", "/api/devices/nope")).status).toBe(400);
  });

  it("canPush is false while APNs isn't configured on the server", async () => {
    delete (env as { APNS_KEY?: string }).APNS_KEY;
    expect((await ok(registerPhone())).canPush).toBe(false);
  });

  it("deleting the account deletes its devices and link key (FK cascade)", async () => {
    await ok(registerPhone());
    await ok(req("GET", "/api/wireless/link"));
    await ok(registerPhone(BOB, { apnsToken: TOKEN_2 }, "33333333-4444-4555-8666-777777777777"));
    db.query(`DELETE FROM "user" WHERE id = ?`, ALICE);
    expect(db.query(`SELECT user_id FROM user_devices`)).toEqual([{ user_id: BOB }]);
    expect(db.query(`SELECT COUNT(*) AS n FROM wireless_links`)[0]).toMatchObject({ n: 0 });
  });
});

describe("POST /api/devices/:deviceId/request-broadcast", () => {
  function decodeJwt(jwt: string) {
    const [h, p, s] = jwt.split(".");
    const json = (part: string) => JSON.parse(new TextDecoder().decode(b64urlToBytes(part)));
    return { header: json(h), payload: json(p), signingInput: `${h}.${p}`, signature: b64urlToBytes(s) };
  }

  it("sends the alert to the phone's APNs environment with a valid ES256 provider token", async () => {
    await ok(registerPhone());
    const before = Math.floor(Date.now() / 1000);
    expect(await ok(askToStream(PHONE, { macId: "  B1E2-MAC  ", macName: "Mike's MacBook Pro" }))).toEqual({ sent: true });
    expect(apns.calls).toHaveLength(1);

    const { url, init } = apns.calls[0];
    const target = new URL(url);
    expect(target.host).toBe("api.sandbox.push.apple.com");
    expect(target.pathname).toBe(`/3/device/${TOKEN}`);
    expect(init.method).toBe("POST");
    const h = init.headers;
    expect(h["apns-topic"]).toBe("so.capturecat.ios");
    expect(h["apns-push-type"]).toBe("alert");
    expect(h["apns-priority"]).toBe("10");
    expect(h["apns-collapse-id"]).toBe("broadcast-request");
    expect(h["content-type"]).toBe("application/json");
    const expiration = Number(h["apns-expiration"]);
    expect(expiration).toBeGreaterThanOrEqual(before + 115);
    expect(expiration).toBeLessThanOrEqual(Math.floor(Date.now() / 1000) + 125);

    expect(JSON.parse(String(init.body))).toEqual({
      aps: {
        alert: {
          title: "Stream to Mike's MacBook Pro",
          body: "Tap to share your screen with CaptureCat on Mike's MacBook Pro.",
        },
        category: "CC_BROADCAST_REQUEST",
        "interruption-level": "time-sensitive",
      },
      cc: { type: "requestBroadcast", macId: "b1e2-mac", macName: "Mike's MacBook Pro" },
    });

    expect(h.authorization).toMatch(/^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    const jwt = decodeJwt(h.authorization.slice("bearer ".length));
    expect(jwt.header).toEqual({ alg: "ES256", kid: KEY_ID });
    expect(Object.keys(jwt.payload).sort()).toEqual(["iat", "iss"]);
    expect(jwt.payload.iss).toBe(TEAM_ID);
    expect(Math.abs(jwt.payload.iat - before)).toBeLessThanOrEqual(5);
    expect(jwt.signature.byteLength).toBe(64); // JWS ES256: raw r‖s
    const verified = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      apnsPublicKey,
      jwt.signature,
      new TextEncoder().encode(jwt.signingInput),
    );
    expect(verified).toBe(true);
  });

  it("reuses the provider token, and uses the production host for production tokens", async () => {
    await ok(registerPhone(ALICE, { apnsToken: TOKEN_2, apnsEnvironment: "production" }));
    await ok(askToStream());
    await ok(askToStream());
    expect(apns.calls).toHaveLength(2);
    expect(new URL(apns.calls[1].url).host).toBe("api.push.apple.com");
    expect(new URL(apns.calls[1].url).pathname).toBe(`/3/device/${TOKEN_2}`);
    expect(apns.calls[1].init.headers.authorization).toBe(apns.calls[0].init.headers.authorization);
  });

  it("sanitizes macName (no control characters, at most 60 characters)", async () => {
    await ok(registerPhone());
    await ok(askToStream(PHONE, { macId: "mac-1", macName: `Evil\n\u202EMac\u0007 ${"y".repeat(100)}` }));
    const sent = JSON.parse(String(apns.calls[0].init.body));
    const name: string = sent.cc.macName;
    expect(name).not.toMatch(/[\n\u202E\u0007]/);
    expect(Array.from(name).length).toBeLessThanOrEqual(60);
    expect(name.startsWith("Evil Mac y")).toBe(true);
    expect(sent.aps.alert.title).toBe(`Stream to ${name}`);
  });

  it("validates macId / macName", async () => {
    await ok(registerPhone());
    for (const body of [{ macName: "Mac" }, { macId: "", macName: "Mac" }, { macId: "a b", macName: "Mac" }, { macId: "m".repeat(65), macName: "Mac" }, { macId: "m", macName: " \n " }, { macId: "m" }]) {
      expect((await askToStream(PHONE, body)).status, JSON.stringify(body)).toBe(400);
    }
    expect(apns.calls).toHaveLength(0);
  });

  it("410 Unregistered forgets the token and answers 409 push_unavailable", async () => {
    await ok(registerPhone());
    apns.respond = () => new Response(JSON.stringify({ reason: "Unregistered", timestamp: 1 }), { status: 410 });
    expect(await ok(askToStream(), 409)).toMatchObject({ code: "push_unavailable" });
    expect(db.query(`SELECT apns_token, apns_env FROM user_devices`)[0]).toEqual({ apns_token: null, apns_env: null });
    expect((await ok(req("GET", "/api/devices"))).devices[0].canPush).toBe(false);
    // And no further push is attempted.
    expect(await ok(askToStream(), 409)).toMatchObject({ code: "push_unavailable" });
    expect(apns.calls).toHaveLength(1);
  });

  it("400 BadDeviceToken forgets the token too", async () => {
    await ok(registerPhone());
    apns.respond = () => new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 });
    expect(await ok(askToStream(), 409)).toMatchObject({ code: "push_unavailable" });
    expect(db.query(`SELECT apns_token FROM user_devices`)[0]).toEqual({ apns_token: null });
  });

  it("a transport error is retryable: 502 push_failed, the token is kept", async () => {
    await ok(registerPhone());
    apns.respond = () => {
      throw new TypeError("fetch failed: HTTP/2 not negotiated");
    };
    expect(await ok(askToStream(), 502)).toMatchObject({ code: "push_failed" });
    expect(db.query(`SELECT apns_token FROM user_devices`)[0]).toEqual({ apns_token: TOKEN });
  });

  it("other APNs refusals are 502 and keep the token; an expired provider token is re-minted", async () => {
    await ok(registerPhone());
    apns.respond = () => new Response(JSON.stringify({ reason: "ExpiredProviderToken" }), { status: 403 });
    expect(await ok(askToStream(), 502)).toMatchObject({ code: "push_failed" });
    apns.respond = () => new Response(JSON.stringify({ reason: "TooManyRequests" }), { status: 429 });
    expect(await ok(askToStream(), 502)).toMatchObject({ code: "push_failed" });
    expect(db.query(`SELECT apns_token FROM user_devices`)[0]).toEqual({ apns_token: TOKEN });
    // ECDSA signatures are randomized, so a re-minted token differs.
    expect(apns.calls[1].init.headers.authorization).not.toBe(apns.calls[0].init.headers.authorization);
  });

  it("503 push_not_configured without the APNs secrets", async () => {
    await ok(registerPhone());
    for (const missing of ["APNS_KEY", "APNS_KEY_ID", "APNS_TEAM_ID"] as const) {
      const saved = env[missing];
      delete (env as Partial<Env>)[missing];
      expect(await ok(askToStream(), 503)).toMatchObject({ code: "push_not_configured" });
      (env as Partial<Env>)[missing] = saved;
    }
    expect(apns.calls).toHaveLength(0);
  });

  it("another account's device is 404; a device without a token (or a Mac) is 409", async () => {
    await ok(registerPhone(BOB));
    expect(await ok(askToStream(PHONE, undefined, ALICE), 404)).toMatchObject({ code: "not_found" });
    await ok(registerPhone(ALICE, { apnsToken: undefined, apnsEnvironment: undefined }, "44444444-5555-4666-8777-888888888888"));
    expect(await ok(askToStream("44444444-5555-4666-8777-888888888888"), 409)).toMatchObject({ code: "push_unavailable" });
    await ok(req("PUT", `/api/devices/${MAC}`, { body: { platform: "mac", name: "Studio" } }));
    expect(await ok(askToStream(MAC), 409)).toMatchObject({ code: "push_unavailable" });
    expect(apns.calls).toHaveLength(0);
  });

  it("is rate limited per user (10 a minute)", async () => {
    await ok(registerPhone());
    for (let i = 0; i < 10; i++) await ok(askToStream());
    expect((await askToStream()).status).toBe(429);
    expect(apns.calls).toHaveLength(10);
  });
});
