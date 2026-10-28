/**
 * The remote MCP server's tools (v1). Each one names the scope it needs,
 * reuses the session routes' lib/ functions for every rule, and returns a
 * short text summary plus `structuredContent` matching its outputSchema.
 *
 * Naming: tool names and arguments are snake_case (the MCP convention, and
 * the Screenshot API's); structured results are camelCase like every other
 * CaptureCat API response.
 *
 * Access mirrors the dashboard exactly:
 *   • view (owner or team member)  get_video, get_transcript, get_summary
 *   • owner only                   everything else that names a video
 *   • the account's own data       get_account, list_videos, search_transcripts, playlists
 * There is no delete tool and no billing tool, by design.
 */

import { z } from "zod";
import {
  getAISummary,
  getTranscript,
  listSharedVideosPage,
  listVideoComments,
  getSharedVideo,
  searchLibraryTranscripts,
  setSharedVideoPrivacy,
  storageUsageBytes,
  viewCount,
  TRANSCRIPT_QUERY_MAX,
  TRANSCRIPT_QUERY_MIN,
} from "../lib/db";
import type { VideoMetadata } from "../types";
import { fixedWindowAllow } from "../lib/entitlement";
import {
  AGENT_NAME_SUFFIX,
  ANNOTATION_KINDS,
  MAX_COMMENT_REQUEST_BYTES,
  agentCommentAuthorName,
  sessionAvatar,
  toPublicComment,
  type PublicComment,
} from "../lib/comments";
import {
  COMMENT_RATE_LIMIT,
  COMMENT_RATE_WINDOW_SEC,
  MAX_COMMENTS_PER_VIDEO,
  MAX_COMMENT_LENGTH,
  commentsOpen,
  postComment,
} from "../lib/comment-post";
import {
  applyShareControls,
  purgeVideoMeta,
  shareControlsPatch,
  type ShareControlsBody,
  type ShareControlsPatch,
} from "../lib/video-share";
import { videoAnalytics } from "../lib/video-analytics";
import { addVideoToPlaylist, listUserPlaylists } from "../lib/playlists";
import { takeScreenshot } from "../lib/screenshot/take";
import { monthlyQuotaUsed } from "../lib/screenshot/quota";
import { AGENT_SCOPES } from "../lib/agent-tokens";
import {
  ToolError,
  Untrusted,
  UNTRUSTED_DESCRIPTION,
  VideoIdSchema,
  defineTool,
  fenced,
  formatSeconds,
  oneLine,
  shareUrlFor,
  toBase64,
  videoFor,
  type ToolDefinition,
} from "./tool";

// ---------------------------------------------------------------------------
// Shared output shapes
// ---------------------------------------------------------------------------

const Privacy = z.enum(["public", "private"]);

const ShareSettings = z.object({
  isPrivate: z.boolean().describe("Private videos play only for the owner (and their team, for team videos)."),
  allowDownload: z.boolean(),
  hasPassword: z.boolean().describe("A password gates the share page. The password itself is never returned."),
  expiresAt: z.string().nullable().describe("ISO-8601 time after which the link stops playing, or null."),
  maxViews: z.number().nullable().describe("Distinct viewers allowed, or null for unlimited."),
  brandAccent: z.string().nullable().describe("Share-page accent colour #RRGGBB, or null."),
  showVersionHistory: z.boolean(),
  cta: z.object({ label: z.string(), url: z.string() }).nullable().describe("Call-to-action button, or null."),
  profileVisible: z.boolean().describe("Listed on the owner's public profile page."),
  commentsEnabled: z.boolean().describe("Viewer comments switched on at share time."),
});

function shareSettingsOf(doc: VideoMetadata): z.input<typeof ShareSettings> {
  return {
    isPrivate: doc.isPrivate,
    allowDownload: doc.allowDownload,
    hasPassword: doc.passwordHash !== null,
    expiresAt: doc.expiresAt,
    maxViews: doc.maxViews && doc.maxViews > 0 ? doc.maxViews : null,
    brandAccent: doc.brandAccent,
    showVersionHistory: doc.showVersionHistory === true,
    cta: doc.ctaLabel && doc.ctaUrl ? { label: doc.ctaLabel, url: doc.ctaUrl } : null,
    profileVisible: doc.profileVisible,
    commentsEnabled: doc.commentsEnabled,
  };
}

const Segment = z.object({ start: z.number(), end: z.number(), text: z.string() });

const Annotation = z
  .object({ v: z.literal(1), shapes: z.array(z.record(z.string(), z.unknown())) })
  .describe("On-frame drawing (v1 shape list; coordinates normalised 0–1 to the video frame).");

const Comment = z.object({
  commentId: z.string(),
  authorName: z.string(),
  isOwner: z.boolean().describe("Posted by the video's owner while signed in (or by an agent on their behalf)."),
  body: z.string(),
  videoTime: z.number().describe("Seconds into the video the comment is anchored at."),
  createdAt: z.string(),
  annotation: Annotation.nullable(),
});

function commentOf(c: PublicComment): z.input<typeof Comment> {
  return {
    commentId: c.commentId,
    authorName: c.authorName,
    isOwner: c.isOwner,
    body: c.body,
    videoTime: c.videoTime,
    createdAt: c.createdAt,
    annotation: c.annotation,
  };
}

const READ = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false } as const;

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

const getAccount = defineTool({
  name: "get_account",
  title: "Get account",
  description:
    "The CaptureCat account this token belongs to: tier, plan, which plan features are on, the plan's limits, storage used against the storage limit, and screenshot renders used this month. Call it first to learn what the account can do before trying a gated tool. Requires scope account:read.",
  scope: "account:read",
  annotations: READ,
  input: z.object({}),
  output: z.object({
    userId: z.string(),
    email: z.string().nullable(),
    name: z.string().nullable(),
    tier: z.enum(["free", "tester", "paid"]),
    plan: z.object({ name: z.string(), displayName: z.string() }),
    features: z.record(z.string(), z.boolean()).describe("Plan feature flags (cloudShare, comments, aiSummaries, screenshotApi, …)."),
    limits: z.record(z.string(), z.number()).describe("Plan limits; 0 means none."),
    storage: z.object({ usedBytes: z.number(), limitBytes: z.number() }),
    screenshots: z.object({ usedThisMonth: z.number(), monthlyLimit: z.number() }),
    token: z.object({ name: z.string(), scopes: z.array(z.string()) }),
  }),
  async run(_args, ctx) {
    const { tier, plan } = await ctx.entitlement();
    const uid = ctx.principal.uid;
    const [user, usedBytes, shots] = await Promise.all([
      ctx.env.DB.prepare(`SELECT email, name FROM "user" WHERE id = ?`).bind(uid).first<{ email: string | null; name: string | null }>(),
      storageUsageBytes(ctx.env.DB, uid),
      monthlyQuotaUsed(ctx.env.DB, uid),
    ]);
    const gb = (n: number) => `${(n / 1024 ** 3).toFixed(2)} GB`;
    const on = Object.entries(plan.features).filter(([, v]) => v).map(([k]) => k);
    return {
      text:
        `${plan.displayName} (${tier}). Storage ${gb(usedBytes)} of ${gb(plan.limits.maxTotalStorageBytes)}. ` +
        `Screenshots ${shots}/${plan.limits.maxScreenshotsPerMonth} this month. ` +
        `Features on: ${on.length ? on.join(", ") : "none"}. Token scopes: ${ctx.principal.scopes.join(", ")}.`,
      structured: {
        userId: uid,
        email: user?.email ?? null,
        name: user?.name ?? null,
        tier,
        plan: { name: plan.name, displayName: plan.displayName },
        features: { ...plan.features },
        limits: { ...plan.limits },
        storage: { usedBytes, limitBytes: plan.limits.maxTotalStorageBytes },
        screenshots: { usedThisMonth: shots, monthlyLimit: plan.limits.maxScreenshotsPerMonth },
        token: { name: ctx.principal.tokenName, scopes: [...ctx.principal.scopes] },
      },
    };
  },
});

// ---------------------------------------------------------------------------
// Videos
// ---------------------------------------------------------------------------

const VideoListItem = z.object({
  id: z.string(),
  title: z.string().describe("The file name the video was shared under."),
  aiTitle: z.string().nullable(),
  shareUrl: z.string(),
  privacy: Privacy,
  hasPassword: z.boolean(),
  durationSeconds: z.number(),
  createdAt: z.string(),
  views: z.number().describe("Distinct viewer sessions."),
});

const listVideos = defineTool({
  name: "list_videos",
  title: "List shared videos",
  description:
    "The account's shared videos, newest first: id, title, share URL, privacy, duration, created time and view count. Paged: pass nextCursor back as cursor for the next page. Use the ids with get_video, get_transcript, list_comments and the other video tools. Requires scope videos:read." +
    UNTRUSTED_DESCRIPTION,
  scope: "videos:read",
  annotations: READ,
  input: z.object({
    limit: z.int().min(1).max(100).default(25).describe("Videos per page, 1–100."),
    cursor: z.string().regex(/^\d{1,6}$/, { error: "cursor must be a nextCursor value from list_videos" }).optional().describe("nextCursor from the previous page; omit for the first page."),
  }),
  output: z.object({
    videos: z.array(VideoListItem),
    total: z.number(),
    nextCursor: z.string().nullable(),
    untrusted: Untrusted,
  }),
  async run(args, ctx) {
    const offset = args.cursor ? Number(args.cursor) : 0;
    const page = await listSharedVideosPage(ctx.env.DB, ctx.principal.uid, args.limit, offset);
    const videos = page.videos.map((v) => ({
      id: v.videoId,
      title: v.fileName,
      aiTitle: v.aiTitle,
      shareUrl: shareUrlFor(ctx.env, v.videoId),
      privacy: v.isPrivate ? ("private" as const) : ("public" as const),
      hasPassword: v.passwordHash !== null,
      durationSeconds: v.durationSeconds,
      createdAt: v.createdAt,
      views: v.views,
    }));
    const next = offset + videos.length < page.total && videos.length > 0 ? String(offset + videos.length) : null;
    const lines = videos.map(
      (v) =>
        `- ${v.id} · ${oneLine(v.title, 80)} · ${v.privacy}${v.hasPassword ? " + password" : ""} · ` +
        `${formatSeconds(v.durationSeconds)} · ${v.views} views · ${v.createdAt.slice(0, 10)} · ${v.shareUrl}`,
    );
    return {
      text:
        videos.length === 0
          ? offset > 0 ? "No more videos." : "No shared videos yet."
          : `${videos.length} of ${page.total} videos (from ${offset + 1})${next ? `; next cursor ${next}` : ""}:\n${fenced(lines)}`,
      structured: { videos, total: page.total, nextCursor: next, untrusted: true as const },
    };
  },
});

const getVideo = defineTool({
  name: "get_video",
  title: "Get video",
  description:
    "Everything about one shared video: title, AI title, share URL, duration, size, views, whether a transcript and AI summary exist, and its share-page settings (privacy, password on/off, expiry, view cap, download, call-to-action, comments). Works for the account's own videos and for team-library videos it can view. Requires scope videos:read." +
    UNTRUSTED_DESCRIPTION,
  scope: "videos:read",
  annotations: READ,
  input: z.object({ video_id: VideoIdSchema }),
  output: z.object({
    id: z.string(),
    title: z.string(),
    aiTitle: z.string().nullable(),
    shareUrl: z.string(),
    privacy: Privacy,
    access: z.enum(["owner", "team"]).describe("owner: this account uploaded it. team: a teammate's video in a shared team library (read-only)."),
    teamId: z.string().nullable(),
    durationSeconds: z.number(),
    fileSizeBytes: z.number(),
    createdAt: z.string(),
    views: z.number().nullable().describe("Distinct viewers; null on a teammate's video (analytics are the uploader's)."),
    currentVersion: z.number(),
    hasTranscript: z.boolean(),
    hasSummary: z.boolean(),
    share: ShareSettings.nullable().describe("Share-page settings; null on a teammate's video (only the uploader manages them)."),
    untrusted: Untrusted,
  }),
  async run(args, ctx) {
    const doc = await videoFor(ctx, args.video_id, "view");
    // A team member gets VIEW access (the byte route's rule) — not the
    // uploader's analytics or share controls, which no session route shows them.
    const isOwner = doc.uid === ctx.principal.uid;
    const [views, transcript, ai] = await Promise.all([
      isOwner ? viewCount(ctx.env.DB, doc.videoId) : Promise.resolve(0),
      getTranscript(ctx.env.DB, doc.videoId),
      getAISummary(ctx.env.DB, doc.videoId),
    ]);
    const share = isOwner ? shareSettingsOf(doc) : null;
    const structured = {
      id: doc.videoId,
      title: doc.fileName,
      aiTitle: ai?.title ?? null,
      shareUrl: shareUrlFor(ctx.env, doc.videoId),
      privacy: doc.isPrivate ? ("private" as const) : ("public" as const),
      access: isOwner ? ("owner" as const) : ("team" as const),
      teamId: doc.orgId ?? null,
      durationSeconds: doc.durationSeconds,
      fileSizeBytes: doc.fileSizeBytes,
      createdAt: doc.createdAt,
      views: isOwner ? views : null,
      currentVersion: doc.currentVersion ?? 1,
      hasTranscript: (transcript?.length ?? 0) > 0,
      hasSummary: !!(ai?.summary || ai?.title),
      share,
      untrusted: true as const,
    };
    return {
      videoId: doc.videoId,
      text:
        `${doc.videoId}${isOwner ? "" : " (teammate's video, read-only)"}: ${structured.privacy}${share?.hasPassword ? " + password" : ""}, ` +
        `${formatSeconds(doc.durationSeconds)}${isOwner ? `, ${views} views` : ""}, transcript ${structured.hasTranscript ? "yes" : "no"}, ` +
        `summary ${structured.hasSummary ? "yes" : "no"} — ${structured.shareUrl}\n` +
        fenced([`title: ${oneLine(doc.fileName)}`, ...(structured.aiTitle ? [`AI title: ${oneLine(structured.aiTitle)}`] : [])]),
      structured,
    };
  },
});

const getTranscriptTool = defineTool({
  name: "get_transcript",
  title: "Get transcript",
  description:
    "The timestamped transcript of a shared video (segments with start/end seconds), when one was uploaded with it. Empty when the video has none. Requires scope videos:read." +
    UNTRUSTED_DESCRIPTION,
  scope: "videos:read",
  annotations: READ,
  input: z.object({ video_id: VideoIdSchema }),
  output: z.object({
    videoId: z.string(),
    segments: z.array(Segment),
    untrusted: Untrusted,
  }),
  async run(args, ctx) {
    const doc = await videoFor(ctx, args.video_id, "view");
    const segments = (await getTranscript(ctx.env.DB, doc.videoId)) ?? [];
    const clean = segments.map((s) => ({ start: s.start, end: s.end, text: s.text }));
    return {
      videoId: doc.videoId,
      text:
        clean.length === 0
          ? `No transcript for ${doc.videoId}.`
          : `${clean.length} transcript segments for ${doc.videoId}:\n` +
            fenced(clean.map((s) => `[${formatSeconds(s.start)}] ${oneLine(s.text, 1000)}`)),
      structured: { videoId: doc.videoId, segments: clean, untrusted: true as const },
    };
  },
});

const getSummary = defineTool({
  name: "get_summary",
  title: "Get AI summary",
  description:
    "The AI title, summary and chapters of a shared video, when one exists (made by the Mac app at share time, or generated from the dashboard on plans with AI summaries). Never generates one: when none exists, exists is false and canGenerate says whether the account's plan could generate one from the dashboard. Requires scope videos:read." +
    UNTRUSTED_DESCRIPTION,
  scope: "videos:read",
  annotations: READ,
  input: z.object({ video_id: VideoIdSchema }),
  output: z.object({
    videoId: z.string(),
    exists: z.boolean(),
    title: z.string().nullable(),
    summary: z.string().nullable(),
    chapters: z.array(z.object({ start: z.number(), label: z.string() })),
    source: z.string().nullable().describe("Who wrote it: e.g. the app's on-device model, or gemini."),
    canGenerate: z.boolean().describe("The owner's plan includes server-side AI summaries and this token's user is the owner."),
    untrusted: Untrusted,
  }),
  async run(args, ctx) {
    const doc = await videoFor(ctx, args.video_id, "view");
    const ai = await getAISummary(ctx.env.DB, doc.videoId);
    let chapters: Array<{ start: number; label: string }> = [];
    if (ai?.chaptersJson) {
      try {
        const parsed: unknown = JSON.parse(ai.chaptersJson);
        if (Array.isArray(parsed)) {
          chapters = parsed.flatMap((ch: { start?: unknown; label?: unknown }) =>
            typeof ch?.start === "number" && typeof ch?.label === "string" ? [{ start: ch.start, label: ch.label }] : [],
          );
        }
      } catch { /* malformed chapters read as none */ }
    }
    const exists = !!(ai?.summary || ai?.title || chapters.length > 0);
    const isOwner = doc.uid === ctx.principal.uid;
    const canGenerate = isOwner && (await ctx.entitlement()).plan.features.aiSummaries && !!ctx.env.GEMINI_API_KEY;
    return {
      videoId: doc.videoId,
      text: exists
        ? `AI summary for ${doc.videoId}:\n` +
          fenced([
            ...(ai?.title ? [`title: ${oneLine(ai.title)}`] : []),
            ...(ai?.summary ? [`summary: ${oneLine(ai.summary, 1000)}`] : []),
            ...chapters.map((ch) => `chapter [${formatSeconds(ch.start)}] ${oneLine(ch.label, 80)}`),
          ])
        : `No AI summary for ${doc.videoId}.${canGenerate ? " The owner can generate one from the CaptureCat dashboard." : ""}`,
      structured: {
        videoId: doc.videoId,
        exists,
        title: ai?.title ?? null,
        summary: ai?.summary ?? null,
        chapters,
        source: ai?.source ?? null,
        canGenerate,
        untrusted: true as const,
      },
    };
  },
});

const searchTranscriptsTool = defineTool({
  name: "search_transcripts",
  title: "Search transcripts",
  description:
    "Find which of the account's shared videos mention a phrase in their transcripts (case-insensitive substring), with up to five matching timestamped segments per video. Up to 20 videos. Requires scope videos:read." +
    UNTRUSTED_DESCRIPTION,
  scope: "videos:read",
  annotations: READ,
  input: z.object({
    query: z
      .string()
      .trim()
      .min(TRANSCRIPT_QUERY_MIN)
      .max(TRANSCRIPT_QUERY_MAX)
      .describe(`Words to look for, ${TRANSCRIPT_QUERY_MIN}–${TRANSCRIPT_QUERY_MAX} characters.`),
  }),
  output: z.object({
    query: z.string(),
    results: z.array(
      z.object({ videoId: z.string(), title: z.string(), shareUrl: z.string(), matches: z.array(Segment) }),
    ),
    untrusted: Untrusted,
  }),
  async run(args, ctx) {
    const hits = await searchLibraryTranscripts(ctx.env.DB, ctx.principal.uid, args.query);
    const docs = await Promise.all(hits.map((h) => getSharedVideo(ctx.env.DB, h.videoId)));
    const results = hits.flatMap((h, i) => {
      const doc = docs[i];
      // Defence in depth: the transcript row's uid already scoped the search.
      if (!doc || doc.uid !== ctx.principal.uid || doc.status !== "ready") return [];
      return [
        {
          videoId: h.videoId,
          title: doc.fileName,
          shareUrl: shareUrlFor(ctx.env, h.videoId),
          matches: h.segments.map((s) => ({ start: s.start, end: s.end, text: s.text })),
        },
      ];
    });
    return {
      text:
        results.length === 0
          ? `No transcripts mention "${args.query}".`
          : `${results.length} videos mention "${args.query}":\n` +
            fenced(
              results.flatMap((r) => [
                `${r.videoId} · ${oneLine(r.title, 80)}`,
                ...r.matches.map((m) => `  [${formatSeconds(m.start)}] ${oneLine(m.text, 200)}`),
              ]),
            ),
      structured: { query: args.query, results, untrusted: true as const },
    };
  },
});

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

const listComments = defineTool({
  name: "list_comments",
  title: "List comments",
  description:
    "Viewer comments on one of the account's videos, as threads (each top-level comment with its replies, ordered by video time), including on-frame drawings. The owner sees every comment, whatever the public comments setting. Requires scope comments:read." +
    UNTRUSTED_DESCRIPTION,
  scope: "comments:read",
  annotations: READ,
  input: z.object({ video_id: VideoIdSchema }),
  output: z.object({
    videoId: z.string(),
    commentsOpen: z.boolean().describe("Viewers can currently post on the share page."),
    total: z.number(),
    threads: z.array(Comment.extend({ replies: z.array(Comment) })),
    untrusted: Untrusted,
  }),
  async run(args, ctx) {
    const doc = await videoFor(ctx, args.video_id, "owner");
    const [rows, open] = await Promise.all([
      listVideoComments(ctx.env.DB, doc.videoId, MAX_COMMENTS_PER_VIDEO),
      commentsOpen(ctx.env, doc),
    ]);
    const all = rows.map((r) => toPublicComment(r, doc.uid));
    const tops = all.filter((c) => c.parentId === null || !all.some((p) => p.commentId === c.parentId));
    const threads = tops.map((t) => ({
      ...commentOf(t),
      replies: all.filter((r) => r.parentId === t.commentId).map(commentOf),
    }));
    const lines = threads.flatMap((t) => [
      `[${formatSeconds(t.videoTime)}] ${oneLine(t.authorName, 40)}${t.isOwner ? " (owner)" : ""}: ${oneLine(t.body, 500)}${t.annotation ? " [drawing]" : ""} (id ${t.commentId})`,
      ...t.replies.map((r) => `    ↳ ${oneLine(r.authorName, 40)}${r.isOwner ? " (owner)" : ""}: ${oneLine(r.body, 500)}`),
    ]);
    return {
      videoId: doc.videoId,
      text:
        all.length === 0
          ? `No comments on ${doc.videoId}.${open ? "" : " Comments are closed on its share page."}`
          : `${all.length} comments in ${threads.length} threads on ${doc.videoId}:\n${fenced(lines)}`,
      structured: { videoId: doc.videoId, commentsOpen: open, total: all.length, threads, untrusted: true as const },
    };
  },
});

/** Documents the v1 drawing format for the model. The AUTHORITATIVE check is
 *  lib/comments.ts parseCommentAnnotation, run by postComment — this schema
 *  is deliberately loose so it can never disagree with it. */
const AnnotationInput = z
  .object({
    v: z.literal(1),
    shapes: z
      .array(
        z
          .object({
            kind: z.enum(ANNOTATION_KINDS),
            color: z.string().describe("#rrggbb"),
            size: z.union([z.literal(1), z.literal(2), z.literal(3)]).describe("1 small, 2 medium, 3 large"),
            points: z.array(z.tuple([z.number(), z.number()])).optional().describe("pen/highlight: the stroke's [x, y] points"),
            from: z.tuple([z.number(), z.number()]).optional().describe("arrow/rect/ellipse: start [x, y]"),
            to: z.tuple([z.number(), z.number()]).optional().describe("arrow/rect/ellipse: end [x, y]"),
            at: z.tuple([z.number(), z.number()]).optional().describe("text: anchor [x, y]"),
            text: z.string().optional().describe("text: the label, ≤ 140 characters"),
          })
          .loose(),
      )
      .max(100),
  })
  .loose()
  .describe(
    "Optional drawing on the frame at video_time. Coordinates are 0–1 fractions of the VIDEO FRAME (0,0 top-left). Not allowed on replies.",
  );

const postCommentTool = defineTool({
  name: "post_comment",
  title: "Post comment",
  description:
    `Post a comment on one of the account's videos, as the owner: it shows on the public share page with the owner badge and the account's name followed by "${AGENT_NAME_SUFFIX.trim()}". Pass parent_id (a top-level comment id from list_comments) to reply; replies sit at their thread's time and cannot carry a drawing. The video must be public with comments switched on, on a plan that includes comments. At most ${COMMENT_RATE_LIMIT} posts per 10 minutes per token. Requires scope comments:write.`,
  scope: "comments:write",
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  input: z.object({
    video_id: VideoIdSchema,
    body: z.string().describe(`The comment text, 1–${MAX_COMMENT_LENGTH} characters.`),
    parent_id: z.string().optional().describe("Reply to this top-level comment (an id from list_comments)."),
    video_time: z.number().min(0).optional().describe("Seconds into the video to anchor a top-level comment at. Default 0."),
    annotation: AnnotationInput.optional(),
  }),
  output: z.object({
    videoId: z.string(),
    shareUrl: z.string(),
    comment: Comment.extend({ parentId: z.string().nullable() }),
  }),
  async run(args, ctx) {
    const doc = await videoFor(ctx, args.video_id, "owner");
    if (!(await commentsOpen(ctx.env, doc))) {
      throw new ToolError(
        "Comments are not open on this video: it must be ready, public, have comments switched on, and be on a plan that includes comments and sharing.",
        doc.videoId,
      );
    }
    // The share page's body cap, applied to what the agent sent.
    if (JSON.stringify(args).length > MAX_COMMENT_REQUEST_BYTES) {
      throw new ToolError("Comment is too large.", doc.videoId);
    }
    // Per token, not per IP: cloud agents share egress addresses.
    if (!(await fixedWindowAllow(ctx.env.DB, `comment:agent:${ctx.principal.tokenId}`, COMMENT_RATE_LIMIT, COMMENT_RATE_WINDOW_SEC))) {
      throw new ToolError("Slow down — at most 10 comments per 10 minutes per token. Try again later.", doc.videoId);
    }
    const owner = await ctx.env.DB.prepare(`SELECT name, image FROM "user" WHERE id = ?`)
      .bind(ctx.principal.uid)
      .first<{ name: string | null; image: string | null }>();
    const result = await postComment(
      ctx.env,
      doc,
      { body: args.body, videoTime: args.video_time, parentId: args.parent_id, annotation: args.annotation },
      {
        authorName: agentCommentAuthorName(owner?.name),
        authorUid: ctx.principal.uid,
        authorImage: sessionAvatar(owner?.image),
      },
    );
    if (!result.ok) throw new ToolError(result.error, doc.videoId);
    const c = result.comment;
    return {
      videoId: doc.videoId,
      text: `Posted ${c.parentId ? "a reply" : "a comment"} at ${formatSeconds(c.videoTime)} on ${doc.videoId} as "${c.authorName}" (id ${c.commentId}).`,
      structured: {
        videoId: doc.videoId,
        shareUrl: shareUrlFor(ctx.env, doc.videoId),
        comment: { ...commentOf(c), parentId: c.parentId },
      },
    };
  },
});

// ---------------------------------------------------------------------------
// Share settings
// ---------------------------------------------------------------------------

/** Patch column → the tool argument that set it. */
const PATCH_FIELD: Record<keyof ShareControlsPatch, string> = {
  allowDownload: "allow_download",
  passwordHash: "password",
  expiresAt: "expires_at",
  maxViews: "max_views",
  brandAccent: "brand_accent",
  showVersionHistory: "show_version_history",
  ctaLabel: "cta",
  ctaUrl: "cta",
  profileVisible: "profile_visible",
};

const SETTING_ARGS = [
  "is_private",
  "allow_download",
  "password",
  "expires_at",
  "max_views",
  "brand_accent",
  "show_version_history",
  "cta",
  "profile_visible",
] as const;

const updateShareSettings = defineTool({
  name: "update_share_settings",
  title: "Update share settings",
  description:
    "Change the share-page settings of one of the account's videos: privacy, a password (set a string, or null to remove it), link expiry, a viewer cap, the download button, the brand accent, version history, the call-to-action button and profile listing. Pass only what should change; anything omitted is left alone. Never deletes anything. Requires scope videos:write.",
  scope: "videos:write",
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  input: z
    .object({
      video_id: VideoIdSchema,
      is_private: z.boolean().optional().describe("true: only the owner (and their team) can play it. false: anyone with the link."),
      allow_download: z.boolean().optional().describe("Show a download button on the share page."),
      password: z.string().min(1).max(100).nullable().optional().describe("Set a share-page password, or null to remove it."),
      expires_at: z.iso.datetime({ offset: true }).nullable().optional().describe("ISO-8601 time the link stops playing, or null for never."),
      max_views: z.int().min(0).max(1_000_000).nullable().optional().describe("Distinct viewers allowed; 0 or null for unlimited."),
      brand_accent: z.string().regex(/^#[0-9a-fA-F]{6}$/, { error: "brand_accent must be #RRGGBB" }).nullable().optional(),
      show_version_history: z.boolean().optional().describe("Let viewers pick older versions of the video."),
      cta: z
        .object({
          label: z.string().trim().min(1).max(60),
          url: z.string().max(300).regex(/^https:\/\//, { error: "cta.url must be an https URL" }),
        })
        .nullable()
        .optional()
        .describe("Call-to-action button {label, https url}, or null to remove it."),
      profile_visible: z.boolean().optional().describe("List the video on the owner's public profile page."),
    })
    .refine((a) => SETTING_ARGS.some((k) => a[k] !== undefined), { error: "Pass at least one setting to change." }),
  output: z.object({
    videoId: z.string(),
    updated: z.array(z.string()).describe("The arguments that were applied."),
    ignored: z.array(z.string()).describe("Arguments passed but not applied (no valid value)."),
    shareUrl: z.string(),
    share: ShareSettings,
  }),
  async run(args, ctx) {
    const doc = await videoFor(ctx, args.video_id, "owner");
    const body: ShareControlsBody = {};
    if (args.allow_download !== undefined) body.allowDownload = args.allow_download;
    if (args.password !== undefined) body.password = args.password;
    if (args.expires_at !== undefined) body.expiresAt = args.expires_at;
    if (args.max_views !== undefined) body.maxViews = args.max_views;
    if (args.brand_accent !== undefined) body.brandAccent = args.brand_accent;
    if (args.show_version_history !== undefined) body.showVersionHistory = args.show_version_history;
    if (args.profile_visible !== undefined) body.profileVisible = args.profile_visible;
    if (args.cta !== undefined) {
      body.ctaLabel = args.cta === null ? null : args.cta.label;
      body.ctaUrl = args.cta === null ? null : args.cta.url;
    }
    // The dashboard's own validation (lib/video-share.ts).
    const patch = await shareControlsPatch(doc.videoId, body);
    const updated = new Set<string>();
    if (Object.keys(patch).length > 0) {
      await applyShareControls(ctx.env, doc.videoId, patch);
      for (const key of Object.keys(patch) as Array<keyof ShareControlsPatch>) updated.add(PATCH_FIELD[key]);
    }
    if (args.is_private !== undefined) {
      // PATCH /video/:id/privacy's write + its MANDATORY metadata purge.
      await setSharedVideoPrivacy(ctx.env.DB, doc.videoId, args.is_private);
      await purgeVideoMeta(doc.videoId);
      updated.add("is_private");
    }
    const ignored = SETTING_ARGS.filter((k) => args[k] !== undefined && !updated.has(k));
    const fresh = (await getSharedVideo(ctx.env.DB, doc.videoId)) ?? doc;
    return {
      videoId: doc.videoId,
      text:
        `Updated ${updated.size > 0 ? [...updated].join(", ") : "nothing"} on ${doc.videoId}` +
        `${ignored.length ? `; ignored ${ignored.join(", ")} (no valid value)` : ""}.`,
      structured: {
        videoId: doc.videoId,
        updated: [...updated],
        ignored,
        shareUrl: shareUrlFor(ctx.env, doc.videoId),
        share: shareSettingsOf(fresh),
      },
    };
  },
});

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------

const Bucket = (key: "viewers" | "sessions" | "count") => z.array(z.object({ second: z.number(), [key]: z.number() }));

const getVideoAnalytics = defineTool({
  name: "get_video_analytics",
  title: "Get video analytics",
  description:
    "Viewer analytics for one of the account's videos: views, plays, completions, CTA clicks, average watched seconds, a per-second watch heatmap, where viewers stopped (drop-off), click hot spots, top countries and top referrers. Requires scope analytics:read." +
    UNTRUSTED_DESCRIPTION,
  scope: "analytics:read",
  annotations: READ,
  input: z.object({ video_id: VideoIdSchema }),
  output: z.object({
    videoId: z.string(),
    durationSeconds: z.number(),
    views: z.number(),
    plays: z.number(),
    completions: z.number(),
    ctaClicks: z.number(),
    ctaLabel: z.string().nullable(),
    ctaUrl: z.string().nullable(),
    avgWatchedSeconds: z.number(),
    watchHeatmap: Bucket("viewers").describe("Distinct viewers per watched second."),
    dropOff: Bucket("sessions").describe("Sessions whose furthest watched second is this one."),
    clicks: Bucket("count").describe("Viewer clicks on the player per second, busiest first."),
    countries: z.array(z.object({ country: z.string(), count: z.number() })),
    referrers: z.array(z.object({ referrer: z.string(), count: z.number() })),
    untrusted: Untrusted,
  }),
  async run(args, ctx) {
    const doc = await videoFor(ctx, args.video_id, "owner");
    const a = await videoAnalytics(ctx.env.DB, doc);
    const { projectId: _projectId, ...rest } = a;
    const top = <T,>(rows: T[], f: (r: T) => string) => rows.slice(0, 5).map(f).join(", ") || "none";
    return {
      videoId: doc.videoId,
      text:
        `${doc.videoId}: ${a.views} views, ${a.plays} plays, ${a.completions} completions, ${a.ctaClicks} CTA clicks; ` +
        `average watched ${formatSeconds(a.avgWatchedSeconds)} of ${formatSeconds(a.durationSeconds)}. ` +
        `Top countries: ${top(a.countries, (r) => `${r.country} ${r.count}`)}.\n` +
        fenced([`Top referrers: ${top(a.referrers, (r) => `${oneLine(r.referrer, 80)} (${r.count})`)}`]),
      structured: { ...rest, untrusted: true as const },
    };
  },
});

// ---------------------------------------------------------------------------
// Playlists
// ---------------------------------------------------------------------------

const listPlaylists = defineTool({
  name: "list_playlists",
  title: "List playlists",
  description:
    "The account's private playlists (the folders in the web library), each with its video ids in order. Requires scope playlists:read.",
  scope: "playlists:read",
  annotations: READ,
  input: z.object({}),
  output: z.object({
    playlists: z.array(
      z.object({
        playlistId: z.string(),
        name: z.string(),
        emoji: z.string().nullable(),
        videoIds: z.array(z.string()),
        createdAt: z.string(),
      }),
    ),
  }),
  async run(_args, ctx) {
    const playlists = await listUserPlaylists(ctx.env.DB, ctx.principal.uid);
    return {
      text:
        playlists.length === 0
          ? "No playlists yet. Create them in the CaptureCat web library."
          : playlists.map((p) => `- ${p.playlistId} · ${p.emoji ? `${p.emoji} ` : ""}${oneLine(p.name, 60)} · ${p.videoIds.length} videos`).join("\n"),
      structured: { playlists },
    };
  },
});

const addToPlaylist = defineTool({
  name: "add_to_playlist",
  title: "Add video to playlist",
  description:
    "Add one of the account's videos to one of its playlists (ids from list_videos and list_playlists). Adding a video that is already there changes nothing. Requires scope playlists:write.",
  scope: "playlists:write",
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  input: z.object({
    playlist_id: z.string().trim().min(1).max(64).describe("A playlistId from list_playlists."),
    video_id: VideoIdSchema,
  }),
  output: z.object({ playlistId: z.string(), videoId: z.string(), added: z.literal(true) }),
  async run(args, ctx) {
    const result = await addVideoToPlaylist(ctx.env.DB, ctx.principal.uid, args.playlist_id, args.video_id);
    if (!result.ok) throw new ToolError(`${result.error}. Use list_playlists and list_videos for valid ids.`, args.video_id);
    return {
      videoId: result.videoId,
      text: `${result.videoId} is in playlist ${result.playlistId}.`,
      structured: { playlistId: result.playlistId, videoId: result.videoId, added: true as const },
    };
  },
});

// ---------------------------------------------------------------------------
// Screenshots
// ---------------------------------------------------------------------------

/** Bigger renders are refused inline (they still used a render): MCP
 *  results travel as one JSON body, and agents choke on huge images. */
export const MAX_INLINE_SCREENSHOT_BYTES = 4 * 1024 * 1024;
/** Renders per token per minute — the /api/screenshot/take per-IP ceiling,
 *  keyed on the token because cloud agents share egress addresses. */
const SCREENSHOT_RATE_LIMIT = 10;

const takeScreenshotTool = defineTool({
  name: "take_screenshot",
  title: "Take screenshot",
  description:
    "Render a public web page to an image with the CaptureCat Screenshot API and return it inline (or, with store=true, save it to the account's storage and return a download URL valid for an hour). Each call uses one render from the plan's monthly quota, including failed renders. Pages behind a login cannot be captured. Needs a plan with the Screenshot API. Requires scope screenshots.",
  scope: "screenshots",
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  input: z.object({
    url: z.string().min(1).max(2048).describe("Absolute http(s) URL of a public page. Private, local and internal hosts are refused."),
    device: z.enum(["desktop", "tablet", "mobile"]).optional().describe("Viewport preset. Default desktop (1440×900)."),
    full_page: z.boolean().optional().describe("Capture the whole scrollable page, not just the viewport."),
    max_height_multiple: z.int().min(1).max(10).optional().describe("With full_page: cap the height at N viewports."),
    viewport_width: z.int().min(100).max(3840).optional(),
    viewport_height: z.int().min(100).max(3840).optional(),
    device_scale_factor: z.int().min(1).max(3).default(1).describe("Pixel ratio. Default 1 here (the API's default is the preset's) to keep inline images small."),
    format: z.enum(["png", "jpeg", "webp"]).default("jpeg").describe("Default jpeg here, for smaller inline images."),
    quality: z.int().min(1).max(100).optional().describe("jpeg/webp quality."),
    delay: z.int().min(0).max(10).optional().describe("Extra seconds to wait after load."),
    dark_mode: z.boolean().optional(),
    block_cookie_banners: z.boolean().optional(),
    block_chats: z.boolean().optional(),
    hide_selectors: z.string().max(4200).optional().describe("Comma-separated CSS selectors to hide (≤ 20)."),
    store: z.boolean().default(false).describe("Save to the account's storage and return a download URL instead of the image (needs a plan with image uploads)."),
  }),
  output: z.object({
    url: z.string(),
    format: z.enum(["png", "jpeg", "webp"]),
    bytes: z.number().describe("Image size; 0 when stored (see download)."),
    delivery: z.enum(["inline", "stored"]),
    download: z
      .object({ url: z.string(), key: z.string(), cacheKey: z.string(), expiresInSeconds: z.number() })
      .nullable(),
    quota: z.object({ limit: z.number(), remaining: z.number() }),
  }),
  async run(args, ctx) {
    if (!(await fixedWindowAllow(ctx.env.DB, `shot:agent:${ctx.principal.tokenId}`, SCREENSHOT_RATE_LIMIT, 60))) {
      throw new ToolError(`Slow down — at most ${SCREENSHOT_RATE_LIMIT} screenshots a minute per token.`);
    }
    const raw = Object.fromEntries(Object.entries(args).filter(([, v]) => v !== undefined));
    // "key" door: a programmatic credential is gated on `screenshotApi`, the
    // same flag and monthly counter as an access key.
    const out = await takeScreenshot(ctx.env, { uid: ctx.principal.uid, claims: ctx.principal.claims, door: "key" }, raw);
    if (!out.ok) throw new ToolError(`${out.error.message} (${out.error.code})`);
    const quota = { limit: out.quota.cap, remaining: Math.max(0, out.quota.cap - out.quota.used) };
    if (out.kind === "stored") {
      return {
        text: `Stored a ${out.stored.format} screenshot of ${args.url}. Download (1 hour): ${out.stored.url}`,
        structured: {
          url: args.url,
          format: out.stored.format,
          bytes: 0,
          delivery: "stored" as const,
          download: { url: out.stored.url, key: out.stored.key, cacheKey: out.stored.cache_key, expiresInSeconds: out.stored.expires_in },
          quota,
        },
      };
    }
    if (out.bytes.byteLength > MAX_INLINE_SCREENSHOT_BYTES) {
      throw new ToolError(
        `The screenshot is ${(out.bytes.byteLength / 1024 / 1024).toFixed(1)} MB, too large to return inline (it used a render). ` +
          "Retry with format jpeg or webp, device_scale_factor 1, a smaller viewport, or store=true for a download URL.",
      );
    }
    return {
      text: `Screenshot of ${args.url} (${out.format}, ${Math.round(out.bytes.byteLength / 1024)} KB). ${quota.remaining} renders left this month.`,
      structured: {
        url: args.url,
        format: out.format,
        bytes: out.bytes.byteLength,
        delivery: "inline" as const,
        download: null,
        quota,
      },
      extra: [{ type: "image" as const, data: toBase64(out.bytes), mimeType: out.contentType.split(";")[0].trim() }],
    };
  },
});

// ---------------------------------------------------------------------------

export const TOOLS: ToolDefinition[] = [
  getAccount,
  listVideos,
  getVideo,
  getTranscriptTool,
  getSummary,
  searchTranscriptsTool,
  listComments,
  postCommentTool,
  updateShareSettings,
  getVideoAnalytics,
  listPlaylists,
  addToPlaylist,
  takeScreenshotTool,
] as unknown as ToolDefinition[];

// Every tool names a scope a token can actually hold.
for (const tool of TOOLS) {
  if (!(AGENT_SCOPES as readonly string[]).includes(tool.scope)) throw new Error(`${tool.name}: unknown scope ${tool.scope}`);
}

export function findTool(name: string): ToolDefinition | undefined {
  return TOOLS.find((t) => t.name === name);
}
