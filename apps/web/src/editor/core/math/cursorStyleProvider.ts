/**
 * Port of Services/CursorStyleProvider.swift — the cursor artwork every
 * renderer uses: per-style point size + hotspot (`asset(for:)`), the raster
 * pixel grid (`rasterizedCGImage(for:pixelSize:)`), and the vector geometry of
 * the drawn styles (private `drawnArrow` / `drawnDot`) as plain draw ops.
 *
 * Locked to Swift by `cursorStyleAssets`: sizes/hotspots/raster grids come from
 * the REAL provider; the draw ops are a verbatim oracle of the private drawing
 * handlers that the Swift harness self-checks by re-drawing them and comparing
 * the raster BYTES with the real `rasterizedCGImage` at several pixel sizes.
 *
 * How the Mac rasterizes (what the GPU/2D rasterizer must reproduce):
 * - A bitmap of `rasterPixelSize(base × rasterScale)` pixels (8-bit RGBA,
 *   deviceRGB, antialiased) with the CTM scaled by (pixelW / baseW, pixelH /
 *   baseH) — the artwork is STRETCHED to fill the grid (independent x/y
 *   scale), operation `.copy` onto a transparent bitmap.
 * - `flipped: true` artwork coordinates are Y-DOWN sprite points (origin
 *   top-left): texel (u, v) = (x · pixelW / baseW, y · pixelH / baseH) with v
 *   counted from the TOP row. `flipped: false` (dot/ring) is Y-up, but every
 *   shape there is symmetric about the centre (12, 12), so orientation is moot.
 * - Ops are painted in order, source-over, colours sRGB with the given alpha:
 *   strokes are centred on the path (half the width inside, half outside), the
 *   arrow path uses ROUND joins (NSBezierPath default butt caps, miter limit
 *   10 — irrelevant for these closed paths), non-zero winding fill. Because
 *   the fill is painted LAST over the strokes, the visible outline is only the
 *   outer half of each stroke: `macOS Arrow` = black fill, white band 1.2 pt
 *   outside the edge, black band from 1.2 to 2.0 pt outside; `White Arrow` =
 *   white fill with a 1.2 pt black band outside.
 * - `Hand` is `NSCursor.pointingHand.image` — a SYSTEM raster (no vector
 *   geometry exists); its point size / hotspot are recorded from macOS by the
 *   vectors. The web needs a bitmap of it (see `handArtworkNote`).
 */
import type { Point, Rect, Size } from "../model/types";
import { CursorStyle } from "../model/enums";
import { sInt, smax } from "./swift";

export interface CursorStyleAsset {
  /** `asset.image.size` — sprite size in POINTS (the layout's `cursorSize`). */
  imageSize: Size;
  /** `asset.hotSpot` — sprite points, Y-DOWN from the top-left. */
  hotSpot: Point;
}

/** sRGB colour with alpha (0…1). */
export interface CursorRGBA {
  r: number;
  g: number;
  b: number;
  a: number;
}

export type CursorDrawOp =
  | { kind: "strokePath"; points: Point[]; closed: true; lineWidth: number; lineJoin: "round"; color: CursorRGBA }
  | { kind: "fillPath"; points: Point[]; closed: true; color: CursorRGBA }
  | { kind: "strokeOval"; rect: Rect; lineWidth: number; color: CursorRGBA }
  | { kind: "fillOval"; rect: Rect; color: CursorRGBA };

export interface CursorArtwork {
  /** NSImage(size:flipped:) — true = Y-down drawing coordinates. */
  flipped: boolean;
  size: Size;
  ops: CursorDrawOp[];
}

const BLACK: CursorRGBA = Object.freeze({ r: 0, g: 0, b: 0, a: 1 });
const WHITE: CursorRGBA = Object.freeze({ r: 1, g: 1, b: 1, a: 1 });
const black = (a: number): CursorRGBA => ({ r: 0, g: 0, b: 0, a });

/** Classic macOS arrow silhouette (Y-down sprite points, tip at (2, 2)). */
export const arrowPath: readonly Point[] = Object.freeze([
  { x: 2, y: 2 },
  { x: 2, y: 23.6 },
  { x: 7.0, y: 19.0 },
  { x: 10.6, y: 26.4 },
  { x: 14.2, y: 24.7 },
  { x: 10.6, y: 17.5 },
  { x: 17.2, y: 17.5 },
]);

export const arrowSize: Size = Object.freeze({ width: 20, height: 28 });
export const dotSize: Size = Object.freeze({ width: 24, height: 24 });

/**
 * `NSCursor.pointingHand` as recorded by the `cursorStyleAssets` vectors on
 * macOS 26 (system artwork — may change with the OS; the vectors will fail if
 * it does).
 */
export const handAsset: CursorStyleAsset = Object.freeze({
  imageSize: Object.freeze({ width: 32, height: 32 }),
  hotSpot: Object.freeze({ x: 13, y: 8 }),
});

export const handArtworkNote =
  "Hand = NSCursor.pointingHand.image (a system raster). The web must ship a bitmap of it " +
  "(export it from macOS at the needed pixel density); it has no vector geometry.";

/** `CursorStyleProvider.asset(for:)` — point size + hotspot. */
export function asset(style: CursorStyle): CursorStyleAsset {
  switch (style) {
    case CursorStyle.hand:
      return { imageSize: { ...handAsset.imageSize }, hotSpot: { ...handAsset.hotSpot } };
    case CursorStyle.system:
    case CursorStyle.inverted:
      return { imageSize: { ...arrowSize }, hotSpot: { x: 2, y: 2 } };
    case CursorStyle.dot:
    case CursorStyle.ring:
      return { imageSize: { ...dotSize }, hotSpot: { x: 12, y: 12 } };
  }
}

/** The draw ops of `drawnArrow` / `drawnDot` (null for `Hand` — system raster). */
export function artwork(style: CursorStyle): CursorArtwork | null {
  const path = arrowPath.map((p) => ({ ...p }));
  switch (style) {
    case CursorStyle.system:
      // drawnArrow(fill: .black, outline: .white, outerOutline: .black)
      return {
        flipped: true,
        size: { ...arrowSize },
        ops: [
          { kind: "strokePath", points: path, closed: true, lineWidth: 4, lineJoin: "round", color: { ...BLACK } },
          { kind: "strokePath", points: path, closed: true, lineWidth: 2.4, lineJoin: "round", color: { ...WHITE } },
          { kind: "fillPath", points: path, closed: true, color: { ...BLACK } },
        ],
      };
    case CursorStyle.inverted:
      // drawnArrow(fill: .white, outline: .black)
      return {
        flipped: true,
        size: { ...arrowSize },
        ops: [
          { kind: "strokePath", points: path, closed: true, lineWidth: 2.4, lineJoin: "round", color: { ...BLACK } },
          { kind: "fillPath", points: path, closed: true, color: { ...WHITE } },
        ],
      };
    case CursorStyle.dot:
      // drawnDot(filled: true)
      return {
        flipped: false,
        size: { ...dotSize },
        ops: [
          { kind: "strokeOval", rect: { x: 1.5, y: 1.5, width: 21, height: 21 }, lineWidth: 1.5, color: black(0.55) },
          { kind: "fillOval", rect: { x: 2.5, y: 2.5, width: 19, height: 19 }, color: { ...WHITE } },
          { kind: "fillOval", rect: { x: 8.5, y: 8.5, width: 7, height: 7 }, color: black(0.25) },
        ],
      };
    case CursorStyle.ring:
      // drawnDot(filled: false)
      return {
        flipped: false,
        size: { ...dotSize },
        ops: [
          { kind: "strokeOval", rect: { x: 3, y: 3, width: 18, height: 18 }, lineWidth: 5, color: black(0.55) },
          { kind: "strokeOval", rect: { x: 3, y: 3, width: 18, height: 18 }, lineWidth: 3, color: { ...WHITE } },
        ],
      };
    case CursorStyle.hand:
      return null;
  }
}

/** `rasterizedCGImage(for:pixelSize:)` pixel grid: `max(1, Int(ceil(side)))`. */
export function rasterPixelSize(pixelSize: Size): Size {
  return {
    width: smax(1, sInt(Math.ceil(pixelSize.width))),
    height: smax(1, sInt(Math.ceil(pixelSize.height))),
  };
}

/** Raster CTM scale: (pixelW / baseW, pixelH / baseH). */
export function rasterScale(style: CursorStyle, pixelSize: Size): { x: number; y: number } {
  const base = asset(style).imageSize;
  const px = rasterPixelSize(pixelSize);
  return { x: px.width / base.width, y: px.height / base.height };
}
