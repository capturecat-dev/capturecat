/**
 * Cloud-project history (phases 1A + 1B): the versioned save, media pinning,
 * retention, and the history routes — through the REAL router, requireAuth,
 * requireEntitlement, plan rows, every migration and every SQL statement
 * (node:sqlite via test-support/d1-sqlite.js). Mocked: the Better Auth
 * session STORE (bearer = uid; the user row read from D1), the S3 presigner,
 * the Cache API (always miss). R2 is in memory — nothing can reach the real one.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { MemoryBucket, gunzipText } from "../test-support/memory-bucket";
import { sha256Hex } from "../lib/cloud-projects";
import { storageUsageBytes } from "../lib/db";
import { encodeChangeHeader, type ChangeSet } from "../lib/project-history";

vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.mock("../lib/presign", () => ({
  createPresignedUploadUrl: vi.fn(async (o: Record<string, unknown>) => `https://r2.test/${o.key}?put`),
  createPresignedDownloadUrl: vi.fn(async (o: Record<string, unknown>) => `https://r2.test/${o.key}?get`),
  headR2ObjectMeta: vi.fn(),
  headR2Object: vi.fn(),
}));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined } });

const { cloudProjectRoutes } = await import("./cloud-projects");
const { cloudProjectHistoryRoutes } = await import("./cloud-project-history");
const { saveVersioned, sweepCloudProjectHistory } = await import("../lib/project-history-db");
const { planForUser } = await import("../lib/entitlement");

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const OWNER = "owner";
const MEMBER = "member";
const STRANGER = "stranger";
const BLOCKED = "blocked-member";
const BIZ = "biz-owner";
const ORG = "org1";

let db: TestD1;
let bucket: MemoryBucket;
let env: Env;
let app: Hono<{ Bindings: Env; Variables: Variables }>;

const T0 = Date.parse("2026-10-01T12:00:00.000Z");
const MIN = 60_000;
const DAY = 86_400_000;

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(T0);
  db = createTestD1();
  bucket = new MemoryBucket();
  env = {
    DB: db,
    R2: bucket as unknown as R2Bucket,
    R2_ENDPOINT: "https://account.r2.test",
    R2_ACCESS_KEY_ID: "test-key",
    R2_SECRET_ACCESS_KEY: "test-secret",
  } as unknown as Env;
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  app.route("/api", cloudProjectRoutes);
  app.route("/api", cloudProjectHistoryRoutes);

  const now = new Date().toISOString();
  const users: Array<[string, number, number]> = [
    [OWNER, 1, 0],
    [MEMBER, 1, 0],
    [STRANGER, 1, 0],
    [BLOCKED, 1, 1],
    [BIZ, 0, 0],
  ];
  for (const [uid, tester, blocked] of users) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
       VALUES (?, ?, ?, 1, ?, ?, ?, ?)`,
      uid, `${uid} name`, `${uid}@test.local`, now, now, tester, blocked,
    );
  }
  db.query(`INSERT INTO "organization" (id, name, slug, createdAt) VALUES (?, 'Team', 'team', ?)`, ORG, now);
  for (const uid of [OWNER, MEMBER, BLOCKED, BIZ]) {
    db.query(
      `INSERT INTO "member" (id, organizationId, userId, role, createdAt) VALUES (?, ?, ?, 'member', ?)`,
      `m-${uid}`, ORG, uid, now,
    );
  }
  db.query(`UPDATE plan SET is_active = 1 WHERE name = 'business'`);
  db.query(
    `INSERT INTO "subscription" (id, plan, referenceId, stripeCustomerId, stripeSubscriptionId, status, periodEnd)
     VALUES ('row_biz', 'business', ?, 'cus_biz', 'sub_biz', 'active', ?)`,
    BIZ, new Date(T0 + 400 * DAY).toISOString(),
  );
});

afterEach(() => {
  vi.useRealTimers();
});

function at(ms: number) {
  vi.setSystemTime(ms);
}

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

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- asserted field by field
async function json<T = any>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

interface FixtureFile {
  path: string;
  contentType: string;
  bytes: Uint8Array;
}
const file = (path: string, contentType: string, content: string): FixtureFile => ({
  path,
  contentType,
  bytes: new TextEncoder().encode(content),
});
const sha = (f: FixtureFile) => sha256Hex(f.bytes);

async function manifest(files: FixtureFile[], extra: Record<string, unknown> = {}) {
  return {
    name: "Demo",
    ...extra,
    files: await Promise.all(
      files.map(async (f) => ({ path: f.path, sha256: await sha(f), bytes: f.bytes.byteLength, contentType: f.contentType })),
    ),
  };
}

function objectKeyOf(owner: string, s: string) {
  return `cloud-projects/${owner}/${ID}/objects/${s}`;
}

/** Stage → upload what is missing → finalize, as `owner`. */
async function pushMedia(files: FixtureFile[], extra: Record<string, unknown> = {}, owner = OWNER) {
  const stage = await call(owner, "PUT", `/cloud-projects/${ID}`, await manifest(files, extra));
  expect(stage.status, "stage").toBe(200);
  for (const m of (await json(stage)).missing as Array<{ sha256: string }>) {
    for (const f of files) if ((await sha(f)) === m.sha256) await bucket.put(objectKeyOf(owner, m.sha256), f.bytes);
  }
  return call(owner, "POST", `/cloud-projects/${ID}/finalize`);
}

function projectJSON(name = "Demo", extra: Record<string, unknown> = {}) {
  return (
    `{\n  "id" : "${ID}",\n  "name" : ${JSON.stringify(name)},\n  "createdAt" : 780000000.5,\n` +
    `  "duration" : 12.25,\n  "settings" : { "backgroundPadding" : 48 },\n  "zoomRegions" : [ ],\n` +
    `  "futureKeyFromANewerMac" : { "nested" : [1, 2.50, "x"] }` +
    Object.entries(extra).map(([k, v]) => `,\n  ${JSON.stringify(k)} : ${JSON.stringify(v)}`).join("") +
    `\n}`
  );
}

const recA = file("recording.mov", "video/quicktime", "A".repeat(40));
const recB = file("recording.mov", "video/quicktime", "B".repeat(40));
const cursor = file("cursor.json", "application/json", '{"events":[1,2,3]}');
const png = file("external/0123456789ab.png", "image/png", "png-bytes");
const baseFiles = () => [recA, cursor, png];

let revision = 0;
function save(uid: string, doc: string, headers: Record<string, string> = {}, rev = revision) {
  return call(uid, "PUT", `/cloud-projects/${ID}/project`, doc, { "If-Match": `"${rev}"`, ...headers });
}

/** Save and expect 200; tracks the revision. */
async function saveOk(uid: string, doc: string, headers: Record<string, string> = {}) {
  const res = await save(uid, doc, headers);
  expect(res.status, `save by ${uid}`).toBe(200);
  const body = await json(res);
  revision = body.revision;
  return body as { revision: number; version: { id: string; seq: number; extended: boolean } };
}

/** Media + first document save (the `upload` version), in the team org. */
async function syncedProject(files = baseFiles(), extra: Record<string, unknown> = { orgId: ORG }) {
  revision = 0;
  expect((await pushMedia(files, extra)).status).toBe(200);
  return saveOk(OWNER, projectJSON());
}

interface VersionDb {
  id: string;
  seq: number;
  kind: string;
  revision: number;
  first_revision: number;
  label: string | null;
  actor_uid: string | null;
  client_kind: string;
  client_id: string | null;
  source: string;
  change_json: string | null;
  restored_from: string | null;
  merged_from_revision: number | null;
  manifest_sha: string | null;
  doc_r2_key: string;
}
const versions = () => db.query<VersionDb>(`SELECT * FROM cloud_project_versions ORDER BY seq`);
const projectRow = () =>
  db.query<{ revision: number; head_version_id: string | null; manifest_sha: string | null; doc_r2_key: string }>(
    `SELECT * FROM cloud_projects WHERE id = ?`,
    ID,
  )[0];

const web = (clientId = "web-1") => ({ "X-CC-Client": "web", "X-CC-Client-Id": clientId, "X-CC-Source": "human" });
const change = (cs: ChangeSet) => ({ "X-CC-Change": encodeChangeHeader(cs)! });
const zoomAdded: ChangeSet = { v: 1, items: { zoomRegions: { added: ["Z1"] } }, settings: {}, fields: [] };
const zoomEdited: ChangeSet = { v: 1, items: { zoomRegions: { changed: { Z1: ["zoomLevel"] } } }, settings: {}, fields: ["name"] };

function setLimits(plan: string, limits: Record<string, number>) {
  for (const [k, v] of Object.entries(limits)) {
    db.query(`UPDATE plan SET limits = json_set(limits, ?, ?) WHERE name = ?`, `$.${k}`, v, plan);
  }
}

// ---------------------------------------------------------------------------
// The versioned save
// ---------------------------------------------------------------------------

describe("versioned saves (coalescing)", () => {
  it("first save is the upload version; same actor+client edits coalesce; anything else opens a new version", async () => {
    const first = await syncedProject();
    expect(first.version).toMatchObject({ seq: 1, extended: false });
    expect(versions().map((v) => [v.seq, v.kind, v.revision])).toEqual([[1, "upload", 1]]);

    // The head is an upload → the first edit opens a version.
    at(T0 + 1 * MIN);
    const e1 = await saveOk(OWNER, projectJSON("e1"), { ...web(), ...change(zoomAdded) });
    expect(e1.version).toMatchObject({ seq: 2, extended: false });

    // Same actor + client + source, 30 s later → extends v2.
    at(T0 + 1 * MIN + 30_000);
    const e2 = await saveOk(OWNER, projectJSON("e2"), { ...web(), ...change(zoomEdited) });
    expect(e2.version).toEqual({ id: e1.version.id, seq: 2, extended: true });
    const v2 = versions()[1];
    expect([v2.first_revision, v2.revision, v2.kind, v2.client_kind, v2.client_id, v2.actor_uid]).toEqual([
      2, 3, "edit", "web", "web-1", OWNER,
    ]);
    // change_json = compose(added Z1, changed Z1) = added Z1 (+ the field).
    expect(JSON.parse(v2.change_json!)).toEqual({ v: 1, items: { zoomRegions: { added: ["Z1"] } }, settings: {}, fields: ["name"] });
    // Extending replaced revision 2's snapshot: only revisions 1 and 3 are stored.
    expect(bucket.docKeys().map((k) => k.split("/doc/")[1].split("-")[0])).toEqual(["1", "3"]);

    // Another browser of the same user → new version.
    at(T0 + 2 * MIN);
    expect((await saveOk(OWNER, projectJSON("e3"), web("web-2"))).version.extended).toBe(false);
    // Another actor (a teammate) → new version, attributed to them.
    at(T0 + 2 * MIN + 10_000);
    const m1 = await saveOk(MEMBER, projectJSON("m1"), web("web-9"));
    expect(m1.version.extended).toBe(false);
    expect(versions().at(-1)!.actor_uid).toBe(MEMBER);
    // A different source (agent) → new version.
    at(T0 + 2 * MIN + 20_000);
    expect((await saveOk(MEMBER, projectJSON("m2"), { ...web("web-9"), "X-CC-Source": "agent" })).version.extended).toBe(false);
    // Same again → extends.
    at(T0 + 2 * MIN + 30_000);
    expect((await saveOk(MEMBER, projectJSON("m3"), { ...web("web-9"), "X-CC-Source": "agent" })).version.extended).toBe(true);
    // Idle ≥ 3 min → new version.
    at(T0 + 6 * MIN);
    const idle = await saveOk(MEMBER, projectJSON("m4"), { ...web("web-9"), "X-CC-Source": "agent" });
    expect(idle.version.extended).toBe(false);
    // Saves every 2 min keep extending until the version is 10 min old.
    for (const t of [8, 10, 12, 14]) {
      at(T0 + t * MIN);
      const r = await saveOk(MEMBER, projectJSON(`m@${t}`), { ...web("web-9"), "X-CC-Source": "agent" });
      expect(r.version, `t=${t}`).toEqual({ id: idle.version.id, seq: idle.version.seq, extended: true });
    }
    at(T0 + 16 * MIN);
    expect((await saveOk(MEMBER, projectJSON("m@16"), { ...web("web-9"), "X-CC-Source": "agent" })).version.extended).toBe(
      false,
    );
    // Seqs are dense and unique; every version's snapshot exists.
    const all = versions();
    expect(all.map((v) => v.seq)).toEqual(all.map((_, i) => i + 1));
    for (const v of all) expect(bucket.objects.has(v.doc_r2_key)).toBe(true);
    expect(projectRow().head_version_id).toBe(all.at(-1)!.id);
  });

  it("checkpoints force a new version at most once a minute; a merge records its source revision", async () => {
    await syncedProject();
    at(T0 + MIN);
    await saveOk(OWNER, projectJSON("a"), web());
    at(T0 + MIN + 5_000);
    const push = await saveOk(OWNER, projectJSON("b"), { ...web(), "X-CC-Checkpoint": "push" });
    expect(push.version.extended).toBe(false);
    at(T0 + MIN + 20_000);
    const throttled = await saveOk(OWNER, projectJSON("c"), { ...web(), "X-CC-Checkpoint": "push" });
    expect(throttled.version).toEqual({ ...push.version, extended: true });
    at(T0 + 2 * MIN + 10_000);
    const merge = await saveOk(OWNER, projectJSON("d"), { ...web(), "X-CC-Checkpoint": "merge", "X-CC-Merged-From": "3" });
    expect(merge.version.extended).toBe(false);
    expect(versions().at(-1)).toMatchObject({ kind: "merge", merged_from_revision: 3 });
  });

  it("a named head is never extended", async () => {
    await syncedProject();
    at(T0 + MIN);
    const e = await saveOk(OWNER, projectJSON("a"), web());
    expect((await call(OWNER, "PATCH", `/cloud-projects/${ID}/versions/${e.version.id}`, { label: "Keep" })).status).toBe(200);
    at(T0 + MIN + 10_000);
    expect((await saveOk(OWNER, projectJSON("b"), web())).version.extended).toBe(false);
  });

  it("old clients (no X-CC headers) keep working and still get a version", async () => {
    await syncedProject();
    at(T0 + MIN);
    const res = await save(OWNER, projectJSON("plain"));
    expect(res.status).toBe(200);
    const body = await json(res);
    revision = body.revision;
    expect(body).toMatchObject({ projectId: ID, revision: 2, version: { seq: 2, extended: false } });
    expect(versions()[1]).toMatchObject({ client_kind: "unknown", client_id: null, source: "human", change_json: null });
    // A malformed change header is ignored, never a failure.
    at(T0 + MIN + 1000);
    expect((await save(OWNER, projectJSON("x"), { "X-CC-Change": "%%%", "X-CC-Client": "toaster" })).status).toBe(200);
  });
});

describe("a lost CAS writes no version row", () => {
  it("two concurrent saves on one revision: one version, the loser's object gone", async () => {
    await syncedProject();
    const [a, b] = await Promise.all([save(OWNER, projectJSON("A"), web("a")), save(MEMBER, projectJSON("B"), web("b"))]);
    expect([a.status, b.status].sort()).toEqual([200, 409]);
    expect(versions().map((v) => v.revision)).toEqual([1, 2]);
    expect(bucket.docKeys()).toHaveLength(2);
  });

  it("the batch guard itself: a swap that misses its revision inserts, extends and backfills nothing", async () => {
    await syncedProject();
    at(T0 + MIN);
    const e = await saveOk(OWNER, projectJSON("a"), web());
    // Simulate a pre-0027 head too, so the backfill statement is exercised.
    const before = versions();
    const res = await saveVersioned(db, {
      swap: {
        uid: OWNER,
        actorUid: OWNER,
        projectId: ID,
        expectedRevision: 1, // stale: the project is at 2
        newRevision: 2,
        r2Key: "cloud-projects/owner/x/doc/2-loser.json",
        bytes: 10,
        sha256: "f".repeat(64),
        name: "loser",
        growthBytes: 0,
        limitBytes: 1e12,
        now: new Date().toISOString(),
      },
      storedBytes: 5,
      version: {
        newId: "loserversion0001",
        extendId: e.version.id,
        kind: "edit",
        clientKind: "web",
        clientId: "web-1",
        source: "human",
        extendedChangeJSON: null,
        ownChangeJSON: null,
        restoredFrom: null,
        mergedFromRevision: null,
        checkpointHonoured: true,
      },
      backfill: { id: "loserbackfill001", revision: 1, r2Key: "k", bytes: 1, sha256: "e".repeat(64), at: "t", actorUid: OWNER },
    });
    expect(res).toEqual({ swapped: false });
    expect(versions()).toEqual(before);
    expect(projectRow()).toMatchObject({ revision: 2, head_version_id: e.version.id });
    expect(db.query(`SELECT last_checkpoint_at FROM cloud_projects`)[0]).toEqual({ last_checkpoint_at: null });
  });

  it("a refused (over-quota) growing save writes no version", async () => {
    await syncedProject();
    setLimits("pro", { maxTotalStorageBytes: await storageUsageBytes(db, OWNER) });
    const res = await save(OWNER, projectJSON("Demo", { padding: "z".repeat(200) }));
    expect(res.status).toBe(413);
    expect(versions()).toHaveLength(1);
    expect(bucket.docKeys()).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------
// Media pinning
// ---------------------------------------------------------------------------

describe("versions pin their media", () => {
  it("a dropped file + finalize leaves the object stored and presignable from the old version", async () => {
    const first = await syncedProject();
    const cursorSha = await sha(cursor);
    expect((await pushMedia([recA, png])).status).toBe(200);

    // Gone from the committed set…
    const current = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/files`));
    expect(current.files.map((f: { path: string }) => f.path)).toEqual(["external/0123456789ab.png", "recording.mov"]);
    // …but the bytes and the row survive: version 1 names them.
    expect(bucket.objects.has(objectKeyOf(OWNER, cursorSha))).toBe(true);
    expect(db.query(`SELECT status FROM cloud_project_objects WHERE sha256 = ?`, cursorSha)).toEqual([{ status: "ready" }]);

    for (const uid of [OWNER, MEMBER]) {
      const res = await call(uid, "GET", `/cloud-projects/${ID}/versions/${first.version.id}`);
      expect(res.status).toBe(200);
      const body = await json(res);
      expect(body.document).toBe(projectJSON());
      expect(body.missingPaths).toEqual([]);
      const c = body.files.find((f: { path: string }) => f.path === "cursor.json");
      expect(c).toMatchObject({ sha256: cursorSha, url: `https://r2.test/${objectKeyOf(OWNER, cursorSha)}?get` });
    }

    // History reports it as removed-but-kept media; Free up releases it once
    // the version pinning it is unnamed and not the head.
    at(T0 + MIN);
    await saveOk(OWNER, projectJSON("after"), web());
    const list = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/versions`));
    expect(list).toMatchObject({ pinnedMediaBytes: cursor.bytes.byteLength, freeableBytes: cursor.bytes.byteLength });

    expect((await call(OWNER, "PATCH", `/cloud-projects/${ID}/versions/${first.version.id}`, { label: "v1" })).status).toBe(200);
    expect(await json(await call(OWNER, "GET", `/cloud-projects/${ID}/versions`))).toMatchObject({ freeableBytes: 0 });
    const keep = await json(await call(OWNER, "POST", `/cloud-projects/${ID}/history/free-up`));
    expect(keep).toMatchObject({ deletedVersions: [], releasedBytes: 0, pinnedMediaBytes: cursor.bytes.byteLength });

    expect((await call(OWNER, "PATCH", `/cloud-projects/${ID}/versions/${first.version.id}`, { label: null })).status).toBe(200);
    const used = await storageUsageBytes(db, OWNER);
    const freed = await json(await call(OWNER, "POST", `/cloud-projects/${ID}/history/free-up`));
    expect(freed).toMatchObject({
      deletedVersions: [first.version.id],
      releasedBytes: cursor.bytes.byteLength,
      pinnedMediaBytes: 0,
      freeableBytes: 0,
    });
    expect(bucket.objects.has(objectKeyOf(OWNER, cursorSha))).toBe(false);
    expect(await storageUsageBytes(db, OWNER)).toBe(used - cursor.bytes.byteLength);
    expect(db.query(`SELECT COUNT(*) AS n FROM cloud_project_manifests`)[0]).toEqual({ n: 1 }); // orphan manifest gone
  });

  it("the credit excludes pinned bytes: replacing a pinned recording at the cap is refused", async () => {
    await syncedProject([recA]);
    const used = await storageUsageBytes(db, OWNER);
    setLimits("pro", { maxTotalStorageBytes: used });
    const stage = await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([recB]));
    expect(stage.status).toBe(413);
    expect((await json(stage)).code).toBe("storage_limit_reached");

    // With room for both, the replacement lands and A stays (and counts).
    setLimits("pro", { maxTotalStorageBytes: used + recB.bytes.byteLength });
    expect((await pushMedia([recB])).status).toBe(200);
    expect(bucket.objects.has(objectKeyOf(OWNER, await sha(recA)))).toBe(true);
    expect(await storageUsageBytes(db, OWNER)).toBe(used + recB.bytes.byteLength);
  });

  it("EXPLOIT (history): a save that pins the credited object before the commit cannot carry the replacement past the cap", async () => {
    // Version 1 pins a tiny sidecar; recording A is then committed WITHOUT a
    // document save, so nothing pins it — it is legitimately credit.
    const tiny = file("cursor.json", "application/json", "{}");
    await syncedProject([tiny]);
    expect((await pushMedia([recA])).status).toBe(200);
    const used = await storageUsageBytes(db, OWNER);
    setLimits("pro", { maxTotalStorageBytes: used });

    // B is accepted on A's credit, but the finalize stops short of committing.
    const never = file("never.json", "application/json", "");
    const stage = await json(await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([recB, never])));
    for (const m of stage.missing as Array<{ sha256: string }>) {
      if (m.sha256 === (await sha(recB))) await bucket.put(objectKeyOf(OWNER, m.sha256), recB.bytes);
    }
    expect((await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`)).status).toBe(409);

    // A (non-growing) document save now pins the committed set — A included.
    at(T0 + MIN);
    await saveOk(OWNER, projectJSON(), web());
    expect(versions().at(-1)!.manifest_sha).toBe(projectRow().manifest_sha);

    // Committing B alone would keep A (pinned) AND B: past the cap. Refused.
    expect((await call(OWNER, "PUT", `/cloud-projects/${ID}`, await manifest([recB]))).status).toBe(200);
    const fin = await call(OWNER, "POST", `/cloud-projects/${ID}/finalize`);
    expect(fin.status).toBe(413);
    const files = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/files`));
    expect(files.files.map((f: { sha256: string }) => f.sha256)).toEqual([await sha(recA)]);
  });

  it("a non-growing save still works over quota (version documents are not counted)", async () => {
    await syncedProject();
    setLimits("pro", { maxTotalStorageBytes: 1 }); // far below what is stored
    for (let i = 0; i < 3; i++) {
      at(T0 + (i + 1) * 5 * MIN);
      const res = await save(OWNER, projectJSON(`D${i}`), web());
      expect(res.status, `save ${i}`).toBe(200);
      revision = (await json(res)).revision;
    }
    expect(versions()).toHaveLength(4);
    // A growing one is still refused, and leaves no version.
    expect((await save(OWNER, projectJSON("Demo", { more: "z".repeat(100) }))).status).toBe(413);
    expect(versions()).toHaveLength(4);
  });
});

// ---------------------------------------------------------------------------
// Retention
// ---------------------------------------------------------------------------

describe("retention", () => {
  /** Versions at -40 d, -20 d (named), -10 d and now (head), for `owner`. */
  async function agedHistory(owner = OWNER) {
    revision = 0;
    at(T0 - 60 * DAY);
    expect((await pushMedia(baseFiles(), { orgId: ORG }, owner)).status).toBe(200);
    const v1 = await saveOk(owner, projectJSON("v1"));
    at(T0 - 40 * DAY);
    const v2 = await saveOk(owner, projectJSON("v2"), web());
    at(T0 - 20 * DAY);
    const v3 = await saveOk(owner, projectJSON("v3"), web());
    expect((await call(owner, "PATCH", `/cloud-projects/${ID}/versions/${v3.version.id}`, { label: "Launch" })).status).toBe(
      200,
    );
    at(T0 - 10 * DAY);
    const v4 = await saveOk(owner, projectJSON("v4"), web());
    at(T0);
    const v5 = await saveOk(owner, projectJSON("v5"), web());
    return [v1, v2, v3, v4, v5].map((r) => r.version.id);
  }
  const sweep = () => sweepCloudProjectHistory(env, Date.now(), async (uid) => (await planForUser(env, uid)).limits);

  it("Pro: the save prunes unnamed versions older than 30 days; named ones are exempt", async () => {
    const [v1, v2, v3, v4, v5] = await agedHistory();
    // The saves at -40/-20/-10/0 days already pruned what had aged out.
    expect(versions().map((v) => v.id)).toEqual([v3, v4, v5]);
    expect(versions().find((v) => v.id === v3)!.label).toBe("Launch");
    // Pruned snapshots are gone from R2; kept ones are still there.
    expect(bucket.docKeys()).toHaveLength(3);
    for (const v of versions()) expect(bucket.objects.has(v.doc_r2_key)).toBe(true);
    void v1;
    void v2;
  });

  it("Business keeps 365 days", async () => {
    const ids = await agedHistory(BIZ);
    expect(versions().map((v) => v.id)).toEqual(ids);
    at(T0 + 330 * DAY);
    await sweep();
    // v1 (-60 d) and v2 (-40 d) are now > 365 days old; the named v3 stays.
    expect(versions().map((v) => v.id)).toEqual(ids.slice(2));
  });

  it("a downgrade trims on the next sweep — named versions included — and releases what only they pinned", async () => {
    const [, , v3, v4, v5] = await agedHistory();
    // Drop the cursor from the committed set, then save: only the OLDER
    // versions (v3 named, v4, v5) still pin it.
    expect((await pushMedia([recA, png])).status).toBe(200);
    at(T0 + MIN);
    const v6 = (await saveOk(OWNER, projectJSON("v6"), web("other"))).version.id;
    expect(versions().map((v) => v.id)).toEqual([v3, v4, v5, v6]);
    const cursorKey = objectKeyOf(OWNER, await sha(cursor));
    expect(bucket.objects.has(cursorKey)).toBe(true);

    db.query(`UPDATE "user" SET tester = 0 WHERE id = ?`, OWNER); // → free: 0 days, 0 named
    const res = await sweep();
    expect(res.deleted).toBe(3);
    expect(versions().map((v) => v.id)).toEqual([v6]);
    expect(bucket.objects.has(cursorKey)).toBe(false);
    expect(bucket.docKeys()).toEqual([versions()[0].doc_r2_key]);
    expect(db.query(`SELECT history_swept_at FROM cloud_projects`)[0]).toEqual({
      history_swept_at: new Date(T0 + MIN).toISOString(),
    });
  });

  it("a head that still pins removed media keeps it (the current document needs it)", async () => {
    await syncedProject();
    expect((await pushMedia([recA, png])).status).toBe(200); // no save since: the head pins the cursor
    db.query(`UPDATE "user" SET tester = 0 WHERE id = ?`, OWNER);
    await sweep();
    expect(bucket.objects.has(objectKeyOf(OWNER, await sha(cursor)))).toBe(true);
    expect(await json(await call(OWNER, "GET", `/cloud-projects/${ID}/versions`))).toMatchObject({
      pinnedMediaBytes: cursor.bytes.byteLength,
      freeableBytes: 0,
    });
  });

  it("the sweep removes manifests nothing references after an hour", async () => {
    revision = 0;
    expect((await pushMedia([recA])).status).toBe(200);
    expect((await pushMedia([recB])).status).toBe(200); // supersedes M1 before any save pinned it
    expect(db.query(`SELECT COUNT(*) AS n FROM cloud_project_manifests`)[0]).toEqual({ n: 1 }); // finalize cleans its own
    db.query(
      `INSERT INTO cloud_project_manifests (project_id, manifest_sha, files_json, created_at) VALUES (?, 'stray', '[]', ?)`,
      ID, new Date(T0 - 2 * 3600 * 1000).toISOString(),
    );
    await sweep();
    expect(db.query(`SELECT manifest_sha FROM cloud_project_manifests`)).toEqual([{ manifest_sha: projectRow().manifest_sha }]);
  });
});

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

describe("permission matrix (owner, member, non-member, blocked) on every history route", () => {
  it("members read, name and restore; only the owner deletes and frees", async () => {
    const v1 = (await syncedProject()).version.id;
    at(T0 + MIN);
    const v2 = (await saveOk(OWNER, projectJSON("two"), web())).version.id;
    at(T0 + 2 * MIN);
    const v3 = (await saveOk(MEMBER, projectJSON("three"), web("m"))).version.id;

    const base = `/cloud-projects/${ID}`;
    type Row = [string, () => Response | Promise<Response>, number];
    const restore = (uid: string) => call(uid, "POST", `${base}/versions/${v1}/restore`, undefined, { "If-Match": `"${revision}"` });
    const matrix: Row[] = [];
    for (const [uid, read, write] of [
      [OWNER, 200, 200],
      [MEMBER, 200, 200],
      [STRANGER, 404, 404],
      [BLOCKED, 403, 403],
    ] as const) {
      matrix.push(
        [`${uid} head`, () => call(uid, "GET", `${base}/head`), read],
        [`${uid} versions`, () => call(uid, "GET", `${base}/versions`), read],
        [`${uid} version`, () => call(uid, "GET", `${base}/versions/${v2}`), read],
        [`${uid} revision document`, () => call(uid, "GET", `${base}/revisions/1/document`), read],
        [`${uid} name`, () => call(uid, "PATCH", `${base}/versions/${v2}`, { label: `by ${uid}` }), write],
      );
    }
    for (const [label, run, expected] of matrix) expect((await run()).status, label).toBe(expected);

    // Restore: non-member / blocked refused, member and owner allowed.
    expect((await restore(STRANGER)).status).toBe(404);
    expect((await restore(BLOCKED)).status).toBe(403);
    const byMember = await restore(MEMBER);
    expect(byMember.status).toBe(200);
    revision = (await json(byMember)).revision;
    at(T0 + 3 * MIN);
    const byOwner = await restore(OWNER);
    expect(byOwner.status).toBe(200);
    revision = (await json(byOwner)).revision;

    // Delete a version / free up: owner only.
    for (const [uid, status] of [[MEMBER, 403], [STRANGER, 404], [BLOCKED, 403]] as const) {
      expect((await call(uid, "DELETE", `${base}/versions/${v3}`)).status, `${uid} delete`).toBe(status);
      expect((await call(uid, "POST", `${base}/history/free-up`)).status, `${uid} free-up`).toBe(status);
    }
    expect((await call(OWNER, "POST", `${base}/history/free-up`)).status).toBe(200);
    expect((await call(OWNER, "DELETE", `${base}/versions/${v3}`)).status).toBe(200);
    expect(versions().some((v) => v.id === v3)).toBe(false);

    // No session at all → 401 from a trusted origin; a cross-site cookie
    // write never gets that far.
    for (const [method, path] of [
      ["GET", `${base}/head`],
      ["GET", `${base}/versions`],
      ["GET", `${base}/versions/${v2}`],
      ["GET", `${base}/revisions/1/document`],
      ["PATCH", `${base}/versions/${v2}`],
      ["POST", `${base}/versions/${v2}/restore`],
      ["DELETE", `${base}/versions/${v2}`],
      ["POST", `${base}/history/free-up`],
    ] as const) {
      expect((await call(null, method, path, undefined, { Origin: "https://app.capturecat.so" })).status, `${method} ${path}`).toBe(
        401,
      );
      if (method !== "GET") expect((await call(null, method, path, undefined, { Origin: "https://evil.test" })).status).toBe(403);
    }
  });

  it("members lose history with the owner's team access", async () => {
    const v1 = (await syncedProject()).version.id;
    db.query(`UPDATE "user" SET tester = 0 WHERE id = ?`, OWNER);
    for (const path of ["head", "versions", `versions/${v1}`, "revisions/1/document"]) {
      expect((await call(MEMBER, "GET", `/cloud-projects/${ID}/${path}`)).status, path).toBe(404);
    }
    expect((await call(OWNER, "GET", `/cloud-projects/${ID}/versions`)).status).toBe(200);
  });
});

describe("history routes", () => {
  it("head, versions (with actor names, retention, paging), version, revision documents", async () => {
    const v1 = (await syncedProject()).version.id;
    at(T0 + MIN);
    const v2 = (await saveOk(MEMBER, projectJSON("two"), { ...web("m"), ...change(zoomAdded) })).version.id;

    const head = await json(await call(MEMBER, "GET", `/cloud-projects/${ID}/head`));
    expect(head).toEqual({
      projectId: ID,
      revision: 2,
      documentSha256: await sha256Hex(projectJSON("two")),
      updatedAt: new Date(T0 + MIN).toISOString(),
      updatedBy: MEMBER,
      headVersionId: v2,
    });

    const list = await json(await call(MEMBER, "GET", `/cloud-projects/${ID}/versions`));
    expect(list.retention).toEqual({ maxHistoryDays: 30, maxNamedVersions: 25, namedCount: 0 });
    expect(list.versions.map((v: { id: string }) => v.id)).toEqual([v2, v1]);
    expect(list.versions[0]).toMatchObject({
      seq: 2,
      kind: "edit",
      isHead: true,
      actor: { uid: MEMBER, name: "member name" },
      client: "web",
      source: "human",
      revision: 2,
      change: { v: 1, items: { zoomRegions: { added: ["Z1"] } }, settings: {}, fields: [] },
    });
    expect(list.versions[1]).toMatchObject({ kind: "upload", isHead: false, actor: { uid: OWNER, name: "owner name" }, change: null });
    const page = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/versions?limit=1`));
    expect(page.versions.map((v: { id: string }) => v.id)).toEqual([v2]);
    expect(page.nextBefore).toBe(2);
    const next = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/versions?limit=1&before=2`));
    expect(next.versions.map((v: { id: string }) => v.id)).toEqual([v1]);

    const rev1 = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/revisions/1/document`));
    expect(rev1).toMatchObject({ revision: 1, versionId: v1, document: projectJSON() });
    // Extend v2 → revision 2 is no longer retained (only a version's head is).
    at(T0 + MIN + 10_000);
    await saveOk(MEMBER, projectJSON("three"), web("m"));
    const gone = await call(OWNER, "GET", `/cloud-projects/${ID}/revisions/2/document`);
    expect(gone.status).toBe(404);
    expect((await json(gone)).code).toBe("revision_not_retained");
    expect((await json(await call(OWNER, "GET", `/cloud-projects/${ID}/revisions/3/document`))).document).toBe(projectJSON("three"));

    expect((await call(OWNER, "GET", `/cloud-projects/${ID}/versions/nope`)).status).toBe(400);
    expect((await call(OWNER, "GET", `/cloud-projects/${ID}/versions/abcdefgh12345678`)).status).toBe(404);
  });

  it("naming is capped by the OWNER's plan", async () => {
    const v1 = (await syncedProject()).version.id;
    at(T0 + MIN);
    const v2 = (await saveOk(OWNER, projectJSON("two"), web())).version.id;
    setLimits("pro", { maxNamedVersions: 1 });
    const name = (uid: string, vid: string, label: string | null) =>
      call(uid, "PATCH", `/cloud-projects/${ID}/versions/${vid}`, { label });
    const named = await name(MEMBER, v1, "  First cut ");
    expect(named.status).toBe(200);
    expect((await json(named)).version).toMatchObject({ label: "First cut", namedBy: { uid: MEMBER, name: "member name" } });
    const capped = await name(MEMBER, v2, "Second");
    expect(capped.status).toBe(402);
    expect(await json(capped)).toMatchObject({ code: "named_version_limit", limit: 1 });
    expect((await name(OWNER, v1, "Renamed")).status).toBe(200); // renaming is not a new slot
    expect((await name(OWNER, v1, null)).status).toBe(200);
    expect((await name(OWNER, v2, "Second")).status).toBe(200);
    expect((await name(OWNER, v2, "bad\u0000label")).status).toBe(400);
    expect(versions().map((v) => v.label)).toEqual([null, "Second"]);
    // A plan with no named versions at all.
    setLimits("pro", { maxNamedVersions: 0 });
    expect((await name(OWNER, v1, "x")).status).toBe(402);
  });

  it("restore re-commits the version's paths (they win; current ones stay) and opens a new version", async () => {
    const v1 = (await syncedProject()).version.id;
    const voice = file("voiceover.m4a", "audio/mp4", "voice-bytes");
    // Replace the recording, drop the cursor, add a voice-over; save.
    expect((await pushMedia([recB, png, voice])).status).toBe(200);
    at(T0 + MIN);
    await saveOk(OWNER, projectJSON("edited"), web());
    const mediaBefore = db.query(`SELECT sha256 FROM cloud_project_objects ORDER BY sha256`);

    expect((await call(MEMBER, "POST", `/cloud-projects/${ID}/versions/${v1}/restore`)).status).toBe(428);
    const stale = await call(MEMBER, "POST", `/cloud-projects/${ID}/versions/${v1}/restore`, undefined, { "If-Match": '"1"' });
    expect(stale.status).toBe(409);
    expect((await json(stale)).code).toBe("revision_conflict");

    at(T0 + 2 * MIN);
    const res = await call(MEMBER, "POST", `/cloud-projects/${ID}/versions/${v1}/restore`, undefined, {
      "If-Match": '"2"',
      ...web("m"),
    });
    expect(res.status).toBe(200);
    const body = await json(res);
    expect(body).toMatchObject({ revision: 3, restoredFrom: v1, version: { seq: 3, extended: false }, fileCount: 4 });
    expect(versions().at(-1)).toMatchObject({ kind: "restore", restored_from: v1, actor_uid: MEMBER, revision: 3 });

    const got = await json(await call(OWNER, "GET", `/cloud-projects/${ID}`));
    expect(got.revision).toBe(3);
    expect(got.document).toBe(projectJSON());
    expect(got.files.map((f: { path: string; sha256: string }) => [f.path, f.sha256])).toEqual([
      ["cursor.json", await sha(cursor)],
      ["external/0123456789ab.png", await sha(png)],
      ["recording.mov", await sha(recA)],
      ["voiceover.m4a", await sha(voice)],
    ]);
    // No bytes added or lost: B stays (version 2 pins it).
    expect(db.query(`SELECT sha256 FROM cloud_project_objects ORDER BY sha256`)).toEqual(mediaBefore);
    // The restore's version pins the restored set; its snapshot is its own copy.
    const [restored] = versions().slice(-1);
    expect(restored.manifest_sha).toBe(projectRow().manifest_sha);
    expect(restored.doc_r2_key).not.toBe(versions()[0].doc_r2_key);
    expect(await gunzipText(bucket.objects.get(restored.doc_r2_key)!.bytes)).toBe(projectJSON());
  });

  it("delete: never the head; removes the snapshot", async () => {
    const v1 = (await syncedProject()).version.id;
    at(T0 + MIN);
    const v2 = (await saveOk(OWNER, projectJSON("two"), web())).version.id;
    const head = await call(OWNER, "DELETE", `/cloud-projects/${ID}/versions/${v2}`);
    expect(head.status).toBe(409);
    expect((await json(head)).code).toBe("head_version");
    const key = versions()[0].doc_r2_key;
    expect((await call(OWNER, "DELETE", `/cloud-projects/${ID}/versions/${v1}`)).status).toBe(200);
    expect(bucket.objects.has(key)).toBe(false);
    expect((await call(OWNER, "DELETE", `/cloud-projects/${ID}/versions/${v1}`)).status).toBe(404);
  });

  it("deleting the project deletes every snapshot", async () => {
    await syncedProject();
    at(T0 + MIN);
    await saveOk(OWNER, projectJSON("two"), web());
    expect(bucket.docKeys()).toHaveLength(2);
    expect((await call(OWNER, "DELETE", `/cloud-projects/${ID}`)).status).toBe(200);
    expect(bucket.objects.size).toBe(0);
    expect(db.query(`SELECT COUNT(*) AS n FROM cloud_project_versions`)[0]).toEqual({ n: 0 });
  });
});

// ---------------------------------------------------------------------------
// Migration 0027 on existing data
// ---------------------------------------------------------------------------

describe("migration 0027", () => {
  it("applies over live 0026 data without touching it, sets the plan limits, and the project then versions lazily", async () => {
    const old = createTestD1({ before: "0027" });
    const now = new Date().toISOString();
    for (const uid of [OWNER, MEMBER]) {
      old.query(
        `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked)
         VALUES (?, ?, ?, 1, ?, ?, 1, 0)`,
        uid, uid, `${uid}@test.local`, now, now,
      );
    }
    const docKey = `cloud-projects/${OWNER}/${ID}/doc/3-legacy00000.json`;
    const doc = projectJSON("Legacy");
    const docBytes = new TextEncoder().encode(doc);
    old.query(
      `INSERT INTO cloud_projects (id, owner_uid, name, revision, doc_r2_key, doc_bytes, doc_sha256, total_bytes, created_at, updated_at, updated_by)
       VALUES (?, ?, 'Legacy', 3, ?, ?, ?, ?, ?, ?, ?)`,
      ID, OWNER, docKey, docBytes.byteLength, await sha256Hex(docBytes), docBytes.byteLength + 40, now, now, OWNER,
    );
    const aSha = await sha(recA);
    old.query(
      `INSERT INTO cloud_project_objects (project_id, sha256, owner_uid, bytes, content_type, r2_key, status, created_at, uploaded_at)
       VALUES (?, ?, ?, 40, 'video/quicktime', ?, 'ready', ?, ?)`,
      ID, aSha, OWNER, objectKeyOf(OWNER, aSha), now, now,
    );
    old.query(
      `INSERT INTO cloud_project_files (project_id, path, sha256, bytes, content_type, r2_key, uploaded_at)
       VALUES (?, 'recording.mov', ?, 40, 'video/quicktime', ?, ?)`,
      ID, aSha, objectKeyOf(OWNER, aSha), now,
    );
    const before = old.query(`SELECT * FROM cloud_projects`)[0];
    // What the 0026 Worker counted: the verified object plus the document.
    // (Spelled out: today's storage sum reads columns from later migrations.)
    const usedBefore = 40 + docBytes.byteLength;

    old.migrate("0027_project_history.sql");
    // Everything after 0027, as production applies it before the new Worker.
    for (const later of ["0028_plan_stripe_sync.sql", "0029_custom_storage.sql"]) old.migrate(later);

    expect(old.query(`SELECT * FROM cloud_projects`)[0]).toEqual({
      ...before,
      head_version_id: null,
      next_version_seq: 1,
      manifest_sha: null,
      last_checkpoint_at: null,
      history_swept_at: null,
    });
    expect(await storageUsageBytes(old, OWNER)).toBe(usedBefore);
    const limits = (name: string) =>
      old.query<{ d: number; n: number }>(
        `SELECT json_extract(limits, '$.maxHistoryDays') AS d, json_extract(limits, '$.maxNamedVersions') AS n FROM plan WHERE name = ?`,
        name,
      )[0];
    expect(limits("pro")).toEqual({ d: 30, n: 25 });
    expect(limits("business")).toEqual({ d: 365, n: 500 });
    expect(limits("free")).toEqual({ d: 0, n: 0 });

    // The new Worker over the migrated rows: reads, then a save, version it.
    db = old;
    env = { ...env, DB: old } as Env;
    await bucket.put(docKey, docBytes, { httpMetadata: { contentType: "application/json" } });
    expect((await json(await call(OWNER, "GET", `/cloud-projects/${ID}`))).document).toBe(doc);
    revision = 3;
    at(T0 + MIN);
    const saved = await saveOk(OWNER, projectJSON("Legacy 2"), web());
    expect(saved.version).toMatchObject({ seq: 2, extended: false });
    expect(versions().map((v) => [v.kind, v.revision, v.doc_r2_key === docKey])).toEqual([
      ["upload", 3, true],
      ["edit", 4, false],
    ]);
    expect(versions()[0].manifest_sha).toBe(projectRow().manifest_sha); // legacy media pinned
  });
});

// ---------------------------------------------------------------------------
// gzip + projects saved before 0027
// ---------------------------------------------------------------------------

describe("snapshots: gzip, and documents saved before 0027", () => {
  /** Turn the synced project into what 0027 found in production: a raw
   *  document object, no versions, no manifests. */
  async function makeLegacy() {
    await syncedProject();
    const key = projectRow().doc_r2_key;
    await bucket.put(key, new TextEncoder().encode(projectJSON()), { httpMetadata: { contentType: "application/json" } });
    db.query(`DELETE FROM cloud_project_versions`);
    db.query(`DELETE FROM cloud_project_manifest_objects`);
    db.query(`DELETE FROM cloud_project_manifests`);
    db.query(`UPDATE cloud_projects SET head_version_id = NULL, manifest_sha = NULL, next_version_seq = 1`);
    return key;
  }

  it("new snapshots are gzip and read back byte-exact", async () => {
    await syncedProject();
    const odd = projectJSON("Démo 🎬", { weird: "  \\ \"q\"" }).replace(/\n/g, "\r\n");
    at(T0 + MIN);
    await saveOk(OWNER, odd, web());
    const key = projectRow().doc_r2_key;
    expect(bucket.objects.get(key)!.customMetadata).toEqual({ enc: "gzip" });
    expect(bucket.objects.get(key)!.bytes.byteLength).not.toBe(new TextEncoder().encode(odd).byteLength);
    expect((await json(await call(OWNER, "GET", `/cloud-projects/${ID}`))).document).toBe(odd);
    expect((await json(await call(OWNER, "GET", `/cloud-projects/${ID}/revisions/2/document`))).document).toBe(odd);
  });

  it("old raw documents still read, and the first history read backfills their version", async () => {
    const key = await makeLegacy();
    expect((await json(await call(OWNER, "GET", `/cloud-projects/${ID}`))).document).toBe(projectJSON());
    expect((await json(await call(OWNER, "GET", `/cloud-projects/${ID}/revisions/1/document`))).document).toBe(projectJSON());

    const list = await json(await call(MEMBER, "GET", `/cloud-projects/${ID}/versions`));
    expect(list.versions).toHaveLength(1);
    expect(list.versions[0]).toMatchObject({ kind: "upload", revision: 1, isHead: true, actor: { uid: OWNER } });
    const [v1] = versions();
    expect(v1.doc_r2_key).toBe(key);
    expect(v1.manifest_sha).not.toBeNull(); // the legacy media is pinned now
    const detail = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/versions/${v1.id}`));
    expect(detail.document).toBe(projectJSON());
    expect(detail.files).toHaveLength(3);
    // Idempotent.
    await call(OWNER, "GET", `/cloud-projects/${ID}/versions`);
    expect(versions()).toHaveLength(1);
  });

  it("the first save of a pre-0027 project records its current document as the upload version, in the same batch", async () => {
    const key = await makeLegacy();
    at(T0 + MIN);
    const res = await saveOk(MEMBER, projectJSON("after migration"), web("m"));
    expect(res.version).toMatchObject({ seq: 2, extended: false });
    expect(versions().map((v) => [v.seq, v.kind, v.revision, v.actor_uid])).toEqual([
      [1, "upload", 1, OWNER],
      [2, "edit", 2, MEMBER],
    ]);
    expect(versions()[0].doc_r2_key).toBe(key);
    expect(bucket.objects.has(key)).toBe(true); // kept: version 1's (raw) snapshot
    expect(bucket.objects.get(key)!.customMetadata).toBeUndefined();
    // Its media is pinned: dropping the cursor keeps it.
    expect((await pushMedia([recA, png])).status).toBe(200);
    expect(bucket.objects.has(objectKeyOf(OWNER, await sha(cursor)))).toBe(true);
    const v1 = await json(await call(OWNER, "GET", `/cloud-projects/${ID}/versions/${versions()[0].id}`));
    expect(v1.document).toBe(projectJSON());
  });
});
