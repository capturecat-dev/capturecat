import { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { planForUser, requireEntitlement } from "../lib/entitlement";
import { parseJsonBody } from "../lib/validate";
import { generateId } from "../lib/id";
import { GET_URL_TTL_SECONDS, parseIfMatchRevision } from "../lib/cloud-projects";
import { getCloudProject, listCloudObjects, type CloudProjectRow } from "../lib/cloud-projects-db";
import {
  VERSIONS_PAGE_DEFAULT,
  VERSIONS_PAGE_MAX,
  isVersionId,
  normalizeLabel,
  parseSaveHeaders,
  type Json,
} from "../lib/project-history";
import {
  deleteVersions,
  ensureHistory,
  freeUpCandidates,
  getManifestEntries,
  getVersion,
  getVersionByRevision,
  historyMediaStats,
  listVersionPage,
  namedVersionCount,
  readStoredDocumentBytes,
  type VersionRow,
} from "../lib/project-history-db";
import {
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
import { restoreProjectVersion } from "../lib/cloud-project-save";
import { backgroundOf, projectSavedData, queueWebhookEvent } from "../lib/webhooks";

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

    // The restore itself is lib/cloud-project-save.ts, shared with the MCP
    // restore_version tool.
    const restored = await restoreProjectVersion(c.env, {
      project,
      source,
      plan: await ownerPlan(c, project, loaded.access),
      actorUid: c.get("user").uid,
      headers: parseSaveHeaders((name) => c.req.header(name)),
    });
    if (!restored.ok) {
      return restored.reason === "conflict" ? revisionConflict(c, restored.current) : c.json(restored.body, restored.status);
    }
    // A restore is a new saved revision: the owner's project.saved webhook, as for a save.
    queueWebhookEvent(
      backgroundOf(c),
      c.env,
      project.ownerUid,
      "project.saved",
      projectSavedData(c.env, { projectId: project.id, name: project.name, revision: restored.revision, savedAt: restored.updatedAt, by: "user" }),
    );
    c.header("ETag", `"${restored.revision}"`);
    return c.json({
      projectId: project.id,
      revision: restored.revision,
      documentSha256: restored.documentSha256,
      updatedAt: restored.updatedAt,
      restoredFrom: restored.restoredFrom,
      version: restored.version,
      fileCount: restored.fileCount,
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
