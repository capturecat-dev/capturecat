/**
 * Port of apps/macos/CaptureCat/Services/DeviceSegmentDip.swift (the Keynote
 * dip across a device-segment cut: a Gaussian in TIMELINE seconds, centred on
 * each boundary) PLUS the exporter's device-segment rules for stitched
 * multi-source takes (VideoExporter.export, commit da569841: deviceFrameActive
 * 743, segmentDeviceAssets 929-981, deviceSegmentActive / deviceBoundaryDip
 * 1018-1027, dip hot spans 1296-1300, the per-frame dip transform + fade
 * 2013-2027 / fadeImage 3181-3189, the curtain device-screen rect 1871-1886).
 *
 * Golden-vector units: `deviceSegmentDip` (real Swift), `deviceSegmentExport`
 * (verbatim oracle), `regionConstants`.
 *
 * ## How the exporter frames device segments (for the renderer)
 * Only when the whole project is NOT a framed device take
 * (`deviceFrameActive` false) and `settings.showDeviceFrame` is on, and at
 * least one `sourceSegments[i].kind == "device"` exists:
 * - `subRect` (CI Y-UP, output px) = the FIRST device segment's
 *   `normalizedContentRect` (top-left origin, 0…1 of the stitched frame)
 *   mapped into `layout.videoRect`. ALL device segments reuse that one rect.
 * - While `deviceSegmentActive(t)` (t within [start − 0.01, end + 0.01] of any
 *   device segment, SOURCE seconds): the video layer is clipped by a
 *   continuous-corner (squircle) mask of `subRect` with radius
 *   `screenCornerRadius(subRect.size)`; the card base is replaced by the
 *   bezel for `subRect` (buttons + body, see deviceBezel.ts) over its own
 *   drop shadow (`makeFrameShadow` over `bezelRect(subRect)` with
 *   `bezelCornerRadius(subRect.size)`, squircle, settings shadow radius ×
 *   canvasScale / opacity) — the full-rect card shadow is dropped; the tilted
 *   side slab (videoWidth = subRect.width) sits between; the island layer
 *   (phone aspect only) goes above the video; the replacement menu bar is
 *   hidden.
 * - The dip: `phase(t, boundaries = every device segment's start and end)`;
 *   when phase > 0.01 the composited CARD is scaled by `scale(phase)` about
 *   the (static) video rect's centre and faded to `opacity(phase)` (clamped
 *   0…1; CIColorMatrix multiplies all four premultiplied channels).
 */
import type { RecordingSourceKind } from "../model/enums";
import type { ProjectSourceSegment, Rect } from "../model/types";
import {
  type AffineTransform,
  identityTransform,
  maxY,
  midX,
  midY,
  minX,
  minY,
  rectHeight,
  rectWidth,
  scaledBy,
  translatedBy,
} from "./geometry";
import { bezelCornerRadius, bezelRect, isPhoneAspect, screenCornerRadius } from "./deviceFrameLayout";
import { smax, smin } from "./swift";

/** Half-width of the dip, in timeline seconds. */
export const sigma = 0.15;
/** How much of the card's scale is given up at full dip. */
export const scaleDrop = 0.05;
/** How much of the card's opacity is given up at full dip. */
export const opacityDrop = 0.55;

/** 0 = undipped, 1 = fully dipped. */
export function phase(time: number, boundaries: readonly number[]): number {
  let g = 0.0;
  for (const boundary of boundaries) {
    const d = (time - boundary) / sigma;
    g = smax(g, Math.exp(-d * d));
  }
  return smin(1, g);
}

export function scale(p: number): number {
  return 1 - scaleDrop * p;
}

export function opacity(p: number): number {
  return 1 - opacityDrop * p;
}

// ── Exporter device-segment rules ──────────────────────────────────────────

/** `ProjectSourceSegment.endTime`. */
export function sourceSegmentEndTime(s: Pick<ProjectSourceSegment, "startTime" | "duration">): number {
  return s.startTime + s.duration;
}

/** `ProjectSourceSegment.normalizedContentRect` (top-left origin, 0…1). */
export function normalizedContentRect(s: ProjectSourceSegment): Rect {
  return { x: s.contentX, y: s.contentY, width: s.contentWidth, height: s.contentHeight };
}

/** VideoExporter 743: the whole take is a framed device recording. */
export function deviceFrameActive(recordingSourceKind: RecordingSourceKind, showDeviceFrame: boolean): boolean {
  return recordingSourceKind === "device" && showDeviceFrame;
}

/** The numbers of `SegmentDeviceAssets` (VideoExporter 916-981). */
export interface SegmentDeviceAssets {
  /** Phone content rect in the exporter's CI Y-UP output space. */
  subRect: Rect;
  screenCornerRadius: number;
  /** The bezel's own drop-shadow rect / radius (squircle). */
  bezelShadowRect: Rect;
  bezelShadowCornerRadius: number;
  /** `makeDeviceIslandImage` is non-nil only for phone-aspect content. */
  hasIsland: boolean;
  /** Device segments' (start, end) in SOURCE seconds. */
  ranges: { start: number; end: number }[];
  /** `tiltedSide(side, videoWidth: subRect.width)`. */
  sideVideoWidth: number;
}

/**
 * `segmentDeviceAssets` minus the CIImage builds (VideoExporter 929-981).
 * `videoRect` is `staticLayout.videoRect` in CI Y-UP output pixels. (The
 * Swift also returns nil if the mask/bezel CGContexts cannot be created — a
 * zero-size canvas — which never happens for a real export.)
 */
export function segmentDeviceAssets(
  recordingSourceKind: RecordingSourceKind,
  showDeviceFrame: boolean,
  sourceSegments: readonly ProjectSourceSegment[],
  videoRect: Rect,
): SegmentDeviceAssets | null {
  if (!(!deviceFrameActive(recordingSourceKind, showDeviceFrame) && showDeviceFrame)) return null;
  const deviceSegments = sourceSegments.filter((s) => s.kind === "device");
  const first = deviceSegments[0];
  if (!first) return null;
  const normalized = normalizedContentRect(first);
  const vr = videoRect;
  // Normalized top-left origin → CI y-up space
  const subRect: Rect = {
    x: minX(vr) + minX(normalized) * rectWidth(vr),
    y: minY(vr) + (1 - minY(normalized) - rectHeight(normalized)) * rectHeight(vr),
    width: rectWidth(normalized) * rectWidth(vr),
    height: rectHeight(normalized) * rectHeight(vr),
  };
  const size = { width: subRect.width, height: subRect.height };
  return {
    subRect,
    screenCornerRadius: screenCornerRadius(size),
    bezelShadowRect: bezelRect(subRect),
    bezelShadowCornerRadius: bezelCornerRadius(size),
    hasIsland: isPhoneAspect(size),
    ranges: deviceSegments.map((s) => ({ start: s.startTime, end: sourceSegmentEndTime(s) })),
    sideVideoWidth: rectWidth(subRect),
  };
}

/** `deviceSegmentActive(_:)` — any device range, ±0.01 s. */
export function deviceSegmentActive(assets: SegmentDeviceAssets | null, time: number): boolean {
  return assets ? assets.ranges.some((r) => time >= r.start - 0.01 && time <= r.end + 0.01) : false;
}

/** `deviceBoundaryDip(_:)` — the dip phase over every device boundary. */
export function deviceBoundaryDip(assets: SegmentDeviceAssets | null, time: number): number {
  if (!assets) return 0;
  return phase(
    time,
    assets.ranges.flatMap((r) => [r.start, r.end]),
  );
}

/** Static-collapse hot spans for the dips (VideoExporter 1296-1300), unsorted. */
export function deviceDipHotSpans(assets: SegmentDeviceAssets | null): { start: number; end: number }[] {
  if (!assets) return [];
  const dipHalf = sigma * 4;
  return assets.ranges.flatMap((r) => [r.start, r.end]).map((b) => ({ start: b - dipHalf, end: b + dipHalf }));
}

/**
 * The per-frame dip applied to the whole card (VideoExporter 2015-2026):
 * null when phase ≤ 0.01; otherwise the CI transform
 * `identity.translatedBy(c).scaledBy(s, s).translatedBy(-c)` about the static
 * video rect's centre (CI Y-UP; the same matrix in Y-down about the flipped
 * centre) and the fade alpha (`fadeImage` clamp).
 */
export function deviceDipTransform(
  dipPhase: number,
  videoRect: Rect,
): { scale: number; transform: AffineTransform; alpha: number } | null {
  if (!(dipPhase > 0.01)) return null;
  const s = scale(dipPhase);
  const c = { x: midX(videoRect), y: midY(videoRect) };
  let t = translatedBy(identityTransform, c.x, c.y);
  t = scaledBy(t, s, s);
  t = translatedBy(t, -c.x, -c.y);
  const alpha = opacity(dipPhase);
  return { scale: s, transform: t, alpha: smin(1, smax(0, alpha)) };
}

/**
 * The device screen the curtain overlay is clipped to (VideoExporter
 * 1871-1886), in the card's Y-DOWN local space (origin = video rect's
 * top-left): the active segment's subRect, else the whole card for a framed
 * device take, else null.
 */
export function curtainDeviceScreen(
  assets: SegmentDeviceAssets | null,
  active: boolean,
  isDeviceFrameActive: boolean,
  videoRect: Rect,
): { rect: Rect; cornerRadius: number } | null {
  if (assets && active) {
    const sub = assets.subRect;
    return {
      rect: { x: minX(sub) - minX(videoRect), y: maxY(videoRect) - maxY(sub), width: rectWidth(sub), height: rectHeight(sub) },
      cornerRadius: screenCornerRadius({ width: sub.width, height: sub.height }),
    };
  }
  if (isDeviceFrameActive) {
    const size = { width: videoRect.width, height: videoRect.height };
    return { rect: { x: 0, y: 0, width: size.width, height: size.height }, cornerRadius: screenCornerRadius(size) };
  }
  return null;
}
