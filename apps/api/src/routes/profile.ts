import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement } from "../lib/entitlement";

/**
 * Public profiles (migration 0019).
 *
 * A user claims a username and gets capturecat.so/{username}, listing the
 * videos they have made public AND left profile-visible. Reads are public and
 * deliberately narrow: no email, no uid, no storage numbers — only what the
 * owner chose to publish.
 */
export const profileRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

/**
 * Names that must never become a profile URL.
 *
 * Next.js matches static routes before the dynamic `/[username]` segment, so a
 * claimed "pricing" would simply be unreachable rather than shadowing the real
 * page — but it would look broken to whoever claimed it, and any future
 * top-level route would silently break an existing profile. The list is
 * intentionally broad: every current path, the obvious future ones, and the
 * usual impersonation bait.
 */
const RESERVED = new Set([
  // current top-level routes
  "app", "api", "share", "embed", "login", "pricing", "terms", "privacy",
  "download", "beta", "agents", "md", "u",
  // framework / infrastructure
  "_next", "static", "public", "assets", "cdn-cgi", "well-known", "robots",
  "sitemap", "favicon", "manifest", "llms", "icon", "images", "img", "css",
  "js", "fonts",
  // obvious future routes
  "about", "account", "admin", "billing", "blog", "changelog", "checkout",
  "contact", "dashboard", "docs", "help", "home", "jobs", "legal", "new",
  "news", "playlist", "playlists", "press", "profile", "search", "settings",
  "signin", "signup", "signout", "logout", "auth", "oauth", "status",
  "support", "team", "upgrade", "user", "users", "video", "videos", "watch",
  "me", "my", "health", "callback", "invite", "referral", "affiliate",
  // impersonation bait
  "capturecat", "official", "staff", "root", "system", "security", "abuse",
  "postmaster", "webmaster", "www", "mail", "ftp", "cdn", "null", "undefined",
]);

const USERNAME_RE = /^[a-z0-9](?:[a-z0-9_-]{1,28}[a-z0-9])$/;

/** Lowercased and validated, or null with a reason. */
function normalizeUsername(raw: unknown): { username: string } | { error: string } {
  if (typeof raw !== "string") return { error: "username required" };
  const username = raw.trim().toLowerCase();
  if (username.length < 3 || username.length > 30) {
    return { error: "Username must be 3–30 characters" };
  }
  if (!USERNAME_RE.test(username)) {
    return {
      error: "Use letters, numbers, hyphens and underscores; start and end with a letter or number",
    };
  }
  if (RESERVED.has(username)) return { error: "That username is reserved" };
  return { username };
}

interface ProfileUserRow {
  id: string;
  name: string | null;
  image: string | null;
  username: string | null;
  bio: string | null;
  website: string | null;
}

/** GET /profile/me — the signed-in user's profile fields. */
profileRoutes.get("/profile/me", requireAuth, async (c) => {
  const row = await c.env.DB
    .prepare("SELECT id, name, image, username, bio, website FROM user WHERE id = ?")
    .bind(c.get("user").uid)
    .first<ProfileUserRow>();
  if (!row) return c.json({ error: "Not found" }, 404);
  return c.json({
    name: row.name,
    image: row.image,
    username: row.username,
    bio: row.bio,
    website: row.website,
  });
});

/** GET /profile/available?username=… — claim-time availability check. */
profileRoutes.get("/profile/available", requireAuth, async (c) => {
  const result = normalizeUsername(c.req.query("username"));
  if ("error" in result) return c.json({ available: false, error: result.error });

  const existing = await c.env.DB
    .prepare("SELECT id FROM user WHERE username = ?")
    .bind(result.username)
    .first<{ id: string }>();
  const mine = existing?.id === c.get("user").uid;
  return c.json({
    available: !existing || mine,
    username: result.username,
    ...(existing && !mine ? { error: "That username is taken" } : {}),
  });
});

/** PATCH /profile — claim or update username, bio, website. */
profileRoutes.patch("/profile", requireAuth, requireEntitlement(), async (c) => {
  const uid = c.get("user").uid;
  const body: { username?: unknown; bio?: unknown; website?: unknown } =
    await c.req.json().catch(() => ({}));

  const sets: string[] = [];
  const binds: unknown[] = [];

  if (body.username !== undefined) {
    const result = normalizeUsername(body.username);
    if ("error" in result) return c.json({ error: result.error }, 400);
    const existing = await c.env.DB
      .prepare("SELECT id FROM user WHERE username = ?")
      .bind(result.username)
      .first<{ id: string }>();
    if (existing && existing.id !== uid) {
      return c.json({ error: "That username is taken" }, 409);
    }
    sets.push("username = ?");
    binds.push(result.username);
  }
  if (body.bio !== undefined) {
    sets.push("bio = ?");
    binds.push(body.bio === null ? null : String(body.bio).trim().slice(0, 200) || null);
  }
  if (body.website !== undefined) {
    if (body.website === null || String(body.website).trim() === "") {
      sets.push("website = ?");
      binds.push(null);
    } else {
      // Owner-supplied and rendered on a public page — https only, re-parsed.
      const parsed = (() => {
        try { return new URL(String(body.website).trim()); } catch { return null; }
      })();
      if (!parsed || parsed.protocol !== "https:") {
        return c.json({ error: "Website must be an https:// link" }, 400);
      }
      sets.push("website = ?");
      binds.push(parsed.toString().slice(0, 300));
    }
  }

  if (sets.length === 0) return c.json({ error: "No valid fields" }, 400);
  binds.push(uid);
  await c.env.DB
    .prepare(`UPDATE user SET ${sets.join(", ")} WHERE id = ?`)
    .bind(...binds)
    .run();

  // The public profile is edge-cached by username; a rename or bio edit must
  // not linger. Both the old and new names are purged.
  const row = await c.env.DB
    .prepare("SELECT username FROM user WHERE id = ?")
    .bind(uid)
    .first<{ username: string | null }>();
  if (row?.username) {
    await caches.default.delete(new Request(`https://meta.internal/profile/${row.username}`));
  }

  return c.json({ ok: true, username: row?.username ?? null });
});

/**
 * GET /u/:username — the PUBLIC profile. No auth.
 *
 * Lists only videos that are ready, not private, not gated (password/expiry/
 * view cap), and profile-visible. A gated video keeps its share link working
 * but never appears in a public listing.
 */
profileRoutes.get("/u/:username", async (c) => {
  const raw = c.req.param("username").toLowerCase();
  if (!USERNAME_RE.test(raw)) return c.json({ error: "Not found" }, 404);

  const user = await c.env.DB
    .prepare("SELECT id, name, image, username, bio, website FROM user WHERE username = ?")
    .bind(raw)
    .first<ProfileUserRow>();
  if (!user) return c.json({ error: "Not found" }, 404);

  const { results } = await c.env.DB
    .prepare(
      `SELECT video_id, file_name, duration_seconds, created_at, url,
              ai_title, ai_summary
         FROM shared_videos
        WHERE uid = ?
          AND status = 'ready'
          AND is_private = 0
          AND profile_visible = 1
          AND password_hash IS NULL
          AND max_views IS NULL
          AND (expires_at IS NULL OR expires_at > ?)
        ORDER BY created_at DESC
        LIMIT 100`
    )
    .bind(user.id, new Date().toISOString())
    .all<{
      video_id: string;
      file_name: string;
      duration_seconds: number;
      created_at: string;
      url: string;
      ai_title: string | null;
      ai_summary: string | null;
    }>();

  return c.json({
    username: user.username,
    name: user.name,
    image: user.image,
    bio: user.bio,
    website: user.website,
    videos: (results ?? []).map((v) => ({
      videoId: v.video_id,
      title: v.ai_title || v.file_name,
      summary: v.ai_summary,
      durationSeconds: v.duration_seconds,
      createdAt: v.created_at,
      url: v.url,
    })),
  });
});
