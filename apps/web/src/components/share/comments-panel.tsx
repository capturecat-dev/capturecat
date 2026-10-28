import { useEffect, useRef, useState, type RefObject } from "react";

import type { AnnotationShape } from "@/lib/share/annotation";
import {
  formatTime,
  relativeTime,
  type CommentThread,
  type CommentViewer,
  type ShareComment,
} from "@/lib/share/comments";
import { PenIcon } from "./annotation-editor";
import { AnnotationThumb, type MediaSize } from "./annotation-layer";
import { CommentAvatar, OwnerBadge } from "./comment-avatar";

const inputClass =
  "w-full rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-white placeholder-white/30 transition-colors focus:border-white/30 focus:outline-none";

export interface ComposerProps {
  viewer: CommentViewer | null;
  authorName: string;
  onAuthorName: (v: string) => void;
  draft: string;
  onDraft: (v: string) => void;
  /** Captures the comment's moment the first time the composer is used. */
  onStartDraft: () => void;
  draftTime: number | null;
  /** Where the comment would land if posted now (draft time, else playhead). */
  anchorTime: number;
  onSeekDraftTime: () => void;
  drawing: boolean;
  drawingShapes: AnnotationShape[];
  onToggleDraw: () => void;
  onRemoveDrawing: () => void;
  posting: boolean;
  postError: string | null;
  onSubmit: () => void;
}

/**
 * The Comments tab: threads (one level of replies) over a composer pinned at
 * the bottom. Everything that touches the player — seeking, showing a
 * drawing, drawing mode — is a callback; this component owns only the
 * inline reply box.
 */
export function CommentsPanel({
  threads,
  total,
  loaded,
  accent,
  media,
  activeId,
  flashId,
  listRef,
  onSeek,
  onShow,
  onHover,
  onReply,
  composer,
}: {
  threads: CommentThread[];
  total: number;
  loaded: boolean;
  accent: string;
  media: MediaSize | null;
  /** The comment whose drawing is on the player now. */
  activeId: string | null;
  /** Briefly highlighted after a scrubber jump. */
  flashId: string | null;
  listRef: RefObject<HTMLDivElement | null>;
  onSeek: (time: number) => void;
  onShow: (comment: ShareComment) => void;
  onHover: (commentId: string | null) => void;
  onReply: (parentId: string, body: string) => Promise<string | null>;
  composer: ComposerProps;
}) {
  const [replyingTo, setReplyingTo] = useState<string | null>(null);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div
        ref={listRef}
        className="relative max-h-[60vh] min-h-[140px] flex-1 overflow-y-auto overscroll-contain px-3 py-3 [scrollbar-width:thin] sm:px-4 lg:max-h-none"
      >
        {!loaded && (
          <div className="space-y-4 py-1" aria-hidden>
            {[0, 1, 2].map((i) => (
              <div key={i} className="flex gap-3">
                <span className="h-8 w-8 shrink-0 rounded-full bg-white/[0.06]" />
                <div className="flex-1 space-y-2 pt-1">
                  <span className="block h-2.5 w-24 rounded bg-white/[0.06]" />
                  <span className="block h-2.5 w-4/5 rounded bg-white/[0.05]" />
                </div>
              </div>
            ))}
          </div>
        )}
        {loaded && threads.length === 0 && (
          <div className="grid h-full place-items-center px-4 py-8 text-center">
            <div>
              <p className="text-sm text-white/60">No comments yet.</p>
              <p className="mt-1 text-xs leading-relaxed text-white/40">
                Pause on a moment and leave a note — or press{" "}
                <kbd className="rounded bg-white/[0.08] px-1 font-sans text-white/60">D</kbd> to draw on the frame.
              </p>
            </div>
          </div>
        )}
        <ol className="space-y-1">
          {threads.map((thread) => (
            <ThreadItem
              key={thread.comment.commentId}
              thread={thread}
              total={total}
              accent={accent}
              media={media}
              active={activeId === thread.comment.commentId}
              flash={flashId === thread.comment.commentId}
              replying={replyingTo === thread.comment.commentId}
              onToggleReply={() =>
                setReplyingTo((r) => (r === thread.comment.commentId ? null : thread.comment.commentId))
              }
              onCloseReply={() => setReplyingTo(null)}
              onSeek={onSeek}
              onShow={onShow}
              onHover={onHover}
              onReply={onReply}
              viewer={composer.viewer}
            />
          ))}
        </ol>
      </div>
      <Composer {...composer} accent={accent} media={media} />
    </div>
  );
}

function ThreadItem({
  thread,
  total,
  accent,
  media,
  active,
  flash,
  replying,
  onToggleReply,
  onCloseReply,
  onSeek,
  onShow,
  onHover,
  onReply,
  viewer,
}: {
  thread: CommentThread;
  total: number;
  accent: string;
  media: MediaSize | null;
  active: boolean;
  flash: boolean;
  replying: boolean;
  onToggleReply: () => void;
  onCloseReply: () => void;
  onSeek: (time: number) => void;
  onShow: (comment: ShareComment) => void;
  onHover: (commentId: string | null) => void;
  onReply: (parentId: string, body: string) => Promise<string | null>;
  viewer: CommentViewer | null;
}) {
  const c = thread.comment;
  const jump = () => (c.annotation ? onShow(c) : onSeek(c.videoTime));
  return (
    <li
      data-comment-id={c.commentId}
      onPointerEnter={() => onHover(c.commentId)}
      onPointerLeave={() => onHover(null)}
      className={`rounded-xl px-2 py-2.5 transition-[background-color,box-shadow] duration-500 motion-reduce:transition-none ${
        flash ? "bg-white/[0.09] shadow-[inset_0_0_0_1px_rgba(255,255,255,0.16)]" : active ? "bg-white/[0.06] shadow-[inset_0_0_0_1px_rgba(255,255,255,0.1)]" : ""
      }`}
    >
      <CommentBody comment={c} accent={accent} size={30} onTime={jump} total={total} />
      {c.annotation && (
        <button
          type="button"
          onClick={() => onShow(c)}
          className="group/draw ml-[42px] mt-2 flex items-center gap-2.5 rounded-lg bg-white/[0.03] p-1 pr-3 text-left ring-1 ring-white/10 transition-colors hover:bg-white/[0.07] hover:ring-white/20"
          aria-label={`Show ${c.authorName}'s drawing on the video at ${formatTime(c.videoTime)}`}
        >
          <AnnotationThumb shapes={c.annotation.shapes} media={media} width={72} />
          <span className="text-xs leading-tight">
            <span className="flex items-center gap-1 font-medium text-white/75">
              <PenIcon className="h-3.5 w-3.5" />
              Drawing · {c.annotation.shapes.length} mark{c.annotation.shapes.length === 1 ? "" : "s"}
            </span>
            <span className="mt-0.5 block text-white/40 transition-colors group-hover/draw:text-white/65">
              {active ? "On the video now" : "Show on the video"}
            </span>
          </span>
        </button>
      )}
      <div className="ml-[42px] mt-1.5 flex items-center gap-3">
        <button
          type="button"
          onClick={onToggleReply}
          aria-expanded={replying}
          className="text-xs font-medium text-white/45 transition-colors hover:text-white"
        >
          Reply
        </button>
      </div>

      {(thread.replies.length > 0 || replying) && (
        <div className="ml-[15px] mt-2 space-y-2.5 border-l border-white/[0.08] pl-[18px]">
          {thread.replies.map((r) => (
            <div key={r.commentId} data-comment-id={r.commentId}>
              <CommentBody comment={r} accent={accent} size={22} total={total} />
            </div>
          ))}
          {replying && (
            <ReplyBox
              parent={c}
              viewer={viewer}
              onReply={onReply}
              onClose={onCloseReply}
            />
          )}
        </div>
      )}
    </li>
  );
}

function CommentBody({
  comment: c,
  accent,
  size,
  onTime,
}: {
  comment: ShareComment;
  accent: string;
  size: number;
  total: number;
  onTime?: () => void;
}) {
  return (
    <div className="flex items-start gap-3" style={{ gap: size > 24 ? 12 : 10 }}>
      <CommentAvatar name={c.authorName} image={c.authorImage} size={size} className="mt-0.5" />
      <div className="min-w-0 flex-1">
        <p className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-white/50">
          <span className="font-medium text-white/85">{c.authorName}</span>
          {c.isOwner && <OwnerBadge accent={accent} />}
          {onTime && (
            <button
              type="button"
              onClick={onTime}
              className="rounded bg-white/[0.07] px-1.5 py-0.5 text-[11px] tabular-nums text-white/60 transition-colors hover:bg-white/[0.16] hover:text-white"
              title="Jump to this moment"
            >
              {formatTime(c.videoTime)}
            </button>
          )}
          <time dateTime={c.createdAt} className="text-white/30" title={c.createdAt ? new Date(c.createdAt).toLocaleString() : undefined}>
            {relativeTime(c.createdAt)}
          </time>
        </p>
        <p className="mt-0.5 whitespace-pre-line break-words text-sm leading-relaxed text-white/90">{c.body}</p>
      </div>
    </div>
  );
}

function ReplyBox({
  parent,
  viewer,
  onReply,
  onClose,
}: {
  parent: ShareComment;
  viewer: CommentViewer | null;
  onReply: (parentId: string, body: string) => Promise<string | null>;
  onClose: () => void;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const ref = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    ref.current?.focus({ preventScroll: true });
  }, []);

  const send = async () => {
    const body = text.trim();
    if (!body || busy) return;
    setBusy(true);
    setError(null);
    const err = await onReply(parent.commentId, body);
    setBusy(false);
    if (err) setError(err);
    else {
      setText("");
      onClose();
    }
  };

  return (
    <div className="flex items-start gap-2.5">
      {viewer ? (
        <CommentAvatar name={viewer.name} image={viewer.image} size={22} className="mt-1" />
      ) : (
        <span className="mt-1 h-[22px] w-[22px] shrink-0 rounded-full bg-white/[0.06] ring-1 ring-white/10" aria-hidden />
      )}
      <div className="min-w-0 flex-1">
        <textarea
          ref={ref}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              void send();
            } else if (e.key === "Escape") {
              e.preventDefault();
              onClose();
            }
          }}
          placeholder={`Reply to ${parent.authorName}…`}
          aria-label={`Reply to ${parent.authorName}`}
          maxLength={500}
          rows={1}
          className={`${inputClass} min-h-[38px] resize-none py-1.5`}
        />
        {error && <p className="mt-1 text-xs text-red-400">{error}</p>}
        <div className="mt-1.5 flex items-center justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded-full px-3 py-1 text-xs font-medium text-white/50 transition-colors hover:text-white"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={() => void send()}
            disabled={!text.trim() || busy}
            className="rounded-full border border-white/10 bg-white/[0.08] px-3.5 py-1 text-xs font-medium text-white transition-colors hover:bg-white/[0.16] disabled:cursor-not-allowed disabled:opacity-40"
          >
            {busy ? "Sending…" : "Reply"}
          </button>
        </div>
      </div>
    </div>
  );
}

function Composer({
  viewer,
  authorName,
  onAuthorName,
  draft,
  onDraft,
  onStartDraft,
  draftTime,
  anchorTime,
  onSeekDraftTime,
  drawing,
  drawingShapes,
  onToggleDraw,
  onRemoveDrawing,
  posting,
  postError,
  onSubmit,
  accent,
  media,
}: ComposerProps & { accent: string; media: MediaSize | null }) {
  const hasDrawing = drawingShapes.length > 0;
  return (
    <div className="shrink-0 space-y-2 border-t border-white/[0.06] bg-white/[0.015] p-3 sm:px-4">
      {viewer ? (
        <p className="flex items-center gap-2 text-xs text-white/50">
          <CommentAvatar name={viewer.name} image={viewer.image} size={20} />
          <span>
            Commenting as <span className="font-medium text-white/80">{viewer.name}</span>
          </span>
          {viewer.isOwner && <OwnerBadge accent={accent} />}
        </p>
      ) : (
        <input
          value={authorName}
          onChange={(e) => onAuthorName(e.target.value)}
          placeholder="Your name (optional)"
          aria-label="Your name"
          maxLength={40}
          className={`${inputClass} py-1.5`}
        />
      )}

      <textarea
        value={draft}
        onFocus={onStartDraft}
        onChange={(e) => {
          onStartDraft();
          onDraft(e.target.value);
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            onSubmit();
          }
        }}
        placeholder={hasDrawing || drawing ? "Say what you marked…" : "Comment at the current moment…"}
        aria-label="Comment"
        maxLength={500}
        rows={2}
        className={`${inputClass} resize-none`}
      />

      {hasDrawing && !drawing && (
        <div className="flex items-center gap-2.5 rounded-lg bg-white/[0.03] p-1 pr-2 ring-1 ring-white/10">
          <AnnotationThumb shapes={drawingShapes} media={media} width={56} />
          <span className="text-xs text-white/65">
            Drawing · {drawingShapes.length} mark{drawingShapes.length === 1 ? "" : "s"}
          </span>
          <button
            type="button"
            onClick={onToggleDraw}
            className="ml-auto rounded-full px-2.5 py-1 text-xs font-medium text-white/60 transition-colors hover:bg-white/[0.08] hover:text-white"
          >
            Edit
          </button>
          <button
            type="button"
            onClick={onRemoveDrawing}
            aria-label="Remove drawing"
            className="grid h-6 w-6 place-items-center rounded-full text-white/45 transition-colors hover:bg-white/[0.08] hover:text-white"
          >
            <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden>
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>
      )}

      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={onSeekDraftTime}
          className="rounded-md bg-white/[0.06] px-2 py-1 text-[11px] tabular-nums text-white/55 transition-colors hover:bg-white/[0.12] hover:text-white"
          title="The moment this comment is anchored to"
        >
          at {formatTime(draftTime ?? anchorTime)}
        </button>
        <button
          type="button"
          onClick={onToggleDraw}
          aria-pressed={drawing}
          title="Draw on the frame (D)"
          className={`flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium transition-colors ${
            drawing
              ? "border-transparent bg-white/[0.16] text-white"
              : "border-white/10 bg-white/[0.04] text-white/70 hover:border-white/20 hover:bg-white/[0.1] hover:text-white"
          }`}
          style={drawing ? { boxShadow: `0 0 0 1.5px ${accent}` } : undefined}
        >
          <PenIcon className="h-3.5 w-3.5" />
          {drawing ? "Drawing…" : "Draw"}
          <kbd className="font-sans text-[10px] text-white/40">D</kbd>
        </button>
        <button
          type="button"
          onClick={onSubmit}
          disabled={!draft.trim() || posting}
          className="ml-auto rounded-full border border-white/10 bg-white/[0.1] px-4 py-1.5 text-sm font-medium text-white transition-colors hover:bg-white/[0.18] disabled:cursor-not-allowed disabled:opacity-40"
        >
          {posting ? "Posting…" : "Post"}
        </button>
      </div>
      {postError && <p className="text-xs text-red-400" role="alert">{postError}</p>}
    </div>
  );
}
