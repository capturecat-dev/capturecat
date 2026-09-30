/**
 * Add one media file the web editor made (a recorded voice-over) to a cloud
 * project — the stage → PUT → finalize half of the Mac's
 * `CloudProjectSync.push`, run for a single new file:
 *
 *   list      GET …/files — the files the cloud holds NOW (another tab or
 *             the Mac may have pushed since this page loaded)
 *   stage     PUT …/:id with that list + the new file. A stage REPLACES the
 *             project's manifest (finalize garbage-collects whatever it
 *             drops), so it must carry every existing file, unchanged.
 *   upload    presigned PUT for what the server lacks (only the new file,
 *             normally; content-addressed, so a re-record of identical bytes
 *             uploads nothing); restage once if the 15-minute presign expires
 *   finalize  until committed ("verifying" = call again)
 *   refresh   fresh presigned GETs, including the new file
 *
 * project.json is NOT saved here: the store's autosave does that (the page
 * holds saves until the upload settles, so a saved document never names a
 * file the cloud does not have yet).
 */
import { putBlob, UploadExpiredError } from "../record/publish";
import { sha256Blob } from "../record/sha256";
import {
  CloudApiError,
  finalizeCloudProject,
  refreshMediaUrls,
  stageCloudProject,
  type ManifestFile,
  type MediaUrls,
  type UploadTarget,
} from "./cloud";

export interface AddCloudFileOptions {
  /** Project name for the stage call (the Mac sends `project.name`). */
  name: string;
  /** Logical path relative to the project folder, e.g. `voiceover-<UUID>.m4a`. */
  path: string;
  file: Blob;
  contentType: string;
  signal?: AbortSignal;
  onProgress?: (fraction: number) => void;
  /** The presigned PUT (tests inject a fake; default: XHR straight to R2). */
  put?: (target: UploadTarget, blob: Blob, onBytes: (sent: number) => void, signal?: AbortSignal) => Promise<void>;
}

/** The manifest for "everything the cloud has, plus this file" (same path → replaced). */
export function manifestWithFile(current: Pick<MediaUrls, "media">, added: ManifestFile): ManifestFile[] {
  const lower = added.path.toLowerCase();
  const files: ManifestFile[] = Object.values(current.media)
    .filter((f) => f.path.toLowerCase() !== lower)
    .map((f) => ({ path: f.path, sha256: f.sha256, bytes: f.bytes, contentType: f.contentType, ...(f.source ? { source: f.source } : {}) }));
  files.push(added);
  return files;
}

/** Uploads `file` into the project and resolves with the refreshed media URLs. */
export async function addCloudProjectFile(projectId: string, opts: AddCloudFileOptions): Promise<MediaUrls & { revision: number }> {
  const { signal } = opts;
  const put = opts.put ?? putBlob;
  const sha256 = await sha256Blob(opts.file, undefined, signal);
  const added: ManifestFile = { path: opts.path, sha256, bytes: opts.file.size, contentType: opts.contentType };

  const current = await refreshMediaUrls(projectId, { signal });
  const files = manifestWithFile(current, added);
  let stage = await stageCloudProject(projectId, { name: opts.name, files }, { signal });

  let queue = [...stage.missing];
  let restaged = false;
  while (queue.length > 0) {
    signal?.throwIfAborted();
    const target = queue[0];
    if (target.sha256 !== sha256) {
      // The cloud lost a file this page never had — only a full push from
      // the Mac can restore it; committing without it would drop it.
      throw new CloudApiError(409, {
        error: `The cloud copy is missing ${target.paths[0] ?? "a file"} — sync the project from the Mac app again.`,
        code: "objects_missing",
      });
    }
    try {
      await put(target, opts.file, (sent) => opts.onProgress?.(Math.min(1, sent / Math.max(1, target.bytes))), signal);
    } catch (error) {
      if (error instanceof UploadExpiredError && !restaged) {
        restaged = true;
        stage = await stageCloudProject(projectId, { name: opts.name, files }, { signal });
        queue = [...stage.missing];
        continue;
      }
      throw error;
    }
    queue.shift();
  }

  for (let attempt = 0; attempt < 60; attempt++) {
    const result = await finalizeCloudProject(projectId, { signal });
    if (result.committed) return refreshMediaUrls(projectId, { signal });
    if (result.status === "missing") {
      throw new CloudApiError(409, { error: "The voice over did not reach the cloud — try again.", code: "objects_missing" });
    }
  }
  throw new CloudApiError(504, { error: "The cloud is still checking the upload — try again in a moment.", code: "verifying" });
}
