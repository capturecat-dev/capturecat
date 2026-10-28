/**
 * Share-page comment model helpers: the API's comment shape, one-level
 * threads, commenter avatars (colour + initial), and the scrubber marker
 * grouping. Pure — unit-tested in comments.test.ts.
 */

import { readAnnotation, type CommentAnnotation } from "./annotation";

/** GET/POST /api/video/:id/comments → one comment. */
export interface ShareComment {
  commentId: string;
  parentId: string | null;
  authorName: string;
  authorImage: string | null;
  isOwner: boolean;
  body: string;
  videoTime: number;
  createdAt: string;
  annotation: CommentAnnotation | null;
}

/** The signed-in caller, as the comments endpoint describes them. */
export interface CommentViewer {
  name: string;
  image: string | null;
  isOwner: boolean;
}

export interface CommentThread {
  comment: ShareComment;
  replies: ShareComment[];
}

/** Tolerant reader for one API comment — older API builds omit the 0031
 *  fields, and a missing field must never break the page. */
export function readComment(raw: unknown): ShareComment | null {
  if (!raw || typeof raw !== "object") return null;
  const c = raw as Record<string, unknown>;
  if (typeof c.commentId !== "string" || typeof c.body !== "string") return null;
  return {
    commentId: c.commentId,
    parentId: typeof c.parentId === "string" ? c.parentId : null,
    authorName: typeof c.authorName === "string" && c.authorName.trim() ? c.authorName : "Anonymous",
    authorImage:
      typeof c.authorImage === "string" && c.authorImage.startsWith("https://") ? c.authorImage : null,
    isOwner: c.isOwner === true,
    body: c.body,
    videoTime: typeof c.videoTime === "number" && Number.isFinite(c.videoTime) ? Math.max(0, c.videoTime) : 0,
    createdAt: typeof c.createdAt === "string" ? c.createdAt : "",
    annotation: readAnnotation(c.annotation),
  };
}

/**
 * Flat list → threads. Top-level comments by video time (then age); replies
 * under their parent, oldest first. A reply whose parent is missing (deleted,
 * or past a list cap) is promoted to top level rather than silently lost.
 */
export function buildThreads(comments: ShareComment[]): CommentThread[] {
  const top = new Map<string, CommentThread>();
  for (const c of comments) {
    if (c.parentId === null) top.set(c.commentId, { comment: c, replies: [] });
  }
  for (const c of comments) {
    if (c.parentId === null) continue;
    const parent = top.get(c.parentId);
    if (parent) parent.replies.push(c);
    else top.set(c.commentId, { comment: { ...c, parentId: null }, replies: [] });
  }
  const byAge = (a: ShareComment, b: ShareComment) => a.createdAt.localeCompare(b.createdAt);
  const threads = [...top.values()];
  for (const t of threads) t.replies.sort(byAge);
  return threads.sort((a, b) => a.comment.videoTime - b.comment.videoTime || byAge(a.comment, b.comment));
}

// ---------------------------------------------------------------------------
// Avatars
// ---------------------------------------------------------------------------

/** FNV-1a — a stable, well-spread hash for picking a colour from a name. */
function fnv1a(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

const isAnonymous = (name: string) => {
  const n = name.trim().toLowerCase();
  return n === "" || n === "anonymous";
};

/** The circle colour for a name: same name → same colour on every device. */
export function avatarColor(name: string): string {
  if (isAnonymous(name)) return "hsl(220 9% 34%)";
  const hue = fnv1a(name.trim().toLowerCase()) % 360;
  return `hsl(${hue} 52% 40%)`;
}

/** First visible character of the name (emoji- and accent-safe). */
export function avatarInitial(name: string): string {
  if (isAnonymous(name)) return "?";
  const first = Array.from(name.trim())[0] ?? "?";
  return first.toLocaleUpperCase();
}

// ---------------------------------------------------------------------------
// Scrubber markers
// ---------------------------------------------------------------------------

export interface MarkerGroup<T> {
  /** Stable key: the first item's id. */
  key: string;
  /** Where the group sits and jumps to — its earliest comment. */
  time: number;
  /** 0–1 along the track. */
  ratio: number;
  items: T[];
}

/**
 * Cluster markers that would overlap on a track `trackPx` wide. Greedy left
 * to right: an item joins the current group while it sits within `minGapPx`
 * of the group's anchor (its first item), so a dense run becomes a few tidy
 * stacks instead of one ever-growing blob.
 */
export function groupMarkers<T extends { id: string; time: number }>(
  items: T[],
  duration: number,
  trackPx: number,
  minGapPx: number
): MarkerGroup<T>[] {
  if (items.length === 0) return [];
  const ratioOf = (t: number) => (duration > 0 ? Math.min(1, Math.max(0, t / duration)) : 0);
  const sorted = [...items].sort((a, b) => a.time - b.time || a.id.localeCompare(b.id));
  const groups: MarkerGroup<T>[] = [];
  for (const item of sorted) {
    const ratio = ratioOf(item.time);
    const last = groups[groups.length - 1];
    if (last && (ratio - last.ratio) * Math.max(0, trackPx) < minGapPx) {
      last.items.push(item);
    } else {
      groups.push({ key: item.id, time: item.time, ratio, items: [item] });
    }
  }
  return groups;
}

/** "now", "5m", "3h", "2d", "4w", then a date. */
export function relativeTime(iso: string, now = Date.now()): string {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "";
  const s = Math.max(0, Math.round((now - t) / 1000));
  if (s < 45) return "now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.round(h / 24);
  if (d < 7) return `${d}d`;
  if (d < 35) return `${Math.round(d / 7)}w`;
  return new Date(t).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
}

export function formatTime(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
