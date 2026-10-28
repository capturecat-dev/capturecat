/**
 * The cloud-project document WRITES — one implementation, whoever saves:
 *
 *   saveProjectDocument   PUT /cloud-projects/:id/project (routes/cloud-projects.ts)
 *                         and the remote MCP editing tools (src/mcp/project-tools.ts)
 *   restoreProjectVersion POST …/versions/:vid/restore (routes/cloud-project-history.ts)
 *                         and the MCP restore_version tool
 *
 * Each runs the revision CAS, the owner's storage rule, version coalescing
 * and history housekeeping exactly as the session routes always have; the
 * callers only decide WHO may call (session + loadForSave, or an agent token
 * on a project its user owns) and how a refusal is spoken (HTTP JSON or a
 * tool error). A lost CAS is `conflict` with the fresh row — the caller
 * rebases (MCP re-applies its ops once) or answers 409.
 */

import type { Env } from "../types";
import { generateId } from "./id";
import { storageUsageBytes } from "./db";
import type { PlanRecord } from "./plans";
import { checkUploadAllowance, storageDeniedBody } from "./upload-policy";
import { checkProjectDocument, documentKey, sha256Hex } from "./cloud-projects";
import {
  ensureCurrentManifest,
  getCloudProject,
  listCloudFiles,
  listCloudObjects,
  manifestOf,
  type CloudProjectRow,
} from "./cloud-projects-db";
import {
  PRUNE_PER_SAVE,
  checkpointHonoured,
  newVersionKind,
  restoredFileSet,
  shouldExtend,
  versionChangeJSON,
  type SaveHeaders,
} from "./project-history";
import {
  deleteDocumentIfUnreferenced,
  deleteOrphanManifests,
  getManifestEntries,
  getVersion,
  pruneProjectHistory,
  putDocumentSnapshot,
  readStoredDocument,
  readStoredDocumentBytes,
  releaseUnpinnedMedia,
  restoreFileSetStatements,
  saveVersioned,
  type VersionRow,
} from "./project-history-db";

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

export interface SavedVersion {
  id: string;
  seq: number;
  extended: boolean;
}

export type SaveOutcome =
  | { ok: true; revision: number; documentSha256: string; updatedAt: string; version: SavedVersion | null }
  /** The revision moved since `project` was read: `current` is the fresh row. */
  | { ok: false; reason: "conflict"; current: CloudProjectRow }
  /** A plan / quota refusal, as the HTTP route answers it. */
  | { ok: false; reason: "refused"; status: 402 | 413 | 429; body: { error: string; code: string } & Record<string, unknown> };

export interface SaveDocumentInput {
  /** The row as read; its `revision` is the base the document was edited from. */
  project: CloudProjectRow;
  /** The OWNER's plan — storage is theirs whoever saves. */
  plan: PlanRecord;
  /** Who made the change (the version's actor). */
  actorUid: string;
  /** The exact bytes to store (checked with checkProjectDocument by the caller). */
  bytes: Uint8Array;
  /** `checkProjectDocument(…).name`. */
  name: string;
  headers: SaveHeaders;
}

/**
 * Save a new project.json over `input.project.revision` (the body of
 * PUT …/project after its If-Match and document checks).
 */
export async function saveProjectDocument(env: Env, input: SaveDocumentInput): Promise<SaveOutcome> {
  const { project, plan, actorUid, bytes, headers } = input;
  // Storage is the OWNER's even when a team member saves.
  const uid = project.ownerUid;

  // A document that GROWS is new storage: plan gate + quota (decided again
  // atomically in the swap). One that shrinks or holds size is always
  // accepted, so an over-quota or downgraded account can still save edits.
  // The owner's plan governs the owner's storage — a member's own plan is
  // irrelevant to how much the owner may store.
  const growth = bytes.byteLength - project.docBytes;
  if (growth > 0) {
    const used = await storageUsageBytes(env.DB, uid);
    const verdict = checkUploadAllowance(plan, { fileSizeBytes: growth, usedBytes: used });
    if (!verdict.ok) return { ok: false, reason: "refused", status: verdict.status, body: verdict.body };
  }

  // History: extend the head version or open a new one (coalescing rules in
  // lib/project-history.ts). The X-CC-* headers are optional — an old client
  // sends none and its saves still version (per actor, no client id).
  const nowMs = Date.now();
  const now = new Date(nowMs).toISOString();
  // A project whose media was committed before 0027 has no manifest yet:
  // record it so this save's version (and a backfilled one) pins that media.
  const manifestSha = await ensureCurrentManifest(env.DB, project, now);
  const head = project.headVersionId ? await getVersion(env.DB, project.id, project.headVersionId) : null;
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
  const storedBytes = await putDocumentSnapshot(env.R2, key, bytes);
  const result = await saveVersioned(env.DB, {
    swap: {
      uid,
      actorUid,
      projectId: project.id,
      expectedRevision: project.revision,
      newRevision,
      r2Key: key,
      bytes: bytes.byteLength,
      sha256: sha,
      name: input.name,
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
    await env.R2.delete(key);
    const fresh = await getCloudProject(env.DB, project.id);
    if (fresh && fresh.revision !== project.revision) return { ok: false, reason: "conflict", current: fresh };
    const used = await storageUsageBytes(env.DB, uid);
    return { ok: false, reason: "refused", status: 413, body: storageDeniedBody(plan, used) };
  }

  // The previous document stays as its version's snapshot — unless this save
  // extended that version, which then names the new object instead.
  if (project.docR2Key && project.docR2Key !== key) {
    await deleteDocumentIfUnreferenced(env, project.id, project.docR2Key);
  }
  await historyHousekeeping(env, project.id, plan, nowMs, {
    opened: result.version !== null && !result.version.extended,
    manifestMoved: extend && head.manifestSha !== manifestSha,
  });

  const saved = await getCloudProject(env.DB, project.id);
  return { ok: true, revision: newRevision, documentSha256: sha, updatedAt: saved?.updatedAt ?? now, version: result.version };
}

export type RestoreOutcome =
  | {
      ok: true;
      revision: number;
      documentSha256: string;
      updatedAt: string;
      restoredFrom: string;
      version: SavedVersion | null;
      fileCount: number;
    }
  | { ok: false; reason: "conflict"; current: CloudProjectRow }
  | { ok: false; reason: "refused"; status: 400 | 409 | 410 | 413; body: { error: string; code: string } & Record<string, unknown> };

export interface RestoreInput {
  /** The row as read; its `revision` is the one being restored over. */
  project: CloudProjectRow;
  /** The version to bring back. */
  source: VersionRow;
  /** The OWNER's plan (retention, housekeeping). */
  plan: PlanRecord;
  actorUid: string;
  headers: SaveHeaders;
}

/**
 * Restore = a NEW revision whose document is the version's and whose file
 * set is the union of the current one and the version's (its paths win).
 * Never deletes anything the history still needs: it is an edit, not a
 * rollback (the replaced revision stays in history).
 */
export async function restoreProjectVersion(env: Env, input: RestoreInput): Promise<RestoreOutcome> {
  const { project, source, plan, headers } = input;
  const bytes = await readStoredDocumentBytes(env.R2, source.docR2Key);
  if (bytes === null) {
    return {
      ok: false,
      reason: "refused",
      status: 410,
      body: { error: "This version's document is no longer stored", code: "version_document_missing" },
    };
  }
  const text = new TextDecoder().decode(bytes);
  const check = checkProjectDocument(text, bytes.byteLength, project.id);
  if (!check.ok) return { ok: false, reason: "refused", status: check.status, body: check.body };

  const nowMs = Date.now();
  const now = new Date(nowMs).toISOString();

  // The version's media back into the committed set: its paths win, the
  // current ones stay (union). Pinned objects are still stored, so this
  // adds no bytes — which is why members may restore.
  const currentManifest = await ensureCurrentManifest(env.DB, project, now);
  const versionEntries = (await getManifestEntries(env.DB, project.id, source.manifestSha)) ?? [];
  const objects = new Map(
    (await listCloudObjects(env.DB, project.id)).filter((o) => o.status === "ready").map((o) => [o.sha256, o]),
  );
  const missing = versionEntries.filter((e) => !objects.has(e.sha256)).map((e) => e.path);
  if (missing.length > 0) {
    return {
      ok: false,
      reason: "refused",
      status: 409,
      body: { error: "Some of this version's media is no longer stored", code: "version_media_missing", missing },
    };
  }
  const current = await listCloudFiles(env.DB, project.id);
  const files = restoredFileSet(current, versionEntries);
  const manifest = await manifestOf(files);
  const filesChange = files.length > 0 && manifest.sha !== currentManifest;

  const uid = project.ownerUid;
  const newRevision = project.revision + 1;
  const key = documentKey(uid, project.id, newRevision, generateId(12));
  const sha = await sha256Hex(bytes);
  // A fresh snapshot object: versions never share one, so deleting either
  // version later cannot take the other's document with it.
  const storedBytes = await putDocumentSnapshot(env.R2, key, bytes);
  const result = await saveVersioned(env.DB, {
    swap: {
      uid,
      actorUid: input.actorUid,
      projectId: project.id,
      expectedRevision: project.revision,
      newRevision,
      r2Key: key,
      bytes: bytes.byteLength,
      sha256: sha,
      name: check.name,
      growthBytes: 0, // restore adds no bytes: no quota effect (owner decision)
      limitBytes: plan.limits.maxTotalStorageBytes,
      now,
      // A /finalize commit since we read the file set → refuse, not clobber.
      expectedManifestSha: currentManifest,
    },
    storedBytes,
    version: {
      newId: generateId(16),
      extendId: null, // a restore always opens a new version
      kind: "restore",
      clientKind: headers.clientKind,
      clientId: headers.clientId,
      source: headers.source,
      extendedChangeJSON: null,
      ownChangeJSON: null,
      restoredFrom: source.id,
      mergedFromRevision: null,
      checkpointHonoured: false,
    },
    backfill: legacyBackfill(project),
    between: !filesChange
      ? []
      : restoreFileSetStatements(env.DB, {
          projectId: project.id,
          newRevision,
          r2Key: key,
          files: files.map((f) => ({ ...f, r2Key: objects.get(f.sha256)!.r2Key })),
          manifest,
          now,
        }),
  });
  if (!result.swapped) {
    await env.R2.delete(key);
    const fresh = (await getCloudProject(env.DB, project.id)) ?? project;
    if (fresh.revision !== project.revision) return { ok: false, reason: "conflict", current: fresh };
    return {
      ok: false,
      reason: "refused",
      status: 409,
      body: { error: "The project's media changed while restoring — try again", code: "files_changed" },
    };
  }

  if (project.docR2Key && project.docR2Key !== key) {
    await deleteDocumentIfUnreferenced(env, project.id, project.docR2Key);
  }
  // Paths the version overrode may have orphaned unpinned objects.
  if (filesChange) await releaseUnpinnedMedia(env, project.id);
  await historyHousekeeping(env, project.id, plan, nowMs, { opened: true, manifestMoved: false });

  const saved = await getCloudProject(env.DB, project.id);
  return {
    ok: true,
    revision: newRevision,
    documentSha256: sha,
    updatedAt: saved?.updatedAt ?? now,
    restoredFrom: source.id,
    version: result.version,
    fileCount: files.length,
  };
}
