import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement } from "../lib/entitlement";
import { generateId } from "../lib/id";
import {
  MAX_PLAYLISTS_PER_USER,
  addVideoToPlaylist,
  listUserPlaylists,
  ownedPlaylist,
} from "../lib/playlists";

/**
 * Dashboard playlists (migration 0018): private, owner-only collections of
 * shared videos — emoji-labelled folders in the web library. A video may sit
 * in many playlists; membership rows die with the playlist or the video.
 */
export const playlistRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

// Caps, ownership and the add-a-video write live in lib/playlists.ts — the
// MCP list_playlists / add_to_playlist tools run the same code.

function sanitizedName(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const name = raw.trim().slice(0, 60);
  return name.length > 0 ? name : null;
}

/** One emoji (or nothing). Grapheme clusters, not code points. */
function sanitizedEmoji(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const segments = [...new Intl.Segmenter().segment(trimmed)];
  return segments.length > 0 ? segments[0].segment.slice(0, 16) : null;
}

/** GET /playlists — the user's playlists with member video ids, so the
 *  dashboard can filter its already-loaded list client-side. */
playlistRoutes.get("/playlists", requireAuth, requireEntitlement(), async (c) => {
  return c.json({ playlists: await listUserPlaylists(c.env.DB, c.get("user").uid) });
});

playlistRoutes.post("/playlists", requireAuth, requireEntitlement(), async (c) => {
  const uid = c.get("user").uid;
  const body: { name?: unknown; emoji?: unknown } = await c.req.json().catch(() => ({}));
  const name = sanitizedName(body.name);
  if (!name) return c.json({ error: "name required (1–60 chars)" }, 400);

  const count = await c.env.DB
    .prepare("SELECT COUNT(*) AS n FROM video_playlists WHERE uid = ?")
    .bind(uid)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_PLAYLISTS_PER_USER) {
    return c.json({ error: "Playlist limit reached" }, 403);
  }

  const playlistId = generateId();
  await c.env.DB
    .prepare(
      `INSERT INTO video_playlists (playlist_id, uid, name, emoji, position, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
    .bind(playlistId, uid, name, sanitizedEmoji(body.emoji), count?.n ?? 0, new Date().toISOString())
    .run();

  return c.json({ playlistId, name, emoji: sanitizedEmoji(body.emoji) });
});

playlistRoutes.patch("/playlists/:playlistId", requireAuth, requireEntitlement(), async (c) => {
  const playlist = await ownedPlaylist(c.env.DB, c.req.param("playlistId"), c.get("user").uid);
  if (!playlist) return c.json({ error: "Playlist not found" }, 404);

  const body: { name?: unknown; emoji?: unknown } = await c.req.json().catch(() => ({}));
  const name = body.name !== undefined ? sanitizedName(body.name) : playlist.name;
  if (!name) return c.json({ error: "name required (1–60 chars)" }, 400);
  const emoji = body.emoji !== undefined ? sanitizedEmoji(body.emoji) : playlist.emoji;

  await c.env.DB
    .prepare("UPDATE video_playlists SET name = ?, emoji = ? WHERE playlist_id = ?")
    .bind(name, emoji, playlist.playlist_id)
    .run();
  return c.json({ playlistId: playlist.playlist_id, name, emoji });
});

playlistRoutes.delete("/playlists/:playlistId", requireAuth, requireEntitlement(), async (c) => {
  const playlist = await ownedPlaylist(c.env.DB, c.req.param("playlistId"), c.get("user").uid);
  if (!playlist) return c.json({ error: "Playlist not found" }, 404);

  // Membership rows first — deleting a playlist never touches the videos.
  await c.env.DB
    .prepare("DELETE FROM playlist_videos WHERE playlist_id = ?")
    .bind(playlist.playlist_id)
    .run();
  await c.env.DB
    .prepare("DELETE FROM video_playlists WHERE playlist_id = ?")
    .bind(playlist.playlist_id)
    .run();
  return c.json({ deleted: true, playlistId: playlist.playlist_id });
});

playlistRoutes.post(
  "/playlists/:playlistId/videos",
  requireAuth,
  requireEntitlement(),
  async (c) => {
    const body: { videoId?: unknown } = await c.req.json().catch(() => ({}));
    const videoId = typeof body.videoId === "string" ? body.videoId : null;
    if (!videoId) return c.json({ error: "videoId required" }, 400);

    const result = await addVideoToPlaylist(c.env.DB, c.get("user").uid, c.req.param("playlistId"), videoId);
    if (!result.ok) return c.json({ error: result.error }, result.status);
    return c.json({ playlistId: result.playlistId, videoId: result.videoId });
  }
);

playlistRoutes.delete(
  "/playlists/:playlistId/videos/:videoId",
  requireAuth,
  requireEntitlement(),
  async (c) => {
    const playlist = await ownedPlaylist(c.env.DB, c.req.param("playlistId"), c.get("user").uid);
    if (!playlist) return c.json({ error: "Playlist not found" }, 404);

    await c.env.DB
      .prepare("DELETE FROM playlist_videos WHERE playlist_id = ? AND video_id = ?")
      .bind(playlist.playlist_id, c.req.param("videoId"))
      .run();
    return c.json({ playlistId: playlist.playlist_id, removed: c.req.param("videoId") });
  }
);
