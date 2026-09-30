/**
 * Route-level tests for cloud projects: authz, presign scoping, finalize
 * verification, quota refusal and optimistic-concurrency conflicts.
 *
 * Real: the Hono router, requireAuth (its blocked gate and cookie-CSRF gate),
 * every migration + every SQL statement (node:sqlite via
 * test-support/d1-sqlite.js), requireEntitlement / userRateLimit / the plan
 * rows / checkUploadAllowance / the storage sum.
 * Mocked: the Better Auth session STORE (a bearer token is the uid; the user
 * row — tester, blocked — is read from D1 exactly as Better Auth would) and
 * the S3 presigner (deterministic URLs we can assert on). R2 is an in-memory
 * bucket — nothing here can reach the real one.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { sha256Hex } from "../lib/cloud-projects";
import { storageUsageBytes } from "../lib/db";

vi.mock("../lib/auth", () => ({
  getAuth: (env: Env) => ({
    api: {
      getSession: async ({ headers }: { headers: Headers }) => {
        const token = headers.get("Authorization")?.replace(/^Bearer /, "");
        if (!token) return null;
        const user = await env.DB.prepare(`SELECT id, email, tester, blocked FROM "user" WHERE id = ?`)
          .bind(token)
          .first<{ id: string; email: string; tester: number; blocked: number }>();
        if (!user) return null;
        return {
          session: { expiresAt: new Date(Date.now() + 86_400_000) },
          // Tester → the pro plan row; everyone else resolves to free.
          user: { id: user.id, email: user.email, tester: user.tester === 1, blocked: user.blocked === 1 },
        };
      },
    },
  }),
}));

const presignCalls = vi.hoisted(() => ({
  put: [] as Array<Record<string, unknown>>,
  get: [] as Array<Record<string, unknown>>,
}));
vi.mock("../lib/presign", () => ({
  createPresignedUploadUrl: vi.fn(async (o: Record<string, unknown>) => {
    presignCalls.put.push(o);
    return `https://r2.test/${o.key}?put&ct=${encodeURIComponent(String(o.contentType))}&len=${o.contentLength}&exp=${o.expiresIn}`;
  }),
  createPresignedDownloadUrl: vi.fn(async (o: Record<string, unknown>) => {
    presignCalls.get.push(o);
    return `https://r2.test/${o.key}?get&rct=${encodeURIComponent(String(o.responseContentType))}&exp=${o.expiresIn}`;
  }),
  headR2ObjectMeta: vi.fn(),
  headR2Object: vi.fn(),
}));

// planForUser (owner's plan for a member's save) uses the Workers Cache API,
// which Node lacks — an always-miss stub keeps it on the D1 path.
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined } });

const { cloudProjectRoutes } = await import("./cloud-projects");

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/** Minimal in-memory R2Bucket: what the routes use (head/get/put/delete). */
class MemoryBucket {
  objects = new Map<string, { bytes: Uint8Array; contentType?: string }>();
  put(key: string, value: Uint8Array | string, opts?: { httpMetadata?: { contentType?: string } }) {
    const bytes = typeof value === "string" ? new TextEncoder().encode(value) : new Uint8Array(value);
    this.objects.set(key, { bytes, contentType: opts?.httpMetadata?.contentType });
    return Promise.resolve({ key, size: bytes.byteLength });
  }
  async head(key: string) {
    const o = this.objects.get(key);
    return o ? { key, size: o.bytes.byteLength, etag: `etag-${o.bytes.byteLength}` } : null;
  }
  async get(key: string) {
    const o = this.objects.get(key);
    if (!o) return null;
    const bytes = o.bytes;
    return {
      key,
      size: bytes.byteLength,
      etag: `etag-${bytes.byteLength}`,
      body: new Response(bytes).body!,
      text: async () => new TextDecoder().decode(bytes),
      arrayBuffer: async () => bytes.slice().buffer,
    };
  }
  async delete(keys: string | string[]) {
    for (const k of Array.isArray(keys) ? keys : [keys]) this.objects.delete(k);
  }
}

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const OWNER = "owner";
const STRANGER = "stranger";
const MEMBER = "member";
const FREE = "freeloader";
const ORG = "org1";

let db: TestD1;
let bucket: MemoryBucket;
let env: Env;
let app: Hono<{ Bindings: Env; Variables: Variables }>;

beforeEach(() => {
  db = createTestD1();
  bucket = new MemoryBucket();
  presignCalls.put.length = 0;
  presignCalls.get.length = 0;
  env = {
    DB: db,
    R2: bucket as unknown as R2Bucket,
    R2_ENDPOINT: "https://account.r2.test",
    R2_ACCESS_KEY_ID: "test-key",
    R2_SECRET_ACCESS_KEY: "test-secret",
  } as unknown as Env;
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  app.route("/api", cloudProjectRoutes);

  const now = new Date().toISOString();
  for (const uid of [OWNER, STRANGER, MEMBER, FREE]) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
       VALUES (?, ?, ?, 1, ?, ?, ?, 0)`,
      uid, uid, `${uid}@test.local`, now, now, uid === FREE ? 0 : 1,
    );
  }
  db.query(`INSERT INTO "organization" (id, name, slug, createdAt) VALUES (?, 'Team', 'team', ?)`, ORG, now);
  for (const uid of [OWNER, MEMBER]) {
    db.query(
      `INSERT INTO "member" (id, organizationId, userId, role, createdAt) VALUES (?, ?, ?, 'member', ?)`,
      `m-${uid}`, ORG, uid, now,
    );
  }
});

function call(uid: string | null, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  const h: Record<string, string> = { ...headers };
  if (uid) h["Authorization"] = `Bearer ${uid}`;
  let payload: BodyInit | undefined;
  if (typeof body === "string") payload = body;
  else if (body !== undefined) {
    payload = JSON.stringify(body);
    h["Content-Type"] = "application/json";
  }
  return app.request(`/api${path}`, { method, headers: h, body: payload }, env);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- test bodies are asserted field by field
async function json<T = any>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

interface FixtureFile {
  path: string;
  contentType: string;
  bytes: Uint8Array;
  source?: string;
}

function file(path: string, contentType: string, content: string, source?: string): FixtureFile {
  return { path, contentType, bytes: new TextEncoder().encode(content), source };
}

async function manifest(files: FixtureFile[], extra: Record<string, unknown> = {}) {
  return {
    name: "Demo",
    ...extra,
    files: await Promise.all(
      files.map(async (f) => ({
        path: f.path,
        sha256: await sha256Hex(f.bytes),
        bytes: f.bytes.byteLength,
        contentType: f.contentType,
        ...(f.source ? { source: f.source } : {}),
      })),
    ),
  };
}

/** What the client does with a presigned PUT: land exactly these bytes. */
async function uploadMissing(stageBody: { missing: Array<{ sha256: string }> }, files: FixtureFile[], owner = OWNER) {
  for (const m of stageBody.missing) {
    for (const f of files) {
      if ((await sha256Hex(f.bytes)) === m.sha256) {
        await bucket.put(`cloud-projects/${owner}/${ID}/objects/${m.sha256}`, f.bytes);
        break;
      }
    }
  }
}

const baseFiles = () => [
  file("recording.mov", "video/quicktime", "fake-movie-bytes-0123456789"),
  file("cursor.json", "application/json", '{"events":[]}'),
  file("external/0123456789ab.png", "image/png", "png-bytes", "/Users/someone/Pictures/wall.png"),
];

function projectJSON(name = "Demo", extra: Record<string, unknown> = {}) {
  // Deliberately odd formatting + a key no server knows: storage must be
  // byte-exact, not parse/re-serialize.
  return (
    `{\n  "id" : "${ID}",\n  "name" : ${JSON.stringify(name)},\n  "createdAt" : 780000000.5,\n` +
    `  "duration" : 12.25,\n  "settings" : { "backgroundPadding" : 48 },\n  "zoomRegions" : [ ],\n` +
    `  "videoURL" : "file:///Users/someone/Library/Application%20Support/CaptureCat/Projects/${ID}/recording.mov",\n` +
    `  "futureKeyFromANewerMac" : { "nested" : [1, 2.50, "x"] }` +
    Object.entries(extra).map(([k, v]) => `,\n  ${JSON.stringify(k)} : ${JSON.stringify(v)}`).join("") +
    `\n}`
  );
}

/** Stage → upload → finalize → first save. Returns the committed state. */
async function syncedProject(files = baseFiles(), extra: Record<string, unknown> = {}) {
  const stage = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(files, extra));
  expect(stage.status).toBe(200);
  await uploadMissing(await json(stage), files);
  const fin = await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`);
  expect(fin.status).toBe(200);
  const save = await call(OWNER, "PUT", `/cloud-projects/${ID}/project`, projectJSON(), { "If-Match": '"0"' });
  expect(save.status).toBe(200);
  return { files };
}

// ---------------------------------------------------------------------------
// AuthN / AuthZ
// ---------------------------------------------------------------------------

describe("authz", () => {
  it("refuses every route without a session", async () => {
    for (const [method, path] of [
      ["GET", "/cloud-projects"],
      ["PUT", `/cloud-projects/${ID}`],
      ["POST", `/cloud-projects/${ID}/finalize`],
      ["GET", `/cloud-projects/${ID}`],
      ["GET", `/cloud-projects/${ID}/files`],
      ["PUT", `/cloud-projects/${ID}/project`],
      ["DELETE", `/cloud-projects/${ID}`],
    ] as const) {
      // From a trusted web origin, so the CSRF gate passes and the missing
      // session is what refuses it…
      const res = await call(null, method, path, undefined, { Origin: "https://app.capturecat.so" });
      expect(res.status, `${method} ${path}`).toBe(401);
      // …and a cookie-style write from anywhere else never gets that far.
      if (method !== "GET") {
        expect((await call(null, method, path, undefined, { Origin: "https://evil.test" })).status).toBe(403);
      }
    }
  });

  it("another account can neither read nor write, nor claim the same id", async () => {
    await syncedProject();
    expect((await call(STRANGER, "GET", `/cloud-projects/${ID}`)).status).toBe(404);
    expect((await call(STRANGER, "GET", `/cloud-projects/${ID}/files`)).status).toBe(404);
    expect((await call(STRANGER, "POST", `/cloud-projects/${ID}/finalize`)).status).toBe(404);
    expect(
      (await call(STRANGER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("hijack"), { "If-Match": '"1"' })).status,
    ).toBe(404);
    expect((await call(STRANGER, "DELETE", `/cloud-projects/${ID}`)).status).toBe(404);

    const claim = await call(STRANGER, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles()));
    expect(claim.status).toBe(403);
    expect((await json(claim)).code).toBe("not_owner");

    const listed = await json(await call(STRANGER, "GET", "/cloud-projects"));
    expect(listed.projects).toEqual([]);
    // Nothing the stranger did touched the owner's project.
    const owner = await json(await call(OWNER, "GET", `/cloud-projects/${ID}`));
    expect(owner.revision).toBe(1);
    expect(owner.document).toBe(projectJSON());
  });

  it("org members read and SAVE edits; media, moves and delete stay owner-only; non-members get nothing", async () => {
    await syncedProject(baseFiles(), { orgId: ORG });

    const read = await call(MEMBER, "GET", `/cloud-projects/${ID}`);
    expect(read.status).toBe(200);
    const body = await json(read);
    expect(body.access).toBe("member");
    expect(body.isOwner).toBe(false);
    expect(body.document).toBe(projectJSON());

    // A teammate's edit lands as a normal revision, stored under the OWNER.
    const save = await call(MEMBER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("team edit"), { "If-Match": '"1"' });
    expect(save.status).toBe(200);
    expect((await json(save)).revision).toBe(2);
    const docKeys = [...bucket.objects.keys()].filter((k) => k.includes("/doc/"));
    expect(docKeys).toHaveLength(1);
    expect(docKeys[0].startsWith(`cloud-projects/${OWNER}/${ID}/doc/2-`)).toBe(true);
    // Revision discipline applies to members exactly as to the owner.
    const stale = await call(MEMBER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("late"), { "If-Match": '"1"' });
    expect(stale.status).toBe(409);
    expect((await call(STRANGER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("x"), { "If-Match": '"2"' })).status).toBe(404);
    expect((await call(MEMBER, "DELETE", `/cloud-projects/${ID}`)).status).toBe(403);
    expect((await call(MEMBER, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles()))).status).toBe(403);

    const team = await json(await call(MEMBER, "GET", `/cloud-projects?orgId=${ORG}`));
    expect(team.projects.map((p: { projectId: string }) => p.projectId)).toEqual([ID]);
    expect((await call(STRANGER, "GET", `/cloud-projects?orgId=${ORG}`)).status).toBe(403);
    expect((await call(STRANGER, "GET", `/cloud-projects/${ID}`)).status).toBe(404);
  });

  it("only a member can put a project into an org", async () => {
    const res = await call(STRANGER, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles(), { orgId: ORG }));
    expect(res.status).toBe(403);
    expect(db.query(`SELECT * FROM cloud_projects`)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Team access (owner decision 2026-09-30): members may READ and SAVE the
// document; only the owner stages/finalizes media, moves or deletes; every
// byte and every entitlement is the OWNER's.
// ---------------------------------------------------------------------------

const BLOCKED = "blocked-member";

function addUser(uid: string, opts: { tester?: boolean; blocked?: boolean; memberOf?: string } = {}) {
  const now = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
     VALUES (?, ?, ?, 1, ?, ?, ?, ?)`,
    uid, uid, `${uid}@test.local`, now, now, opts.tester === false ? 0 : 1, opts.blocked ? 1 : 0,
  );
  if (opts.memberOf) {
    db.query(
      `INSERT INTO "member" (id, organizationId, userId, role, createdAt) VALUES (?, ?, ?, 'member', ?)`,
      `m-${uid}`, opts.memberOf, uid, now,
    );
  }
}

describe("team access matrix", () => {
  it("owner / member / non-member / blocked on read, list, save, stage, finalize and delete", async () => {
    await syncedProject(baseFiles(), { orgId: ORG });
    addUser(BLOCKED, { blocked: true, memberOf: ORG });
    let revision = 1;
    const save = (uid: string) =>
      call(uid, "PUT", `/cloud-projects/${ID}/project`, projectJSON(`by ${uid}`), { "If-Match": `"${revision}"` });
    const stage = async (uid: string) => call(uid, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles()));

    type Row = [string, () => Response | Promise<Response>, number];
    const matrix: Row[] = [
      // read
      ["owner GET", () => call(OWNER, "GET", `/cloud-projects/${ID}`), 200],
      ["member GET", () => call(MEMBER, "GET", `/cloud-projects/${ID}`), 200],
      ["non-member GET", () => call(STRANGER, "GET", `/cloud-projects/${ID}`), 404],
      ["blocked GET", () => call(BLOCKED, "GET", `/cloud-projects/${ID}`), 403],
      ["owner files", () => call(OWNER, "GET", `/cloud-projects/${ID}/files`), 200],
      ["member files", () => call(MEMBER, "GET", `/cloud-projects/${ID}/files`), 200],
      ["non-member files", () => call(STRANGER, "GET", `/cloud-projects/${ID}/files`), 404],
      ["blocked files", () => call(BLOCKED, "GET", `/cloud-projects/${ID}/files`), 403],
      // team listing
      ["member list", () => call(MEMBER, "GET", `/cloud-projects?orgId=${ORG}`), 200],
      ["non-member list", () => call(STRANGER, "GET", `/cloud-projects?orgId=${ORG}`), 403],
      ["blocked list", () => call(BLOCKED, "GET", `/cloud-projects?orgId=${ORG}`), 403],
      // save (document) — owner and member both may
      ["non-member save", () => save(STRANGER), 404],
      ["blocked save", () => save(BLOCKED), 403],
      ["member save", () => save(MEMBER), 200],
      ["owner save", () => { revision = 2; return save(OWNER); }, 200],
      // media — owner only
      ["member stage", () => stage(MEMBER), 403],
      ["non-member stage", () => stage(STRANGER), 403],
      ["blocked stage", () => stage(BLOCKED), 403],
      ["member finalize", () => call(MEMBER, "POST", `/cloud-projects/${ID}/finalize`), 403],
      ["non-member finalize", () => call(STRANGER, "POST", `/cloud-projects/${ID}/finalize`), 404],
      ["blocked finalize", () => call(BLOCKED, "POST", `/cloud-projects/${ID}/finalize`), 403],
      ["owner stage", () => stage(OWNER), 200],
      ["owner finalize", () => call(OWNER, "POST", `/cloud-projects/${ID}/finalize`), 200],
      // delete — owner only
      ["member delete", () => call(MEMBER, "DELETE", `/cloud-projects/${ID}`), 403],
      ["non-member delete", () => call(STRANGER, "DELETE", `/cloud-projects/${ID}`), 404],
      ["blocked delete", () => call(BLOCKED, "DELETE", `/cloud-projects/${ID}`), 403],
      ["owner delete", () => call(OWNER, "DELETE", `/cloud-projects/${ID}`), 200],
    ];
    for (const [label, run, expected] of matrix) {
      expect((await run()).status, label).toBe(expected);
    }
  });

  it("records WHO saved: a member's save is attributed to the member, not the owner", async () => {
    await syncedProject(baseFiles(), { orgId: ORG });
    expect(db.query(`SELECT updated_by FROM cloud_projects`)[0]).toEqual({ updated_by: OWNER });
    const res = await call(MEMBER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("team edit"), { "If-Match": '"1"' });
    expect(res.status).toBe(200);
    expect(db.query(`SELECT updated_by FROM cloud_projects`)[0]).toEqual({ updated_by: MEMBER });
  });

  it("entitlement and quota are the OWNER's: a free-plan member saves into a paid owner's project, charged to the owner", async () => {
    await syncedProject(baseFiles(), { orgId: ORG });
    addUser("free-member", { tester: false, memberOf: ORG });
    const ownerBefore = await storageUsageBytes(db, OWNER);
    const doc = projectJSON("Demo", { padding: "z".repeat(50) });
    const res = await call("free-member", "PUT", `/cloud-projects/${ID}/project`, doc, { "If-Match": '"1"' });
    expect(res.status).toBe(200); // the member's own (free) plan is irrelevant
    const growth = new TextEncoder().encode(doc).byteLength - new TextEncoder().encode(projectJSON()).byteLength;
    expect(await storageUsageBytes(db, OWNER)).toBe(ownerBefore + growth);
    expect(await storageUsageBytes(db, "free-member")).toBe(0);
    // The document object lives under the OWNER's prefix.
    expect([...bucket.objects.keys()].filter((k) => k.includes("/doc/"))[0]).toMatch(
      new RegExp(`^cloud-projects/${OWNER}/${ID}/doc/2-`),
    );
  });

  it("team access is the owner's paid feature: when the owner's plan lapses, members lose the project and the owner keeps it", async () => {
    await syncedProject(baseFiles(), { orgId: ORG });
    db.query(`UPDATE "user" SET tester = 0 WHERE id = ?`, OWNER); // owner now resolves to the free plan
    expect((await call(MEMBER, "GET", `/cloud-projects/${ID}`)).status).toBe(404);
    expect((await call(MEMBER, "GET", `/cloud-projects/${ID}/files`)).status).toBe(404);
    expect(
      (await call(MEMBER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("x"), { "If-Match": '"1"' })).status,
    ).toBe(404);
    expect((await json(await call(MEMBER, "GET", `/cloud-projects?orgId=${ORG}`))).projects).toEqual([]);
    expect((await call(OWNER, "GET", `/cloud-projects/${ID}`)).status).toBe(200);
    // A blocked owner is the same as a lapsed one.
    db.query(`UPDATE "user" SET tester = 1, blocked = 1 WHERE id = ?`, OWNER);
    expect((await call(MEMBER, "GET", `/cloud-projects/${ID}`)).status).toBe(404);
  });

  it("a member cannot enlarge the owner's storage by any path", async () => {
    await syncedProject(baseFiles(), { orgId: ORG });
    const before = await storageUsageBytes(db, OWNER);
    setProLimits({ maxTotalStorageBytes: before + 10 });
    const extra = [...baseFiles(), file("voiceover.m4a", "audio/mp4", "member-supplied-audio")];

    // Media into the owner's project: stage (with or without an org move) and finalize.
    expect((await call(MEMBER, "PUT", `/cloud-projects/${ID}`, await manifest(extra))).status).toBe(403);
    expect((await call(MEMBER, "PUT", `/cloud-projects/${ID}`, await manifest(extra, { orgId: null }))).status).toBe(403);
    expect((await call(MEMBER, "POST", `/cloud-projects/${ID}/finalize`)).status).toBe(403);
    expect(presignCalls.put.filter((p) => String(p.key).includes(`/${OWNER}/`))).toHaveLength(3); // the owner's own sync only
    // A document that would push the owner past their cap.
    const huge = projectJSON("Demo", { padding: "z".repeat(100) });
    const grow = await call(MEMBER, "PUT", `/cloud-projects/${ID}/project`, huge, { "If-Match": '"1"' });
    expect(grow.status).toBe(413);
    // Deleting is not a member's to do either (and would not enlarge anything).
    expect((await call(MEMBER, "DELETE", `/cloud-projects/${ID}`)).status).toBe(403);

    expect(await storageUsageBytes(db, OWNER)).toBe(before);
    expect(db.query(`SELECT COUNT(*) AS n FROM cloud_project_objects WHERE status = 'pending'`)[0]).toEqual({ n: 0 });
    expect(db.query(`SELECT revision, staged_manifest FROM cloud_projects`)[0]).toEqual({ revision: 1, staged_manifest: null });
  });
});

// ---------------------------------------------------------------------------
// Presign scoping
// ---------------------------------------------------------------------------

describe("presign scoping", () => {
  it("presigns only missing objects, each to its exact key, type, length and TTL", async () => {
    const files = baseFiles();
    // Lower-case id in the URL resolves to the canonical upper-case project.
    const res = await call(OWNER, "PUT", `/cloud-projects/${ID.toLowerCase()}`, await manifest(files));
    expect(res.status).toBe(200);
    const body = await json(res);
    expect(body.projectId).toBe(ID);
    expect(body.revision).toBe(0);
    expect(body.missing).toHaveLength(3);
    expect(body.expiresIn).toBe(900);

    for (const f of files) {
      const sha = await sha256Hex(f.bytes);
      const key = `cloud-projects/${OWNER}/${ID}/objects/${sha}`;
      const upload = body.missing.find((m: { sha256: string }) => m.sha256 === sha);
      expect(upload).toMatchObject({
        bytes: f.bytes.byteLength,
        contentType: f.contentType,
        paths: [f.path],
        method: "PUT",
        headers: { "Content-Type": f.contentType },
      });
      expect(upload.uploadUrl).toBe(
        `https://r2.test/${key}?put&ct=${encodeURIComponent(f.contentType)}&len=${f.bytes.byteLength}&exp=900`,
      );
      expect(presignCalls.put).toContainEqual(
        expect.objectContaining({
          bucket: "capturecat",
          key,
          contentType: f.contentType,
          contentLength: f.bytes.byteLength,
          expiresIn: 900,
        }),
      );
    }
    // Pending until verified — and not counted against the quota yet.
    expect(db.query(`SELECT status FROM cloud_project_objects`).map((r) => r.status)).toEqual([
      "pending",
      "pending",
      "pending",
    ]);
    expect(await storageUsageBytes(db, OWNER)).toBe(0);
  });

  it("one presign per distinct hash; nothing re-uploaded once committed", async () => {
    const same = "identical-bytes";
    const files = [file("a.json", "application/json", same), file("b.json", "application/json", same)];
    const first = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(files)));
    expect(first.missing).toHaveLength(1);
    expect(first.missing[0].paths).toEqual(["a.json", "b.json"]);
    await uploadMissing(first, files);
    expect((await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`)).status).toBe(200);

    presignCalls.put.length = 0;
    const again = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(files)));
    expect(again.missing).toEqual([]);
    expect(again.presentCount).toBe(1);
    expect(presignCalls.put).toEqual([]);

    const changed = [files[0], file("b.json", "application/json", "new-bytes")];
    const third = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(changed)));
    expect(third.missing.map((m: { paths: string[] }) => m.paths)).toEqual([["b.json"]]);
  });

  it("refuses bad paths, types and sizes before presigning anything", async () => {
    const sha = "b".repeat(64);
    const cases: Array<[Record<string, unknown>, number, string | undefined]> = [
      [{ path: "../escape.json", sha256: sha, bytes: 1, contentType: "application/json" }, 400, "invalid_path"],
      [{ path: "/abs.mov", sha256: sha, bytes: 1, contentType: "video/quicktime" }, 400, "invalid_path"],
      [{ path: ".mcp-history/1.json", sha256: sha, bytes: 1, contentType: "application/json" }, 400, "invalid_path"],
      [{ path: "project.json", sha256: sha, bytes: 1, contentType: "application/json" }, 400, "invalid_path"],
      [{ path: "x.svg", sha256: sha, bytes: 1, contentType: "image/svg+xml" }, 400, "invalid_path"],
      [{ path: "cursor.json", sha256: sha, bytes: 1, contentType: "text/html" }, 400, "invalid_content_type"],
      [{ path: "bg.png", sha256: sha, bytes: 65 * 1024 * 1024, contentType: "image/png" }, 413, "file_too_large"],
      [{ path: "r.mov", sha256: "nothex", bytes: 1, contentType: "video/quicktime" }, 400, undefined],
      [{ path: "r.mov", sha256: sha, bytes: -1, contentType: "video/quicktime" }, 400, undefined],
    ];
    for (const [f, status, code] of cases) {
      const res = await call(OWNER, "PUT", `/cloud-projects/${ID}`, { name: "x", files: [f] });
      expect(res.status, JSON.stringify(f)).toBe(status);
      if (code) expect((await json(res)).code).toBe(code);
    }
    expect(presignCalls.put).toEqual([]);
    expect(db.query(`SELECT * FROM cloud_projects`)).toEqual([]);
    expect((await call(OWNER, "PUT", `/cloud-projects/not-a-uuid`, { name: "x", files: [] })).status).toBe(400);
  });
});

// ---------------------------------------------------------------------------
// Finalize: the client's sizes and hashes are claims until verified
// ---------------------------------------------------------------------------

describe("finalize verification", () => {
  it("409 objects_missing before the bytes are uploaded", async () => {
    await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles()));
    const res = await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`);
    expect(res.status).toBe(409);
    const body = await json(res);
    expect(body.code).toBe("objects_missing");
    expect(body.missing).toHaveLength(3);
  });

  it("rejects bytes whose SHA-256 differs from the declared one, and deletes them", async () => {
    const files = [file("cursor.json", "application/json", "the-real-bytes")];
    const stage = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(files)));
    const key = `cloud-projects/${OWNER}/${ID}/objects/${stage.missing[0].sha256}`;
    await bucket.put(key, new TextEncoder().encode("the-fake-bytes")); // same length, other content
    const res = await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`);
    expect(res.status).toBe(422);
    expect((await json(res)).code).toBe("hash_mismatch");
    expect(bucket.objects.has(key)).toBe(false);
    expect(db.query(`SELECT * FROM cloud_project_objects`)).toEqual([]);
    expect(db.query(`SELECT * FROM cloud_project_files`)).toEqual([]);
  });

  it("rejects a size that differs from the declared one", async () => {
    const files = [file("cursor.json", "application/json", "twelve bytes")];
    const stage = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(files)));
    const key = `cloud-projects/${OWNER}/${ID}/objects/${stage.missing[0].sha256}`;
    await bucket.put(key, new TextEncoder().encode("longer than twelve bytes"));
    const res = await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`);
    expect(res.status).toBe(422);
    expect((await json(res)).code).toBe("size_mismatch");
    expect(bucket.objects.has(key)).toBe(false);
  });

  it("commits verified files; GET serves each with a presigned, typed GET URL", async () => {
    await syncedProject();
    const res = await call(OWNER, "GET", `/cloud-projects/${ID}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("ETag")).toBe('"1"');
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    const body = await json(res);
    expect(body.files.map((f: { path: string }) => f.path)).toEqual([
      "cursor.json",
      "external/0123456789ab.png",
      "recording.mov",
    ]);
    const png = body.files.find((f: { path: string }) => f.path.endsWith(".png"));
    expect(png.source).toBe("/Users/someone/Pictures/wall.png");
    expect(png.url).toContain(`cloud-projects/${OWNER}/${ID}/objects/${png.sha256}?get&rct=image%2Fpng&exp=900`);
    expect(Date.parse(body.urlsExpireAt)).toBeGreaterThan(Date.now());

    const refreshed = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/files`));
    expect(refreshed.files).toHaveLength(3);
  });

  it("garbage-collects objects a new manifest drops", async () => {
    const { files } = await syncedProject();
    const cursorSha = await sha256Hex(files[1].bytes);
    const cursorKey = `cloud-projects/${OWNER}/${ID}/objects/${cursorSha}`;
    expect(bucket.objects.has(cursorKey)).toBe(true);

    const fewer = [files[0], files[2]];
    const stage = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(fewer)));
    expect(stage.missing).toEqual([]);
    expect((await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`)).status).toBe(200);
    expect(bucket.objects.has(cursorKey)).toBe(false);
    expect(db.query(`SELECT path FROM cloud_project_files ORDER BY path`).map((r) => r.path)).toEqual([
      "external/0123456789ab.png",
      "recording.mov",
    ]);
  });

  it("is idempotent once committed", async () => {
    await syncedProject();
    const again = await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`);
    expect(again.status).toBe(200);
    expect((await json(again)).fileCount).toBe(3);
  });
});

// ---------------------------------------------------------------------------
// Quota (the plan decides; the storage sum is shared with shares/screenshots)
// ---------------------------------------------------------------------------

function setProLimits(limits: Record<string, number>) {
  for (const [k, v] of Object.entries(limits)) {
    db.query(`UPDATE plan SET limits = json_set(limits, ?, ?) WHERE name = 'pro'`, `$.${k}`, v);
  }
}

describe("quota", () => {
  it("a plan without cloud storage is refused with 402", async () => {
    const res = await call(FREE, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles()));
    expect(res.status).toBe(402);
    expect((await json(res)).code).toBe("cloud_share_required");
    expect(presignCalls.put).toEqual([]);
  });

  it("refuses a manifest that would exceed the storage cap (413 + path)", async () => {
    setProLimits({ maxTotalStorageBytes: 30 });
    const res = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles()));
    expect(res.status).toBe(413);
    const body = await json(res);
    expect(body.code).toBe("storage_limit_reached");
    expect(body.limitBytes).toBe(30);
    expect(typeof body.path).toBe("string");
    expect(presignCalls.put).toEqual([]);
  });

  it("lifts the plan's share-upload per-file cap for raw project media (total quota still binds)", async () => {
    // Share uploads are exported mp4s; a cloud project carries the RAW
    // recording, so its per-file ceiling is the per-kind one.
    setProLimits({ maxFileSizeBytes: 20 });
    const res = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles()));
    expect(res.status).toBe(200);
    // …but a plan with no storage at all still refuses, and says so.
    setProLimits({ maxFileSizeBytes: 0 });
    const none = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(baseFiles()));
    expect(none.status).toBe(402);
  });

  it("a member's growing save is charged to the OWNER's quota", async () => {
    await syncedProject(baseFiles(), { orgId: ORG });
    const used = await storageUsageBytes(db, OWNER);
    setProLimits({ maxTotalStorageBytes: used + 5 });
    const bigger = projectJSON("Demo", { padding: "z".repeat(100) });
    const grow = await call(MEMBER, "PUT", `/cloud-projects/${ID}/project`, bigger, { "If-Match": '"1"' });
    expect(grow.status).toBe(413);
  });

  it("counts other projects' outstanding presigns as used", async () => {
    const other = "11111111-2222-3333-4444-555555555555";
    await call(OWNER, "PUT", `/cloud-projects/${other}`, await manifest([file("big.json", "application/json", "x".repeat(40))]));
    setProLimits({ maxTotalStorageBytes: 60 });
    const res = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([file("c.json", "application/json", "y".repeat(30))]));
    expect(res.status).toBe(413);
  });

  it("re-checks at finalize on VERIFIED bytes and deletes what does not fit", async () => {
    const files = baseFiles();
    const stage = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(files)));
    await uploadMissing(stage, files);
    setProLimits({ maxTotalStorageBytes: 20 }); // plan shrank (or usage grew) since the presign
    const res = await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`);
    expect(res.status).toBe(413);
    expect((await json(res)).code).toBe("storage_limit_reached");
    expect(db.query(`SELECT * FROM cloud_project_files`)).toEqual([]);
    expect(await storageUsageBytes(db, OWNER)).toBeLessThanOrEqual(20);
  });

  it("verified media and the document count in the one storage sum", async () => {
    const { files } = await syncedProject();
    const media = files.reduce((s, f) => s + f.bytes.byteLength, 0);
    const doc = new TextEncoder().encode(projectJSON()).byteLength;
    expect(await storageUsageBytes(db, OWNER)).toBe(media + doc);
    const list = await json(await call(OWNER, "GET", "/cloud-projects"));
    expect(list.storage.usedBytes).toBe(media + doc);
    expect(list.projects[0]).toMatchObject({ projectId: ID, revision: 1, hasDocument: true, totalBytes: media + doc });
  });

  it("a growing document is quota-checked; a shrinking one always saves", async () => {
    await syncedProject();
    const used = await storageUsageBytes(db, OWNER);
    setProLimits({ maxTotalStorageBytes: used + 5 });
    const bigger = projectJSON("Demo", { padding: "z".repeat(100) });
    const grow = await call(OWNER, "PUT", `/cloud-projects/${ID}/project`, bigger, { "If-Match": '"1"' });
    expect(grow.status).toBe(413);
    const smaller = projectJSON("D");
    const shrink = await call(OWNER, "PUT", `/cloud-projects/${ID}/project`, smaller, { "If-Match": '"1"' });
    expect(shrink.status).toBe(200);
  });

  it("replacing a recording at the cap still works: the dropped object is credit", async () => {
    const a = file("recording.mov", "video/quicktime", "A".repeat(40));
    await syncedProject([a]);
    const used = await storageUsageBytes(db, OWNER);
    setProLimits({ maxTotalStorageBytes: used });
    const b = file("recording.mov", "video/quicktime", "B".repeat(40));
    const stage = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([b])));
    await uploadMissing(stage, [b]);
    expect((await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`)).status).toBe(200);
    const got = await json(await call(OWNER, "GET", `/cloud-projects/${ID}`));
    expect(got.files.map((f: { sha256: string }) => f.sha256)).toEqual([await sha256Hex(b.bytes)]);
    expect(await storageUsageBytes(db, OWNER)).toBe(used);
  });

  it("EXPLOIT: a replacement accepted on credit cannot be committed alongside the object it replaced", async () => {
    // At the cap with recording A committed.
    const a = file("recording.mov", "video/quicktime", "A".repeat(40));
    await syncedProject([a]);
    const used = await storageUsageBytes(db, OWNER);
    setProLimits({ maxTotalStorageBytes: used });

    // Stage a same-size replacement B plus a zero-byte sidecar that is never
    // uploaded: finalize verifies B, accepts it on A's credit, then stops
    // short of committing (409 objects_missing) — so A is never collected.
    const b = file("recording.mov", "video/quicktime", "B".repeat(40));
    const never = file("never.json", "application/json", "");
    const stage = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([b, never])));
    await uploadMissing(stage, [b]);
    expect((await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`)).status).toBe(409);

    // Restage naming BOTH objects: nothing is missing, so nothing is presigned
    // or quota-checked at stage time…
    const both = [a, file("replacement.mov", "video/quicktime", "B".repeat(40))];
    expect((await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest(both))).status).toBe(200);
    // …and the commit is where the cap must hold.
    const fin = await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`);
    expect(fin.status).toBe(413);
    expect((await json(fin)).code).toBe("storage_limit_reached");
    const got = await json(await call(OWNER, "GET", `/cloud-projects/${ID}`));
    expect(got.files.map((f: { sha256: string }) => f.sha256)).toEqual([await sha256Hex(a.bytes)]);

    // The uncommitted leftover still counts and is never credit again, so the
    // trick cannot be repeated to ratchet storage up.
    const c3 = file("recording.mov", "video/quicktime", "C".repeat(40));
    const again = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([c3, never]));
    expect(again.status).toBe(413);
  });

  it("restaging one project with fresh hashes cannot mint presigns past the cap or the pending bound", async () => {
    setProLimits({ maxTotalStorageBytes: 100 });
    const first = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([file("a.json", "application/json", "x".repeat(60))]));
    expect(first.status).toBe(200);
    // The first presign is still outstanding (its bytes may already be in R2).
    const second = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([file("b.json", "application/json", "y".repeat(60))]));
    expect(second.status).toBe(413);

    // Same for the COUNT of outstanding presigns (MAX_PENDING_OBJECTS = 200).
    setProLimits({ maxTotalStorageBytes: 1_000_000 });
    const batch = (tag: string) =>
      Array.from({ length: 150 }, (_, i) => file(`${tag}${i}.json`, "application/json", `${tag}-${i}`));
    const other = "11111111-2222-3333-4444-555555555555";
    expect((await call(OWNER, "PUT", `/cloud-projects/${other}`, await manifest(batch("p")))).status).toBe(200);
    const again = await call(OWNER, "PUT", `/cloud-projects/${other}`, await manifest(batch("q")));
    expect(again.status).toBe(429);
    expect((await json(again)).code).toBe("too_many_pending");
  });
});

// ---------------------------------------------------------------------------
// project.json: byte-exact storage + optimistic concurrency
// ---------------------------------------------------------------------------

describe("document saves", () => {
  it("requires If-Match", async () => {
    await syncedProject();
    const res = await call(OWNER, "PUT", `/cloud-projects/${ID}/project`, projectJSON());
    expect(res.status).toBe(428);
    expect((await json(res)).code).toBe("revision_required");
  });

  it("stores the document byte-for-byte and bumps the revision", async () => {
    await syncedProject();
    const edited = projectJSON("Renamed on the web");
    const res = await call(OWNER, "PUT", `/cloud-projects/${ID}/project`, edited, { "If-Match": '"1"' });
    expect(res.status).toBe(200);
    expect(res.headers.get("ETag")).toBe('"2"');
    const body = await json(res);
    expect(body.revision).toBe(2);
    expect(body.documentSha256).toBe(await sha256Hex(edited));

    const got = await json(await call(OWNER, "GET", `/cloud-projects/${ID}`));
    expect(got.document).toBe(edited);
    expect(got.name).toBe("Renamed on the web");
    // Only the live revision's object is kept.
    const docKeys = [...bucket.objects.keys()].filter((k) => k.includes("/doc/"));
    expect(docKeys).toHaveLength(1);
    expect(docKeys[0]).toMatch(new RegExp(`^cloud-projects/${OWNER}/${ID}/doc/2-[a-z0-9]{12}\\.json$`));
  });

  it("409 on a stale revision, with the current revision and document", async () => {
    await syncedProject();
    const webEdit = projectJSON("web edit");
    expect((await call(OWNER, "PUT", `/cloud-projects/${ID}/project`, webEdit, { "If-Match": '"1"' })).status).toBe(200);

    const stale = await call(OWNER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("mac edit"), { "If-Match": '"1"' });
    expect(stale.status).toBe(409);
    expect(stale.headers.get("ETag")).toBe('"2"');
    const body = await json(stale);
    expect(body).toMatchObject({ code: "revision_conflict", revision: 2, document: webEdit });
    expect(body.documentSha256).toBe(await sha256Hex(webEdit));

    // Resolving by re-basing on the returned revision succeeds.
    const retry = await call(OWNER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("mac edit"), { "If-Match": '"2"' });
    expect(retry.status).toBe(200);
    expect((await json(retry)).revision).toBe(3);
  });

  it("two concurrent saves on one revision: exactly one wins", async () => {
    await syncedProject();
    const [a, b] = await Promise.all([
      call(OWNER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("A"), { "If-Match": '"1"' }),
      call(OWNER, "PUT", `/cloud-projects/${ID}/project`, projectJSON("B"), { "If-Match": '"1"' }),
    ]);
    expect([a.status, b.status].sort()).toEqual([200, 409]);
    const got = await json(await call(OWNER, "GET", `/cloud-projects/${ID}`));
    expect(got.revision).toBe(2);
    const winner = a.status === 200 ? projectJSON("A") : projectJSON("B");
    expect(got.document).toBe(winner);
    // The loser orphaned only its own attempt's object, and deleted it; the
    // winner's bytes are intact (the regression: both aimed at doc/2.json and
    // the loser's late PUT replaced the winner's document under its row).
    const docKeys = [...bucket.objects.keys()].filter((k) => k.includes("/doc/"));
    expect(docKeys).toHaveLength(1);
    expect(new TextDecoder().decode(bucket.objects.get(docKeys[0])!.bytes)).toBe(winner);
    expect(got.documentSha256).toBe(await sha256Hex(winner));
  });

  it("refuses documents the Mac could not decode", async () => {
    await syncedProject();
    const put = (body: string) => call(OWNER, "PUT", `/cloud-projects/${ID}/project`, body, { "If-Match": '"1"' });
    expect((await json(await put(projectJSON().replace(ID, "00000000-0000-0000-0000-000000000000")))).code).toBe("id_mismatch");
    expect((await put("{not json")).status).toBe(400);
    expect((await put(JSON.stringify({ id: ID, name: "x" }))).status).toBe(400);
    expect((await json(await call(OWNER, "GET", `/cloud-projects/${ID}`))).revision).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// Delete
// ---------------------------------------------------------------------------

describe("delete", () => {
  it("removes rows and every R2 object, and frees the storage", async () => {
    await syncedProject();
    expect(bucket.objects.size).toBe(4); // 3 media + 1 document
    const res = await call(OWNER, "DELETE", `/cloud-projects/${ID}`);
    expect(res.status).toBe(200);
    expect(bucket.objects.size).toBe(0);
    expect(await storageUsageBytes(db, OWNER)).toBe(0);
    expect((await call(OWNER, "GET", `/cloud-projects/${ID}`)).status).toBe(404);
  });
});
