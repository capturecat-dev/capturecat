/**
 * The admin Projects page through the REAL Worker entry (mounting, the admin
 * role gate, requireAuth): every cloud project with its owner, the "never
 * shared" split, search, paging, one project's file list and shares — and
 * that no admin route serves a project's files. Migrations run for real (node:sqlite); R2 is
 * in memory. `Authorization: Bearer <uid>` is that user's session.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { MemoryBucket } from "../test-support/memory-bucket";

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
const OTHER = "other-1";
const SHARED = "11111111-1111-4111-8111-111111111111";
const LONELY = "22222222-2222-4222-8222-222222222222";
const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

let db: TestD1;
let env: Env;
let r2: MemoryBucket;

function addUser(id: string, email: string, role = "user") {
  const now = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked, role, username)
     VALUES (?, ?, ?, 1, ?, ?, 1, 0, ?, ?)`,
    id, email.split("@")[0], email, now, now, role, id.replace(/[^a-z0-9]/g, ""),
  );
}

function addProject(id: string, opts: { name?: string; owner?: string; createdAt?: string; revision?: number } = {}) {
  const at = opts.createdAt ?? new Date().toISOString();
  db.query(
    `INSERT INTO cloud_projects (id, owner_uid, name, revision, total_bytes, created_at, updated_at)
     VALUES (?, ?, ?, ?, 10, ?, ?)`,
    id, opts.owner ?? OWNER, opts.name ?? `Project ${id.slice(0, 4)}`, opts.revision ?? 1, at, at,
  );
}

function addFile(projectId: string, path: string, contentType: string, bytes: string) {
  const key = `cloud-projects/${projectId}/${path}`;
  db.query(
    `INSERT INTO cloud_project_files (project_id, path, sha256, bytes, content_type, r2_key, uploaded_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    projectId, path, path.padEnd(64, "0").slice(0, 64), bytes.length, contentType, key, new Date().toISOString(),
  );
  void r2.put(key, bytes);
}

function addShare(videoId: string, projectId: string) {
  db.query(
    `INSERT INTO shared_videos (video_id, uid, file_name, r2_key, url, status, created_at, duration_seconds, file_size_bytes, is_private, comments_enabled, profile_visible, project_id)
     VALUES (?, ?, ?, ?, 'u', 'ready', ?, 12, 10, 0, 1, 1, ?)`,
    videoId, OWNER, `${videoId}.mp4`, `videos/${videoId}.mp4`, new Date().toISOString(), projectId,
  );
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
  addUser(OTHER, "other@test.local");
  addProject(SHARED, { name: "Onboarding walkthrough", createdAt: "2026-10-02T00:00:00.000Z" });
  addProject(LONELY, { name: "Bug repro", createdAt: "2026-10-03T00:00:00.000Z" });
  addShare("vidShared", SHARED);
});

function req(method: string, path: string, init: { as?: string; headers?: Record<string, string> } = {}) {
  const headers: Record<string, string> = { "CF-Connecting-IP": "203.0.113.7", ...init.headers };
  if (init.as) headers.Authorization = `Bearer ${init.as}`;
  return worker.fetch(new Request(`${API}${path}`, { method, headers, redirect: "manual" }), env, ctx);
}

type Page = {
  projects: Array<{ projectId: string; name: string; owner: { email: string }; shares: number; uploaded: boolean }>;
  nextCursor: string | null;
  counts: { all: number; unshared: number; shared: number };
};
const list = async (query = "") => (await (await req("GET", `/api/admin/projects${query}`, { as: ADMIN })).json()) as Page;

describe("admin projects", () => {
  it("is invisible to non-admins", async () => {
    for (const who of [OWNER, OTHER, undefined]) {
      expect((await req("GET", "/api/admin/projects", { as: who })).status, String(who)).toBe(who ? 404 : 401);
      expect((await req("GET", `/api/admin/projects/${SHARED}`, { as: who })).status, String(who)).toBe(who ? 404 : 401);
    }
  });

  it("lists every project newest first with its owner, and splits never-shared from shared", async () => {
    const all = await list();
    expect(all.projects.map((p) => p.projectId)).toEqual([LONELY, SHARED]);
    expect(all.projects[0]).toMatchObject({ name: "Bug repro", owner: { email: "owner@test.local" }, shares: 0, uploaded: true });
    expect(all.projects[1]?.shares).toBe(1);
    expect(all.counts).toEqual({ all: 2, unshared: 1, shared: 1 });

    expect((await list("?filter=unshared")).projects.map((p) => p.projectId)).toEqual([LONELY]);
    expect((await list("?filter=shared")).projects.map((p) => p.projectId)).toEqual([SHARED]);
  });

  it("searches by name, owner email and id (either case)", async () => {
    addProject("33333333-3333-4333-8333-333333333333", { owner: OTHER, name: "Pricing page" });
    expect((await list("?q=walkthrough")).projects.map((p) => p.projectId)).toEqual([SHARED]);
    expect((await list("?q=other%40test")).projects).toHaveLength(1);
    expect((await list(`?q=${LONELY.toLowerCase()}`)).projects.map((p) => p.projectId)).toEqual([LONELY]);
    // LIKE wildcards are literal.
    expect((await list("?q=%25")).projects).toHaveLength(0);
  });

  it("pages with a cursor", async () => {
    for (let i = 0; i < 5; i++) {
      addProject(`4444444${i}-4444-4444-8444-444444444444`, { createdAt: `2026-09-0${i + 1}T00:00:00.000Z` });
    }
    const seen: string[] = [];
    let cursor: string | null = null;
    do {
      const page = await list(`?limit=2${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`);
      seen.push(...page.projects.map((p) => p.projectId));
      cursor = page.nextCursor;
    } while (cursor);
    expect(seen).toHaveLength(7);
    expect(new Set(seen).size).toBe(7);
  });

  it("marks a project whose upload never finished", async () => {
    addProject("55555555-5555-4555-8555-555555555555", { revision: 0 });
    const page = await list();
    expect(page.projects.find((p) => p.projectId.startsWith("5555"))?.uploaded).toBe(false);
  });

  it("shows one project's file list and its shares", async () => {
    addFile(SHARED, "camera.mov", "video/quicktime", "camcamcam");
    addFile(SHARED, "recording.mov", "video/quicktime", "0123456789");
    addFile(SHARED, "cursor.json", "application/json", "{}");
    const res = await req("GET", `/api/admin/projects/${SHARED.toLowerCase()}`, { as: ADMIN });
    expect(res.status).toBe(200);
    const detail = (await res.json()) as {
      project: { projectId: string; fileCount: number };
      files: Array<{ path: string; kind: string }>;
      videos: Array<{ videoId: string; shareUrl: string }>;
    };
    expect(detail.project).toMatchObject({ projectId: SHARED, fileCount: 3 });
    expect(detail.files.map((f) => [f.path, f.kind])).toEqual([
      ["camera.mov", "video"],
      ["cursor.json", "data"],
      ["recording.mov", "video"],
    ]);
    expect(detail).not.toHaveProperty("primaryVideo");
    expect(detail.videos.map((v) => v.videoId)).toEqual(["vidShared"]);
    expect(detail.videos[0]?.shareUrl).toMatch(/\/share\/vidShared$/);
    expect((await req("GET", "/api/admin/projects/66666666-6666-4666-8666-666666666666", { as: ADMIN })).status).toBe(404);
  });

  it("never serves a project's files, not even to an admin", async () => {
    addFile(LONELY, "recording.mov", "video/quicktime", "0123456789");
    const res = await req("GET", `/api/admin/projects/${LONELY}/media?path=recording.mov`, { as: ADMIN, headers: { Range: "bytes=2-5" } });
    expect(res.status).toBe(404);
    expect(await res.text()).not.toContain("2345");
  });
});
