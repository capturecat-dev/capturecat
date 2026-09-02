import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from "react";

import { API_URL } from "@/lib/api-url";
import { useViewerAnalytics } from "./use-viewer-analytics";

/** Annotation marker in output-time seconds (validated server-side). */
export interface AnnotationMarker {
  start: number;
  end: number;
  label?: string;
  autoPause?: boolean;
  pauseDuration?: number;
}

interface Comment {
  commentId: string;
  authorName: string;
  body: string;
  videoTime: number;
  createdAt: string;
}

interface SharePlayerProps {
  videoId: string;
  videoStreamUrl: string;
  durationSeconds: number;
  commentsEnabled: boolean;
  annotations: AnnotationMarker[];
  /** Owner brand accent for chrome tinting, "#RRGGBB" or null for default. */
  brandAccent?: string | null;
  /** Presigned-equivalent download endpoint, when the owner allows it. */
  downloadUrl?: string | null;
  /** AI chapter markers {start, label} — rendered beside annotation chips. */
  aiChapters?: { start: number; label: string }[];
  /** Transcript availability — the panel lazy-fetches when true. */
  hasTranscript?: boolean;
  /** API origin for reactions/transcript fetches. */
  apiUrl?: string;
  /** Seek here once metadata loads (?t= support). */
  startAt?: number | null;
  /** Owner call-to-action rendered over the player; clicks are tracked. */
  ctaLabel?: string | null;
  ctaUrl?: string | null;
  /** Watch-page header (YouTube-style shell): title + optional summary/date. */
  title?: string;
  summary?: string | null;
  createdAt?: string | null;
  /** Published version history (owner opt-in) + the version being played. */
  versions?: { version: number; createdAt: string; current: boolean }[];
  playVersion?: number;
}

function formatTime(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

/** Idle delay before the control bar fades out during playback. */
const IDLE_MS = 2400;

export default function SharePlayer({
  videoId,
  videoStreamUrl,
  durationSeconds,
  commentsEnabled,
  annotations,
  brandAccent,
  downloadUrl,
  aiChapters = [],
  hasTranscript = false,
  apiUrl = "",
  startAt = null,
  ctaLabel = null,
  ctaUrl = null,
  title = "",
  summary = null,
  createdAt = null,
  versions = [],
  playVersion,
}: SharePlayerProps) {
  const accent = brandAccent ?? "#FBBF24";
  // Stable per-browser id so "one reaction per user" survives reloads.
  const reactionSession = useRef("");
  if (!reactionSession.current && typeof window !== "undefined") {
    const stored = window.localStorage.getItem("cc-react-id");
    if (stored && /^[A-Za-z0-9_-]{8,64}$/.test(stored)) {
      reactionSession.current = stored;
    } else {
      reactionSession.current = crypto.randomUUID().replace(/-/g, "");
      window.localStorage.setItem("cc-react-id", reactionSession.current);
    }
  }
  const [myEmoji, setMyEmoji] = useState<string | null>(null);
  const [reactions, setReactions] = useState<{ emoji: string; videoTime: number }[]>([]);
  /** IG/TikTok-style floaters currently animating over the video. Each gets
   *  randomized drift/duration via CSS vars; removal on animation end. */
  const [floaters, setFloaters] = useState<
    { id: number; emoji: string; x: number; dx1: number; dx2: number; dur: number; size: number }[]
  >([]);
  const floaterSeq = useRef(0);
  const reactionsRef = useRef<{ emoji: string; videoTime: number }[]>([]);
  const spawnFloater = useCallback(
    (emoji: string, videoTime: number, totalDuration: number, fromPlayback: boolean) => {
      setFloaters((prev) => {
        const id = ++floaterSeq.current;
        // Anchored to the MOMENT: the emoji rises from the scrubber position
        // of its timestamp — live taps and replays alike — with a hair of
        // jitter so simultaneous emojis don't stack pixel-perfect.
        const fraction = totalDuration > 0 ? videoTime / totalDuration : 0;
        const x = Math.min(97, Math.max(3, fraction * 100 + (Math.random() - 0.5) * 3));
        const next = [
          ...prev,
          {
            id,
            emoji,
            x,
            dx1: (Math.random() - 0.5) * 60,
            dx2: (Math.random() - 0.5) * 90,
            dur: 1.9 + Math.random() * 1.1,
            size: fromPlayback ? 20 + Math.random() * 8 : 26 + Math.random() * 10,
          },
        ];
        // Bound concurrent floaters so a spam-tap doesn't wallpaper the video.
        return next.slice(-14);
      });
    },
    []
  );
  const [transcript, setTranscript] = useState<{ start: number; end: number; text: string }[]>([]);
  // Open by default: the transcript lives in the watch-page rail now, and an
  // empty collapsed rail card reads as a broken feature.
  const [transcriptOpen, setTranscriptOpen] = useState(true);
  const [transcriptFilter, setTranscriptFilter] = useState("");
  const [linkCopied, setLinkCopied] = useState(false);
  /** Long AI summaries collapse to a few lines, YouTube-description style. */
  const [descExpanded, setDescExpanded] = useState(false);
  const startAtDone = useRef(false);

  /** Per-emoji totals for the action pills, tabular alongside each emoji. */
  const reactionCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const r of reactions) {
      counts.set(r.emoji, (counts.get(r.emoji) ?? 0) + 1);
    }
    return counts;
  }, [reactions]);

  useEffect(() => {
    reactionsRef.current = reactions;
  }, [reactions]);

  useEffect(() => {
    if (!apiUrl) return;
    void fetch(
      `${apiUrl}/api/video/${videoId}/reactions?session=${reactionSession.current}`
    )
      .then((r) => (r.ok ? r.json() : { reactions: [] }))
      .then(
        (d: {
          reactions?: { emoji: string; videoTime: number }[];
          mine?: { emoji: string } | null;
        }) => {
          setReactions(d.reactions ?? []);
          setMyEmoji(d.mine?.emoji ?? null);
        }
      )
      .catch(() => {});
  }, [apiUrl, videoId]);

  useEffect(() => {
    if (!hasTranscript || !transcriptOpen || !apiUrl || transcript.length > 0) return;
    void fetch(`${apiUrl}/api/video/${videoId}/transcript`)
      .then((r) => (r.ok ? r.json() : { segments: [] }))
      .then((d: { segments?: { start: number; end: number; text: string }[] }) =>
        setTranscript(d.segments ?? [])
      )
      .catch(() => {});
  }, [hasTranscript, transcriptOpen, apiUrl, videoId, transcript.length]);

  const sendReaction = (emoji: string) => {
    const v = videoRef.current;
    const t = v ? v.currentTime : 0;
    const unliking = myEmoji === emoji;
    // Optimistic: one reaction per viewer — same emoji toggles off, a
    // different one replaces. Floater only when something lands.
    setMyEmoji(unliking ? null : emoji);
    if (!unliking) {
      spawnFloater(emoji, t, v?.duration || durationSeconds, false);
    }
    if (!apiUrl) return;
    void fetch(`${apiUrl}/api/video/${videoId}/reactions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ emoji, videoTime: t, sessionId: reactionSession.current }),
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((d: { mine?: { emoji: string } | null } | null) => {
        if (d) setMyEmoji(d.mine?.emoji ?? null);
        // Re-sync the strip so the previous reaction's dot moves/vanishes.
        return fetch(
          `${apiUrl}/api/video/${videoId}/reactions?session=${reactionSession.current}`
        );
      })
      .then((r) => (r && r.ok ? r.json() : null))
      .then((d: { reactions?: { emoji: string; videoTime: number }[] } | null) => {
        if (d?.reactions) setReactions(d.reactions);
      })
      .catch(() => {});
  };
  const videoRef = useRef<HTMLVideoElement>(null);
  // Owner-facing view/drop-off/click analytics; listeners attach to the
  // element directly, so the player's own handlers are unaffected.
  const { track } = useViewerAnalytics(videoId, videoRef);
  const shellRef = useRef<HTMLDivElement>(null);
  const barRef = useRef<HTMLDivElement>(null);
  // Auto-pause bookkeeping: markers already fired this viewing pass, and the
  // timeout that resumes playback. Seeking backward re-arms passed markers.
  const firedRef = useRef<Set<number>>(new Set());
  const resumeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastTimeRef = useRef(0);
  const idleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const draggingRef = useRef(false);

  const [comments, setComments] = useState<Comment[]>([]);
  const [commentsLoaded, setCommentsLoaded] = useState(false);
  const [authorName, setAuthorName] = useState("");
  const [draft, setDraft] = useState("");
  const [draftTime, setDraftTime] = useState<number | null>(null);
  const [posting, setPosting] = useState(false);
  const [postError, setPostError] = useState<string | null>(null);

  // ---- Transport state ----------------------------------------------------

  const [duration, setDuration] = useState(durationSeconds || 0);
  const [currentTime, setCurrentTime] = useState(0);
  const [paused, setPaused] = useState(true);
  const [buffered, setBuffered] = useState(0);
  const [muted, setMuted] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [controlsVisible, setControlsVisible] = useState(true);
  /** Pointer position over the scrubber, 0–1, or null when not hovering. */
  const [hoverRatio, setHoverRatio] = useState<number | null>(null);
  const [scrubbing, setScrubbing] = useState(false);

  // Duration from metadata wins; the prop is only a pre-metadata placeholder so
  // the marker positions do not visibly jump on load.
  const total = duration > 0 ? duration : durationSeconds;

  /** Marker geometry in percentages, memoised against the annotation list. */
  const markers = useMemo(() => {
    if (total <= 0) return [];
    return annotations.map((marker, index) => {
      const start = clamp(marker.start, 0, total);
      const end = clamp(Math.max(marker.end, marker.start), 0, total);
      return {
        index,
        marker,
        left: (start / total) * 100,
        // A zero-length annotation would render as an invisible hairline, so
        // every range gets a minimum on-screen presence.
        width: Math.max(((end - start) / total) * 100, 0.8),
      };
    });
  }, [annotations, total]);

  /** The annotation covering a given time, if any. */
  const markerAt = useCallback(
    (time: number) =>
      annotations.findIndex((m) => time >= m.start && time <= m.end),
    [annotations]
  );

  const hoverTime = hoverRatio === null ? null : hoverRatio * total;
  const hoveredMarker = hoverTime === null ? -1 : markerAt(hoverTime);

  // ---- Auto-pause at annotations -----------------------------------------

  const handleTimeUpdate = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;
    const t = video.currentTime;
    if (!draggingRef.current) setCurrentTime(t);

    const previous = lastTimeRef.current;
    lastTimeRef.current = t;
    if (video.paused || video.seeking) return;
    // Normal forward playback only — a seek jump should not fire holds.
    if (t <= previous || t - previous > 1.5) return;

    // Replay stored reactions as floaters when the playhead crosses them —
    // capped per tick so a pile-up at one moment stays a flurry, not a wall.
    const crossed = reactionsRef.current
      .filter((r) => r.videoTime > previous && r.videoTime <= t)
      .slice(0, 4);
    for (const r of crossed) {
      spawnFloater(r.emoji, r.videoTime, video.duration || durationSeconds, true);
    }

    for (const [index, marker] of annotations.entries()) {
      if (!marker.autoPause) continue;
      if (firedRef.current.has(index)) continue;
      if (marker.start > previous && marker.start <= t) {
        firedRef.current.add(index);
        video.pause();
        const hold = Math.min(30, Math.max(0.5, marker.pauseDuration ?? 2));
        resumeTimerRef.current = setTimeout(() => {
          // Only resume if the viewer hasn't taken over meanwhile.
          const v = videoRef.current;
          if (v && v.paused && Math.abs(v.currentTime - t) < 0.5) {
            void v.play().catch(() => {});
          }
        }, hold * 1000);
        break;
      }
    }
  }, [annotations]);

  const onSeeked = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;
    lastTimeRef.current = video.currentTime;
    setCurrentTime(video.currentTime);
    // Re-arm every marker at or after the new position.
    const rearmed = new Set<number>();
    for (const [index, marker] of annotations.entries()) {
      if (marker.start < video.currentTime && firedRef.current.has(index)) {
        rearmed.add(index);
      }
    }
    firedRef.current = rearmed;
    if (resumeTimerRef.current) {
      clearTimeout(resumeTimerRef.current);
      resumeTimerRef.current = null;
    }
  }, [annotations]);

  useEffect(() => {
    return () => {
      if (resumeTimerRef.current) clearTimeout(resumeTimerRef.current);
      if (idleTimerRef.current) clearTimeout(idleTimerRef.current);
    };
  }, []);

  // ---- Transport ----------------------------------------------------------

  /** Seek, snapping into an annotation's start when the target lands inside
   *  one — clicking anywhere on a highlighted range jumps to its beginning. */
  const seekTo = useCallback(
    (time: number, { snap = true }: { snap?: boolean } = {}) => {
      const video = videoRef.current;
      if (!video) return;
      const covering = snap ? annotations[markerAt(time)] : undefined;
      const target = covering ? covering.start : time;
      firedRef.current = new Set(); // onSeeked re-arms precisely
      const safe = clamp(target, 0, Math.max(0, (total || 0) - 0.05));
      video.currentTime = safe;
      setCurrentTime(safe);
    },
    [annotations, markerAt, total]
  );

  const jumpToMarker = useCallback(
    (marker: AnnotationMarker) => {
      seekTo(marker.start, { snap: false });
      void videoRef.current?.play().catch(() => {});
    },
    [seekTo]
  );

  const togglePlay = useCallback(() => {
    const video = videoRef.current;
    if (!video) return;
    if (video.paused) void video.play().catch(() => {});
    else video.pause();
  }, []);

  const wake = useCallback(() => {
    setControlsVisible(true);
    if (idleTimerRef.current) clearTimeout(idleTimerRef.current);
    idleTimerRef.current = setTimeout(() => {
      const video = videoRef.current;
      if (video && !video.paused && !draggingRef.current) {
        setControlsVisible(false);
      }
    }, IDLE_MS);
  }, []);

  const toggleFullscreen = useCallback(() => {
    if (document.fullscreenElement) void document.exitFullscreen();
    else void shellRef.current?.requestFullscreen().catch(() => {});
  }, []);

  useEffect(() => {
    const onChange = () => setFullscreen(Boolean(document.fullscreenElement));
    document.addEventListener("fullscreenchange", onChange);
    return () => document.removeEventListener("fullscreenchange", onChange);
  }, []);

  // ---- Scrubber -----------------------------------------------------------

  const ratioFromPointer = useCallback((clientX: number) => {
    const el = barRef.current;
    if (!el) return 0;
    const rect = el.getBoundingClientRect();
    if (rect.width === 0) return 0;
    return clamp((clientX - rect.left) / rect.width, 0, 1);
  }, []);

  const onBarPointerDown = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      event.preventDefault();
      draggingRef.current = true;
      setScrubbing(true);
      event.currentTarget.setPointerCapture(event.pointerId);
      const ratio = ratioFromPointer(event.clientX);
      setHoverRatio(ratio);
      seekTo(ratio * total);
    },
    [ratioFromPointer, seekTo, total]
  );

  const onBarPointerMove = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      const ratio = ratioFromPointer(event.clientX);
      setHoverRatio(ratio);
      // While dragging, scrub without snapping — snapping mid-drag would fight
      // the pointer. The snap applies on the initial click and on release.
      if (draggingRef.current) {
        const video = videoRef.current;
        if (video) {
          const t = ratio * total;
          video.currentTime = t;
          setCurrentTime(t);
        }
      }
    },
    [ratioFromPointer, total]
  );

  const endDrag = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      if (!draggingRef.current) return;
      draggingRef.current = false;
      setScrubbing(false);
      if (event.currentTarget.hasPointerCapture(event.pointerId)) {
        event.currentTarget.releasePointerCapture(event.pointerId);
      }
      seekTo(ratioFromPointer(event.clientX) * total);
      wake();
    },
    [ratioFromPointer, seekTo, total, wake]
  );

  const onBarKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      const video = videoRef.current;
      if (!video) return;
      const step = event.shiftKey ? 10 : 5;
      switch (event.key) {
        case "ArrowRight":
          event.preventDefault();
          seekTo(video.currentTime + step, { snap: false });
          break;
        case "ArrowLeft":
          event.preventDefault();
          seekTo(video.currentTime - step, { snap: false });
          break;
        case "Home":
          event.preventDefault();
          seekTo(0, { snap: false });
          break;
        case "End":
          event.preventDefault();
          seekTo(total, { snap: false });
          break;
        case " ":
        case "k":
          event.preventDefault();
          togglePlay();
          break;
        default:
          break;
      }
    },
    [seekTo, togglePlay, total]
  );

  const playedPct = total > 0 ? (currentTime / total) * 100 : 0;
  const bufferedPct = total > 0 ? (buffered / total) * 100 : 0;

  // ---- Comments ----------------------------------------------------------

  useEffect(() => {
    if (!commentsEnabled) return;
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch(
          `${API_URL}/api/video/${encodeURIComponent(videoId)}/comments`
        );
        if (!res.ok) return;
        const data = (await res.json()) as { comments: Comment[] };
        if (!cancelled) setComments(data.comments);
      } catch {
        // Comments are progressive enhancement; the player must never break.
      } finally {
        if (!cancelled) setCommentsLoaded(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [commentsEnabled, videoId]);

  const seekToComment = useCallback(
    (time: number) => {
      seekTo(time);
      void videoRef.current?.play().catch(() => {});
    },
    [seekTo]
  );

  const startDraft = useCallback(() => {
    if (draftTime === null) {
      setDraftTime(videoRef.current?.currentTime ?? 0);
    }
  }, [draftTime]);

  const submit = useCallback(async () => {
    const text = draft.trim();
    if (!text || posting) return;
    setPosting(true);
    setPostError(null);
    try {
      const res = await fetch(
        `${API_URL}/api/video/${encodeURIComponent(videoId)}/comments`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            authorName: authorName.trim() || undefined,
            body: text,
            videoTime: draftTime ?? 0,
          }),
        }
      );
      if (!res.ok) {
        const err = (await res.json().catch(() => null)) as
          | { error?: string }
          | null;
        setPostError(err?.error ?? "Could not post comment");
        return;
      }
      const data = (await res.json()) as { comment: Comment };
      setComments((prev) =>
        [...prev, data.comment].sort((a, b) => a.videoTime - b.videoTime)
      );
      setDraft("");
      setDraftTime(null);
    } catch {
      setPostError("Could not post comment");
    } finally {
      setPosting(false);
    }
  }, [authorName, draft, draftTime, posting, videoId]);

  // ---- Render -------------------------------------------------------------

  const showChrome = controlsVisible || paused || scrubbing;
  // A lone chapter at 0:00 says nothing the scrubber doesn't; hide the strip.
  // Same for unlabeled annotations pinned at the very start.
  const trivialChapters =
    aiChapters.length === 0 || (aiChapters.length === 1 && aiChapters[0].start < 1);
  const pillAnnotations = annotations.filter(
    (m) => (m.label && m.label.trim().length > 0) || m.start >= 1
  );
  const showChapterPills = !trivialChapters || pillAnnotations.length > 0;

  // YouTube-style watch shell, single column: glass-framed player, then
  // title + byline/actions, description box with chapter pills, transcript,
  // comments. Same liquid-glass dark language as the rest of the site —
  // only the layout is borrowed.
  return (
    <div className="min-w-0">
      <div className="glass-panel hairline-top overflow-hidden rounded-2xl p-1.5 shadow-2xl sm:p-2">
      <div
        ref={shellRef}
        className="group/player relative aspect-video overflow-hidden rounded-xl bg-black"
        onPointerMove={wake}
        onPointerLeave={() => {
          if (!draggingRef.current && !paused) setControlsVisible(false);
        }}
      >
        {/* Owner CTA — always visible, tinted with the brand accent. The
            click is flushed to analytics before the browser navigates. */}
        {ctaLabel && ctaUrl && (
          <a
            href={ctaUrl}
            target="_blank"
            // nofollow/ugc: the destination is owner-supplied on a public
            // page — never pass along ranking signal from capturecat.so.
            rel="noopener noreferrer nofollow ugc"
            onClick={() => track("cta")}
            className="absolute right-3 top-3 z-20 rounded-full px-4 py-1.5 text-sm font-semibold text-black shadow-lg transition-transform hover:scale-105"
            style={{ backgroundColor: brandAccent || "#FBBF24" }}
          >
            {ctaLabel} →
          </a>
        )}
        <video
          ref={videoRef}
          src={videoStreamUrl}
          autoPlay
          playsInline
          onClick={togglePlay}
          onTimeUpdate={handleTimeUpdate}
          onSeeked={onSeeked}
          onLoadedMetadata={(e) => {
            const v = e.currentTarget;
            const d = v.duration;
            if (Number.isFinite(d) && d > 0) setDuration(d);
            setMuted(v.muted);
            // ?t= deep link: seek once, after the duration is known.
            if (startAt != null && !startAtDone.current) {
              startAtDone.current = true;
              v.currentTime = Math.min(Math.max(0, startAt), d || startAt);
            }
          }}
          onDurationChange={(e) => {
            const d = e.currentTarget.duration;
            if (Number.isFinite(d) && d > 0) setDuration(d);
          }}
          onPlay={() => {
            setPaused(false);
            wake();
          }}
          onPause={() => {
            setPaused(true);
            setControlsVisible(true);
          }}
          onEnded={() => setControlsVisible(true)}
          onVolumeChange={(e) => setMuted(e.currentTarget.muted)}
          onProgress={(e) => {
            const v = e.currentTarget;
            if (v.buffered.length > 0) {
              setBuffered(v.buffered.end(v.buffered.length - 1));
            }
          }}
          className="block h-full w-full cursor-pointer object-contain"
        />

        {/* IG/TikTok-style reaction floaters. */}
        {floaters.length > 0 && (
          <div className="pointer-events-none absolute inset-0 overflow-hidden">
            {floaters.map((f) => (
              <span
                key={f.id}
                onAnimationEnd={() =>
                  setFloaters((prev) => prev.filter((x) => x.id !== f.id))
                }
                className="cc-floater absolute bottom-16 select-none"
                style={{
                  left: `${f.x}%`,
                  fontSize: `${f.size}px`,
                  animationDuration: `${f.dur}s`,
                  ["--dx1" as string]: `${f.dx1}px`,
                  ["--dx2" as string]: `${f.dx2}px`,
                }}
              >
                {f.emoji}
              </span>
            ))}
            <style>{`
              .cc-floater {
                animation-name: cc-float-up;
                animation-timing-function: ease-out;
                animation-fill-mode: forwards;
                will-change: transform, opacity;
              }
              @keyframes cc-float-up {
                0% {
                  transform: translate(0, 0) scale(0.4) rotate(0deg);
                  opacity: 0;
                }
                8% {
                  transform: translate(calc(var(--dx1) * 0.2), -8vh) scale(1.25) rotate(-6deg);
                  opacity: 1;
                }
                30% {
                  transform: translate(var(--dx1), -22vh) scale(1) rotate(7deg);
                  opacity: 1;
                }
                60% {
                  transform: translate(var(--dx2), -42vh) scale(0.95) rotate(-6deg);
                  opacity: 0.9;
                }
                100% {
                  transform: translate(calc(var(--dx2) * 1.4), -62vh) scale(0.8) rotate(4deg);
                  opacity: 0;
                }
              }
            `}</style>
          </div>
        )}

        {/* Center affordance while paused. */}
        {paused && (
          <button
            onClick={togglePlay}
            aria-label="Play"
            className="absolute inset-0 grid place-items-center"
          >
            <span className="grid h-16 w-16 place-items-center rounded-full bg-black/55 text-white ring-1 ring-white/20 backdrop-blur-sm transition-transform duration-200 hover:scale-105">
              <PlayIcon className="ml-0.5 h-7 w-7" />
            </span>
          </button>
        )}

        {/* Control bar. */}
        <div
          className={`absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/85 via-black/45 to-transparent px-3 pb-2 pt-10 transition-opacity duration-200 ${
            showChrome ? "opacity-100" : "pointer-events-none opacity-0"
          }`}
        >
          {/* Scrubber. Generous hit area, thin visual track. */}
          <div
            ref={barRef}
            role="slider"
            tabIndex={0}
            aria-label="Seek"
            aria-valuemin={0}
            aria-valuemax={Math.round(total)}
            aria-valuenow={Math.round(currentTime)}
            aria-valuetext={`${formatTime(currentTime)} of ${formatTime(total)}`}
            onPointerDown={onBarPointerDown}
            onPointerMove={onBarPointerMove}
            onPointerUp={endDrag}
            onPointerCancel={endDrag}
            onPointerLeave={() => {
              if (!draggingRef.current) setHoverRatio(null);
            }}
            onKeyDown={onBarKeyDown}
            className="group/bar relative cursor-pointer py-2 focus:outline-none"
          >
            {/* Tooltip: timecode, plus the annotation label when over a range. */}
            {hoverRatio !== null && (
              <div
                className="pointer-events-none absolute bottom-full z-10 mb-1 -translate-x-1/2 whitespace-nowrap rounded-md bg-black/90 px-2 py-1 text-[11px] font-medium tabular-nums text-white ring-1 ring-white/15"
                style={{ left: `${clamp(hoverRatio * 100, 4, 96)}%` }}
              >
                {hoveredMarker >= 0 && (
                  <span className="mr-1.5 text-amber-300">
                    {annotations[hoveredMarker].label ?? "Annotation"}
                  </span>
                )}
                {formatTime(hoverTime ?? 0)}
              </div>
            )}

            <div
              className={`relative w-full overflow-hidden rounded-full bg-white/20 transition-[height] duration-150 ${
                scrubbing ? "h-[6px]" : "h-[3px] group-hover/bar:h-[6px]"
              }`}
            >
              <div
                className="absolute inset-y-0 left-0 bg-white/25"
                style={{ width: `${bufferedPct}%` }}
              />
              <div
                className="absolute inset-y-0 left-0"
                style={{ width: `${playedPct}%`, backgroundColor: brandAccent ?? "#FFFFFF" }}
              />
              {/* Annotation ranges sit above the fill at partial opacity so
                  they stay legible over both played and unplayed track. */}
              {markers.map(({ index, left, width }) => (
                <div
                  key={index}
                  className="absolute inset-y-0 transition-colors duration-150"
                  style={{
                    left: `${left}%`, width: `${width}%`,
                    backgroundColor: accent,
                    opacity: hoveredMarker === index ? 1 : 0.7,
                  }}
                />
              ))}
            </div>

            {/* Reaction density strip: each reaction is a tiny emoji at its
                timestamp, floating just above the track. */}
            {total > 0 && reactions.length > 0 && (
              <div className="pointer-events-none absolute inset-x-0 -top-3 h-4">
                {reactions.slice(-200).map((r, i) => (
                  <span
                    key={i}
                    className="absolute -translate-x-1/2 text-[10px] leading-none"
                    style={{ left: `${clamp((r.videoTime / total) * 100, 0, 100)}%` }}
                  >
                    {r.emoji}
                  </span>
                ))}
              </div>
            )}

            {/* Playhead. */}
            <div
              className={`pointer-events-none absolute top-1/2 -translate-x-1/2 -translate-y-1/2 rounded-full bg-white shadow transition-[height,width] duration-150 ${
                scrubbing
                  ? "h-3.5 w-3.5"
                  : "h-0 w-0 group-hover/bar:h-3.5 group-hover/bar:w-3.5"
              }`}
              style={{ left: `${playedPct}%` }}
            />
          </div>

          <div className="flex items-center gap-3 pt-0.5 text-white">
            <button
              onClick={togglePlay}
              aria-label={paused ? "Play" : "Pause"}
              className="rounded p-1 transition-colors hover:bg-white/15"
            >
              {paused ? (
                <PlayIcon className="h-5 w-5" />
              ) : (
                <PauseIcon className="h-5 w-5" />
              )}
            </button>

            <button
              onClick={() => {
                const v = videoRef.current;
                if (v) v.muted = !v.muted;
              }}
              aria-label={muted ? "Unmute" : "Mute"}
              className="rounded p-1 transition-colors hover:bg-white/15"
            >
              {muted ? (
                <MuteIcon className="h-5 w-5" />
              ) : (
                <SoundIcon className="h-5 w-5" />
              )}
            </button>

            <span className="text-xs tabular-nums text-white/75">
              {formatTime(currentTime)} / {formatTime(total)}
            </span>

            <div className="ml-auto" />

            {downloadUrl && (
              <a
                href={downloadUrl}
                download
                aria-label="Download video"
                title="Download"
                className="rounded p-1 transition-colors hover:bg-white/15"
              >
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="h-5 w-5">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v12m0 0l-4-4m4 4l4-4M5 20h14" />
                </svg>
              </a>
            )}
            <button
              onClick={toggleFullscreen}
              aria-label={fullscreen ? "Exit full screen" : "Full screen"}
              className="rounded p-1 transition-colors hover:bg-white/15"
            >
              <FullscreenIcon className="h-5 w-5" />
            </button>
          </div>
        </div>
      </div>

      </div>

      {/* Watch-page header: title, then byline + action pills (YouTube shell). */}
      {title && (
        <h1 className="mt-4 line-clamp-2 text-lg font-semibold leading-snug tracking-[-0.01em] text-white sm:text-xl">
          {title}
        </h1>
      )}
      <div className="mt-2.5 flex flex-wrap items-center gap-x-4 gap-y-2.5">
        <p className="text-sm text-white/45">
          {createdAt && (
            <>
              {new Date(createdAt).toLocaleDateString("en-GB", {
                day: "numeric",
                month: "short",
                year: "numeric",
              })}
              <span className="mx-1.5 text-white/25">·</span>
            </>
          )}
          {total > 0 && (
            <>
              <span className="tabular-nums">{formatTime(total)}</span>
              <span className="mx-1.5 text-white/25">·</span>
            </>
          )}
          Shared via CaptureCat
        </p>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          {/* Reactions: tap to drop an emoji at the current moment. */}
          <div className="flex items-center gap-1 rounded-full border border-white/10 bg-white/[0.04] p-1 backdrop-blur-sm">
            {["👍", "❤️", "🔥", "😂", "😮", "🎉"].map((emoji) => {
              const count = reactionCounts.get(emoji) ?? 0;
              return (
                <button
                  key={emoji}
                  onClick={() => sendReaction(emoji)}
                  aria-label={`React ${emoji}`}
                  aria-pressed={myEmoji === emoji}
                  className={`flex items-center gap-1 rounded-full px-1.5 py-0.5 text-sm transition-transform duration-150 hover:scale-110 active:scale-95 ${
                    myEmoji === emoji
                      ? "bg-white/[0.16]"
                      : "hover:bg-white/[0.08]"
                  }`}
                  style={
                    myEmoji === emoji
                      ? { boxShadow: `0 0 0 1.5px ${accent}` }
                      : undefined
                  }
                >
                  {emoji}
                  {count > 0 && (
                    <span className="text-[11px] tabular-nums text-white/55">
                      {count}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
          <button
            onClick={() => {
              void navigator.clipboard.writeText(window.location.href).then(() => {
                setLinkCopied(true);
                window.setTimeout(() => setLinkCopied(false), 1600);
              });
            }}
            className="rounded-full border border-white/10 bg-white/[0.04] px-3.5 py-1.5 text-xs font-medium text-white/70 backdrop-blur-sm transition-colors hover:border-white/20 hover:bg-white/[0.1] hover:text-white"
          >
            {linkCopied ? "Copied!" : "Copy link"}
          </button>
          {downloadUrl && (
            <a
              href={downloadUrl}
              onClick={() => track("download")}
              className="rounded-full border border-white/10 bg-white/[0.04] px-3.5 py-1.5 text-xs font-medium text-white/70 backdrop-blur-sm transition-colors hover:border-white/20 hover:bg-white/[0.1] hover:text-white"
            >
              Download
            </a>
          )}
        </div>
      </div>

      {/* Description box: AI summary + chapters + version history — YouTube's
          grey box, in glass. */}
      {(summary || versions.length > 1 || showChapterPills) && (
        <section className="glass-panel hairline-top mt-4 rounded-2xl p-4">
          {summary && (
            <>
              <p
                className={`whitespace-pre-line text-sm leading-relaxed text-white/70 ${
                  descExpanded ? "" : "line-clamp-3"
                }`}
              >
                {summary}
              </p>
              {summary.length > 200 && (
                <button
                  onClick={() => setDescExpanded((e) => !e)}
                  className="mt-1.5 text-xs font-medium text-white/50 transition-colors hover:text-white"
                >
                  {descExpanded ? "Show less" : "Show more"}
                </button>
              )}
            </>
          )}

          {/* Chapters: horizontal seekable pill strip. Hidden when the only
              chapter is a trivial 0:00 marker. */}
          {showChapterPills && (
            <div className={summary ? "mt-3.5" : ""}>
              <div className="-mx-1 flex gap-2 overflow-x-auto px-1 pb-1 [scrollbar-width:thin]">
                {aiChapters.map((chapter, i) => (
                  <button
                    key={`ai-${i}`}
                    onClick={() => {
                      const v = videoRef.current;
                      if (v) v.currentTime = chapter.start;
                    }}
                    onPointerEnter={() =>
                      setHoverRatio(total > 0 ? chapter.start / total : null)
                    }
                    onPointerLeave={() => setHoverRatio(null)}
                    title={chapter.label}
                    className="flex shrink-0 items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.05] px-3 py-1.5 text-xs text-white/70 transition-colors hover:border-white/20 hover:bg-white/[0.1] hover:text-white"
                  >
                    <span className="tabular-nums text-white/40">
                      {formatTime(chapter.start)}
                    </span>
                    <span className="max-w-[18rem] truncate">{chapter.label}</span>
                  </button>
                ))}
                {pillAnnotations.map((marker, i) => (
                  <button
                    key={`ann-${i}`}
                    onClick={() => jumpToMarker(marker)}
                    onPointerEnter={() =>
                      setHoverRatio(total > 0 ? marker.start / total : null)
                    }
                    onPointerLeave={() => setHoverRatio(null)}
                    title={marker.label ?? "Annotation"}
                    className="flex shrink-0 items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.05] px-3 py-1.5 text-xs text-white/70 transition-colors hover:border-white/20 hover:bg-white/[0.1] hover:text-white"
                  >
                    <span
                      className="h-1.5 w-1.5 shrink-0 rounded-full"
                      style={{ backgroundColor: accent }}
                    />
                    <span className="tabular-nums text-white/40">
                      {formatTime(marker.start)}
                    </span>
                    {marker.label && (
                      <span className="max-w-[18rem] truncate">{marker.label}</span>
                    )}
                  </button>
                ))}
              </div>
            </div>
          )}
          {versions.length > 1 && (
            <div className={`flex flex-wrap items-center gap-2 ${summary || showChapterPills ? "mt-3.5" : ""}`}>
              <span className="text-xs uppercase tracking-wide text-white/40">
                Version history
              </span>
              {versions.map((ver) => {
                const active = ver.version === playVersion;
                return (
                  <a
                    key={ver.version}
                    href={`/share/${videoId}?v=${ver.version}`}
                    className={
                      active
                        ? "rounded-full bg-white/15 px-3 py-1 text-xs text-white"
                        : "rounded-full bg-white/5 px-3 py-1 text-xs text-white/50 transition-colors hover:bg-white/10 hover:text-white/80"
                    }
                  >
                    v{ver.version}
                    {ver.current ? " · latest" : ""}
                    <span className="ml-1 text-white/40">
                      {new Date(ver.createdAt).toLocaleDateString("en-GB", {
                        day: "numeric",
                        month: "short",
                      })}
                    </span>
                  </a>
                );
              })}
            </div>
          )}
        </section>
      )}

      {/* Transcript: collapsible glass panel, YouTube's "Show transcript". */}
      {hasTranscript && (
        <section className="glass-panel hairline-top mt-4 rounded-2xl p-4">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-medium text-white/80">Transcript</h2>
            <button
              onClick={() => setTranscriptOpen((o) => !o)}
              className="text-xs font-medium text-white/50 transition-colors hover:text-white"
            >
              {transcriptOpen ? "Hide" : "Show"}
            </button>
          </div>
          {transcriptOpen && (
            <div className="mt-3">
              <input
                value={transcriptFilter}
                onChange={(e) => setTranscriptFilter(e.target.value)}
                placeholder="Search transcript…"
                className="mb-2 w-full rounded-lg bg-white/[0.05] px-3 py-1.5 text-sm text-white placeholder-white/35 outline-none ring-1 ring-white/10 focus:ring-white/30"
              />
              {transcript.length === 0 && (
                <p className="px-1 py-2 text-sm text-white/40">Loading transcript…</p>
              )}
              <div className="max-h-[45vh] space-y-0.5 overflow-y-auto">
                {transcript
                  .filter(
                    (seg) =>
                      !transcriptFilter ||
                      seg.text.toLowerCase().includes(transcriptFilter.toLowerCase())
                  )
                  .map((seg, i) => (
                    <button
                      key={i}
                      onClick={() => {
                        const v = videoRef.current;
                        if (v) v.currentTime = seg.start;
                      }}
                      className={`flex w-full items-start gap-2.5 rounded-md px-2 py-1 text-left text-sm transition-colors hover:bg-white/[0.08] ${
                        currentTime >= seg.start && currentTime <= seg.end
                          ? "bg-white/[0.08] text-white"
                          : "text-white/70"
                      }`}
                    >
                      <span className="shrink-0 pt-px text-[11px] tabular-nums text-white/40">
                        {formatTime(seg.start)}
                      </span>
                      <span>{seg.text}</span>
                    </button>
                  ))}
              </div>
            </div>
          )}
        </section>
      )}

      {commentsEnabled && (
        <section className="glass-panel hairline-top mt-4 rounded-2xl p-4 sm:p-5">
          <h2 className="text-sm font-medium text-white/80">
            {commentsLoaded
              ? `${comments.length} comment${comments.length === 1 ? "" : "s"}`
              : "Comments"}
          </h2>

          <div className="mt-4 space-y-4">
            {comments.map((comment) => {
              const name = comment.authorName?.trim() || "Anonymous";
              return (
                <div key={comment.commentId} className="flex items-start gap-3">
                  <span
                    aria-hidden
                    className="mt-0.5 grid h-8 w-8 shrink-0 place-items-center rounded-full bg-white/[0.08] text-xs font-semibold text-white/70 ring-1 ring-white/10"
                  >
                    {name.charAt(0).toUpperCase()}
                  </span>
                  <div className="min-w-0">
                    <p className="flex items-baseline gap-2 text-xs text-white/50">
                      <span className="font-medium text-white/75">{name}</span>
                      <button
                        onClick={() => seekToComment(comment.videoTime)}
                        className="rounded bg-white/[0.06] px-1.5 py-0.5 text-[11px] tabular-nums text-white/55 transition-colors hover:bg-white/[0.14] hover:text-white"
                        title="Jump to this moment"
                      >
                        {formatTime(comment.videoTime)}
                      </button>
                    </p>
                    <p className="mt-0.5 break-words text-sm text-white/90">
                      {comment.body}
                    </p>
                  </div>
                </div>
              );
            })}
            {commentsLoaded && comments.length === 0 && (
              <p className="text-sm text-white/40">
                No comments yet — be the first.
              </p>
            )}
          </div>

          <div className="mt-5 space-y-2 border-t border-white/[0.06] pt-4">
            <div className="flex gap-2">
              <input
                value={authorName}
                onChange={(e) => setAuthorName(e.target.value)}
                placeholder="Name (optional)"
                maxLength={40}
                className="w-40 rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-white placeholder-white/30 focus:border-white/30 focus:outline-none"
              />
              <span className="self-center text-xs tabular-nums text-white/40">
                at {formatTime(draftTime ?? 0)}
              </span>
            </div>
            <textarea
              value={draft}
              onFocus={startDraft}
              onChange={(e) => {
                startDraft();
                setDraft(e.target.value);
              }}
              placeholder="Comment at the current moment in the video…"
              maxLength={500}
              rows={2}
              className="w-full resize-none rounded-lg border border-white/10 bg-white/[0.05] px-3 py-2 text-sm text-white placeholder-white/30 focus:border-white/30 focus:outline-none"
            />
            {postError && <p className="text-xs text-red-400">{postError}</p>}
            <button
              onClick={() => void submit()}
              disabled={!draft.trim() || posting}
              className="rounded-full border border-white/10 bg-white/[0.08] px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-white/[0.16] disabled:cursor-not-allowed disabled:opacity-40"
            >
              {posting ? "Posting…" : "Post comment"}
            </button>
          </div>
        </section>
      )}
    </div>
  );
}

/* ---- Icons. Inline so the player pulls in no icon dependency. ------------ */

function PlayIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M8 5.14v13.72a.5.5 0 0 0 .76.43l11.14-6.86a.5.5 0 0 0 0-.86L8.76 4.71a.5.5 0 0 0-.76.43Z" />
    </svg>
  );
}

function PauseIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M7 4h3.5v16H7zM13.5 4H17v16h-3.5z" />
    </svg>
  );
}

function SoundIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M4 9v6h4l5 4V5L8 9H4Z" />
      <path
        d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
      />
    </svg>
  );
}

function MuteIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M4 9v6h4l5 4V5L8 9H4Z" />
      <path
        d="M16.5 9.5l5 5m0-5l-5 5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
      />
    </svg>
  );
}

function FullscreenIcon({ className }: { className?: string }) {
  return (
    <svg
      className={className}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M4 9V5.5A1.5 1.5 0 0 1 5.5 4H9M15 4h3.5A1.5 1.5 0 0 1 20 5.5V9M20 15v3.5a1.5 1.5 0 0 1-1.5 1.5H15M9 20H5.5A1.5 1.5 0 0 1 4 18.5V15" />
    </svg>
  );
}
