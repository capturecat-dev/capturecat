/**
 * D1 data layer for cloud projects (migration 0026). Prepared statements
 * only; the rules live in lib/cloud-projects.ts and the flow in
 * routes/cloud-projects.ts.
 */

import { STORAGE_SUM_SQL, isOrgMember } from "./db";
import { sha256Hex } from "./cloud-projects";
import { manifestText, type ManifestEntry } from "./project-history";

export interface CloudProjectRow {
  id: string;
  ownerUid: string;
  orgId: string | null;
  name: string;
  revision: number;
  docR2Key: string | null;
  docBytes: number;
  docSha256: string | null;
  totalBytes: number;
  stagedManifest: string | null;
  stagedAt: string | null;
  createdAt: string;
  updatedAt: string;
  updatedBy: string | null;
  /** History (migration 0027): the version the current revision belongs to;
   *  null until the project's first save or history read after 0027. */
  headVersionId: string | null;
  nextVersionSeq: number;
  /** The committed file set's manifest (content-addressed); null = none recorded yet. */
  manifestSha: string | null;
  lastCheckpointAt: string | null;
}

interface ProjectDbRow {
  id: string;
  owner_uid: string;
  org_id: string | null;
  name: string;
  revision: number;
  doc_r2_key: string | null;
  doc_bytes: number;
  doc_sha256: string | null;
  total_bytes: number;
  staged_manifest: string | null;
  staged_at: string | null;
  created_at: string;
  updated_at: string;
  updated_by: string | null;
  head_version_id?: string | null;
  next_version_seq?: number | null;
  manifest_sha?: string | null;
  last_checkpoint_at?: string | null;
}

function toProject(r: ProjectDbRow): CloudProjectRow {
  return {
    id: r.id,
    ownerUid: r.owner_uid,
    orgId: r.org_id,
    name: r.name,
    revision: r.revision,
    docR2Key: r.doc_r2_key,
    docBytes: r.doc_bytes,
    docSha256: r.doc_sha256,
    totalBytes: r.total_bytes,
    stagedManifest: r.staged_manifest,
    stagedAt: r.staged_at,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    updatedBy: r.updated_by,
    headVersionId: r.head_version_id ?? null,
    nextVersionSeq: r.next_version_seq ?? 1,
    manifestSha: r.manifest_sha ?? null,
    lastCheckpointAt: r.last_checkpoint_at ?? null,
  };
}

export interface CloudObjectRow {
  sha256: string;
  bytes: number;
  contentType: string;
  r2Key: string;
  status: "pending" | "ready";
}

export interface CloudFileRow {
  path: string;
  sha256: string;
  bytes: number;
  contentType: string;
  r2Key: string;
  source: string | null;
  uploadedAt: string;
}

// ---------------------------------------------------------------------------
// Media pinned by history (migration 0027)
// ---------------------------------------------------------------------------

/**
 * SQL: is object `shaExpr` of project `projectExpr` pinned by some VERSION's
 * manifest? Versions pin everything they were saved against (owner decision
 * 3), so a pinned object is never garbage-collected and never counted as
 * credit, even when the committed file set no longer references it. Derived
 * on every use — there is no stored reference count to drift.
 */
export function pinnedSql(projectExpr: string, shaExpr: string): string {
  return `EXISTS (SELECT 1 FROM cloud_project_manifest_objects mo
                    JOIN cloud_project_versions pv
                      ON pv.project_id = mo.project_id AND pv.manifest_sha = mo.manifest_sha
                   WHERE mo.project_id = ${projectExpr} AND mo.sha256 = ${shaExpr})`;
}

/** The canonical manifest of a file set and its content address. */
export async function manifestOf(files: readonly ManifestEntry[]): Promise<{ sha: string; text: string; shas: string[] }> {
  const text = manifestText(files);
  return { sha: await sha256Hex(text), text, shas: [...new Set(files.map((f) => f.sha256))].sort() };
}

/**
 * Ready objects this project's COMMITTED file set references, `wantedShas`
 * drops, and no version pins — the only bytes a replacement may be accepted
 * on credit for (stage's advisory check and finalize's atomic accept),
 * because only they are garbage-collected by the commit.
 */
export async function releasableObjects(
  db: D1Database,
  projectId: string,
  wantedShas: Iterable<string>,
): Promise<Array<{ sha256: string; bytes: number }>> {
  const { results } = await db
    .prepare(
      `SELECT o.sha256, o.bytes FROM cloud_project_objects o
        WHERE o.project_id = ?1 AND o.status = 'ready'
          AND EXISTS (SELECT 1 FROM cloud_project_files f WHERE f.project_id = ?1 AND f.sha256 = o.sha256)
          AND o.sha256 NOT IN (SELECT value FROM json_each(?2))
          AND NOT ${pinnedSql("?1", "o.sha256")}`,
    )
    .bind(projectId, JSON.stringify([...wantedShas]))
    .all<{ sha256: string; bytes: number }>();
  return results ?? [];
}

/**
 * Record the committed file set's manifest when a project predates 0027
 * (lazy backfill): the first save or history read after the migration must
 * pin the media its first version was saved against. One batch, conditional
 * on `manifest_sha IS NULL`, so a concurrent /finalize commit (which sets its
 * own manifest) always wins. Returns the project's manifest sha afterwards.
 */
export async function ensureCurrentManifest(db: D1Database, project: CloudProjectRow, now: string): Promise<string | null> {
  if (project.manifestSha) return project.manifestSha;
  const files = await listCloudFiles(db, project.id);
  if (files.length === 0) return null;
  const m = await manifestOf(files);
  const guard = `EXISTS (SELECT 1 FROM cloud_projects WHERE id = ?1 AND manifest_sha IS NULL)`;
  await db.batch([
    db
      .prepare(
        `INSERT OR IGNORE INTO cloud_project_manifests (project_id, manifest_sha, files_json, created_at)
         SELECT ?1, ?2, ?3, ?4 WHERE ${guard}`,
      )
      .bind(project.id, m.sha, m.text, now),
    db
      .prepare(
        `INSERT OR IGNORE INTO cloud_project_manifest_objects (project_id, manifest_sha, sha256)
         SELECT ?1, ?2, value FROM json_each(?3) WHERE ${guard}`,
      )
      .bind(project.id, m.sha, JSON.stringify(m.shas)),
    db
      .prepare(`UPDATE cloud_projects SET manifest_sha = ?2 WHERE id = ?1 AND manifest_sha IS NULL`)
      .bind(project.id, m.sha),
  ]);
  const row = await db
    .prepare(`SELECT manifest_sha FROM cloud_projects WHERE id = ?`)
    .bind(project.id)
    .first<{ manifest_sha: string | null }>();
  return row?.manifest_sha ?? null;
}

export async function getCloudProject(db: D1Database, id: string): Promise<CloudProjectRow | null> {
  const row = await db.prepare(`SELECT * FROM cloud_projects WHERE id = ?`).bind(id).first<ProjectDbRow>();
  return row ? toProject(row) : null;
}

/** Owner = full access; a member of the project's org = read + save the
 *  document (routes/cloud-projects.ts has the rules); else none. */
export async function cloudProjectAccess(
  db: D1Database,
  project: CloudProjectRow,
  uid: string,
): Promise<"owner" | "member" | "none"> {
  if (project.ownerUid === uid) return "owner";
  if (project.orgId && (await isOrgMember(db, project.orgId, uid))) return "member";
  return "none";
}

export async function listOwnedCloudProjects(db: D1Database, uid: string): Promise<CloudProjectRow[]> {
  const { results } = await db
    .prepare(`SELECT * FROM cloud_projects WHERE owner_uid = ? ORDER BY updated_at DESC LIMIT 500`)
    .bind(uid)
    .all<ProjectDbRow>();
  return (results ?? []).map(toProject);
}

/** Team projects with a document (an unfinished upload is its owner's business). */
export async function listOrgCloudProjects(db: D1Database, orgId: string): Promise<CloudProjectRow[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM cloud_projects WHERE org_id = ? AND revision > 0 ORDER BY updated_at DESC LIMIT 500`,
    )
    .bind(orgId)
    .all<ProjectDbRow>();
  return (results ?? []).map(toProject);
}

/**
 * Create the project or restage its manifest. Owner-guarded INSIDE the
 * upsert (`DO UPDATE … WHERE owner_uid = excluded.owner_uid`), so two
 * accounts racing for the same id cannot both win. `orgId === undefined`
 * keeps the current org. Returns false when the id belongs to someone else.
 */
export async function stageCloudProject(
  db: D1Database,
  input: {
    id: string;
    ownerUid: string;
    name: string;
    orgId: string | null | undefined;
    stagedManifest: string;
    now: string;
  },
): Promise<boolean> {
  const keepOrg = input.orgId === undefined ? 1 : 0;
  const res = await db
    .prepare(
      `INSERT INTO cloud_projects (id, owner_uid, org_id, name, staged_manifest, staged_at, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, ?6)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name,
         org_id = CASE WHEN ?7 = 1 THEN cloud_projects.org_id ELSE excluded.org_id END,
         staged_manifest = excluded.staged_manifest,
         staged_at = excluded.staged_at,
         updated_at = excluded.updated_at
       WHERE cloud_projects.owner_uid = excluded.owner_uid`,
    )
    .bind(input.id, input.ownerUid, input.orgId ?? null, input.name, input.stagedManifest, input.now, keepOrg)
    .run();
  return (res.meta?.changes ?? 0) > 0;
}

export async function listCloudObjects(db: D1Database, projectId: string): Promise<CloudObjectRow[]> {
  const { results } = await db
    .prepare(
      `SELECT sha256, bytes, content_type, r2_key, status FROM cloud_project_objects WHERE project_id = ?`,
    )
    .bind(projectId)
    .all<{ sha256: string; bytes: number; content_type: string; r2_key: string; status: "pending" | "ready" }>();
  return (results ?? []).map((r) => ({
    sha256: r.sha256,
    bytes: r.bytes,
    contentType: r.content_type,
    r2Key: r.r2_key,
    status: r.status,
  }));
}

/** Pending objects the user holds in OTHER projects — outstanding presigns
 *  whose bytes may already sit in R2 without counting against the quota. */
export async function pendingObjectsElsewhere(
  db: D1Database,
  uid: string,
  projectId: string,
): Promise<{ count: number; bytes: number }> {
  const row = await db
    .prepare(
      `SELECT COUNT(*) AS n, COALESCE(SUM(bytes), 0) AS b FROM cloud_project_objects
        WHERE owner_uid = ? AND status = 'pending' AND project_id != ?`,
    )
    .bind(uid, projectId)
    .first<{ n: number; b: number }>();
  return { count: row?.n ?? 0, bytes: row?.b ?? 0 };
}

/** Record presigned objects as pending. A re-stage of an object that is still
 *  pending refreshes its clock so the sweep does not delete an upload that is
 *  in flight; a ready object is never touched. */
export async function insertPendingObjects(
  db: D1Database,
  rows: Array<{
    projectId: string;
    sha256: string;
    ownerUid: string;
    bytes: number;
    contentType: string;
    r2Key: string;
  }>,
  now: string,
): Promise<void> {
  if (rows.length === 0) return;
  const stmt = db.prepare(
    `INSERT INTO cloud_project_objects (project_id, sha256, owner_uid, bytes, content_type, r2_key, status, created_at)
     VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
     ON CONFLICT(project_id, sha256) DO UPDATE SET created_at = excluded.created_at
     WHERE cloud_project_objects.status = 'pending'`,
  );
  await db.batch(
    rows.map((r) => stmt.bind(r.projectId, r.sha256, r.ownerUid, r.bytes, r.contentType, r.r2Key, now)),
  );
}

/**
 * Flip a verified object to ready ONLY IF that keeps the owner within
 * `limitBytes` — the same one-statement atomic accept as
 * markVersionReadyWithinQuota, so concurrent finalizes cannot each read the
 * same "used" figure and all land. `creditBytes` are this project's ready
 * objects the staged manifest no longer references (garbage-collected right
 * after the commit), so replacing a recording does not need twice the space.
 */
export async function markObjectReadyWithinQuota(
  db: D1Database,
  input: {
    uid: string;
    projectId: string;
    sha256: string;
    etag: string | null;
    limitBytes: number;
    creditBytes: number;
    now: string;
  },
): Promise<"ready" | "over_quota" | "missing"> {
  const res = await db
    .prepare(
      `UPDATE cloud_project_objects
          SET status = 'ready', etag = ?2, uploaded_at = ?3
        WHERE project_id = ?4 AND sha256 = ?5 AND status = 'pending'
          AND (bytes + (${STORAGE_SUM_SQL}) - ?6) <= ?7`,
    )
    .bind(input.uid, input.etag, input.now, input.projectId, input.sha256, input.creditBytes, input.limitBytes)
    .run();
  if ((res.meta?.changes ?? 0) > 0) return "ready";
  const row = await db
    .prepare(`SELECT status FROM cloud_project_objects WHERE project_id = ? AND sha256 = ?`)
    .bind(input.projectId, input.sha256)
    .first<{ status: string }>();
  if (!row) return "missing";
  return row.status === "ready" ? "ready" : "over_quota";
}

export async function deleteCloudObjectRow(db: D1Database, projectId: string, sha256: string): Promise<void> {
  await db
    .prepare(`DELETE FROM cloud_project_objects WHERE project_id = ? AND sha256 = ?`)
    .bind(projectId, sha256)
    .run();
}

/**
 * Replace the committed file set with the staged manifest, atomically (one
 * D1 batch = one transaction) and ONLY if the manifest staged at `stagedAt`
 * is still the staged one AND committing it keeps the owner within
 * `limitBytes` (or does not grow what this project stores).
 *
 * WHY THE QUOTA IS DECIDED HERE TOO. /finalize accepts a replacement object
 * on CREDIT for the committed objects the manifest drops, because those are
 * garbage-collected right after the commit. That credit is only sound if the
 * commit actually happens with them dropped. Without this check a finalize
 * that stopped short of committing (409 objects_missing, 202 verifying)
 * left the replacement `ready`, and a restage naming BOTH the old and new
 * objects then committed them together — past the quota, repeatably.
 *
 * The first statement claims the commit by swapping `staged_at` for a
 * per-attempt token, conditional on the staged manifest AND the quota; every
 * later statement is guarded on that token. So the quota is evaluated ONCE,
 * on the pre-commit state, and a refused claim leaves everything untouched.
 * Returns "committed", "manifest_changed" or "over_quota".
 *
 * HISTORY (0027). Objects a version pins are NOT collected by the commit, so
 * the claim may not count them as released: the quota branch subtracts only
 * unpinned objects, and the "does not grow" branch compares what the project
 * keeps afterwards (wanted ∪ pinned) with what it keeps without the commit
 * (committed ∪ pinned). Otherwise a replacement accepted on an unpinned
 * object's credit, followed by a save that pins that object, would commit
 * both — one recording's worth past the cap per round. The commit also
 * records the file set's content-addressed manifest and points
 * `cloud_projects.manifest_sha` at it (the next save's version pins it).
 */
export async function commitCloudFiles(
  db: D1Database,
  input: {
    projectId: string;
    ownerUid: string;
    stagedAt: string;
    files: Array<Omit<CloudFileRow, "uploadedAt">>;
    limitBytes: number;
    now: string;
  },
): Promise<"committed" | "manifest_changed" | "over_quota"> {
  const token = `commit:${input.stagedAt}:${crypto.randomUUID()}`;
  const manifest = await manifestOf(input.files);
  const wanted = JSON.stringify([...new Set(input.files.map((f) => f.sha256))]);
  // ?1 owner (STORAGE_SUM_SQL's uid slot), ?2 project, ?3 staged_at,
  // ?4 claim token, ?5 wanted SHA-256s (JSON array), ?6 limit.
  const pinned = pinnedSql("?2", "o.sha256");
  const readyBytes = (shaFilter: string) =>
    `(SELECT COALESCE(SUM(o.bytes), 0) FROM cloud_project_objects o
       WHERE o.project_id = ?2 AND o.status = 'ready' AND ${shaFilter})`;
  const claim = db
    .prepare(
      `UPDATE cloud_projects SET staged_at = ?4
        WHERE id = ?2 AND staged_at = ?3
          AND (
            ${readyBytes(`(o.sha256 IN (SELECT value FROM json_each(?5)) OR ${pinned})`)}
              <= ${readyBytes(`(o.sha256 IN (SELECT sha256 FROM cloud_project_files WHERE project_id = ?2) OR ${pinned})`)}
            OR ((${STORAGE_SUM_SQL}) - ${readyBytes(`o.sha256 NOT IN (SELECT value FROM json_each(?5)) AND NOT ${pinned}`)}) <= ?6
          )`,
    )
    .bind(input.ownerUid, input.projectId, input.stagedAt, token, wanted, input.limitBytes);

  const guard = `EXISTS (SELECT 1 FROM cloud_projects WHERE id = ?1 AND staged_at = ?2)`;
  const insert = db.prepare(
    `INSERT INTO cloud_project_files (project_id, path, sha256, bytes, content_type, r2_key, source, uploaded_at)
     SELECT ?1, ?3, ?4, ?5, ?6, ?7, ?8, ?9 WHERE ${guard}`,
  );
  const statements = [
    claim,
    db
      .prepare(`DELETE FROM cloud_project_files WHERE project_id = ?1 AND ${guard}`)
      .bind(input.projectId, token),
    ...input.files.map((f) =>
      insert.bind(
        input.projectId,
        token,
        f.path,
        f.sha256,
        f.bytes,
        f.contentType,
        f.r2Key,
        f.source,
        input.now,
      ),
    ),
    // The committed set's manifest (content-addressed: a set seen before is
    // the same row) — what the next document save's version pins.
    db
      .prepare(
        `INSERT OR IGNORE INTO cloud_project_manifests (project_id, manifest_sha, files_json, created_at)
         SELECT ?1, ?3, ?4, ?5 WHERE ${guard}`,
      )
      .bind(input.projectId, token, manifest.sha, manifest.text, input.now),
    db
      .prepare(
        `INSERT OR IGNORE INTO cloud_project_manifest_objects (project_id, manifest_sha, sha256)
         SELECT ?1, ?3, value FROM json_each(?4) WHERE ${guard}`,
      )
      .bind(input.projectId, token, manifest.sha, JSON.stringify(manifest.shas)),
    // Last: its change count is the commit's verdict.
    db
      .prepare(
        `UPDATE cloud_projects
            SET staged_manifest = NULL, staged_at = NULL, updated_at = ?3, manifest_sha = ?4,
                total_bytes = doc_bytes + (
                  SELECT COALESCE(SUM(o.bytes), 0) FROM cloud_project_objects o
                   WHERE o.project_id = ?1
                     AND o.sha256 IN (SELECT sha256 FROM cloud_project_files WHERE project_id = ?1))
          WHERE id = ?1 AND staged_at = ?2`,
      )
      .bind(input.projectId, token, input.now, manifest.sha),
  ];
  const results = await db.batch(statements);
  if ((results[results.length - 1]?.meta?.changes ?? 0) > 0) return "committed";
  // Lost the claim: either a restage moved staged_at, or the quota refused.
  const row = await db
    .prepare(`SELECT staged_at FROM cloud_projects WHERE id = ?`)
    .bind(input.projectId)
    .first<{ staged_at: string | null }>();
  return row?.staged_at === input.stagedAt ? "over_quota" : "manifest_changed";
}

export async function listCloudFiles(db: D1Database, projectId: string): Promise<CloudFileRow[]> {
  const { results } = await db
    .prepare(
      `SELECT path, sha256, bytes, content_type, r2_key, source, uploaded_at
         FROM cloud_project_files WHERE project_id = ? ORDER BY path`,
    )
    .bind(projectId)
    .all<{
      path: string;
      sha256: string;
      bytes: number;
      content_type: string;
      r2_key: string;
      source: string | null;
      uploaded_at: string;
    }>();
  return (results ?? []).map((r) => ({
    path: r.path,
    sha256: r.sha256,
    bytes: r.bytes,
    contentType: r.content_type,
    r2Key: r.r2_key,
    source: r.source,
    uploadedAt: r.uploaded_at,
  }));
}

/**
 * Drop one object row if nothing references it: no COMMITTED file, no
 * VERSION's manifest (history pins its media — owner decision 3), and not
 * the staged manifest (an in-flight restage counts on its ready objects).
 * Every check is re-evaluated inside the statement, so a concurrent commit
 * or save cannot lose a file to garbage collection. Returns true when the
 * row went — the caller then deletes the R2 bytes.
 */
export async function deleteObjectIfUnreferenced(
  db: D1Database,
  projectId: string,
  sha256: string,
): Promise<boolean> {
  const res = await db
    .prepare(
      `DELETE FROM cloud_project_objects
        WHERE project_id = ?1 AND sha256 = ?2
          AND NOT EXISTS (SELECT 1 FROM cloud_project_files WHERE project_id = ?1 AND sha256 = ?2)
          AND NOT ${pinnedSql("?1", "?2")}
          AND ?2 NOT IN (
            SELECT lower(json_extract(sf.value, '$.sha256'))
              FROM cloud_projects sp, json_each(sp.staged_manifest, '$.files') sf
             WHERE sp.id = ?1 AND sp.staged_manifest IS NOT NULL)`,
    )
    .bind(projectId, sha256)
    .run();
  return (res.meta?.changes ?? 0) > 0;
}

/**
 * Compare-and-swap the document pointer. Succeeds only if the row is still
 * at `expectedRevision` AND owned by `uid` AND — when the document grows —
 * the growth fits under `limitBytes` (the same atomic sum the media path
 * uses). Returns false on any of those; the caller re-reads to tell a
 * revision conflict from a quota refusal.
 *
 * `uid` is the OWNER (whose storage the document is charged to); `actorUid`
 * is whoever saved — the owner or an org member — and is what `updated_by`
 * records.
 *
 * `expectedManifestSha` (restore only): also require the committed file set
 * to be the one the caller computed against (`manifest_sha IS ?`), so a
 * concurrent /finalize commit is never overwritten by a stale union.
 */
export interface SwapDocumentInput {
  uid: string;
  actorUid: string;
  projectId: string;
  expectedRevision: number;
  newRevision: number;
  r2Key: string;
  bytes: number;
  sha256: string;
  name: string;
  growthBytes: number;
  limitBytes: number;
  now: string;
  expectedManifestSha?: string | null;
}

/** The CAS as a statement, for callers that put it at the head of a batch
 *  (the versioned save: every history statement after it is guarded on it). */
export function swapCloudDocumentStatement(db: D1Database, input: SwapDocumentInput): D1PreparedStatement {
  const checkManifest = input.expectedManifestSha !== undefined;
  return db
    .prepare(
      `UPDATE cloud_projects
          SET revision = ?2, doc_r2_key = ?3, doc_bytes = ?4, doc_sha256 = ?5, name = ?6,
              total_bytes = total_bytes - doc_bytes + ?4, updated_at = ?7, updated_by = ?12
        WHERE id = ?8 AND owner_uid = ?1 AND revision = ?9
          AND (?10 <= 0 OR (?10 + (${STORAGE_SUM_SQL})) <= ?11)
          AND (?13 = 0 OR manifest_sha IS ?14)`,
    )
    .bind(
      input.uid,
      input.newRevision,
      input.r2Key,
      input.bytes,
      input.sha256,
      input.name,
      input.now,
      input.projectId,
      input.expectedRevision,
      input.growthBytes,
      input.limitBytes,
      input.actorUid,
      checkManifest ? 1 : 0,
      checkManifest ? (input.expectedManifestSha ?? null) : null,
    );
}

export async function swapCloudDocument(db: D1Database, input: SwapDocumentInput): Promise<boolean> {
  const res = await swapCloudDocumentStatement(db, input).run();
  return (res.meta?.changes ?? 0) > 0;
}

/** Remove every row of a project, history included (FKs cascade too). */
export async function deleteCloudProjectRows(db: D1Database, projectId: string): Promise<void> {
  await db.batch([
    db.prepare(`DELETE FROM cloud_project_versions WHERE project_id = ?`).bind(projectId),
    db.prepare(`DELETE FROM cloud_project_manifest_objects WHERE project_id = ?`).bind(projectId),
    db.prepare(`DELETE FROM cloud_project_manifests WHERE project_id = ?`).bind(projectId),
    db.prepare(`DELETE FROM cloud_project_files WHERE project_id = ?`).bind(projectId),
    db.prepare(`DELETE FROM cloud_project_objects WHERE project_id = ?`).bind(projectId),
    db.prepare(`DELETE FROM cloud_projects WHERE id = ?`).bind(projectId),
  ]);
}

/** Hourly sweep: presigned objects never verified within 2 h. */
export async function stalePendingObjects(
  db: D1Database,
  cutoffIso: string,
  limit = 200,
): Promise<Array<{ projectId: string; sha256: string; r2Key: string }>> {
  const { results } = await db
    .prepare(
      `SELECT project_id, sha256, r2_key FROM cloud_project_objects
        WHERE status = 'pending' AND created_at < ? LIMIT ?`,
    )
    .bind(cutoffIso, limit)
    .all<{ project_id: string; sha256: string; r2_key: string }>();
  return (results ?? []).map((r) => ({ projectId: r.project_id, sha256: r.sha256, r2Key: r.r2_key }));
}
