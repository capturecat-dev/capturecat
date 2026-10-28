/**
 * Moderation (migration 0038): viewer reports, admin takedowns and the audit
 * trail. The admin console's Videos page drives it through
 * routes/admin-moderation.ts; viewers report from the share page through
 * POST /api/video/:id/report (routes/video-report.ts).
 *
 * A takedown HIDES a video, it does not delete it: `removed_at` is set and
 * every public surface — the byte route, /meta, unlock, download, thumbnail,
 * comments, reactions, analytics ingest, the public profile — answers
 * "removed" (410 + REMOVED_BODY). The owner still sees it in their dashboard
 * with the reason; only an admin can restore it.
 */
import type { Context } from "hono";
import type { Env, VideoMetadata } from "../types";
import { generateId } from "./id";
import { purgeVideoMeta } from "./video-share";

/** Report categories, in the order the share page lists them. Raw values are
 *  persistence identity (video_reports.reason) — never rename one. */
export const REPORT_REASONS = [
  "spam",
  "sexual",
  "violence",
  "hate",
  "harassment",
  "illegal",
  "copyright",
  "other",
] as const;
export type ReportReason = (typeof REPORT_REASONS)[number];

export const REPORT_REASON_LABELS: Record<ReportReason, string> = {
  spam: "Spam or misleading",
  sexual: "Sexual content",
  violence: "Violence or gore",
  hate: "Hate or harassment of a group",
  harassment: "Bullying or harassment",
  illegal: "Illegal activity",
  copyright: "Copyright infringement",
  other: "Something else",
};

export const REPORT_DETAILS_MAX = 1000;
export const REMOVAL_REASON_MAX = 500;

/** What every public surface says about a removed video. */
export const REMOVED_MESSAGE = "This video was removed for violating CaptureCat's terms.";
export const REMOVED_BODY = { error: "removed", message: REMOVED_MESSAGE } as const;

export function isRemoved(doc: Pick<VideoMetadata, "removedAt">): boolean {
  return !!doc.removedAt;
}

/** 410 Gone with the shared body — the share page renders the notice from it. */
export function removedResponse(c: Context) {
  return c.json(REMOVED_BODY, 410);
}

/**
 * Who reported, without storing who: HMAC-SHA256 of the IP (and the user id
 * when signed in) under the auth secret. Stable enough to keep one open
 * report per person per video; useless for recovering the IP.
 */
export async function reporterHash(secret: string, ip: string, uid: string | null): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(`video-report:${secret}`),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ip}\n${uid ?? ""}`));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export type ModerationAction = "remove" | "restore" | "delete" | "dismiss";

export async function recordModerationAction(
  db: D1Database,
  entry: { videoId: string; videoOwner: string | null; adminUid: string; action: ModerationAction; reason?: string | null },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO moderation_actions (id, video_id, video_owner, admin_uid, action, reason, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(generateId(), entry.videoId, entry.videoOwner, entry.adminUid, entry.action, entry.reason ?? null, new Date().toISOString())
    .run();
}

/** Close every open report on a video with this resolution. */
export async function resolveReports(db: D1Database, videoId: string, resolution: "removed" | "dismissed"): Promise<number> {
  const result = await db
    .prepare(`UPDATE video_reports SET resolved_at = ?, resolution = ? WHERE video_id = ? AND resolved_at IS NULL`)
    .bind(new Date().toISOString(), resolution, videoId)
    .run();
  return result.meta.changes ?? 0;
}

/**
 * Drop the caches that would keep serving a video after a takedown in this
 * colo: the byte route's metadata copy (it decides on that) and the edge
 * copy of a public share's bytes. Other colos follow within the metadata's
 * 30 s lifetime — the byte route re-checks before it serves from cache.
 */
export async function purgeVideoCaches(env: Env, videoId: string): Promise<void> {
  await purgeVideoMeta(videoId);
  const origin = (env.BETTER_AUTH_URL ?? "https://api.capturecat.so").replace(/\/+$/, "");
  await caches.default.delete(new Request(`${origin}/api/video/${videoId}`));
}

export async function takeDownVideo(env: Env, doc: VideoMetadata, adminUid: string, reason: string): Promise<void> {
  await env.DB
    .prepare(`UPDATE shared_videos SET removed_at = ?, removed_reason = ?, removed_by = ? WHERE video_id = ?`)
    .bind(new Date().toISOString(), reason, adminUid, doc.videoId)
    .run();
  await resolveReports(env.DB, doc.videoId, "removed");
  await recordModerationAction(env.DB, { videoId: doc.videoId, videoOwner: doc.uid, adminUid, action: "remove", reason });
  await purgeVideoCaches(env, doc.videoId);
}

export async function restoreVideo(env: Env, doc: VideoMetadata, adminUid: string): Promise<void> {
  await env.DB
    .prepare(`UPDATE shared_videos SET removed_at = NULL, removed_reason = NULL, removed_by = NULL WHERE video_id = ?`)
    .bind(doc.videoId)
    .run();
  await recordModerationAction(env.DB, { videoId: doc.videoId, videoOwner: doc.uid, adminUid, action: "restore" });
  await purgeVideoCaches(env, doc.videoId);
}
