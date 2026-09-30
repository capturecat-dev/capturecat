/**
 * The export loop's per-frame cursor decisions (VideoExporter.export ≈ lines
 * 1481–1490 and 1730–1776), as data for the GPU passes:
 *
 *   cursorPosition = CursorSmoother.interpolateIfFresh(events, at: t)
 *   if showCursor, cursorPosition, sourceExtent > 0:
 *       renderCursorCI(...)              → `sprite` (null = auto-hidden / no layout)
 *       if showClickRipple: renderClickRipple(...) → `ripple` (null = nothing to draw)
 *
 * `t` is SOURCE seconds (`timelineSourceTimes[i]`). All math is the core's
 * (exportCursorFrame / cursorSpriteComposite / renderClickRipple); this file
 * only windows the event list for the ripple query (see `rippleWindow`).
 */
import type { CursorEvent } from "../../../core/model/types";
import {
  cursorSpriteComposite,
  exportCursorFrame,
  renderClickRipple,
  type CursorSpriteComposite,
} from "../../../core/math/exportCursor";
import type { RippleExportDraw } from "../../../core/math/clickRippleOverlay";
import type { CursorSceneData } from "./cursorScene";

export interface CursorFrameDraw {
  sprite: CursorSpriteComposite | null;
  ripple: RippleExportDraw | null;
}

const NONE: CursorFrameDraw = { sprite: null, ripple: null };

/** First index whose timestamp is ≥ `t` (events are time-ordered). */
function lowerBound(events: readonly CursorEvent[], t: number): number {
  let lo = 0;
  let hi = events.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (events[mid].timestamp < t) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/** Longest look-back any ripple-overlay term has: ripple life 0.45 s, drag
 * release 0.25 s (clickRippleOverlay.defaultRippleDuration / dragRelease). */
const LOOK_BACK = 0.5;

/**
 * The slice of `events` whose ripple-overlay result at `t` equals the whole
 * list's: every press-run (contiguous `isClick` samples) that can still draw
 * at `t` is included WHOLE (run detection, the drag threshold and a ripple's
 * anchor sample all depend on the complete run), plus the samples bracketing
 * `t` for the drag glow's `interpolate`. Runs entirely outside contribute
 * nothing (elapsed > 0.45 s, or a drag released > 0.25 s ago, or starting
 * after `t`). Proven equal to the full-list result by cursorFrame.test.ts.
 * Keeps the per-frame cost O(log n + window) on long recordings.
 */
export function rippleWindow(events: readonly CursorEvent[], t: number): readonly CursorEvent[] {
  const n = events.length;
  if (n === 0) return events;
  let lo = Math.max(0, lowerBound(events, t - LOOK_BACK) - 1);
  while (lo > 0 && events[lo].isClick) lo--;
  let hi = Math.min(n, lowerBound(events, t) + 1);
  while (hi < n && events[hi - 1].isClick) hi++;
  if (hi < n) hi++; // bracket sample after t
  return lo === 0 && hi === n ? events : events.slice(lo, hi);
}

/** Per-frame cursor + ripple draw data; `hasSourceFrame` = a decoded frame is shown. */
export function cursorFrameDraw(data: CursorSceneData, t: number, hasSourceFrame: boolean): CursorFrameDraw {
  const { settings, events } = data;
  const gate = exportCursorFrame(t, events, settings, hasSourceFrame);
  if (!gate.drawCursor || !gate.cursorPosition) return NONE;

  let sprite: CursorSpriteComposite | null = null;
  const raster = data.asset.rasterPixelSize;
  if (raster) {
    sprite = cursorSpriteComposite(
      t,
      gate.cursorPosition,
      events,
      { baseSize: data.asset.baseSize, hotSpot: data.asset.hotSpot, rasterPixelSize: raster },
      data.coordinateSize,
      data.layoutVideoRect,
      data.outputSize,
      settings,
      data.canvasScale,
    );
  }

  let ripple: RippleExportDraw | null = null;
  if (gate.drawRipples) {
    const r = renderClickRipple(t, rippleWindow(events, t), data.coordinateSize, data.layoutVideoRect, settings);
    if (r.draws && r.draw && r.draw.ops.length > 0) ripple = r.draw;
  }
  return { sprite, ripple };
}
