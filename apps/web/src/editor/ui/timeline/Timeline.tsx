/**
 * React wrapper for the canvas timeline: the DOM label column + the track
 * viewport hosting TimelineRenderer. React renders this only when the
 * snapshot/scale/theme changes; playback time flows through the
 * PlayheadChannel straight into the renderer.
 */
import { memo, useEffect, useLayoutEffect, useRef, useState } from "react";

import { useCCTheme } from "../kit";
import type { PlayheadChannel } from "../shell/types";
import { canvasAreaHeight, M } from "./metrics";
import { TimelineRenderer, type ContextMenuRequest } from "./TimelineRenderer";
import type { TimelineIntents, TimelineSnapshot } from "./types";

const LANES = ["VIDEO", "VOICE", "EFFECTS", "FOCUS", "ANNOTATE"] as const;

export interface TimelineProps {
  snapshot: TimelineSnapshot;
  intents: TimelineIntents;
  playhead: PlayheadChannel;
  isPlaying: boolean;
  scale: number;
  onScaleChange(scale: number): void;
  onContextMenu?(req: ContextMenuRequest): void;
  /** EFFECTS sub-row count changed — the panel height follows. */
  onEffectsRows?(rows: number): void;
  /** Exposes the renderer (perf harness / dev tools). */
  rendererRef?: { current: TimelineRenderer | null };
}

export const Timeline = memo(function Timeline({
  snapshot,
  intents,
  playhead,
  isPlaying,
  scale,
  onScaleChange,
  onContextMenu,
  onEffectsRows,
  rendererRef,
}: TimelineProps) {
  const { themeKey } = useCCTheme();
  const hostRef = useRef<HTMLDivElement>(null);
  const baseRef = useRef<HTMLCanvasElement>(null);
  const overlayRef = useRef<HTMLCanvasElement>(null);
  const labelsRef = useRef<HTMLDivElement>(null);
  const renderer = useRef<TimelineRenderer | null>(null);
  const [effectsRows, setEffectsRows] = useState(1);

  // Latest callbacks without re-creating the renderer.
  const hooks = useRef({ intents, onContextMenu, onScaleChange, onEffectsRows });
  hooks.current = { intents, onContextMenu, onScaleChange, onEffectsRows };

  useLayoutEffect(() => {
    const host = hostRef.current!;
    const r = new TimelineRenderer(host, baseRef.current!, overlayRef.current!, {
      get intents() {
        return hooks.current.intents;
      },
      onContextMenu: (req) => hooks.current.onContextMenu?.(req),
      onLayout: ({ effectsRows: rows }) => {
        setEffectsRows(rows);
        hooks.current.onEffectsRows?.(rows);
      },
      onScrollY: (y) => {
        if (labelsRef.current) labelsRef.current.style.transform = `translateY(${-y}px)`;
      },
      onScale: (s) => hooks.current.onScaleChange(s),
    });
    renderer.current = r;
    if (rendererRef) rendererRef.current = r;
    const measure = () => {
      const rect = host.getBoundingClientRect();
      r.resize(Math.round(rect.width), Math.round(rect.height), window.devicePixelRatio || 1);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(host);
    // DPR changes (window dragged across displays / zoom).
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
      r.destroy();
      renderer.current = null;
      if (rendererRef) rendererRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useLayoutEffect(() => {
    renderer.current?.setSnapshot(snapshot);
  }, [snapshot]);

  useLayoutEffect(() => {
    renderer.current?.refreshTheme();
  }, [themeKey]);

  useEffect(() => {
    const r = renderer.current;
    if (!r) return;
    r.setPlayhead(playhead.get());
    return playhead.subscribe((t) => r.setPlayhead(t));
  }, [playhead]);

  useEffect(() => {
    renderer.current?.setPlaying(isPlaying);
  }, [isPlaying]);

  useEffect(() => {
    const r = renderer.current;
    if (r && Math.abs(r.getScale() - scale) > 0.0001) r.setScale(scale);
  }, [scale]);

  const extra = (effectsRows - 1) * M.subRowPitch;

  return (
    <div className="cc-tl-area" style={{ height: canvasAreaHeight(effectsRows) }}>
      <div className="cc-tl-labels" aria-hidden>
        <div ref={labelsRef} className="cc-tl-labels__inner">
          <div style={{ height: M.rulerHeight + M.rulerBottomSpacing }} />
          {LANES.map((name, i) => (
            <div
              key={name}
              className="cc-tl-label"
              style={{
                height: name === "EFFECTS" ? M.trackHeight + extra : M.trackHeight,
                marginBottom: i < LANES.length - 1 ? M.trackSpacing : 0,
              }}
            >
              {name}
            </div>
          ))}
        </div>
      </div>
      <div ref={hostRef} className="cc-tl-viewport" role="application" aria-label="Timeline">
        <canvas ref={baseRef} className="cc-tl-canvas" />
        <canvas ref={overlayRef} className="cc-tl-canvas cc-tl-canvas--overlay" />
      </div>
    </div>
  );
});
