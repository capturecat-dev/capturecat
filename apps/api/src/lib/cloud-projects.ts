/**
 * Cloud projects (web editor) — the rules, as pure functions.
 *
 * A cloud project is a Mac project bundle mirrored to R2 so the web editor at
 * app.capturecat.so/editor can open it: project.json plus the media it
 * references (recording, cursor/keystroke JSON, camera, voice-overs, images).
 *
 *   PUT  /cloud-projects/:id            stage a manifest → presigned PUTs for
 *                                       the objects the cloud does not have
 *   POST /cloud-projects/:id/finalize   verify (size + SHA-256) and commit
 *   GET  /cloud-projects/:id            project.json + presigned GETs
 *   PUT  /cloud-projects/:id/project    save project.json (If-Match revision)
 *
 * Everything here is pure (no D1, no R2, no Hono) so the path, content-type,
 * size and document rules are unit-testable and are the ONE definition the
 * routes enforce. The Mac client mirrors the path/type table in
 * CloudProjectSync.swift (`CloudPath`); a mismatch there only costs a 400.
 */

import { z } from "zod";
import { MAX_SIGNABLE_UPLOAD_BYTES } from "./upload-schemas";

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

/** Presigned PUT lifetime. The signature is checked when the PUT STARTS, so a
 *  slow upload is unaffected; the Mac re-stages to get fresh URLs if a later
 *  file in a long queue finds its URL expired. Same window as share uploads. */
export const PUT_URL_TTL_SECONDS = 900;
/** Presigned GET lifetime for editor media. Short: the web refreshes through
 *  GET /cloud-projects/:id/files before `urlsExpireAt`. */
export const GET_URL_TTL_SECONDS = 900;
/** Hard cap on one project.json. Real documents are tens to hundreds of KB;
 *  a one-hour take with word-timed subtitles stays well under 4 MB. */
export const MAX_DOCUMENT_BYTES = 16 * 1024 * 1024;
/** Files per manifest (recording + JSON sidecars + voice-overs + images; a
 *  real project has ~10). Bounded well inside D1's per-invocation query
 *  budget: stage writes one row per new object and finalize one insert per
 *  file, plus a verify/accept per object, in a single request. */
export const MAX_MANIFEST_FILES = 200;
/** Presigned-but-unverified objects per user, across all projects. Each is a
 *  liability until /finalize (the bytes may already be in R2, invisible to
 *  the quota); the hourly sweep deletes strays after 2 h. */
export const MAX_PENDING_OBJECTS = 200;
/** Bytes /finalize will stream through SHA-256 in one request before it
 *  answers 202 and asks the client to call again. Keeps one request's wall
 *  time bounded on multi-GB projects. */
export const FINALIZE_VERIFY_BUDGET_BYTES = 4 * 1024 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Project ids
// ---------------------------------------------------------------------------

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The Mac project UUID in its canonical (Swift `uuidString`, uppercase)
 *  form, or null. Lower-case input from a URL resolves to the same project. */
export function normalizeProjectId(raw: string | undefined | null): string | null {
  if (!raw || !UUID_RE.test(raw)) return null;
  return raw.toUpperCase();
}

// ---------------------------------------------------------------------------
// Logical paths + content types
// ---------------------------------------------------------------------------

export type CloudFileKind = "video" | "audio" | "image" | "data";

/**
 * Extension → accepted content types. Anything not listed is refused — no
 * SVG/HTML (served from a presigned URL they would be a script vector), no
 * archives, no executables. The FIRST type is the canonical one.
 */
export const CLOUD_FILE_TYPES: Record<string, { kind: CloudFileKind; types: readonly string[] }> = {
  mov: { kind: "video", types: ["video/quicktime"] },
  mp4: { kind: "video", types: ["video/mp4"] },
  m4v: { kind: "video", types: ["video/mp4", "video/x-m4v"] },
  m4a: { kind: "audio", types: ["audio/mp4", "audio/x-m4a"] },
  aac: { kind: "audio", types: ["audio/aac"] },
  mp3: { kind: "audio", types: ["audio/mpeg"] },
  wav: { kind: "audio", types: ["audio/wav", "audio/x-wav"] },
  caf: { kind: "audio", types: ["audio/x-caf"] },
  png: { kind: "image", types: ["image/png"] },
  jpg: { kind: "image", types: ["image/jpeg"] },
  jpeg: { kind: "image", types: ["image/jpeg"] },
  heic: { kind: "image", types: ["image/heic"] },
  webp: { kind: "image", types: ["image/webp"] },
  gif: { kind: "image", types: ["image/gif"] },
  json: { kind: "data", types: ["application/json"] },
};

/**
 * Per-KIND ceiling, independent of the plan. The plan's `maxFileSizeBytes`
 * and storage cap still apply on top (via checkUploadAllowance); these only
 * stop a JSON sidecar or a wallpaper from being signed for gigabytes.
 */
export const KIND_MAX_BYTES: Record<CloudFileKind, number> = {
  video: MAX_SIGNABLE_UPLOAD_BYTES,
  audio: 1024 * 1024 * 1024,
  image: 64 * 1024 * 1024,
  data: 512 * 1024 * 1024,
};

const SEGMENT_RE = /^[A-Za-z0-9][A-Za-z0-9 ._()+@,-]{0,127}$/;

/**
 * A logical path is relative to the Mac project folder: `recording.mov`,
 * `cursor.json`, `voiceover-<uuid>.m4a`, `external/<sha12>.jpg` for a file
 * the project references from outside its folder. Refused: absolute paths,
 * `..`/`.` and hidden segments (every segment must START alphanumeric),
 * backslashes, more than 4 levels, unknown extensions, and project.json
 * itself (the document has its own endpoint and revision).
 */
export function checkLogicalPath(path: string): { ok: true; ext: string } | { ok: false; error: string } {
  if (typeof path !== "string" || path.length === 0 || path.length > 255) {
    return { ok: false, error: "path must be 1–255 characters" };
  }
  const segments = path.split("/");
  if (segments.length > 4) return { ok: false, error: "path is nested too deeply" };
  for (const segment of segments) {
    if (!SEGMENT_RE.test(segment)) return { ok: false, error: `invalid path segment "${segment}"` };
  }
  if (path.toLowerCase() === "project.json") {
    return { ok: false, error: "project.json is saved through /project, not as a file" };
  }
  const last = segments[segments.length - 1];
  const dot = last.lastIndexOf(".");
  const ext = dot > 0 ? last.slice(dot + 1).toLowerCase() : "";
  if (!(ext in CLOUD_FILE_TYPES)) return { ok: false, error: `file type ".${ext}" is not allowed` };
  return { ok: true, ext };
}

// ---------------------------------------------------------------------------
// Manifest (body of PUT /cloud-projects/:id)
// ---------------------------------------------------------------------------

const ManifestFileSchema = z.object({
  path: z.string(),
  sha256: z
    .string()
    .regex(/^[0-9a-fA-F]{64}$/, "must be a hex SHA-256")
    .transform((s) => s.toLowerCase()),
  bytes: z.int().min(0).max(MAX_SIGNABLE_UPLOAD_BYTES),
  contentType: z.string().transform((s) => s.split(";")[0].trim().toLowerCase()),
  // The reference exactly as project.json spells it, when that is not the
  // path itself (an absolute backgroundImagePath, a file:// URL…). Lets the
  // web resolve any reference without guessing. Control characters refused.
  source: z
    .string()
    .max(2048)
    .regex(/^[^\u0000-\u001f\u007f]*$/, "must not contain control characters")
    .nullish()
    .transform((s) => (s && s.length > 0 ? s : null)),
});
export type ManifestFile = z.output<typeof ManifestFileSchema>;

export const ManifestBodySchema = z.object({
  name: z
    .string()
    .transform((s) => s.trim().slice(0, 200))
    .transform((s) => (s.length > 0 ? s : "Untitled")),
  /** undefined = keep the project's current org; null = personal. */
  orgId: z.string().min(1).max(128).nullish(),
  files: z.array(ManifestFileSchema).max(MAX_MANIFEST_FILES),
});
export type ManifestBody = z.output<typeof ManifestBodySchema>;

export type ManifestProblem = { status: 400 | 413; body: { error: string; code: string; path?: string } };

/**
 * Semantic checks zod cannot express: path rules, per-extension content
 * types, per-kind size ceilings, unique paths (case-insensitively — the Mac
 * volume is case-insensitive, so `Recording.mov` and `recording.mov` are the
 * same file there).
 */
export function checkManifest(body: ManifestBody): ManifestProblem | null {
  const seen = new Set<string>();
  for (const file of body.files) {
    const path = checkLogicalPath(file.path);
    if (!path.ok) {
      return { status: 400, body: { error: `${file.path}: ${path.error}`, code: "invalid_path", path: file.path } };
    }
    const lower = file.path.toLowerCase();
    if (seen.has(lower)) {
      return { status: 400, body: { error: `${file.path}: listed twice`, code: "duplicate_path", path: file.path } };
    }
    seen.add(lower);
    const spec = CLOUD_FILE_TYPES[path.ext];
    if (!spec.types.includes(file.contentType)) {
      return {
        status: 400,
        body: {
          error: `${file.path}: content type must be ${spec.types.join(" or ")}`,
          code: "invalid_content_type",
          path: file.path,
        },
      };
    }
    if (file.bytes > KIND_MAX_BYTES[spec.kind]) {
      return {
        status: 413,
        body: { error: `${file.path}: file is too large`, code: "file_too_large", path: file.path },
      };
    }
  }
  return null;
}

/** One entry per distinct SHA-256 (the storage unit), with every path that
 *  points at it. The object's content type is its first path's type. */
export function distinctObjects(files: readonly ManifestFile[]): Array<{
  sha256: string;
  bytes: number;
  contentType: string;
  paths: string[];
}> {
  const bySha = new Map<string, { sha256: string; bytes: number; contentType: string; paths: string[] }>();
  for (const f of files) {
    const hit = bySha.get(f.sha256);
    if (hit) hit.paths.push(f.path);
    else bySha.set(f.sha256, { sha256: f.sha256, bytes: f.bytes, contentType: f.contentType, paths: [f.path] });
  }
  return [...bySha.values()];
}

/** Two manifest entries claiming the same SHA-256 with different sizes are a
 *  lying (or broken) client: identical bytes have one length. */
export function inconsistentSizes(files: readonly ManifestFile[]): string | null {
  const sizes = new Map<string, number>();
  for (const f of files) {
    const known = sizes.get(f.sha256);
    if (known !== undefined && known !== f.bytes) return f.path;
    sizes.set(f.sha256, f.bytes);
  }
  return null;
}

// ---------------------------------------------------------------------------
// R2 keys
// ---------------------------------------------------------------------------

/** Media: content-addressed per owner + project, so an unchanged recording is
 *  never re-uploaded and an object can never be reached from another
 *  account's project. */
export function objectKey(ownerUid: string, projectId: string, sha256: string): string {
  return `cloud-projects/${ownerUid}/${projectId}/objects/${sha256}`;
}

/**
 * project.json: one object per save ATTEMPT (write new, then CAS the row).
 * The nonce matters: two saves racing from the same base revision both aim
 * at revision N+1, and with a key of just `N+1` the loser's PUT could land
 * after the winner's and silently replace the bytes the winning row points
 * at. With a per-attempt key the loser only ever orphans its own object.
 */
export function documentKey(ownerUid: string, projectId: string, revision: number, nonce: string): string {
  return `cloud-projects/${ownerUid}/${projectId}/doc/${revision}-${nonce}.json`;
}

// ---------------------------------------------------------------------------
// Optimistic concurrency
// ---------------------------------------------------------------------------

/** `If-Match: "12"`, `12` or `W/"12"` → 12. Anything else (missing, `*`,
 *  junk) → null: a save must name the revision it was based on. */
export function parseIfMatchRevision(header: string | undefined | null): number | null {
  if (!header) return null;
  const m = /^\s*(?:W\/)?"?(\d{1,12})"?\s*$/.exec(header);
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isSafeInteger(n) ? n : null;
}

// ---------------------------------------------------------------------------
// project.json
// ---------------------------------------------------------------------------

export type DocumentCheck =
  | { ok: true; name: string }
  | { ok: false; status: 400 | 413; body: { error: string; code: string } };

/**
 * Structural check of a project.json before it replaces the cloud copy. The
 * document is stored VERBATIM (byte-for-byte what the client sent — keys the
 * server does not know survive untouched); this only refuses documents the
 * Mac could not decode, so a bad web save can never brick the project on
 * the Mac. The required keys are exactly the ones Project.init(from:) reads
 * with `decode` (not `decodeIfPresent`): id, name, createdAt, settings,
 * zoomRegions, duration.
 */
export function checkProjectDocument(text: string, byteLength: number, expectedId: string): DocumentCheck {
  if (byteLength > MAX_DOCUMENT_BYTES) {
    return { ok: false, status: 413, body: { error: "project.json is too large", code: "document_too_large" } };
  }
  let doc: unknown;
  try {
    doc = JSON.parse(text);
  } catch {
    return { ok: false, status: 400, body: { error: "project.json is not valid JSON", code: "invalid_document" } };
  }
  if (typeof doc !== "object" || doc === null || Array.isArray(doc)) {
    return { ok: false, status: 400, body: { error: "project.json must be an object", code: "invalid_document" } };
  }
  const d = doc as Record<string, unknown>;
  if (normalizeProjectId(typeof d.id === "string" ? d.id : null) !== expectedId) {
    return {
      ok: false,
      status: 400,
      body: { error: "project.json id does not match this project", code: "id_mismatch" },
    };
  }
  const missing: string[] = [];
  if (typeof d.name !== "string") missing.push("name");
  if (typeof d.createdAt !== "number") missing.push("createdAt");
  if (typeof d.duration !== "number") missing.push("duration");
  if (typeof d.settings !== "object" || d.settings === null || Array.isArray(d.settings)) missing.push("settings");
  if (!Array.isArray(d.zoomRegions)) missing.push("zoomRegions");
  if (missing.length > 0) {
    return {
      ok: false,
      status: 400,
      body: { error: `project.json is missing required keys: ${missing.join(", ")}`, code: "invalid_document" },
    };
  }
  const name = (d.name as string).trim().slice(0, 200);
  return { ok: true, name: name.length > 0 ? name : "Untitled" };
}

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------

export function toHex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(data: string | ArrayBuffer | Uint8Array): Promise<string> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return toHex(await crypto.subtle.digest("SHA-256", bytes));
}

/**
 * SHA-256 of a stream without buffering it. Workers have
 * `crypto.DigestStream` (incremental, native); the Node test pool does not,
 * and falls back to buffering — fine for test-sized bodies, and unreachable
 * in production.
 */
export async function sha256OfStream(body: ReadableStream<Uint8Array>): Promise<string> {
  const Digest = (crypto as unknown as { DigestStream?: typeof DigestStream }).DigestStream;
  if (typeof Digest === "function") {
    const digest = new Digest("SHA-256");
    await body.pipeTo(digest);
    return toHex(await digest.digest);
  }
  return toHex(await crypto.subtle.digest("SHA-256", await new Response(body).arrayBuffer()));
}
