/**
 * The changelog (migration 0037): written in the admin console, read by the
 * public site (capturecat.so/changelog, /changelog.md, /changelog.xml).
 *
 * Public, unauthenticated, published entries only:
 *
 *   GET /changelog?limit&cursor   newest first; `nextCursor` pages on
 *                                 (published_at, id), so a new entry never
 *                                 shifts a page someone is reading
 *   GET /changelog/:slug          one entry; a draft, a scheduled entry and an
 *                                 unknown slug are all the same 404
 *
 * Admin (registered onto `adminRoutes` in routes/admin.ts, so its role guard
 * applies — a non-admin gets the same 404 as for every other admin route):
 *
 *   GET    /admin/changelog                 every entry, drafts included
 *   POST   /admin/changelog                 create (a draft)
 *   PUT    /admin/changelog/:id             edit; partial body, merged over the row
 *   POST   /admin/changelog/:id/publish     { publishedAt? } — blank = now (or the
 *                                           date it already has); a future date
 *                                           schedules it
 *   POST   /admin/changelog/:id/unpublish   back to draft
 *   DELETE /admin/changelog/:id             gone (admin content, nothing refers to it)
 *
 * Nothing is sanitized here beyond length caps and shapes: the body is stored
 * as written. Rendering is where safety lives — the site's renderer
 * (apps/web/src/lib/changelog/markdown.tsx) escapes everything and links only
 * http(s) URLs, so raw HTML in a body shows as text.
 *
 * No rate limit on the public routes on purpose: the site server-renders the
 * changelog from its Worker, whose egress IPs are shared by every visitor, so
 * a per-IP limit would throttle the whole page at once. Each call is one
 * indexed D1 read.
 */
import { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { generateId } from "../lib/id";
import { parseJsonBody, parseValue } from "../lib/validate";

type App = Hono<{ Bindings: Env; Variables: Variables }>;

/** Persistence identity — never rename one (apps/web/src/lib/changelog/model.ts mirrors them). */
export const CHANGELOG_CATEGORIES = ["new", "improved", "fixed", "security"] as const;
export const CHANGELOG_PLATFORMS = ["mac", "web", "api", "agents"] as const;
export type ChangelogCategory = (typeof CHANGELOG_CATEGORIES)[number];
export type ChangelogPlatform = (typeof CHANGELOG_PLATFORMS)[number];

export const CHANGELOG_LIMITS = { slug: 80, title: 140, summary: 280, body: 50_000, version: 32 } as const;
export const CHANGELOG_PAGE = { default: 20, max: 50 } as const;

const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

/** One line of text: runs of whitespace (newlines included) become one space. */
const line = (field: string, max: number) =>
  z
    .string({ error: `${field} is required` })
    .transform((s) => s.replace(/\s+/g, " ").trim())
    .pipe(z.string().min(1, { error: `${field} is required` }).max(max, { error: `${field} is too long (max ${max})` }));

/**
 * Every field, no defaults: the PUT carries only what the console sent and
 * is merged over the stored row; the POST fills the optional ones itself.
 */
const EntryFieldsSchema = z.object({
  slug: z
    .string({ error: "slug is required" })
    .trim()
    .toLowerCase()
    .max(CHANGELOG_LIMITS.slug, { error: `slug is too long (max ${CHANGELOG_LIMITS.slug})` })
    .regex(SLUG_RE, { error: "slug must be lowercase letters, digits and single hyphens" }),
  title: line("title", CHANGELOG_LIMITS.title),
  summary: line("summary", CHANGELOG_LIMITS.summary),
  body: z
    .string()
    .max(CHANGELOG_LIMITS.body, { error: `body is too long (max ${CHANGELOG_LIMITS.body})` })
    .transform((s) => s.replace(/\r\n?/g, "\n")),
  category: z.enum(CHANGELOG_CATEGORIES, { error: `category must be one of ${CHANGELOG_CATEGORIES.join(", ")}` }),
  platforms: z
    .array(z.enum(CHANGELOG_PLATFORMS, { error: `platforms must be among ${CHANGELOG_PLATFORMS.join(", ")}` }))
    .max(CHANGELOG_PLATFORMS.length * 2)
    // Stored in the canonical order, once each, so the badges never reorder.
    .transform((list) => CHANGELOG_PLATFORMS.filter((p) => list.includes(p))),
  /** "1.3.1"; blank or null = not tied to a release. */
  version: z
    .string()
    .max(CHANGELOG_LIMITS.version, { error: `version is too long (max ${CHANGELOG_LIMITS.version})` })
    .nullable()
    .transform((v) => v?.replace(/\s+/g, " ").trim() || null),
});

const CreateSchema = z.strictObject({
  ...EntryFieldsSchema.shape,
  body: EntryFieldsSchema.shape.body.optional(),
  platforms: EntryFieldsSchema.shape.platforms.optional(),
  version: EntryFieldsSchema.shape.version.optional(),
});
const UpdateSchema = z.strictObject(EntryFieldsSchema.shape).partial();

const PublishSchema = z.strictObject({
  /** ISO 8601 with an offset, or a bare date (= 00:00 UTC that day). */
  publishedAt: z.union([z.iso.datetime({ offset: true }), z.iso.date()]).nullable().optional(),
});

const ListQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(CHANGELOG_PAGE.max).default(CHANGELOG_PAGE.default),
  cursor: z.string().max(200).optional(),
});

interface EntryRow {
  id: string;
  slug: string;
  title: string;
  summary: string;
  body: string;
  category: string;
  platforms: string;
  version: string | null;
  published_at: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
}

const COLUMNS = `e.id, e.slug, e.title, e.summary, e.body, e.category, e.platforms, e.version,
                 e.published_at, e.created_at, e.updated_at, e.created_by`;

const nowIso = () => new Date().toISOString();

function parsePlatforms(raw: string): ChangelogPlatform[] {
  try {
    const list = JSON.parse(raw) as unknown;
    return Array.isArray(list) ? CHANGELOG_PLATFORMS.filter((p) => list.includes(p)) : [];
  } catch {
    return [];
  }
}

/** The public shape: no id, no author. */
function publicEntry(r: EntryRow) {
  return {
    slug: r.slug,
    title: r.title,
    summary: r.summary,
    body: r.body,
    category: r.category as ChangelogCategory,
    platforms: parsePlatforms(r.platforms),
    version: r.version,
    publishedAt: r.published_at as string,
    updatedAt: r.updated_at,
  };
}
export type PublicChangelogEntry = ReturnType<typeof publicEntry>;

function adminEntry(r: EntryRow & { created_by_email?: string | null }, now = nowIso()) {
  return {
    id: r.id,
    slug: r.slug,
    title: r.title,
    summary: r.summary,
    body: r.body,
    category: r.category as ChangelogCategory,
    platforms: parsePlatforms(r.platforms),
    version: r.version,
    publishedAt: r.published_at,
    status: !r.published_at ? "draft" : r.published_at > now ? "scheduled" : "published",
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    createdBy: r.created_by_email ?? r.created_by,
  } as const;
}
export type AdminChangelogEntry = ReturnType<typeof adminEntry>;

// ── cursor: base64url("<published_at>~<id>") ───────────────────────────────

export function encodeCursor(publishedAt: string, id: string): string {
  return btoa(`${publishedAt}~${id}`).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function decodeCursor(cursor: string): { publishedAt: string; id: string } | null {
  try {
    const raw = atob(cursor.replace(/-/g, "+").replace(/_/g, "/"));
    const at = raw.lastIndexOf("~");
    const publishedAt = raw.slice(0, at);
    const id = raw.slice(at + 1);
    if (at <= 0 || !/^[a-z0-9]{1,64}$/.test(id) || Number.isNaN(Date.parse(publishedAt))) return null;
    return { publishedAt, id };
  } catch {
    return null;
  }
}

const isUniqueViolation = (err: unknown) => /UNIQUE constraint failed/i.test(err instanceof Error ? err.message : String(err));
const slugTaken = (slug: string) => `The slug "${slug}" is already used by another entry.`;

async function slugOwner(db: D1Database, slug: string): Promise<string | null> {
  const row = await db.prepare(`SELECT id FROM changelog_entries WHERE slug = ?`).bind(slug).first<{ id: string }>();
  return row?.id ?? null;
}

async function entryById(db: D1Database, id: string) {
  return db
    .prepare(
      `SELECT ${COLUMNS}, u.email AS created_by_email
         FROM changelog_entries e LEFT JOIN "user" u ON u.id = e.created_by
        WHERE e.id = ?`,
    )
    .bind(id)
    .first<EntryRow & { created_by_email: string | null }>();
}

/** `publishedAt` → the stored ISO instant. A bare date is 00:00 UTC that day. */
function toInstant(value: string): string {
  return new Date(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T00:00:00Z` : value).toISOString();
}

// ── public ──────────────────────────────────────────────────────────────────

export const changelogRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

changelogRoutes.get("/changelog", async (c) => {
  const parsed = parseValue(c.req.query(), ListQuerySchema);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const { limit, cursor: rawCursor } = parsed.data;
  const cursor = rawCursor ? decodeCursor(rawCursor) : null;
  if (rawCursor && !cursor) return c.json({ error: "cursor: Invalid cursor" }, 400);

  const now = nowIso();
  const { results } = await c.env.DB.prepare(
    `SELECT ${COLUMNS} FROM changelog_entries e
      WHERE e.published_at IS NOT NULL AND e.published_at <= ?
        ${cursor ? "AND (e.published_at < ? OR (e.published_at = ? AND e.id < ?))" : ""}
      ORDER BY e.published_at DESC, e.id DESC
      LIMIT ?`,
  )
    .bind(now, ...(cursor ? [cursor.publishedAt, cursor.publishedAt, cursor.id] : []), limit + 1)
    .all<EntryRow>();

  const rows = results ?? [];
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return c.json(
    {
      entries: page.map(publicEntry),
      nextCursor: rows.length > limit && last ? encodeCursor(last.published_at as string, last.id) : null,
    },
    200,
    { "Cache-Control": "public, max-age=60" },
  );
});

changelogRoutes.get("/changelog/:slug", async (c) => {
  const slug = c.req.param("slug");
  if (slug.length > CHANGELOG_LIMITS.slug || !SLUG_RE.test(slug)) return c.json({ error: "Not found" }, 404);
  const row = await c.env.DB.prepare(
    `SELECT ${COLUMNS} FROM changelog_entries e
      WHERE e.slug = ? AND e.published_at IS NOT NULL AND e.published_at <= ?`,
  )
    .bind(slug, nowIso())
    .first<EntryRow>();
  if (!row) return c.json({ error: "Not found" }, 404);
  return c.json({ entry: publicEntry(row) }, 200, { "Cache-Control": "public, max-age=60" });
});

// ── admin ───────────────────────────────────────────────────────────────────

export function registerChangelogAdminRoutes(app: App): void {
  app.get("/admin/changelog", async (c) => {
    // Drafts first (most recently touched on top), then everything with a
    // date — scheduled ones lead because their dates are in the future.
    const { results } = await c.env.DB.prepare(
      `SELECT ${COLUMNS}, u.email AS created_by_email
         FROM changelog_entries e LEFT JOIN "user" u ON u.id = e.created_by
        ORDER BY (e.published_at IS NULL) DESC, COALESCE(e.published_at, e.updated_at) DESC, e.id DESC
        LIMIT 1000`,
    ).all<EntryRow & { created_by_email: string | null }>();
    const now = nowIso();
    return c.json({ entries: (results ?? []).map((r) => adminEntry(r, now)) });
  });

  app.post("/admin/changelog", async (c) => {
    const parsed = await parseJsonBody(c.req, CreateSchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const input = parsed.data;
    if (await slugOwner(c.env.DB, input.slug)) return c.json({ error: slugTaken(input.slug) }, 409);

    const id = generateId(16);
    const now = nowIso();
    try {
      await c.env.DB.prepare(
        `INSERT INTO changelog_entries
           (id, slug, title, summary, body, category, platforms, version, published_at, created_at, updated_at, created_by)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)`,
      )
        .bind(
          id,
          input.slug,
          input.title,
          input.summary,
          input.body ?? "",
          input.category,
          JSON.stringify(input.platforms ?? []),
          input.version ?? null,
          now,
          now,
          c.get("user").uid,
        )
        .run();
    } catch (err) {
      // Two saves racing for one slug: the UNIQUE index decides.
      if (isUniqueViolation(err)) return c.json({ error: slugTaken(input.slug) }, 409);
      throw err;
    }
    return c.json({ entry: adminEntry((await entryById(c.env.DB, id))!) }, 201);
  });

  app.put("/admin/changelog/:id", async (c) => {
    const id = c.req.param("id");
    const parsed = await parseJsonBody(c.req, UpdateSchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const row = await entryById(c.env.DB, id);
    if (!row) return c.json({ error: "Entry not found" }, 404);

    const patch = parsed.data;
    const next = {
      slug: patch.slug ?? row.slug,
      title: patch.title ?? row.title,
      summary: patch.summary ?? row.summary,
      body: patch.body ?? row.body,
      category: patch.category ?? row.category,
      platforms: patch.platforms ? JSON.stringify(patch.platforms) : row.platforms,
      version: patch.version !== undefined ? patch.version : row.version,
    };
    if (next.slug !== row.slug) {
      const owner = await slugOwner(c.env.DB, next.slug);
      if (owner && owner !== id) return c.json({ error: slugTaken(next.slug) }, 409);
    }
    try {
      await c.env.DB.prepare(
        `UPDATE changelog_entries
            SET slug = ?, title = ?, summary = ?, body = ?, category = ?, platforms = ?, version = ?, updated_at = ?
          WHERE id = ?`,
      )
        .bind(next.slug, next.title, next.summary, next.body, next.category, next.platforms, next.version, nowIso(), id)
        .run();
    } catch (err) {
      if (isUniqueViolation(err)) return c.json({ error: slugTaken(next.slug) }, 409);
      throw err;
    }
    return c.json({ entry: adminEntry((await entryById(c.env.DB, id))!) });
  });

  app.post("/admin/changelog/:id/publish", async (c) => {
    const id = c.req.param("id");
    const parsed = await parseJsonBody(c.req, PublishSchema, { emptyOnInvalidJson: true });
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const row = await entryById(c.env.DB, id);
    if (!row) return c.json({ error: "Entry not found" }, 404);

    // Publishing twice without a date keeps the date it has, so a re-save
    // never bumps an old entry to the top of the feed.
    const publishedAt = parsed.data.publishedAt ? toInstant(parsed.data.publishedAt) : row.published_at ?? nowIso();
    await c.env.DB.prepare(`UPDATE changelog_entries SET published_at = ?, updated_at = ? WHERE id = ?`)
      .bind(publishedAt, nowIso(), id)
      .run();
    return c.json({ entry: adminEntry((await entryById(c.env.DB, id))!) });
  });

  app.post("/admin/changelog/:id/unpublish", async (c) => {
    const id = c.req.param("id");
    const res = await c.env.DB.prepare(`UPDATE changelog_entries SET published_at = NULL, updated_at = ? WHERE id = ?`)
      .bind(nowIso(), id)
      .run();
    if ((res.meta?.changes ?? 0) === 0) return c.json({ error: "Entry not found" }, 404);
    return c.json({ entry: adminEntry((await entryById(c.env.DB, id))!) });
  });

  app.delete("/admin/changelog/:id", async (c) => {
    const id = c.req.param("id");
    const res = await c.env.DB.prepare(`DELETE FROM changelog_entries WHERE id = ?`).bind(id).run();
    if ((res.meta?.changes ?? 0) === 0) return c.json({ error: "Entry not found" }, 404);
    return c.json({ id });
  });
}
