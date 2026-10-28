/**
 * Moderation end to end through the REAL Worker entry (mounting, CORS, the
 * admin role gate, requireAuth): a viewer reports a share, the admin console
 * lists it, takes it down — and every public surface then answers "removed"
 * while the owner still sees it with the reason — then restores, dismisses
 * and deletes. Migrations run for real (node:sqlite); R2 is in memory.
 * `Authorization: Bearer <uid>` is that user's session (fake-session).
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { MemoryBucket } from "../test-support/memory-bucket";
import { REMOVED_MESSAGE } from "../lib/moderation";
import { REPORT_RATE_LIMIT } from "./video-report";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });
vi.stubGlobal("fetch", vi.fn(async () => {
  throw new Error("offline test: unexpected fetch");
}));

const { default: worker } = await import("../index");

const API = "https://api.capturecat.so";
const ADMIN = "admin-1";
const OWNER = "owner-1";
const OTHER = "viewer-1";
const VIDEO = "vidMod1";
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

let db: TestD1;
let env: Env;
let r2: MemoryBucket;

function addUser(id: string, email: string, role = "user", tester = 1) {
  const now = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked, role, username)
     VALUES (?, ?, ?, 1, ?, ?, ?, 0, ?, ?)`,
    id, email.split("@")[0], email, now, now, tester, role, id.replace(/[^a-z0-9]/g, ""),
  );
}

function addVideo(videoId: string, opts: { isPrivate?: boolean; createdAt?: string; title?: string } = {}) {
  db.query(
    `INSERT INTO shared_videos (video_id, uid, file_name, r2_key, url, status, created_at, duration_seconds, file_size_bytes, is_private, comments_enabled, profile_visible)
     VALUES (?, ?, ?, ?, 'u', 'ready', ?, 12, 10, ?, 1, 1)`,
    videoId, OWNER, opts.title ?? `${videoId}.mp4`, `videos/${videoId}.mp4`, opts.createdAt ?? new Date().toISOString(), opts.isPrivate ? 1 : 0,
  );
  void r2.put(`videos/${videoId}.mp4`, "0123456789");
}

beforeEach(() => {
  db = createTestD1();
  r2 = new MemoryBucket();
  env = {
    DB: db,
    R2: r2,
    BETTER_AUTH_URL: API,
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
  } as unknown as Env;
  addUser(ADMIN, "admin@test.local", "admin");
  addUser(OWNER, "owner@test.local");
  addUser(OTHER, "viewer@test.local");
  addVideo(VIDEO, { title: "Quarterly demo.mp4" });
});

function req(method: string, path: string, init: { as?: string; json?: unknown; headers?: Record<string, string> } = {}) {
  const headers: Record<string, string> = { "CF-Connecting-IP": "203.0.113.7", ...init.headers };
  if (init.as) headers.Authorization = `Bearer ${init.as}`;
  let body: string | undefined;
  if (init.json !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(init.json);
  }
  return worker.fetch(new Request(`${API}${path}`, { method, headers, body, redirect: "manual" }), env, ctx);
}

const report = (videoId = VIDEO, json: unknown = { reason: "spam", details: "Link farm" }, ip = "203.0.113.7") =>
  req("POST", `/api/video/${videoId}/report`, { json, headers: { "CF-Connecting-IP": ip } });

describe("viewer reports", () => {
  it("anyone who can watch a share can report it; a repeat updates the open report", async () => {
    expect((await report()).status).toBe(201);
    expect((await report(VIDEO, { reason: "sexual" })).status).toBe(201);
    const rows = db.query(`SELECT reason, details, reporter_hash FROM video_reports WHERE video_id = ?`, VIDEO) as Array<{ reason: string; details: string | null; reporter_hash: string }>;
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ reason: "sexual", details: null });
    // Only a hash of who reported — never the IP.
    expect(rows[0]!.reporter_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(rows)).not.toContain("203.0.113.7");
    // A different reporter is a second report.
    expect((await report(VIDEO, { reason: "spam" }, "198.51.100.4")).status).toBe(201);
    expect(db.query(`SELECT id FROM video_reports`)).toHaveLength(2);
  });

  it("validates the reason and refuses private, missing and over-limit reports", async () => {
    expect((await report(VIDEO, { reason: "boring" })).status).toBe(400);
    expect((await report(VIDEO, { reason: "other", details: "x".repeat(1001) })).status).toBe(400);
    addVideo("vidPriv", { isPrivate: true });
    expect((await report("vidPriv")).status).toBe(404);
    expect((await report("nope")).status).toBe(404);
    // Refused requests above never counted: exactly REPORT_RATE_LIMIT get through.
    for (let i = 0; i < REPORT_RATE_LIMIT; i++) expect((await report()).status).toBe(201);
    expect((await report()).status).toBe(429);
  });
});

describe("admin videos", () => {
  it("is invisible to non-admins", async () => {
    for (const who of [OWNER, OTHER, undefined]) {
      expect((await req("GET", "/api/admin/videos", { as: who })).status, String(who)).toBe(who ? 404 : 401);
    }
  });

  it("lists every upload newest first with its owner, and the Reported queue", async () => {
    addVideo("vidOld", { createdAt: "2026-01-01T00:00:00.000Z" });
    addVideo("vidPriv", { isPrivate: true });
    await report();
    const all = (await (await req("GET", "/api/admin/videos", { as: ADMIN })).json()) as {
      videos: Array<{ videoId: string; owner: { email: string }; openReports: number; visibility: string; title: string }>;
      counts: { all: number; reported: number; removed: number };
    };
    expect(all.videos.map((v) => v.videoId).at(-1)).toBe("vidOld");
    expect(all.videos.find((v) => v.videoId === VIDEO)).toMatchObject({ owner: { email: "owner@test.local" }, openReports: 1, title: "Quarterly demo.mp4" });
    expect(all.videos.find((v) => v.videoId === "vidPriv")?.visibility).toBe("private");
    expect(all.counts).toEqual({ all: 3, reported: 1, removed: 0 });

    const reported = (await (await req("GET", "/api/admin/videos?filter=reported", { as: ADMIN })).json()) as { videos: Array<{ videoId: string }> };
    expect(reported.videos.map((v) => v.videoId)).toEqual([VIDEO]);
    const search = (await (await req("GET", "/api/admin/videos?q=owner%40test", { as: ADMIN })).json()) as { videos: unknown[] };
    expect(search.videos).toHaveLength(3);
    const byTitle = (await (await req("GET", "/api/admin/videos?q=Quarterly", { as: ADMIN })).json()) as { videos: Array<{ videoId: string }> };
    expect(byTitle.videos.map((v) => v.videoId)).toEqual([VIDEO]);
  });

  it("pages the full list with a cursor", async () => {
    for (let i = 0; i < 5; i++) addVideo(`vidP${i}`, { createdAt: `2026-02-0${i + 1}T00:00:00.000Z` });
    const seen: string[] = [];
    let cursor: string | null = null;
    do {
      const res = await req("GET", `/api/admin/videos?limit=2${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`, { as: ADMIN });
      const page = (await res.json()) as { videos: Array<{ videoId: string }>; nextCursor: string | null };
      seen.push(...page.videos.map((v) => v.videoId));
      cursor = page.nextCursor;
    } while (cursor);
    expect(seen).toHaveLength(6);
    expect(new Set(seen).size).toBe(6);
  });

  it("takes a video down everywhere public, keeps the file, and the owner still sees it with the reason", async () => {
    await report();
    expect((await req("POST", `/api/admin/videos/${VIDEO}/remove`, { as: ADMIN, json: {} })).status).toBe(400);
    expect((await req("POST", `/api/admin/videos/${VIDEO}/remove`, { as: ADMIN, json: { reason: "Spam links" } })).status).toBe(200);

    // Every public surface: removed.
    for (const [method, path] of [
      ["GET", `/api/video/${VIDEO}`],
      ["GET", `/api/video/${VIDEO}/meta`],
      ["POST", `/api/video/${VIDEO}/report`],
    ] as const) {
      const res = await req(method, path, { json: method === "POST" ? { reason: "spam" } : undefined });
      expect(res.status, path).toBe(410);
      expect(await res.json(), path).toEqual({ error: "removed", message: REMOVED_MESSAGE });
    }
    for (const path of [`/api/video/${VIDEO}/comments`, `/api/video/${VIDEO}/transcript`, `/api/video/${VIDEO}/reactions`]) {
      expect((await req("GET", path)).status, path).toBe(404);
    }
    expect((await req("POST", `/api/video/${VIDEO}/analytics`, { json: { events: [] } })).status).toBe(404);
    // A signed-in stranger is still a stranger.
    expect((await req("GET", `/api/video/${VIDEO}`, { as: OTHER })).status).toBe(410);

    // The file is kept; the owner's dashboard shows why.
    expect(await r2.head(`videos/${VIDEO}.mp4`)).not.toBeNull();
    const mine = (await (await req("GET", "/api/videos", { as: OWNER })).json()) as { videos: Array<{ videoId: string; removed: { reason: string } | null }> };
    expect(mine.videos.find((v) => v.videoId === VIDEO)?.removed?.reason).toBe("Spam links");

    // Reports closed as removed; the action audited; the queue is empty.
    expect(db.query(`SELECT resolution FROM video_reports WHERE video_id = ?`, VIDEO)).toEqual([{ resolution: "removed" }]);
    expect(db.query(`SELECT action, reason, admin_uid FROM moderation_actions`)).toEqual([{ action: "remove", reason: "Spam links", admin_uid: ADMIN }]);
    const counts = ((await (await req("GET", "/api/admin/videos", { as: ADMIN })).json()) as { counts: object }).counts;
    expect(counts).toEqual({ all: 1, reported: 0, removed: 1 });

    // The console's player still streams it — ranged, never cacheable.
    const ranged = await req("GET", `/api/admin/videos/${VIDEO}/stream`, { as: ADMIN, headers: { Range: "bytes=2-5" } });
    expect(ranged.status).toBe(206);
    expect(ranged.headers.get("Content-Range")).toBe("bytes 2-5/10");
    expect(ranged.headers.get("Cache-Control")).toBe("private, no-store");
    expect(await ranged.text()).toBe("2345");
    expect((await req("GET", `/api/admin/videos/${VIDEO}/stream`, { as: OWNER })).status).toBe(404);

    // Restore: public again.
    expect((await req("POST", `/api/admin/videos/${VIDEO}/restore`, { as: ADMIN })).status).toBe(200);
    expect((await req("GET", `/api/video/${VIDEO}/meta`)).status).toBe(200);
    expect((await req("POST", `/api/admin/videos/${VIDEO}/restore`, { as: ADMIN })).status).toBe(409);
  });

  it("drops a removed video from its owner's public profile", async () => {
    const listed = async () => {
      const res = await req("GET", `/api/u/${OWNER.replace(/[^a-z0-9]/g, "")}`);
      expect(res.status).toBe(200);
      const body = (await res.json()) as { videos: Array<{ videoId: string }> };
      return body.videos.map((v) => v.videoId);
    };
    expect(await listed()).toContain(VIDEO);
    await req("POST", `/api/admin/videos/${VIDEO}/remove`, { as: ADMIN, json: { reason: "Hate" } });
    expect(await listed()).not.toContain(VIDEO);
  });

  it("dismisses reports without touching the video, and deletes for good", async () => {
    await report();
    const dismissed = (await (await req("POST", `/api/admin/videos/${VIDEO}/dismiss`, { as: ADMIN })).json()) as { dismissed: number };
    expect(dismissed.dismissed).toBe(1);
    expect((await req("GET", `/api/video/${VIDEO}/meta`)).status).toBe(200);

    const detail = (await (await req("GET", `/api/admin/videos/${VIDEO}`, { as: ADMIN })).json()) as {
      reports: Array<{ reasonLabel: string; resolution: string }>;
      history: Array<{ action: string; adminEmail: string }>;
    };
    expect(detail.reports).toEqual([expect.objectContaining({ reasonLabel: "Spam or misleading", resolution: "dismissed" })]);
    expect(detail.history).toEqual([expect.objectContaining({ action: "dismiss", adminEmail: "admin@test.local" })]);

    expect((await req("DELETE", `/api/admin/videos/${VIDEO}`, { as: ADMIN })).status).toBe(200);
    expect(db.query(`SELECT video_id FROM shared_videos WHERE video_id = ?`, VIDEO)).toEqual([]);
    expect(await r2.head(`videos/${VIDEO}.mp4`)).toBeNull();
    // The audit trail outlives the video.
    expect(db.query(`SELECT action FROM moderation_actions WHERE video_id = ? ORDER BY created_at`, VIDEO).map((r) => (r as { action: string }).action))
      .toEqual(["dismiss", "delete"]);
    expect((await req("GET", `/api/admin/videos/${VIDEO}`, { as: ADMIN })).status).toBe(404);
  });
});
