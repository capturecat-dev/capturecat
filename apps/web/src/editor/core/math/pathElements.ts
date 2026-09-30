/**
 * Converters between the three path-element encodings the clusters used
 * while they were built in parallel, so every CoreGraphics path primitive
 * has ONE implementation:
 *
 *   styleSupport.PathElement   `{ op, pts }`         — canonical (cgPathRect,
 *                                                      cgPathRoundedRect,
 *                                                      cgPathEllipse,
 *                                                      continuousRoundedRect.path)
 *   overlaySupport.PathEl      `["M", x, y]` tuples  — overlay draw recipes
 *   regionsSupport.PathElement `{ type, points }`    — device/region recipes
 *
 * All three list exactly the elements CGPath.applyWithBlock reports.
 */
import type { PathElement } from "./styleSupport";
import type { PathEl } from "./overlaySupport";
import type { PathElement as TypedPathElement } from "./regionsSupport";

export function toTuples(path: readonly PathElement[]): PathEl[] {
  return path.map((e): PathEl => {
    const p = e.pts;
    switch (e.op) {
      case "move":
        return ["M", p[0].x, p[0].y];
      case "line":
        return ["L", p[0].x, p[0].y];
      case "quad":
        return ["Q", p[0].x, p[0].y, p[1].x, p[1].y];
      case "curve":
        return ["C", p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y];
      case "close":
        return ["Z"];
    }
  });
}

export function toTyped(path: readonly PathElement[]): TypedPathElement[] {
  return path.map((e): TypedPathElement => {
    const p = e.pts;
    switch (e.op) {
      case "move":
        return { type: "move", points: [p[0]] };
      case "line":
        return { type: "line", points: [p[0]] };
      case "quad":
        return { type: "quad", points: [p[0], p[1]] };
      case "curve":
        return { type: "curve", points: [p[0], p[1], p[2]] };
      case "close":
        return { type: "close", points: [] };
    }
  });
}
