import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";

import {
  containRect,
  drawAnnotation,
  type AnnotationShape,
  type Rect,
} from "@/lib/share/annotation";

/** Intrinsic video size, when known — the frame inside the contain box. */
export interface MediaSize {
  w: number;
  h: number;
}

/**
 * A high-DPI canvas that paints annotation shapes over a box. The ONE place
 * shapes become pixels: the composer, the playback overlay and the comment
 * thumbnails all render through this, so they cannot disagree.
 *
 * The backing store follows the box size × devicePixelRatio and redraws on
 * resize (and on a DPR change, e.g. dragging the window to another display),
 * so strokes stay crisp at any size — they are stored normalized, never as
 * pixels.
 */
export function AnnotationLayer({
  shapes,
  media,
  className = "",
  style,
  minStrokePx,
  shadows,
  onFrameRect,
}: {
  shapes: AnnotationShape[];
  media?: MediaSize | null;
  className?: string;
  style?: CSSProperties;
  minStrokePx?: number;
  shadows?: boolean;
  /** Reports the frame rect (box px) whenever it changes — the editor maps
   *  pointer positions through it. */
  onFrameRect?: (rect: Rect) => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [box, setBox] = useState({ w: 0, h: 0, dpr: 1 });

  useLayoutEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const measure = () =>
      setBox((prev) => {
        const next = {
          w: canvas.clientWidth,
          h: canvas.clientHeight,
          dpr: typeof window !== "undefined" ? window.devicePixelRatio || 1 : 1,
        };
        return prev.w === next.w && prev.h === next.h && prev.dpr === next.dpr ? prev : next;
      });
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(canvas);
    // DPR changes do not resize the element; listen for them separately.
    let mq: MediaQueryList | null = null;
    const onDpr = () => {
      measure();
      mq?.removeEventListener("change", onDpr);
      mq = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
      mq.addEventListener("change", onDpr);
    };
    onDpr();
    return () => {
      ro.disconnect();
      mq?.removeEventListener("change", onDpr);
    };
  }, []);

  const mediaW = media?.w ?? 0;
  const mediaH = media?.h ?? 0;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = containRect(box.w, box.h, mediaW, mediaH);
    onFrameRect?.(rect);
    const pw = Math.max(1, Math.round(box.w * box.dpr));
    const ph = Math.max(1, Math.round(box.h * box.dpr));
    if (canvas.width !== pw) canvas.width = pw;
    if (canvas.height !== ph) canvas.height = ph;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, pw, ph);
    ctx.setTransform(box.dpr, 0, 0, box.dpr, 0, 0);
    drawAnnotation(ctx, shapes, rect, { pixelRatio: box.dpr, minStrokePx, shadows });
  }, [shapes, box, mediaW, mediaH, minStrokePx, shadows, onFrameRect]);

  return <canvas ref={canvasRef} aria-hidden className={`block h-full w-full ${className}`} style={style} />;
}

/**
 * Small preview of a comment's drawing — the marks on a dark plate shaped
 * like the video, for comment rows and the scrubber hover card.
 */
export function AnnotationThumb({
  shapes,
  media,
  width = 64,
  className = "",
}: {
  shapes: AnnotationShape[];
  media?: MediaSize | null;
  width?: number;
  className?: string;
}) {
  const aspect = media && media.w > 0 && media.h > 0 ? media.w / media.h : 16 / 9;
  // Very tall videos would make a towering thumbnail; cap the height.
  const height = Math.min(width / aspect, width * 1.1);
  return (
    <span
      aria-hidden
      className={`relative inline-block shrink-0 overflow-hidden rounded-md bg-[#0d0f15] ring-1 ring-white/10 ${className}`}
      style={{ width, height }}
    >
      <span
        aria-hidden
        className="absolute inset-0 opacity-60"
        style={{
          background:
            "radial-gradient(120% 90% at 30% 20%, rgba(120,140,255,0.16), transparent 60%), linear-gradient(180deg, rgba(255,255,255,0.03), transparent)",
        }}
      />
      <AnnotationLayer shapes={shapes} media={media} minStrokePx={1.1} shadows={false} className="absolute inset-0" />
    </span>
  );
}
