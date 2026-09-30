/**
 * `watermarkStatic` geometry (VideoExporter.export), Y-DOWN output pixels:
 *   edgePad = 20 · canvasScale
 *   targetW = min(watermarkSize · canvasScale, max(1, W − 2·edgePad))
 *   scale   = targetW / rawW,  targetH = rawH · scale
 *   usable  = max(0, W|H − 2·edgePad − target)
 *   origin  = edgePad + clamp01(x) · usableW,  CI y = edgePad + (1 − clamp01(y)) · usableH
 */
import { smax, smin } from "../../core/math/swift";

export interface WatermarkPlacement {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** `edgePad` — the watermark's inset from every canvas edge (also the drag's usable span). */
export function watermarkEdgePad(canvasScale: number): number {
  return 20 * canvasScale;
}

export function watermarkPlacement(
  raw: { width: number; height: number },
  output: { width: number; height: number },
  canvasScale: number,
  s: { watermarkSize: number; watermarkX: number; watermarkY: number },
): WatermarkPlacement | null {
  const edgePad = watermarkEdgePad(canvasScale);
  const rawW = raw.width;
  const rawH = raw.height;
  if (!(rawW > 0 && rawH > 0)) return null;
  const targetW = smin(s.watermarkSize * canvasScale, smax(1, output.width - 2 * edgePad));
  const scale = targetW / rawW;
  const targetH = rawH * scale;
  const usableW = smax(0, output.width - 2 * edgePad - targetW);
  const usableH = smax(0, output.height - 2 * edgePad - targetH);
  const fx = smin(1, smax(0, s.watermarkX));
  const fy = smin(1, smax(0, s.watermarkY));
  const originX = edgePad + fx * usableW;
  // CI: originY (Y-up) = edgePad + (1 − fy) · usableH → top edge in Y-down px.
  const originYUp = edgePad + (1 - fy) * usableH;
  return { x: originX, y: output.height - originYUp - targetH, width: targetW, height: targetH };
}
