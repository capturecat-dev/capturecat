import { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { planForUser, requireEntitlement } from "../lib/entitlement";
import { parseJsonBody } from "../lib/validate";
import { generateId } from "../lib/id";
import {
  GET_URL_TTL_SECONDS,
  checkProjectDocument,
  documentKey,
  parseIfMatchRevision,
  sha256Hex,
} from "../lib/cloud-projects";
import {
  ensureCurrentManifest,
  getCloudProject,
  listCloudFiles,
  listCloudObjects,
  manifestOf,
  type CloudProjectRow,
} from "../lib/cloud-projects-db";
import {
  VERSIONS_PAGE_DEFAULT,
  VERSIONS_PAGE_MAX,
  isVersionId,
  normalizeLabel,
  parseSaveHeaders,
  restoredFileSet,
  type Json,
} from "../lib/project-history";
import {
  deleteDocumentIfUnreferenced,
  deleteVersions,
  ensureHistory,
  freeUpCandidates,
  getManifestEntries,
  getVersion,
  getVersionByRevision,
  historyMediaStats,
  listVersionPage,
  namedVersionCount,
  putDocumentSnapshot,
  readStoredDocumentBytes,
  releaseUnpinnedMedia,
  restoreFileSetStatements,
  saveVersioned,
  type VersionRow,
} from "../lib/project-history-db";
import {
  historyHousekeeping,
  legacyBackfill,
  loadForRead,
  loadForSave,
  loadForWrite,
  ownerPlan,
  presignFiles,
  revisionConflict,
  saveLimit,
  syncLimit,
  type Ctx,
} from "./cloud-projects";

/**
 * Cloud-project history (docs/project-history.md §6; design 2026-09-30).
 *
 *   GET    /cloud-projects/:id/head                    revision + head version (cheap poll)
 *   GET    /cloud-projects/:id/versions?before=&limit=  history, newest first
 *   GET    /cloud-projects/:id/versions/:vid           a version's document + presigned media
 *   GET    /cloud-projects/:id/revisions/:rev/document a retained revision's document (merge base)
 *   PATCH  /cloud-projects/:id/versions/:vid           name / un-name   { label: string | null }
 *   POST   /cloud-projects/:id/versions/:vid/restore   restore (If-Match: current revision)
 *   DELETE /cloud-projects/:id/versions/:vid           delete a version (owner; never the head)
 *   POST   /cloud-projects/:id/history/free-up         delete the unnamed versions pinning removed media (owner)
 *
 * Access (owner decision 2026-09-30): org members READ, NAME and RESTORE —
 * restore re-commits media the project already stores, so it adds no bytes
 * and has no quota effect. Only the OWNER deletes versions or frees media.
 * Retention, the named-version cap and every byte are the OWNER's plan's,
 * whoever acts. Reads follow GET /cloud-projects/:id (no entitlement gate;
 * a lapsed owner keeps reading their own history, members lose it with
 * team access).
 */
export const cloudProjectHistoryRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

const nowIso = () => new Date().toISOString();

function parseChange(text: string | null): Json | null {
  if (!text) return null;
  try {
    return JSON.parse(text) as Json;
  } catch {
    return null;
  }
}

function versionJSON(
  v: VersionRow & { actorName?: string | null; namedByName?: string | null },
  headVersionId: string | null,
) {
  return {
    id: v.id,
    seq: v.seq,
    kind: v.kind,
    label: v.label,
    namedBy: v.namedBy ? { uid: v.namedBy, name: v.namedByName ?? null } : null,
    namedAt: v.namedAt,
    actor: v.actorUid ? { uid: v.actorUid, name: v.actorName ?? null } : null,
    client: v.clientKind,
    source: v.source,
    firstRevision: v.firstRevision,
    revision: v.revision,
    documentBytes: v.docBytes,
    documentSha256: v.docSha256,
    // The change-set (docs/project-history.md §4) from the previous version
    // to this one, or null when unknown (a client that sent no X-CC-Change).
    change: parseChange(v.changeJSON),
    restoredFrom: v.restoredFrom,
    mergedFromRevision: v.mergedFromRevision,
    openedAt: v.openedAt,
    updatedAt: v.updatedAt,
    isHead: v.id === headVersionId,
  };
}

/** :vid of a project the caller may read, or the error response. */
async function loadVersion(c: Ctx, project: CloudProjectRow): Promise<{ ok: true; version: VersionRow } | { ok: false; res: Response }> {
  const vid = c.req.param("vid");
  if (!isVersionId(vid)) return { ok: false, res: c.json({ error: "Invalid version id" }, 400) };
  const version = await getVersion(c.env.DB, project.id, vid);
  if (!version) return { ok: false, res: c.json({ error: "Version not found", code: "version_not_found" }, 404) };
  return { ok: true, version };
}

// ---------------------------------------------------------------------------
// GET …/head — polling
// ---------------------------------------------------------------------------

cloudProjectHistoryRoutes.get("/cloud-projects/:id/head", requireAuth, async (c) => {
  const loaded = await loadForRead(c);
  if (!loaded.ok) return loaded.res;
  const p = loaded.project;
  c.header("Cache-Control", "no-store");
  c.header("ETag", `"${p.revision}"`);
  return c.json({
    projectId: p.id,
    revision: p.revision,
    documentSha256: p.docSha256,
    updatedAt: p.updatedAt,
    updatedBy: p.updatedBy,
    headVersionId: p.headVersionId,
  });
});

// ---------------------------------------------------------------------------
// GET …/versions — the History list
// ---------------------------------------------------------------------------

cloudProjectHistoryRoutes.get("/cloud-projects/:id/versions", requireAuth, async (c) => {
  const loaded = await loadForRead(c);
  if (!loaded.ok) return loaded.res;
  // Lazy backfill: a project last saved before 0027 gets its first version now.
  const project = await ensureHistory(c.env.DB, loaded.project, generateId(16), nowIso());

  const beforeRaw = c.req.query("before");
  const before = beforeRaw && /^\d{1,9}$/.test(beforeRaw) ? Number(beforeRaw) : null;
  const limitRaw = Number(c.req.query("limit") ?? VERSIONS_PAGE_DEFAULT);
  const limit = Number.isInteger(limitRaw) ? Math.min(Math.max(limitRaw, 1), VERSIONS_PAGE_MAX) : VERSIONS_PAGE_DEFAULT;

  const [page, plan, namedCount, media] = await Promise.all([
    listVersionPage(c.env.DB, project.id, { beforeSeq: before, limit }),
    planForUser(c.env, project.ownerUid),
    namedVersionCount(c.env.DB, project.id),
    historyMediaStats(c.env.DB, project.id),
  ]);
  c.header("Cache-Control", "no-store");
  return c.json({
    projectId: project.id,
    revision: project.revision,
    headVersionId: project.headVersionId,
    access: loaded.access,
    versions: page.map((v) => versionJSON(v, project.headVersionId)),
    nextBefore: page.length === limit ? page[page.length - 1].seq : null,
    retention: {
      maxHistoryDays: plan.limits.maxHistoryDays,
      maxNamedVersions: plan.limits.maxNamedVersions,
      namedCount,
    },
    // "History keeps X of removed media [Free up]": bytes the committed set
    // dropped that versions still pin (they count toward storage), and the
    // part Free up would release (pinned only by unnamed, non-head versions).
    pinnedMediaBytes: media.pinnedMediaBytes,
    freeableBytes: media.freeableBytes,
  });
});

// ---------------------------------------------------------------------------
// GET …/versions/:vid — preview a version
// ---------------------------------------------------------------------------

cloudProjectHistoryRoutes.get("/cloud-projects/:id/versions/:vid", requireAuth, async (c) => {
  const loaded = await loadForRead(c);
  if (!loaded.ok) return loaded.res;
  const project = loaded.project;
  const found = await loadVersion(c, project);
  if (!found.ok) return found.res;
  const v = found.version;

  const bytes = await readStoredDocumentBytes(c.env.R2, v.docR2Key);
  if (bytes === null) {
    return c.json({ error: "This version's document is no longer stored", code: "version_document_missing" }, 410);
  }
  // The version's media, resolved through ITS manifest (what its document
  // was saved against); objects are pinned, so they are still stored.
  const entries = (await getManifestEntries(c.env.DB, project.id, v.manifestSha)) ?? [];
  const objects = new Map(
    (await listCloudObjects(c.env.DB, project.id)).filter((o) => o.status === "ready").map((o) => [o.sha256, o]),
  );
  const present = entries.filter((e) => objects.has(e.sha256));
  c.header("Cache-Control", "no-store");
  return c.json({
    projectId: project.id,
    version: versionJSON(v, project.headVersionId),
    // Byte-exact project.json text of this version (a JSON string).
    document: new TextDecoder().decode(bytes),
    files: await presignFiles(
      c.env,
      present.map((e) => ({ ...e, source: e.source ?? null, r2Key: objects.get(e.sha256)!.r2Key })),
    ),
    missingPaths: entries.filter((e) => !objects.has(e.sha256)).map((e) => e.path),
    urlsExpireAt: new Date(Date.now() + GET_URL_TTL_SECONDS * 1000).toISOString(),
  });
});

// ---------------------------------------------------------------------------
// GET …/revisions/:rev/document — a retained revision (Mac merge base)
// ---------------------------------------------------------------------------

cloudProjectHistoryRoutes.get("/cloud-projects/:id/revisions/:rev/document", requireAuth, async (c) => {
  const loaded = await loadForRead(c);
  if (!loaded.ok) return loaded.res;
  const project = loaded.project;
  const raw = c.req.param("rev");
  if (!/^\d{1,12}$/.test(raw)) return c.json({ error: "Invalid revision" }, 400);
  const revision = Number(raw);
  // Only revisions some version holds are retained (an extended version
  // keeps only its latest revision). The current revision of a project not
  // yet backfilled is still readable.
  const version = await getVersionByRevision(c.env.DB, project.id, revision);
  const key = version?.docR2Key ?? (revision === project.revision && revision > 0 ? project.docR2Key : null);
  const bytes = key ? await readStoredDocumentBytes(c.env.R2, key) : null;
  if (bytes === null) {
    return c.json({ error: "That revision is not retained", code: "revision_not_retained" }, 404);
  }
  c.header("Cache-Control", "no-store");
  c.header("ETag", `"${revision}"`);
  return c.json({
    projectId: project.id,
    revision,
    versionId: version?.id ?? null,
    documentSha256: version?.docSha256 ?? project.docSha256,
    document: new TextDecoder().decode(bytes),
  });
});

// ---------------------------------------------------------------------------
// PATCH …/versions/:vid — name / un-name
// ---------------------------------------------------------------------------

const LabelBodySchema = z.object({ label: z.string().nullable() });

cloudProjectHistoryRoutes.patch(
  "/cloud-projects/:id/versions/:vid",
  requireAuth,
  requireEntitlement(),
  saveLimit,
  async (c) => {
    const loaded = await loadForSave(c);
    if (!loaded.ok) return loaded.res;
    const project = loaded.project;
    const found = await loadVersion(c, project);
    if (!found.ok) return found.res;
    const parsed = await parseJsonBody(c.req, LabelBodySchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const label = normalizeLabel(parsed.data.label);
    if (!label.ok) return c.json({ error: label.error, code: "invalid_label" }, 400);

    // The cap is the OWNER's plan's, decided inside the statement so two
    // concurrent namings cannot both take the last slot.
    const plan = await ownerPlan(c, project, loaded.access);
    const cap = plan.limits.maxNamedVersions;
    const res = await c.env.DB
      .prepare(
        `UPDATE cloud_project_versions
            SET label = ?3,
                named_by = CASE WHEN ?3 IS NULL THEN NULL ELSE ?4 END,
                named_at = CASE WHEN ?3 IS NULL THEN NULL ELSE ?5 END
          WHERE project_id = ?1 AND id = ?2
            AND (?3 IS NULL OR label IS NOT NULL
                 OR (SELECT COUNT(*) FROM cloud_project_versions WHERE project_id = ?1 AND label IS NOT NULL) < ?6)`,
      )
      .bind(project.id, found.version.id, label.label, c.get("user").uid, nowIso(), cap)
      .run();
    if ((res.meta?.changes ?? 0) === 0) {
      const still = await getVersion(c.env.DB, project.id, found.version.id);
      if (!still) return c.json({ error: "Version not found", code: "version_not_found" }, 404);
      return c.json(
        {
          error:
            cap > 0
              ? `This project already has ${cap} named versions — the most the ${plan.displayName} plan keeps. Remove a name first.`
              : `Named versions are not included in the ${plan.displayName} plan.`,
          code: "named_version_limit",
          limit: cap,
        },
        402,
      );
    }
    const updated = (await getVersion(c.env.DB, project.id, found.version.id))!;
    const fresh = (await getCloudProject(c.env.DB, project.id)) ?? project;
    return c.json({ projectId: project.id, version: versionJSON(updated, fresh.headVersionId) });
  },
);

// ---------------------------------------------------------------------------
// POST …/versions/:vid/restore
// ---------------------------------------------------------------------------

cloudProjectHistoryRoutes.post(
  "/cloud-projects/:id/versions/:vid/restore",
  requireAuth,
  requireEntitlement(),
  saveLimit,
  async (c) => {
    const loaded = await loadForSave(c);
    if (!loaded.ok) return loaded.res;
    const project = loaded.project;
    const found = await loadVersion(c, project);
    if (!found.ok) return found.res;
    const source = found.version;

    const baseRevision = parseIfMatchRevision(c.req.header("If-Match"));
    if (baseRevision === null) {
      return c.json(
        { error: 'Send If-Match: "<revision>" — the revision you are restoring over', code: "revision_required" },
        428,
      );
    }
    if (baseRevision !== project.revision) return revisionConflict(c, project);

    const bytes = await readStoredDocumentBytes(c.env.R2, source.docR2Key);
    if (bytes === null) {
      return c.json({ error: "This version's document is no longer stored", code: "version_document_missing" }, 410);
    }
    const text = new TextDecoder().decode(bytes);
    const check = checkProjectDocument(text, bytes.byteLength, project.id);
    if (!check.ok) return c.json(check.body, check.status);

    const nowMs = Date.now();
    const now = new Date(nowMs).toISOString();

    // The version's media back into the committed set: its paths win, the
    // current ones stay (union). Pinned objects are still stored, so this
    // adds no bytes — which is why members may restore.
    const currentManifest = await ensureCurrentManifest(c.env.DB, project, now);
    const versionEntries = (await getManifestEntries(c.env.DB, project.id, source.manifestSha)) ?? [];
    const objects = new Map(
      (await listCloudObjects(c.env.DB, project.id)).filter((o) => o.status === "ready").map((o) => [o.sha256, o]),
    );
    const missing = versionEntries.filter((e) => !objects.has(e.sha256)).map((e) => e.path);
    if (missing.length > 0) {
      return c.json(
        { error: "Some of this version's media is no longer stored", code: "version_media_missing", missing },
        409,
      );
    }
    const current = await listCloudFiles(c.env.DB, project.id);
    const files = restoredFileSet(current, versionEntries);
    const manifest = await manifestOf(files);
    const filesChange = files.length > 0 && manifest.sha !== currentManifest;

    const uid = project.ownerUid;
    const newRevision = project.revision + 1;
    const key = documentKey(uid, project.id, newRevision, generateId(12));
    const sha = await sha256Hex(bytes);
    // A fresh snapshot object: versions never share one, so deleting either
    // version later cannot take the other's document with it.
    const storedBytes = await putDocumentSnapshot(c.env.R2, key, bytes);
    const headers = parseSaveHeaders((name) => c.req.header(name));
    const plan = await ownerPlan(c, project, loaded.access);
    const result = await saveVersioned(c.env.DB, {
      swap: {
        uid,
        actorUid: c.get("user").uid,
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
        : restoreFileSetStatements(c.env.DB, {
              projectId: project.id,
              newRevision,
              r2Key: key,
              files: files.map((f) => ({ ...f, r2Key: objects.get(f.sha256)!.r2Key })),
              manifest,
              now,
            }),
    });
    if (!result.swapped) {
      await c.env.R2.delete(key);
      const fresh = (await getCloudProject(c.env.DB, project.id)) ?? project;
      if (fresh.revision !== project.revision) return revisionConflict(c, fresh);
      return c.json(
        { error: "The project's media changed while restoring — try again", code: "files_changed" },
        409,
      );
    }

    if (project.docR2Key && project.docR2Key !== key) {
      await deleteDocumentIfUnreferenced(c.env, project.id, project.docR2Key);
    }
    // Paths the version overrode may have orphaned unpinned objects.
    if (filesChange) await releaseUnpinnedMedia(c.env, project.id);
    await historyHousekeeping(c.env, project.id, plan, nowMs, { opened: true, manifestMoved: false });

    const saved = await getCloudProject(c.env.DB, project.id);
    c.header("ETag", `"${newRevision}"`);
    return c.json({
      projectId: project.id,
      revision: newRevision,
      documentSha256: sha,
      updatedAt: saved?.updatedAt ?? now,
      restoredFrom: source.id,
      version: result.version,
      fileCount: files.length,
    });
  },
);

// ---------------------------------------------------------------------------
// DELETE …/versions/:vid — owner only, never the head
// ---------------------------------------------------------------------------

cloudProjectHistoryRoutes.delete("/cloud-projects/:id/versions/:vid", requireAuth, syncLimit, async (c) => {
  const loaded = await loadForWrite(c);
  if (!loaded.ok) return loaded.res;
  const project = loaded.project;
  const found = await loadVersion(c, project);
  if (!found.ok) return found.res;
  if (found.version.id === project.headVersionId) {
    return c.json({ error: "The current version cannot be deleted", code: "head_version" }, 409);
  }
  const res = await deleteVersions(c.env, project.id, [found.version.id]);
  if (res.deleted.length === 0) {
    return c.json({ error: "The current version cannot be deleted", code: "head_version" }, 409);
  }
  return c.json({ projectId: project.id, deleted: true, versionId: found.version.id, releasedBytes: res.releasedBytes });
});

// ---------------------------------------------------------------------------
// POST …/history/free-up — owner only
// ---------------------------------------------------------------------------

cloudProjectHistoryRoutes.post("/cloud-projects/:id/history/free-up", requireAuth, syncLimit, async (c) => {
  const loaded = await loadForWrite(c);
  if (!loaded.ok) return loaded.res;
  const project = loaded.project;
  const ids = await freeUpCandidates(c.env.DB, project.id);
  const res = ids.length > 0 ? await deleteVersions(c.env, project.id, ids) : { deleted: [], releasedBytes: 0 };
  const media = await historyMediaStats(c.env.DB, project.id);
  return c.json({
    projectId: project.id,
    deletedVersions: res.deleted,
    releasedBytes: res.releasedBytes,
    pinnedMediaBytes: media.pinnedMediaBytes,
    freeableBytes: media.freeableBytes,
  });
});
