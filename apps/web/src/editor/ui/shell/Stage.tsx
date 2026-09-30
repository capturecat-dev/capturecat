/**
 * The stage card (EditorStageViewController): panel-surface card, radius lg,
 * no hairline, the output canvas letterboxed to the project aspect and
 * centred, and the bottom-trailing zoom pill `[-] 100% [+]` (inset 10).
 *
 * THE ENGINE SLOT: `.cc-stageslot` is exactly the letterboxed output rect.
 * The engine mounts into it via `StageMount.mount(host, viewport)` and gets
 * every size/zoom/DPR change through `onViewport` (see shell/types.ts).
 */
import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";

import { QuietButton } from "../kit";
import { clampPreviewZoom, stageReferenceSize } from "../stage/stageLayout";
import type { StageMount, StageViewport } from "./types";

export const ZOOM_STEPS = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4] as const;

/**
 * One device pixel of the render per screen pixel. The slot's size comes from
 * a CSS calc (e.g. 884.44 × 497.5) and it is centred at a fractional offset;
 * a canvas stretched to it is resampled by a fraction of a pixel on display —
 * Chrome snaps that away, Safari visibly softens every frame (small text went
 * to mush). So the canvas gets EXACTLY its backing size in CSS px (the engine
 * backs it at round(round(css) × dpr)) and a sub-pixel nudge onto the device
 * grid.
 */
function snapCanvas(slot: HTMLElement, rect: DOMRect): void {
  const dpr = window.devicePixelRatio || 1;
  const w = Math.max(1, Math.round(Math.round(rect.width) * dpr));
  const h = Math.max(1, Math.round(Math.round(rect.height) * dpr));
  const dx = (Math.round(rect.left * dpr) - rect.left * dpr) / dpr;
  const dy = (Math.round(rect.top * dpr) - rect.top * dpr) / dpr;
  slot.style.setProperty("--cv-w", `${w / dpr}px`);
  slot.style.setProperty("--cv-h", `${h / dpr}px`);
  slot.style.setProperty("--cv-x", `${dx}px`);
  slot.style.setProperty("--cv-y", `${dy}px`);
}

export function Stage({
  aspect,
  mount,
  zoom,
  onZoomChange,
}: {
  /** Output canvas w/h. */
  aspect: number;
  mount?: StageMount;
  zoom: number;
  onZoomChange: (zoom: number) => void;
}) {
  const slotRef = useRef<HTMLDivElement>(null);
  const cardRef = useRef<HTMLDivElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const viewport = useRef<StageViewport>({ cssWidth: 0, cssHeight: 0, dpr: 1, zoom });
  const mountRef = useRef(mount);
  mountRef.current = mount;
  const aspectRef = useRef(aspect);
  aspectRef.current = aspect;
  const zoomRef = useRef(zoom);
  zoomRef.current = zoom;
  const onZoomRef = useRef(onZoomChange);
  onZoomRef.current = onZoomChange;
  const [resizing, setResizing] = useState(false);
  // A pinch is in flight: the slot follows the fingers with no settle
  // transition, and the point under them stays put (NSScrollView magnify).
  const [pinching, setPinching] = useState(false);
  const pinchAnchor = useRef<{ clientX: number; clientY: number; fx: number; fy: number } | null>(null);

  /** Slot size + the unmagnified letterboxed canvas (`project.previewCanvasSize`). */
  const measure = (slot: HTMLElement): StageViewport => {
    const rect = slot.getBoundingClientRect();
    const card = cardRef.current?.getBoundingClientRect();
    const ref = card ? stageReferenceSize({ width: card.width, height: card.height }, aspectRef.current) : null;
    return {
      cssWidth: Math.round(rect.width),
      cssHeight: Math.round(rect.height),
      dpr: window.devicePixelRatio || 1,
      zoom: zoomRef.current,
      reference: ref && ref.width > 0 && ref.height > 0 ? { width: Math.round(ref.width), height: Math.round(ref.height) } : undefined,
    };
  };

  // Mount/unmount the engine into the slot.
  useLayoutEffect(() => {
    const slot = slotRef.current;
    if (!slot || !mount) return;
    viewport.current = measure(slot);
    const cleanup = mount.mount(slot, viewport.current);
    return cleanup;
    // Mount identity only — viewport changes flow through onViewport.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mount]);

  // Report size / DPR / zoom changes.
  useEffect(() => {
    const slot = slotRef.current;
    if (!slot) return;
    let settle = 0;
    const report = () => {
      snapCanvas(slot, slot.getBoundingClientRect());
      const next = measure(slot);
      const v = viewport.current;
      if (
        next.cssWidth === v.cssWidth &&
        next.cssHeight === v.cssHeight &&
        next.dpr === v.dpr &&
        next.zoom === v.zoom &&
        next.reference?.width === v.reference?.width &&
        next.reference?.height === v.reference?.height
      ) {
        return;
      }
      viewport.current = next;
      mountRef.current?.onViewport?.(next);
    };
    const ro = new ResizeObserver(() => {
      // While the window is being resized, snap (no settle transition) so
      // the canvas never lags the card.
      setResizing(true);
      window.clearTimeout(settle);
      settle = window.setTimeout(() => setResizing(false), 120);
      report();
    });
    ro.observe(slot);
    if (cardRef.current) ro.observe(cardRef.current);
    // The slot also MOVES without resizing (sidebar, inspector) — re-snap.
    const onWindow = () => snapCanvas(slot, slot.getBoundingClientRect());
    window.addEventListener("resize", onWindow);
    report();
    return () => {
      ro.disconnect();
      window.removeEventListener("resize", onWindow);
      window.clearTimeout(settle);
    };
  }, [zoom]);

  // Keep the pinched point under the fingers once the new size has laid out.
  useLayoutEffect(() => {
    const anchor = pinchAnchor.current;
    const slot = slotRef.current;
    const scroll = scrollRef.current;
    if (!anchor || !slot || !scroll) return;
    pinchAnchor.current = null;
    const r = slot.getBoundingClientRect();
    scroll.scrollLeft += r.left - (anchor.clientX - anchor.fx * r.width);
    scroll.scrollTop += r.top - (anchor.clientY - anchor.fy * r.height);
  }, [zoom]);

  // Trackpad pinch → the SAME zoom the pill drives (the Mac scroll view's
  // `allowsMagnification`, 0.25…4×, continuous). Chromium/Firefox deliver a
  // pinch as ctrl+wheel; Safari as gesture events.
  useEffect(() => {
    const wrap = wrapRef.current;
    if (!wrap) return;
    let settle = 0;
    let gestureBase = 1;
    const apply = (next: number, clientX: number, clientY: number) => {
      const z = clampPreviewZoom(next);
      if (Math.abs(z - zoomRef.current) < 1e-4) return;
      const slot = slotRef.current;
      if (slot) {
        const r = slot.getBoundingClientRect();
        const fx = r.width > 0 ? Math.min(1, Math.max(0, (clientX - r.left) / r.width)) : 0.5;
        const fy = r.height > 0 ? Math.min(1, Math.max(0, (clientY - r.top) / r.height)) : 0.5;
        pinchAnchor.current = { clientX, clientY, fx, fy };
      }
      setPinching(true);
      window.clearTimeout(settle);
      settle = window.setTimeout(() => setPinching(false), 160);
      zoomRef.current = z;
      onZoomRef.current(z);
    };
    const onWheel = (e: WheelEvent) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      const dy = e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY;
      apply(zoomRef.current * Math.exp(-dy * 0.01), e.clientX, e.clientY);
    };
    const onGestureStart = (e: Event) => {
      e.preventDefault();
      gestureBase = zoomRef.current;
    };
    const onGestureChange = (e: Event & { scale?: number; clientX?: number; clientY?: number }) => {
      e.preventDefault();
      const r = wrap.getBoundingClientRect();
      apply(gestureBase * (e.scale ?? 1), e.clientX ?? r.left + r.width / 2, e.clientY ?? r.top + r.height / 2);
    };
    wrap.addEventListener("wheel", onWheel, { passive: false });
    wrap.addEventListener("gesturestart", onGestureStart);
    wrap.addEventListener("gesturechange", onGestureChange as EventListener);
    return () => {
      wrap.removeEventListener("wheel", onWheel);
      wrap.removeEventListener("gesturestart", onGestureStart);
      wrap.removeEventListener("gesturechange", onGestureChange as EventListener);
      window.clearTimeout(settle);
    };
  }, []);

  const step = (dir: 1 | -1) => {
    if (dir > 0) {
      const next = ZOOM_STEPS.find((z) => z > zoom + 1e-6);
      if (next) onZoomChange(next);
    } else {
      const prev = [...ZOOM_STEPS].reverse().find((z) => z < zoom - 1e-6);
      if (prev) onZoomChange(prev);
    }
  };

  // ⌘- / ⌘= like the Mac pill's key equivalents.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey) || e.altKey) return;
      if (e.key === "=" || e.key === "+") {
        e.preventDefault();
        step(1);
      } else if (e.key === "-") {
        e.preventDefault();
        step(-1);
      } else if (e.key === "0") {
        e.preventDefault();
        onZoomChange(1);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  return (
    <div ref={wrapRef} className="cc-stagewrap">
      <div ref={cardRef} className="cc-stagecard">
        <div ref={scrollRef} className="cc-stagescroll" data-zoomed={zoom > 1 || undefined}>
          <div
            ref={slotRef}
            className="cc-stageslot"
            data-engine-slot=""
            data-resizing={resizing || pinching || undefined}
            style={{ "--aspect": aspect, "--zoom": zoom } as CSSProperties}
          />
        </div>
      </div>
      <div className="cc-zoompill">
        <QuietButton symbol="minus.magnifyingglass" paddingX={1} title="Zoom Out (⌘-)" disabled={zoom <= ZOOM_STEPS[0]} onClick={() => step(-1)} />
        <QuietButton paddingX={5} style={{ minWidth: 36 }} title="Reset zoom to 100%" onClick={() => onZoomChange(1)}>
          {Math.round(zoom * 100)}%
        </QuietButton>
        <QuietButton
          symbol="plus.magnifyingglass"
          paddingX={1}
          title="Zoom In (⌘=)"
          disabled={zoom >= ZOOM_STEPS[ZOOM_STEPS.length - 1]}
          onClick={() => step(1)}
        />
      </div>
    </div>
  );
}
