import { useMemo, useState } from "react";

import { formatTime, groupMarkers, type CommentThread, type ShareComment } from "@/lib/share/comments";
import { AnnotationThumb, type MediaSize } from "./annotation-layer";
import { CommentAvatar, OwnerBadge } from "./comment-avatar";

/** Stacked avatars peek out this far behind the front one. */
const PEEK_PX = 5;

/**
 * Commenter avatars along the scrubber. Top-level comments only (replies
 * live under their thread); markers that would overlap at the current track
 * width collapse into a stack with a count. Hover/focus shows a preview card,
 * click jumps to the moment. Sits ABOVE the track, outside the seek target,
 * so hovering an avatar never fights the scrubber's own hover tooltip.
 */
export function CommentMarkers({
  threads,
  total,
  trackWidth,
  media,
  accent,
  activeId,
  onJump,
}: {
  threads: CommentThread[];
  total: number;
  trackWidth: number;
  media: MediaSize | null;
  accent: string;
  activeId: string | null;
  onJump: (comment: ShareComment) => void;
}) {
  const [hovered, setHovered] = useState<string | null>(null);
  // Smaller faces on a phone-sized player, where the frame is precious.
  const AVATAR_PX = trackWidth < 480 ? 16 : 20;

  const groups = useMemo(() => {
    const items = threads.map((t) => ({ id: t.comment.commentId, time: t.comment.videoTime, thread: t }));
    // A stack is wider than one avatar; keep stacks from touching.
    return groupMarkers(items, total, trackWidth, AVATAR_PX + PEEK_PX * 2);
  }, [threads, total, trackWidth, AVATAR_PX]);

  if (total <= 0 || trackWidth <= 0 || groups.length === 0) return null;

  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-full mb-[14px]" style={{ height: AVATAR_PX + 6 }}>
      {groups.map((group) => {
        const shown = group.items.slice(0, 3);
        const count = group.items.length;
        const isHovered = hovered === group.key;
        const isActive = group.items.some((i) => i.id === activeId);
        const first = group.items[0].thread.comment;
        const label =
          count === 1
            ? `Comment by ${first.authorName} at ${formatTime(first.videoTime)}`
            : `${count} comments from ${formatTime(first.videoTime)}`;
        // Keep the card on-screen near the ends of the track.
        const align = group.ratio < 0.18 ? "left" : group.ratio > 0.82 ? "right" : "center";
        return (
          <div
            key={group.key}
            className="absolute bottom-0"
            style={{ left: `${group.ratio * 100}%`, zIndex: isHovered ? 20 : isActive ? 10 : 1 }}
          >
            <button
              type="button"
              aria-label={label}
              onPointerEnter={() => setHovered(group.key)}
              onPointerLeave={() => setHovered((h) => (h === group.key ? null : h))}
              onFocus={() => setHovered(group.key)}
              onBlur={() => setHovered((h) => (h === group.key ? null : h))}
              onPointerDown={(e) => e.stopPropagation()}
              onClick={(e) => {
                e.stopPropagation();
                onJump(first);
              }}
              className={`pointer-events-auto relative block -translate-x-1/2 rounded-full outline-none transition-transform duration-150 focus-visible:ring-2 focus-visible:ring-white/70 motion-safe:hover:-translate-y-0.5 ${
                isActive ? "-translate-y-0.5" : ""
              }`}
              style={{ width: AVATAR_PX + (shown.length - 1) * PEEK_PX, height: AVATAR_PX }}
            >
              {/* Painted back to front: the earliest comment's avatar sits
                  on top at the left, later ones peek out behind it. */}
              {shown
                .map((item, i) => ({ item, i }))
                .reverse()
                .map(({ item, i }) => (
                  <span key={item.id} className="absolute top-0" style={{ left: i * PEEK_PX, zIndex: shown.length - i }}>
                    <CommentAvatar
                      name={item.thread.comment.authorName}
                      image={item.thread.comment.authorImage}
                      size={AVATAR_PX}
                      ring="ring-[1.5px] ring-black/70"
                      className="shadow-[0_1px_4px_rgba(0,0,0,0.5)]"
                    />
                  </span>
                ))}
              {isActive && (
                <span
                  aria-hidden
                  className="absolute left-0 top-0 rounded-full"
                  style={{ width: AVATAR_PX, height: AVATAR_PX, boxShadow: `0 0 0 2px ${accent}`, zIndex: 9 }}
                />
              )}
              {count > 1 && (
                <span className="absolute -right-2 -top-1.5 z-10 min-w-[15px] rounded-full bg-white px-1 text-center text-[9px] font-bold leading-[14px] text-black shadow">
                  {count}
                </span>
              )}
              {/* Stem pointing at the exact moment on the track. */}
              <span
                aria-hidden
                className="absolute top-full h-[9px] w-px -translate-x-1/2 bg-white/45"
                style={{ left: AVATAR_PX / 2 }}
              />
            </button>

            {isHovered && (
              <div
                role="tooltip"
                className={`pointer-events-none absolute bottom-full mb-2.5 w-[248px] rounded-xl bg-[#101218]/95 p-2.5 text-left shadow-2xl ring-1 ring-white/12 backdrop-blur-md motion-safe:animate-[cc-pop-in_140ms_ease-out] ${
                  align === "left" ? "-left-3" : align === "right" ? "-right-3" : "left-0 -translate-x-1/2"
                }`}
              >
                <ul className="space-y-2">
                  {shown.map(({ id, thread }) => {
                    const c = thread.comment;
                    return (
                      <li key={id} className="flex items-start gap-2">
                        <CommentAvatar name={c.authorName} image={c.authorImage} size={22} />
                        <div className="min-w-0 flex-1">
                          <p className="flex items-center gap-1.5 text-[11px] text-white/50">
                            <span className="truncate font-medium text-white/85">{c.authorName}</span>
                            {c.isOwner && <OwnerBadge accent={accent} />}
                            <span className="ml-auto shrink-0 tabular-nums">{formatTime(c.videoTime)}</span>
                          </p>
                          <p className="mt-0.5 line-clamp-2 break-words text-xs leading-snug text-white/80">{c.body}</p>
                          {(c.annotation || thread.replies.length > 0) && (
                            <div className="mt-1.5 flex items-center gap-2 text-[10px] text-white/45">
                              {c.annotation && (
                                <AnnotationThumb shapes={c.annotation.shapes} media={media} width={56} />
                              )}
                              {thread.replies.length > 0 && (
                                <span>
                                  {thread.replies.length} repl{thread.replies.length === 1 ? "y" : "ies"}
                                </span>
                              )}
                            </div>
                          )}
                        </div>
                      </li>
                    );
                  })}
                </ul>
                {count > shown.length && (
                  <p className="mt-2 border-t border-white/[0.07] pt-1.5 text-[11px] text-white/45">
                    and {count - shown.length} more
                  </p>
                )}
              </div>
            )}
          </div>
        );
      })}
      <style>{`
        @keyframes cc-pop-in {
          from { opacity: 0; transform: translateY(4px) scale(0.98); }
          to { opacity: 1; transform: translateY(0) scale(1); }
        }
      `}</style>
    </div>
  );
}
