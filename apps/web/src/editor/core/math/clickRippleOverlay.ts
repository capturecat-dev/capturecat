/**
 * Port of Views/Editor/ClickRippleOverlay.swift `ClickRippleOverlay` — the
 * click-ripple frame math shared by the preview compositor and the exporter
 * (CLAUDE.md §2 names `discreteClickTimes` as a preview/export source of
 * truth): `activeRipples`, `discreteClickTimes`, `discreteClicks`,
 * (fileprivate) `discreteClickEvents`, `dragHighlightRuns`,
 * `dragHighlightStrength`, (private) `clickDragThreshold`, and every number
 * `renderForExport(into:...)` draws.
 *
 * Discrete clicks: the tracker flags EVERY sample while the button is down, so
 * a press-run becomes ONE click (its first sample) unless the pointer moved
 * more than `clickDragThreshold` from the run's first sample (a drag — those
 * become `dragHighlightRuns` with a sustained glow instead).
 *
 * Locked to Swift by `clickRippleDiscrete`, `clickRippleActive` and
 * `clickRippleExportDraw` (the last is a verbatim oracle of the numbers
 * renderForExport feeds CoreGraphics, self-checked in Swift by re-drawing
 * them and comparing bytes with the real renderForExport).
 */
import type { CursorEvent, Point, Rect, Size } from "../model/types";
import { maxY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { interpolate } from "./cursorSmoother";
import { chypot } from "./cursorSupport";
import { smax, smin } from "./swift";

/** Default ripple lifetime (s) — `rippleDuration: Double = 0.45`. */
export const defaultRippleDuration = 0.45;
/** Drag-glow attack / release (s). */
export const dragAttack = 0.12;
export const dragRelease = 0.25;

export interface ActiveRipple {
  /** Ripple centre in `videoRect`'s space (both renderers pass Y-DOWN). */
  position: Point;
  /** 0…1 over `rippleDuration`. */
  progress: number;
  /** Index of the click's first sample in `cursorEvents` (stable layer id). */
  id: number;
}

export interface TimeRun {
  start: number;
  end: number;
}

/** `ClickRippleOverlay.clickDragThreshold(for:)` (private): 0.6 % of the
 * short side, clamped to 10…24 recording points; 12 when the size is unknown. */
export function clickDragThreshold(coordinateSize: Size): number {
  const shortSide = smin(coordinateSize.width, coordinateSize.height);
  if (!(shortSide > 0)) return 12;
  return smax(10, smin(24, shortSide * 0.006));
}

/** `ClickRippleOverlay.discreteClickEvents(from:coordinateSize:)` (fileprivate). */
export function discreteClickEvents(
  cursorEvents: readonly CursorEvent[],
  coordinateSize: Size,
): { index: number; event: CursorEvent }[] {
  const result: { index: number; event: CursorEvent }[] = [];
  let startIndex: number | null = null;
  let startEvent: CursorEvent | null = null;
  let maxDistance = 0;
  const dragThreshold = clickDragThreshold(coordinateSize);

  const finishRun = () => {
    if (startIndex === null || startEvent === null) return;
    if (maxDistance <= dragThreshold) result.push({ index: startIndex, event: startEvent });
    startIndex = null;
    startEvent = null;
    maxDistance = 0;
  };

  for (let index = 0; index < cursorEvents.length; index++) {
    const event = cursorEvents[index];
    if (event.isClick) {
      if (startEvent === null) {
        startIndex = index;
        startEvent = event;
        maxDistance = 0;
      } else {
        const distance = chypot(event.x - startEvent.x, event.y - startEvent.y);
        maxDistance = smax(maxDistance, distance);
      }
    } else {
      finishRun();
    }
  }
  finishRun();
  return result;
}

/** `ClickRippleOverlay.discreteClickTimes(from:coordinateSize:)` — the click
 * SOUND fires once per entry, exactly like the ripple. */
export function discreteClickTimes(cursorEvents: readonly CursorEvent[], coordinateSize: Size): number[] {
  return discreteClickEvents(cursorEvents, coordinateSize).map((c) => c.event.timestamp);
}

/** `ClickRippleOverlay.discreteClicks(from:coordinateSize:)` (Auto Zoom input). */
export function discreteClicks(cursorEvents: readonly CursorEvent[], coordinateSize: Size): CursorEvent[] {
  return discreteClickEvents(cursorEvents, coordinateSize).map((c) => c.event);
}

/** `ClickRippleOverlay.dragHighlightRuns(from:coordinateSize:)` — press-runs
 * that travelled PAST the drag threshold, as (first, last) click timestamps. */
export function dragHighlightRuns(cursorEvents: readonly CursorEvent[], coordinateSize: Size): TimeRun[] {
  const result: TimeRun[] = [];
  let startEvent: CursorEvent | null = null;
  let lastClick: CursorEvent | null = null;
  let maxDistance = 0;
  const dragThreshold = clickDragThreshold(coordinateSize);

  const finishRun = () => {
    if (startEvent !== null && lastClick !== null && maxDistance > dragThreshold) {
      result.push({ start: startEvent.timestamp, end: lastClick.timestamp });
    }
    startEvent = null;
    lastClick = null;
    maxDistance = 0;
  };

  for (const event of cursorEvents) {
    if (event.isClick) {
      if (startEvent !== null) {
        maxDistance = smax(maxDistance, chypot(event.x - startEvent.x, event.y - startEvent.y));
      } else {
        startEvent = event;
      }
      lastClick = event;
    } else {
      finishRun();
    }
  }
  finishRun();
  return result;
}

/** `ClickRippleOverlay.dragHighlightStrength(runs:at:)` — 0…1; quick attack
 * once the press starts moving, short fade after release. */
export function dragHighlightStrength(runs: readonly TimeRun[], time: number): number {
  const attack = 0.12;
  const release = 0.25;
  let strength = 0.0;
  for (const run of runs) {
    if (time >= run.start && time <= run.end) {
      strength = smax(strength, smin(1, (time - run.start) / attack));
    } else if (time > run.end) {
      strength = smax(strength, smin(1, smax(0, 1 - (time - run.end) / release)));
    }
  }
  return strength;
}

/** `ClickRippleOverlay.activeRipples(cursorEvents:currentTime:coordinateSize:videoRect:rippleDuration:)`. */
export function activeRipples(
  cursorEvents: readonly CursorEvent[],
  currentTime: number,
  coordinateSize: Size,
  videoRect: Rect,
  rippleDuration = defaultRippleDuration,
): ActiveRipple[] {
  if (
    !(
      rectWidth(videoRect) > 0 &&
      rectHeight(videoRect) > 0 &&
      coordinateSize.width > 0 &&
      coordinateSize.height > 0
    )
  ) {
    return [];
  }
  const ripples: ActiveRipple[] = [];
  for (const { index, event } of discreteClickEvents(cursorEvents, coordinateSize)) {
    const elapsed = currentTime - event.timestamp;
    if (!(elapsed >= 0 && elapsed <= rippleDuration)) continue;
    const progress = elapsed / rippleDuration;
    const viewX = minX(videoRect) + (event.x / coordinateSize.width) * rectWidth(videoRect);
    const viewY = minY(videoRect) + (event.y / coordinateSize.height) * rectHeight(videoRect);
    ripples.push({ position: { x: viewX, y: viewY }, progress, id: index });
  }
  return ripples;
}

/**
 * One CoreGraphics call of `renderForExport`: an ellipse inscribed in `rect`,
 * stroked (`lineWidth` set) or filled (`lineWidth` null), in the ripple colour
 * with its alpha REPLACED by `alpha` (`CGColor.copy(alpha:)` — the colour's own
 * opacity is ignored). `rect` is the raw CGRect Swift builds (a negative size
 * is possible only for a negative rippleSize; CG standardizes it when drawing).
 */
export interface RippleDrawOp {
  kind: "strokeEllipse" | "fillEllipse";
  rect: Rect;
  lineWidth: number | null;
  alpha: number;
}

export interface RippleExportDraw {
  /** Draw calls in order (per ripple: outer ring, inner ring, centre dot;
   * then the drag glow ring + fill). */
  ops: RippleDrawOp[];
  /** `dragHighlightStrength` at `currentTime` (the glow draws when > 0.01). */
  dragStrength: number;
}

/**
 * Every number `ClickRippleOverlay.renderForExport(into:cursorEvents:
 * currentTime:videoRect:sourceSize:rippleColor:rippleSize:rippleDuration:)`
 * draws, in draw order.
 *
 * SPACE: the exporter passes `layout.videoRect` in CoreImage/CG Y-UP output
 * pixels and draws into a full-output-size CGContext (origin bottom-left), so
 * every rect here is Y-UP output pixels: `cy = videoRect.maxY − y/h·height`.
 * A Y-down GPU pass uses `outputHeight − cy`. Line widths (2.5 / 1.5 / 2),
 * the 3 px dot and `rippleSize` are raw OUTPUT PIXELS — NOT multiplied by
 * canvasScale (unlike the cursor shadow). Stroke = centred on the ellipse
 * path, antialiased, source-over in sRGB (8-bit premultiplied BGRA context),
 * then composited over the frame.
 */
export function renderForExport(
  cursorEvents: readonly CursorEvent[],
  currentTime: number,
  videoRect: Rect,
  sourceSize: Size,
  rippleSize: number,
  rippleDuration = defaultRippleDuration,
): RippleExportDraw {
  const ops: RippleDrawOp[] = [];
  if (
    !(
      rectWidth(videoRect) > 0 &&
      rectHeight(videoRect) > 0 &&
      sourceSize.width > 0 &&
      sourceSize.height > 0
    )
  ) {
    return { ops, dragStrength: 0 };
  }

  for (const { event } of discreteClickEvents(cursorEvents, sourceSize)) {
    const elapsed = currentTime - event.timestamp;
    if (!(elapsed >= 0 && elapsed <= rippleDuration)) continue;

    const progress = elapsed / rippleDuration;
    const screenX = event.x / sourceSize.width;
    const screenY = event.y / sourceSize.height;
    // In CG coordinates, Y is flipped.
    const cx = minX(videoRect) + screenX * rectWidth(videoRect);
    const cy = maxY(videoRect) - screenY * rectHeight(videoRect);

    const outerScale = 0.2 + progress * 0.8;
    const outerOpacity = 1.0 - progress;
    const radius = (rippleSize * outerScale) / 2;
    ops.push({
      kind: "strokeEllipse",
      rect: { x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2 },
      lineWidth: 2.5,
      alpha: outerOpacity * 0.7,
    });

    const innerProgress = smax(0, progress - 0.1) / 0.9;
    const innerScale = 0.15 + innerProgress * 0.5;
    const innerOpacity = smax(0, 1.0 - innerProgress * 1.5);
    const innerRadius = (rippleSize * 0.6 * innerScale) / 2;
    ops.push({
      kind: "strokeEllipse",
      rect: {
        x: cx - innerRadius,
        y: cy - innerRadius,
        width: innerRadius * 2,
        height: innerRadius * 2,
      },
      lineWidth: 1.5,
      alpha: innerOpacity * 0.5,
    });

    const dotOpacity = smax(0, 1.0 - progress * 3);
    const dotRadius = 3;
    ops.push({
      kind: "fillEllipse",
      rect: { x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2 },
      lineWidth: null,
      alpha: dotOpacity * 0.6,
    });
  }

  // Drag-highlight glow at the interpolated cursor position, Y-flipped for CG.
  const runs = dragHighlightRuns(cursorEvents, sourceSize);
  const strength = dragHighlightStrength(runs, currentTime);
  if (strength > 0.01) {
    const pos = interpolate(cursorEvents, currentTime);
    const cx = minX(videoRect) + (pos.x / sourceSize.width) * rectWidth(videoRect);
    const cy = maxY(videoRect) - (pos.y / sourceSize.height) * rectHeight(videoRect);
    const ringD = rippleSize * 0.33;
    const rect = { x: cx - ringD / 2, y: cy - ringD / 2, width: ringD, height: ringD };
    ops.push({ kind: "strokeEllipse", rect, lineWidth: 2, alpha: 0.55 * strength });
    ops.push({ kind: "fillEllipse", rect: { ...rect }, lineWidth: null, alpha: 0.15 * strength });
  }
  return { ops, dragStrength: strength };
}
