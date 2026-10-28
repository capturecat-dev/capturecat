/**
 * Share-page comment rules that do not need a database: the strict validator
 * for on-frame annotations, the one-level threading rule, the commenter
 * identity taken from a session, and the public JSON shape of a comment.
 *
 * Pure on purpose — every rule here is unit-tested in comments.test.ts, and
 * the route (routes/video.ts) only wires them to D1.
 *
 * Annotation wire format (v1). Every coordinate is normalized 0–1 to the
 * VIDEO FRAME (the picture, not the letterboxed player box), so the same
 * shapes land on the same pixels at any player size:
 *
 *   { v: 1, shapes: [
 *     { kind: "pen" | "highlight", color, size, points: [[x, y], …] },
 *     { kind: "arrow" | "rect" | "ellipse", color, size, from: [x, y], to: [x, y] },
 *     { kind: "text", color, size, at: [x, y], text },
 *   ] }
 *
 * `color` is "#rrggbb"; `size` is 1 | 2 | 3 (small / medium / large — the
 * renderer turns it into a stroke width or font size relative to the frame).
 */

export const ANNOTATION_KINDS = ["pen", "highlight", "arrow", "rect", "ellipse", "text"] as const;
export type AnnotationKind = (typeof ANNOTATION_KINDS)[number];

export const ANNOTATION_LIMITS = {
  /** Shapes in one annotation. */
  maxShapes: 100,
  /** Points across every shape (a two-point shape counts 2, text counts 1). */
  maxTotalPoints: 5000,
  /** Points in one pen / highlighter stroke. */
  maxPointsPerStroke: 2000,
  /** Characters in one text label. */
  maxTextLength: 140,
  /** Canonical serialized size, the thing actually stored. */
  maxBytes: 32 * 1024,
} as const;

/** Raw request bodies above this are refused before JSON parsing — a comment
 *  (≤ 500 chars) plus the largest valid annotation fits with room to spare. */
export const MAX_COMMENT_REQUEST_BYTES = 96 * 1024;

export type Point = [number, number];

export type AnnotationShape =
  | { kind: "pen" | "highlight"; color: string; size: 1 | 2 | 3; points: Point[] }
  | { kind: "arrow" | "rect" | "ellipse"; color: string; size: 1 | 2 | 3; from: Point; to: Point }
  | { kind: "text"; color: string; size: 1 | 2 | 3; at: Point; text: string };

export interface CommentAnnotation {
  v: 1;
  shapes: AnnotationShape[];
}

export type AnnotationResult =
  | { ok: true; annotation: CommentAnnotation | null; json: string | null }
  | { ok: false; error: string };

const COLOR_RE = /^#[0-9a-fA-F]{6}$/;
// C0/C1 controls and the bidi override/isolate characters — a label is one
// short line of plain text, and an RLO can make it read backwards.
// eslint-disable-next-line no-control-regex
const UNSAFE_TEXT_RE = /[\u0000-\u001F\u007F-\u009F‪-‮⁦-⁩]/g;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** 4 decimals = 1/10 000 of the frame: sub-pixel at 8K, and it keeps a long
 *  stroke's JSON small. */
function roundCoord(value: number): number {
  return Math.round(Math.min(1, Math.max(0, value)) * 10_000) / 10_000;
}

function parsePoint(raw: unknown): Point | null {
  if (!Array.isArray(raw) || raw.length !== 2) return null;
  const [x, y] = raw;
  if (typeof x !== "number" || typeof y !== "number") return null;
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  // Clamped, not rejected: a pen dragged a hair past the frame edge is a
  // normal gesture. Anything wildly outside is still just pinned to the edge.
  return [roundCoord(x), roundCoord(y)];
}

/** The text a label is stored with: controls stripped, whitespace collapsed. */
export function cleanLabel(raw: string): string {
  return raw.replace(UNSAFE_TEXT_RE, " ").replace(/\s+/g, " ").trim();
}

/**
 * Validate an annotation from a request body and rebuild it in canonical form
 * (known keys only, colours lower-cased, coordinates clamped and rounded).
 * `undefined` / `null` / an empty shape list mean "no drawing". Anything else
 * that is not exactly the v1 format is refused — never stored "best effort".
 */
export function parseCommentAnnotation(raw: unknown): AnnotationResult {
  if (raw === undefined || raw === null) return { ok: true, annotation: null, json: null };
  if (!isRecord(raw)) return { ok: false, error: "annotation must be an object" };
  if (raw.v !== 1) return { ok: false, error: "annotation.v must be 1" };
  if (!Array.isArray(raw.shapes)) return { ok: false, error: "annotation.shapes must be an array" };
  if (raw.shapes.length === 0) return { ok: true, annotation: null, json: null };
  if (raw.shapes.length > ANNOTATION_LIMITS.maxShapes) {
    return { ok: false, error: `annotation has more than ${ANNOTATION_LIMITS.maxShapes} shapes` };
  }

  const shapes: AnnotationShape[] = [];
  let totalPoints = 0;
  for (const [index, rawShape] of raw.shapes.entries()) {
    const where = `annotation.shapes[${index}]`;
    if (!isRecord(rawShape)) return { ok: false, error: `${where} must be an object` };
    const kind = rawShape.kind;
    if (typeof kind !== "string" || !(ANNOTATION_KINDS as readonly string[]).includes(kind)) {
      return { ok: false, error: `${where}.kind is not a supported shape` };
    }
    const color = rawShape.color;
    if (typeof color !== "string" || !COLOR_RE.test(color)) {
      return { ok: false, error: `${where}.color must be #rrggbb` };
    }
    const size = rawShape.size;
    if (size !== 1 && size !== 2 && size !== 3) {
      return { ok: false, error: `${where}.size must be 1, 2 or 3` };
    }
    const base = { color: color.toLowerCase(), size } as const;

    if (kind === "pen" || kind === "highlight") {
      if (!Array.isArray(rawShape.points) || rawShape.points.length === 0) {
        return { ok: false, error: `${where}.points must be a non-empty array` };
      }
      if (rawShape.points.length > ANNOTATION_LIMITS.maxPointsPerStroke) {
        return { ok: false, error: `${where} has more than ${ANNOTATION_LIMITS.maxPointsPerStroke} points` };
      }
      const points: Point[] = [];
      for (const p of rawShape.points) {
        const point = parsePoint(p);
        if (!point) return { ok: false, error: `${where}.points must be [x, y] number pairs` };
        points.push(point);
      }
      totalPoints += points.length;
      shapes.push({ kind, ...base, points });
    } else if (kind === "arrow" || kind === "rect" || kind === "ellipse") {
      const from = parsePoint(rawShape.from);
      const to = parsePoint(rawShape.to);
      if (!from || !to) return { ok: false, error: `${where}.from and .to must be [x, y]` };
      totalPoints += 2;
      shapes.push({ kind, ...base, from, to });
    } else {
      const at = parsePoint(rawShape.at);
      if (!at) return { ok: false, error: `${where}.at must be [x, y]` };
      if (typeof rawShape.text !== "string") {
        return { ok: false, error: `${where}.text must be a string` };
      }
      const text = cleanLabel(rawShape.text);
      if (text.length === 0) return { ok: false, error: `${where}.text is empty` };
      if ([...text].length > ANNOTATION_LIMITS.maxTextLength) {
        return { ok: false, error: `${where}.text is longer than ${ANNOTATION_LIMITS.maxTextLength} characters` };
      }
      totalPoints += 1;
      shapes.push({ kind: "text", ...base, at, text });
    }
    if (totalPoints > ANNOTATION_LIMITS.maxTotalPoints) {
      return { ok: false, error: `annotation has more than ${ANNOTATION_LIMITS.maxTotalPoints} points` };
    }
  }

  const annotation: CommentAnnotation = { v: 1, shapes };
  const json = JSON.stringify(annotation);
  if (new TextEncoder().encode(json).length > ANNOTATION_LIMITS.maxBytes) {
    return { ok: false, error: "annotation is too large" };
  }
  return { ok: true, annotation, json };
}

/** Stored JSON → annotation, re-validated so a hand-edited row can never
 *  reach the page in a shape the renderer does not expect. */
export function annotationFromStored(json: string | null | undefined): CommentAnnotation | null {
  if (!json) return null;
  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch {
    return null;
  }
  const result = parseCommentAnnotation(raw);
  return result.ok ? result.annotation : null;
}

// ---------------------------------------------------------------------------
// Threading
// ---------------------------------------------------------------------------

/** Comment ids are lib/id.ts generateId() output; anything else is not one. */
const COMMENT_ID_RE = /^[a-z0-9]{6,32}$/;

export function isCommentId(value: unknown): value is string {
  return typeof value === "string" && COMMENT_ID_RE.test(value);
}

export type ReplyCheck =
  | { ok: true }
  | { ok: false; status: 400 | 404; error: string };

/**
 * One level deep: a reply's parent must exist, be on the SAME video, and be a
 * top-level comment itself. A parent on another video answers exactly like a
 * missing one, so the endpoint is no oracle for comment ids elsewhere.
 */
export function checkReplyParent(
  parent: { videoId: string; parentId: string | null } | null,
  videoId: string
): ReplyCheck {
  if (!parent || parent.videoId !== videoId) {
    return { ok: false, status: 404, error: "The comment you are replying to no longer exists" };
  }
  if (parent.parentId !== null) {
    return { ok: false, status: 400, error: "Replies are one level deep — reply to the top comment" };
  }
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Commenter identity + the public shape
// ---------------------------------------------------------------------------

/** Session avatar → stored avatar. https only and bounded; OAuth providers
 *  hand out https URLs, so anything else is not worth rendering. */
export function sessionAvatar(image: unknown): string | null {
  if (typeof image !== "string" || image.length === 0 || image.length > 1024) return null;
  try {
    const url = new URL(image);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

/** Display name for a comment: the signed-in account's name wins over
 *  whatever the form said; otherwise the typed name, else "Anonymous". */
export function commentAuthorName(sessionName: unknown, typedName: unknown): string {
  for (const candidate of [sessionName, typedName]) {
    if (typeof candidate === "string") {
      const clean = cleanLabel(candidate).slice(0, 40).trim();
      if (clean) return clean;
    }
  }
  return "Anonymous";
}

export interface StoredComment {
  commentId: string;
  parentId?: string | null;
  authorName: string;
  authorUid?: string | null;
  authorImage?: string | null;
  body: string;
  videoTime: number;
  createdAt: string;
  annotationJson?: string | null;
}

export interface PublicComment {
  commentId: string;
  /** null = top-level; otherwise the top-level comment this replies to. */
  parentId: string | null;
  authorName: string;
  /** Signed-in commenters' avatar (from their session); null → initial. */
  authorImage: string | null;
  /** Posted by the video's owner while signed in. */
  isOwner: boolean;
  body: string;
  videoTime: number;
  createdAt: string;
  annotation: CommentAnnotation | null;
}

/** Row → page JSON. `author_uid` never leaves the server; it is reduced to
 *  `isOwner` against the video's uid here. */
export function toPublicComment(comment: StoredComment, ownerUid: string): PublicComment {
  return {
    commentId: comment.commentId,
    parentId: comment.parentId ?? null,
    authorName: comment.authorName,
    authorImage: comment.authorImage ?? null,
    isOwner: !!comment.authorUid && comment.authorUid === ownerUid,
    body: comment.body,
    videoTime: comment.videoTime,
    createdAt: comment.createdAt,
    annotation: annotationFromStored(comment.annotationJson),
  };
}
