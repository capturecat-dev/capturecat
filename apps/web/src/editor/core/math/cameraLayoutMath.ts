/**
 * Port of Services/CameraLayoutMath.swift — dynamic camera layouts (bubble /
 * camera-only / side-by-side / screen-only), interpolated across mode
 * boundaries with a smootherstep morph so a switch reads as a morph, not a
 * cut. Shared by the preview compositor and the exporter (each passes its OWN
 * card rect and bubble rect; the output is consumed identically).
 *
 * Functions: `ease`, `bubbleApproxCornerRadius`, `region(at:regions:)`,
 * `mode(at:regions:)`, `arrangement(at:regions:stacking:)`, `columns(in:side:style:)`,
 * `stackRatio(_:)`, `stackRows(area:ratio:yAxisIsUp:yield:)`, `stackActive(settings:canvas:)`
 * (the vertical stack, docs/camera-cutout.md §12.12), `stackYield(zoom:)`,
 * `outerZoom(_:stacking:)` (the layout owns the zoom while stacking, §12.13),
 * `resolve(...)` (incl. the private `target(_:...)` and `lerp` helpers,
 * exercised through `resolve`),
 * `cardTransform(_:videoRect:)`, `boundaries(_:duration:)`,
 * `look(at:regions:defaultLook:stacking:)`, `lookWeights(…)` (docs/camera-cutout.md §4);
 * constants `transitionDuration`, `sideBySideScreenFraction`,
 * `sideBySideGapFraction`, `stackDefaultRatio`, `stackRatioRange`, `stackGapFraction`.
 *
 * Locked by the golden-vector units `cameraLayoutMathBasics`,
 * `cameraLayoutResolve`, `cameraLayoutBoundaries`, `cameraLookWeights` and
 * `styleConstants`.
 *
 * Space: the card squeeze is a UNIFORM scale plus an X translation about the
 * card centre, so the same numbers are valid in Y-down (preview/web) and Y-up
 * (CoreImage) space. The vertical stack adds a Y translation computed from
 * rows in the CALLER's space (`stackRows(…, yAxisIsUp:)`), so it is right in
 * either convention too. The camera pass computes in the exporter's Y-up
 * space and flips.
 *
 * Faithful-port notes:
 * - `boundaries` returns only the filtered, sorted region edges; its Swift doc
 *   mentions "plus the tail of each morph" but the code adds no tails.
 * - `lerp(CGRect)` interpolates `minX`/`minY`/`width`/`height` (standardized
 *   accessors), so a negative-size rect is normalized by the morph.
 */
import type { CameraLayoutRegion, ProjectSettings, Rect, Size } from "../model/types";
import type { CameraLayoutMode, CameraLook, CameraShape, CameraSide, CameraSplitStyle } from "../model/enums";
import {
  type AffineTransform,
  identityTransform,
  maxX,
  maxY,
  midX,
  midY,
  minX,
  minY,
  rectApplying,
  rectHeight,
  rectWidth,
  scaledBy,
  translatedBy,
} from "./geometry";
import { envelope, sizeFactor } from "./reactiveCameraLayout";
import { smax, smin } from "./swift";

/** Morph length at every mode boundary (seconds). */
export const transitionDuration = 0.45;
/** Side-by-side: the screen keeps 60% of the card width. */
export const sideBySideScreenFraction = 0.6;
/** Side-by-side gutter as a fraction of the card width. */
export const sideBySideGapFraction = 0.03;

/** Smootherstep 6t⁵−15t⁴+10t³ on a clamped t. */
export function ease(t: number): number {
  const x = smin(1, smax(0, t));
  return x * x * x * (x * (x * 6 - 15) + 10);
}

/** `CameraLayoutMath.Resolved` */
export interface CameraLayoutResolved {
  /** null = the project has no camera at all. */
  cameraRect: Rect | null;
  cameraCornerRadius: number;
  cameraOpacity: number;
  chromeOpacity: number;
  cardScale: number;
  cardTranslationX: number;
  /** Card translation along Y, caller's space — non-zero only for the vertical
   *  stack (§12.12), which moves the card into its row. */
  cardTranslationY: number;
  /** Full-height split (docs/camera-cutout.md §12.11): the card is clipped to
   *  this rounded rect (caller's space, like videoRect) at the card seam,
   *  riders included. null = no clip — every arrangement but a full split
   *  and its morphs. */
  cardClip: Rect | null;
  cardClipCornerRadius: number;
  /** The rounded-rect SHAPE each tile's corners come from when it differs from
   *  the visible rect (§12.14): a joined stack runs each row's shape past the
   *  seam by its radius, so the mask (shape cropped to the rect) is square
   *  there. Absent / null = the rect. */
  cameraShapeRect?: Rect | null;
  cardClipShapeRect?: Rect | null;
  /** How much the stack's rows are joined (§12.14), 0…1, eased through morphs:
   *  the camera tile's card shadow fades by 1 − seamJoin. */
  seamJoin: number;
  isPlainBubble: boolean;
}

/** `bubbleApproxCornerRadius(shape:customRadius:size:)` (customRadius pre-scaled). */
export function bubbleApproxCornerRadius(shape: CameraShape, customRadius: number, size: Size): number {
  const short = smin(size.width, size.height);
  switch (shape) {
    case "Circle":
      return short / 2;
    case "Square":
      return 0;
    case "Rounded Rectangle":
      return smin(smax(0, customRadius), short / 2);
    case "Squircle":
      return short * 0.25;
  }
}

/** `region(at:regions:)` — the FIRST region containing t (closed interval). */
export function region(t: number, regions: readonly CameraLayoutRegion[]): CameraLayoutRegion | null {
  for (const r of regions) if (t >= r.startTime && t <= r.endTime) return r;
  return null;
}

/** `mode(at:regions:)` — `.bubble` outside every region. */
export function mode(t: number, regions: readonly CameraLayoutRegion[]): CameraLayoutMode {
  return region(t, regions)?.mode ?? "bubble";
}

/**
 * `Arrangement` (docs/camera-cutout.md §12.6) — what a morph compares: the
 * mode, plus the camera side while it is Side by Side (trailing otherwise),
 * so adjacent splits on opposite sides morph (the camera slides across).
 */
export interface CameraArrangement {
  mode: CameraLayoutMode;
  side: CameraSide;
  /** §12.11: tiles or the full-height split (tiles off sideBySide). */
  split: CameraSplitStyle;
  /** §12.12: the vertical stack — the default arrangement while active. */
  stacked: boolean;
}

/**
 * `arrangement(at:regions:stacking:)` — bubble / trailing / tiles outside
 * every region (stacked while the vertical stack is active); a Side by Side
 * region is stacked too while it is active; Bubble, Camera Only and Screen
 * Only regions are unchanged.
 */
export function arrangement(t: number, regions: readonly CameraLayoutRegion[], stacking = false): CameraArrangement {
  const r = region(t, regions);
  if (!r) return { mode: "bubble", side: "trailing", split: "tiles", stacked: stacking };
  if (r.mode !== "sideBySide") return { mode: r.mode, side: "trailing", split: "tiles", stacked: false };
  if (stacking) return { mode: r.mode, side: "trailing", split: "tiles", stacked: true };
  // `effectiveSide` / `effectiveSplitStyle`; anything but "leading" / "full"
  // reads as the default, like the lenient decode.
  return {
    mode: r.mode,
    side: r.cameraSide === "leading" ? "leading" : "trailing",
    split: r.splitStyle === "full" ? "full" : "tiles",
    stacked: false,
  };
}

function sameArrangement(a: CameraArrangement, b: CameraArrangement): boolean {
  return a.mode === b.mode && a.side === b.side && a.split === b.split && a.stacked === b.stacked;
}

// ── Vertical stack (docs/camera-cutout.md §12.12) ───────────────────────────

/** `StackRows` — the two rows of the vertical stack, in the caller's space. */
export interface CameraStackRows {
  camera: Rect;
  screen: Rect;
}

export const stackDefaultRatio = 0.42;
export const stackRatioRange = { lowerBound: 0.25, upperBound: 0.7 } as const;
export const stackGapFraction = 0.02;
export const stackGapRange = { lowerBound: 0, upperBound: 0.08 } as const;

/** `stackGap(_:)` — the rows' gap as a share of the stack height (§12.14),
 *  clamped to 0…0.08, absent = 0.02. 0 joins the rows into one card. */
export function stackGap(stored: number | null | undefined): number {
  return smin(stackGapRange.upperBound, smax(stackGapRange.lowerBound, stored ?? stackGapFraction));
}

/** `stackRatio(_:)` — the camera row's share, clamped to 0.25…0.7 (absent = 0.42). */
export function stackRatio(stored: number | null | undefined): number {
  return smin(stackRatioRange.upperBound, smax(stackRatioRange.lowerBound, stored ?? stackDefaultRatio));
}

/** `stackRows(area:ratio:yAxisIsUp:yield:)` — camera row on TOP, screen row below,
 *  inside `area` (the content rect: the canvas inside the frame padding).
 *  `cameraYield` (Swift `yield`, §12.13 `stackYield`) shrinks the camera
 *  row's height while the screen zooms; the screen row takes what it gives up. */
export function stackRows(
  area: Rect,
  ratio: number,
  yAxisIsUp: boolean,
  cameraYield = 1,
  storedGap: number | null | undefined = null,
): CameraStackRows {
  const gap = rectHeight(area) * stackGap(storedGap);
  const h = (rectHeight(area) - gap) * stackRatio(ratio) * cameraYield;
  const screenH = rectHeight(area) - h - gap;
  if (yAxisIsUp) {
    return {
      camera: { x: minX(area), y: maxY(area) - h, width: rectWidth(area), height: h },
      screen: { x: minX(area), y: minY(area), width: rectWidth(area), height: screenH },
    };
  }
  return {
    camera: { x: minX(area), y: minY(area), width: rectWidth(area), height: h },
    screen: { x: minX(area), y: minY(area) + h + gap, width: rectWidth(area), height: screenH },
  };
}

/** `stackActive(settings:canvas:)` — switched on and the OUTPUT canvas is
 *  portrait. The caller also needs a camera to show. */
export function stackActive(settings: Pick<ProjectSettings, "cameraPortraitStack">, canvas: Size): boolean {
  return (settings.cameraPortraitStack ?? false) && canvas.height > canvas.width;
}

// ── Zoom inside the vertical stack (docs/camera-cutout.md §12.13) ───────────

/** `StackZoom` — the screen's view while stacked: the smoothed zoom and its
 *  focal point (0…1 of the video rect, Y-down), the values the card zoom uses. */
export interface CameraStackZoom {
  zoom: number;
  focalX: number;
  focalY: number;
}

export const stackNoZoom: CameraStackZoom = { zoom: 1, focalX: 0.5, focalY: 0.5 };

/** `stackYield(zoom:)` — how much of its height the camera row keeps at
 *  `zoom` (pass `layoutZoom`, so Shrink During Zoom off keeps it): the
 *  bubble's own shrink, so the seam glides up on the same curve. */
export function stackYield(zoom: number): number {
  return sizeFactor(zoom);
}

/** `outerZoom(_:stacking:)` — the zoom the card stage AFTER the layout
 *  applies. While the stack is on, every zoom-in happens inside the layout
 *  (`resolve`: inside the row when stacked, about the focal on the card in a
 *  Bubble / Camera Only / Screen Only block), so the camera tile never rides a
 *  zoom; a scale-down stays here. Feeds the cover zoom, the background
 *  parallax and both motion blur samples. */
export function outerZoom(zoom: number, stacking: boolean): number {
  return stacking && zoom > 1 ? 1 : zoom;
}

/** `columns(in:side:style:)` — side-by-side tiles: trailing (default) =
 *  screen leading, camera trailing; leading mirrors the row (camera first).
 *  `style` full (§12.11) runs both tiles the card's full height. */
export function columns(videoRect: Rect, side: CameraSide = "trailing", style: CameraSplitStyle = "tiles"): { screen: Rect; camera: Rect } {
  const gap = rectWidth(videoRect) * sideBySideGapFraction;
  const screenWidth = rectWidth(videoRect) * sideBySideScreenFraction;
  const cameraWidth = rectWidth(videoRect) - screenWidth - gap;
  const tileHeight = style === "full" ? rectHeight(videoRect) : rectHeight(videoRect) * sideBySideScreenFraction;
  const tileY = style === "full" ? minY(videoRect) : midY(videoRect) - tileHeight / 2;
  if (side === "leading") {
    return {
      screen: { x: maxX(videoRect) - screenWidth, y: tileY, width: screenWidth, height: tileHeight },
      camera: { x: minX(videoRect), y: tileY, width: cameraWidth, height: tileHeight },
    };
  }
  return {
    screen: { x: minX(videoRect), y: tileY, width: screenWidth, height: tileHeight },
    camera: { x: maxX(videoRect) - cameraWidth, y: tileY, width: cameraWidth, height: tileHeight },
  };
}

/** private `target(_:videoRect:bubbleRect:bubbleCornerRadius:cardCornerRadius:stack:stackZoom:)` */
function target(
  a: CameraArrangement,
  videoRect: Rect,
  bubbleRect: Rect,
  bubbleCornerRadius: number,
  cardCornerRadius: number,
  stack: CameraStackRows | null,
  stackZoom: CameraStackZoom,
): CameraLayoutResolved {
  if (!a.stacked && stack && stackZoom.zoom > 1) {
    // §12.13, the other arrangements while the stack is on: the plain zoom
    // about the focal on the card, folded into the card transform.
    const r = target(a, videoRect, bubbleRect, bubbleCornerRadius, cardCornerRadius, null, stackNoZoom);
    const z = stackZoom.zoom;
    const yUp = midY(stack.camera) > midY(stack.screen);
    const cx = midX(videoRect);
    const cy = midY(videoRect);
    const ax = minX(videoRect) + stackZoom.focalX * rectWidth(videoRect);
    const ay = yUp ? maxY(videoRect) - stackZoom.focalY * rectHeight(videoRect) : minY(videoRect) + stackZoom.focalY * rectHeight(videoRect);
    // p ↦ a + z·(T(p) − a), T = the arrangement's own card transform.
    return {
      ...r,
      cardTranslationX: ax + z * (cx + r.cardTranslationX - ax) - cx,
      cardTranslationY: ay + z * (cy + r.cardTranslationY - ay) - cy,
      cardScale: r.cardScale * z,
    };
  }
  if (a.stacked && stack) {
    // The card aspect-fills the screen row and is clipped to it; the camera
    // fills the row above.
    const row = stack.screen;
    const fill =
      rectWidth(videoRect) > 0 && rectHeight(videoRect) > 0
        ? smax(rectWidth(row) / rectWidth(videoRect), rectHeight(row) / rectHeight(videoRect))
        : 1;
    // §12.13: the screen zooms INSIDE its row; the focal point P (on the
    // filled card) eases toward the same fraction of the row (Qd) as the zoom
    // grows. The rows' order tells the caller's Y convention.
    const z = smax(1, stackZoom.zoom);
    const fx = smin(1, smax(0, stackZoom.focalX));
    const fy = smin(1, smax(0, stackZoom.focalY));
    const yUp = midY(stack.camera) > midY(row);
    const cx = midX(videoRect);
    const cy = midY(videoRect);
    const focalX = minX(videoRect) + fx * rectWidth(videoRect);
    const focalY = yUp ? maxY(videoRect) - fy * rectHeight(videoRect) : minY(videoRect) + fy * rectHeight(videoRect);
    const px = midX(row) + fill * (focalX - cx);
    const py = midY(row) + fill * (focalY - cy);
    const qdx = minX(row) + fx * rectWidth(row);
    const qdy = yUp ? maxY(row) - fy * rectHeight(row) : minY(row) + fy * rectHeight(row);
    const e = envelope(z);
    const qx = px + (qdx - px) * e;
    const qy = py + (qdy - py) * e;
    // At rest exactly the plain fill (no rounding drift).
    const zoomed = z > 1;
    // §12.14: rows that touch (Gap 0) join into one card — each row's rounded
    // shape runs past the seam by the radius, square there once cropped.
    const seam = yUp ? minY(stack.camera) - maxY(row) : minY(row) - maxY(stack.camera);
    const joined = seam <= 1e-6 * smax(1, rectHeight(stack.camera) + rectHeight(row));
    const reach = joined ? smax(0, cardCornerRadius) : 0;
    return {
      cameraRect: stack.camera,
      cameraCornerRadius: cardCornerRadius,
      cameraOpacity: 1,
      chromeOpacity: 0,
      cardScale: fill * z,
      cardTranslationX: zoomed ? qx + z * (midX(row) - px) - cx : midX(row) - cx,
      cardTranslationY: zoomed ? qy + z * (midY(row) - py) - cy : midY(row) - cy,
      cardClip: row,
      cardClipCornerRadius: cardCornerRadius,
      cameraShapeRect:
        reach > 0
          ? {
              x: minX(stack.camera),
              y: yUp ? minY(stack.camera) - reach : minY(stack.camera),
              width: rectWidth(stack.camera),
              height: rectHeight(stack.camera) + reach,
            }
          : null,
      cardClipShapeRect:
        reach > 0
          ? { x: minX(row), y: yUp ? minY(row) : minY(row) - reach, width: rectWidth(row), height: rectHeight(row) + reach }
          : null,
      seamJoin: joined ? 1 : 0,
      isPlainBubble: false,
    };
  }
  switch (a.mode) {
    case "bubble":
      return {
        cameraRect: bubbleRect,
        cameraCornerRadius: bubbleCornerRadius,
        cameraOpacity: 1,
        chromeOpacity: 1,
        cardScale: 1,
        cardTranslationX: 0,
        cardTranslationY: 0,
        cardClip: null,
        cardClipCornerRadius: 0,
        seamJoin: 0,
        isPlainBubble: true,
      };
    case "cameraOnly":
      return {
        cameraRect: videoRect,
        cameraCornerRadius: cardCornerRadius,
        cameraOpacity: 1,
        chromeOpacity: 0,
        cardScale: 1,
        cardTranslationX: 0,
        cardTranslationY: 0,
        cardClip: null,
        cardClipCornerRadius: 0,
        seamJoin: 0,
        isPlainBubble: false,
      };
    case "sideBySide": {
      if (a.split === "full") {
        // Full-height split (§12.11): the card keeps its size and slides so
        // the screen's centre sits in its column, clipped to it; the camera
        // fills the other full-height column.
        const cols = columns(videoRect, a.side, "full");
        return {
          cameraRect: cols.camera,
          cameraCornerRadius: cardCornerRadius,
          cameraOpacity: 1,
          chromeOpacity: 0,
          cardScale: 1,
          cardTranslationX: midX(cols.screen) - midX(videoRect),
          cardTranslationY: 0,
          cardClip: cols.screen,
          cardClipCornerRadius: cardCornerRadius,
          seamJoin: 0,
          isPlainBubble: false,
        };
      }
      const cols = columns(videoRect, a.side);
      const scale = rectWidth(videoRect) > 0 ? rectWidth(cols.screen) / rectWidth(videoRect) : 1;
      return {
        cameraRect: cols.camera,
        cameraCornerRadius: cardCornerRadius,
        cameraOpacity: 1,
        chromeOpacity: 0,
        cardScale: scale,
        cardTranslationX: midX(cols.screen) - midX(videoRect),
        cardTranslationY: 0,
        cardClip: null,
        cardClipCornerRadius: 0,
        seamJoin: 0,
        isPlainBubble: false,
      };
    }
    case "screenOnly":
      return {
        cameraRect: bubbleRect,
        cameraCornerRadius: bubbleCornerRadius,
        cameraOpacity: 0,
        chromeOpacity: 0,
        cardScale: 1,
        cardTranslationX: 0,
        cardTranslationY: 0,
        cardClip: null,
        cardClipCornerRadius: 0,
        seamJoin: 0,
        isPlainBubble: false,
      };
  }
}

function lerp(a: number, b: number, p: number): number {
  return a + (b - a) * p;
}

function lerpRect(a: Rect, b: Rect, p: number): Rect {
  return {
    x: lerp(minX(a), minX(b), p),
    y: lerp(minY(a), minY(b), p),
    width: lerp(rectWidth(a), rectWidth(b), p),
    height: lerp(rectHeight(a), rectHeight(b), p),
  };
}

/**
 * `resolve(at:regions:videoRect:bubbleRect:bubbleCornerRadius:cardCornerRadius:hasCamera:stack:stackZoom:)`.
 * A pure function of timeline position (never a wall clock). `stack` = the
 * vertical stack's rows (caller space) while it is active, else null.
 */
export function resolve(
  t: number,
  regions: readonly CameraLayoutRegion[],
  videoRect: Rect,
  bubbleRect: Rect,
  bubbleCornerRadius: number,
  cardCornerRadius: number,
  hasCamera: boolean,
  stack: CameraStackRows | null = null,
  stackZoom: CameraStackZoom = stackNoZoom,
): CameraLayoutResolved {
  if (!hasCamera) {
    return {
      cameraRect: null,
      cameraCornerRadius: 0,
      cameraOpacity: 0,
      chromeOpacity: 0,
      cardScale: 1,
      cardTranslationX: 0,
      cardTranslationY: 0,
      cardClip: null,
      cardClipCornerRadius: 0,
      seamJoin: 0,
      isPlainBubble: false,
    };
  }
  const stacking = stack !== null;
  if (regions.length === 0) {
    return target({ mode: "bubble", side: "trailing", split: "tiles", stacked: stacking }, videoRect, bubbleRect, bubbleCornerRadius, cardCornerRadius, stack, stackZoom);
  }

  const current = arrangement(t, regions, stacking);
  const settled = target(current, videoRect, bubbleRect, bubbleCornerRadius, cardCornerRadius, stack, stackZoom);

  const edges = regions.flatMap((r) => [r.startTime, r.endTime]).sort((a, b) => a - b);
  let boundary: number | undefined;
  for (let i = edges.length - 1; i >= 0; i--) {
    if (edges[i] <= t) {
      boundary = edges[i];
      break;
    }
  }
  if (boundary === undefined || !(boundary > 0.05) || !(t - boundary < transitionDuration)) {
    return settled;
  }

  // The ARRANGEMENT just before the edge (§12.6: a side change morphs too).
  const previous = arrangement(boundary - 0.001, regions, stacking);
  if (sameArrangement(previous, current)) return settled;

  const from = target(previous, videoRect, bubbleRect, bubbleCornerRadius, cardCornerRadius, stack, stackZoom);
  const p = ease((t - boundary) / transitionDuration);

  // The clip (§12.11) only exists when an end has one; the other end stands
  // in as its whole transformed card, so the clip opens from / closes onto
  // the card's own outline (radius cardCornerRadius × its cardScale).
  let cardClip: Rect | null = null;
  let cardClipCornerRadius = 0;
  let cardClipShapeRect: Rect | null = null;
  if (from.cardClip !== null || settled.cardClip !== null) {
    const outline = (r: CameraLayoutResolved): [Rect, number] =>
      r.cardClip !== null
        ? [r.cardClip, r.cardClipCornerRadius]
        : [rectApplying(videoRect, cardTransform(r, videoRect)), cardCornerRadius * r.cardScale];
    const a = outline(from);
    const b = outline(settled);
    cardClip = lerpRect(a[0], b[0], p);
    cardClipCornerRadius = lerp(a[1], b[1], p);
    // A joined end's shape (§12.14) eases to the other end's outline.
    if (from.cardClipShapeRect || settled.cardClipShapeRect) {
      cardClipShapeRect = lerpRect(from.cardClipShapeRect ?? a[0], settled.cardClipShapeRect ?? b[0], p);
    }
  }
  const fromCamera = from.cameraRect ?? bubbleRect;
  const toCamera = settled.cameraRect ?? bubbleRect;
  const cameraShapeRect =
    from.cameraShapeRect || settled.cameraShapeRect
      ? lerpRect(from.cameraShapeRect ?? fromCamera, settled.cameraShapeRect ?? toCamera, p)
      : null;

  return {
    cameraRect: lerpRect(fromCamera, toCamera, p),
    cameraCornerRadius: lerp(from.cameraCornerRadius, settled.cameraCornerRadius, p),
    cameraOpacity: lerp(from.cameraOpacity, settled.cameraOpacity, p),
    chromeOpacity: lerp(from.chromeOpacity, settled.chromeOpacity, p),
    cardScale: lerp(from.cardScale, settled.cardScale, p),
    cardTranslationX: lerp(from.cardTranslationX, settled.cardTranslationX, p),
    cardTranslationY: lerp(from.cardTranslationY, settled.cardTranslationY, p),
    cardClip,
    cardClipCornerRadius,
    cameraShapeRect,
    cardClipShapeRect,
    seamJoin: lerp(from.seamJoin, settled.seamJoin, p),
    // Mid-morph is never the plain bubble, even when both ends are.
    isPlainBubble: false,
  };
}

/** `cardTransform(_:videoRect:)` — uniform scale + (tx, ty) translation about the card centre
 *  (ty: the vertical stack only, §12.12). */
export function cardTransform(
  resolved: Pick<CameraLayoutResolved, "cardScale" | "cardTranslationX"> & { cardTranslationY?: number },
  videoRect: Rect,
): AffineTransform {
  const ty = resolved.cardTranslationY ?? 0;
  if (!(resolved.cardScale !== 1 || resolved.cardTranslationX !== 0 || ty !== 0)) return identityTransform;
  const c = { x: midX(videoRect), y: midY(videoRect) };
  let t = translatedBy(identityTransform, c.x + resolved.cardTranslationX, c.y + ty);
  t = scaledBy(t, resolved.cardScale, resolved.cardScale);
  t = translatedBy(t, -c.x, -c.y);
  return t;
}

/** `boundaries(_:duration:)` — region edges strictly inside (0.05, duration − 0.05), sorted. */
export function boundaries(regions: readonly CameraLayoutRegion[], duration: number): number[] {
  return regions
    .flatMap((r) => [r.startTime, r.endTime])
    .filter((e) => e > 0.05 && e < duration - 0.05)
    .sort((a, b) => a - b);
}

// ── Camera looks (docs/camera-cutout.md §4) ─────────────────────────────────

/** `look(at:regions:defaultLook:stacking:)` (docs/camera-cutout.md §1a) —
 *  inside a region, its `look` while its mode is `bubble` (the default look
 *  when it sets none) and null on any other mode; outside every region, the
 *  default look (`settings.cameraLook`, the Camera pane's whole-video
 *  Background). While the vertical stack is active (§12.12) its camera row
 *  wears the default look too — outside regions and on a Side by Side region,
 *  which stacks. */
export function look(
  t: number,
  regions: readonly CameraLayoutRegion[],
  defaultLook: CameraLook | null | undefined,
  stacking = false,
): CameraLook | null {
  const r = region(t, regions);
  if (!r) return defaultLook ?? null;
  if (r.mode === "bubble") return r.look ?? defaultLook ?? null;
  return r.mode === "sideBySide" && stacking ? (defaultLook ?? null) : null;
}

/** `LookWeights` — each 0…1, summing to ≤ 1. */
export interface CameraLookWeights {
  cutout: number;
  popOut: number;
}

function lookTarget(l: CameraLook | null): CameraLookWeights {
  return { cutout: l === "cutout" ? 1 : 0, popOut: l === "popOut" ? 1 : 0 };
}

/**
 * `lookWeights(at:regions:defaultLook:)` — how much of each look draws at t,
 * eased across region edges exactly like `resolve` morphs modes: the last
 * edge ≤ t, no morph when that edge is ≤ 0.05 s (no intro morph at t = 0, so
 * a whole-video default look is settled from frame one) or more than
 * `transitionDuration` ago; otherwise smootherstep from the look just before
 * the edge (`look(at: edge − 0.001)`) to the look at t.
 */
export function lookWeights(
  t: number,
  regions: readonly CameraLayoutRegion[],
  defaultLook: CameraLook | null | undefined,
  /** §12.12: the vertical stack is active (a Side by Side region stacks and
   *  wears the default look). */
  stacking = false,
): CameraLookWeights {
  if (regions.length === 0) return lookTarget(defaultLook ?? null);
  const current = look(t, regions, defaultLook, stacking);
  const settled = lookTarget(current);

  const edges = regions.flatMap((r) => [r.startTime, r.endTime]).sort((a, b) => a - b);
  let boundary: number | undefined;
  for (let i = edges.length - 1; i >= 0; i--) {
    if (edges[i] <= t) {
      boundary = edges[i];
      break;
    }
  }
  if (boundary === undefined || !(boundary > 0.05) || !(t - boundary < transitionDuration)) {
    return settled;
  }

  const previous = look(boundary - 0.001, regions, defaultLook, stacking);
  if (previous === current) return settled;

  const from = lookTarget(previous);
  const p = ease((t - boundary) / transitionDuration);
  return {
    cutout: lerp(from.cutout, settled.cutout, p),
    popOut: lerp(from.popOut, settled.popOut, p),
  };
}
