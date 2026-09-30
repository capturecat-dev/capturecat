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
  const viewport = useRef<StageViewport>({ cssWidth: 0, cssHeight: 0, dpr: 1, zoom });
  const mountRef = useRef(mount);
  mountRef.current = mount;
  const [resizing, setResizing] = useState(false);

  // Mount/unmount the engine into the slot.
  useLayoutEffect(() => {
    const slot = slotRef.current;
    if (!slot || !mount) return;
    const rect = slot.getBoundingClientRect();
    viewport.current = {
      cssWidth: Math.round(rect.width),
      cssHeight: Math.round(rect.height),
      dpr: window.devicePixelRatio || 1,
      zoom,
    };
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
      const rect = slot.getBoundingClientRect();
      snapCanvas(slot, rect);
      const next: StageViewport = {
        cssWidth: Math.round(rect.width),
        cssHeight: Math.round(rect.height),
        dpr: window.devicePixelRatio || 1,
        zoom,
      };
      const v = viewport.current;
      if (next.cssWidth === v.cssWidth && next.cssHeight === v.cssHeight && next.dpr === v.dpr && next.zoom === v.zoom) return;
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
    <div className="cc-stagewrap">
      <div className="cc-stagecard">
        <div className="cc-stagescroll" data-zoomed={zoom > 1 || undefined}>
          <div
            ref={slotRef}
            className="cc-stageslot"
            data-engine-slot=""
            data-resizing={resizing || undefined}
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
