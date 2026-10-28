/**
 * The changelog through the WHOLE Worker (src/index.ts — its CORS, its
 * mounts, requireAuth and the admin role gate), the real migrations
 * (node:sqlite, 0037 included) and a fake session (`Bearer <uid>`).
 *
 * What must hold: only admins write; drafts and scheduled entries are never
 * public; the public feed is newest first and pages without gaps or repeats;
 * slugs are unique; the web model mirrors the API's category/platform lists.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { CHANGELOG_CATEGORIES, CHANGELOG_LIMITS, CHANGELOG_PLATFORMS, decodeCursor, encodeCursor } from "./changelog";
import * as webModel from "../../../web/src/lib/changelog/model";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });
vi.stubGlobal("fetch", vi.fn(async () => new Response("offline test", { status: 500 })));

const { default: worker } = await import("../index");

const ADMIN = "admin-user";
const USER = "plain-user";
const DAY = 86_400_000;
let db: TestD1;
let env: Env;

function addUser(id: string, email: string, role = "user") {
  const iso = new Date().toISOString();
  db.query(
    `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked, role)
     VALUES (?, ?, ?, 1, ?, ?, 0, 0, ?)`,
    id, email.split("@")[0], email, iso, iso, role,
  );
}

beforeEach(() => {
  db = createTestD1();
  env = { DB: db, BETTER_AUTH_URL: "http://localhost:8787" } as unknown as Env;
  addUser(ADMIN, "owner@test.local", "admin");
  addUser(USER, "someone@test.local");
});

function call(method: string, path: string, body?: unknown, as: string | null = ADMIN, headers: Record<string, string> = {}) {
  return worker.fetch(
    new Request(`http://localhost:8787/api${path}`, {
      method,
      headers: {
        ...(as ? { Authorization: `Bearer ${as}` } : {}),
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        ...headers,
      },
      ...(body === undefined ? {} : { body: typeof body === "string" ? body : JSON.stringify(body) }),
    }),
    env,
    { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext,
  );
}

async function ok<T = Record<string, any>>(res: Response | Promise<Response>, status = 200): Promise<T> {
  const r = await res;
  const body = await r.json();
  expect(r.status, JSON.stringify(body)).toBe(status);
  return body as T;
}

const draft = (over: Record<string, unknown> = {}) => ({
  slug: "agents-share-links",
  title: "Agents can publish share links",
  summary: "An agent asks first; you approve from the link.",
  body: "## Details\n\n- One\n- Two",
  category: "new",
  platforms: ["agents", "web"],
  version: "1.3.1",
  ...over,
});

async function create(over: Record<string, unknown> = {}) {
  return (await ok<{ entry: Record<string, any> }>(call("POST", "/admin/changelog", draft(over)), 201)).entry;
}
async function publish(id: string, publishedAt?: string) {
  return (await ok<{ entry: Record<string, any> }>(call("POST", `/admin/changelog/${id}/publish`, publishedAt ? { publishedAt } : {}))).entry;
}
const publicList = (qs = "") => ok<{ entries: Record<string, any>[]; nextCursor: string | null }>(call("GET", `/changelog${qs}`, undefined, null));

describe("admin-only writes", () => {
  it("hides every admin route from a signed-in non-admin (404) and asks a stranger to sign in (401)", async () => {
    const entry = await create();
    const attempts: Array<[string, string, unknown?]> = [
      ["GET", "/admin/changelog"],
      ["POST", "/admin/changelog", draft({ slug: "other" })],
      ["PUT", `/admin/changelog/${entry.id}`, { title: "Hijacked" }],
      ["POST", `/admin/changelog/${entry.id}/publish`, {}],
      ["POST", `/admin/changelog/${entry.id}/unpublish`, {}],
      ["DELETE", `/admin/changelog/${entry.id}`],
    ];
    for (const [method, path, body] of attempts) {
      expect((await call(method, path, body, USER)).status, `${method} ${path} as user`).toBe(404);
      // (from the admin console's own origin, so requireAuth's CSRF gate passes and the session check answers)
      expect((await call(method, path, body, null, { Origin: "http://localhost:3300" })).status, `${method} ${path} signed out`).toBe(401);
    }
    const [row] = db.query(`SELECT title, published_at FROM changelog_entries`);
    expect(row).toEqual({ title: "Agents can publish share links", published_at: null });
    expect(db.query(`SELECT COUNT(*) AS n FROM changelog_entries`)[0]).toEqual({ n: 1 });
  });

  it("refuses a cookie-authenticated write from a foreign origin (requireAuth's CSRF gate)", async () => {
    const r = await call("POST", "/admin/changelog", draft(), null, { Cookie: "better-auth.session_token=x", Origin: "https://evil.example" });
    expect(r.status).toBe(403);
  });
});

describe("drafts are never public", () => {
  it("create → draft; publish → public; unpublish → gone; delete → gone", async () => {
    const entry = await create();
    expect(entry).toMatchObject({ status: "draft", publishedAt: null, createdBy: "owner@test.local", platforms: ["web", "agents"] });
    expect((await publicList()).entries).toEqual([]);
    expect((await call("GET", "/changelog/agents-share-links", undefined, null)).status).toBe(404);

    const published = await publish(entry.id);
    expect(published.status).toBe("published");
    const list = await publicList();
    expect(list.entries.map((e) => e.slug)).toEqual(["agents-share-links"]);
    // The public shape: no id, no author.
    expect(Object.keys(list.entries[0]).sort()).toEqual(
      ["body", "category", "platforms", "publishedAt", "slug", "summary", "title", "updatedAt", "version"].sort(),
    );
    const one = await ok(call("GET", "/changelog/agents-share-links", undefined, null));
    expect(one.entry).toMatchObject({ slug: "agents-share-links", version: "1.3.1", body: "## Details\n\n- One\n- Two" });

    await ok(call("POST", `/admin/changelog/${entry.id}/unpublish`, {}));
    expect((await publicList()).entries).toEqual([]);
    expect((await call("GET", "/changelog/agents-share-links", undefined, null)).status).toBe(404);

    await publish(entry.id);
    expect(await ok(call("DELETE", `/admin/changelog/${entry.id}`))).toEqual({ id: entry.id });
    expect((await publicList()).entries).toEqual([]);
    expect((await call("GET", "/changelog/agents-share-links", undefined, null)).status).toBe(404);
    expect((await call("DELETE", `/admin/changelog/${entry.id}`)).status).toBe(404);
  });

  it("a future date schedules: not public until then, 'scheduled' in admin", async () => {
    const entry = await create();
    const future = new Date(Date.now() + 3 * DAY).toISOString();
    expect((await publish(entry.id, future)).status).toBe("scheduled");
    expect((await publicList()).entries).toEqual([]);
    expect((await call("GET", "/changelog/agents-share-links", undefined, null)).status).toBe(404);
    const admin = await ok(call("GET", "/admin/changelog"));
    expect(admin.entries.map((e: any) => e.status)).toEqual(["scheduled"]);

    // Time passes (the stored date moves into the past): it is public, unchanged.
    db.query(`UPDATE changelog_entries SET published_at = ? WHERE id = ?`, new Date(Date.now() - 1000).toISOString(), entry.id);
    expect((await publicList()).entries).toHaveLength(1);
  });

  it("re-publishing keeps the date; a bare date is 00:00 UTC; nonsense is a 400", async () => {
    const entry = await create();
    const first = await publish(entry.id, "2026-10-01");
    expect(first.publishedAt).toBe("2026-10-01T00:00:00.000Z");
    expect((await publish(entry.id)).publishedAt).toBe("2026-10-01T00:00:00.000Z");
    expect((await publish(entry.id, "2026-09-30T18:00:00+01:00")).publishedAt).toBe("2026-09-30T17:00:00.000Z");
    expect((await call("POST", `/admin/changelog/${entry.id}/publish`, { publishedAt: "next tuesday" })).status).toBe(400);
    expect((await call("POST", `/admin/changelog/${entry.id}/publish`, { publishedAt: "2026-10-01", extra: 1 })).status).toBe(400);
    expect((await call("POST", `/admin/changelog/nope/publish`, {})).status).toBe(404);
    expect((await call("POST", `/admin/changelog/nope/unpublish`, {})).status).toBe(404);
  });
});

describe("the public feed", () => {
  async function seed() {
    // Out of order on purpose, plus two at the same instant (id breaks the tie).
    const dates = ["2026-08-15", "2026-10-20", "2026-09-01", "2026-10-28", "2026-10-02", "2026-10-02", "2026-07-04"];
    for (const [i, d] of dates.entries()) {
      const e = await create({ slug: `entry-${i}`, title: `Entry ${i}` });
      await publish(e.id, d);
    }
    await create({ slug: "still-a-draft" });
    const sameDay = db.query<{ id: string; slug: string }>(
      `SELECT id, slug FROM changelog_entries WHERE published_at = '2026-10-02T00:00:00.000Z' ORDER BY id DESC`,
    );
    return ["entry-3", "entry-1", ...sameDay.map((r) => r.slug), "entry-2", "entry-0", "entry-6"];
  }

  it("is newest first, drafts excluded", async () => {
    const expected = await seed();
    const { entries, nextCursor } = await publicList();
    expect(entries.map((e) => e.slug)).toEqual(expected);
    expect(nextCursor).toBeNull();
  });

  it("pages by cursor with no gaps or repeats, then stops", async () => {
    const expected = await seed();
    const seen: string[] = [];
    let cursor: string | null = null;
    let pages = 0;
    do {
      const page = await publicList(`?limit=2${cursor ? `&cursor=${cursor}` : ""}`);
      expect(page.entries.length).toBeLessThanOrEqual(2);
      seen.push(...page.entries.map((e) => e.slug));
      cursor = page.nextCursor;
      pages++;
    } while (cursor && pages < 10);
    expect(seen).toEqual(expected);
    expect(pages).toBe(4);

    // A page stays put when something newer is published meanwhile.
    const first = await publicList("?limit=3");
    const fresh = await create({ slug: "brand-new" });
    await publish(fresh.id);
    const second = await publicList(`?limit=3&cursor=${first.nextCursor}`);
    expect(second.entries.map((e) => e.slug)).toEqual(expected.slice(3, 6));
  });

  it("validates limit and cursor", async () => {
    await seed();
    expect((await call("GET", "/changelog?limit=0", undefined, null)).status).toBe(400);
    expect((await call("GET", "/changelog?limit=51", undefined, null)).status).toBe(400);
    expect((await call("GET", "/changelog?limit=abc", undefined, null)).status).toBe(400);
    expect((await call("GET", "/changelog?cursor=not-a-cursor", undefined, null)).status).toBe(400);
    expect((await publicList("?limit=50")).entries).toHaveLength(7);
    expect(decodeCursor(encodeCursor("2026-10-02T00:00:00.000Z", "abc123"))).toEqual({ publishedAt: "2026-10-02T00:00:00.000Z", id: "abc123" });
    expect(decodeCursor(btoa("garbage~UPPER"))).toBeNull();
  });

  it("is readable cross-origin from the site and cacheable briefly", async () => {
    const r = await call("GET", "/changelog", undefined, null, { Origin: "http://localhost:3200" });
    expect(r.status).toBe(200);
    expect(r.headers.get("Access-Control-Allow-Origin")).toBe("http://localhost:3200");
    expect(r.headers.get("Cache-Control")).toBe("public, max-age=60");
    expect((await call("GET", "/changelog/Not_A_Slug", undefined, null)).status).toBe(404);
  });
});

describe("slugs and fields", () => {
  it("slugs are unique on create and on edit", async () => {
    const a = await create();
    const b = await create({ slug: "second-entry" });
    const dupe = await call("POST", "/admin/changelog", draft());
    expect(dupe.status).toBe(409);
    expect(((await dupe.json()) as { error: string }).error).toMatch(/already used/);
    expect((await call("PUT", `/admin/changelog/${b.id}`, { slug: "agents-share-links" })).status).toBe(409);
    // Keeping its own slug, or taking a free one, is fine.
    await ok(call("PUT", `/admin/changelog/${a.id}`, { slug: "agents-share-links", title: "Renamed" }));
    const moved = (await ok(call("PUT", `/admin/changelog/${b.id}`, { slug: "Second-Entry-Renamed" }))).entry;
    expect(moved.slug).toBe("second-entry-renamed");
    // The UNIQUE index backs the pre-check.
    expect(() => db.query(`UPDATE changelog_entries SET slug = 'agents-share-links' WHERE id = ?`, b.id)).toThrow(/UNIQUE/);
  });

  it("normalises and caps fields; unknown keys are refused", async () => {
    const e = await create({
      title: "  Two\n lines  ",
      summary: "One\nline\n\nonly",
      platforms: ["agents", "mac", "agents"],
      version: "   ",
      body: "a\r\nb",
    });
    expect(e).toMatchObject({ title: "Two lines", summary: "One line only", platforms: ["mac", "agents"], version: null, body: "a\nb" });

    const bad: Array<Record<string, unknown>> = [
      { slug: "Has Spaces" },
      { slug: "trailing-" },
      { slug: "a".repeat(CHANGELOG_LIMITS.slug + 1) },
      { title: "" },
      { title: "x".repeat(CHANGELOG_LIMITS.title + 1) },
      { summary: "   " },
      { summary: "x".repeat(CHANGELOG_LIMITS.summary + 1) },
      { body: "x".repeat(CHANGELOG_LIMITS.body + 1) },
      { category: "breaking" },
      { platforms: ["windows"] },
      { version: "1".repeat(CHANGELOG_LIMITS.version + 1) },
      { extra: true },
    ];
    for (const [i, over] of bad.entries()) {
      const r = await call("POST", "/admin/changelog", draft({ slug: `ok-${i}`, ...over }));
      expect(r.status, JSON.stringify(over)).toBe(400);
    }
    expect((await call("POST", "/admin/changelog", "{not json")).status).toBe(400);
    expect((await call("PUT", `/admin/changelog/${e.id}`, { createdBy: "someone" })).status).toBe(400);
    expect((await call("PUT", `/admin/changelog/missing`, { title: "x" })).status).toBe(404);

    // Body and the optional fields default on create.
    const minimal = await ok(call("POST", "/admin/changelog", { slug: "minimal", title: "T", summary: "S", category: "fixed" }), 201);
    expect(minimal.entry).toMatchObject({ body: "", platforms: [], version: null, category: "fixed" });
  });

  it("a partial edit changes only what it carries", async () => {
    const e = await create();
    const edited = (await ok(call("PUT", `/admin/changelog/${e.id}`, { category: "improved", version: null }))).entry;
    expect(edited).toMatchObject({ title: e.title, summary: e.summary, body: e.body, platforms: e.platforms, category: "improved", version: null });
    expect(edited.updatedAt >= e.updatedAt).toBe(true);
  });

  it("the admin list shows drafts first, then by date", async () => {
    const old = await create({ slug: "old" });
    await publish(old.id, "2026-01-01");
    const recent = await create({ slug: "recent" });
    await publish(recent.id, "2026-10-01");
    await create({ slug: "a-draft" });
    const { entries } = await ok(call("GET", "/admin/changelog"));
    expect(entries.map((x: any) => [x.slug, x.status])).toEqual([
      ["a-draft", "draft"],
      ["recent", "published"],
      ["old", "published"],
    ]);
  });
});

describe("the web model mirrors the API", () => {
  it("has the same categories, platforms and caps", () => {
    expect([...webModel.CHANGELOG_CATEGORIES]).toEqual([...CHANGELOG_CATEGORIES]);
    expect([...webModel.CHANGELOG_PLATFORMS]).toEqual([...CHANGELOG_PLATFORMS]);
    expect(webModel.CHANGELOG_LIMITS).toEqual(CHANGELOG_LIMITS);
    expect(Object.keys(webModel.CATEGORY_META)).toEqual([...CHANGELOG_CATEGORIES]);
    expect(Object.keys(webModel.PLATFORM_LABELS)).toEqual([...CHANGELOG_PLATFORMS]);
  });

  it("the editor's suggested slugs pass the API's slug rule", async () => {
    for (const title of ["Agents can publish share links — and must ask you first", "1.3.1: fixes", "Café & crème"]) {
      const slug = webModel.slugify(title);
      await ok(call("POST", "/admin/changelog", draft({ slug, title })), 201);
    }
  });
});
