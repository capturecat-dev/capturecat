import { Hono } from "hono";
import type { Context } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { planForUser, requireEntitlement, userRateLimit } from "../lib/entitlement";
import { createPresignedDownloadUrl, createPresignedUploadUrl } from "../lib/presign";
import { planForEntitlement, type PlanRecord } from "../lib/plans";
import { checkUploadAllowance, storageDeniedBody } from "../lib/upload-policy";
import { parseJsonBody } from "../lib/validate";
import { MAX_SIGNABLE_UPLOAD_BYTES } from "../lib/upload-schemas";
import { isOrgMember, storageUsageBytes } from "../lib/db";
import { generateId } from "../lib/id";
import {
  FINALIZE_VERIFY_BUDGET_BYTES,
  GET_URL_TTL_SECONDS,
  MAX_DOCUMENT_BYTES,
  MAX_PENDING_OBJECTS,
  ManifestBodySchema,
  PUT_URL_TTL_SECONDS,
  checkManifest,
  checkProjectDocument,
  distinctObjects,
  documentKey,
  inconsistentSizes,
  normalizeProjectId,
  objectKey,
  parseIfMatchRevision,
  sha256Hex,
  sha256OfStream,
  type ManifestBody,
} from "../lib/cloud-projects";
import {
  cloudProjectAccess,
  commitCloudFiles,
  deleteCloudObjectRow,
  deleteCloudProjectRows,
  deleteObjectIfUnreferenced,
  ensureCurrentManifest,
  getCloudProject,
  insertPendingObjects,
  listCloudFiles,
  listCloudObjects,
  listOrgCloudProjects,
  listOwnedCloudProjects,
  markObjectReadyWithinQuota,
  pendingObjectsElsewhere,
  releasableObjects,
  stageCloudProject,
  type CloudFileRow,
  type CloudProjectRow,
} from "../lib/cloud-projects-db";
import {
  PRUNE_PER_SAVE,
  checkpointHonoured,
  newVersionKind,
  parseSaveHeaders,
  shouldExtend,
  versionChangeJSON,
} from "../lib/project-history";
import {
  deleteDocumentIfUnreferenced,
  deleteOrphanManifests,
  getVersion,
  pruneProjectHistory,
  putDocumentSnapshot,
  readStoredDocument,
  releaseUnpinnedMedia,
  saveVersioned,
} from "../lib/project-history-db";

/**
 * Cloud projects for the web editor (app.capturecat.so/editor).
 *
 *   GET    /cloud-projects                 list (mine; ?orgId= for a team's)
 *   PUT    /cloud-projects/:id             stage manifest → missing objects + presigned PUTs
 *   POST   /cloud-projects/:id/finalize    verify size + SHA-256 of new objects, commit manifest
 *   GET    /cloud-projects/:id             project.json + presigned GETs for every file
 *   GET    /cloud-projects/:id/files       presigned GETs only (refresh before they expire)
 *   PUT    /cloud-projects/:id/project     save project.json — `If-Match: "<revision>"`,
 *                                          409 + current revision/document on conflict
 *   DELETE /cloud-projects/:id             delete project, files and R2 objects
 *
 * AuthN: the Better Auth session — cookie from the web app, bearer from the
 * desktop app (requireAuth; cookie writes also pass its Origin/CSRF gate).
 * AuthZ: the OWNER may do everything. When the owner has put the project in
 * an organization (`orgId`, needs the plan's `teams` feature + membership —
 * the same rule as POST /video/:id/org), that org's members may READ it
 * (list, GET, files) and SAVE edits to its project.json — the revision check
 * keeps concurrent editors honest, and a growing document is charged to the
 * OWNER's quota under the OWNER's plan (the storage is theirs). Media
 * (stage/finalize), org moves and delete stay owner-only: media counts
 * against the owner's storage. A non-member gets 404 on reads (a random
 * UUID's existence is not theirs to learn) and 403 on writes to an id
 * another account owns. Team access is the OWNER's plan feature (`teams`),
 * checked at use time like share links: once the owner's plan lapses, the
 * members lose the project (the owner keeps it) — otherwise one month of a
 * paid plan would buy a permanent team library on the free tier.
 *
 * App Attest (checkAssertion) is deliberately NOT chained: these routes are
 * the web editor's too, and a browser cannot attest. The boundary is the
 * session, ownership, and the plan's storage accounting.
 *
 * Storage: objects are counted against the owner's plan quota once verified
 * (STORAGE_SUM_SQL, lib/db.ts). Allowance decisions go through the same
 * `checkUploadAllowance` as share uploads (cloudShare feature + total cap),
 * except the per-file cap: a cloud project carries the RAW recording the web
 * editor renders 1:1 from, so its per-file ceiling is the per-kind one in
 * lib/cloud-projects.ts (video: the 5 GiB single-PUT limit), not the plan's
 * share-upload cap (sized for exported mp4s). The total quota still binds.
 *
 * History (migration 0027, docs/project-history.md): every save also extends
 * or opens a VERSION (gzipped snapshot + the media manifest it was saved
 * against) in the same D1 batch as the revision CAS — see
 * lib/project-history{,-db}.ts and routes/cloud-project-history.ts. Versions
 * pin their media: an object a version names is never garbage-collected and
 * never counted as credit for a replacement, and pinned media still counts
 * against the owner's storage (owner decision 3). Version documents do not
 * count; they are bounded per project instead.
 */
export const cloudProjectRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

export type Ctx = Context<{ Bindings: Env; Variables: Variables }>;

const BUCKET = "capturecat";

function r2Creds(env: Env) {
  return {
    r2Endpoint: env.R2_ENDPOINT,
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
    bucket: BUCKET,
  };
}

const nowIso = () => new Date().toISOString();

// Per-uid write limits (D1 fixed window). One sync is ~3 calls (stage,
// finalize, save); the web's autosave is debounced, so 120 saves/min is
// headroom rather than a target.
export const syncLimit = userRateLimit({ limit: 30, windowSec: 60, scope: "cloud-sync" });
export const saveLimit = userRateLimit({ limit: 120, windowSec: 60, scope: "cloud-save" });

/** Resolve :id and the row, enforcing read access. */
export async function loadForRead(c: Ctx): Promise<
  { ok: true; project: CloudProjectRow; access: "owner" | "member" } | { ok: false; res: Response }
> {
  const id = normalizeProjectId(c.req.param("id"));
  if (!id) return { ok: false, res: c.json({ error: "Invalid project id" }, 400) };
  const project = await getCloudProject(c.env.DB, id);
  let access = project ? await cloudProjectAccess(c.env.DB, project, c.get("user").uid) : "none";
  if (project && access === "member" && !(await ownerHasTeams(c.env, project.ownerUid))) access = "none";
  if (!project || access === "none") return { ok: false, res: c.json({ error: "Project not found" }, 404) };
  return { ok: true, project, access };
}

/** Whether the owner's CURRENT plan still includes team access. */
async function ownerHasTeams(env: Env, ownerUid: string): Promise<boolean> {
  return (await planForUser(env, ownerUid)).features.teams;
}

/** Bytes of this project's ready objects that the COMMITTED file set
 *  references, `wantedShas` drops, and no version pins — the only bytes a
 *  replacement may be accepted on credit for, because only they are
 *  garbage-collected by the commit (releasableObjects). Uncommitted
 *  leftovers (a finalize that stopped short) are never credit: they still
 *  count, so they cannot be traded twice. Pinned media is never credit
 *  either: history keeps it, and it keeps counting (owner decision 3). */
async function creditBytes(env: Env, projectId: string, wantedShas: Set<string>): Promise<number> {
  return (await releasableObjects(env.DB, projectId, wantedShas)).reduce((sum, o) => sum + o.bytes, 0);
}

/** The OWNER's plan — what governs the owner's storage, history retention
 *  and named-version cap, whoever (owner or member) is acting. Needs
 *  requireEntitlement upstream for the owner's own request. */
export async function ownerPlan(c: Ctx, project: CloudProjectRow, access: "owner" | "member"): Promise<PlanRecord> {
  return access === "owner" && c.get("entitlement")
    ? planForEntitlement(c.env.DB, c.get("entitlement"))
    : planForUser(c.env, project.ownerUid);
}

/** The plan as it applies to cloud-project MEDIA: the per-file cap lifts to
 *  the single-PUT ceiling (per-kind caps are enforced on the manifest). A
 *  plan with no storage keeps its zero cap so the refusal still says so. */
function cloudMediaPlan<P extends { limits: { maxFileSizeBytes: number } }>(plan: P): P {
  if (plan.limits.maxFileSizeBytes <= 0) return plan;
  return {
    ...plan,
    limits: { ...plan.limits, maxFileSizeBytes: Math.max(plan.limits.maxFileSizeBytes, MAX_SIGNABLE_UPLOAD_BYTES) },
  };
}

/** Resolve :id and the row for a project.json save: the owner, or a member
 *  of the org the owner put it in. */
export async function loadForSave(c: Ctx): Promise<
  { ok: true; project: CloudProjectRow; access: "owner" | "member" } | { ok: false; res: Response }
> {
  return loadForRead(c);
}

/** Resolve :id and the row, enforcing ownership. */
export async function loadForWrite(c: Ctx): Promise<{ ok: true; project: CloudProjectRow } | { ok: false; res: Response }> {
  const read = await loadForRead(c);
  if (!read.ok) return read;
  if (read.access !== "owner") {
    return {
      ok: false,
      res: c.json({ error: "Only the project's owner can change it", code: "not_owner" }, 403),
    };
  }
  return { ok: true, project: read.project };
}

export async function presignFiles(
  env: Env,
  files: Array<Pick<CloudFileRow, "path" | "sha256" | "bytes" | "contentType" | "source" | "r2Key">>,
) {
  const creds = r2Creds(env);
  return Promise.all(
    files.map(async (f) => ({
      path: f.path,
      sha256: f.sha256,
      bytes: f.bytes,
      contentType: f.contentType,
      source: f.source,
      url: await createPresignedDownloadUrl({
        ...creds,
        key: f.r2Key,
        expiresIn: GET_URL_TTL_SECONDS,
        responseContentType: f.contentType,
      }),
    })),
  );
}

function projectSummary(p: CloudProjectRow, uid: string) {
  return {
    projectId: p.id,
    name: p.name,
    revision: p.revision,
    hasDocument: p.revision > 0,
    documentSha256: p.docSha256,
    totalBytes: p.totalBytes,
    orgId: p.orgId,
    isOwner: p.ownerUid === uid,
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
  };
}

/** The current document text, tolerating the few-millisecond window where a
 *  concurrent save swapped the row and deleted the object we were about to
 *  read (one re-read of the row). Snapshots written since 0027 are gzipped
 *  (`customMetadata.enc`); older objects are read raw. */
export async function readDocument(env: Env, project: CloudProjectRow): Promise<{ project: CloudProjectRow; text: string | null }> {
  let current = project;
  for (let attempt = 0; attempt < 2; attempt++) {
    if (!current.docR2Key || current.revision === 0) return { project: current, text: null };
    const text = await readStoredDocument(env.R2, current.docR2Key);
    if (text !== null) return { project: current, text };
    const fresh = await getCloudProject(env.DB, current.id);
    if (!fresh) return { project: current, text: null };
    current = fresh;
  }
  throw new Error(`cloud project ${project.id}: document object missing for revision ${current.revision}`);
}

// ---------------------------------------------------------------------------
// GET /cloud-projects — list
// ---------------------------------------------------------------------------

cloudProjectRoutes.get("/cloud-projects", requireAuth, requireEntitlement(), async (c) => {
  const uid = c.get("user").uid;
  const orgId = c.req.query("orgId");
  if (orgId) {
    if (!(await isOrgMember(c.env.DB, orgId, uid))) {
      return c.json({ error: "Not a member of this team" }, 403);
    }
    const projects = await listOrgCloudProjects(c.env.DB, orgId);
    // Same use-time rule as loadForRead: a project whose owner's plan lost
    // team access is not listed to the team (the owner still sees their own).
    const visible = new Map<string, boolean>();
    for (const owner of new Set(projects.map((p) => p.ownerUid))) {
      visible.set(owner, owner === uid || (await ownerHasTeams(c.env, owner)));
    }
    return c.json({
      projects: projects.filter((p) => visible.get(p.ownerUid)).map((p) => projectSummary(p, uid)),
    });
  }
  const [projects, usedBytes, plan] = await Promise.all([
    listOwnedCloudProjects(c.env.DB, uid),
    storageUsageBytes(c.env.DB, uid),
    planForEntitlement(c.env.DB, c.get("entitlement")),
  ]);
  return c.json({
    projects: projects.map((p) => projectSummary(p, uid)),
    storage: { usedBytes, limitBytes: plan.limits.maxTotalStorageBytes },
  });
});

// ---------------------------------------------------------------------------
// PUT /cloud-projects/:id — stage a manifest, presign what is missing
// ---------------------------------------------------------------------------

cloudProjectRoutes.put("/cloud-projects/:id", requireAuth, requireEntitlement(), syncLimit, async (c) => {
  const uid = c.get("user").uid;
  const id = normalizeProjectId(c.req.param("id"));
  if (!id) return c.json({ error: "Invalid project id" }, 400);

  const parsed = await parseJsonBody(c.req, ManifestBodySchema);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const body: ManifestBody = parsed.data;
  const problem = checkManifest(body);
  if (problem) return c.json(problem.body, problem.status);
  const liar = inconsistentSizes(body.files);
  if (liar) return c.json({ error: `${liar}: same SHA-256 declared with two sizes`, code: "inconsistent_manifest" }, 400);

  const existing = await getCloudProject(c.env.DB, id);
  if (existing && existing.ownerUid !== uid) {
    return c.json({ error: "This project belongs to another account", code: "not_owner" }, 403);
  }

  const plan = await planForEntitlement(c.env.DB, c.get("entitlement"));

  // Org scoping: the same gate as sharing a video into a team library.
  if (body.orgId) {
    if (!plan.features.teams) return c.json({ error: "Team projects require a paid plan", code: "teams_required" }, 402);
    if (!(await isOrgMember(c.env.DB, body.orgId, uid))) {
      return c.json({ error: "Not a member of this team" }, 403);
    }
  }

  // The plan must carry cloud storage at all — even a manifest whose bytes
  // are all present already (nothing to upload) is a cloud write.
  const gate = checkUploadAllowance(plan, { fileSizeBytes: 0, usedBytes: 0 });
  if (!gate.ok) return c.json(gate.body, gate.status);

  const objects = existing ? await listCloudObjects(c.env.DB, id) : [];
  const readyShas = new Set(objects.filter((o) => o.status === "ready").map((o) => o.sha256));
  const wanted = distinctObjects(body.files);
  const wantedShas = new Set(wanted.map((o) => o.sha256));
  const missing = wanted.filter((o) => !readyShas.has(o.sha256));

  // Liability bound on outstanding presigns (their bytes are not yet counted):
  // other projects' pending objects AND this project's pending objects that
  // the new manifest does not re-stage. Counting only other projects let one
  // project be restaged with fresh hashes indefinitely, each restage minting
  // new presigned PUTs while the earlier ones were never counted.
  const elsewhere = await pendingObjectsElsewhere(c.env.DB, uid, id);
  const missingShas = new Set(missing.map((o) => o.sha256));
  for (const o of objects) {
    if (o.status === "pending" && !missingShas.has(o.sha256)) {
      elsewhere.count += 1;
      elsewhere.bytes += o.bytes;
    }
  }
  if (elsewhere.count + missing.length > MAX_PENDING_OBJECTS) {
    return c.json(
      { error: "Too many uploads in progress — finish or wait a moment before starting another.", code: "too_many_pending" },
      429,
    );
  }

  // Quota at presign time (advisory — /finalize decides atomically on the
  // verified bytes). Outstanding presigns count as used; this project's
  // committed objects that the new manifest drops — and no version pins —
  // count as freed.
  const used = await storageUsageBytes(c.env.DB, uid);
  const credit = existing ? await creditBytes(c.env, id, wantedShas) : 0;
  let running = used + elsewhere.bytes - credit;
  const mediaPlan = cloudMediaPlan(plan);
  for (const obj of missing) {
    const verdict = checkUploadAllowance(mediaPlan, { fileSizeBytes: obj.bytes, usedBytes: Math.max(0, running) });
    if (!verdict.ok) return c.json({ ...verdict.body, path: obj.paths[0] }, verdict.status);
    running += obj.bytes;
  }

  const now = nowIso();
  const staged = await stageCloudProject(c.env.DB, {
    id,
    ownerUid: uid,
    name: body.name,
    orgId: body.orgId,
    stagedManifest: JSON.stringify({ files: body.files }),
    now,
  });
  if (!staged) {
    return c.json({ error: "This project belongs to another account", code: "not_owner" }, 403);
  }

  const creds = r2Creds(c.env);
  const rows = missing.map((o) => ({
    projectId: id,
    sha256: o.sha256,
    ownerUid: uid,
    bytes: o.bytes,
    contentType: o.contentType,
    r2Key: objectKey(uid, id, o.sha256),
  }));
  await insertPendingObjects(c.env.DB, rows, now);

  // One presigned PUT per missing object: exact key, exact Content-Type,
  // exact Content-Length, 15 minutes. It is a permit for one upload of the
  // declared bytes to this project's content-addressed slot — nothing else.
  const uploads = await Promise.all(
    rows.map(async (r, i) => ({
      sha256: r.sha256,
      bytes: r.bytes,
      contentType: r.contentType,
      paths: missing[i].paths,
      method: "PUT" as const,
      uploadUrl: await createPresignedUploadUrl({
        ...creds,
        key: r.r2Key,
        contentType: r.contentType,
        contentLength: r.bytes,
        expiresIn: PUT_URL_TTL_SECONDS,
      }),
      headers: { "Content-Type": r.contentType },
    })),
  );

  const project = await getCloudProject(c.env.DB, id);
  return c.json({
    projectId: id,
    revision: project?.revision ?? 0,
    documentSha256: project?.docSha256 ?? null,
    missing: uploads,
    presentCount: wanted.length - missing.length,
    expiresIn: PUT_URL_TTL_SECONDS,
  });
});

// ---------------------------------------------------------------------------
// POST /cloud-projects/:id/finalize — verify + commit
// ---------------------------------------------------------------------------

cloudProjectRoutes.post("/cloud-projects/:id/finalize", requireAuth, requireEntitlement(), syncLimit, async (c) => {
  const loaded = await loadForWrite(c);
  if (!loaded.ok) return loaded.res;
  const project = loaded.project;
  const uid = project.ownerUid;

  const committedSummary = async () => {
    const fresh = (await getCloudProject(c.env.DB, project.id)) ?? project;
    const files = await listCloudFiles(c.env.DB, project.id);
    return {
      projectId: project.id,
      committed: true,
      revision: fresh.revision,
      fileCount: files.length,
      totalBytes: fresh.totalBytes,
    };
  };

  // Idempotent: nothing staged means the last finalize already committed.
  if (!project.stagedManifest || !project.stagedAt) return c.json(await committedSummary());

  const staged = JSON.parse(project.stagedManifest) as { files: ManifestBody["files"] };
  const wanted = distinctObjects(staged.files);
  const wantedShas = new Set(wanted.map((o) => o.sha256));
  const objects = await listCloudObjects(c.env.DB, project.id);
  const bySha = new Map(objects.map((o) => [o.sha256, o]));

  const plan: PlanRecord = await planForEntitlement(c.env.DB, c.get("entitlement"));
  // Re-evaluated atomically at commit (commitCloudFiles' claim), where a pin
  // that appeared since — a save in between — is accounted for.
  const credit = await creditBytes(c.env, project.id, wantedShas);

  const notUploaded: Array<{ sha256: string; paths: string[] }> = [];
  let verifiedBytes = 0;
  for (const want of wanted) {
    const row = bySha.get(want.sha256);
    if (row?.status === "ready") continue;
    if (!row) {
      // Garbage-collected since staging (a concurrent restage) — re-stage.
      notUploaded.push({ sha256: want.sha256, paths: want.paths });
      continue;
    }
    if (verifiedBytes >= FINALIZE_VERIFY_BUDGET_BYTES) {
      // Bounded work per request: the client calls again.
      return c.json({ projectId: project.id, committed: false, status: "verifying" }, 202);
    }

    // Size first (cheap HEAD), then stream the bytes through SHA-256. The
    // client's declared size AND hash are claims until this passes.
    const head = await c.env.R2.head(row.r2Key);
    if (!head) {
      notUploaded.push({ sha256: want.sha256, paths: want.paths });
      continue;
    }
    const reject = async (code: string, error: string) => {
      await c.env.R2.delete(row.r2Key);
      await deleteCloudObjectRow(c.env.DB, project.id, row.sha256);
      return c.json({ error, code, path: want.paths[0], sha256: row.sha256 }, 422);
    };
    if (head.size !== row.bytes) {
      return reject("size_mismatch", `${want.paths[0]}: uploaded ${head.size} bytes, declared ${row.bytes}`);
    }
    const body = await c.env.R2.get(row.r2Key);
    if (!body) {
      notUploaded.push({ sha256: want.sha256, paths: want.paths });
      continue;
    }
    const actual = await sha256OfStream(body.body);
    verifiedBytes += row.bytes;
    if (actual !== row.sha256) {
      return reject("hash_mismatch", `${want.paths[0]}: uploaded bytes do not match the declared SHA-256`);
    }

    // Re-check the plan with the VERIFIED size, then accept atomically.
    const used = await storageUsageBytes(c.env.DB, uid);
    const verdict = checkUploadAllowance(cloudMediaPlan(plan), {
      fileSizeBytes: row.bytes,
      usedBytes: Math.max(0, used - credit),
    });
    const accepted = verdict.ok
      ? await markObjectReadyWithinQuota(c.env.DB, {
          uid,
          projectId: project.id,
          sha256: row.sha256,
          etag: head.etag ?? null,
          limitBytes: plan.limits.maxTotalStorageBytes,
          creditBytes: credit,
          now: nowIso(),
        })
      : "over_quota";
    if (accepted === "missing") {
      notUploaded.push({ sha256: want.sha256, paths: want.paths });
      continue;
    }
    if (!verdict.ok || accepted !== "ready") {
      // Denied after the bytes landed: delete them so they never count.
      await c.env.R2.delete(row.r2Key);
      await deleteCloudObjectRow(c.env.DB, project.id, row.sha256);
      return c.json(
        { ...(verdict.ok ? storageDeniedBody(plan, used) : verdict.body), path: want.paths[0] },
        verdict.ok ? 413 : verdict.status,
      );
    }
  }

  if (notUploaded.length > 0) {
    return c.json(
      {
        error: "Some files have not been uploaded yet",
        code: "objects_missing",
        missing: notUploaded,
      },
      409,
    );
  }

  const committed = await commitCloudFiles(c.env.DB, {
    projectId: project.id,
    ownerUid: uid,
    stagedAt: project.stagedAt,
    limitBytes: plan.limits.maxTotalStorageBytes,
    files: staged.files.map((f) => ({
      path: f.path,
      sha256: f.sha256,
      bytes: f.bytes,
      contentType: f.contentType,
      r2Key: objectKey(uid, project.id, f.sha256),
      source: f.source ?? null,
    })),
    now: nowIso(),
  });
  if (committed === "over_quota") {
    // Every object verified, but committing this set would leave the owner
    // over the cap (e.g. a restage naming an object AND its replacement).
    // Nothing was committed; the previous file set is still the live one.
    return c.json(storageDeniedBody(plan, await storageUsageBytes(c.env.DB, uid)), 413);
  }
  if (committed !== "committed") {
    return c.json(
      { error: "The manifest was restaged while finalizing — finalize again", code: "manifest_changed" },
      409,
    );
  }

  // Garbage-collect objects the committed set no longer references (and
  // pending ones the new manifest dropped) — except what a version pins
  // (deleteObjectIfUnreferenced re-checks that atomically): history keeps
  // the media its documents were saved against. Re-read the staged manifest:
  // a restage that landed after the commit may point at an old object again.
  await deleteOrphanManifests(c.env.DB, project.id);
  const after = await getCloudProject(c.env.DB, project.id);
  const restaged = new Set<string>(
    after?.stagedManifest
      ? (JSON.parse(after.stagedManifest) as { files: Array<{ sha256: string }> }).files.map((f) => f.sha256)
      : [],
  );
  for (const obj of await listCloudObjects(c.env.DB, project.id)) {
    if (wantedShas.has(obj.sha256) || restaged.has(obj.sha256)) continue;
    if (await deleteObjectIfUnreferenced(c.env.DB, project.id, obj.sha256)) {
      await c.env.R2.delete(obj.r2Key);
    }
  }

  return c.json(await committedSummary());
});

// ---------------------------------------------------------------------------
// GET /cloud-projects/:id — document + media URLs
// ---------------------------------------------------------------------------

cloudProjectRoutes.get("/cloud-projects/:id", requireAuth, async (c) => {
  const loaded = await loadForRead(c);
  if (!loaded.ok) return loaded.res;
  const { project: current, text } = await readDocument(c.env, loaded.project);
  const files = await listCloudFiles(c.env.DB, current.id);
  const uid = c.get("user").uid;
  c.header("Cache-Control", "no-store");
  c.header("ETag", `"${current.revision}"`);
  return c.json({
    ...projectSummary(current, uid),
    access: loaded.access,
    // The raw project.json text, exactly as last saved — a JSON string, not
    // an object, so no parse/serialize step on the server can reorder keys,
    // reformat numbers or drop anything. Null until the first save.
    document: text,
    files: await presignFiles(c.env, files),
    urlsExpireAt: new Date(Date.now() + GET_URL_TTL_SECONDS * 1000).toISOString(),
  });
});

cloudProjectRoutes.get("/cloud-projects/:id/files", requireAuth, async (c) => {
  const loaded = await loadForRead(c);
  if (!loaded.ok) return loaded.res;
  const files = await listCloudFiles(c.env.DB, loaded.project.id);
  c.header("Cache-Control", "no-store");
  return c.json({
    projectId: loaded.project.id,
    revision: loaded.project.revision,
    files: await presignFiles(c.env, files),
    urlsExpireAt: new Date(Date.now() + GET_URL_TTL_SECONDS * 1000).toISOString(),
  });
});

// ---------------------------------------------------------------------------
// PUT /cloud-projects/:id/project — save project.json (optimistic concurrency)
// ---------------------------------------------------------------------------

cloudProjectRoutes.put("/cloud-projects/:id/project", requireAuth, requireEntitlement(), saveLimit, async (c) => {
  const loaded = await loadForSave(c);
  if (!loaded.ok) return loaded.res;
  const project = loaded.project;
  // Storage is the OWNER's even when a team member saves.
  const uid = project.ownerUid;

  const baseRevision = parseIfMatchRevision(c.req.header("If-Match"));
  if (baseRevision === null) {
    return c.json(
      { error: 'Send If-Match: "<revision>" — the revision this document was based on', code: "revision_required" },
      428,
    );
  }

  const declared = parseInt(c.req.header("Content-Length") ?? "", 10);
  if (Number.isFinite(declared) && declared > MAX_DOCUMENT_BYTES) {
    return c.json({ error: "project.json is too large", code: "document_too_large" }, 413);
  }
  const bytes = new Uint8Array(await c.req.arrayBuffer());
  let text: string;
  try {
    // Fatal: the Mac's JSONDecoder refuses invalid UTF-8, so storing it
    // would brick the project there. The BYTES are what gets stored.
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
  } catch {
    return c.json({ error: "project.json must be UTF-8", code: "invalid_document" }, 400);
  }
  const check = checkProjectDocument(text, bytes.byteLength, project.id);
  if (!check.ok) return c.json(check.body, check.status);

  if (baseRevision !== project.revision) return revisionConflict(c, project);

  // A document that GROWS is new storage: plan gate + quota (decided again
  // atomically in the swap). One that shrinks or holds size is always
  // accepted, so an over-quota or downgraded account can still save edits.
  // The owner's plan governs the owner's storage — a member's own plan is
  // irrelevant to how much the owner may store.
  const plan = await ownerPlan(c, project, loaded.access);
  const growth = bytes.byteLength - project.docBytes;
  if (growth > 0) {
    const used = await storageUsageBytes(c.env.DB, uid);
    const verdict = checkUploadAllowance(plan, { fileSizeBytes: growth, usedBytes: used });
    if (!verdict.ok) return c.json(verdict.body, verdict.status);
  }

  // History: extend the head version or open a new one (coalescing rules in
  // lib/project-history.ts). The X-CC-* headers are optional — an old client
  // sends none and its saves still version (per actor, no client id).
  const actorUid = c.get("user").uid;
  const headers = parseSaveHeaders((name) => c.req.header(name));
  const nowMs = Date.now();
  const now = new Date(nowMs).toISOString();
  // A project whose media was committed before 0027 has no manifest yet:
  // record it so this save's version (and a backfilled one) pins that media.
  const manifestSha = await ensureCurrentManifest(c.env.DB, project, now);
  const head = project.headVersionId ? await getVersion(c.env.DB, project.id, project.headVersionId) : null;
  const forceNew = checkpointHonoured(headers, project.lastCheckpointAt, nowMs);
  const extend =
    head !== null &&
    head.revision === project.revision &&
    shouldExtend(head, { actorUid, clientId: headers.clientId, source: headers.source }, nowMs, forceNew);

  const newRevision = project.revision + 1;
  const key = documentKey(uid, project.id, newRevision, generateId(12));
  const sha = await sha256Hex(bytes);
  // Write the new revision's object FIRST (gzipped — it is also the
  // version's snapshot), then swap the row. A lost race or refusal leaves
  // only an orphan object (deleted below), never a row pointing at a torn
  // document — and, the version statements being guarded on the swap, never
  // a version row either.
  const storedBytes = await putDocumentSnapshot(c.env.R2, key, bytes);
  const result = await saveVersioned(c.env.DB, {
    swap: {
      uid,
      actorUid,
      projectId: project.id,
      expectedRevision: project.revision,
      newRevision,
      r2Key: key,
      bytes: bytes.byteLength,
      sha256: sha,
      name: check.name,
      growthBytes: growth,
      limitBytes: plan.limits.maxTotalStorageBytes,
      now,
    },
    storedBytes,
    version: {
      newId: generateId(16),
      extendId: extend ? head.id : null,
      kind: newVersionKind(project.revision, headers),
      clientKind: headers.clientKind,
      clientId: headers.clientId,
      source: headers.source,
      extendedChangeJSON: extend ? versionChangeJSON(head.changeJSON, headers.change, true) : null,
      ownChangeJSON: versionChangeJSON(null, headers.change, false),
      restoredFrom: null,
      mergedFromRevision: headers.mergedFrom,
      checkpointHonoured: forceNew,
    },
    backfill: legacyBackfill(project),
  });
  if (!result.swapped) {
    // Our key is unique to this attempt, so nothing else can point at it.
    await c.env.R2.delete(key);
    const fresh = await getCloudProject(c.env.DB, project.id);
    if (fresh && fresh.revision !== project.revision) return revisionConflict(c, fresh);
    const used = await storageUsageBytes(c.env.DB, uid);
    return c.json(storageDeniedBody(plan, used), 413);
  }

  // The previous document stays as its version's snapshot — unless this save
  // extended that version, which then names the new object instead.
  if (project.docR2Key && project.docR2Key !== key) {
    await deleteDocumentIfUnreferenced(c.env, project.id, project.docR2Key);
  }
  await historyHousekeeping(c.env, project.id, plan, nowMs, {
    opened: result.version !== null && !result.version.extended,
    manifestMoved: extend && head.manifestSha !== manifestSha,
  });

  const saved = await getCloudProject(c.env.DB, project.id);
  c.header("ETag", `"${newRevision}"`);
  return c.json({
    projectId: project.id,
    revision: newRevision,
    documentSha256: sha,
    updatedAt: saved?.updatedAt ?? now,
    version: result.version,
  });
});

/** 409 with the current revision and document (the client rebases or merges). */
export async function revisionConflict(c: Ctx, current: CloudProjectRow) {
  const { project: fresh, text: currentText } = await readDocument(c.env, current);
  c.header("ETag", `"${fresh.revision}"`);
  return c.json(
    {
      error: "This project changed since your copy was loaded",
      code: "revision_conflict",
      revision: fresh.revision,
      documentSha256: fresh.docSha256,
      updatedAt: fresh.updatedAt,
      headVersionId: fresh.headVersionId,
      document: currentText,
    },
    409,
  );
}

/** A project saved before 0027 has no version for its current document; the
 *  next save records it (its `upload` version) in the same batch. */
export function legacyBackfill(project: CloudProjectRow) {
  if (project.headVersionId || project.revision === 0 || !project.docR2Key || !project.docSha256) return null;
  return {
    id: generateId(16),
    revision: project.revision,
    r2Key: project.docR2Key,
    bytes: project.docBytes,
    sha256: project.docSha256,
    at: project.updatedAt,
    actorUid: project.updatedBy,
  };
}

/**
 * After a save that landed: a NEW version may push the project past its
 * retention (the owner's plan; at most PRUNE_PER_SAVE here, the hourly sweep
 * does the rest); an EXTENDED version that moved to a new manifest may have
 * orphaned the old one and the media only it pinned. Never fails the save.
 */
export async function historyHousekeeping(
  env: Env,
  projectId: string,
  plan: PlanRecord,
  nowMs: number,
  what: { opened: boolean; manifestMoved: boolean },
): Promise<void> {
  try {
    if (what.opened) await pruneProjectHistory(env, projectId, plan.limits, nowMs, PRUNE_PER_SAVE);
    if (what.manifestMoved) {
      await deleteOrphanManifests(env.DB, projectId);
      await releaseUnpinnedMedia(env, projectId);
    }
  } catch (err) {
    console.error(`cloud project ${projectId}: history housekeeping failed`, err);
  }
}

// ---------------------------------------------------------------------------
// DELETE /cloud-projects/:id
// ---------------------------------------------------------------------------

cloudProjectRoutes.delete("/cloud-projects/:id", requireAuth, syncLimit, async (c) => {
  const loaded = await loadForWrite(c);
  if (!loaded.ok) return loaded.res;
  const project = loaded.project;
  const objects = await listCloudObjects(c.env.DB, project.id);
  const keys = objects.map((o) => o.r2Key);
  // Every version's snapshot too (the head's is the current document).
  const snapshots = await c.env.DB
    .prepare(`SELECT doc_r2_key FROM cloud_project_versions WHERE project_id = ?`)
    .bind(project.id)
    .all<{ doc_r2_key: string }>();
  for (const key of new Set([project.docR2Key, ...(snapshots.results ?? []).map((r) => r.doc_r2_key)])) {
    if (key) keys.push(key);
  }
  // R2's batch delete takes up to 1000 keys per call.
  for (let i = 0; i < keys.length; i += 1000) {
    await c.env.R2.delete(keys.slice(i, i + 1000));
  }
  await deleteCloudProjectRows(c.env.DB, project.id);
  return c.json({ projectId: project.id, deleted: true });
});
