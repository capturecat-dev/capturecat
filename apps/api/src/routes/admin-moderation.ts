/**
 * The admin console's Videos page (admin.capturecat.so → /admin/videos):
 * every upload, viewer reports, and the moderation actions. Mounted under
 * adminRoutes, so every path here is behind its role check (404 to anyone
 * who is not an admin). Model and rules: lib/moderation.ts, migration 0038.
 *
 *   GET    /admin/videos?filter=all|reported|removed&q=&cursor=&limit=
 *   GET    /admin/videos/:id              one video, its reports and its history
 *   GET    /admin/videos/:id/stream       the bytes, for the console's player
 *                                         (any video, removed or private —
 *                                         moderating needs to see it)
 *   GET    /admin/videos/:id/thumbnail    the owner-uploaded poster, if any
 *   POST   /admin/videos/:id/remove       { reason } take down (file kept)
 *   POST   /admin/videos/:id/restore      undo a takedown
 *   POST   /admin/videos/:id/dismiss      close its open reports, no action
 *   DELETE /admin/videos/:id              delete for good (lib/video-delete.ts)
 *
 * Every action is written to moderation_actions with the admin's id.
 */
import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Env, Variables, VideoMetadata } from "../types";
import { getSharedVideo } from "../lib/db";
import { parseJsonBody, parseValue } from "../lib/validate";
import { customObjectUrl, storeFor, StorageUnavailableError } from "../lib/storage";
import { shareBaseURL } from "../lib/origins";
import {
  REMOVAL_REASON_MAX,
  REPORT_REASON_LABELS,
  type ReportReason,
  recordModerationAction,
  resolveReports,
  restoreVideo,
  takeDownVideo,
} from "../lib/moderation";
import { deleteVideoEverywhere } from "../lib/video-delete";

type App = Hono<{ Bindings: Env; Variables: Variables }>;
type C = Context<{ Bindings: Env; Variables: Variables }>;

export const ADMIN_VIDEOS_PAGE = { default: 50, max: 100 } as const;

const listQuery = z.object({
  filter: z.enum(["all", "reported", "removed"]).default("all"),
  q: z.string().trim().max(200).optional(),
  cursor: z.string().max(400).optional(),
  limit: z.coerce.number().int().min(1).max(ADMIN_VIDEOS_PAGE.max).default(ADMIN_VIDEOS_PAGE.default),
});

const removeBody = z.object({ reason: z.string().trim().min(1).max(REMOVAL_REASON_MAX) });

interface AdminVideoRow {
  video_id: string;
  uid: string;
  file_name: string;
  ai_title: string | null;
  file_size_bytes: number;
  duration_seconds: number;
  is_private: number;
  status: string;
  created_at: string;
  password_hash: string | null;
  profile_visible: number;
  thumbnail_type: string | null;
  removed_at: string | null;
  removed_reason: string | null;
  owner_email: string | null;
  owner_name: string | null;
  owner_blocked: number | null;
  views: number;
  open_reports: number;
  last_report_at: string | null;
}

const SELECT = `
  SELECT sv.video_id, sv.uid, sv.file_name, sv.ai_title, sv.file_size_bytes, sv.duration_seconds,
         sv.is_private, sv.status, sv.created_at, sv.password_hash, sv.profile_visible,
         sv.thumbnail_type, sv.removed_at, sv.removed_reason,
         u.email AS owner_email, u.name AS owner_name, u.blocked AS owner_blocked,
         (SELECT COUNT(*) FROM video_views vv WHERE vv.video_id = sv.video_id) AS views,
         (SELECT COUNT(*) FROM video_reports r WHERE r.video_id = sv.video_id AND r.resolved_at IS NULL) AS open_reports,
         (SELECT MAX(r.created_at) FROM video_reports r WHERE r.video_id = sv.video_id AND r.resolved_at IS NULL) AS last_report_at
    FROM shared_videos sv
    LEFT JOIN "user" u ON u.id = sv.uid`;

/** Who can watch it today, in the words the rest of the product uses. */
function visibility(r: Pick<AdminVideoRow, "is_private" | "password_hash" | "profile_visible">): "private" | "password" | "public" | "unlisted" {
  if (r.is_private === 1) return "private";
  if (r.password_hash) return "password";
  return r.profile_visible === 1 ? "public" : "unlisted";
}

function toAdminVideo(env: Env, r: AdminVideoRow) {
  return {
    videoId: r.video_id,
    title: r.ai_title || r.file_name,
    fileName: r.file_name,
    sizeBytes: r.file_size_bytes,
    durationSeconds: r.duration_seconds,
    status: r.status,
    visibility: visibility(r),
    createdAt: r.created_at,
    hasThumbnail: !!r.thumbnail_type,
    shareUrl: `${shareBaseURL(env)}/share/${r.video_id}`,
    owner: { id: r.uid, email: r.owner_email, name: r.owner_name, blocked: r.owner_blocked === 1 },
    views: r.views,
    openReports: r.open_reports,
    lastReportAt: r.last_report_at,
    removed: r.removed_at ? { at: r.removed_at, reason: r.removed_reason } : null,
  };
}

/** Opaque keyset cursor for the "all" list: (created_at, video_id) of the last row. */
function encodeCursor(createdAt: string, videoId: string): string {
  return btoa(JSON.stringify([createdAt, videoId]));
}
function decodeCursor(raw: string | undefined): [string, string] | null {
  if (!raw) return null;
  try {
    const value = JSON.parse(atob(raw));
    return Array.isArray(value) && typeof value[0] === "string" && typeof value[1] === "string" ? [value[0], value[1]] : null;
  } catch {
    return null;
  }
}

async function counts(db: D1Database) {
  const row = await db
    .prepare(
      `SELECT (SELECT COUNT(*) FROM shared_videos) AS all_count,
              (SELECT COUNT(DISTINCT video_id) FROM video_reports WHERE resolved_at IS NULL) AS reported,
              (SELECT COUNT(*) FROM shared_videos WHERE removed_at IS NOT NULL) AS removed`,
    )
    .first<{ all_count: number; reported: number; removed: number }>();
  return { all: row?.all_count ?? 0, reported: row?.reported ?? 0, removed: row?.removed ?? 0 };
}

async function videoOr404(c: C): Promise<VideoMetadata | Response> {
  const doc = await getSharedVideo(c.env.DB, c.req.param("id")!);
  return doc ?? c.json({ error: "Video not found" }, 404);
}

export function registerModerationAdminRoutes(app: App): void {
  app.get("/admin/videos", async (c) => {
    const parsed = parseValue(Object.fromEntries(new URL(c.req.url).searchParams), listQuery);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const { filter, q, limit } = parsed.data;

    const where: string[] = [];
    const binds: unknown[] = [];
    if (q) {
      // An exact id, or a substring of the title, file name or owner email.
      const like = `%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`;
      where.push(
        `(sv.video_id = ? OR sv.file_name LIKE ? ESCAPE '\\' OR sv.ai_title LIKE ? ESCAPE '\\' OR u.email LIKE ? ESCAPE '\\')`,
      );
      binds.push(q, like, like, like);
    }
    let order: string;
    let offset = 0;
    if (filter === "reported") {
      where.push(`EXISTS (SELECT 1 FROM video_reports r WHERE r.video_id = sv.video_id AND r.resolved_at IS NULL)`);
      order = `last_report_at DESC, sv.video_id DESC`;
      offset = Math.max(0, Number.parseInt(c.req.query("cursor") ?? "0", 10) || 0);
    } else if (filter === "removed") {
      where.push(`sv.removed_at IS NOT NULL`);
      order = `sv.removed_at DESC, sv.video_id DESC`;
      offset = Math.max(0, Number.parseInt(c.req.query("cursor") ?? "0", 10) || 0);
    } else {
      const cursor = decodeCursor(parsed.data.cursor);
      if (cursor) {
        where.push(`(sv.created_at < ? OR (sv.created_at = ? AND sv.video_id < ?))`);
        binds.push(cursor[0], cursor[0], cursor[1]);
      }
      order = `sv.created_at DESC, sv.video_id DESC`;
    }

    const sql = `${SELECT}${where.length ? ` WHERE ${where.join(" AND ")}` : ""} ORDER BY ${order} LIMIT ? OFFSET ?`;
    const { results } = await c.env.DB.prepare(sql)
      .bind(...binds, limit + 1, offset)
      .all<AdminVideoRow>();
    const page = results.slice(0, limit);
    const more = results.length > limit;
    const last = page[page.length - 1];
    const nextCursor = !more || !last
      ? null
      : filter === "all"
        ? encodeCursor(last.created_at, last.video_id)
        : String(offset + limit);

    return c.json({
      videos: page.map((r) => toAdminVideo(c.env, r)),
      nextCursor,
      counts: await counts(c.env.DB),
    });
  });

  app.get("/admin/videos/:id", async (c) => {
    const row = await c.env.DB.prepare(`${SELECT} WHERE sv.video_id = ?`)
      .bind(c.req.param("id"))
      .first<AdminVideoRow>();
    if (!row) return c.json({ error: "Video not found" }, 404);
    const [reports, actions] = await Promise.all([
      c.env.DB.prepare(
        `SELECT id, reason, details, reporter_uid, created_at, resolved_at, resolution
           FROM video_reports WHERE video_id = ? ORDER BY created_at DESC LIMIT 100`,
      )
        .bind(row.video_id)
        .all<{ id: string; reason: string; details: string | null; reporter_uid: string | null; created_at: string; resolved_at: string | null; resolution: string | null }>(),
      c.env.DB.prepare(
        `SELECT a.id, a.action, a.reason, a.created_at, u.email AS admin_email
           FROM moderation_actions a LEFT JOIN "user" u ON u.id = a.admin_uid
          WHERE a.video_id = ? ORDER BY a.created_at DESC LIMIT 50`,
      )
        .bind(row.video_id)
        .all<{ id: string; action: string; reason: string | null; created_at: string; admin_email: string | null }>(),
    ]);
    return c.json({
      video: toAdminVideo(c.env, row),
      reports: reports.results.map((r) => ({
        id: r.id,
        reason: r.reason,
        reasonLabel: REPORT_REASON_LABELS[r.reason as ReportReason] ?? r.reason,
        details: r.details,
        signedIn: !!r.reporter_uid,
        createdAt: r.created_at,
        resolvedAt: r.resolved_at,
        resolution: r.resolution,
      })),
      history: actions.results.map((a) => ({
        id: a.id,
        action: a.action,
        reason: a.reason,
        createdAt: a.created_at,
        adminEmail: a.admin_email,
      })),
    });
  });

  app.get("/admin/videos/:id/stream", async (c) => {
    const doc = await videoOr404(c);
    if (doc instanceof Response) return doc;
    if (doc.status !== "ready") return c.json({ error: "Video not uploaded yet" }, 404);
    // r2Key / storageId already mirror the current version's row.
    const r2Key = doc.r2Key;
    const storageId = doc.storageId ?? null;

    if (storageId) {
      try {
        const store = await storeFor(c.env, storageId);
        const location = await customObjectUrl(store, r2Key, { expiresIn: 3600, contentType: doc.contentType || "video/mp4" });
        return new Response(null, {
          status: 302,
          headers: { Location: location, "Cache-Control": "private, no-store", "Referrer-Policy": "no-referrer" },
        });
      } catch (err) {
        if (err instanceof StorageUnavailableError) {
          return c.json({ error: "Video file not available from its storage bucket" }, 502);
        }
        throw err;
      }
    }

    const range = parseRange(c.req.header("Range"));
    const object = range ? await c.env.R2.get(r2Key, { range }) : await c.env.R2.get(r2Key);
    if (!object) return c.json({ error: "Video file not found in storage" }, 404);
    const headers = new Headers({
      "Content-Type": doc.contentType || "video/mp4",
      "Accept-Ranges": "bytes",
      // Never in a shared cache: this route ignores every share gate.
      "Cache-Control": "private, no-store",
    });
    if (range) {
      // What R2 served (object.range), else what was asked, clamped to the file.
      const served = ("range" in object && object.range ? object.range : range) as R2Range;
      const offset = "suffix" in served && served.suffix !== undefined
        ? Math.max(0, object.size - served.suffix)
        : ("offset" in served ? served.offset ?? 0 : 0);
      const asked = "length" in served && served.length !== undefined ? served.length : object.size - offset;
      const length = Math.max(0, Math.min(asked, object.size - offset));
      headers.set("Content-Range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
      headers.set("Content-Length", String(length));
      return new Response(object.body, { status: 206, headers });
    }
    headers.set("Content-Length", String(object.size));
    return new Response(object.body, { status: 200, headers });
  });

  app.get("/admin/videos/:id/thumbnail", async (c) => {
    const doc = await videoOr404(c);
    if (doc instanceof Response) return doc;
    if (!doc.thumbnailType) return c.json({ error: "No thumbnail" }, 404);
    const object = await c.env.R2.get(`thumbs/${doc.videoId}`);
    if (!object) return c.json({ error: "No thumbnail" }, 404);
    return new Response(object.body, {
      headers: { "Content-Type": doc.thumbnailType, "Cache-Control": "private, max-age=300" },
    });
  });

  app.post("/admin/videos/:id/remove", async (c) => {
    const doc = await videoOr404(c);
    if (doc instanceof Response) return doc;
    const parsed = await parseJsonBody(c.req, removeBody);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    if (doc.removedAt) return c.json({ error: "Already removed" }, 409);
    await takeDownVideo(c.env, doc, c.get("user").uid, parsed.data.reason);
    return c.json({ removed: true });
  });

  app.post("/admin/videos/:id/restore", async (c) => {
    const doc = await videoOr404(c);
    if (doc instanceof Response) return doc;
    if (!doc.removedAt) return c.json({ error: "Not removed" }, 409);
    await restoreVideo(c.env, doc, c.get("user").uid);
    return c.json({ restored: true });
  });

  app.post("/admin/videos/:id/dismiss", async (c) => {
    const doc = await videoOr404(c);
    if (doc instanceof Response) return doc;
    const dismissed = await resolveReports(c.env.DB, doc.videoId, "dismissed");
    if (dismissed > 0) {
      await recordModerationAction(c.env.DB, { videoId: doc.videoId, videoOwner: doc.uid, adminUid: c.get("user").uid, action: "dismiss" });
    }
    return c.json({ dismissed });
  });

  app.delete("/admin/videos/:id", async (c) => {
    const doc = await videoOr404(c);
    if (doc instanceof Response) return doc;
    const result = await deleteVideoEverywhere(c.env, doc);
    if (!result.ok) return c.json({ error: "Failed to delete video from storage", r2Key: result.r2Key }, 500);
    // Reports stay as the record of why; the audit row outlives the video.
    await resolveReports(c.env.DB, doc.videoId, "removed");
    await recordModerationAction(c.env.DB, { videoId: doc.videoId, videoOwner: doc.uid, adminUid: c.get("user").uid, action: "delete" });
    return c.json({ deleted: true, ...(result.leftInBucket.length > 0 ? { leftInBucket: result.leftInBucket } : {}) });
  });
}

/** "bytes=a-b" / "bytes=a-" / "bytes=-n" → an R2 range, or null. */
function parseRange(header: string | undefined): R2Range | null {
  const m = header?.match(/^bytes=(\d*)-(\d*)$/);
  if (!m) return null;
  const [, start, end] = m;
  if (start === "" && end === "") return null;
  if (start === "") return { suffix: Number(end) };
  const offset = Number(start);
  return end === "" ? { offset } : { offset, length: Number(end) - offset + 1 };
}
