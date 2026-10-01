/**
 * D1 + R2 layer for cloud-project history (migration 0027). The rules are
 * pure in lib/project-history.ts; the routes are routes/cloud-project-history.ts
 * and the versioned save in routes/cloud-projects.ts.
 *
 * Invariants:
 *   - The head version (cloud_projects.head_version_id) holds the CURRENT
 *     revision; its doc_r2_key IS cloud_projects.doc_r2_key. It is never
 *     deleted or pruned.
 *   - Every version statement of a save runs in the SAME D1 batch as the
 *     revision CAS and is guarded on it having landed (`revision = new AND
 *     doc_r2_key = <this attempt's key>`), so a lost race writes nothing.
 *   - Each version owns its snapshot object; no two versions share one (a
 *     restore writes a fresh copy), so deleting a version may delete its
 *     object once nothing else names it.
 *   - Media a version's manifest names stays (pinnedSql in cloud-projects-db.ts);
 *     after versions go, `releaseUnpinnedMedia` collects what nothing pins.
 */

import {
  deleteObjectIfUnreferenced,
  ensureCurrentManifest,
  getCloudProject,
  pinnedSql,
  swapCloudDocumentStatement,
  type CloudProjectRow,
  type SwapDocumentInput,
} from "./cloud-projects-db";
import {
  GZIP_ENCODING,
  gunzipBytes,
  gzipBytes,
  selectPrunable,
  type ClientKind,
  type ManifestEntry,
  type RetainedVersion,
  type RetentionLimits,
  type SaveSource,
  type VersionKind,
} from "./project-history";

export interface HistoryEnv {
  DB: D1Database;
  R2: R2Bucket;
}

export interface VersionRow {
  id: string;
  projectId: string;
  seq: number;
  firstRevision: number;
  revision: number;
  docR2Key: string;
  docBytes: number;
  storedBytes: number;
  docSha256: string;
  manifestSha: string | null;
  kind: VersionKind;
  label: string | null;
  namedBy: string | null;
  namedAt: string | null;
  actorUid: string | null;
  clientKind: ClientKind;
  clientId: string | null;
  source: SaveSource;
  changeJSON: string | null;
  restoredFrom: string | null;
  mergedFromRevision: number | null;
  openedAt: string;
  updatedAt: string;
}

interface VersionDbRow {
  id: string;
  project_id: string;
  seq: number;
  first_revision: number;
  revision: number;
  doc_r2_key: string;
  doc_bytes: number;
  stored_bytes: number;
  doc_sha256: string;
  manifest_sha: string | null;
  kind: VersionKind;
  label: string | null;
  named_by: string | null;
  named_at: string | null;
  actor_uid: string | null;
  client_kind: ClientKind;
  client_id: string | null;
  source: SaveSource;
  change_json: string | null;
  restored_from: string | null;
  merged_from_revision: number | null;
  opened_at: string;
  updated_at: string;
}

function toVersion(r: VersionDbRow): VersionRow {
  return {
    id: r.id,
    projectId: r.project_id,
    seq: r.seq,
    firstRevision: r.first_revision,
    revision: r.revision,
    docR2Key: r.doc_r2_key,
    docBytes: r.doc_bytes,
    storedBytes: r.stored_bytes,
    docSha256: r.doc_sha256,
    manifestSha: r.manifest_sha,
    kind: r.kind,
    label: r.label,
    namedBy: r.named_by,
    namedAt: r.named_at,
    actorUid: r.actor_uid,
    clientKind: r.client_kind,
    clientId: r.client_id,
    source: r.source,
    changeJSON: r.change_json,
    restoredFrom: r.restored_from,
    mergedFromRevision: r.merged_from_revision,
    openedAt: r.opened_at,
    updatedAt: r.updated_at,
  };
}

/** One version, with its actor's and namer's display names. */
export async function getVersion(
  db: D1Database,
  projectId: string,
  id: string,
): Promise<(VersionRow & { actorName: string | null; namedByName: string | null }) | null> {
  const row = await db
    .prepare(
      `SELECT v.*, au.name AS actor_name, nu.name AS named_by_name
         FROM cloud_project_versions v
         LEFT JOIN "user" au ON au.id = v.actor_uid
         LEFT JOIN "user" nu ON nu.id = v.named_by
        WHERE v.project_id = ? AND v.id = ?`,
    )
    .bind(projectId, id)
    .first<VersionDbRow & { actor_name: string | null; named_by_name: string | null }>();
  return row ? { ...toVersion(row), actorName: row.actor_name, namedByName: row.named_by_name } : null;
}

/** The version whose head is `revision` — the only revisions still retained. */
export async function getVersionByRevision(db: D1Database, projectId: string, revision: number): Promise<VersionRow | null> {
  const row = await db
    .prepare(`SELECT * FROM cloud_project_versions WHERE project_id = ? AND revision = ? LIMIT 1`)
    .bind(projectId, revision)
    .first<VersionDbRow>();
  return row ? toVersion(row) : null;
}

/** One page of history, newest first, with each actor's display name. */
export async function listVersionPage(
  db: D1Database,
  projectId: string,
  opts: { beforeSeq: number | null; limit: number },
): Promise<Array<VersionRow & { actorName: string | null; namedByName: string | null }>> {
  const { results } = await db
    .prepare(
      `SELECT v.*, au.name AS actor_name, nu.name AS named_by_name
         FROM cloud_project_versions v
         LEFT JOIN "user" au ON au.id = v.actor_uid
         LEFT JOIN "user" nu ON nu.id = v.named_by
        WHERE v.project_id = ?1 AND (?2 IS NULL OR v.seq < ?2)
        ORDER BY v.seq DESC LIMIT ?3`,
    )
    .bind(projectId, opts.beforeSeq, opts.limit)
    .all<VersionDbRow & { actor_name: string | null; named_by_name: string | null }>();
  return (results ?? []).map((r) => ({ ...toVersion(r), actorName: r.actor_name, namedByName: r.named_by_name }));
}

export async function namedVersionCount(db: D1Database, projectId: string): Promise<number> {
  const row = await db
    .prepare(`SELECT COUNT(*) AS n FROM cloud_project_versions WHERE project_id = ? AND label IS NOT NULL`)
    .bind(projectId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

async function retentionRows(db: D1Database, projectId: string): Promise<RetainedVersion[]> {
  const { results } = await db
    .prepare(
      `SELECT id, seq, label, updated_at, stored_bytes FROM cloud_project_versions WHERE project_id = ?`,
    )
    .bind(projectId)
    .all<{ id: string; seq: number; label: string | null; updated_at: string; stored_bytes: number }>();
  return (results ?? []).map((r) => ({
    id: r.id,
    seq: r.seq,
    label: r.label,
    updatedAt: r.updated_at,
    storedBytes: r.stored_bytes,
  }));
}

export async function getManifestEntries(db: D1Database, projectId: string, manifestSha: string | null): Promise<ManifestEntry[] | null> {
  if (!manifestSha) return null;
  const row = await db
    .prepare(`SELECT files_json FROM cloud_project_manifests WHERE project_id = ? AND manifest_sha = ?`)
    .bind(projectId, manifestSha)
    .first<{ files_json: string }>();
  if (!row) return null;
  try {
    const parsed = JSON.parse(row.files_json) as ManifestEntry[];
    return Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Snapshot objects (R2)
// ---------------------------------------------------------------------------

/** Store a document snapshot gzipped (`customMetadata.enc = "gzip"`).
 *  Returns the stored (compressed) size. */
export async function putDocumentSnapshot(r2: R2Bucket, key: string, bytes: Uint8Array): Promise<number> {
  const gz = await gzipBytes(bytes);
  await r2.put(key, gz, {
    httpMetadata: { contentType: "application/json" },
    customMetadata: { enc: GZIP_ENCODING },
  });
  return gz.byteLength;
}

/** The exact document bytes behind `key`: gunzipped when the object says it
 *  is gzip, raw otherwise (every document saved before 0027). Null = gone. */
export async function readStoredDocumentBytes(r2: R2Bucket, key: string): Promise<Uint8Array | null> {
  const obj = await r2.get(key);
  if (!obj) return null;
  const raw = new Uint8Array(await obj.arrayBuffer());
  return obj.customMetadata?.enc === GZIP_ENCODING ? gunzipBytes(raw) : raw;
}

export async function readStoredDocument(r2: R2Bucket, key: string): Promise<string | null> {
  const bytes = await readStoredDocumentBytes(r2, key);
  return bytes === null ? null : new TextDecoder().decode(bytes);
}

// ---------------------------------------------------------------------------
// The versioned save (one D1 batch)
// ---------------------------------------------------------------------------

export interface VersionedSaveInput {
  swap: SwapDocumentInput;
  /** Bytes the snapshot occupies in R2 (gzip). */
  storedBytes: number;
  version: {
    /** Id for a NEW version (used unless the extend lands). */
    newId: string;
    /** The head version to extend, or null to open a new one. */
    extendId: string | null;
    kind: VersionKind;
    clientKind: ClientKind;
    clientId: string | null;
    source: SaveSource;
    /** change_json when the extend lands (head ∘ save). */
    extendedChangeJSON: string | null;
    /** change_json when a new version opens (the save's own). */
    ownChangeJSON: string | null;
    restoredFrom: string | null;
    mergedFromRevision: number | null;
    checkpointHonoured: boolean;
  };
  /** A project saved before 0027 has no version for its current document:
   *  record it (as its `upload` version) in the same batch, before the new one. */
  backfill: {
    id: string;
    revision: number;
    r2Key: string;
    bytes: number;
    sha256: string;
    at: string;
    actorUid: string | null;
  } | null;
  /** Extra statements after the CAS and before the version rows, guarded by
   *  the caller on the CAS (`savedGuardSql`): restore's file-set change. */
  between?: D1PreparedStatement[];
}

export type VersionedSaveResult =
  | { swapped: false }
  | { swapped: true; version: { id: string; seq: number; extended: boolean } | null };

/** SQL guard (params ?1 project, ?2 new revision, ?3 this attempt's doc key):
 *  true only once THIS save's CAS has landed. */
export const SAVED_GUARD_SQL = `EXISTS (SELECT 1 FROM cloud_projects WHERE id = ?1 AND revision = ?2 AND doc_r2_key = ?3)`;

export async function saveVersioned(db: D1Database, input: VersionedSaveInput): Promise<VersionedSaveResult> {
  const { swap, version: v } = input;
  const p = swap.projectId;
  const rev = swap.newRevision;
  const key = swap.r2Key;
  const statements: D1PreparedStatement[] = [swapCloudDocumentStatement(db, swap)];

  const bf = input.backfill;
  if (bf) {
    statements.push(
      db
        .prepare(
          `INSERT INTO cloud_project_versions
             (id, project_id, seq, first_revision, revision, doc_r2_key, doc_bytes, stored_bytes, doc_sha256,
              manifest_sha, kind, actor_uid, client_kind, source, opened_at, updated_at)
           SELECT ?4, cp.id, cp.next_version_seq, ?5, ?5, ?6, ?7, ?7, ?8,
                  cp.manifest_sha, 'upload', ?9, 'unknown', 'human', ?10, ?10
             FROM cloud_projects cp
            WHERE cp.id = ?1 AND cp.revision = ?2 AND cp.doc_r2_key = ?3 AND cp.head_version_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM cloud_project_versions WHERE project_id = ?1 AND revision = ?5)`,
        )
        .bind(p, rev, key, bf.id, bf.revision, bf.r2Key, bf.bytes, bf.sha256, bf.actorUid, bf.at),
      db
        .prepare(
          `UPDATE cloud_projects SET head_version_id = ?4, next_version_seq = next_version_seq + 1
            WHERE id = ?1 AND revision = ?2 AND doc_r2_key = ?3 AND head_version_id IS NULL
              AND EXISTS (SELECT 1 FROM cloud_project_versions WHERE id = ?4)`,
        )
        .bind(p, rev, key, bf.id),
    );
  }

  statements.push(...(input.between ?? []));

  if (v.extendId) {
    // Still the head, still unnamed, still an edit — re-checked HERE, so a
    // rename that landed after the decision makes this a no-op and the
    // insert below opens a new version instead.
    statements.push(
      db
        .prepare(
          `UPDATE cloud_project_versions
              SET revision = ?2, doc_r2_key = ?3, doc_bytes = ?5, stored_bytes = ?6, doc_sha256 = ?7,
                  manifest_sha = (SELECT manifest_sha FROM cloud_projects WHERE id = ?1),
                  change_json = ?8, updated_at = ?9
            WHERE id = ?4 AND project_id = ?1 AND label IS NULL AND kind = 'edit'
              AND id = (SELECT head_version_id FROM cloud_projects WHERE id = ?1)
              AND ${SAVED_GUARD_SQL}`,
        )
        .bind(p, rev, key, v.extendId, swap.bytes, input.storedBytes, swap.sha256, v.extendedChangeJSON, swap.now),
    );
  }

  statements.push(
    db
      .prepare(
        `INSERT INTO cloud_project_versions
           (id, project_id, seq, first_revision, revision, doc_r2_key, doc_bytes, stored_bytes, doc_sha256,
            manifest_sha, kind, actor_uid, client_kind, client_id, source, change_json, restored_from,
            merged_from_revision, opened_at, updated_at)
         SELECT ?4, cp.id, cp.next_version_seq, ?2, ?2, ?3, ?5, ?6, ?7,
                cp.manifest_sha, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?16
           FROM cloud_projects cp
          WHERE cp.id = ?1 AND cp.revision = ?2 AND cp.doc_r2_key = ?3
            AND NOT EXISTS (SELECT 1 FROM cloud_project_versions WHERE project_id = ?1 AND revision = ?2)`,
      )
      .bind(
        p,
        rev,
        key,
        v.newId,
        swap.bytes,
        input.storedBytes,
        swap.sha256,
        v.kind,
        swap.actorUid,
        v.clientKind,
        v.clientId,
        v.source,
        v.ownChangeJSON,
        v.restoredFrom,
        v.mergedFromRevision,
        swap.now,
      ),
    db
      .prepare(
        `UPDATE cloud_projects
            SET head_version_id = ?4, next_version_seq = next_version_seq + 1,
                last_checkpoint_at = CASE WHEN ?5 = 1 THEN ?6 ELSE last_checkpoint_at END
          WHERE id = ?1 AND revision = ?2 AND doc_r2_key = ?3
            AND EXISTS (SELECT 1 FROM cloud_project_versions WHERE id = ?4)`,
      )
      .bind(p, rev, key, v.newId, v.checkpointHonoured ? 1 : 0, swap.now),
    db
      .prepare(
        `SELECT id, seq FROM cloud_project_versions WHERE project_id = ?1 AND revision = ?2 AND doc_r2_key = ?3`,
      )
      .bind(p, rev, key),
  );

  const results = await db.batch(statements);
  if ((results[0]?.meta?.changes ?? 0) === 0) return { swapped: false };
  const row = (results[results.length - 1]?.results?.[0] ?? null) as { id: string; seq: number } | null;
  return {
    swapped: true,
    version: row ? { id: row.id, seq: row.seq, extended: row.id === v.extendId } : null,
  };
}

/**
 * Restore's file-set change, as statements for `saveVersioned({ between })`:
 * the committed set becomes `files` (the version's paths win over the
 * current ones, unioned), its manifest is recorded and becomes current —
 * all guarded on the restore's CAS. Only ready objects are referenced.
 */
export function restoreFileSetStatements(
  db: D1Database,
  input: {
    projectId: string;
    newRevision: number;
    r2Key: string;
    files: Array<ManifestEntry & { r2Key: string }>;
    manifest: { sha: string; text: string; shas: string[] };
    now: string;
  },
): D1PreparedStatement[] {
  const g = [input.projectId, input.newRevision, input.r2Key] as const;
  const insert = db.prepare(
    `INSERT INTO cloud_project_files (project_id, path, sha256, bytes, content_type, r2_key, source, uploaded_at)
     SELECT ?1, ?4, ?5, ?6, ?7, ?8, ?9, ?10
      WHERE ${SAVED_GUARD_SQL}
        AND EXISTS (SELECT 1 FROM cloud_project_objects WHERE project_id = ?1 AND sha256 = ?5 AND status = 'ready')`,
  );
  return [
    db.prepare(`DELETE FROM cloud_project_files WHERE project_id = ?1 AND ${SAVED_GUARD_SQL}`).bind(...g),
    ...input.files.map((f) =>
      insert.bind(...g, f.path, f.sha256, f.bytes, f.contentType, f.r2Key, f.source ?? null, input.now),
    ),
    db
      .prepare(
        `INSERT OR IGNORE INTO cloud_project_manifests (project_id, manifest_sha, files_json, created_at)
         SELECT ?1, ?4, ?5, ?6 WHERE ${SAVED_GUARD_SQL}`,
      )
      .bind(...g, input.manifest.sha, input.manifest.text, input.now),
    db
      .prepare(
        `INSERT OR IGNORE INTO cloud_project_manifest_objects (project_id, manifest_sha, sha256)
         SELECT ?1, ?4, value FROM json_each(?5) WHERE ${SAVED_GUARD_SQL}`,
      )
      .bind(...g, input.manifest.sha, JSON.stringify(input.manifest.shas)),
    db
      .prepare(
        `UPDATE cloud_projects
            SET manifest_sha = ?4,
                total_bytes = doc_bytes + (
                  SELECT COALESCE(SUM(o.bytes), 0) FROM cloud_project_objects o
                   WHERE o.project_id = ?1
                     AND o.sha256 IN (SELECT sha256 FROM cloud_project_files WHERE project_id = ?1))
          WHERE id = ?1 AND revision = ?2 AND doc_r2_key = ?3`,
      )
      .bind(...g, input.manifest.sha),
  ];
}

// ---------------------------------------------------------------------------
// Lazy backfill (history reads)
// ---------------------------------------------------------------------------

/**
 * A project saved before 0027 has a document but no version: give its
 * current revision an `upload` version (pinning the media it was saved
 * against) so History has a row to show and restore to. Idempotent and
 * race-safe (guarded on `head_version_id IS NULL` + the current revision).
 * Returns the (possibly refreshed) project row.
 */
export async function ensureHistory(
  db: D1Database,
  project: CloudProjectRow,
  newId: string,
  now: string,
): Promise<CloudProjectRow> {
  if (project.headVersionId || project.revision === 0 || !project.docR2Key || !project.docSha256) return project;
  await ensureCurrentManifest(db, project, now);
  await db.batch([
    db
      .prepare(
        `INSERT INTO cloud_project_versions
           (id, project_id, seq, first_revision, revision, doc_r2_key, doc_bytes, stored_bytes, doc_sha256,
            manifest_sha, kind, actor_uid, client_kind, source, opened_at, updated_at)
         SELECT ?4, cp.id, cp.next_version_seq, cp.revision, cp.revision, cp.doc_r2_key, cp.doc_bytes, cp.doc_bytes,
                cp.doc_sha256, cp.manifest_sha, 'upload', cp.updated_by, 'unknown', 'human', cp.updated_at, cp.updated_at
           FROM cloud_projects cp
          WHERE cp.id = ?1 AND cp.revision = ?2 AND cp.doc_r2_key = ?3 AND cp.head_version_id IS NULL
            AND NOT EXISTS (SELECT 1 FROM cloud_project_versions WHERE project_id = ?1 AND revision = ?2)`,
      )
      .bind(project.id, project.revision, project.docR2Key, newId),
    db
      .prepare(
        `UPDATE cloud_projects SET head_version_id = ?4, next_version_seq = next_version_seq + 1
          WHERE id = ?1 AND revision = ?2 AND doc_r2_key = ?3 AND head_version_id IS NULL
            AND EXISTS (SELECT 1 FROM cloud_project_versions WHERE id = ?4)`,
      )
      .bind(project.id, project.revision, project.docR2Key, newId),
  ]);
  return (await getCloudProject(db, project.id)) ?? project;
}

// ---------------------------------------------------------------------------
// Deleting versions and releasing what they pinned
// ---------------------------------------------------------------------------

/** Delete a snapshot object unless a version or the project still names it. */
export async function deleteDocumentIfUnreferenced(env: HistoryEnv, projectId: string, key: string): Promise<boolean> {
  const ref = await env.DB
    .prepare(
      `SELECT 1 AS hit FROM cloud_project_versions WHERE project_id = ?1 AND doc_r2_key = ?2
        UNION ALL SELECT 1 FROM cloud_projects WHERE id = ?1 AND doc_r2_key = ?2
        LIMIT 1`,
    )
    .bind(projectId, key)
    .first<{ hit: number }>();
  if (ref) return false;
  await env.R2.delete(key);
  return true;
}

/** Manifests no version references and that are not the committed set's. */
export async function deleteOrphanManifests(db: D1Database, projectId: string): Promise<void> {
  const orphan = (table: string) => `
    project_id = ?1
    AND manifest_sha IS NOT (SELECT manifest_sha FROM cloud_projects WHERE id = ?1)
    AND NOT EXISTS (SELECT 1 FROM cloud_project_versions v
                     WHERE v.project_id = ?1 AND v.manifest_sha = ${table}.manifest_sha)`;
  await db.batch([
    db
      .prepare(`DELETE FROM cloud_project_manifest_objects WHERE ${orphan("cloud_project_manifest_objects")}`)
      .bind(projectId),
    db.prepare(`DELETE FROM cloud_project_manifests WHERE ${orphan("cloud_project_manifests")}`).bind(projectId),
  ]);
}

/**
 * Collect ready media nothing references any more (not committed, not pinned
 * by a version, not staged): row first (re-checked atomically), then bytes.
 * Returns what was released.
 */
export async function releaseUnpinnedMedia(env: HistoryEnv, projectId: string): Promise<{ count: number; bytes: number }> {
  const { results } = await env.DB
    .prepare(
      `SELECT o.sha256, o.r2_key, o.bytes FROM cloud_project_objects o
        WHERE o.project_id = ?1 AND o.status = 'ready'
          AND NOT EXISTS (SELECT 1 FROM cloud_project_files f WHERE f.project_id = ?1 AND f.sha256 = o.sha256)
          AND NOT ${pinnedSql("?1", "o.sha256")}
        LIMIT 500`,
    )
    .bind(projectId)
    .all<{ sha256: string; r2_key: string; bytes: number }>();
  let count = 0;
  let bytes = 0;
  for (const o of results ?? []) {
    if (await deleteObjectIfUnreferenced(env.DB, projectId, o.sha256)) {
      await env.R2.delete(o.r2_key);
      count += 1;
      bytes += o.bytes;
    }
  }
  return { count, bytes };
}

/**
 * Delete versions (never the head — re-checked in the statement), their
 * snapshot objects, orphaned manifests, and the media only they pinned.
 */
export async function deleteVersions(
  env: HistoryEnv,
  projectId: string,
  ids: readonly string[],
): Promise<{ deleted: string[]; releasedBytes: number }> {
  const deleted: string[] = [];
  for (let i = 0; i < ids.length; i += 100) {
    const { results } = await env.DB
      .prepare(
        `DELETE FROM cloud_project_versions
          WHERE project_id = ?1 AND id IN (SELECT value FROM json_each(?2))
            AND id IS NOT (SELECT head_version_id FROM cloud_projects WHERE id = ?1)
          RETURNING id, doc_r2_key`,
      )
      .bind(projectId, JSON.stringify(ids.slice(i, i + 100)))
      .all<{ id: string; doc_r2_key: string }>();
    for (const r of results ?? []) {
      deleted.push(r.id);
      await deleteDocumentIfUnreferenced(env, projectId, r.doc_r2_key);
    }
  }
  if (deleted.length === 0) return { deleted, releasedBytes: 0 };
  await deleteOrphanManifests(env.DB, projectId);
  const released = await releaseUnpinnedMedia(env, projectId);
  return { deleted, releasedBytes: released.bytes };
}

/** Apply the retention rules to one project (at most `maxDeletes` versions). */
export async function pruneProjectHistory(
  env: HistoryEnv,
  projectId: string,
  limits: RetentionLimits,
  nowMs: number,
  maxDeletes: number,
): Promise<{ deleted: string[]; releasedBytes: number }> {
  const head = await env.DB
    .prepare(`SELECT head_version_id FROM cloud_projects WHERE id = ?`)
    .bind(projectId)
    .first<{ head_version_id: string | null }>();
  const ids = selectPrunable(await retentionRows(env.DB, projectId), head?.head_version_id ?? null, limits, nowMs, {
    maxDeletes,
  });
  if (ids.length === 0) return { deleted: [], releasedBytes: 0 };
  return deleteVersions(env, projectId, ids);
}

// ---------------------------------------------------------------------------
// "History keeps X of removed media [Free up]"
// ---------------------------------------------------------------------------

/**
 * pinnedMediaBytes: ready media the committed set no longer references that
 * history still holds. freeableBytes: the part only UNNAMED, non-head
 * versions hold — what "Free up" releases.
 */
export async function historyMediaStats(
  db: D1Database,
  projectId: string,
): Promise<{ pinnedMediaBytes: number; freeableBytes: number }> {
  const row = await db
    .prepare(
      `SELECT COALESCE(SUM(o.bytes), 0) AS pinned,
              COALESCE(SUM(CASE WHEN NOT EXISTS (
                  SELECT 1 FROM cloud_project_manifest_objects mo
                    JOIN cloud_project_versions kv
                      ON kv.project_id = mo.project_id AND kv.manifest_sha = mo.manifest_sha
                   WHERE mo.project_id = ?1 AND mo.sha256 = o.sha256
                     AND (kv.label IS NOT NULL OR kv.id IS (SELECT head_version_id FROM cloud_projects WHERE id = ?1)))
                THEN o.bytes ELSE 0 END), 0) AS freeable
         FROM cloud_project_objects o
        WHERE o.project_id = ?1 AND o.status = 'ready'
          AND NOT EXISTS (SELECT 1 FROM cloud_project_files f WHERE f.project_id = ?1 AND f.sha256 = o.sha256)
          AND ${pinnedSql("?1", "o.sha256")}`,
    )
    .bind(projectId)
    .first<{ pinned: number; freeable: number }>();
  return { pinnedMediaBytes: row?.pinned ?? 0, freeableBytes: row?.freeable ?? 0 };
}

/** The unnamed, non-head versions pinning media the committed set dropped. */
export async function freeUpCandidates(db: D1Database, projectId: string): Promise<string[]> {
  const { results } = await db
    .prepare(
      `SELECT v.id FROM cloud_project_versions v
        WHERE v.project_id = ?1 AND v.label IS NULL
          AND v.id IS NOT (SELECT head_version_id FROM cloud_projects WHERE id = ?1)
          AND EXISTS (SELECT 1 FROM cloud_project_manifest_objects mo
                       WHERE mo.project_id = ?1 AND mo.manifest_sha = v.manifest_sha
                         AND NOT EXISTS (SELECT 1 FROM cloud_project_files f
                                          WHERE f.project_id = ?1 AND f.sha256 = mo.sha256))
        ORDER BY v.seq`,
    )
    .bind(projectId)
    .all<{ id: string }>();
  return (results ?? []).map((r) => r.id);
}

// ---------------------------------------------------------------------------
// Hourly sweep
// ---------------------------------------------------------------------------

/**
 * Retention for the projects least recently swept (with more than one
 * version ever): each owner's CURRENT plan decides, so a downgrade trims on
 * the next pass. Then manifests orphaned anywhere (older than an hour) go.
 */
export async function sweepCloudProjectHistory(
  env: HistoryEnv,
  nowMs: number,
  limitsFor: (ownerUid: string) => Promise<RetentionLimits>,
  opts: { projects?: number; perProject?: number } = {},
): Promise<{ projects: number; deleted: number }> {
  const now = new Date(nowMs).toISOString();
  const { results } = await env.DB
    .prepare(
      `SELECT id, owner_uid FROM cloud_projects
        WHERE next_version_seq > 2
        ORDER BY history_swept_at IS NOT NULL, history_swept_at
        LIMIT ?`,
    )
    .bind(opts.projects ?? 100)
    .all<{ id: string; owner_uid: string }>();
  let deleted = 0;
  const limitsCache = new Map<string, RetentionLimits>();
  for (const p of results ?? []) {
    try {
      let limits = limitsCache.get(p.owner_uid);
      if (!limits) {
        limits = await limitsFor(p.owner_uid);
        limitsCache.set(p.owner_uid, limits);
      }
      const res = await pruneProjectHistory(env, p.id, limits, nowMs, opts.perProject ?? 200);
      deleted += res.deleted.length;
    } catch (err) {
      console.error(`history sweep: project ${p.id}`, err);
    }
    await env.DB.prepare(`UPDATE cloud_projects SET history_swept_at = ? WHERE id = ?`).bind(now, p.id).run();
  }

  // Manifests nothing references: a commit superseded them before any save
  // pinned them. An hour's grace is belt-and-braces (every writer records a
  // manifest and points at it in one batch).
  const cutoff = new Date(nowMs - 3600 * 1000).toISOString();
  const orphans = `
    SELECT m.project_id, m.manifest_sha FROM cloud_project_manifests m
      JOIN cloud_projects cp ON cp.id = m.project_id
     WHERE m.created_at < ?1 AND m.manifest_sha IS NOT cp.manifest_sha
       AND NOT EXISTS (SELECT 1 FROM cloud_project_versions v
                        WHERE v.project_id = m.project_id AND v.manifest_sha = m.manifest_sha)
     LIMIT 500`;
  await env.DB.batch([
    env.DB
      .prepare(`DELETE FROM cloud_project_manifest_objects WHERE (project_id, manifest_sha) IN (${orphans})`)
      .bind(cutoff),
    env.DB.prepare(`DELETE FROM cloud_project_manifests WHERE (project_id, manifest_sha) IN (${orphans})`).bind(cutoff),
  ]);
  return { projects: results?.length ?? 0, deleted };
}
