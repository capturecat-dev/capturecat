/**
 * Share links — the web editor's client for the API's share-upload routes
 * (apps/api/src/routes/upload.ts + routes/jobs.ts; bodies validated by
 * apps/api/src/lib/upload-schemas.ts). A 1:1 port of the Mac's
 * `ShareUploadAPI` network steps and `ShareJobCenter.runUpload` sequence
 * (apps/macos/CaptureCat/Services/ShareJobCenter.swift):
 *
 *   replace?  POST /api/upload/video/:id/replace          → { version, uploadUrl }
 *             (a project shared before keeps its link; any failure → fresh)
 *   presign   POST /api/upload/video                      → { videoId, uploadUrl }
 *   mirror    POST /api/upload/jobs                       → { job: { jobId } }   (non-fatal)
 *   upload    PUT  <uploadUrl>  (XHR, progress; Content-Type video/mp4)
 *             POST /api/upload/jobs/:id/progress  ≤ every 2 s or 5 %          (non-fatal)
 *   complete  POST /api/upload/jobs/:id/progress {progress: 1, completing}     (non-fatal)
 *   confirm   POST /api/upload/video/:id/complete         → { url }
 *             or …/replace/:version/complete {annotations, transcript} → { url }
 *   done      POST /api/upload/jobs/:id/complete {shareUrl}                   (non-fatal)
 *   failure   POST /api/upload/jobs/:id/fail {error}                           (non-fatal)
 *
 * Auth is the web session cookie (`credentials: "include"`), exactly like
 * state/cloud.ts — the API accepts cookie auth for the web origins (CSRF
 * gate: Origin must be a web origin). The Mac's bearer token, X-App-Token
 * client marker and App Attest headers are desktop-only; App Attest runs in
 * report mode, so a web request without them is accepted (an `enforce` mode
 * would need a web exemption server-side).
 *
 * Pure fetch/XHR + types: no React.
 */
import { API_URL } from "@/lib/api-url";

import type { ShareMarker } from "../core/export/shareMarkers";
import type { Project } from "../core/model";
import { transcriptPayload } from "../webmcp/ops/describe";

// ---------------------------------------------------------------------------
// Wire types (apps/api/src/lib/upload-schemas.ts)
// ---------------------------------------------------------------------------

export interface TranscriptWord {
  start: number;
  end: number;
  text: string;
}
export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
  words?: TranscriptWord[];
}

/** `POST /upload/video` body (UploadVideoBodySchema). */
export interface UploadVideoBody {
  fileName: string;
  contentType: "video/mp4";
  fileSizeBytes: number;
  durationSeconds: number;
  commentsEnabled?: true;
  annotations?: ShareMarker[];
  projectId?: string;
  transcript?: TranscriptSegment[];
}

/** Any non-2xx from the share API. */
export class ShareApiError extends Error {
  readonly status: number;
  readonly body: Record<string, unknown>;
  constructor(status: number, body: Record<string, unknown>, fallback: string) {
    super(
      status === 401
        ? "You must be signed in to share videos."
        : typeof body.error === "string"
          ? body.error
          : fallback,
    );
    this.name = "ShareApiError";
    this.status = status;
    this.body = body;
  }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

interface RequestOptions {
  signal?: AbortSignal;
  /** Injectable for tests (defaults to the global fetch). */
  fetch?: typeof fetch;
}

async function post(path: string, body: unknown, opts: RequestOptions, fallback: string): Promise<Record<string, unknown>> {
  const f = opts.fetch ?? fetch;
  const res = await f(`${API_URL}/api${path}`, {
    method: "POST",
    credentials: "include",
    cache: "no-store",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: opts.signal,
  });
  const json = (await res.json().catch(() => null)) as unknown;
  const obj = json && typeof json === "object" && !Array.isArray(json) ? (json as Record<string, unknown>) : {};
  // The Mac requires exactly 200 on the upload routes (`statusCode == 200`).
  if (res.status !== 200) throw new ShareApiError(res.status, obj, `${fallback} (HTTP ${res.status})`);
  return obj;
}

const invalid = () => new ShareApiError(0, {}, "Received an invalid response from the server.");

// ---------------------------------------------------------------------------
// ShareUploadAPI
// ---------------------------------------------------------------------------

/** `requestUploadURL` — presign a first upload (creates the pending share). */
export async function requestUploadURL(
  req: {
    fileName: string;
    fileSizeBytes: number;
    durationSeconds: number;
    commentsEnabled: boolean;
    annotations: ShareMarker[];
    projectId: string | null;
    transcript: TranscriptSegment[];
  },
  opts: RequestOptions = {},
): Promise<{ videoId: string; uploadUrl: string }> {
  const body: UploadVideoBody = {
    fileName: req.fileName,
    contentType: "video/mp4",
    fileSizeBytes: req.fileSizeBytes,
    durationSeconds: req.durationSeconds,
  };
  if (req.commentsEnabled) body.commentsEnabled = true;
  if (req.annotations.length > 0) body.annotations = req.annotations;
  // Lets the dashboard deep-link back to this project.
  if (req.projectId) body.projectId = req.projectId;
  if (req.transcript.length > 0) body.transcript = req.transcript;
  const json = await post("/upload/video", body, opts, "Could not start the upload");
  if (typeof json.videoId !== "string" || typeof json.uploadUrl !== "string") throw invalid();
  return { videoId: json.videoId, uploadUrl: json.uploadUrl };
}

/** `requestReplaceUploadURL` — presign a NEW version of an already-shared video (same link). */
export async function requestReplaceUploadURL(
  videoId: string,
  req: { fileName: string; fileSizeBytes: number; durationSeconds: number },
  opts: RequestOptions = {},
): Promise<{ version: number; uploadUrl: string }> {
  const json = await post(
    `/upload/video/${encodeURIComponent(videoId)}/replace`,
    { fileName: req.fileName, contentType: "video/mp4", fileSizeBytes: req.fileSizeBytes, durationSeconds: req.durationSeconds },
    opts,
    "Could not start the replacement upload",
  );
  if (typeof json.version !== "number" || !Number.isInteger(json.version) || typeof json.uploadUrl !== "string") throw invalid();
  return { version: json.version, uploadUrl: json.uploadUrl };
}

/** `confirmUpload` — the server verifies the object and returns the share link. */
export async function confirmUpload(videoId: string, opts: RequestOptions = {}): Promise<string> {
  const json = await post(`/upload/video/${encodeURIComponent(videoId)}/complete`, {}, opts, "Confirm failed");
  if (typeof json.url !== "string") throw invalid();
  return json.url;
}

/** `confirmReplace` — flips the link to the new version; the new cut's markers + transcript ride here. */
export async function confirmReplace(
  videoId: string,
  version: number,
  meta: { annotations: ShareMarker[]; transcript: TranscriptSegment[] },
  opts: RequestOptions = {},
): Promise<string> {
  const body: { annotations?: ShareMarker[]; transcript?: TranscriptSegment[] } = {};
  if (meta.annotations.length > 0) body.annotations = meta.annotations;
  if (meta.transcript.length > 0) body.transcript = meta.transcript;
  const json = await post(`/upload/video/${encodeURIComponent(videoId)}/replace/${version}/complete`, body, opts, "Confirm failed");
  if (typeof json.url !== "string") throw invalid();
  return json.url;
}

/** Minimal XHR surface (tests inject a fake). */
export interface XhrLike {
  open(method: string, url: string): void;
  setRequestHeader(name: string, value: string): void;
  send(body: Blob): void;
  abort(): void;
  readonly status: number;
  readonly responseText: string;
  upload: { onprogress: ((e: { loaded: number; total: number; lengthComputable: boolean }) => void) | null };
  onload: (() => void) | null;
  onerror: (() => void) | null;
  onabort: (() => void) | null;
}

/**
 * `uploadFile` — PUT the file straight to R2 on the presigned URL, with
 * progress (0…1 of the file's bytes). The Content-Type is the one the URL
 * was signed for.
 */
export function uploadFile(
  uploadUrl: string,
  file: Blob,
  onProgress: (fraction: number) => void,
  opts: { signal?: AbortSignal; xhr?: () => XhrLike } = {},
): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = opts.xhr ? opts.xhr() : (new XMLHttpRequest() as unknown as XhrLike);
    xhr.open("PUT", uploadUrl);
    xhr.setRequestHeader("Content-Type", "video/mp4");
    const total = Math.max(1, file.size);
    xhr.upload.onprogress = (e) => onProgress(Math.min(1, e.loaded / total));
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        onProgress(1);
        resolve();
      } else {
        reject(new ShareApiError(xhr.status, {}, `Upload failed (HTTP ${xhr.status})`));
      }
    };
    xhr.onerror = () =>
      reject(new Error("Upload failed — the storage bucket must allow PUT from this site (R2 CORS)."));
    xhr.onabort = () => reject(new DOMException("Upload cancelled", "AbortError"));
    opts.signal?.addEventListener("abort", () => xhr.abort(), { once: true });
    xhr.send(file);
  });
}

// ── Job mirror (the per-user ShareJobs Durable Object; the dashboard reads it) ──

export async function registerJob(
  req: { videoId: string; projectId: string | null; projectName: string; fileName: string; fileSizeBytes: number },
  opts: RequestOptions = {},
): Promise<string> {
  const body: Record<string, unknown> = {
    videoId: req.videoId,
    projectName: req.projectName,
    fileName: req.fileName,
    fileSizeBytes: req.fileSizeBytes,
  };
  if (req.projectId) body.projectId = req.projectId;
  const json = await post("/upload/jobs", body, opts, "Could not register the upload");
  const job = json.job as { jobId?: unknown } | undefined;
  if (!job || typeof job.jobId !== "string") throw invalid();
  return job.jobId;
}

export async function reportProgress(jobId: string, progress: number, completing = false, opts: RequestOptions = {}): Promise<void> {
  const body: Record<string, unknown> = { progress };
  if (completing) body.completing = true;
  await post(`/upload/jobs/${encodeURIComponent(jobId)}/progress`, body, opts, "Progress report failed");
}

export async function completeJob(jobId: string, shareUrl: string, opts: RequestOptions = {}): Promise<void> {
  await post(`/upload/jobs/${encodeURIComponent(jobId)}/complete`, { shareUrl }, opts, "Job completion failed");
}

export async function failJob(jobId: string, error: string, opts: RequestOptions = {}): Promise<void> {
  await post(`/upload/jobs/${encodeURIComponent(jobId)}/fail`, { error }, opts, "Job failure report failed");
}

// ---------------------------------------------------------------------------
// Transcript
// ---------------------------------------------------------------------------

/**
 * `ShareIntelligence.transcriptPayload(for:)` — the project's subtitle cues
 * retimed to OUTPUT seconds (the exporter's trim + speed map), in the API's
 * transcript shape. One small function on purpose: the shared
 * `transcriptForShare` lands separately and replaces it at merge.
 */
export function transcriptForShare(project: Project): TranscriptSegment[] {
  return transcriptPayload(project) as unknown as TranscriptSegment[];
}

// ---------------------------------------------------------------------------
// The upload sequence (ShareJobCenter.runUpload)
// ---------------------------------------------------------------------------

/** `ShareService.ShareState` — what the sheet, the top bar and the dashboard show. */
export type ShareState =
  | { phase: "idle" }
  | { phase: "exporting"; progress: number }
  | { phase: "uploading"; progress: number }
  | { phase: "completing" }
  | { phase: "done"; url: string }
  | { phase: "failed"; message: string };

export interface ShareUploadInput {
  file: Blob;
  fileName: string;
  /** `project.duration` (the recording's length — what the Mac sends). */
  durationSeconds: number;
  commentsEnabled: boolean;
  annotations: ShareMarker[];
  transcript: TranscriptSegment[];
  projectId: string | null;
  projectName: string;
  /** The project's previous share (same link, new version); null = a fresh link. */
  replaceVideoId: string | null;
}

export interface ShareUploadResult {
  url: string;
  videoId: string;
}

export async function runShareUpload(
  input: ShareUploadInput,
  onState: (state: ShareState) => void,
  opts: RequestOptions & { xhr?: () => XhrLike; now?: () => number } = {},
): Promise<ShareUploadResult> {
  const now = opts.now ?? (() => Date.now());
  const size = input.file.size;
  let jobId: string | null = null;
  onState({ phase: "uploading", progress: 0 });
  try {
    // A project shared before REPLACES its cloud video in place: same link,
    // new version. Only if that is gone does it fall back to a fresh link.
    let replace: { videoId: string; version: number; uploadUrl: string } | null = null;
    if (input.replaceVideoId) {
      try {
        const r = await requestReplaceUploadURL(
          input.replaceVideoId,
          { fileName: input.fileName, fileSizeBytes: size, durationSeconds: input.durationSeconds },
          opts,
        );
        replace = { videoId: input.replaceVideoId, ...r };
      } catch (e) {
        if ((e as DOMException)?.name === "AbortError") throw e;
        replace = null;
      }
    }
    const { videoId, uploadUrl } = replace
      ? replace
      : await requestUploadURL(
          {
            fileName: input.fileName,
            fileSizeBytes: size,
            durationSeconds: input.durationSeconds,
            commentsEnabled: input.commentsEnabled,
            annotations: input.annotations,
            projectId: input.projectId,
            transcript: input.transcript,
          },
          opts,
        );

    // The dashboard's progress mirror — never fatal.
    jobId = await registerJob(
      { videoId, projectId: input.projectId, projectName: input.projectName, fileName: input.fileName, fileSizeBytes: size },
      opts,
    ).catch(() => null);

    // Throttled remote mirror: at most one report per 2 s or 5 %.
    let lastReported = -Infinity;
    let lastProgress = 0;
    await uploadFile(
      uploadUrl,
      input.file,
      (progress) => {
        onState({ phase: "uploading", progress });
        if (jobId && (progress - lastProgress >= 0.05 || now() - lastReported >= 2000)) {
          lastProgress = progress;
          lastReported = now();
          void reportProgress(jobId, progress, false, opts).catch(() => undefined);
        }
      },
      { signal: opts.signal, xhr: opts.xhr },
    );

    onState({ phase: "completing" });
    if (jobId) await reportProgress(jobId, 1, true, opts).catch(() => undefined);
    const url = replace
      ? // The new cut's markers / transcript ride the completion.
        await confirmReplace(videoId, replace.version, { annotations: input.annotations, transcript: input.transcript }, opts)
      : await confirmUpload(videoId, opts);
    onState({ phase: "done", url });
    if (jobId) await completeJob(jobId, url, opts).catch(() => undefined);
    return { url, videoId };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    onState({ phase: "failed", message });
    if (jobId) await failJob(jobId, message, opts).catch(() => undefined);
    throw e;
  }
}
