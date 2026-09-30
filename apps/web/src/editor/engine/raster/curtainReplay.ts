/**
 * Replays the Curtain Unveil draw RECIPE (`core/math/curtainUnveilMath`
 * `curtainRecipe`, locked to `CurtainUnveilMath.renderImage` by the
 * curtainUnveilDrawRecipe vectors) into a Y-DOWN Canvas2D raster of the
 * recipe's `width × height`.
 *
 * Space mapping (see the core module doc): polygons, gradient axes and
 * centres are UNIT card space → pixel `(u.x · w, u.y · h)` with NO flip (the
 * CG raster's rows are already in visual order); `cardClip.path` is Y-UP
 * raster pixels (flip `y ↦ h − y`); `logo.rect` is Y-UP pixels (drawn
 * upright at `h − y − height`); `radialGradient` radii are pixels.
 *
 * CG semantics: each gradient op = clip to its polygon, then
 * `drawLinearGradient` / `drawRadialGradient` in gamma-encoded sRGB with
 * straight-alpha interpolation (canvas gradients do the same). Without
 * drawsBefore/AfterLocation CG paints nothing beyond the axis ends; canvas
 * gradients always extend, so those sides are clipped away by a half-plane.
 * Everything sits inside the card clip.
 */
import type { CurtainOp } from "../../core/math/curtainUnveilMath";
import type { RGBA } from "../../core/math/overlaySupport";
import type { Point } from "../../core/model";
import { addStops, cssColor, toPath2D, type Ctx2D } from "./cgReplay";

const BIG = 1e5;

function polyPath(poly: readonly Point[], w: number, h: number): Path2D {
  const p = new Path2D();
  poly.forEach((q, i) => (i === 0 ? p.moveTo(q.x * w, q.y * h) : p.lineTo(q.x * w, q.y * h)));
  p.closePath();
  return p;
}

/** Half-plane { q : (q − origin) · dir ≥ 0 } as a huge quad (pixels). */
function halfPlane(origin: { x: number; y: number }, dir: { x: number; y: number }): Path2D {
  const len = Math.hypot(dir.x, dir.y) || 1;
  const d = { x: dir.x / len, y: dir.y / len };
  const n = { x: -d.y, y: d.x };
  const p = new Path2D();
  p.moveTo(origin.x + n.x * BIG, origin.y + n.y * BIG);
  p.lineTo(origin.x - n.x * BIG, origin.y - n.y * BIG);
  p.lineTo(origin.x - n.x * BIG + d.x * BIG, origin.y - n.y * BIG + d.y * BIG);
  p.lineTo(origin.x + n.x * BIG + d.x * BIG, origin.y + n.y * BIG + d.y * BIG);
  p.closePath();
  return p;
}

export interface CurtainLogo {
  image: ImageBitmap;
  /** Cached tinted silhouettes by `${w}x${h}|tint`. */
  tinted: Map<string, OffscreenCanvas>;
}

function tintedLogo(logo: CurtainLogo, w: number, h: number, tint: RGBA): OffscreenCanvas {
  const key = `${w}x${h}|${tint.r},${tint.g},${tint.b},${tint.a}`;
  const hit = logo.tinted.get(key);
  if (hit) return hit;
  const c = new OffscreenCanvas(Math.max(1, w), Math.max(1, h));
  const x = c.getContext("2d") as Ctx2D;
  x.imageSmoothingQuality = "high";
  x.drawImage(logo.image, 0, 0, c.width, c.height);
  // CGContext.clip(to:mask:) with the logo's alpha, then fill with the tint.
  x.globalCompositeOperation = "source-in";
  x.fillStyle = cssColor(tint);
  x.fillRect(0, 0, c.width, c.height);
  if (logo.tinted.size > 8) logo.tinted.clear();
  logo.tinted.set(key, c);
  return c;
}

export function replayCurtain(ctx: Ctx2D, ops: readonly CurtainOp[], w: number, h: number, logo: CurtainLogo | null): void {
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 1;
  ctx.globalCompositeOperation = "source-over";
  for (const op of ops) {
    switch (op.op) {
      case "cardClip": {
        // Y-UP raster path → Y-down canvas.
        ctx.setTransform(1, 0, 0, -1, 0, h);
        ctx.clip(toPath2D(op.path));
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        break;
      }
      case "linearGradient": {
        const s = { x: op.start.x * w, y: op.start.y * h };
        const e = { x: op.end.x * w, y: op.end.y * h };
        const dir = { x: e.x - s.x, y: e.y - s.y };
        ctx.save();
        ctx.clip(polyPath(op.polygon, w, h));
        if (!op.before) ctx.clip(halfPlane(s, dir));
        if (!op.after) ctx.clip(halfPlane(e, { x: -dir.x, y: -dir.y }));
        const g = ctx.createLinearGradient(s.x, s.y, e.x, e.y);
        addStops(g, op.colors, op.locations);
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, w, h);
        ctx.restore();
        break;
      }
      case "radialGradient": {
        const c = { x: op.center.x * w, y: op.center.y * h };
        ctx.save();
        ctx.clip(polyPath(op.polygon, w, h));
        if (!op.after) {
          const p = new Path2D();
          p.arc(c.x, c.y, Math.max(0, op.endRadius), 0, Math.PI * 2);
          ctx.clip(p);
        }
        if (!op.before && op.startRadius > 0) {
          const p = new Path2D();
          p.rect(-BIG, -BIG, 2 * BIG, 2 * BIG);
          p.arc(c.x, c.y, op.startRadius, 0, Math.PI * 2);
          ctx.clip(p, "evenodd");
        }
        const g = ctx.createRadialGradient(c.x, c.y, Math.max(0, op.startRadius), c.x, c.y, Math.max(0, op.endRadius));
        addStops(g, op.colors, op.locations);
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, w, h);
        ctx.restore();
        break;
      }
      case "logo": {
        if (!logo) break;
        const r = op.rect;
        const y = h - r.y - r.height; // Y-UP rect → visual rows
        ctx.save();
        ctx.clip(polyPath(op.polygon, w, h));
        ctx.globalAlpha = op.alpha;
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = "high";
        if (op.tint) {
          const tw = Math.max(1, Math.round(r.width));
          const th = Math.max(1, Math.round(r.height));
          ctx.drawImage(tintedLogo(logo, tw, th, op.tint), r.x, y, r.width, r.height);
        } else {
          ctx.drawImage(logo.image, r.x, y, r.width, r.height);
        }
        ctx.restore();
        break;
      }
    }
  }
  ctx.restore();
}
