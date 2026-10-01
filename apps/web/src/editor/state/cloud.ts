/**
 * Cloud projects — the web editor's client for the API's /api/cloud-projects
 * routes (apps/api/src/routes/cloud-projects.ts; contract in
 * editor/ARCHITECTURE.md → "Storage").
 *
 *   listCloudProjects()        my projects (or a team's, with orgId)
 *   loadCloudProject(id)       raw project.json + revision + media URL map
 *   saveCloudProject(…)        save with the base revision → saved | conflict
 *   refreshMediaUrls(…)        new presigned GETs before the old ones expire
 *   resolveMediaRef(…)         project.json reference → media file
 *   stageCloudProject(…)       manifest → presigned PUTs for the missing files
 *   finalizeCloudProject(…)    verify + commit the uploaded files
 *
 * Auth is the session cookie: every call is `credentials: "include"` against
 * API_URL, the same convention as lib/auth-client.ts and lib/thumbnails.ts
 * (the API's CORS + CSRF gate trust app.capturecat.so).
 *
 * LOSSLESS CONTRACT: the document travels as TEXT both ways. `load` hands
 * back the exact bytes the Mac (or a previous web save) stored, and `save`
 * sends exactly the string it is given. Parsing/serializing is core/model's
 * job (it preserves unknown keys and Swift enum raw values); nothing here
 * ever JSON.stringify()s a project, so this layer cannot drop a key.
 *
 * Pure fetch + types: no React, no store — callable from the main thread or
 * a worker.
 */

import { API_URL } from "@/lib/api-url";

// ---------------------------------------------------------------------------
// Wire types (mirror the API's JSON)
// ---------------------------------------------------------------------------

export interface CloudProjectSummary {
  projectId: string;
  name: string;
  /** project.json revision; 0 = uploaded media but no document yet. */
  revision: number;
  hasDocument: boolean;
  documentSha256: string | null;
  totalBytes: number;
  orgId: string | null;
  isOwner: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface CloudProjectList {
  projects: CloudProjectSummary[];
  /** Present for your own list (not a team's). */
  storage?: { usedBytes: number; limitBytes: number };
}

/** One media file of a project, with a short-lived presigned GET URL. */
export interface CloudMediaFile {
  /** Logical path relative to the Mac project folder, e.g. `recording.mov`. */
  path: string;
  sha256: string;
  bytes: number;
  contentType: string;
  /** The reference exactly as project.json spells it when it is not `path`
   *  (an absolute backgroundImagePath, say). */
  source: string | null;
  url: string;
}

export interface MediaUrls {
  /** Keyed by logical path. */
  media: Record<string, CloudMediaFile>;
  /** `source` reference → logical path. */
  sources: Record<string, string>;
  /** Epoch ms after which the URLs stop working. */
  urlsExpireAt: number;
}

export interface LoadedCloudProject extends MediaUrls {
  projectId: string;
  name: string;
  revision: number;
  documentSha256: string | null;
  /** "owner" saves and adds media; "member" (a team member) saves edits but
   *  cannot add or replace files — those count against the owner's storage. */
  access: "owner" | "member";
  isOwner: boolean;
  orgId: string | null;
  updatedAt: string;
  /** The raw project.json text, byte-for-byte as stored. Null only for a
   *  project whose first save never happened. Parse with core/model. */
  document: string | null;
}

export type SaveResult =
  | { ok: true; revision: number; documentSha256: string; updatedAt: string }
  | {
      ok: false;
      conflict: true;
      /** The revision the cloud is at now — re-base on it to retry. */
      revision: number;
      documentSha256: string | null;
      updatedAt: string;
      /** The cloud's current project.json text (merge against it). */
      document: string | null;
    };

/** Any non-2xx the caller did not ask to handle (conflicts are a SaveResult). */
export class CloudApiError extends Error {
  readonly status: number;
  /** The API's machine-readable code: "storage_limit_reached", "not_owner",
   *  "revision_required", "invalid_document", "id_mismatch", … */
  readonly code: string | undefined;
  readonly body: Record<string, unknown>;

  constructor(status: number, body: Record<string, unknown>) {
    super(typeof body.error === "string" ? body.error : `Cloud request failed (HTTP ${status})`);
    this.name = "CloudApiError";
    this.status = status;
    this.code = typeof body.code === "string" ? body.code : undefined;
    this.body = body;
  }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

interface RequestOptions {
  signal?: AbortSignal;
}

const base = () => `${API_URL}/api/cloud-projects`;

function projectPath(projectId: string): string {
  return `${base()}/${encodeURIComponent(projectId)}`;
}

async function request(url: string, init: RequestInit): Promise<Response> {
  return fetch(url, { ...init, credentials: "include", cache: "no-store" });
}

async function errorBody(res: Response): Promise<Record<string, unknown>> {
  const body = (await res.json().catch(() => null)) as unknown;
  return body && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : {};
}

async function expectOk<T>(res: Response): Promise<T> {
  if (!res.ok) throw new CloudApiError(res.status, await errorBody(res));
  return (await res.json()) as T;
}

function toMediaUrls(files: CloudMediaFile[], urlsExpireAt: string): MediaUrls {
  const media: Record<string, CloudMediaFile> = {};
  const sources: Record<string, string> = {};
  for (const f of files) {
    media[f.path] = f;
    if (f.source) sources[f.source] = f.path;
  }
  return { media, sources, urlsExpireAt: Date.parse(urlsExpireAt) };
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

/** Your cloud projects, newest first — or a team's with `orgId` (members edit; the owner adds media). */
export async function listCloudProjects(opts: RequestOptions & { orgId?: string } = {}): Promise<CloudProjectList> {
  const url = opts.orgId ? `${base()}?orgId=${encodeURIComponent(opts.orgId)}` : base();
  return expectOk<CloudProjectList>(await request(url, { method: "GET", signal: opts.signal }));
}

interface ProjectResponse {
  projectId: string;
  name: string;
  revision: number;
  documentSha256: string | null;
  access: "owner" | "member";
  isOwner: boolean;
  orgId: string | null;
  updatedAt: string;
  document: string | null;
  files: CloudMediaFile[];
  urlsExpireAt: string;
}

/** The project document (raw text), its revision, and every media file's
 *  presigned URL. 404 → CloudApiError (missing, or not yours to read). */
export async function loadCloudProject(projectId: string, opts: RequestOptions = {}): Promise<LoadedCloudProject> {
  const body = await expectOk<ProjectResponse>(
    await request(projectPath(projectId), { method: "GET", signal: opts.signal }),
  );
  return {
    projectId: body.projectId,
    name: body.name,
    revision: body.revision,
    documentSha256: body.documentSha256,
    access: body.access,
    isOwner: body.isOwner,
    orgId: body.orgId,
    updatedAt: body.updatedAt,
    document: body.document,
    ...toMediaUrls(body.files, body.urlsExpireAt),
  };
}

/**
 * Save project.json. `document` must be the lossless serialization from
 * core/model (sent verbatim); `baseRevision` is the revision it was edited
 * from. A 409 is NOT thrown — it comes back as `{ ok: false, conflict }`
 * carrying the cloud's current revision and document, so the caller can
 * merge (or reload) and retry with that revision. Everything else that is
 * not a 2xx throws CloudApiError (403 read-only, 413 quota, 400 invalid…).
 */
export async function saveCloudProject(
  projectId: string,
  document: string,
  baseRevision: number,
  opts: RequestOptions = {},
): Promise<SaveResult> {
  const res = await request(`${projectPath(projectId)}/project`, {
    method: "PUT",
    headers: { "Content-Type": "application/json", "If-Match": `"${baseRevision}"` },
    body: document,
    signal: opts.signal,
  });
  if (res.status === 409) {
    const body = await errorBody(res);
    if (body.code === "revision_conflict") {
      return {
        ok: false,
        conflict: true,
        revision: Number(body.revision),
        documentSha256: typeof body.documentSha256 === "string" ? body.documentSha256 : null,
        updatedAt: String(body.updatedAt ?? ""),
        document: typeof body.document === "string" ? body.document : null,
      };
    }
    throw new CloudApiError(res.status, body);
  }
  const body = await expectOk<{ revision: number; documentSha256: string; updatedAt: string }>(res);
  return { ok: true, revision: body.revision, documentSha256: body.documentSha256, updatedAt: body.updatedAt };
}

/** One file of a stage manifest (PUT /cloud-projects/:id). */
export interface ManifestFile {
  /** Logical path relative to the project folder, e.g. `recording.mov`. */
  path: string;
  sha256: string;
  bytes: number;
  contentType: string;
  /** The reference exactly as project.json spells it, when that is not `path`. */
  source?: string | null;
}

/** A presigned upload slot the API asks for (content-addressed, 15 min). */
export interface UploadTarget {
  sha256: string;
  bytes: number;
  contentType: string;
  paths: string[];
  method: "PUT";
  uploadUrl: string;
  headers: Record<string, string>;
}

export interface StageResult {
  projectId: string;
  /** The cloud document's revision (0 = none yet) — the base for the first save. */
  revision: number;
  documentSha256: string | null;
  missing: UploadTarget[];
  presentCount: number;
  expiresIn: number;
}

/**
 * Stage a project's file manifest (creates the project on first call). The
 * API answers with presigned PUTs for every file it does not hold yet —
 * upload those, then `finalizeCloudProject`. Owner only.
 */
export async function stageCloudProject(
  projectId: string,
  manifest: { name: string; files: ManifestFile[]; orgId?: string | null },
  opts: RequestOptions = {},
): Promise<StageResult> {
  return expectOk<StageResult>(
    await request(projectPath(projectId), {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(manifest),
      signal: opts.signal,
    }),
  );
}

export type FinalizeResult =
  | { committed: true; revision: number; fileCount: number; totalBytes: number }
  | { committed: false; status: "verifying" }
  | { committed: false; status: "missing"; missing: Array<{ sha256: string; paths: string[] }> };

/**
 * Verify the uploaded bytes (size + SHA-256, server side) and commit the
 * staged manifest. `verifying` = the per-request verify budget ran out —
 * call again; `missing` = restage and upload those.
 */
export async function finalizeCloudProject(projectId: string, opts: RequestOptions = {}): Promise<FinalizeResult> {
  const res = await request(`${projectPath(projectId)}/finalize`, { method: "POST", signal: opts.signal });
  if (res.status === 202) return { committed: false, status: "verifying" };
  if (res.status === 409) {
    const body = await errorBody(res);
    if (body.code === "objects_missing" && Array.isArray(body.missing)) {
      return { committed: false, status: "missing", missing: body.missing as Array<{ sha256: string; paths: string[] }> };
    }
    throw new CloudApiError(res.status, body);
  }
  const body = await expectOk<{ revision: number; fileCount: number; totalBytes: number }>(res);
  return { committed: true, revision: body.revision, fileCount: body.fileCount, totalBytes: body.totalBytes };
}

/** Fresh presigned GETs for every media file (the document is not re-sent). */
export async function refreshMediaUrls(projectId: string, opts: RequestOptions = {}): Promise<MediaUrls & { revision: number }> {
  const body = await expectOk<{ revision: number; files: CloudMediaFile[]; urlsExpireAt: string }>(
    await request(`${projectPath(projectId)}/files`, { method: "GET", signal: opts.signal }),
  );
  return { revision: body.revision, ...toMediaUrls(body.files, body.urlsExpireAt) };
}

/** Delete a cloud project and all its stored media (owner only). */
export async function deleteCloudProject(projectId: string, opts: RequestOptions = {}): Promise<void> {
  await expectOk(await request(projectPath(projectId), { method: "DELETE", signal: opts.signal }));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Refresh margin: presigned GETs live ~15 min; refresh when <2 min remain so
 *  a decoder mid-seek never holds a dead URL. */
export const MEDIA_URL_REFRESH_MARGIN_MS = 120_000;

export function mediaUrlsNeedRefresh(
  urls: Pick<MediaUrls, "urlsExpireAt">,
  now: number = Date.now(),
  marginMs: number = MEDIA_URL_REFRESH_MARGIN_MS,
): boolean {
  return !Number.isFinite(urls.urlsExpireAt) || urls.urlsExpireAt - now <= marginMs;
}

/**
 * Resolve a reference as project.json spells it — a `file://` URL
 * (videoURL/cursorDataURL/keystrokeDataURL/cameraVideoURL), an absolute path
 * (backgroundImagePath), or a bare file name relative to the project folder
 * (voice-over `fileName`, watermark/curtain logo names) — to its media file.
 *
 * Order: the exact `source` the Mac recorded → the logical path itself → the
 * project-relative tail of a Mac path (`…/Projects/<id>/<name>`) → the last
 * path component. Never guesses beyond that; undefined means not uploaded.
 */
export function resolveMediaRef(urls: Pick<MediaUrls, "media" | "sources">, ref: string | null | undefined): CloudMediaFile | undefined {
  if (!ref) return undefined;
  const bySource = urls.sources[ref];
  if (bySource) return urls.media[bySource];
  if (urls.media[ref]) return urls.media[ref];

  let path = ref;
  if (path.startsWith("file://")) {
    try {
      path = decodeURIComponent(new URL(path).pathname);
    } catch {
      return undefined;
    }
  }
  const decodedSource = urls.sources[path];
  if (decodedSource) return urls.media[decodedSource];

  const marker = "/CaptureCat/Projects/";
  const at = path.indexOf(marker);
  if (at >= 0) {
    // …/Projects/<UUID>/<relative path>
    const rest = path.slice(at + marker.length).split("/").slice(1).join("/");
    // `sources` first: an image the Mac CONVERTED for browsers (HEIC → PNG)
    // uploads as `<name>.png` and records its original relative path there.
    const restViaSource = rest ? urls.sources[rest] : undefined;
    if (restViaSource) return urls.media[restViaSource];
    if (rest && urls.media[rest]) return urls.media[rest];
  }
  const last = path.split("/").pop();
  if (!last) return undefined;
  const lastViaSource = urls.sources[last];
  return lastViaSource ? urls.media[lastViaSource] : urls.media[last];
}
