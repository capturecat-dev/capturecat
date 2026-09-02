import { useEffect, useRef } from "react";
import { API_URL } from "@/lib/api-url";

/**
 * Viewer analytics for the share page.
 *
 * Attaches listeners straight to the <video> element so the player's own
 * handlers stay untouched. Events queue locally and flush every 10 s (fetch)
 * and on tab-hide (sendBeacon), so a viewer who closes the tab mid-watch still
 * reports where they stopped.
 *
 * A 'tick' is emitted once per watched second-bucket — the server derives the
 * heatmap and per-session drop-off from those. The session id is a random
 * per-tab value held in memory only; nothing is written to storage.
 */
export function useViewerAnalytics(
  videoId: string,
  videoRef: React.RefObject<HTMLVideoElement | null>
) {
  const queue = useRef<{ type: string; videoTime: number; meta?: string }[]>([]);
  const sessionId = useRef<string>("");
  if (!sessionId.current && typeof crypto !== "undefined") {
    sessionId.current = crypto.randomUUID().replace(/-/g, "");
  }
  // Imperative tracker for UI events outside the <video> element (the CTA
  // button). Flushes immediately — a CTA click usually navigates away.
  const trackRef = useRef<(type: string) => void>(() => {});

  useEffect(() => {
    const video = videoRef.current;
    if (!video || !sessionId.current) return;

    const endpoint = `${API_URL}/api/video/${encodeURIComponent(videoId)}/analytics`;
    const seenSeconds = new Set<number>();

    const push = (type: string, meta?: string) => {
      queue.current.push({
        type,
        videoTime: Math.round((video.currentTime || 0) * 1000) / 1000,
        ...(meta ? { meta } : {}),
      });
    };

    const flush = (useBeacon = false) => {
      if (queue.current.length === 0) return;
      const body = JSON.stringify({
        sessionId: sessionId.current,
        referrer: document.referrer || undefined,
        events: queue.current.splice(0, 50),
      });
      if (useBeacon && "sendBeacon" in navigator) {
        navigator.sendBeacon(endpoint, new Blob([body], { type: "application/json" }));
      } else {
        void fetch(endpoint, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body,
          keepalive: true,
        }).catch(() => {});
      }
    };

    // Register the view immediately, even if the viewer never presses play.
    void fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sessionId: sessionId.current,
        referrer: document.referrer || undefined,
        events: [],
      }),
    }).catch(() => {});

    const onTimeUpdate = () => {
      const second = Math.floor(video.currentTime || 0);
      if (!video.paused && !seenSeconds.has(second)) {
        seenSeconds.add(second);
        queue.current.push({ type: "tick", videoTime: second });
      }
    };
    const onPlay = () => push("play");
    const onPause = () => push("pause");
    const onSeeked = () => push("seek");
    const onEnded = () => {
      push("ended");
      flush();
    };
    const onClick = () => push("click");
    const onVisibility = () => {
      if (document.visibilityState === "hidden") flush(true);
    };

    video.addEventListener("timeupdate", onTimeUpdate);
    video.addEventListener("play", onPlay);
    video.addEventListener("pause", onPause);
    video.addEventListener("seeked", onSeeked);
    video.addEventListener("ended", onEnded);
    video.addEventListener("click", onClick);
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("pagehide", () => flush(true));

    const interval = window.setInterval(() => flush(), 10_000);

    trackRef.current = (type: string) => {
      push(type);
      flush(true);
    };

    return () => {
      video.removeEventListener("timeupdate", onTimeUpdate);
      video.removeEventListener("play", onPlay);
      video.removeEventListener("pause", onPause);
      video.removeEventListener("seeked", onSeeked);
      video.removeEventListener("ended", onEnded);
      video.removeEventListener("click", onClick);
      document.removeEventListener("visibilitychange", onVisibility);
      window.clearInterval(interval);
      flush(true);
    };
  }, [videoId, videoRef]);

  return { track: (type: string) => trackRef.current(type) };
}
