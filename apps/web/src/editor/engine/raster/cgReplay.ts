/**
 * Replays a CGContext draw RECIPE (`core/math/overlaySupport` `DrawOp[]`,
 * recorded by the ported Swift renderers) into a Canvas2D context, with
 * CoreGraphics semantics:
 *
 *  - The recipe's CTM starts at the CG bitmap's identity, i.e. Y-UP device
 *    pixels. The canvas is Y-DOWN, so replay starts from the device flip
 *    `(1, 0, 0, −1, 0, H)`; the recipe's own base transform
 *    (translate(0, h) · scale(1, −1)) then cancels it and every path lands
 *    Y-down, upright — exactly the CGImage rows the exporter composites.
 *  - `alpha` → globalAlpha (multiplies every paint and a layer composite).
 *  - `shadow` → canvas shadow in DEVICE pixels, untouched by the CTM (CG
 *    semantics). CG's offset is Y-UP device space, so +offsetY moves the
 *    shadow UP (canvas `shadowOffsetY = −offsetY`); CG's blur and canvas
 *    `shadowBlur` share the σ = blur / 2 Gaussian.
 *  - `beginLayer`/`endLayer` → an offscreen canvas; alpha and shadow reset
 *    to defaults inside, and at the end the finished group is composited ONCE
 *    with the alpha + shadow that were current at `beginLayer` (so the
 *    shadow is cast by the whole group, like CGContextBeginTransparencyLayer).
 *  - fills (non-zero / even-odd), strokes (width, cap, join, miter limit,
 *    dash in user space), clips, CG radial gradients (CGGradient stops or
 *    the 256-stop Oklab ramp; canvas gradients interpolate straight alpha in
 *    sRGB like CGGradient; drawsBefore/After emulated by clipping).
 *  - `text` ops are handed to the caller's `drawText` (fonts are the
 *    caller's business).
 *
 * Dirty bounds: every draw's device-space extent (stroke width, AA and
 * shadow spread included, clipped) is accumulated, so a layer only clears /
 * composites the region it touched and the caller can upload just the
 * region that changed.
 */
import type { DrawOp, GradientSpec, PathElements, RGBA } from "../../core/math/overlaySupport";
import { oklabGradientTable } from "../../core/math/overlaySupport";

export type Ctx2D = OffscreenCanvasRenderingContext2D;

/** Device-pixel box (x0 ≤ x < x1). Empty when x1 ≤ x0. */
export interface Box {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}
export const EMPTY_BOX: Box = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
export const boxEmpty = (b: Box) => !(b.x1 > b.x0 && b.y1 > b.y0);
export function boxUnion(a: Box, b: Box): Box {
  if (boxEmpty(a)) return b;
  if (boxEmpty(b)) return a;
  return { x0: Math.min(a.x0, b.x0), y0: Math.min(a.y0, b.y0), x1: Math.max(a.x1, b.x1), y1: Math.max(a.y1, b.y1) };
}
export function boxIntersect(a: Box, b: Box): Box {
  return { x0: Math.max(a.x0, b.x0), y0: Math.max(a.y0, b.y0), x1: Math.min(a.x1, b.x1), y1: Math.min(a.y1, b.y1) };
}
function boxOutset(b: Box, d: number): Box {
  return boxEmpty(b) ? b : { x0: b.x0 - d, y0: b.y0 - d, x1: b.x1 + d, y1: b.y1 + d };
}
/** Integer pixel box (outward), clamped to the canvas. */
export function boxPixels(b: Box, w: number, h: number): Box {
  if (boxEmpty(b)) return EMPTY_BOX;
  const r = { x0: Math.max(0, Math.floor(b.x0)), y0: Math.max(0, Math.floor(b.y0)), x1: Math.min(w, Math.ceil(b.x1)), y1: Math.min(h, Math.ceil(b.y1)) };
  return boxEmpty(r) ? EMPTY_BOX : r;
}

export function cssColor(c: RGBA): string {
  const ch = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255);
  const a = Math.max(0, Math.min(1, c.a));
  return `rgba(${ch(c.r)},${ch(c.g)},${ch(c.b)},${a})`;
}

export function toPath2D(els: PathElements): Path2D {
  const p = new Path2D();
  for (const e of els) {
    switch (e[0]) {
      case "M":
        p.moveTo(e[1], e[2]);
        break;
      case "L":
        p.lineTo(e[1], e[2]);
        break;
      case "Q":
        p.quadraticCurveTo(e[1], e[2], e[3], e[4]);
        break;
      case "C":
        p.bezierCurveTo(e[1], e[2], e[3], e[4], e[5], e[6]);
        break;
      case "Z":
        p.closePath();
        break;
    }
  }
  return p;
}

/** User-space control-point box of a path (conservative for curves). */
function pathUserBox(els: PathElements): Box {
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (const e of els) {
    for (let i = 1; i + 1 < e.length; i += 2) {
      const x = e[i] as number;
      const y = e[i + 1] as number;
      if (x < x0) x0 = x;
      if (y < y0) y0 = y;
      if (x > x1) x1 = x;
      if (y > y1) y1 = y;
    }
  }
  return { x0, y0, x1, y1 };
}

function deviceBox(m: DOMMatrix, b: Box): Box {
  if (!(b.x1 >= b.x0 && b.y1 >= b.y0)) return EMPTY_BOX;
  const pts = [
    m.transformPoint({ x: b.x0, y: b.y0 }),
    m.transformPoint({ x: b.x1, y: b.y0 }),
    m.transformPoint({ x: b.x0, y: b.y1 }),
    m.transformPoint({ x: b.x1, y: b.y1 }),
  ];
  return {
    x0: Math.min(...pts.map((p) => p.x)),
    y0: Math.min(...pts.map((p) => p.y)),
    x1: Math.max(...pts.map((p) => p.x)),
    y1: Math.max(...pts.map((p) => p.y)),
  };
}

/** Gradient colour stops (CGGradient table or the OklabGradient ramp). */
export function gradientStops(g: GradientSpec): { colors: RGBA[]; locations: number[] } {
  if (g.kind === "stops") return { colors: g.colors, locations: g.locations };
  const table = oklabGradientTable([
    { location: 0, color: g.from },
    { location: 1, color: g.to },
  ]);
  return table ?? { colors: [g.from, g.to], locations: [0, 1] };
}

export function addStops(grad: CanvasGradient, colors: readonly RGBA[], locations: readonly number[]): void {
  for (let i = 0; i < colors.length; i++) {
    grad.addColorStop(Math.max(0, Math.min(1, locations[i] ?? i / Math.max(1, colors.length - 1))), cssColor(colors[i]));
  }
}

type Shadow = { offsetX: number; offsetY: number; blur: number; color: RGBA } | null;

interface ReplayState {
  alpha: number;
  shadow: Shadow;
  /** Device-space clip box (null = unclipped). */
  clip: Box | null;
}

export interface ReplayOptions {
  /** Target pixel size (the Y-UP → Y-DOWN device flip uses the height). */
  width: number;
  height: number;
  /**
   * Draws one `text`/`ctText` op with the current transform/alpha/shadow and
   * returns the run's USER-space box (conservative) for dirty tracking.
   */
  drawText?: (ctx: Ctx2D, op: DrawOp & Record<string, unknown>) => Box;
  /** Offscreen canvases for transparency layers (same size as the target, kept CLEAR between uses). */
  layerCanvas: (depth: number) => OffscreenCanvas;
}

function applyShadow(ctx: Ctx2D, s: Shadow): void {
  if (!s) {
    ctx.shadowColor = "rgba(0,0,0,0)";
    ctx.shadowBlur = 0;
    ctx.shadowOffsetX = 0;
    ctx.shadowOffsetY = 0;
    return;
  }
  ctx.shadowColor = cssColor(s.color);
  ctx.shadowBlur = s.blur;
  ctx.shadowOffsetX = s.offsetX;
  // CG shadow offsets are Y-UP device pixels; canvas shadow offsets are Y-DOWN device pixels.
  ctx.shadowOffsetY = -s.offsetY;
}

/** Device box of a shadowed draw: the shape plus its offset, blurred copy. */
function withShadow(b: Box, s: Shadow): Box {
  if (!s || boxEmpty(b)) return b;
  const spread = s.blur * 1.5 + 2;
  const shifted = { x0: b.x0 + s.offsetX, y0: b.y0 - s.offsetY, x1: b.x1 + s.offsetX, y1: b.y1 - s.offsetY };
  return boxUnion(b, boxOutset(shifted, spread));
}

/**
 * Replays `ops` into `target` (whose pixels outside the returned box are
 * untouched). Returns the device-pixel box everything was drawn in.
 */
export function replayCG(target: Ctx2D, ops: readonly DrawOp[], opt: ReplayOptions): Box {
  const base = new DOMMatrix([1, 0, 0, -1, 0, opt.height]);
  const full: Box = { x0: 0, y0: 0, x1: opt.width, y1: opt.height };
  interface Frame {
    ctx: Ctx2D;
    state: ReplayState;
    stack: ReplayState[];
    bounds: Box;
    /** State captured at beginLayer (applied when compositing the layer). */
    composite?: ReplayState;
    canvas?: OffscreenCanvas;
  }
  const reset = (ctx: Ctx2D) => {
    ctx.setTransform(base);
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = "source-over";
    applyShadow(ctx, null);
    ctx.lineCap = "butt";
    ctx.lineJoin = "miter";
    ctx.miterLimit = 10;
    ctx.setLineDash([]);
    ctx.imageSmoothingEnabled = true;
  };
  reset(target);
  target.save();
  const frames: Frame[] = [{ ctx: target, state: { alpha: 1, shadow: null, clip: null }, stack: [], bounds: EMPTY_BOX }];
  const top = () => frames[frames.length - 1];
  const touch = (f: Frame, b: Box) => {
    let d = withShadow(boxOutset(b, 1), f.state.shadow);
    d = boxIntersect(d, f.state.clip ?? full);
    if (!boxEmpty(d)) f.bounds = boxUnion(f.bounds, d);
  };

  for (const op of ops) {
    const f = top();
    const ctx = f.ctx;
    switch (op.op) {
      case "save":
        ctx.save();
        f.stack.push({ ...f.state });
        break;
      case "restore": {
        ctx.restore();
        const s = f.stack.pop();
        if (s) f.state = s;
        break;
      }
      case "translate":
        ctx.translate(op.x, op.y);
        break;
      case "scale":
        ctx.scale(op.x, op.y);
        break;
      case "alpha":
        f.state.alpha = op.alpha;
        ctx.globalAlpha = op.alpha;
        break;
      case "shadow":
        f.state.shadow = op.color && op.color.a > 0 ? { offsetX: op.offsetX, offsetY: op.offsetY, blur: op.blur, color: op.color } : null;
        applyShadow(ctx, f.state.shadow);
        break;
      case "beginLayer": {
        const canvas = opt.layerCanvas(frames.length);
        const lctx = canvas.getContext("2d") as Ctx2D;
        reset(lctx);
        lctx.save();
        // Same CTM as the parent; alpha/shadow reset inside the layer. (The
        // parent's clip still applies when the finished layer is composited.)
        lctx.setTransform(ctx.getTransform());
        frames.push({
          ctx: lctx,
          state: { alpha: 1, shadow: null, clip: f.state.clip },
          stack: [],
          bounds: EMPTY_BOX,
          composite: { ...f.state },
          canvas,
        });
        break;
      }
      case "endLayer": {
        if (frames.length < 2) break;
        const layer = frames.pop()!;
        const lctx = layer.ctx;
        lctx.restore();
        const parent = top();
        const pctx = parent.ctx;
        const b = boxPixels(layer.bounds, opt.width, opt.height);
        if (!boxEmpty(b)) {
          pctx.save();
          pctx.setTransform(1, 0, 0, 1, 0, 0);
          pctx.globalAlpha = layer.composite?.alpha ?? 1;
          applyShadow(pctx, layer.composite?.shadow ?? null);
          const w = b.x1 - b.x0;
          const h = b.y1 - b.y0;
          pctx.drawImage(layer.canvas!, b.x0, b.y0, w, h, b.x0, b.y0, w, h);
          pctx.restore();
          // Leave the layer canvas clear for its next use.
          lctx.save();
          lctx.setTransform(1, 0, 0, 1, 0, 0);
          lctx.clearRect(b.x0, b.y0, w, h);
          lctx.restore();
          let pb = withShadow(b, layer.composite?.shadow ?? null);
          pb = boxIntersect(pb, parent.state.clip ?? full);
          if (!boxEmpty(pb)) parent.bounds = boxUnion(parent.bounds, pb);
        }
        break;
      }
      case "fill":
        ctx.fillStyle = cssColor(op.color);
        ctx.fill(toPath2D(op.path), op.evenOdd ? "evenodd" : "nonzero");
        touch(f, deviceBox(ctx.getTransform(), pathUserBox(op.path)));
        break;
      case "stroke": {
        ctx.strokeStyle = cssColor(op.color);
        ctx.lineWidth = op.lineWidth;
        ctx.lineCap = op.cap;
        ctx.lineJoin = op.join;
        ctx.miterLimit = op.miterLimit;
        ctx.setLineDash(op.dash ?? []);
        ctx.lineDashOffset = op.dashPhase;
        ctx.stroke(toPath2D(op.path));
        const reach = (op.lineWidth / 2) * (op.join === "miter" ? Math.max(1, op.miterLimit) : op.cap === "square" ? Math.SQRT2 : 1);
        const ub = pathUserBox(op.path);
        touch(f, deviceBox(ctx.getTransform(), { x0: ub.x0 - reach, y0: ub.y0 - reach, x1: ub.x1 + reach, y1: ub.y1 + reach }));
        break;
      }
      case "clip": {
        ctx.clip(toPath2D(op.path), op.evenOdd ? "evenodd" : "nonzero");
        const b = boxOutset(deviceBox(ctx.getTransform(), pathUserBox(op.path)), 1);
        f.state.clip = f.state.clip ? boxIntersect(f.state.clip, b) : b;
        break;
      }
      case "radialGradient": {
        const { colors, locations } = gradientStops(op.gradient);
        const g = ctx.createRadialGradient(
          op.startCenter.x, op.startCenter.y, Math.max(0, op.startRadius),
          op.endCenter.x, op.endCenter.y, Math.max(0, op.endRadius),
        );
        addStops(g, colors, locations);
        ctx.save();
        let area: Box = f.state.clip ?? full;
        if (!op.after) {
          // CG paints nothing past the end circle without drawsAfterEndLocation.
          const p = new Path2D();
          p.arc(op.endCenter.x, op.endCenter.y, Math.max(0, op.endRadius), 0, Math.PI * 2);
          ctx.clip(p);
          const r = Math.max(0, op.endRadius);
          area = boxIntersect(area, deviceBox(ctx.getTransform(), { x0: op.endCenter.x - r, y0: op.endCenter.y - r, x1: op.endCenter.x + r, y1: op.endCenter.y + r }));
        }
        if (!op.before && op.startRadius > 0) {
          // …and nothing inside the start circle without drawsBeforeStartLocation.
          const p = new Path2D();
          p.rect(-1e6, -1e6, 2e6, 2e6);
          p.arc(op.startCenter.x, op.startCenter.y, op.startRadius, 0, Math.PI * 2);
          ctx.clip(p, "evenodd");
        }
        ctx.fillStyle = g;
        if (!boxEmpty(area)) {
          const inv = ctx.getTransform().inverse();
          const ub = deviceBox(inv, boxOutset(area, 1));
          ctx.fillRect(ub.x0, ub.y0, ub.x1 - ub.x0, ub.y1 - ub.y0);
          touch(f, area);
        }
        ctx.restore();
        break;
      }
      case "text":
      case "ctText": {
        const ub = opt.drawText?.(ctx, op as DrawOp & Record<string, unknown>);
        if (ub) touch(f, deviceBox(ctx.getTransform(), ub));
        break;
      }
    }
  }
  // Unbalanced layers (never in a recorded recipe): flush them.
  while (frames.length > 1) {
    const layer = frames.pop()!;
    layer.ctx.restore();
    const parent = top();
    parent.ctx.save();
    parent.ctx.setTransform(1, 0, 0, 1, 0, 0);
    parent.ctx.drawImage(layer.canvas!, 0, 0);
    parent.ctx.restore();
    layer.ctx.save();
    layer.ctx.setTransform(1, 0, 0, 1, 0, 0);
    layer.ctx.clearRect(0, 0, opt.width, opt.height);
    layer.ctx.restore();
    parent.bounds = full;
  }
  target.restore();
  target.setTransform(1, 0, 0, 1, 0, 0);
  return boxPixels(frames[0].bounds, opt.width, opt.height);
}
