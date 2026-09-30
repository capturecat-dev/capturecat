/**
 * Port of Services/ContinuousRoundedRect.swift — Apple's continuous-corner
 * ("squircle") rounded rectangle as CGPath elements, element-for-element
 * (three cubics per corner, per-axis reach capped at half the edge), plus the
 * circular-corner `circularPath`. `DeviceFrameLayout.continuousRoundedPath`
 * and `VideoExporter.frameShapeCGPath(.squircle)` are this same call.
 *
 * Locked by the golden-vector units `continuousRoundedRectPath`,
 * `cgPathPrimitives` (the CG rect / rounded-rect fallbacks) and
 * `styleConstants` (`fullReach`).
 *
 * Space: the path is emitted in whatever space `rect` is in; Swift callers
 * pass CG Y-UP bitmap rects. The shape is symmetric, so the element list for
 * a Y-down rect describes the same outline (start point and winding differ
 * only in orientation — fill with the non-zero or even-odd rule, both agree
 * for this simple closed curve).
 */
import type { Rect } from "../model/types";
import { maxX, maxY, midY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { cgPathRect, cgPathRoundedRect, type PathElement } from "./styleSupport";
import { smax, smin } from "./swift";

/** Corner reach as a multiple of r when nothing caps it. */
export const fullReach = 1.528665;
const aFull = 1.08849;
const bFull = 0.868407;
const aMin = 0.96;
const bMin = 0.82;
const endLong = 0.631494;
const endShort = 0.074911;
const midLong = 0.372824;
const midShort = 0.16906;

/** private `controls(reach:)` */
function controls(p: number): [number, number] {
  const t = (p - 1) / (fullReach - 1);
  return [aMin + (aFull - aMin) * t, bMin + (bFull - bMin) * t];
}

/** `path(rect:cornerRadius:)` — radius clamped to min(w, h)/2 like SwiftUI. */
export function path(rect: Rect, cornerRadius: number): PathElement[] {
  if (!(rectWidth(rect) > 0 && rectHeight(rect) > 0)) return cgPathRect(rect);
  const r = smin(smax(0, cornerRadius), smin(rectWidth(rect), rectHeight(rect)) / 2);
  if (!(r > 0)) return cgPathRect(rect);

  const reachY = smin(fullReach, rectHeight(rect) / 2 / r);
  const reachX = smin(fullReach, rectWidth(rect) / 2 / r);
  const [aY, bY] = controls(reachY);
  const [aX, bX] = controls(reachX);
  const pY = reachY * r;
  const pX = reachX * r;
  const aYr = aY * r;
  const bYr = bY * r;
  const aXr = aX * r;
  const bXr = bX * r;
  const eL = endLong * r;
  const eS = endShort * r;
  const mL = midLong * r;
  const mS = midShort * r;

  const x0 = minX(rect);
  const x1 = maxX(rect);
  const y0 = minY(rect);
  const y1 = maxY(rect);
  const P = (x: number, y: number) => ({ x, y });
  const mv = (x: number, y: number): PathElement => ({ op: "move", pts: [P(x, y)] });
  const ln = (x: number, y: number): PathElement => ({ op: "line", pts: [P(x, y)] });
  const cv = (to: [number, number], c1: [number, number], c2: [number, number]): PathElement => ({
    op: "curve",
    pts: [P(c1[0], c1[1]), P(c2[0], c2[1]), P(to[0], to[1])],
  });

  return [
    mv(x1, midY(rect)),
    // Bottom-right.
    ln(x1, y1 - pY),
    cv([x1 - eS, y1 - eL], [x1, y1 - aYr], [x1, y1 - bYr]),
    cv([x1 - eL, y1 - eS], [x1 - mS, y1 - mL], [x1 - mL, y1 - mS]),
    cv([x1 - pX, y1], [x1 - bXr, y1], [x1 - aXr, y1]),
    // Bottom-left.
    ln(x0 + pX, y1),
    cv([x0 + eL, y1 - eS], [x0 + aXr, y1], [x0 + bXr, y1]),
    cv([x0 + eS, y1 - eL], [x0 + mL, y1 - mS], [x0 + mS, y1 - mL]),
    cv([x0, y1 - pY], [x0, y1 - bYr], [x0, y1 - aYr]),
    // Top-left.
    ln(x0, y0 + pY),
    cv([x0 + eS, y0 + eL], [x0, y0 + aYr], [x0, y0 + bYr]),
    cv([x0 + eL, y0 + eS], [x0 + mS, y0 + mL], [x0 + mL, y0 + mS]),
    cv([x0 + pX, y0], [x0 + bXr, y0], [x0 + aXr, y0]),
    // Top-right.
    ln(x1 - pX, y0),
    cv([x1 - eL, y0 + eS], [x1 - aXr, y0], [x1 - bXr, y0]),
    cv([x1 - eS, y0 + eL], [x1 - mL, y0 + mS], [x1 - mS, y0 + mL]),
    cv([x1, y0 + pY], [x1, y0 + bYr], [x1, y0 + aYr]),
    { op: "close", pts: [] },
  ];
}

/** `circularPath(rect:cornerRadius:)` — CG circular-corner rounded rect. */
export function circularPath(rect: Rect, cornerRadius: number): PathElement[] {
  const r = smin(smax(0, cornerRadius), smin(rectWidth(rect), rectHeight(rect)) / 2);
  if (!(r > 0)) return cgPathRect(rect);
  return cgPathRoundedRect(rect, r, r);
}
