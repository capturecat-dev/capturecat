/**
 * Publish a web take as a cloud project — the Mac's "Open in Web Editor"
 * push (CloudProjectSync.push) run from the browser:
 *
 *   project.json  newProject(…) — the Mac's `Project(videoURL:…)` defaults,
 *                 serialized losslessly by core/model (2-space pretty JSON)
 *   hash          SHA-256 of every file (streamed; the API re-verifies)
 *   stage         PUT /cloud-projects/:id → presigned PUTs for what is missing
 *   upload        PUT straight to R2 (XHR for progress; restage once if the
 *                 15-minute presigns expire mid-queue)
 *   finalize      POST …/finalize until committed (the server verifies size +
 *                 hash; "verifying" = call again)
 *   save          PUT …/project with If-Match: "<stage revision>"
 *
 * Media references in project.json are Mac-shaped absolute file URLs
 * (…/CaptureCat/Projects/<UUID>/recording.mov): the web resolves them by
 * their project-relative tail, and the Mac re-bases foreign absolute URLs
 * onto its own project folder by file name when it pulls the project.
 */
import { newProject, serializeProjectText, type RecordingSourceKind } from "../core/model";
import {
  CloudApiError,
  finalizeCloudProject,
  saveCloudProject,
  stageCloudProject,
  type ManifestFile,
  type StageResult,
  type UploadTarget,
} from "../state/cloud";
import { backgroundFileName, projectFilePath } from "../state/imageImport";
import { imageLibrary } from "../state/imageLibrary";
import type { RecordedTake } from "./session";
import { sha256Blob } from "./sha256";

export type PublishPhase = "preparing" | "uploading" | "verifying" | "saving" | "done";

export interface PublishProgress {
  phase: PublishPhase;
  /** 0…1 within the phase. */
  fraction: number;
  message: string;
}

const PROJECT_ROOT = "/CaptureCat/Projects";

/** `file:///CaptureCat/Projects/<UUID>/<name>` — a Mac-shaped reference. */
export function mediaRef(projectId: string, name: string): string {
  return `file://${PROJECT_ROOT}/${projectId}/${encodeURIComponent(name)}`;
}

/** The Mac's RecordingSourceKind for a shared surface (a tab is a window of the browser). */
export function sourceKindFor(surface: RecordedTake["surface"]): RecordingSourceKind {
  return surface === "monitor" ? "display" : "window";
}

/** The library image "Set as Default" picked for new projects (CustomWallpaperStore.defaultBackground). */
export interface NewProjectBackground {
  /** File name inside the project folder (`backgroundFileName`). */
  fileName: string;
  /** ProjectSettings.BackgroundType raw value ("Wallpaper", as the Mac stores it). */
  type: "Wallpaper" | "Image";
  blob: Blob;
  contentType: string;
}

/** project.json for a take — exactly what AppState builds after a Mac recording. */
export function projectDocumentFor(take: RecordedTake, name?: string, background?: Pick<NewProjectBackground, "fileName" | "type"> | null): string {
  const project = newProject({
    id: take.id,
    name: name?.trim() || "Untitled Recording",
    videoURL: mediaRef(take.id, "recording.mov"),
    cursorDataURL: null,
    cameraVideoURL: take.camera ? mediaRef(take.id, "camera.mov") : null,
    cameraTimeOffset: take.camera ? take.cameraTimeOffset : 0,
    duration: take.duration,
    recordingSourceKind: sourceKindFor(take.surface),
  });
  // No cursor.json: the cursor overlay has nothing to draw (the system
  // cursor is burned into the frames) — settings stay the Mac's defaults.
  if (background) {
    // CustomWallpaperStore.applyDefaultBackground — applied by AppState's
    // creation flows, never by Project.init (newProject stays the init).
    project.settings.backgroundType = background.type;
    project.settings.backgroundImagePath = projectFilePath(take.id, background.fileName);
  }
  return serializeProjectText(project);
}

/** This browser's default background for a new project from `take`, or null. */
export async function defaultBackgroundFor(take: RecordedTake): Promise<NewProjectBackground | null> {
  try {
    const def = await imageLibrary().defaultBackground();
    if (!def) return null;
    const taken = new Set(filesOf(take).map((f) => f.path.toLowerCase()));
    const { image } = def;
    const fileName = backgroundFileName(image.name, image.ext, image.sha256, (n) => (taken.has(n.toLowerCase()) ? "" : undefined));
    return { fileName, type: def.type, blob: image.blob, contentType: image.contentType };
  } catch {
    return null; // no IndexedDB (private window…) — the Mac's defaults
  }
}

interface LocalFile {
  path: string;
  blob: Blob;
  contentType: string;
}

function filesOf(take: RecordedTake): LocalFile[] {
  const out: LocalFile[] = [{ path: "recording.mov", blob: take.screen, contentType: "video/quicktime" }];
  if (take.camera) out.push({ path: "camera.mov", blob: take.camera, contentType: "video/quicktime" });
  if (take.camera && take.poster) out.push({ path: "camera_poster.png", blob: take.poster, contentType: "image/png" });
  return out;
}

class UploadExpiredError extends Error {}

function putBlob(target: UploadTarget, blob: Blob, onBytes: (sent: number) => void, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open(target.method, target.uploadUrl);
    for (const [k, v] of Object.entries(target.headers)) xhr.setRequestHeader(k, v);
    xhr.upload.onprogress = (e) => onBytes(e.loaded);
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) return resolve();
      // R2 answers an expired presign with 403 (AccessDenied / Request has expired).
      if (xhr.status === 403 && /expired/i.test(xhr.responseText)) return reject(new UploadExpiredError());
      reject(new Error(`Upload failed (HTTP ${xhr.status})${xhr.status === 0 ? "" : ""}`));
    };
    xhr.onerror = () =>
      reject(
        new Error(
          "Upload blocked — the storage bucket must allow PUT from this site (R2 CORS rule \"web-recorder-upload\").",
        ),
      );
    xhr.onabort = () => reject(new DOMException("Upload cancelled", "AbortError"));
    signal?.addEventListener("abort", () => xhr.abort(), { once: true });
    xhr.send(blob);
  });
}

/**
 * Stage a project's COMPLETE file manifest (the API replaces the project's
 * file list with it on finalize — list every file the project keeps), upload
 * what the cloud does not hold yet straight to R2 (restaging once if the
 * 15-minute presigned PUTs expire mid-queue), then finalize until the server
 * has verified and committed it. `blobFor(sha256)` supplies the bytes of any
 * file the API asks for. Resolves with the stage result (its revision is the
 * base for the next project.json save).
 */
export async function commitCloudFiles(
  projectId: string,
  opts: {
    name: string;
    manifest: ManifestFile[];
    blobFor: (sha256: string) => Blob | undefined;
    onProgress?: (p: PublishProgress) => void;
    signal?: AbortSignal;
  },
): Promise<StageResult> {
  const report = opts.onProgress ?? (() => undefined);
  const { name, manifest, signal } = opts;

  // ── stage + upload
  let stage = await stageCloudProject(projectId, { name, files: manifest }, { signal });
  let queue = [...stage.missing];
  const uploadTotal = Math.max(1, queue.reduce((n, t) => n + t.bytes, 0));
  let sent = 0;
  let restaged = false;
  while (queue.length > 0) {
    signal?.throwIfAborted();
    const target = queue[0];
    const blob = opts.blobFor(target.sha256);
    if (!blob) throw new Error("The server asked for a file this project does not have.");
    const left = queue.length;
    const message = left === 1 ? "Uploading…" : `Uploading ${left} files…`;
    try {
      await putBlob(
        target,
        blob,
        (bytes) => report({ phase: "uploading", fraction: Math.min(1, (sent + bytes) / uploadTotal), message }),
        signal,
      );
    } catch (error) {
      if (error instanceof UploadExpiredError && !restaged) {
        restaged = true;
        stage = await stageCloudProject(projectId, { name, files: manifest }, { signal });
        const done = new Set(manifest.map((m) => m.sha256).filter((s) => !queue.some((q) => q.sha256 === s)));
        queue = stage.missing.filter((m) => !done.has(m.sha256));
        continue;
      }
      throw error;
    }
    sent += target.bytes;
    queue.shift();
  }

  // ── finalize (bounded verify per request: keep calling while "verifying")
  report({ phase: "verifying", fraction: 0, message: "Checking upload…" });
  for (let attempt = 0; attempt < 60; attempt++) {
    const result = await finalizeCloudProject(projectId, { signal });
    if (result.committed) break;
    if (result.status === "missing") {
      throw new CloudApiError(409, { error: "Some files did not reach the cloud — try again.", code: "objects_missing" });
    }
    report({ phase: "verifying", fraction: Math.min(0.95, (attempt + 1) / 10), message: "Checking upload…" });
  }
  return stage;
}

/**
 * Upload a take and create its cloud project. Resolves with the project id
 * (the Mac-style UUID) once project.json is saved — open /app/editor/<id>.
 * This browser's default background ("Set as Default" in the image library)
 * is applied and uploaded with it, like the Mac's creation flows.
 */
export async function publishTake(
  take: RecordedTake,
  opts: {
    name?: string;
    onProgress?: (p: PublishProgress) => void;
    signal?: AbortSignal;
    /** Override the library default (null = none). */
    defaultBackground?: NewProjectBackground | null;
  } = {},
): Promise<string> {
  const report = opts.onProgress ?? (() => undefined);
  const signal = opts.signal;
  const id = take.id;
  const name = opts.name?.trim() || "Untitled Recording";
  const background = opts.defaultBackground !== undefined ? opts.defaultBackground : await defaultBackgroundFor(take);
  const document = projectDocumentFor(take, name, background);
  const files = filesOf(take);
  if (background) files.push({ path: background.fileName, blob: background.blob, contentType: background.contentType });

  // ── hash
  const totalBytes = files.reduce((n, f) => n + f.blob.size, 0) || 1;
  let hashed = 0;
  const manifest: ManifestFile[] = [];
  for (const f of files) {
    const before = hashed;
    const sha256 = await sha256Blob(
      f.blob,
      (done) => report({ phase: "preparing", fraction: (before + done) / totalBytes, message: "Preparing files…" }),
      signal,
    );
    hashed += f.blob.size;
    manifest.push({ path: f.path, sha256, bytes: f.blob.size, contentType: f.contentType });
  }
  const bySha = new Map(manifest.map((m, i) => [m.sha256, files[i]]));

  // ── stage + upload + finalize
  const stage = await commitCloudFiles(id, { name, manifest, blobFor: (sha) => bySha.get(sha)?.blob, onProgress: report, signal });

  // ── project.json (first save: based on the stage's revision, 0 for a new project)
  report({ phase: "saving", fraction: 0, message: "Saving project…" });
  const saved = await saveCloudProject(id, document, stage.revision, { signal });
  if (!saved.ok) {
    // A project with this id already has a document — never overwrite it silently.
    throw new CloudApiError(409, { error: "A project with this id already exists in the cloud.", code: "revision_conflict" });
  }
  report({ phase: "done", fraction: 1, message: "Saved" });
  return id;
}
