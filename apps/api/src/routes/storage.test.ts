/**
 * Bring-your-own bucket (migration 0029), end to end through the REAL routes,
 * plan rows, storage sum and credential encryption (node:sqlite over the real
 * migrations). Faked: the session store, the S3 calls (recorded with the
 * bucket + endpoint they were aimed at, so a test can prove WHICH bucket got
 * a presign/HEAD/DELETE), CaptureCat R2 (in memory), the Cache API and fetch.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { storageUsageBytes } from "../lib/db";

vi.mock("../lib/auth", () => import("../test-support/fake-session"));

type S3Call = { op: string; bucket: string; endpoint?: string; region?: string; key: string; secret?: string };
const s3 = vi.hoisted(() => ({
  calls: [] as S3Call[],
  /** `${bucket}/${key}` → size, for HEAD. */
  objects: new Map<string, number>(),
  failPut: null as null | Error,
}));
vi.mock("../lib/presign", () => {
  const rec = (op: string, o: { bucket: string; endpoint?: string; region?: string; key: string; secretAccessKey?: string }) =>
    s3.calls.push({ op, bucket: o.bucket, endpoint: o.endpoint, region: o.region, key: o.key, secret: o.secretAccessKey });
  return {
    createPresignedUploadUrl: vi.fn(async (o: { bucket: string; key: string }) => {
      rec("presignPut", o);
      return `https://${o.bucket}.s3.test/${o.key}?put`;
    }),
    createPresignedDownloadUrl: vi.fn(async (o: { bucket: string; key: string; responseContentDisposition?: string }) => {
      rec("presignGet", o);
      return `https://${o.bucket}.s3.test/${o.key}?get${o.responseContentDisposition ? "&attachment" : ""}`;
    }),
    headR2ObjectMeta: vi.fn(async (o: { bucket: string; key: string }) => {
      rec("head", o);
      const size = s3.objects.get(`${o.bucket}/${o.key}`);
      return size === undefined ? null : { size, etag: `etag-${o.key}` };
    }),
    headR2Object: vi.fn(async () => null),
    putS3Object: vi.fn(async (o: { bucket: string; key: string }) => {
      rec("put", o);
      if (s3.failPut) throw s3.failPut;
      s3.objects.set(`${o.bucket}/${o.key}`, 24);
    }),
    deleteS3Object: vi.fn(async (o: { bucket: string; key: string }) => {
      rec("delete", o);
      s3.objects.delete(`${o.bucket}/${o.key}`);
    }),
  };
});

vi.stubGlobal("caches", {
  default: { match: async () => undefined, put: async () => undefined, delete: async () => true },
});
const fetched = vi.hoisted(() => [] as string[]);
vi.stubGlobal(
  "fetch",
  vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input instanceof Request ? input.url : input);
    fetched.push(url);
    // The public-URL check: a CDN that serves the test object.
    if (url.startsWith("https://cdn.example.com/")) return new Response("capturecat storage check");
    return new Response("nope", { status: 403 });
  }),
);

const { storageRoutes } = await import("./storage");
const { uploadRoutes } = await import("./upload");
const { videoRoutes } = await import("./video");
const { deleteRoutes } = await import("./delete");

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

const USER = "storage-user";
const FREE = "free-user";
const SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
let db: TestD1;
let r2: MemoryBucket;
let env: Env;
let app: Hono<{ Bindings: Env; Variables: Variables }>;

beforeEach(() => {
  s3.calls.length = 0;
  s3.objects.clear();
  s3.failPut = null;
  fetched.length = 0;
  db = createTestD1();
  r2 = new MemoryBucket();
  env = {
    DB: db,
    R2: r2 as unknown as R2Bucket,
    R2_ENDPOINT: "https://account.r2.test",
    R2_ACCESS_KEY_ID: "k",
    R2_SECRET_ACCESS_KEY: "s",
    BETTER_AUTH_URL: "https://api.capturecat.so",
    BETTER_AUTH_SECRET: "test-secret",
    ATTEST_MODE: "off",
    STORAGE_CREDENTIALS_KEY: btoa(String.fromCharCode(...new Uint8Array(32).fill(7))),
  } as unknown as Env;
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  for (const r of [storageRoutes, uploadRoutes, videoRoutes, deleteRoutes]) app.route("/api", r);

  const now = new Date().toISOString();
  // USER is a tester → the pro plan row. FREE has no subscription.
  for (const [uid, tester] of [[USER, 1], [FREE, 0]] as const) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
       VALUES (?, ?, ?, 1, ?, ?, ?, 0)`,
      uid, uid, `${uid}@test.local`, now, now, tester,
    );
  }
});

function enableCustomStorage(on = true) {
  db.query(`UPDATE plan SET features = json_set(features, '$.customStorage', json(?)) WHERE name = 'pro'`, on ? "true" : "false");
}

function call(method: string, path: string, body?: unknown, uid: string | null = USER) {
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

const r2Bucket = {
  provider: "r2",
  endpoint: "https://acct123.r2.cloudflarestorage.com",
  region: "auto",
  bucket: "my-videos",
  pathPrefix: "capturecat",
  accessKeyId: "AKIAEXAMPLE12345678",
  secretAccessKey: SECRET,
};

async function connect(body: Record<string, unknown> = r2Bucket) {
  const res = await call("PUT", "/storage/bucket", body);
  expect(res.status, await res.clone().text()).toBe(200);
  return res.json() as Promise<{ bucket: { id: string; accessKeyIdHint: string; pathPrefix: string } }>;
}

/** Presign → client PUT (simulated) → complete. */
async function share(size = 1000) {
  const res = await call("POST", "/upload/video", {
    fileName: "demo.mp4",
    contentType: "video/mp4",
    fileSizeBytes: size,
    durationSeconds: 10,
  });
  expect(res.status, await res.clone().text()).toBe(200);
  const body = (await res.json()) as { videoId: string; uploadUrl: string; r2Key: string; storage: string };
  const presign = s3.calls.find((c) => c.op === "presignPut" && c.key === body.r2Key)!;
  if (presign.bucket === "capturecat") r2.objects.set(body.r2Key, new Uint8Array(size));
  s3.objects.set(`${presign.bucket}/${body.r2Key}`, size);
  const done = await call("POST", `/upload/video/${body.videoId}/complete`);
  expect(done.status, await done.clone().text()).toBe(200);
  return { ...body, bucket: presign.bucket };
}

describe("the paid gate", () => {
  it("migrations grant custom storage to every paid plan and never to free", () => {
    const rows = db.query<{ name: string; enabled: number | null }>(
      `SELECT name, json_extract(features, '$.customStorage') AS enabled FROM plan ORDER BY name`,
    );
    expect(Object.fromEntries(rows.map((r) => [r.name, r.enabled === 1]))).toEqual({
      business: true,
      free: false,
      pro: true,
    });
  });

  it("EXPLOIT: a free account cannot connect a bucket or presign into one", async () => {
    expect(((await (await call("GET", "/storage/bucket", undefined, FREE)).json()) as { enabled: boolean }).enabled).toBe(false);
    expect((await call("PUT", "/storage/bucket", r2Bucket, FREE)).status).toBe(402);
    expect((await call("POST", "/storage/bucket/cors-probe", undefined, FREE)).status).toBe(402);
    expect(s3.calls).toEqual([]);
    expect(db.query(`SELECT COUNT(*) AS n FROM storage_buckets`)[0]).toEqual({ n: 0 });
  });

  it("EXPLOIT: a bucket row planted for a free account is never used for uploads", async () => {
    // Connected while paid, then lapsed (or written by hand): the upload
    // routes re-check the plan on every presign.
    enableCustomStorage();
    await connect();
    enableCustomStorage(false);
    const res = await call("POST", "/upload/video", {
      fileName: "x.mp4", contentType: "video/mp4", fileSizeBytes: 10, durationSeconds: 1,
    });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { storage: string }).storage).toBe("capturecat");
    expect((await call("POST", "/storage/bucket/cors-probe")).status).toBe(402);
  });
});

describe("connecting a bucket", () => {
  it("is unavailable, not insecure, without STORAGE_CREDENTIALS_KEY", async () => {
    enableCustomStorage();
    env = { ...env, STORAGE_CREDENTIALS_KEY: undefined } as Env;
    expect((await call("PUT", "/storage/bucket", r2Bucket)).status).toBe(503);
    expect(db.query(`SELECT COUNT(*) AS n FROM storage_buckets`)[0]).toEqual({ n: 0 });
  });

  it("test-writes, reads and deletes an object, then stores the secret encrypted only", async () => {
    enableCustomStorage();
    const state = await connect();
    expect(s3.calls.map((c) => c.op)).toEqual(["put", "head", "delete"]);
    expect(s3.calls.every((c) => c.bucket === "my-videos" && c.endpoint === r2Bucket.endpoint)).toBe(true);
    expect(s3.calls[0].key.startsWith("capturecat/.capturecat-check-")).toBe(true);
    expect(s3.objects.size).toBe(0);

    expect(state.bucket.pathPrefix).toBe("capturecat/");
    expect(state.bucket.accessKeyIdHint).toBe("AKIA…5678");
    const raw = JSON.stringify(db.query(`SELECT * FROM storage_buckets`));
    expect(raw).not.toContain(SECRET);
    const text = await (await call("GET", "/storage/bucket")).text();
    expect(text).not.toContain(SECRET);
    expect(text).not.toContain("AKIAEXAMPLE12345678");
  });

  it("saves nothing when the bucket refuses, and says why", async () => {
    enableCustomStorage();
    s3.failPut = Object.assign(new Error("Access Denied"), { name: "AccessDenied" });
    const res = await call("PUT", "/storage/bucket", r2Bucket);
    expect(res.status).toBe(422);
    expect(await res.json()).toMatchObject({ code: "verify_failed", step: "write" });
    expect(db.query(`SELECT COUNT(*) AS n FROM storage_buckets`)[0]).toEqual({ n: 0 });
  });

  it.each([
    [{ endpoint: "http://acct.r2.cloudflarestorage.com" }, "https"],
    [{ endpoint: "https://10.0.0.5" }, "https"],
    [{ endpoint: "https://localhost" }, "https"],
    [{ endpoint: "https://acct.r2.cloudflarestorage.com/my-videos" }, "host only"],
    [{ provider: "aws", endpoint: "https://evil.example.com" }, "AWS"],
    [{ pathPrefix: "a/../b" }, ".."],
    [{ publicBaseUrl: "http://cdn.example.com" }, "Public URL"],
  ])("rejects %o", async (patch, message) => {
    enableCustomStorage();
    const res = await call("PUT", "/storage/bucket", { ...r2Bucket, ...patch });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toContain(message);
    expect(s3.calls).toEqual([]);
  });

  it("checks a public base URL serves the bucket before accepting it", async () => {
    enableCustomStorage();
    const bad = await call("PUT", "/storage/bucket", { ...r2Bucket, publicBaseUrl: "https://private.example.com" });
    expect(bad.status).toBe(422);
    expect(await bad.json()).toMatchObject({ step: "public_url" });
    expect(s3.objects.size).toBe(0); // the test object was still cleaned up
    await connect({ ...r2Bucket, publicBaseUrl: "https://cdn.example.com/" });
  });
});

describe("share uploads with a bucket connected", () => {
  it("presign, verify and playback all go to the user's bucket, outside the CaptureCat quota", async () => {
    enableCustomStorage();
    await connect();
    const shared = await share(5000);
    expect(shared.bucket).toBe("my-videos");
    expect(shared.storage).toBe("custom");
    expect(shared.r2Key).toBe(`capturecat/videos/${shared.videoId}.mp4`);
    expect(s3.calls.find((c) => c.op === "head" && c.key === shared.r2Key)?.bucket).toBe("my-videos");
    // The presign was signed with the decrypted secret.
    expect(s3.calls.find((c) => c.op === "presignPut")?.secret).toBe(SECRET);
    expect(await storageUsageBytes(db, USER)).toBe(0);

    const stream = await call("GET", `/video/${shared.videoId}`, undefined, null);
    expect(stream.status).toBe(302);
    expect(stream.headers.get("Location")).toBe(`https://my-videos.s3.test/${shared.r2Key}?get`);
    expect(stream.headers.get("Cache-Control")).toBe("private, no-store");
  });

  it("is not exempt from the per-file cap, only the storage total", async () => {
    enableCustomStorage();
    db.query(
      `UPDATE plan SET limits = json_set(limits, '$.maxTotalStorageBytes', 10, '$.maxFileSizeBytes', 100000) WHERE name = 'pro'`,
    );
    await connect();
    await share(50_000); // far over the 10-byte total: fine, it is their bucket
    const tooBig = await call("POST", "/upload/video", {
      fileName: "x.mp4", contentType: "video/mp4", fileSizeBytes: 200_000, durationSeconds: 1,
    });
    expect(tooBig.status).toBe(413);
  });

  it("plays through the public base URL when one is set", async () => {
    enableCustomStorage();
    await connect({ ...r2Bucket, publicBaseUrl: "https://cdn.example.com/media" });
    const shared = await share();
    const stream = await call("GET", `/video/${shared.videoId}`, undefined, null);
    expect(stream.headers.get("Location")).toBe(`https://cdn.example.com/media/${shared.r2Key}`);
  });

  it("still applies share gates before redirecting", async () => {
    enableCustomStorage();
    await connect();
    const shared = await share();
    db.query(`UPDATE shared_videos SET is_private = 1 WHERE video_id = ?`, shared.videoId);
    expect((await call("GET", `/video/${shared.videoId}`, undefined, null)).status).toBe(403);
  });

  it("deleting the share deletes the file from the user's bucket", async () => {
    enableCustomStorage();
    await connect();
    const shared = await share();
    const res = await call("DELETE", `/video/${shared.videoId}`);
    expect(res.status).toBe(200);
    expect(s3.calls.some((c) => c.op === "delete" && c.bucket === "my-videos" && c.key === shared.r2Key)).toBe(true);
    expect(db.query(`SELECT COUNT(*) AS n FROM shared_videos`)[0]).toEqual({ n: 0 });
  });

  it("disconnecting sends new uploads back to CaptureCat; old videos keep playing from the bucket", async () => {
    enableCustomStorage();
    await connect();
    const before = await share();
    const res = await call("DELETE", "/storage/bucket");
    expect(await res.json()).toEqual({ disconnected: true, retained: true, videoCount: 1 });

    const after = await share(700);
    expect(after.bucket).toBe("capturecat");
    expect(after.r2Key).toBe(`videos/${after.videoId}.mp4`);
    expect(await storageUsageBytes(db, USER)).toBe(700);

    const old = await call("GET", `/video/${before.videoId}`, undefined, null);
    expect(old.status).toBe(302);
    expect(old.headers.get("Location")).toContain("my-videos");
    expect(((await (await call("GET", "/storage/bucket")).json()) as { retainedCount: number }).retainedCount).toBe(1);
  });

  it("a downgrade uploads to CaptureCat again without losing the bucket's videos", async () => {
    enableCustomStorage();
    await connect();
    const before = await share();
    enableCustomStorage(false);
    expect((await share()).bucket).toBe("capturecat");
    expect((await call("GET", `/video/${before.videoId}`, undefined, null)).status).toBe(302);
  });

  it("a replace after connecting puts v2 in the bucket while v1 stays in R2", async () => {
    enableCustomStorage(false);
    const v1 = await share(300); // plan without the gate → CaptureCat R2
    expect(v1.bucket).toBe("capturecat");
    enableCustomStorage();
    await connect();
    const rep = await call("POST", `/upload/video/${v1.videoId}/replace`, {
      contentType: "video/mp4", fileSizeBytes: 400, durationSeconds: 5,
    });
    expect(rep.status, await rep.clone().text()).toBe(200);
    const { r2Key, version } = (await rep.json()) as { r2Key: string; version: number };
    expect(r2Key).toBe(`capturecat/videos/${v1.videoId}/v2.mp4`);
    s3.objects.set(`my-videos/${r2Key}`, 400);
    expect((await call("POST", `/upload/video/${v1.videoId}/replace/${version}/complete`, {})).status).toBe(200);

    // Current → the bucket; the quota still counts only v1's R2 bytes.
    expect((await call("GET", `/video/${v1.videoId}`, undefined, null)).headers.get("Location")).toContain("my-videos");
    expect(await storageUsageBytes(db, USER)).toBe(300);
    // The owner can still pin v1, served from R2 bytes.
    const pinned = await call("GET", `/video/${v1.videoId}?v=1`);
    expect(pinned.status).toBe(200);
  });

  it("reconnecting the same bucket and folder updates the row in place", async () => {
    enableCustomStorage();
    const first = await connect();
    await share();
    const again = await connect({ ...r2Bucket, accessKeyId: "AKIAROTATED000009999" });
    expect(again.bucket.id).toBe(first.bucket.id);
    expect(again.bucket.accessKeyIdHint).toBe("AKIA…9999");
    expect(db.query(`SELECT COUNT(*) AS n FROM storage_buckets`)[0]).toEqual({ n: 1 });
  });

  it("switching buckets retains the old one only while videos use it", async () => {
    enableCustomStorage();
    await connect();
    await connect({ ...r2Bucket, bucket: "other-bucket" }); // first had no videos → dropped
    expect(db.query(`SELECT bucket, active FROM storage_buckets`)).toEqual([{ bucket: "other-bucket", active: 1 }]);
    await share();
    await connect({ ...r2Bucket, bucket: "third-bucket" });
    expect(db.query(`SELECT bucket, active FROM storage_buckets ORDER BY bucket`)).toEqual([
      { bucket: "other-bucket", active: 0 },
      { bucket: "third-bucket", active: 1 },
    ]);
  });
});
