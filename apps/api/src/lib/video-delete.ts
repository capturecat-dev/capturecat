/**
 * Deleting a share for good: every version's file (CaptureCat R2 and the
 * owner's own bucket), the owner-uploaded poster, the version rows, playlist
 * entries and the share row. One implementation for the owner's
 * DELETE /video/:id (routes/delete.ts) and the admin's moderation delete
 * (routes/admin-moderation.ts), so neither can leave files behind that the
 * other would have removed.
 */
import type { Env, VideoMetadata } from "../types";
import { deleteSharedVideo, deleteVideoVersion, listVideoVersions } from "./db";
import { deleteStoredObject } from "./storage";
import { purgeVideoMeta } from "./video-share";

export type DeleteVideoResult =
  | { ok: true; leftInBucket: string[] }
  /** An R2 object survived its delete; nothing in D1 was touched. */
  | { ok: false; r2Key: string };

export async function deleteVideoEverywhere(env: Env, doc: VideoMetadata): Promise<DeleteVideoResult> {
  const videoId = doc.videoId;
  // Every version's file goes too (migration 0017), plus the legacy key.
  // Files in the owner's own bucket (migration 0029) are listed separately:
  // they go through that bucket's S3 API, not the R2 binding.
  const versions = await listVideoVersions(env.DB, videoId);
  const customFiles = new Map<string, { storageId: string; key: string }>();
  for (const f of [{ storageId: doc.storageId, key: doc.r2Key }, ...versions.map((v) => ({ storageId: v.storageId, key: v.r2Key }))]) {
    if (f.storageId && f.key.length > 0) {
      customFiles.set(`${f.storageId}\n${f.key}`, { storageId: f.storageId, key: f.key });
    }
  }
  const candidateKeys = Array.from(
    new Set(
      [
        doc.r2Key.length > 0 && !doc.storageId ? doc.r2Key : null,
        `videos/${videoId}.mp4`,
        ...versions.filter((v) => !v.storageId).map((v) => v.r2Key),
        // The owner-uploaded poster (routes/video.ts thumbnailR2Key). It was
        // orphaned in R2 forever when the video went. Posters always live in
        // CaptureCat R2, whatever bucket the video is in.
        `thumbs/${videoId}`,
      ].filter((value): value is string => value !== null)
    )
  );

  // The owner's bucket may refuse (keys rotated, bucket deleted). The share
  // still goes — refusing would leave them a link they can never take down —
  // and the result names what is left for them to clean up.
  const leftInBucket: string[] = [];
  for (const f of customFiles.values()) {
    await deleteStoredObject(env, f.storageId, f.key).catch((err) => {
      console.error("delete: custom bucket refused", f.key, err);
      leftInBucket.push(f.key);
    });
  }

  for (const key of candidateKeys) {
    await env.R2.delete(key);
  }

  for (const key of candidateKeys) {
    const existingObject = await env.R2.get(key);
    if (existingObject) return { ok: false, r2Key: key };
  }

  // Delete DB records (version rows first — no FK, but never leave orphans)
  for (const v of versions) {
    await deleteVideoVersion(env.DB, videoId, v.versionNumber);
  }
  await env.DB
    .prepare("DELETE FROM playlist_videos WHERE video_id = ?")
    .bind(videoId)
    .run();
  await deleteSharedVideo(env.DB, videoId);

  await purgeVideoMeta(videoId);
  return { ok: true, leftInBucket };
}
