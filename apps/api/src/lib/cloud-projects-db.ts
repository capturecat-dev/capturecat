/**
 * D1 data layer for cloud projects (migration 0026). Prepared statements
 * only; the rules live in lib/cloud-projects.ts and the flow in
 * routes/cloud-projects.ts.
 */

import { STORAGE_SUM_SQL, isOrgMember } from "./db";

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

export async function getCloudProject(db: D1Database, id: string): Promise<CloudProjectRow | null> {
  const row = await db.prepare(`SELECT * FROM cloud_projects WHERE id = ?`).bind(id).first<ProjectDbRow>();
  return row ? toProject(row) : null;
}

/** Owner = full access; a member of the project's org = read-only; else none. */
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
  const wanted = JSON.stringify([...new Set(input.files.map((f) => f.sha256))]);
  // ?1 owner (STORAGE_SUM_SQL's uid slot), ?2 project, ?3 staged_at,
  // ?4 claim token, ?5 wanted SHA-256s (JSON array), ?6 limit.
  const readyBytes = (shaFilter: string) =>
    `(SELECT COALESCE(SUM(o.bytes), 0) FROM cloud_project_objects o
       WHERE o.project_id = ?2 AND o.status = 'ready' AND ${shaFilter})`;
  const claim = db
    .prepare(
      `UPDATE cloud_projects SET staged_at = ?4
        WHERE id = ?2 AND staged_at = ?3
          AND (
            ${readyBytes("o.sha256 IN (SELECT value FROM json_each(?5))")}
              <= ${readyBytes("o.sha256 IN (SELECT sha256 FROM cloud_project_files WHERE project_id = ?2)")}
            OR ((${STORAGE_SUM_SQL}) - ${readyBytes("o.sha256 NOT IN (SELECT value FROM json_each(?5))")}) <= ?6
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
    db
      .prepare(
        `UPDATE cloud_projects
            SET staged_manifest = NULL, staged_at = NULL, updated_at = ?3,
                total_bytes = doc_bytes + (
                  SELECT COALESCE(SUM(o.bytes), 0) FROM cloud_project_objects o
                   WHERE o.project_id = ?1
                     AND o.sha256 IN (SELECT sha256 FROM cloud_project_files WHERE project_id = ?1))
          WHERE id = ?1 AND staged_at = ?2`,
      )
      .bind(input.projectId, token, input.now),
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
 * Drop one object row if nothing COMMITTED references it (the NOT EXISTS is
 * re-checked inside the statement, so a concurrent commit cannot lose a file
 * to garbage collection). Returns true when the row went — the caller then
 * deletes the R2 bytes.
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
          AND NOT EXISTS (SELECT 1 FROM cloud_project_files WHERE project_id = ?1 AND sha256 = ?2)`,
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
 */
export async function swapCloudDocument(
  db: D1Database,
  input: {
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
  },
): Promise<boolean> {
  const res = await db
    .prepare(
      `UPDATE cloud_projects
          SET revision = ?2, doc_r2_key = ?3, doc_bytes = ?4, doc_sha256 = ?5, name = ?6,
              total_bytes = total_bytes - doc_bytes + ?4, updated_at = ?7, updated_by = ?12
        WHERE id = ?8 AND owner_uid = ?1 AND revision = ?9
          AND (?10 <= 0 OR (?10 + (${STORAGE_SUM_SQL})) <= ?11)`,
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
    )
    .run();
  return (res.meta?.changes ?? 0) > 0;
}

/** Remove every row of a project (objects/files first; FKs cascade too). */
export async function deleteCloudProjectRows(db: D1Database, projectId: string): Promise<void> {
  await db.batch([
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
