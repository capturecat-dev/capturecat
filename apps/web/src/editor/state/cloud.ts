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
 * Project history (docs/project-history.md §6): `historyHeaders` / the
 * `history` option of saveCloudProject (X-CC-Client/-Client-Id/-Source/
 * -Change/-Checkpoint/-Merged-From), `webClientId()`, and the version routes
 * — getCloudHead, listProjectVersions, getProjectVersion, getRevisionDocument,
 * nameProjectVersion, restoreProjectVersion, deleteProjectVersion.
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
  | { ok: true; revision: number; documentSha256: string; updatedAt: string; version?: SavedVersionRef | null }
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
  opts: RequestOptions & { history?: SaveHistoryMeta } = {},
): Promise<SaveResult> {
  const res = await request(`${projectPath(projectId)}/project`, {
    method: "PUT",
    headers: { "Content-Type": "application/json", "If-Match": `"${baseRevision}"`, ...historyHeaders(opts.history) },
    body: document,
    signal: opts.signal,
  });
  if (res.status === 409) {
    const body = await errorBody(res);
    const conflict = revisionConflict(body);
    if (conflict) return conflict;
    throw new CloudApiError(res.status, body);
  }
  const body = await expectOk<{ revision: number; documentSha256: string; updatedAt: string; version?: unknown }>(res);
  return {
    ok: true,
    revision: body.revision,
    documentSha256: body.documentSha256,
    updatedAt: body.updatedAt,
    version: savedVersionRef(body.version) ?? undefined,
  };
}

type ConflictResult = Extract<SaveResult, { ok: false }>;

/** A 409 `revision_conflict` body → the conflict result (null for any other 409). */
function revisionConflict(body: Record<string, unknown>): ConflictResult | null {
  if (body.code !== "revision_conflict") return null;
  return {
    ok: false,
    conflict: true,
    revision: Number(body.revision),
    documentSha256: typeof body.documentSha256 === "string" ? body.documentSha256 : null,
    updatedAt: String(body.updatedAt ?? ""),
    document: typeof body.document === "string" ? body.document : null,
  };
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
// Project history (docs/project-history.md §6 — the wire contract)
// ---------------------------------------------------------------------------

export type HistoryClientKind = "mac" | "web" | "unknown";
export type HistorySource = "human" | "agent" | "mixed";
export type HistoryCheckpoint = "merge" | "restore" | "push" | "upload" | "named";
export type VersionKind = "upload" | "edit" | "merge" | "restore";

/** The optional `X-CC-*` headers of `PUT …/project` (old clients send none). */
export interface SaveHistoryMeta {
  /** `X-CC-Client` — this client is always `web`. */
  client?: "web";
  /** `X-CC-Client-Id` — the per-browser id (`webClientId()`), the coalescing key. */
  clientId?: string;
  /** `X-CC-Source` — from the undo entries' `source` since the last save. */
  source?: HistorySource;
  /** `X-CC-Change` — `encodeChangeHeader(diff(base, new))`; null = no header (over budget). */
  change?: string | null;
  /** `X-CC-Checkpoint` — force a NEW version (merge / restore / …). */
  checkpoint?: HistoryCheckpoint;
  /** `X-CC-Merged-From` — the server revision (theirs) this save merged. */
  mergedFrom?: number;
}

const CLIENT_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const CHANGE_HEADER_LIMIT = 8192;

/** `SaveHistoryMeta` → request headers; malformed values are dropped (the save still goes). */
export function historyHeaders(meta: SaveHistoryMeta | undefined): Record<string, string> {
  if (!meta) return {};
  const h: Record<string, string> = {};
  if (meta.client) h["X-CC-Client"] = meta.client;
  if (meta.clientId && CLIENT_ID_RE.test(meta.clientId)) h["X-CC-Client-Id"] = meta.clientId;
  if (meta.source) h["X-CC-Source"] = meta.source;
  if (meta.change && meta.change.length <= CHANGE_HEADER_LIMIT) h["X-CC-Change"] = meta.change;
  if (meta.checkpoint) h["X-CC-Checkpoint"] = meta.checkpoint;
  if (meta.mergedFrom != null && Number.isSafeInteger(meta.mergedFrom) && meta.mergedFrom >= 0) {
    h["X-CC-Merged-From"] = String(meta.mergedFrom);
  }
  return h;
}

const CLIENT_ID_KEY = "cc.editor.historyClientId";
let sessionClientId: string | null = null;

function randomId(): string {
  const c = (globalThis as { crypto?: Crypto }).crypto;
  if (c?.randomUUID) return c.randomUUID();
  const bytes = new Uint8Array(16);
  if (c?.getRandomValues) c.getRandomValues(bytes);
  else for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * This browser's history client id: a random UUID kept in localStorage —
 * opaque on purpose (no device or person name in it). Private windows and
 * blocked storage get one per page session.
 */
export function webClientId(storage: Pick<Storage, "getItem" | "setItem"> | null = defaultStorage()): string {
  try {
    const stored = storage?.getItem(CLIENT_ID_KEY);
    if (stored && CLIENT_ID_RE.test(stored)) return stored;
    const fresh = randomId();
    storage?.setItem(CLIENT_ID_KEY, fresh);
    if (storage?.getItem(CLIENT_ID_KEY) === fresh) return fresh;
  } catch {
    // storage blocked — fall through to the session id
  }
  sessionClientId ??= randomId();
  return sessionClientId;
}

function defaultStorage(): Storage | null {
  try {
    return typeof window !== "undefined" ? window.localStorage : null;
  } catch {
    return null;
  }
}

/** What a save's response says about the version it landed in. */
export interface SavedVersionRef {
  id: string;
  seq: number;
  /** True when the save EXTENDED the head version (coalesced). */
  extended: boolean;
}

function savedVersionRef(v: unknown): SavedVersionRef | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  if (typeof o.id !== "string") return null;
  return { id: o.id, seq: Number(o.seq) || 0, extended: o.extended === true };
}

/** One retained version (a row of `GET …/versions`). */
export interface ProjectVersion {
  id: string;
  seq: number;
  /** The revision this version's document is at (its head). */
  revision: number;
  firstRevision: number;
  kind: VersionKind;
  /** The user's name for it; null = unnamed (pruned by the retention window). */
  label: string | null;
  namedBy: string | null;
  namedAt: string | null;
  actorUid: string | null;
  /** The actor's display name (the API joins it); null when unknown. */
  actorName: string | null;
  clientKind: HistoryClientKind;
  source: HistorySource;
  /** The change-set JSON (`change_json`), or null when the save sent none. */
  change: unknown;
  restoredFrom: string | null;
  mergedFromRevision: number | null;
  openedAt: string;
  updatedAt: string;
  docBytes: number | null;
}

/** The owner plan's history allowance (null fields = unknown). */
export interface HistoryRetention {
  /** Days unnamed versions are kept; 0 = no cloud history (Free). */
  days: number;
  /** Named versions the plan allows. */
  maxNamed: number;
  /** Named versions the project holds now, when the API says. */
  namedCount: number | null;
}

export interface VersionList {
  versions: ProjectVersion[];
  headVersionId: string | null;
  retention: HistoryRetention | null;
  /** Bytes of media only old versions still reference ("History keeps X…"). */
  pinnedMediaBytes: number;
  /** Cursor for the next page (`before=`), null at the end. */
  nextBefore: string | null;
}

export interface VersionDetail extends MediaUrls {
  version: ProjectVersion;
  /** The version's project.json text, byte-for-byte. */
  document: string;
}

export interface CloudHead {
  revision: number;
  docSha256: string | null;
  updatedAt: string;
  updatedBy: string | null;
  headVersionId: string | null;
}

const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v)) ? Number(v) : null);
const pick = (o: Record<string, unknown>, ...keys: string[]): unknown => {
  for (const k of keys) if (o[k] !== undefined) return o[k];
  return undefined;
};

/** Tolerant decode of one version row (camelCase, with the D1 snake_case names accepted). */
export function decodeVersion(v: unknown): ProjectVersion | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const id = str(o.id);
  if (!id) return null;
  const actor = (o.actor && typeof o.actor === "object" ? o.actor : {}) as Record<string, unknown>;
  const kind = str(o.kind);
  const client = str(pick(o, "clientKind", "client_kind", "client"));
  const source = str(o.source);
  let change: unknown = pick(o, "change", "changeJson", "change_json") ?? null;
  if (typeof change === "string") {
    try {
      change = JSON.parse(change) as unknown;
    } catch {
      change = null;
    }
  }
  const revision = num(o.revision) ?? 0;
  return {
    id,
    seq: num(o.seq) ?? 0,
    revision,
    firstRevision: num(pick(o, "firstRevision", "first_revision")) ?? revision,
    kind: kind === "upload" || kind === "merge" || kind === "restore" ? kind : "edit",
    label: str(o.label),
    namedBy: str(pick(o, "namedBy", "named_by")),
    namedAt: str(pick(o, "namedAt", "named_at")),
    actorUid: str(pick(o, "actorUid", "actor_uid")) ?? str(actor.uid),
    actorName: str(pick(o, "actorName", "actor_name")) ?? str(actor.name) ?? str(actor.displayName),
    clientKind: client === "mac" || client === "web" ? client : "unknown",
    source: source === "agent" || source === "mixed" ? source : "human",
    change,
    restoredFrom: str(pick(o, "restoredFrom", "restored_from")),
    mergedFromRevision: num(pick(o, "mergedFromRevision", "merged_from_revision")),
    openedAt: str(pick(o, "openedAt", "opened_at")) ?? str(pick(o, "updatedAt", "updated_at")) ?? "",
    updatedAt: str(pick(o, "updatedAt", "updated_at")) ?? "",
    docBytes: num(pick(o, "docBytes", "doc_bytes")),
  };
}

function decodeRetention(v: unknown): HistoryRetention | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const days = num(pick(o, "days", "historyDays", "maxHistoryDays"));
  const maxNamed = num(pick(o, "maxNamed", "namedVersions", "maxNamedVersions"));
  if (days == null && maxNamed == null) return null;
  return { days: days ?? 0, maxNamed: maxNamed ?? 0, namedCount: num(pick(o, "namedCount", "named")) };
}

function versionsPath(projectId: string, versionId?: string): string {
  return `${projectPath(projectId)}/versions${versionId ? `/${encodeURIComponent(versionId)}` : ""}`;
}

/** `GET …/:id/head` — the cheap poll: revision, sha, who saved last, head version. */
export async function getCloudHead(projectId: string, opts: RequestOptions = {}): Promise<CloudHead> {
  const b = await expectOk<Record<string, unknown>>(await request(`${projectPath(projectId)}/head`, { method: "GET", signal: opts.signal }));
  return {
    revision: num(b.revision) ?? 0,
    docSha256: str(pick(b, "docSha", "docSha256", "documentSha256")),
    updatedAt: str(b.updatedAt) ?? "",
    updatedBy: str(b.updatedBy),
    headVersionId: str(b.headVersionId),
  };
}

/** `GET …/:id/versions?before=&limit=` — newest first, with retention + pinned media bytes. */
export async function listProjectVersions(
  projectId: string,
  opts: RequestOptions & { before?: string | null; limit?: number } = {},
): Promise<VersionList> {
  const q = new URLSearchParams();
  if (opts.before) q.set("before", opts.before);
  q.set("limit", String(opts.limit ?? 50));
  const b = await expectOk<Record<string, unknown>>(
    await request(`${versionsPath(projectId)}?${q.toString()}`, { method: "GET", signal: opts.signal }),
  );
  const versions = (Array.isArray(b.versions) ? b.versions : []).map(decodeVersion).filter((v): v is ProjectVersion => v != null);
  const nextRaw = pick(b, "nextBefore", "before", "cursor");
  return {
    versions,
    headVersionId: str(b.headVersionId),
    retention: decodeRetention(b.retention),
    pinnedMediaBytes: num(b.pinnedMediaBytes) ?? 0,
    nextBefore: typeof nextRaw === "number" ? String(nextRaw) : str(nextRaw),
  };
}

/** `GET …/:id/versions/:vid` — the version's document + presigned GETs for its manifest. */
export async function getProjectVersion(projectId: string, versionId: string, opts: RequestOptions = {}): Promise<VersionDetail> {
  const b = await expectOk<Record<string, unknown>>(
    await request(versionsPath(projectId, versionId), { method: "GET", signal: opts.signal }),
  );
  const version = decodeVersion(b.version) ?? decodeVersion({ ...b, id: versionId });
  if (!version || typeof b.document !== "string") throw new CloudApiError(500, { error: "The version could not be read." });
  const files = Array.isArray(b.files) ? (b.files as CloudMediaFile[]) : [];
  return { version, document: b.document, ...toMediaUrls(files, String(b.urlsExpireAt ?? "")) };
}

/** `GET …/:id/revisions/:rev/document` — retained only when some version's head is that revision. */
export async function getRevisionDocument(projectId: string, revision: number, opts: RequestOptions = {}): Promise<string> {
  const res = await request(`${projectPath(projectId)}/revisions/${revision}/document`, { method: "GET", signal: opts.signal });
  if (!res.ok) throw new CloudApiError(res.status, await errorBody(res));
  const text = await res.text();
  // Either the raw project.json, or `{ document: "<text>" }`.
  try {
    const parsed = JSON.parse(text) as Record<string, unknown>;
    if (parsed && typeof parsed === "object" && typeof parsed.document === "string" && !("id" in parsed)) return parsed.document;
  } catch {
    // not JSON — return as-is (the API validates documents on save)
  }
  return text;
}

/** `PATCH …/versions/:vid {label}` — name (or, with null, unname) a version. */
export async function nameProjectVersion(
  projectId: string,
  versionId: string,
  label: string | null,
  opts: RequestOptions = {},
): Promise<ProjectVersion | null> {
  const b = await expectOk<Record<string, unknown>>(
    await request(versionsPath(projectId, versionId), {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ label }),
      signal: opts.signal,
    }),
  );
  return decodeVersion(b.version ?? b);
}

export type RestoreResult =
  | { ok: true; revision: number; documentSha256: string | null; updatedAt: string; document: string | null; version: SavedVersionRef | null }
  | ConflictResult;

/**
 * `POST …/versions/:vid/restore` with `If-Match: <current revision>`. The
 * server saves the old document as a new revision + `restore` version (no new
 * bytes, so members may restore). A 409 comes back as a conflict with the head.
 */
export async function restoreProjectVersion(
  projectId: string,
  versionId: string,
  baseRevision: number,
  opts: RequestOptions = {},
): Promise<RestoreResult> {
  const res = await request(`${versionsPath(projectId, versionId)}/restore`, {
    method: "POST",
    headers: { "If-Match": `"${baseRevision}"` },
    signal: opts.signal,
  });
  if (res.status === 409) {
    const body = await errorBody(res);
    const conflict = revisionConflict(body);
    if (conflict) return conflict;
    throw new CloudApiError(res.status, body);
  }
  const b = await expectOk<Record<string, unknown>>(res);
  return {
    ok: true,
    revision: num(b.revision) ?? 0,
    documentSha256: str(b.documentSha256),
    updatedAt: str(b.updatedAt) ?? "",
    document: typeof b.document === "string" ? b.document : null,
    version: savedVersionRef(b.version),
  };
}

/** `DELETE …/versions/:vid` — owner only; never the head. Releases media only it pinned. */
export async function deleteProjectVersion(projectId: string, versionId: string, opts: RequestOptions = {}): Promise<void> {
  await expectOk(await request(versionsPath(projectId, versionId), { method: "DELETE", signal: opts.signal }));
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
