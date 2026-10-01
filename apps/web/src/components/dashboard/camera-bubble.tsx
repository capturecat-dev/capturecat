/**
 * The floating camera bubble — the Mac's recording-time camera preview
 * (Views/AppKitSurfaces/CameraFloatPreview.swift) on the dashboard: a live,
 * mirrored feed masked to the true squircle, floating over every /app page
 * while the recorder is armed with a camera. The whole bubble is a drag
 * handle (free positioning, remembered); right-click picks Small / Medium /
 * Large, and the new size grows out of the corner it's parked in on the
 * house bounce. Geometry, persistence and the show/hide policy live in
 * editor/record/cameraBubble.ts; RecorderDock decides where it shows.
 *
 * Chrome, as CameraFloatSquircleView draws it:
 *   shadow    black 0.35, radius 12, 5 px down — cast by the squircle itself
 *             (the Mac's shadowPath), never a bounding box
 *   clip      black backdrop, the feed mirrored like a mirror, a camera glyph
 *             (ink 0.3) until frames arrive
 *   hairline  1.5 px on the squircle edge, ink 0.35 (white in dark, black in
 *             light), inside the mask like the Mac's stroke sublayer
 */
import { useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";
import { createPortal } from "react-dom";
import { CameraIcon } from "lucide-react";

import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuRadioGroup,
  ContextMenuRadioItem,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import { cn } from "@/lib/utils";
import type { Rect, Size } from "@/editor/core/model/types";
import {
  BUBBLE_EXIT_MS,
  BUBBLE_SIZES,
  BUBBLE_TOOLTIP,
  SHADOW_PADDING,
  SQUIRCLE_MASK_IMAGE,
  UNIT_SQUIRCLE_D,
  anchorFromRect,
  clampRect,
  isCurrentSize,
  loadAnchor,
  loadDiameter,
  panelSize,
  placeBubble,
  restoreAnchor,
  saveAnchor,
  saveDiameter,
  type BubbleAnchor,
} from "@/editor/record/cameraBubble";

/** The squircle at whatever size its box is — it follows a size animation frame by frame. */
const SQUIRCLE_MASK: CSSProperties = {
  maskImage: SQUIRCLE_MASK_IMAGE,
  WebkitMaskImage: SQUIRCLE_MASK_IMAGE,
  maskSize: "100% 100%",
  WebkitMaskSize: "100% 100%",
  maskRepeat: "no-repeat",
  WebkitMaskRepeat: "no-repeat",
};

function MirroredFeed({ stream }: { stream: MediaStream }) {
  const ref = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const v = ref.current;
    if (!v) return;
    v.srcObject = stream;
    void v.play().catch(() => undefined);
    return () => {
      v.srcObject = null;
    };
  }, [stream]);
  // No backdrop of its own: until the first frame the video paints nothing
  // and the placeholder glyph underneath shows through.
  return (
    <video
      ref={ref}
      muted
      playsInline
      className="absolute inset-0 size-full object-cover"
      style={{ transform: "scaleX(-1)" }}
    />
  );
}

/**
 * The bubble's look (shadow + masked feed + hairline), filling its parent.
 * The page bubble and the floating controls window both draw it.
 */
export function CameraSquircle({ stream, className }: { stream: MediaStream | null; className?: string }) {
  return (
    <div className={cn("absolute inset-0", className)}>
      <div aria-hidden className="absolute inset-0" style={{ filter: "drop-shadow(0 5px 12px rgba(0, 0, 0, 0.35))" }}>
        <div className="size-full bg-black" style={SQUIRCLE_MASK} />
      </div>
      <div data-camera-clip className="absolute inset-0 overflow-hidden bg-black" style={SQUIRCLE_MASK}>
        <CameraIcon
          aria-hidden
          strokeWidth={1.75}
          className="absolute left-1/2 top-1/2 size-7 -translate-x-1/2 -translate-y-1/2 text-black/30 dark:text-white/30"
        />
        {stream && <MirroredFeed stream={stream} />}
        <svg
          aria-hidden
          viewBox="0 0 1 1"
          preserveAspectRatio="none"
          className="pointer-events-none absolute inset-0 size-full overflow-visible text-black/35 dark:text-white/35"
        >
          <path d={UNIT_SQUIRCLE_D} fill="none" stroke="currentColor" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
        </svg>
      </div>
    </div>
  );
}

// ── the page bubble ──────────────────────────────────────────────────────────

function readViewport(): Size {
  const root = document.documentElement;
  return { width: root.clientWidth || window.innerWidth, height: root.clientHeight || window.innerHeight };
}

/** The recording bar's frame — the default placement keeps clear of it. */
function dockRect(): Rect | null {
  const el = document.querySelector<HTMLElement>("[data-recorder-dock]");
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return { x: r.left, y: r.top, width: r.width, height: r.height };
}

/** Mounted while showing or leaving; "out" plays the exit before unmounting. */
function usePresence(show: boolean): "in" | "out" | null {
  const [state, setState] = useState<"in" | "out" | null>(show ? "in" : null);
  if (show && state !== "in") setState("in");
  if (!show && state === "in") setState("out");
  useEffect(() => {
    if (state !== "out") return;
    const t = window.setTimeout(() => setState(null), BUBBLE_EXIT_MS);
    return () => window.clearTimeout(t);
  }, [state]);
  return state;
}

/**
 * Floating over the page (portalled to <body>, above the dashboard and below
 * its menus). `show` false plays the exit, then unmounts; the next show
 * restores the remembered size and place.
 */
export function CameraBubble({ stream, show }: { stream: MediaStream | null; show: boolean }) {
  const presence = usePresence(show);
  if (!presence || typeof document === "undefined") return null;
  return createPortal(<FloatingBubble stream={stream} leaving={presence === "out"} />, document.body);
}

interface DragState {
  pointer: number;
  startX: number;
  startY: number;
  rect: Rect;
  moved: boolean;
}

function FloatingBubble({ stream, leaving }: { stream: MediaStream | null; leaving: boolean }) {
  const [viewport, setViewport] = useState<Size>(readViewport);
  const [diameter, setDiameter] = useState(loadDiameter);
  const [anchor, setAnchor] = useState<BubbleAnchor>(() =>
    restoreAnchor(loadAnchor(), panelSize(loadDiameter()), readViewport(), dockRect()),
  );
  const drag = useRef<DragState | null>(null);

  // Keep it on-screen as the window changes (placeBubble clamps; the anchor
  // itself is kept, so growing the window back returns it to its place).
  useEffect(() => {
    const sync = () => setViewport(readViewport());
    window.addEventListener("resize", sync);
    return () => window.removeEventListener("resize", sync);
  }, []);

  const panel = panelSize(diameter);
  const { css } = placeBubble(anchor, diameter, viewport);

  const dragTo = (e: ReactPointerEvent<HTMLElement>, d: DragState): BubbleAnchor => {
    const moved = clampRect({ ...d.rect, x: d.rect.x + e.clientX - d.startX, y: d.rect.y + e.clientY - d.startY }, viewport);
    return anchorFromRect(moved, viewport);
  };

  const onPointerDown = (e: ReactPointerEvent<HTMLElement>) => {
    // Primary button only; control-click is the Mac's right-click (the size menu).
    if (e.button !== 0 || e.ctrlKey) return;
    drag.current = {
      pointer: e.pointerId,
      startX: e.clientX,
      startY: e.clientY,
      rect: placeBubble(anchor, diameter, viewport).rect,
      moved: false,
    };
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e: ReactPointerEvent<HTMLElement>) => {
    const d = drag.current;
    if (!d || d.pointer !== e.pointerId) return;
    if (!d.moved && Math.hypot(e.clientX - d.startX, e.clientY - d.startY) < 1) return;
    d.moved = true;
    setAnchor(dragTo(e, d));
  };
  const endDrag = (e: ReactPointerEvent<HTMLElement>) => {
    const d = drag.current;
    if (!d || d.pointer !== e.pointerId) return;
    drag.current = null;
    if (!d.moved) return;
    const next = dragTo(e, d);
    setAnchor(next);
    saveAnchor(next);
  };

  const pickSize = (value: number) => {
    setDiameter(value);
    saveDiameter(value);
  };
  const current = BUBBLE_SIZES.find((s) => isCurrentSize(diameter, s.diameter));

  return (
    <div
      data-rec-ui="bubble"
      data-camera-bubble={leaving ? "out" : "in"}
      data-diameter={diameter}
      className={cn("pointer-events-none fixed z-[45]", leaving ? "rec-bubble-out" : "rec-bubble-in")}
      style={{
        ...css,
        width: panel,
        height: panel,
        // Growth lands on the house bounce; the anchored edges stay pinned.
        transition: "width var(--rec-grow) var(--rec-bounce), height var(--rec-grow) var(--rec-bounce)",
      }}
    >
      <ContextMenu>
        <ContextMenuTrigger asChild disabled={leaving}>
          <div
            role="img"
            aria-label="Camera preview"
            title={BUBBLE_TOOLTIP}
            className={cn(
              "absolute cursor-grab touch-none select-none active:cursor-grabbing",
              leaving ? "pointer-events-none" : "pointer-events-auto",
            )}
            style={{ inset: SHADOW_PADDING }}
            onPointerDown={onPointerDown}
            onPointerMove={onPointerMove}
            onPointerUp={endDrag}
            onPointerCancel={endDrag}
          >
            <CameraSquircle stream={stream} />
          </div>
        </ContextMenuTrigger>
        <ContextMenuContent className="min-w-36">
          <ContextMenuRadioGroup value={current ? String(current.diameter) : ""} onValueChange={(v) => pickSize(Number(v))}>
            {BUBBLE_SIZES.map((s) => (
              <ContextMenuRadioItem key={s.diameter} value={String(s.diameter)}>
                {s.label}
              </ContextMenuRadioItem>
            ))}
          </ContextMenuRadioGroup>
        </ContextMenuContent>
      </ContextMenu>
    </div>
  );
}
