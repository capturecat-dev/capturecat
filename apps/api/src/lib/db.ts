/**
 * D1 data layer. Replaces the old Firestore REST client (lib/firestore.ts).
 *
 * Rows use snake_case columns; the API keeps the camelCase shapes that the
 * routes (and the edge metadata cache) already rely on, so records returned
 * here are drop-in replacements for the old Firestore documents.
 */

import type { VideoComment, VideoMetadata, VideoVersion } from "../types";

// NOTE: the Stripe customer/subscription mapping used to live here
// (StripeCustomerRecord / upsertStripeCustomer / findUidByStripeCustomer over
// the `stripe_customers` table). It is gone — @better-auth/stripe owns the
// `subscription` table and `user.stripeCustomerId`. Read paths live in
// src/lib/stripe.ts (`hasPaidSubscription`).

interface SharedVideoRow {
  video_id: string;
  uid: string;
  file_name: string;
  content_type: string;
  file_size_bytes: number;
  duration_seconds: number;
  r2_key: string;
  url: string;
  is_private: number;
  status: string;
  created_at: string;
  comments_enabled: number;
  annotations_json: string | null;
  project_id: string | null;
  allow_download: number;
  password_hash: string | null;
  expires_at: string | null;
  max_views: number | null;
  brand_accent: string | null;
  current_version: number;
  show_version_history: number;
  cta_label: string | null;
  cta_url: string | null;
  profile_visible: number;
  thumbnail_type: string | null;
  etag?: string | null;
  org_id?: string | null;
}

function rowToVideo(row: SharedVideoRow): VideoMetadata {
  return {
    videoId: row.video_id,
    uid: row.uid,
    fileName: row.file_name,
    contentType: row.content_type,
    fileSizeBytes: row.file_size_bytes,
    durationSeconds: row.duration_seconds,
    r2Key: row.r2_key,
    url: row.url,
    isPrivate: row.is_private === 1,
    status: row.status as VideoMetadata["status"],
    createdAt: row.created_at,
    commentsEnabled: row.comments_enabled === 1,
    annotationsJson: row.annotations_json ?? null,
    projectId: row.project_id ?? null,
    allowDownload: row.allow_download === 1,
    passwordHash: row.password_hash ?? null,
    expiresAt: row.expires_at ?? null,
    maxViews: row.max_views ?? null,
    brandAccent: row.brand_accent ?? null,
    currentVersion: row.current_version ?? 1,
    showVersionHistory: row.show_version_history === 1,
    ctaLabel: row.cta_label ?? null,
    ctaUrl: row.cta_url ?? null,
    profileVisible: row.profile_visible !== 0,
    etag: row.etag ?? null,
    orgId: row.org_id ?? null,
    thumbnailType: row.thumbnail_type ?? null,
  };
}

/** Record (or clear, with null) that a custom thumbnail exists in R2 and the
 *  content type it was stored with (migration 0020). */
export async function setThumbnailType(
  db: D1Database,
  videoId: string,
  thumbnailType: string | null
): Promise<boolean> {
  const result = await db
    .prepare("UPDATE shared_videos SET thumbnail_type = ? WHERE video_id = ?")
    .bind(thumbnailType, videoId)
    .run();
  return (result.meta.changes ?? 0) > 0;
}

/** Owner-set share-page controls (migration 0012). `password` here is the
 *  precomputed hash, never plaintext — hashing happens at the route. */
export async function updateShareControls(
  db: D1Database,
  videoId: string,
  patch: {
    allowDownload?: boolean;
    passwordHash?: string | null;
    expiresAt?: string | null;
    maxViews?: number | null;
    brandAccent?: string | null;
    showVersionHistory?: boolean;
    ctaLabel?: string | null;
    ctaUrl?: string | null;
    profileVisible?: boolean;
  }
): Promise<boolean> {
  const sets: string[] = [];
  const binds: unknown[] = [];
  if (patch.allowDownload !== undefined) {
    sets.push("allow_download = ?");
    binds.push(patch.allowDownload ? 1 : 0);
  }
  if (patch.passwordHash !== undefined) {
    sets.push("password_hash = ?");
    binds.push(patch.passwordHash);
  }
  if (patch.expiresAt !== undefined) {
    sets.push("expires_at = ?");
    binds.push(patch.expiresAt);
  }
  if (patch.maxViews !== undefined) {
    sets.push("max_views = ?");
    binds.push(patch.maxViews);
  }
  if (patch.brandAccent !== undefined) {
    sets.push("brand_accent = ?");
    binds.push(patch.brandAccent);
  }
  if (patch.showVersionHistory !== undefined) {
    sets.push("show_version_history = ?");
    binds.push(patch.showVersionHistory ? 1 : 0);
  }
  if (patch.ctaLabel !== undefined) {
    sets.push("cta_label = ?");
    binds.push(patch.ctaLabel);
  }
  if (patch.ctaUrl !== undefined) {
    sets.push("cta_url = ?");
    binds.push(patch.ctaUrl);
  }
  if (patch.profileVisible !== undefined) {
    sets.push("profile_visible = ?");
    binds.push(patch.profileVisible ? 1 : 0);
  }
  if (sets.length === 0) return false;
  binds.push(videoId);
  const result = await db
    .prepare(`UPDATE shared_videos SET ${sets.join(", ")} WHERE video_id = ?`)
    .bind(...binds)
    .run();
  return (result.meta.changes ?? 0) > 0;
}

/** Distinct viewer sessions — the number `max_views` caps. */
export async function viewCount(db: D1Database, videoId: string): Promise<number> {
  const row = await db
    .prepare("SELECT COUNT(*) AS n FROM video_views WHERE video_id = ?")
    .bind(videoId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

export async function getSharedVideo(
  db: D1Database,
  videoId: string
): Promise<VideoMetadata | null> {
  const row = await db
    .prepare("SELECT * FROM shared_videos WHERE video_id = ?")
    .bind(videoId)
    .first<SharedVideoRow>();
  return row ? rowToVideo(row) : null;
}

export async function upsertSharedVideo(
  db: D1Database,
  video: VideoMetadata
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO shared_videos (
         video_id, uid, file_name, content_type, file_size_bytes,
         duration_seconds, r2_key, url, is_private, status, created_at,
         comments_enabled, annotations_json, project_id
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(video_id) DO UPDATE SET
         uid = excluded.uid,
         file_name = excluded.file_name,
         content_type = excluded.content_type,
         file_size_bytes = excluded.file_size_bytes,
         duration_seconds = excluded.duration_seconds,
         r2_key = excluded.r2_key,
         url = excluded.url,
         is_private = excluded.is_private,
         status = excluded.status,
         created_at = excluded.created_at,
         comments_enabled = excluded.comments_enabled,
         annotations_json = excluded.annotations_json,
         project_id = excluded.project_id`
    )
    .bind(
      video.videoId,
      video.uid,
      video.fileName,
      video.contentType,
      video.fileSizeBytes,
      video.durationSeconds,
      video.r2Key,
      video.url,
      video.isPrivate ? 1 : 0,
      video.status,
      video.createdAt,
      video.commentsEnabled ? 1 : 0,
      video.annotationsJson,
      video.projectId
    )
    .run();
}

export async function deleteSharedVideo(
  db: D1Database,
  videoId: string
): Promise<void> {
  await db
    .prepare("DELETE FROM shared_videos WHERE video_id = ?")
    .bind(videoId)
    .run();
}

/** Total bytes of "ready" shared media for a user (storage-cap check).
 *  Versioned videos count every retained version; videos without version rows
 *  (pre-0017 uploads that were never re-shared) fall back to the top-level
 *  size so nothing is double-counted or missed. */
export async function storageUsageBytes(
  db: D1Database,
  uid: string
): Promise<number> {
  const row = await db
    .prepare(
      `SELECT COALESCE(SUM(sz), 0) AS total FROM (
         SELECT vv.file_size_bytes AS sz
           FROM video_versions vv
           JOIN shared_videos sv ON sv.video_id = vv.video_id
          WHERE sv.uid = ?1 AND sv.status = 'ready' AND vv.status = 'ready'
         UNION ALL
         SELECT sv.file_size_bytes AS sz
           FROM shared_videos sv
          WHERE sv.uid = ?1 AND sv.status = 'ready'
            AND NOT EXISTS (
              SELECT 1 FROM video_versions vv WHERE vv.video_id = sv.video_id
            )
       )`
    )
    .bind(uid)
    .first<{ total: number }>();
  return row?.total ?? 0;
}

/**
 * A user's ready videos, newest first. Backs GET /api/videos.
 *
 * `idx_shared_videos_uid_status` already covers this predicate. The web
 * dashboard used to query Firestore directly for this, which stopped returning
 * anything the moment uploads started writing D1 instead.
 */
export async function listSharedVideos(
  db: D1Database,
  uid: string
): Promise<VideoMetadata[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM shared_videos
        WHERE uid = ? AND status = 'ready'
        ORDER BY created_at DESC`
    )
    .bind(uid)
    .all<SharedVideoRow>();
  return (results ?? []).map(rowToVideo);
}

/** Ready videos in an organization's team library, newest first. */
export async function listOrgVideos(
  db: D1Database,
  orgId: string
): Promise<VideoMetadata[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM shared_videos
        WHERE org_id = ? AND status = 'ready'
        ORDER BY created_at DESC`
    )
    .bind(orgId)
    .all<SharedVideoRow>();
  return (results ?? []).map(rowToVideo);
}

/** Is `uid` a member of `orgId`? Reads the Better Auth org plugin's table. */
export async function isOrgMember(
  db: D1Database,
  orgId: string,
  uid: string
): Promise<boolean> {
  const row = await db
    .prepare('SELECT 1 AS x FROM "member" WHERE "organizationId" = ? AND "userId" = ? LIMIT 1')
    .bind(orgId, uid)
    .first<{ x: number }>();
  return !!row;
}

/** Move a video in/out of an org's team library (uploader keeps ownership). */
export async function setVideoOrg(
  db: D1Database,
  videoId: string,
  orgId: string | null
): Promise<void> {
  await db
    .prepare("UPDATE shared_videos SET org_id = ? WHERE video_id = ?")
    .bind(orgId, videoId)
    .run();
}

// ---------------------------------------------------------------------------
// Version history (migration 0017)
// ---------------------------------------------------------------------------

interface VideoVersionRow {
  version_id: string;
  video_id: string;
  version_number: number;
  r2_key: string;
  file_size_bytes: number;
  duration_seconds: number;
  status: string;
  created_at: string;
}

function rowToVersion(row: VideoVersionRow): VideoVersion {
  return {
    versionId: row.version_id,
    videoId: row.video_id,
    versionNumber: row.version_number,
    r2Key: row.r2_key,
    fileSizeBytes: row.file_size_bytes,
    durationSeconds: row.duration_seconds,
    status: row.status as VideoVersion["status"],
    createdAt: row.created_at,
  };
}

/** All versions of a video, newest first. Pass `readyOnly` for viewer-facing
 *  lists — pending rows are in-flight replace uploads. */
export async function listVideoVersions(
  db: D1Database,
  videoId: string,
  readyOnly = false
): Promise<VideoVersion[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM video_versions
        WHERE video_id = ?${readyOnly ? " AND status = 'ready'" : ""}
        ORDER BY version_number DESC`
    )
    .bind(videoId)
    .all<VideoVersionRow>();
  return (results ?? []).map(rowToVersion);
}

export async function getVideoVersion(
  db: D1Database,
  videoId: string,
  versionNumber: number
): Promise<VideoVersion | null> {
  const row = await db
    .prepare(
      "SELECT * FROM video_versions WHERE video_id = ? AND version_number = ?"
    )
    .bind(videoId, versionNumber)
    .first<VideoVersionRow>();
  return row ? rowToVersion(row) : null;
}

export async function insertVideoVersion(
  db: D1Database,
  version: VideoVersion
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO video_versions (
         version_id, video_id, version_number, r2_key,
         file_size_bytes, duration_seconds, status, created_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .bind(
      version.versionId,
      version.videoId,
      version.versionNumber,
      version.r2Key,
      version.fileSizeBytes,
      version.durationSeconds,
      version.status,
      version.createdAt
    )
    .run();
}

/** The next version number to mint for a replace upload. */
export async function nextVersionNumber(
  db: D1Database,
  videoId: string
): Promise<number> {
  const row = await db
    .prepare(
      "SELECT COALESCE(MAX(version_number), 1) AS n FROM video_versions WHERE video_id = ?"
    )
    .bind(videoId)
    .first<{ n: number }>();
  return (row?.n ?? 1) + 1;
}

export async function markVersionReady(
  db: D1Database,
  videoId: string,
  versionNumber: number,
  fileSizeBytes: number
): Promise<void> {
  await db
    .prepare(
      `UPDATE video_versions SET status = 'ready', file_size_bytes = ?
        WHERE video_id = ? AND version_number = ?`
    )
    .bind(fileSizeBytes, videoId, versionNumber)
    .run();
}

/** Point the share link at a version: the parent row's r2_key/size/duration
 *  follow so every existing read path (stream, meta, quotas) sees the new
 *  file without learning about versions. */
export async function setCurrentVersion(
  db: D1Database,
  videoId: string,
  version: VideoVersion
): Promise<void> {
  await db
    .prepare(
      `UPDATE shared_videos
          SET current_version = ?, r2_key = ?, file_size_bytes = ?, duration_seconds = ?
        WHERE video_id = ?`
    )
    .bind(
      version.versionNumber,
      version.r2Key,
      version.fileSizeBytes,
      version.durationSeconds,
      videoId
    )
    .run();
}

export async function deleteVideoVersion(
  db: D1Database,
  videoId: string,
  versionNumber: number
): Promise<void> {
  await db
    .prepare(
      "DELETE FROM video_versions WHERE video_id = ? AND version_number = ?"
    )
    .bind(videoId, versionNumber)
    .run();
}

// ---------------------------------------------------------------------------
// Viewer comments
// ---------------------------------------------------------------------------

interface VideoCommentRow {
  comment_id: string;
  video_id: string;
  author_name: string;
  body: string;
  video_time: number;
  created_at: string;
}

function rowToComment(row: VideoCommentRow): VideoComment {
  return {
    commentId: row.comment_id,
    videoId: row.video_id,
    authorName: row.author_name,
    body: row.body,
    videoTime: row.video_time,
    createdAt: row.created_at,
  };
}

/** A video's comments ordered by their anchor time in the video. */
export async function listVideoComments(
  db: D1Database,
  videoId: string,
  limit = 200
): Promise<VideoComment[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM video_comments
        WHERE video_id = ?
        ORDER BY video_time ASC, created_at ASC
        LIMIT ?`
    )
    .bind(videoId, limit)
    .all<VideoCommentRow>();
  return (results ?? []).map(rowToComment);
}

export async function insertVideoComment(
  db: D1Database,
  comment: VideoComment
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO video_comments (
         comment_id, video_id, author_name, body, video_time, created_at
       ) VALUES (?, ?, ?, ?, ?, ?)`
    )
    .bind(
      comment.commentId,
      comment.videoId,
      comment.authorName,
      comment.body,
      comment.videoTime,
      comment.createdAt
    )
    .run();
}

/** Comment count guard — caps runaway threads on a public page. */
export async function countVideoComments(
  db: D1Database,
  videoId: string
): Promise<number> {
  const row = await db
    .prepare("SELECT COUNT(*) AS n FROM video_comments WHERE video_id = ?")
    .bind(videoId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

/** Flips a video's privacy flag. Returns false when the row does not exist. */
export async function setSharedVideoPrivacy(
  db: D1Database,
  videoId: string,
  isPrivate: boolean
): Promise<boolean> {
  const res = await db
    .prepare("UPDATE shared_videos SET is_private = ? WHERE video_id = ?")
    .bind(isPrivate ? 1 : 0, videoId)
    .run();
  return (res.meta?.changes ?? 0) > 0;
}

// ---------------------------------------------------------------------------
// Reactions (migration 0013)
// ---------------------------------------------------------------------------

export interface VideoReaction {
  emoji: string;
  videoTime: number;
}

const REACTION_EMOJI = new Set(["👍", "❤️", "🔥", "😂", "😮", "🎉"]);

export function isAllowedReaction(emoji: string): boolean {
  return REACTION_EMOJI.has(emoji);
}

/** One reaction per (video, session): a re-react replaces, same-emoji
 *  re-react toggles off. Returns the viewer's resulting reaction. */
export async function setReaction(
  db: D1Database,
  reactionId: string,
  videoId: string,
  sessionId: string,
  emoji: string,
  videoTime: number
): Promise<{ emoji: string; videoTime: number } | null> {
  const existing = await db
    .prepare(
      "SELECT emoji FROM video_reactions WHERE video_id = ? AND session_id = ?"
    )
    .bind(videoId, sessionId)
    .first<{ emoji: string }>();
  if (existing && existing.emoji === emoji) {
    await db
      .prepare("DELETE FROM video_reactions WHERE video_id = ? AND session_id = ?")
      .bind(videoId, sessionId)
      .run();
    return null;
  }
  await db
    .prepare(
      `INSERT INTO video_reactions
         (reaction_id, video_id, session_id, emoji, video_time, created_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(video_id, session_id) DO UPDATE SET
         emoji = excluded.emoji,
         video_time = excluded.video_time,
         created_at = excluded.created_at`
    )
    .bind(reactionId, videoId, sessionId, emoji, videoTime, new Date().toISOString())
    .run();
  return { emoji, videoTime };
}

export async function myReaction(
  db: D1Database,
  videoId: string,
  sessionId: string
): Promise<{ emoji: string; videoTime: number } | null> {
  const row = await db
    .prepare(
      "SELECT emoji, video_time FROM video_reactions WHERE video_id = ? AND session_id = ?"
    )
    .bind(videoId, sessionId)
    .first<{ emoji: string; video_time: number }>();
  return row ? { emoji: row.emoji, videoTime: row.video_time } : null;
}

/** All reactions for a video, oldest first — the player builds its density
 *  strip client-side (bounded by the per-video cap). */
export async function listReactions(
  db: D1Database,
  videoId: string
): Promise<VideoReaction[]> {
  const rows = await db
    .prepare(
      `SELECT emoji, video_time FROM video_reactions
        WHERE video_id = ? ORDER BY video_time LIMIT 2000`
    )
    .bind(videoId)
    .all<{ emoji: string; video_time: number }>();
  return (rows.results ?? []).map((r) => ({ emoji: r.emoji, videoTime: r.video_time }));
}

export async function reactionCount(db: D1Database, videoId: string): Promise<number> {
  const row = await db
    .prepare("SELECT COUNT(*) AS n FROM video_reactions WHERE video_id = ?")
    .bind(videoId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

// ---------------------------------------------------------------------------
// Transcripts (migration 0013)
// ---------------------------------------------------------------------------

export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
  /** Optional word-level timings (karaoke captions); absent on older uploads. */
  words?: Array<{ start: number; end: number; text: string }>;
}

export async function upsertTranscript(
  db: D1Database,
  videoId: string,
  uid: string,
  segments: TranscriptSegment[]
): Promise<void> {
  const fullText = segments.map((s) => s.text).join(" ").toLowerCase().slice(0, 200_000);
  await db
    .prepare(
      `INSERT INTO video_transcripts (video_id, uid, segments_json, full_text, created_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(video_id) DO UPDATE SET
         uid = excluded.uid,
         segments_json = excluded.segments_json,
         full_text = excluded.full_text`
    )
    .bind(videoId, uid, JSON.stringify(segments), fullText, new Date().toISOString())
    .run();
}

export async function getTranscript(
  db: D1Database,
  videoId: string
): Promise<TranscriptSegment[] | null> {
  const row = await db
    .prepare("SELECT segments_json FROM video_transcripts WHERE video_id = ?")
    .bind(videoId)
    .first<{ segments_json: string }>();
  if (!row) return null;
  try {
    const parsed = JSON.parse(row.segments_json);
    return Array.isArray(parsed) ? (parsed as TranscriptSegment[]) : null;
  } catch {
    return null;
  }
}

/** Library-wide transcript search: which of the user's videos mention `q`,
 *  and the first few matching segments of each. */
export async function searchTranscripts(
  db: D1Database,
  uid: string,
  q: string
): Promise<Array<{ videoId: string; segments: TranscriptSegment[] }>> {
  const needle = `%${q.toLowerCase().replace(/[%_]/g, "")}%`;
  const rows = await db
    .prepare(
      `SELECT video_id, segments_json FROM video_transcripts
        WHERE uid = ? AND full_text LIKE ? LIMIT 20`
    )
    .bind(uid, needle)
    .all<{ video_id: string; segments_json: string }>();
  const lowered = q.toLowerCase();
  return (rows.results ?? []).map((r) => {
    let segments: TranscriptSegment[] = [];
    try {
      const parsed = JSON.parse(r.segments_json) as TranscriptSegment[];
      segments = parsed.filter((s) => s.text.toLowerCase().includes(lowered)).slice(0, 5);
    } catch { /* skip */ }
    return { videoId: r.video_id, segments };
  });
}

// ---------------------------------------------------------------------------
// AI summaries (migration 0013)
// ---------------------------------------------------------------------------

export async function setAISummary(
  db: D1Database,
  videoId: string,
  fields: { title: string | null; summary: string | null; chaptersJson: string | null; source: string }
): Promise<void> {
  await db
    .prepare(
      `UPDATE shared_videos
          SET ai_title = ?, ai_summary = ?, ai_chapters_json = ?, ai_source = ?
        WHERE video_id = ?`
    )
    .bind(fields.title, fields.summary, fields.chaptersJson, fields.source, videoId)
    .run();
}

export async function getAISummary(
  db: D1Database,
  videoId: string
): Promise<{ title: string | null; summary: string | null; chaptersJson: string | null; source: string | null } | null> {
  const row = await db
    .prepare(
      "SELECT ai_title, ai_summary, ai_chapters_json, ai_source FROM shared_videos WHERE video_id = ?"
    )
    .bind(videoId)
    .first<{ ai_title: string | null; ai_summary: string | null; ai_chapters_json: string | null; ai_source: string | null }>();
  if (!row) return null;
  return {
    title: row.ai_title,
    summary: row.ai_summary,
    chaptersJson: row.ai_chapters_json,
    source: row.ai_source,
  };
}

// ---------------------------------------------------------------------------
// Custom domains (migration 0013)
// ---------------------------------------------------------------------------

export interface CustomDomain {
  domain: string;
  uid: string;
  verified: boolean;
  createdAt: string;
}

export async function listDomains(db: D1Database, uid: string): Promise<CustomDomain[]> {
  const rows = await db
    .prepare("SELECT * FROM custom_domains WHERE uid = ? ORDER BY created_at")
    .bind(uid)
    .all<{ domain: string; uid: string; verified: number; created_at: string }>();
  return (rows.results ?? []).map((r) => ({
    domain: r.domain,
    uid: r.uid,
    verified: r.verified === 1,
    createdAt: r.created_at,
  }));
}

export async function insertDomain(
  db: D1Database,
  domain: string,
  uid: string
): Promise<boolean> {
  try {
    await db
      .prepare(
        "INSERT INTO custom_domains (domain, uid, verified, created_at) VALUES (?, ?, 0, ?)"
      )
      .bind(domain, uid, new Date().toISOString())
      .run();
    return true;
  } catch {
    return false; // taken
  }
}

export async function setDomainVerified(
  db: D1Database,
  domain: string,
  verified: boolean
): Promise<void> {
  await db
    .prepare("UPDATE custom_domains SET verified = ? WHERE domain = ?")
    .bind(verified ? 1 : 0, domain)
    .run();
}

export async function deleteDomain(db: D1Database, domain: string, uid: string): Promise<void> {
  await db
    .prepare("DELETE FROM custom_domains WHERE domain = ? AND uid = ?")
    .bind(domain, uid)
    .run();
}

export async function resolveDomain(
  db: D1Database,
  domain: string
): Promise<CustomDomain | null> {
  const row = await db
    .prepare("SELECT * FROM custom_domains WHERE domain = ? AND verified = 1")
    .bind(domain)
    .first<{ domain: string; uid: string; verified: number; created_at: string }>();
  return row
    ? { domain: row.domain, uid: row.uid, verified: true, createdAt: row.created_at }
    : null;
}
