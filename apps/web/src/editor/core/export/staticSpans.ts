/**
 * Fast export — static-span collapse (VFR). A 1:1 port of `StaticSpanCollapse`
 * (apps/macos/CaptureCat/Services/ExportFormats.swift), locked to the Swift by
 * the `collapse` golden vectors (`CaptureCat --export-formats-test`) and, end
 * to end, by the Mac exporter's own sample timestamps for the synthetic VFR
 * fixture (scripts/editor-lab/export-formats.mjs).
 *
 * When NOTHING that reaches the pixels changes between two output frames, the
 * second frame is neither rendered nor encoded — the previous sample simply
 * lasts longer. A frame is skippable only if it is neither the first nor the
 * last, its quantized key equals the LAST APPENDED frame's, the last appended
 * frame is < 5 s old, the cursor has not MOVED in the trailing 2 s, and the
 * time is outside every SOURCE-time hot span (camera-layout morphs, blur /
 * focus / highlight / subtitle / annotation / shortcut-pill spans, device
 * dips) and every OUTPUT-time hot span (curtain unveil, intro slide).
 *
 * Times are the Mac exporter's: frame i's output seconds are
 * `CMTime(seconds: i / fps, preferredTimescale: 600)` (truncated — see
 * `exportFrameSeconds`), its source seconds `timeMap.sourceTime(output)`.
 */
import { animationSpeedDuration } from "../model/enums";
import type { CursorEvent, Point, Project, ProjectSettings, Rect } from "../model/types";
import { formatFixed, srounded } from "../math/swift";
import { cmTimeSeconds } from "../math/exportLayout";
import { transitionDuration as cameraLayoutTransition } from "../math/cameraLayoutMath";
import { fadeIn, fadeOut, hold } from "../math/keystrokeOverlay";
import { sigma as deviceDipSigma } from "../math/deviceSegmentDip";

export interface Span {
  start: number;
  end: number;
}

/** A frame is forced at least this often (seconds of output). */
export const MAX_STATIC_GAP = 5;
/** Trailing window in which cursor MOTION can still move pixels (springs, ripples, hide fades). */
export const CURSOR_QUIET_WINDOW = 2;

/** Everything the compositor reads that can change between two frames (`StaticSpanCollapse.FrameKey`). */
export interface StaticFrameKey {
  videoSampleSeconds: number;
  cameraSampleSeconds: number;
  zoom: number;
  focalX: number;
  focalY: number;
  offsetX: number;
  offsetY: number;
  tiltPitch: number;
  tiltYaw: number;
  tiltRoll: number;
  cursorPosition: Point | null;
  cursorHidden: boolean;
  dimAlpha: number;
  deviceSegment: boolean;
  cameraLayout: string;
}

const q = (v: number, s: number) => srounded(v * s) / s;

/** `FrameKey.quantized()` — below visual resolution (1e-6 of the canvas, 1e-4° tilt, 1e-3 pt cursor). */
export function quantizeKey(k: StaticFrameKey): StaticFrameKey {
  return {
    ...k,
    videoSampleSeconds: q(k.videoSampleSeconds, 1e6),
    cameraSampleSeconds: q(k.cameraSampleSeconds, 1e6),
    zoom: q(k.zoom, 1e6),
    focalX: q(k.focalX, 1e6),
    focalY: q(k.focalY, 1e6),
    offsetX: q(k.offsetX, 1e6),
    offsetY: q(k.offsetY, 1e6),
    tiltPitch: q(k.tiltPitch, 1e4),
    tiltYaw: q(k.tiltYaw, 1e4),
    tiltRoll: q(k.tiltRoll, 1e4),
    cursorPosition: k.cursorPosition ? { x: q(k.cursorPosition.x, 1e3), y: q(k.cursorPosition.y, 1e3) } : null,
    dimAlpha: q(k.dimAlpha, 1e4),
  };
}

/** Swift's synthesized `==` (Double `==`: NaN ≠ NaN, -0 == 0). */
export function keysEqual(a: StaticFrameKey | null, b: StaticFrameKey | null): boolean {
  if (!a || !b) return a === b;
  const pa = a.cursorPosition;
  const pb = b.cursorPosition;
  return (
    a.videoSampleSeconds === b.videoSampleSeconds &&
    a.cameraSampleSeconds === b.cameraSampleSeconds &&
    a.zoom === b.zoom &&
    a.focalX === b.focalX &&
    a.focalY === b.focalY &&
    a.offsetX === b.offsetX &&
    a.offsetY === b.offsetY &&
    a.tiltPitch === b.tiltPitch &&
    a.tiltYaw === b.tiltYaw &&
    a.tiltRoll === b.tiltRoll &&
    (pa === null ? pb === null : pb !== null && pa.x === pb.x && pa.y === pb.y) &&
    a.cursorHidden === b.cursorHidden &&
    a.dimAlpha === b.dimAlpha &&
    a.deviceSegment === b.deviceSegment &&
    a.cameraLayout === b.cameraLayout
  );
}

export interface CameraLayoutKeyInput {
  cameraRect: Rect | null;
  cameraOpacity: number;
  chromeOpacity: number;
  cardScale: number;
  cardTranslationX: number;
}

/**
 * `StaticSpanCollapse.cameraLayoutKey` — `String(format: "%.0f,%.0f,%.0f,%.0f,
 * %.3f,%.3f,%.4f,%.1f", rect?.minX ?? -1, …)`. On the Mac a nil rect formats
 * as "nan" (the `?? -1` CGFloat does not survive the variadic), which the
 * golden vectors record — ported as observed.
 */
export function cameraLayoutKey(l: CameraLayoutKeyInput): string {
  const r = l.cameraRect;
  const rect = r
    ? [Math.min(r.x, r.x + r.width), Math.min(r.y, r.y + r.height), Math.abs(r.width), Math.abs(r.height)].map((v) => formatFixed(v, 0))
    : ["nan", "nan", "nan", "nan"];
  return [
    ...rect,
    formatFixed(l.cameraOpacity, 3),
    formatFixed(l.chromeOpacity, 3),
    formatFixed(l.cardScale, 4),
    formatFixed(l.cardTranslationX, 1),
  ].join(",");
}

type SpansProject = Pick<
  Project,
  "cameraLayoutRegions" | "blurRegions" | "focusRegions" | "highlightRegions" | "subtitles" | "annotations"
>;

/** `StaticSpanCollapse.animationHotSpans` — SOURCE-time spans whose renders read the raw clock, sorted by start. */
export function animationHotSpans(
  project: SpansProject,
  transitionDuration: number,
  keystrokeTimes: readonly number[],
  deviceSegmentBoundaries: readonly number[] | null,
): Span[] {
  const spans: Span[] = [];
  for (const r of project.cameraLayoutRegions) {
    const d = cameraLayoutTransition;
    spans.push({ start: r.startTime - 0.1, end: r.startTime + d + 0.1 });
    spans.push({ start: r.endTime - 0.1, end: r.endTime + d + 0.1 });
  }
  for (const r of project.blurRegions) spans.push({ start: r.startTime - 1, end: r.endTime + 1 });
  for (const r of project.focusRegions) spans.push({ start: r.startTime - 1, end: r.endTime + 1 });
  for (const r of project.highlightRegions) {
    spans.push({ start: r.startTime - transitionDuration - 1, end: r.endTime + transitionDuration + 1 });
  }
  for (const s of project.subtitles) spans.push({ start: s.startTime - 0.5, end: s.endTime + 0.5 });
  for (const a of project.annotations) spans.push({ start: a.startTime - 1, end: a.endTime + 1 });
  const pillLife = fadeIn + hold + fadeOut;
  for (const time of keystrokeTimes) spans.push({ start: time - 0.1, end: time + pillLife + 0.1 });
  if (deviceSegmentBoundaries) {
    const dipHalf = deviceDipSigma * 4;
    for (const b of deviceSegmentBoundaries) spans.push({ start: b - dipHalf, end: b + dipHalf });
  }
  return spans.sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
}

/** `StaticSpanCollapse.outputHotSpans` — curtain unveil / intro slide on the OUTPUT clock. */
export function outputHotSpans(
  settings: Pick<
    ProjectSettings,
    "curtainUnveilCorner" | "curtainUnveilStart" | "curtainUnveilDuration" | "introSlideStyle" | "introSlideStart" | "introSlideDuration"
  >,
): Span[] {
  const spans: Span[] = [];
  if (settings.curtainUnveilCorner !== "Off") {
    spans.push({ start: settings.curtainUnveilStart - 0.1, end: settings.curtainUnveilStart + settings.curtainUnveilDuration + 0.1 });
  }
  if (settings.introSlideStyle !== "Off") {
    spans.push({ start: settings.introSlideStart - 0.1, end: settings.introSlideStart + settings.introSlideDuration + 0.1 });
  }
  return spans.sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
}

/** `StaticSpanCollapse.cursorMotionTimestamps` — samples > 0.5 pt from the last kept one, or a press flip. */
export function cursorMotionTimestamps(events: readonly Pick<CursorEvent, "timestamp" | "x" | "y" | "isClick">[]): number[] {
  const out: number[] = [];
  let anchor: Pick<CursorEvent, "x" | "y" | "isClick"> | null = null;
  for (const e of events) {
    if (anchor) {
      if (Math.abs(e.x - anchor.x) > 0.5 || Math.abs(e.y - anchor.y) > 0.5 || e.isClick !== anchor.isClick) {
        out.push(e.timestamp);
        anchor = e;
      }
    } else {
      out.push(e.timestamp);
      anchor = e;
    }
  }
  return out;
}

/** `StaticSpanCollapse.inSpans` — linear scan with early exit over start-sorted spans. */
export function inSpans(spans: readonly Span[], t: number): boolean {
  for (const span of spans) {
    if (span.start > t) return false;
    if (t <= span.end) return true;
  }
  return false;
}

/** The exporter's frame clock: `CMTime(seconds: i / fps + start, preferredTimescale: 600).seconds` (truncates). */
export function exportFrameSeconds(index: number, fps: number, start = 0): number {
  return cmTimeSeconds(index / Math.max(1, Math.trunc(fps)) + start, 600);
}

/** The skip predicate, stepped frame by frame (`StaticSpanCollapse`). */
export class StaticSpanCollapse {
  lastAppendedKey: StaticFrameKey | null = null;
  lastAppendedSeconds = -Number.MAX_VALUE;
  collapsedFrameCount = 0;

  constructor(
    readonly enabled: boolean,
    readonly animationHotSpans: readonly Span[],
    readonly outputHotSpans: readonly Span[],
    readonly cursorTimestamps: readonly number[],
  ) {}

  /** The exporter's collapser for `project` (spans only built when enabled). */
  static forProject(
    enabled: boolean,
    project: SpansProject & { settings: Parameters<typeof outputHotSpans>[0] & Pick<ProjectSettings, "animationSpeed"> },
    keystrokeTimes: readonly number[],
    deviceSegmentBoundaries: readonly number[] | null,
    cursorEvents: readonly CursorEvent[],
  ): StaticSpanCollapse {
    return new StaticSpanCollapse(
      enabled,
      enabled
        ? animationHotSpans(project, animationSpeedDuration(project.settings.animationSpeed), keystrokeTimes, deviceSegmentBoundaries)
        : [],
      enabled ? outputHotSpans(project.settings) : [],
      cursorMotionTimestamps(cursorEvents),
    );
  }

  /** No cursor motion in (t − window, t]. */
  cursorQuiet(t: number): boolean {
    const ts = this.cursorTimestamps;
    if (ts.length === 0) return true;
    let lo = 0;
    let hi = ts.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (ts[mid] <= t - CURSOR_QUIET_WINDOW) lo = mid + 1;
      else hi = mid;
    }
    return lo >= ts.length || ts[lo] > t;
  }

  /** true = skip this frame (the previous sample keeps playing); false = render + append it. */
  shouldSkip(frameIndex: number, frameCount: number, outputSeconds: number, sourceTime: number, key: StaticFrameKey): boolean {
    if (!this.enabled) return false;
    const quantized = quantizeKey(key);
    const skippable =
      frameIndex > 0 &&
      frameIndex < frameCount - 1 &&
      keysEqual(quantized, this.lastAppendedKey) &&
      outputSeconds - this.lastAppendedSeconds < MAX_STATIC_GAP &&
      this.cursorQuiet(sourceTime) &&
      !inSpans(this.animationHotSpans, sourceTime) &&
      !inSpans(this.outputHotSpans, outputSeconds);
    if (skippable) {
      this.collapsedFrameCount++;
      return true;
    }
    this.lastAppendedKey = quantized;
    this.lastAppendedSeconds = outputSeconds;
    return false;
  }
}

/**
 * VFR sample durations for the appended frames: each lasts until the next
 * appended frame; the last until the timeline's end (the Mac pins the
 * session end at `totalSeconds`). Seconds in, seconds out.
 */
export function vfrDurations(appendedSeconds: readonly number[], totalSeconds: number): number[] {
  return appendedSeconds.map((t, i) => (i + 1 < appendedSeconds.length ? appendedSeconds[i + 1] : Math.max(t, totalSeconds)) - t);
}
