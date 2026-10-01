/**
 * The web history client against the API's REAL route handlers — not mocks
 * that agree with themselves (docs/project-history.md §6).
 *
 * The Hono routers (`routes/cloud-projects.ts` + `routes/cloud-project-history.ts`)
 * run in this process exactly as the API's own route tests run them: every
 * migration and SQL statement through node:sqlite (`test-support/d1-sqlite.js`),
 * R2 in memory (`test-support/memory-bucket.ts`), and the Better Auth session
 * store replaced by `test-support/fake-session.ts` (bearer = uid; the user row
 * — tester / blocked — read from D1). The S3 presigner is stubbed (it only
 * signs URLs) and the Cache API always misses.
 *
 * `fetch` is the seam: the web client's requests to API_URL go to
 * `app.request(...)` with the signed-in user's bearer (the browser sends the
 * session cookie); a presigned PUT to `https://r2.test/<key>` lands in the
 * memory bucket. Everything above it — cloud.ts, the store's merge + save
 * headers, HistoryController, ProjectMedia's storage-cap path — is the real
 * web code.
 *
 * The API sources are imported by computed path so the web's `tsc` does not
 * type-check Worker code under the web's settings.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

import { API_URL } from "@/lib/api-url";
import { newProject, serializeProjectText } from "../core/model";
import {
  CloudApiError,
  deleteProjectVersion,
  finalizeCloudProject,
  getCloudHead,
  getProjectVersion,
  getRevisionDocument,
  listProjectVersions,
  loadCloudProject,
  saveCloudProject,
  stageCloudProject,
  type ManifestFile,
  type SaveHistoryMeta,
} from "./cloud";
import { cloudHistoryApi, historyErrorMessage, HistoryController } from "./history";
import { HistoryStorageError, ProjectMedia } from "./projectMedia";
import { EditorStore, type Persistence } from "./store";

const API_SRC = new URL("../../../../api/src/", import.meta.url);
const api = (path: string) => new URL(path, API_SRC).pathname;

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- Worker types live in the API package
type Any = any;

let app: { request(path: string, init: RequestInit, env: unknown): Promise<Response> };
let createTestD1: () => Any;
let MemoryBucket: new () => Any;

async function loadApi(): Promise<void> {
  vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined } });
  vi.doMock(api("lib/auth.ts"), () => import(/* @vite-ignore */ api("test-support/fake-session.ts")));
  vi.doMock(api("lib/presign.ts"), () => ({
    createPresignedUploadUrl: async (o: { key: string }) => `https://r2.test/${o.key}?put`,
    createPresignedDownloadUrl: async (o: { key: string }) => `https://r2.test/${o.key}?get`,
    headR2ObjectMeta: async () => null,
    headR2Object: async () => null,
  }));
  const { Hono } = await import("hono");
  const { cloudProjectRoutes } = await import(/* @vite-ignore */ api("routes/cloud-projects.ts"));
  const { cloudProjectHistoryRoutes } = await import(/* @vite-ignore */ api("routes/cloud-project-history.ts"));
  ({ createTestD1 } = await import(/* @vite-ignore */ api("test-support/d1-sqlite.js")));
  ({ MemoryBucket } = await import(/* @vite-ignore */ api("test-support/memory-bucket.ts")));
  const hono = new Hono();
  hono.route("/api", cloudProjectRoutes);
  hono.route("/api", cloudProjectHistoryRoutes);
  app = hono as unknown as typeof app;
}

/**
 * The API's packages must be installed (apps/api/node_modules — a worktree
 * links the main checkout's). Without them the suite is SKIPPED, loudly;
 * any other load failure fails it.
 */
const loadError = await loadApi().then(
  () => null,
  (e: unknown) => e,
);
const missingApiDeps = loadError instanceof Error && /Cannot find package|Failed to load url/.test(loadError.message) ? loadError.message : null;
if (loadError && !missingApiDeps) throw loadError;
if (missingApiDeps) console.warn(`history.contract.test SKIPPED — the API's dependencies are not installed (${missingApiDeps}). Link apps/api/node_modules to run it.`);
const contract = missingApiDeps ? describe.skip : describe;


// ── Fixture: an org with a Pro owner (tester → pro) and a member ────────────

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const ID2 = "3F2504E0-4F89-11D3-9A0C-0305E82C3302";
const OWNER = "owner";
const ANA = "ana";
const ORG = "org1";

let db: Any;
let bucket: Any;
let env: Any;
/** Who the browser is signed in as. */
let caller = OWNER;

beforeEach(() => {
  if (missingApiDeps) return;
  db = createTestD1();
  bucket = new MemoryBucket();
  env = { DB: db, R2: bucket, R2_ENDPOINT: "https://account.r2.test", R2_ACCESS_KEY_ID: "k", R2_SECRET_ACCESS_KEY: "s" };
  caller = OWNER;
  const now = new Date().toISOString();
  for (const [uid, name] of [
    [OWNER, "Mike"],
    [ANA, "Ana"],
  ]) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked) VALUES (?, ?, ?, 1, ?, ?, 1, 0)`,
      uid,
      name,
      `${uid}@test.local`,
      now,
      now,
    );
  }
  db.query(`INSERT INTO "organization" (id, name, slug, createdAt) VALUES (?, 'Team', 'team', ?)`, ORG, now);
  for (const uid of [OWNER, ANA]) {
    db.query(`INSERT INTO "member" (id, organizationId, userId, role, createdAt) VALUES (?, ?, ?, 'member', ?)`, `m-${uid}`, ORG, uid, now);
  }
  const apiOrigin = new URL(API_URL).origin;
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    if (url.origin === apiOrigin) {
      const headers = new Headers(init.headers);
      headers.set("Authorization", `Bearer ${caller}`); // the session cookie, in the fake session's terms
      const { credentials: _credentials, cache: _cache, ...rest } = init;
      return app.request(url.pathname + url.search, { ...rest, headers }, env);
    }
    if (url.origin === "https://r2.test" && init.method === "PUT") {
      await bucket.put(url.pathname.slice(1), new Uint8Array(await (init.body as Blob).arrayBuffer()));
      return new Response(null, { status: 200 });
    }
    throw new Error(`unexpected fetch ${url.href}`);
  });
});

const enc = (s: string) => new TextEncoder().encode(s);
async function sha256(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface Media {
  path: string;
  contentType: string;
  bytes: Uint8Array;
}
const media = (path: string, contentType: string, content: string): Media => ({ path, contentType, bytes: enc(content) });
const MEDIA = 40_000;
const recA = media("recording.mov", "video/quicktime", "A".repeat(MEDIA));
const recB = media("recording.mov", "video/quicktime", "B".repeat(MEDIA));
const recC = media("recording.mov", "video/quicktime", "C".repeat(MEDIA));
const cursor = media("cursor.json", "application/json", '{"events":[1,2,3]}');

async function manifestOf(files: Media[]): Promise<ManifestFile[]> {
  return Promise.all(files.map(async (f) => ({ path: f.path, sha256: await sha256(f.bytes), bytes: f.bytes.byteLength, contentType: f.contentType })));
}

/** The web's stage → presigned PUT → finalize (record/publish.ts minus its XHR), through the web client. */
async function commitMedia(projectId: string, manifest: ManifestFile[], blobFor: (sha: string) => Blob | undefined, orgId?: string) {
  const stage = await stageCloudProject(projectId, { name: "Launch", files: manifest, ...(orgId ? { orgId } : null) });
  for (const target of stage.missing) {
    const blob = blobFor(target.sha256);
    if (!blob) throw new Error("asked for a file we do not have");
    const res = await fetch(target.uploadUrl, { method: "PUT", body: blob });
    if (!res.ok) throw new Error("put failed");
  }
  const fin = await finalizeCloudProject(projectId);
  if (!fin.committed) throw new Error(`finalize: ${JSON.stringify(fin)}`);
  return stage;
}

async function pushMedia(projectId: string, files: Media[], orgId?: string) {
  const bySha = new Map(await Promise.all(files.map(async (f) => [await sha256(f.bytes), new Blob([f.bytes as BlobPart])] as const)));
  return commitMedia(projectId, await manifestOf(files), (s) => bySha.get(s), orgId);
}

function projectText(id: string, mut?: (j: Record<string, Any>) => void): string {
  const p = newProject({ id, duration: 12, videoURL: `file:///Users/m/Library/Application%20Support/CaptureCat/Projects/${id}/recording.mov` });
  const j = JSON.parse(serializeProjectText(p));
  j.name = "Launch";
  j.futureKeyFromANewerMac = { nested: [1, 2.5, "x"] };
  mut?.(j);
  return JSON.stringify(j, null, 2);
}

const WEB = (clientId: string): SaveHistoryMeta => ({ client: "web", clientId, source: "human" });

/** The page's persistence (EditorPage): save + the X-CC-* headers from the store's SaveMeta. */
function persistence(projectId: string, clientId: string): Persistence {
  return {
    save: async (document, baseRevision, meta) => {
      const r = await saveCloudProject(projectId, document, baseRevision, { history: meta ? { client: "web", clientId, ...meta } : undefined });
      return r.ok
        ? { ok: true, revision: r.revision }
        : { ok: false, conflict: true, revision: r.revision, document: r.document, updatedAt: r.updatedAt, headVersionId: r.headVersionId };
    },
  };
}

async function until(cond: () => boolean, label: string, ms = 5000) {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) throw new Error(`timed out: ${label}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

contract("web history client × the API's real routes", () => {
  it("saves with X-CC-* headers, merges a 409 (merge version, who), names, previews, restores, refuses what §6.1 refuses", async () => {
    await pushMedia(ID, [recA, cursor], ORG);

    // First save (the `upload` version) and the document comes back byte-exact.
    const first = projectText(ID);
    const saved = await saveCloudProject(ID, first, 0, { history: WEB("browser-1") });
    expect(saved).toMatchObject({ ok: true, revision: 1, version: { seq: 1, extended: false } });
    const loaded = await loadCloudProject(ID);
    expect(loaded.document).toBe(first);

    // The editor store, saving through the real route.
    const store = new EditorStore();
    store.load({ text: loaded.document!, origin: "cloud", revision: loaded.revision, persistence: persistence(ID, "browser-1") });
    const confirm = vi.fn(async () => 0);
    const h = new HistoryController({ store, api: cloudHistoryApi(ID), isOwner: true, confirm });

    store.updateSettings({ backgroundPadding: 30 });
    await store.flush();
    expect(store.getState()).toMatchObject({ revision: 2, sync: "saved", dirty: false });

    // Ana edits the name from her Mac in between.
    caller = ANA;
    const theirs = projectText(ID, (j) => (j.name = "Launch — Ana's cut"));
    const anaSave = await saveCloudProject(ID, theirs.replace('"backgroundPadding": 40', '"backgroundPadding": 30'), 2, {
      history: { client: "mac", clientId: "ana-mac", source: "human" },
    });
    expect(anaSave.ok).toBe(true);
    caller = OWNER;

    // Our next save collides → the store merges three ways and saves the merge.
    store.updateSettings({ cornerRadius: 22 });
    await store.flush();
    await until(() => store.getState().sync === "saved" && !store.getState().dirty, "merge save");
    const head = await loadCloudProject(ID);
    const merged = JSON.parse(head.document!);
    expect(merged.name).toBe("Launch — Ana's cut");
    expect(merged.settings.cornerRadius).toBe(22);
    expect(merged.futureKeyFromANewerMac).toEqual({ nested: [1, 2.5, "x"] });
    expect(store.getState().undoLabel).toBe("Merge Changes");
    // The 409 named theirs' version; the callout learns who with the cheapest call.
    const notice = store.getState().mergeNotice!;
    expect(notice.headVersionId).toBeTruthy();
    await until(() => h.getState().mergedFrom != null, "merge author");
    expect(h.getState().mergedFrom!.who).toBe("Ana (Mac)");

    // The list, as the API returns it (§6.1).
    await h.refresh();
    const s = h.getState();
    expect(s).toMatchObject({ status: "ready", access: "owner", retention: { days: 30, maxNamed: 25, namedCount: 0 } });
    const [mergeV, anaV, ...rest] = s.versions;
    expect(mergeV).toMatchObject({ kind: "merge", clientKind: "web", source: "human", actorName: "Mike", mergedFromRevision: anaV.revision, isHead: true });
    expect(anaV).toMatchObject({ kind: "edit", clientKind: "mac", actorName: "Ana", id: notice.headVersionId });
    expect(mergeV.change).toMatchObject({ v: 1, settings: { background: ["cornerRadius"] } });
    const uploadV = rest[rest.length - 1];
    expect(uploadV).toMatchObject({ kind: "upload", seq: 1 });
    expect(s.headVersionId).toBe(mergeV.id);

    // Name (PATCH), and the API's refusals said plainly.
    expect(await h.commitName(uploadV.id, "  First cut ")).toBe(true);
    expect(h.version(uploadV.id)!.label).toBe("First cut");
    expect(await h.commitName(anaV.id, "bad\u0007name")).toBe(false);
    expect(h.getState().message).toBe("Couldn’t name it. Names can be up to 100 characters, on one line.");
    const headDelete = await deleteProjectVersion(ID, mergeV.id).catch((e: unknown) => e);
    expect(headDelete).toBeInstanceOf(CloudApiError);
    expect(historyErrorMessage(headDelete)).toBe("The current version can’t be deleted.");

    // Preview the upload version (its own manifest), then restore it — one undo step.
    await h.preview(uploadV.id);
    expect(store.getState().preview).toMatchObject({ versionId: uploadV.id });
    expect(store.documentText()).toBe(first);
    expect(await h.restore(uploadV.id)).toBe(true);
    expect(store.getState()).toMatchObject({ preview: null, undoLabel: "Restore Version", dirty: false });
    const restoredHead = await loadCloudProject(ID);
    expect(restoredHead.document).toBe(first);
    expect(store.getState().revision).toBe(restoredHead.revision);
    await h.refresh();
    expect(h.getState().versions[0]).toMatchObject({ kind: "restore", restoredFrom: uploadV.id, isHead: true });

    // A restore that loses the race merges the head instead.
    caller = ANA;
    await saveCloudProject(ID, projectText(ID, (j) => (j.name = "Ana again")), restoredHead.revision, { history: { client: "mac", clientId: "ana-mac", source: "human" } });
    caller = OWNER;
    expect(await h.restore(anaV.id)).toBe(false);
    expect(h.getState().message).toMatch(/Someone saved while you were restoring/);
    await until(() => store.getState().sync === "saved", "race merge");
    expect(store.getState().project!.name).toBe("Ana again");

    // Head + a retained revision.
    const cloudHead = await getCloudHead(ID);
    expect(cloudHead).toMatchObject({ revision: store.getState().revision, updatedBy: ANA });
    expect(await getRevisionDocument(ID, 1)).toBe(first);

    // 410: the version's stored document is gone.
    const [{ doc_r2_key }] = db.query(`SELECT doc_r2_key FROM cloud_project_versions WHERE id = ?`, anaV.id);
    await bucket.delete(doc_r2_key);
    const gone = await getProjectVersion(ID, anaV.id).catch((e: unknown) => e);
    expect(gone).toMatchObject({ status: 410, code: "version_document_missing" });
    await h.preview(anaV.id);
    expect(h.getState().message).toBe("Couldn’t open that version. This version’s document is no longer stored, so it can’t be opened or restored.");
  });

  it("a Free owner: retention 0/0 → upsell; naming → 402 named_version_limit said plainly", async () => {
    await pushMedia(ID, [recA, cursor]);
    expect((await saveCloudProject(ID, projectText(ID), 0, { history: WEB("b") })).ok).toBe(true);
    db.query(`UPDATE "user" SET tester = 0 WHERE id = ?`, OWNER); // downgraded to Free
    const list = await listProjectVersions(ID, { limit: 500 });
    expect(list.retention).toEqual({ days: 0, maxNamed: 0, namedCount: 0 });
    const store = new EditorStore();
    store.load({ text: projectText(ID), origin: "cloud", revision: 1, persistence: persistence(ID, "b") });
    const h = new HistoryController({ store, api: cloudHistoryApi(ID), isOwner: true });
    await h.refresh();
    expect(h.getState().status).toBe("gated");
    expect(await h.commitName(list.versions[0].id, "Keep")).toBe(false);
    expect(h.getState().message).toBe("Couldn’t name it. Named versions are part of Pro — upgrade to keep versions by name.");
  });

  it("an upload at the storage cap because history keeps the old recording → Free up history → the retry lands", async () => {
    // Room for two recordings (+ the current document, which counts), not three.
    const docBytes = Math.max(enc(projectText(ID2)).byteLength, enc(projectText(ID2, (j) => (j.name = "B"))).byteLength);
    db.query(`UPDATE plan SET limits = json_set(limits, '$.maxTotalStorageBytes', ?) WHERE name = 'pro'`, 2.5 * MEDIA + docBytes);
    // v1 pins recording A; v2 (a checkpoint, so a NEW version) pins B, which replaced A.
    await pushMedia(ID2, [recA]);
    expect((await saveCloudProject(ID2, projectText(ID2), 0, { history: WEB("b") })).ok).toBe(true);
    await pushMedia(ID2, [recB]);
    expect((await saveCloudProject(ID2, projectText(ID2, (j) => (j.name = "B")), 1, { history: { ...WEB("b"), checkpoint: "push" } })).ok).toBe(true);
    expect((await listProjectVersions(ID2)).freeableBytes).toBe(MEDIA);

    const loaded = await loadCloudProject(ID2);
    const blobs = new Map<string, Blob>();
    const pm = new ProjectMedia({
      projectId: ID2,
      origin: "cloud",
      cloud: loaded,
      createObjectURL: () => "blob:test",
      // The web's commit (record/publish.ts) through the web client, minus the XHR.
      commitFiles: (projectId, o) => commitMedia(projectId, o.manifest, (s) => blobs.get(s) ?? o.blobFor(s)),
    });
    const store = new EditorStore();
    store.load({ text: loaded.document!, origin: "cloud", revision: loaded.revision, persistence: persistence(ID2, "b") });
    const h = new HistoryController({ store, api: cloudHistoryApi(ID2), isOwner: true, media: pm, confirm: async () => 0 });
    pm.freeUpHandler = () => h.freeUp("upload");

    // Replace the recording: A (kept by v1) + B (the head's) + C does not fit.
    const shaC = await sha256(recC.bytes);
    const failed = await pm
      .addFile({ ref: "recording.mov", path: "recording.mov", blob: new Blob([recC.bytes as BlobPart]), sha256: shaC, contentType: recC.contentType })
      .catch((e: unknown) => e);
    expect(failed).toBeInstanceOf(HistoryStorageError);
    expect((failed as HistoryStorageError).message).toBe("History is keeping the old recording — Free up history to replace it.");
    expect(failed).toMatchObject({ status: 413, code: "storage_limit_reached", freeableBytes: MEDIA, replaces: "recording" });
    expect(pm.historyBlock).toBe(failed);

    // Free up (POST …/history/free-up via the History pane's Free up) → the upload retries and lands.
    await pm.requestFreeUp();
    expect(pm.historyBlock).toBeNull();
    const files = await loadCloudProject(ID2);
    expect(files.media["recording.mov"].sha256).toBe(shaC);
    expect(h.getState()).toMatchObject({ freeableBytes: 0 });
  });
});
