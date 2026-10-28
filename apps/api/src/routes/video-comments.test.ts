/**
 * Route-level tests for share-page comments (migration 0031): threads,
 * annotations, signed-in identity, and the gates every comment request
 * passes — against the REAL migrations and SQL (node:sqlite).
 *
 * Mocked: the Better Auth session store. `Authorization: Bearer <uid>` or a
 * `cc_test_session=<uid>` cookie names the caller (the cookie form exists so
 * the cross-site cookie rule can be exercised); the user row is read from D1.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";

vi.mock("../lib/auth", () => ({
  getAuth(env: Env) {
    return {
      api: {
        getSession: async ({ headers }: { headers: Headers }) => {
          const bearer = headers.get("Authorization")?.replace(/^Bearer /, "");
          const cookie = /cc_test_session=([^;]+)/.exec(headers.get("Cookie") ?? "")?.[1];
          const uid = bearer || cookie;
          if (!uid) return null;
          const user = await env.DB.prepare(
            `SELECT id, email, name, image, tester, blocked FROM "user" WHERE id = ?`
          )
            .bind(uid)
            .first<{ id: string; email: string; name: string; image: string | null; tester: number; blocked: number }>();
          if (!user) return null;
          return {
            session: { expiresAt: new Date(Date.now() + 86_400_000) },
            user: { ...user, tester: user.tester === 1, blocked: user.blocked === 1 },
          };
        },
      },
    };
  },
}));
vi.mock("../lib/presign", () => ({
  createPresignedUploadUrl: vi.fn(),
  createPresignedDownloadUrl: vi.fn(),
  headR2ObjectMeta: vi.fn(),
  headR2Object: vi.fn(),
}));
// Workers Cache API stand-in: always-miss, so every limiter/plan read takes
// its D1 path.
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });

const { videoRoutes } = await import("./video");

const OWNER = "owner";
const VIEWER = "viewer";
const BLOCKED = "blocked";
const OWNER_AVATAR = "https://avatars.test/owner.png";

let db: TestD1;
let env: Env;
let app: Hono<{ Bindings: Env; Variables: Variables }>;
let ipSeq = 0;

function insertVideo(videoId: string, extra: Record<string, unknown> = {}) {
  const row: Record<string, unknown> = {
    video_id: videoId,
    uid: OWNER,
    file_name: `${videoId}.mp4`,
    r2_key: `videos/${videoId}.mp4`,
    url: `https://x.test/${videoId}`,
    status: "ready",
    created_at: new Date().toISOString(),
    duration_seconds: 60,
    comments_enabled: 1,
    ...extra,
  };
  const cols = Object.keys(row);
  db.query(
    `INSERT INTO shared_videos (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`,
    ...cols.map((c) => row[c])
  );
}

beforeEach(() => {
  db = createTestD1();
  env = {
    DB: db,
    BETTER_AUTH_URL: "https://api.capturecat.so",
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret",
  } as unknown as Env;
  app = new Hono<{ Bindings: Env; Variables: Variables }>();
  app.route("/api", videoRoutes);
  const now = new Date().toISOString();
  const users: Array<[string, string, string | null, number, number]> = [
    // id, name, image, tester (→ a plan with comments), blocked
    [OWNER, "Olive Owner", OWNER_AVATAR, 1, 0],
    [VIEWER, "Vic Viewer", "http://insecure.test/v.png", 0, 0],
    [BLOCKED, "Bad Actor", null, 0, 1],
  ];
  for (const [id, name, image, tester, blocked] of users) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, image, createdAt, updatedAt, tester, blocked)
       VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?)`,
      id, name, `${id}@test.local`, image, now, now, tester, blocked
    );
  }
  insertVideo("vid1");
  insertVideo("vid2");
});

/** Each call from a fresh IP unless pinned — the per-IP limiter is its own test. */
function call(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = {}
) {
  const h: Record<string, string> = { "CF-Connecting-IP": `10.0.0.${++ipSeq % 250}`, ...headers };
  let payload: string | undefined;
  if (typeof body === "string") payload = body;
  else if (body !== undefined) {
    payload = JSON.stringify(body);
    h["Content-Type"] = "application/json";
  }
  return app.request(`/api${path}`, { method, headers: h, body: payload }, env);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- asserted field by field
async function json<T = any>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

const drawing = {
  v: 1,
  shapes: [
    { kind: "arrow", color: "#FBBF24", size: 2, from: [0.1, 0.1], to: [0.4, 0.5] },
    { kind: "text", color: "#ffffff", size: 2, at: [0.5, 0.5], text: "here" },
  ],
};

async function post(videoId: string, body: Record<string, unknown>, headers: Record<string, string> = {}) {
  return call("POST", `/video/${videoId}/comments`, body, headers);
}

describe("POST comments — annotations", () => {
  it("stores a canonical annotation and returns it", async () => {
    const res = await post("vid1", { body: "Look", videoTime: 12.5, annotation: drawing });
    expect(res.status).toBe(200);
    const { comment } = await json(res);
    expect(comment).toMatchObject({
      parentId: null,
      authorName: "Anonymous",
      authorImage: null,
      isOwner: false,
      body: "Look",
      videoTime: 12.5,
    });
    expect(comment.annotation.shapes[0].color).toBe("#fbbf24");
    const [row] = db.query<{ annotation_json: string; author_uid: string | null }>(
      "SELECT annotation_json, author_uid FROM video_comments WHERE comment_id = ?",
      comment.commentId
    );
    expect(JSON.parse(row.annotation_json)).toEqual(comment.annotation);
    expect(row.author_uid).toBeNull();
  });

  it("refuses an invalid annotation and stores nothing", async () => {
    const res = await post("vid1", {
      body: "x",
      annotation: { v: 1, shapes: [{ kind: "script", color: "#ffffff", size: 1, at: [0, 0] }] },
    });
    expect(res.status).toBe(400);
    expect((await json(res)).error).toContain("Invalid drawing");
    expect(db.query("SELECT * FROM video_comments")).toHaveLength(0);
  });

  it("refuses an oversized request body before parsing it", async () => {
    const huge = JSON.stringify({ body: "x", annotation: { v: 1, shapes: [], pad: "x".repeat(200_000) } });
    const res = await call("POST", "/video/vid1/comments", huge, { "Content-Type": "application/json" });
    expect(res.status).toBe(413);
  });

  it("still requires a 1–500 character body", async () => {
    expect((await post("vid1", { body: "  ", annotation: drawing })).status).toBe(400);
    expect((await post("vid1", { body: "x".repeat(501) })).status).toBe(400);
  });
});

describe("POST comments — threads", () => {
  async function topLevel(videoId = "vid1", time = 20) {
    const res = await post(videoId, { body: "top", videoTime: time });
    expect(res.status).toBe(200);
    return (await json(res)).comment.commentId as string;
  }

  it("a reply lands under its parent at the parent's time", async () => {
    const parent = await topLevel("vid1", 20);
    const res = await post("vid1", { body: "reply", parentId: parent, videoTime: 55 });
    expect(res.status).toBe(200);
    const { comment } = await json(res);
    expect(comment.parentId).toBe(parent);
    expect(comment.videoTime).toBe(20);
  });

  it("refuses a reply to a reply", async () => {
    const parent = await topLevel();
    const reply = (await json(await post("vid1", { body: "r1", parentId: parent }))).comment.commentId;
    const res = await post("vid1", { body: "r2", parentId: reply });
    expect(res.status).toBe(400);
  });

  it("refuses a parent on another video like a missing one", async () => {
    const elsewhere = await topLevel("vid2");
    const cross = await post("vid1", { body: "r", parentId: elsewhere });
    const missing = await post("vid1", { body: "r", parentId: "zzzzzzzzzz" });
    expect(cross.status).toBe(404);
    expect(missing.status).toBe(404);
    expect(await json(cross)).toEqual(await json(missing));
    const malformed = await post("vid1", { body: "r", parentId: "../../etc" });
    expect(malformed.status).toBe(404);
  });

  it("refuses a drawing on a reply", async () => {
    const parent = await topLevel();
    const res = await post("vid1", { body: "r", parentId: parent, annotation: drawing });
    expect(res.status).toBe(400);
  });
});

describe("identity — from the session only", () => {
  it("the owner's comment is marked, named and pictured from the session", async () => {
    const res = await post(
      "vid1",
      { body: "Thanks!", authorName: "Someone Else", authorImage: "https://evil.test/x.png" },
      { Authorization: `Bearer ${OWNER}` }
    );
    const { comment } = await json(res);
    expect(comment).toMatchObject({ isOwner: true, authorName: "Olive Owner", authorImage: OWNER_AVATAR });
  });

  it("a signed-in non-owner is not the owner; a non-https session image is dropped", async () => {
    const { comment } = await json(await post("vid1", { body: "hi" }, { Authorization: `Bearer ${VIEWER}` }));
    expect(comment).toMatchObject({ isOwner: false, authorName: "Vic Viewer", authorImage: null });
  });

  it("a client-sent authorImage is never stored for an anonymous viewer", async () => {
    const { comment } = await json(
      await post("vid1", { body: "hi", authorName: "Olive Owner", authorImage: OWNER_AVATAR })
    );
    // Same typed name as the owner — but no badge and no picture.
    expect(comment).toMatchObject({ isOwner: false, authorName: "Olive Owner", authorImage: null });
  });

  it("a blocked account posts anonymously-shaped (no identity attached)", async () => {
    const { comment } = await json(
      await post("vid1", { body: "hi", authorName: "typed" }, { Authorization: `Bearer ${BLOCKED}` })
    );
    expect(comment).toMatchObject({ authorName: "typed", isOwner: false });
  });

  it("a session cookie identifies the poster only from a trusted origin", async () => {
    const trusted = await json(
      await post("vid1", { body: "a" }, { Cookie: `cc_test_session=${OWNER}`, Origin: "https://capturecat.so" })
    );
    expect(trusted.comment.isOwner).toBe(true);
    const crossSite = await json(
      await post("vid1", { body: "b" }, { Cookie: `cc_test_session=${OWNER}`, Origin: "https://evil.test" })
    );
    expect(crossSite.comment).toMatchObject({ isOwner: false, authorName: "Anonymous", authorImage: null });
    const noOrigin = await json(await post("vid1", { body: "c" }, { Cookie: `cc_test_session=${OWNER}` }));
    expect(noOrigin.comment.isOwner).toBe(false);
  });
});

describe("GET comments", () => {
  it("returns the flat thread list and who is viewing", async () => {
    const parent = (await json(await post("vid1", { body: "top", videoTime: 5, annotation: drawing }))).comment
      .commentId;
    await post("vid1", { body: "owner reply", parentId: parent }, { Authorization: `Bearer ${OWNER}` });
    // An old (pre-0031-shaped) row renders unchanged.
    db.query(
      `INSERT INTO video_comments (comment_id, video_id, author_name, body, video_time, created_at)
       VALUES ('legacy0001', 'vid1', 'Old', 'old comment', 1, '2026-01-01T00:00:00.000Z')`
    );

    const anon = await json(await call("GET", "/video/vid1/comments"));
    expect(anon.viewer).toBeNull();
    expect(anon.comments.map((c: { body: string }) => c.body)).toEqual(["old comment", "top", "owner reply"]);
    expect(anon.comments[0]).toEqual({
      commentId: "legacy0001",
      parentId: null,
      authorName: "Old",
      authorImage: null,
      isOwner: false,
      body: "old comment",
      videoTime: 1,
      createdAt: "2026-01-01T00:00:00.000Z",
      annotation: null,
    });
    expect(anon.comments[1].annotation.shapes).toHaveLength(2);
    expect(anon.comments[2]).toMatchObject({ parentId: parent, isOwner: true });
    expect(JSON.stringify(anon)).not.toContain(OWNER + '"'); // no uid leaks

    const asOwner = await json(await call("GET", "/video/vid1/comments", undefined, { Authorization: `Bearer ${OWNER}` }));
    expect(asOwner.viewer).toEqual({ name: "Olive Owner", image: OWNER_AVATAR, isOwner: true });
    const asViewer = await json(await call("GET", "/video/vid1/comments", undefined, { Authorization: `Bearer ${VIEWER}` }));
    expect(asViewer.viewer).toEqual({ name: "Vic Viewer", image: null, isOwner: false });
  });
});

describe("gates", () => {
  it("comments switched off → 404 for read and write", async () => {
    insertVideo("off", { comments_enabled: 0 });
    expect((await call("GET", "/video/off/comments")).status).toBe(404);
    expect((await post("off", { body: "x" })).status).toBe(404);
  });

  it("private → 404", async () => {
    insertVideo("priv", { is_private: 1 });
    expect((await call("GET", "/video/priv/comments")).status).toBe(404);
  });

  it("expired link → 404", async () => {
    insertVideo("old", { expires_at: "2020-01-01T00:00:00.000Z" });
    expect((await call("GET", "/video/old/comments")).status).toBe(404);
    expect((await post("old", { body: "x" })).status).toBe(404);
  });

  it("password-protected: closed without the unlock token, open with it", async () => {
    // Legacy digest form: SHA-256("<videoId>:<password>") hex.
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("locked:hunter2"));
    const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    insertVideo("locked", { password_hash: hex });
    expect((await call("GET", "/video/locked/comments")).status).toBe(404);
    expect((await post("locked", { body: "x" })).status).toBe(404);

    const unlock = await call("POST", "/video/locked/unlock", { password: "hunter2" });
    expect(unlock.status).toBe(200);
    const { token } = await json(unlock);
    expect((await call("GET", `/video/locked/comments?token=${token}`)).status).toBe(200);
    expect((await call("POST", `/video/locked/comments?token=${token}`, { body: "in" })).status).toBe(200);
    expect((await call("GET", "/video/locked/comments?token=deadbeef")).status).toBe(404);
  });

  it("the per-IP rate limit still applies", async () => {
    const pinned = { "CF-Connecting-IP": "192.0.2.1" };
    for (let i = 0; i < 10; i++) {
      expect((await post("vid1", { body: `n${i}` }, pinned)).status).toBe(200);
    }
    expect((await post("vid1", { body: "one too many" }, pinned)).status).toBe(429);
  });
});
