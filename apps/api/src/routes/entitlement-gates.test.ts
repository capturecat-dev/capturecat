/**
 * Paid-feature gates on the share/upload/AI routes, through the REAL
 * requireAuth + requireEntitlement + plan rows + storage sum (node:sqlite over
 * the real migrations). Faked: the session store (bearer token = uid, the user
 * row read from D1), the S3 presigner/HEAD, R2 (in memory), the Cache API
 * (always miss) and `fetch` (nothing may leave the process).
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { storageUsageBytes } from "../lib/db";

vi.mock("../lib/auth", () => import("../test-support/fake-session"));

const heads = vi.hoisted(() => new Map<string, number>());
vi.mock("../lib/presign", () => ({
  createPresignedUploadUrl: vi.fn(async (o: { key: string }) => `https://r2.test/${o.key}?put`),
  createPresignedDownloadUrl: vi.fn(async (o: { key: string }) => `https://r2.test/${o.key}?get`),
  headR2ObjectMeta: vi.fn(async (o: { key: string }) => {
    const size = heads.get(o.key);
    return size === undefined ? null : { size, etag: `etag-${o.key}` };
  }),
  headR2Object: vi.fn(async (o: { key: string }) => heads.get(o.key) ?? null),
}));

vi.stubGlobal("caches", {
  default: { match: async () => undefined, put: async () => undefined, delete: async () => true },
});
const outbound = vi.hoisted(() => [] as string[]);
vi.stubGlobal(
  "fetch",
  vi.fn(async (input: RequestInfo | URL) => {
    outbound.push(String(input instanceof Request ? input.url : input));
    return new Response("{}", { status: 500 });
  }),
);

const { aiRoutes } = await import("./ai");
const { videoRoutes } = await import("./video");
const { uploadRoutes } = await import("./upload");

class MemoryBucket {
  objects = new Map<string, Uint8Array>();
  async get(key: string) {
    const bytes = this.objects.get(key);
    if (!bytes) return null;
    return { key, size: bytes.byteLength, etag: `etag-${key}`, body: new Response(bytes).body!, range: undefined };
  }
  async put(key: string, value: Uint8Array) {
    this.objects.set(key, value);
  }
  async delete(keys: string | string[]) {
    for (const k of Array.isArray(keys) ? keys : [keys]) this.objects.delete(k);
  }
}

const PRO = "pro-user";
const BIZ = "business-user";
const MEMBER = "team-member";
const ORG = "org1";

let db: TestD1;
let bucket: MemoryBucket;
let env: Env;
let app: Hono<{ Bindings: Env; Variables: Variables }>;

beforeEach(() => {
  outbound.length = 0;
  heads.clear();
  db = createTestD1();
  bucket = new MemoryBucket();
  env = {
    DB: db,
    R2: bucket as unknown as R2Bucket,
    R2_ENDPOINT: "https://account.r2.test",
    R2_ACCESS_KEY_ID: "k",
    R2_SECRET_ACCESS_KEY: "s",
    BETTER_AUTH_URL: "https://api.capturecat.so",
    BETTER_AUTH_SECRET: "test-secret",
    ATTEST_MODE: "off",
    GEMINI_API_KEY: undefined,
  } as unknown as Env;
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  app.route("/api", aiRoutes);
  app.route("/api", videoRoutes);
  app.route("/api", uploadRoutes);

  const now = new Date().toISOString();
  // PRO and MEMBER are testers (→ the pro plan row); BIZ pays for Business.
  for (const [uid, tester] of [[PRO, 1], [BIZ, 0], [MEMBER, 1]] as const) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
       VALUES (?, ?, ?, 1, ?, ?, ?, 0)`,
      uid, uid, `${uid}@test.local`, now, now, tester,
    );
  }
  db.query(`UPDATE plan SET is_active = 1 WHERE name = 'business'`);
  db.query(
    `INSERT INTO "subscription" (id, plan, referenceId, stripeCustomerId, stripeSubscriptionId, status, periodEnd)
     VALUES ('row_biz', 'business', ?, 'cus_biz', 'sub_biz', 'active', ?)`,
    BIZ, new Date(Date.now() + 20 * 86_400_000).toISOString(),
  );
  db.query(`INSERT INTO "organization" (id, name, slug, createdAt) VALUES (?, 'Team', 'team', ?)`, ORG, now);
  for (const uid of [PRO, MEMBER]) {
    db.query(
      `INSERT INTO "member" (id, organizationId, userId, role, createdAt) VALUES (?, ?, ?, 'member', ?)`,
      `m-${uid}`, ORG, uid, now,
    );
  }
});

function call(uid: string | null, method: string, path: string, body?: unknown) {
  const headers: Record<string, string> = {};
  if (uid) headers["Authorization"] = `Bearer ${uid}`;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  return app.request(
    `/api${path}`,
    { method, headers, body: body === undefined ? undefined : JSON.stringify(body) },
    env,
    { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext,
  );
}

function setLimits(plan: string, limits: Record<string, number>) {
  for (const [k, v] of Object.entries(limits)) {
    db.query(`UPDATE plan SET limits = json_set(limits, ?, ?) WHERE name = ?`, `$.${k}`, v, plan);
  }
}

describe("server-side AI (/ai/generate)", () => {
  it("EXPLOIT: a plan without aiSummaries (Pro) cannot use the owner-billed Gemini proxy", async () => {
    const res = await call(PRO, "POST", "/ai/generate", { prompt: "write my homework" });
    expect(res.status).toBe(402);
    expect(outbound).toEqual([]);
  });

  it("a plan WITH aiSummaries passes the gate (and then needs the key)", async () => {
    const res = await call(BIZ, "POST", "/ai/generate", { prompt: "title this" });
    expect(res.status).toBe(503); // past the plan gate; no GEMINI_API_KEY in tests
    expect(outbound).toEqual([]);
  });
});

describe("private team videos stream only while the uploader's plan includes teams", () => {
  function privateTeamVideo() {
    db.query(
      `INSERT INTO shared_videos (video_id, uid, file_name, r2_key, url, is_private, status, created_at, org_id)
       VALUES ('v1', ?, 'demo.mp4', 'videos/v1.mp4', 'https://capturecat.so/share/v1', 1, 'ready', ?, ?)`,
      PRO, new Date().toISOString(), ORG,
    );
    bucket.objects.set("videos/v1.mp4", new TextEncoder().encode("movie-bytes"));
  }

  it("EXPLOIT: after the uploader lapses, teammates can no longer stream it (the uploader still can)", async () => {
    privateTeamVideo();
    expect((await call(MEMBER, "GET", "/video/v1")).status).toBe(200);
    // One month of Pro must not buy permanent team hosting on the free tier.
    db.query(`UPDATE "user" SET tester = 0 WHERE id = ?`, PRO);
    expect((await call(MEMBER, "GET", "/video/v1")).status).toBe(403);
    expect((await call(PRO, "GET", "/video/v1")).status).toBe(200);
    expect((await call(null, "GET", "/video/v1")).status).toBe(403);
  });
});

describe("share uploads: storage cap under concurrency", () => {
  function pendingUpload(videoId: string, bytes: number) {
    const now = new Date().toISOString();
    db.query(
      `INSERT INTO shared_videos (video_id, uid, file_name, r2_key, url, status, created_at)
       VALUES (?, ?, 'x.mp4', ?, 'u', 'pending', ?)`,
      videoId, PRO, `videos/${videoId}.mp4`, now,
    );
    db.query(
      `INSERT INTO video_versions (version_id, video_id, version_number, r2_key, status, created_at)
       VALUES (?, ?, 1, ?, 'pending', ?)`,
      `v1-${videoId}`, videoId, `videos/${videoId}.mp4`, now,
    );
    heads.set(`videos/${videoId}.mp4`, bytes);
  }

  it("EXPLOIT: concurrent /complete calls cannot each fit under the cap and all land", async () => {
    setLimits("pro", { maxTotalStorageBytes: 100, maxFileSizeBytes: 100 });
    pendingUpload("a", 60);
    pendingUpload("b", 60);
    const [a, b] = await Promise.all([
      call(PRO, "POST", "/upload/video/a/complete"),
      call(PRO, "POST", "/upload/video/b/complete"),
    ]);
    expect([a.status, b.status].sort()).toEqual([200, 413]);
    expect(await storageUsageBytes(db, PRO)).toBe(60);
  });
});
