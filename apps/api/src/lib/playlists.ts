/**
 * Dashboard playlists (migration 0018): private, owner-only collections of
 * shared videos. The reads and the add-a-video write are shared by the
 * session routes (routes/playlists.ts) and the MCP list_playlists /
 * add_to_playlist tools (src/mcp/), so both enforce the same ownership and
 * caps.
 */

import { getSharedVideo } from "./db";

export const MAX_PLAYLISTS_PER_USER = 100;
export const MAX_VIDEOS_PER_PLAYLIST = 500;

export interface PlaylistRow {
  playlist_id: string;
  uid: string;
  name: string;
  emoji: string | null;
  position: number;
  created_at: string;
}

export interface Playlist {
  playlistId: string;
  name: string;
  emoji: string | null;
  videoIds: string[];
  createdAt: string;
}

/** The playlist, only when `uid` owns it. */
export async function ownedPlaylist(
  db: D1Database,
  playlistId: string,
  uid: string
): Promise<PlaylistRow | null> {
  const row = await db
    .prepare("SELECT * FROM video_playlists WHERE playlist_id = ?")
    .bind(playlistId)
    .first<PlaylistRow>();
  return row && row.uid === uid ? row : null;
}

/** The user's playlists with member video ids, in display order. */
export async function listUserPlaylists(db: D1Database, uid: string): Promise<Playlist[]> {
  const { results: playlists } = await db
    .prepare("SELECT * FROM video_playlists WHERE uid = ? ORDER BY position, created_at")
    .bind(uid)
    .all<PlaylistRow>();

  const { results: members } = await db
    .prepare(
      `SELECT pv.playlist_id, pv.video_id
         FROM playlist_videos pv
         JOIN video_playlists p ON p.playlist_id = pv.playlist_id
        WHERE p.uid = ?
        ORDER BY pv.position, pv.created_at`
    )
    .bind(uid)
    .all<{ playlist_id: string; video_id: string }>();

  const byPlaylist = new Map<string, string[]>();
  for (const m of members ?? []) {
    byPlaylist.set(m.playlist_id, [...(byPlaylist.get(m.playlist_id) ?? []), m.video_id]);
  }

  return (playlists ?? []).map((p) => ({
    playlistId: p.playlist_id,
    name: p.name,
    emoji: p.emoji,
    videoIds: byPlaylist.get(p.playlist_id) ?? [],
    createdAt: p.created_at,
  }));
}

export type AddToPlaylistResult =
  | { ok: true; playlistId: string; videoId: string }
  | { ok: false; status: 403 | 404; error: string };

/** Add one of the user's own videos to one of their playlists. Adding a
 *  video already in it is a no-op success. */
export async function addVideoToPlaylist(
  db: D1Database,
  uid: string,
  playlistId: string,
  videoId: string
): Promise<AddToPlaylistResult> {
  const playlist = await ownedPlaylist(db, playlistId, uid);
  if (!playlist) return { ok: false, status: 404, error: "Playlist not found" };

  // Only the user's own videos — a playlist must never reference someone
  // else's media, even by id.
  const video = await getSharedVideo(db, videoId);
  if (!video || video.uid !== uid) return { ok: false, status: 404, error: "Video not found" };

  const count = await db
    .prepare("SELECT COUNT(*) AS n FROM playlist_videos WHERE playlist_id = ?")
    .bind(playlist.playlist_id)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_VIDEOS_PER_PLAYLIST) {
    return { ok: false, status: 403, error: "Playlist is full" };
  }

  await db
    .prepare(
      `INSERT OR IGNORE INTO playlist_videos (playlist_id, video_id, position, created_at)
       VALUES (?, ?, ?, ?)`
    )
    .bind(playlist.playlist_id, videoId, count?.n ?? 0, new Date().toISOString())
    .run();
  return { ok: true, playlistId: playlist.playlist_id, videoId };
}
