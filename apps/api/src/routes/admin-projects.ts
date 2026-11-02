/**
 * The admin console's Projects page (admin.capturecat.so → /projects): every
 * cloud project — each web recording, and each Mac project someone opened in
 * the web editor — and whether it was ever shared as a video. Mounted under
 * adminRoutes, so every path here is behind its role check (404 to anyone
 * who is not an admin). Read-only: the owner is the only one who changes a
 * project. Recordings that never left a Mac are not on the server at all.
 *
 * METADATA ONLY: names, owners, sizes, file lists and share links — no route
 * here reads a project's files. A project's recordings are the owner's: the
 * privacy policy says uploads are stored so share links work, with no staff
 * access, so the console never plays or downloads them (a shared video is
 * reviewed through its share, on the Videos page).
 *
 *   GET /admin/projects?filter=all|unshared|shared&q=&cursor=&limit=
 *   GET /admin/projects/:id             one project, its file list and its shares
 *
 * A project counts as shared when a shared video names it (shared_videos.
 * project_id — both apps send the project UUID when they share).
 */
import type { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { parseValue } from "../lib/validate";
import { listCloudFiles } from "../lib/cloud-projects-db";
import { CLOUD_FILE_TYPES } from "../lib/cloud-projects";
import { shareBaseURL } from "../lib/origins";
import { decodeCursor, encodeCursor } from "./admin-moderation";

type App = Hono<{ Bindings: Env; Variables: Variables }>;

export const ADMIN_PROJECTS_PAGE = { default: 50, max: 100 } as const;

const listQuery = z.object({
  filter: z.enum(["all", "unshared", "shared"]).default("all"),
  q: z.string().trim().max(200).optional(),
  cursor: z.string().max(400).optional(),
  limit: z.coerce.number().int().min(1).max(ADMIN_PROJECTS_PAGE.max).default(ADMIN_PROJECTS_PAGE.default),
});

interface AdminProjectRow {
  id: string;
  owner_uid: string;
  org_id: string | null;
  org_name: string | null;
  name: string;
  revision: number;
  total_bytes: number;
  created_at: string;
  updated_at: string;
  owner_email: string | null;
  owner_name: string | null;
  owner_blocked: number | null;
  file_count: number;
  shares: number;
  last_share_at: string | null;
}

const SHARED = `EXISTS (SELECT 1 FROM shared_videos sv WHERE sv.project_id = cp.id)`;

const SELECT = `
  SELECT cp.id, cp.owner_uid, cp.org_id, o.name AS org_name, cp.name, cp.revision, cp.total_bytes,
         cp.created_at, cp.updated_at,
         u.email AS owner_email, u.name AS owner_name, u.blocked AS owner_blocked,
         (SELECT COUNT(*) FROM cloud_project_files f WHERE f.project_id = cp.id) AS file_count,
         (SELECT COUNT(*) FROM shared_videos sv WHERE sv.project_id = cp.id) AS shares,
         (SELECT MAX(sv.created_at) FROM shared_videos sv WHERE sv.project_id = cp.id) AS last_share_at
    FROM cloud_projects cp
    LEFT JOIN "user" u ON u.id = cp.owner_uid
    LEFT JOIN "organization" o ON o.id = cp.org_id`;

function toAdminProject(r: AdminProjectRow) {
  return {
    projectId: r.id,
    name: r.name,
    owner: { id: r.owner_uid, email: r.owner_email, name: r.owner_name, blocked: r.owner_blocked === 1 },
    team: r.org_id ? { id: r.org_id, name: r.org_name } : null,
    // Revision 0 = the upload was staged but no project.json was ever saved.
    uploaded: r.revision > 0,
    revision: r.revision,
    totalBytes: r.total_bytes,
    fileCount: r.file_count,
    shares: r.shares,
    lastShareAt: r.last_share_at,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

async function counts(db: D1Database) {
  const row = await db
    .prepare(
      `SELECT COUNT(*) AS all_count,
              COALESCE(SUM(CASE WHEN ${SHARED} THEN 1 ELSE 0 END), 0) AS shared
         FROM cloud_projects cp`,
    )
    .first<{ all_count: number; shared: number }>();
  const all = row?.all_count ?? 0;
  const shared = row?.shared ?? 0;
  return { all, unshared: all - shared, shared };
}

function fileKind(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return CLOUD_FILE_TYPES[ext]?.kind ?? "data";
}

export function registerProjectAdminRoutes(app: App): void {
  app.get("/admin/projects", async (c) => {
    const parsed = parseValue(Object.fromEntries(new URL(c.req.url).searchParams), listQuery);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const { filter, q, limit } = parsed.data;

    const where: string[] = [];
    const binds: unknown[] = [];
    if (q) {
      // An exact id (either case), or a substring of the name or owner email.
      const like = `%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`;
      where.push(`(cp.id = ? OR cp.name LIKE ? ESCAPE '\\' OR u.email LIKE ? ESCAPE '\\')`);
      binds.push(q.toUpperCase(), like, like);
    }
    if (filter === "unshared") where.push(`NOT ${SHARED}`);
    if (filter === "shared") where.push(SHARED);
    const cursor = decodeCursor(parsed.data.cursor);
    if (cursor) {
      where.push(`(cp.created_at < ? OR (cp.created_at = ? AND cp.id < ?))`);
      binds.push(cursor[0], cursor[0], cursor[1]);
    }

    const sql = `${SELECT}${where.length ? ` WHERE ${where.join(" AND ")}` : ""} ORDER BY cp.created_at DESC, cp.id DESC LIMIT ?`;
    const { results } = await c.env.DB.prepare(sql)
      .bind(...binds, limit + 1)
      .all<AdminProjectRow>();
    const page = results.slice(0, limit);
    const last = page[page.length - 1];
    const nextCursor = results.length > limit && last ? encodeCursor(last.created_at, last.id) : null;

    return c.json({
      projects: page.map(toAdminProject),
      nextCursor,
      counts: await counts(c.env.DB),
    });
  });

  app.get("/admin/projects/:id", async (c) => {
    const row = await c.env.DB.prepare(`${SELECT} WHERE cp.id = ?`)
      .bind(c.req.param("id").toUpperCase())
      .first<AdminProjectRow>();
    if (!row) return c.json({ error: "Project not found" }, 404);
    const [files, videos, versions] = await Promise.all([
      listCloudFiles(c.env.DB, row.id),
      c.env.DB.prepare(
        `SELECT video_id, file_name, ai_title, status, created_at, removed_at
           FROM shared_videos WHERE project_id = ? ORDER BY created_at DESC LIMIT 50`,
      )
        .bind(row.id)
        .all<{ video_id: string; file_name: string; ai_title: string | null; status: string; created_at: string; removed_at: string | null }>(),
      c.env.DB.prepare(
        `SELECT COUNT(*) AS n,
                (SELECT client_kind FROM cloud_project_versions WHERE project_id = ?1 ORDER BY seq DESC LIMIT 1) AS last_client
           FROM cloud_project_versions WHERE project_id = ?1`,
      )
        .bind(row.id)
        .first<{ n: number; last_client: string | null }>(),
    ]);
    const fileList = files.map((f) => ({ path: f.path, bytes: f.bytes, contentType: f.contentType, kind: fileKind(f.path) }));
    return c.json({
      project: toAdminProject(row),
      files: fileList,
      videos: videos.results.map((v) => ({
        videoId: v.video_id,
        title: v.ai_title || v.file_name,
        status: v.status,
        createdAt: v.created_at,
        removed: v.removed_at !== null,
        shareUrl: `${shareBaseURL(c.env)}/share/${v.video_id}`,
      })),
      versions: versions?.n ?? 0,
      lastEditedIn: versions?.last_client === "mac" || versions?.last_client === "web" ? versions.last_client : null,
    });
  });
}
