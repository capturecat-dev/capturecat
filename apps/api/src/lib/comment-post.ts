/**
 * Posting a comment, shared by the share page (POST /video/:id/comments,
 * routes/video.ts) and the MCP post_comment tool (src/mcp/) — one copy of
 * the gates, caps and validation, so an agent can post nothing a viewer's
 * browser could not. The pure rules (annotation validator, threading,
 * public shape) stay in lib/comments.ts; this is their D1 wiring.
 *
 * What stays with each caller: the rate limit (per IP for the page, per
 * token for agents), the raw-body size check, and WHO is posting.
 */

import type { Env, VideoComment, VideoMetadata } from "../types";
import { countCommentReplies, countVideoComments, getVideoComment, insertVideoComment } from "./db";
import { planForUser } from "./entitlement";
import { generateId } from "./id";
import { queueWebhookEvent, videoEventData } from "./webhooks";
import {
  checkReplyParent,
  isCommentId,
  parseCommentAnnotation,
  toPublicComment,
  type PublicComment,
} from "./comments";

/** Max comments a single video accepts — runaway-thread backstop. Replies
 *  count toward it; the list endpoint returns up to this many. */
export const MAX_COMMENTS_PER_VIDEO = 500;
/** Replies one top-level comment accepts. */
export const MAX_REPLIES_PER_THREAD = 100;
/** Posts allowed per IP (share page) or per agent token, per 10 minutes. */
export const COMMENT_RATE_LIMIT = 10;
export const COMMENT_RATE_WINDOW_SEC = 600;
/** Characters in a comment body. */
export const MAX_COMMENT_LENGTH = 500;

/**
 * Comments are open on this video at all: ready, public, switched on by the
 * uploader, and the uploader's plan still includes comments and sharing.
 * `commentsEnabled` is a client-sent flag; the plan flag is the entitlement.
 * The share page additionally applies the share gate (password, expiry, view
 * cap) — the owner posting through an agent is not a viewer and skips it.
 */
export async function commentsOpen(env: { DB: D1Database }, doc: VideoMetadata): Promise<boolean> {
  // A video an admin took down (lib/moderation.ts) takes no comments.
  if (doc.status !== "ready" || doc.isPrivate || !doc.commentsEnabled || doc.removedAt) return false;
  const plan = await planForUser(env, doc.uid);
  return plan.features.comments && plan.features.cloudShare;
}

export interface CommentInput {
  body?: unknown;
  videoTime?: unknown;
  parentId?: unknown;
  annotation?: unknown;
}

/** Who the comment is from — always decided by the caller from a session or
 *  token, never from the request body. */
export interface CommentAuthor {
  authorName: string;
  authorUid: string | null;
  authorImage: string | null;
}

export type PostCommentResult =
  | { ok: true; comment: PublicComment }
  | { ok: false; status: 400 | 403 | 404; error: string };

/** Where the comment.created webhook (lib/webhooks.ts) is sent from: the
 *  Worker env, and ctx.waitUntil so delivery never delays the response. */
export interface CommentWebhookHook {
  env: Env;
  waitUntil: ((promise: Promise<unknown>) => void) | undefined;
}

/**
 * Validate and store one comment on a video whose comments are open. The
 * order of refusals matches what the share page has always answered: video
 * full, body, drawing, parent, reply-with-drawing, thread full. With
 * `webhook`, a stored comment emits `comment.created` to the OWNER's
 * endpoints (the text marked untrusted unless the owner wrote it).
 */
export async function postComment(
  env: Pick<Env, "DB">,
  doc: VideoMetadata,
  input: CommentInput,
  author: CommentAuthor,
  webhook?: CommentWebhookHook,
): Promise<PostCommentResult> {
  if ((await countVideoComments(env.DB, doc.videoId)) >= MAX_COMMENTS_PER_VIDEO) {
    return { ok: false, status: 403, error: "This video is no longer accepting comments" };
  }

  const text = typeof input.body === "string" ? input.body.trim() : "";
  if (!text || text.length > MAX_COMMENT_LENGTH) {
    return { ok: false, status: 400, error: `Comment must be 1–${MAX_COMMENT_LENGTH} characters` };
  }

  const annotation = parseCommentAnnotation(input.annotation);
  if (!annotation.ok) return { ok: false, status: 400, error: `Invalid drawing: ${annotation.error}` };

  let parentId: string | null = null;
  let videoTime: number;
  if (input.parentId !== undefined && input.parentId !== null) {
    if (!isCommentId(input.parentId)) {
      return { ok: false, status: 404, error: "The comment you are replying to no longer exists" };
    }
    const parent = await getVideoComment(env.DB, input.parentId);
    const verdict = checkReplyParent(
      parent ? { videoId: parent.videoId, parentId: parent.parentId ?? null } : null,
      doc.videoId
    );
    if (!verdict.ok) return { ok: false, status: verdict.status, error: verdict.error };
    if (annotation.annotation) {
      return { ok: false, status: 400, error: "Replies can't carry a drawing — start a new comment" };
    }
    if ((await countCommentReplies(env.DB, input.parentId)) >= MAX_REPLIES_PER_THREAD) {
      return { ok: false, status: 403, error: "This thread is full" };
    }
    parentId = input.parentId;
    // A reply lives at its thread's moment.
    videoTime = parent!.videoTime;
  } else {
    const rawTime =
      typeof input.videoTime === "number" && isFinite(input.videoTime) ? input.videoTime : 0;
    videoTime =
      Math.round(Math.min(Math.max(0, rawTime), Math.max(0, doc.durationSeconds)) * 1000) / 1000;
  }

  const comment: VideoComment = {
    commentId: generateId(),
    videoId: doc.videoId,
    authorName: author.authorName,
    body: text,
    videoTime,
    createdAt: new Date().toISOString(),
    parentId,
    annotationJson: annotation.json,
    authorUid: author.authorUid,
    authorImage: author.authorImage,
  };
  await insertVideoComment(env.DB, comment);
  const posted = toPublicComment(comment, doc.uid);
  if (webhook) {
    // Minimal: no author name (a viewer's), no IP. Viewer text is untrusted.
    queueWebhookEvent(webhook.waitUntil, webhook.env, doc.uid, "comment.created", {
      ...videoEventData(webhook.env, doc),
      comment: {
        commentId: posted.commentId,
        parentId: posted.parentId,
        videoTime: posted.videoTime,
        byOwner: posted.isOwner,
        body: posted.body,
        untrusted: !posted.isOwner,
      },
    });
  }
  return { ok: true, comment: posted };
}
