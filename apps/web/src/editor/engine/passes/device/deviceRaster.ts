/**
 * The iPhone 16 Pro chrome as card-space sprites — the exporter's LAYER SPLIT
 * (`DeviceFrameRenderer`): the bezel (side buttons + titanium body + glass
 * margin; its shadow is the separate `makeFrameShadow` layer), the side slab
 * (translated per frame by `TiltMath.deviceSideOffset` when tilted) and the
 * island layer (screen seam + Dynamic Island + lens, above the video; phone
 * aspect only).
 *
 * Numbers come from the golden-locked DRAW RECIPES in core/math/deviceBezel.ts
 * (a port of DeviceBezelRenderer); this file only paints them with Canvas2D,
 * following the recipe's paint semantics: continuous-corner paths, strokes
 * centred on the path, fills clipped to their shape, gradients from the
 * 257-stop Oklab table (CG lerps linearly between those stops), the body's
 * band + rim + AO composited as ONE group (the transparency layer).
 */
import {
  bodyRecipe,
  islandRecipe,
  sideButtonsRecipe,
  sideSlabRecipe,
  type LinearGradient,
} from "../../../core/math/deviceBezel";
import { continuousRoundedPath } from "../../../core/math/deviceFrameLayout";
import { gradientTable } from "../../../core/math/oklabGradient";
import { cgPathEllipse, cgPathRoundedRect } from "../../../core/math/styleSupport";
import type { Rect } from "../../layout";
import { cssColor, makeSprite, toPath2D, type Sprite } from "../sprite";

export interface DeviceSprites {
  bezel: Sprite | null;
  side: Sprite | null;
  island: Sprite | null;
}

type Ctx = OffscreenCanvasRenderingContext2D;

function gradient(ctx: Ctx, g: LinearGradient): CanvasGradient {
  const lg = ctx.createLinearGradient(g.start.x, g.start.y, g.end.x, g.end.y);
  const table = gradientTable(g.stops) ?? g.stops;
  for (const s of table) lg.addColorStop(Math.max(0, Math.min(1, s.location)), cssColor(s.color));
  return lg;
}

const cont = (rect: Rect, r: number) => toPath2D(continuousRoundedPath(rect, r));

function outset(r: Rect, d: number): Rect {
  return { x: r.x - d, y: r.y - d, width: r.width + 2 * d, height: r.height + 2 * d };
}

/** Bezel (buttons + body + glass) — `makeDeviceBezelImage`. */
function drawBezel(ctx: Ctx, videoRect: Rect) {
  for (const b of sideButtonsRecipe(videoRect)) {
    ctx.save();
    ctx.clip(cont(b.rect, b.cornerRadius));
    ctx.fillStyle = gradient(ctx, b.fill);
    ctx.fillRect(b.rect.x - 2, b.rect.y - 2, b.rect.width + 4, b.rect.height + 4);
    ctx.restore();
    ctx.lineWidth = b.hairline.lineWidth;
    ctx.strokeStyle = cssColor(b.hairline.color);
    ctx.stroke(cont(b.hairline.rect, b.hairline.cornerRadius));
  }
  // Exporter: shadowRadius / opacity 0 — the shadow is its own layer.
  const body = bodyRecipe(videoRect, 0, 0, 1);
  if (!body) return;
  // Band + rim + AO as one group (CG transparency layer).
  const group = new OffscreenCanvas(ctx.canvas.width, ctx.canvas.height);
  const g = group.getContext("2d", { colorSpace: "srgb" });
  if (g) {
    g.setTransform(ctx.getTransform());
    g.save();
    g.clip(cont(body.rect, body.cornerRadius));
    g.fillStyle = gradient(g, body.band);
    g.fillRect(body.rect.x - 2, body.rect.y - 2, body.rect.width + 4, body.rect.height + 4);
    g.restore();
    // Rim: the stroke outline of the inset path is the clip, the gradient fills it.
    g.lineWidth = body.rim.lineWidth;
    g.strokeStyle = gradient(g, body.rim.gradient);
    g.stroke(cont(body.rim.rect, body.rim.cornerRadius));
    g.lineWidth = body.ao.lineWidth;
    g.strokeStyle = cssColor(body.ao.color);
    g.stroke(cont(body.ao.rect, body.ao.cornerRadius));
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(group, 0, 0);
    ctx.restore();
  }
  if (body.glass) {
    ctx.fillStyle = cssColor(body.glass.color);
    ctx.fill(cont(body.glass.rect, body.glass.cornerRadius));
  }
}

/** Side slab at offset zero — `makeDeviceSideImage`. */
function drawSide(ctx: Ctx, videoRect: Rect) {
  const s = sideSlabRecipe(videoRect, { width: 0, height: 0 });
  if (!s) return;
  ctx.save();
  ctx.clip(cont(s.rect, s.cornerRadius));
  ctx.fillStyle = gradient(ctx, s.fill);
  ctx.fillRect(s.rect.x - 2, s.rect.y - 2, s.rect.width + 4, s.rect.height + 4);
  ctx.restore();
}

/** Seam + Dynamic Island + lens — `makeDeviceIslandImage`. */
function drawIsland(ctx: Ctx, videoRect: Rect) {
  const r = islandRecipe(videoRect);
  if (!r) return;
  ctx.lineWidth = r.seam.lineWidth;
  ctx.strokeStyle = cssColor(r.seam.color);
  ctx.stroke(cont(r.seam.rect, r.seam.cornerRadius));
  ctx.fillStyle = cssColor(r.pill.color);
  ctx.fill(toPath2D(cgPathRoundedRect(r.pill.rect, r.pill.cornerRadius, r.pill.cornerRadius)));
  ctx.fillStyle = cssColor(r.lens.color);
  ctx.fill(toPath2D(cgPathEllipse(r.lens.rect)));
  ctx.lineWidth = r.lensRing.lineWidth;
  ctx.strokeStyle = cssColor(r.lensRing.color);
  ctx.stroke(toPath2D(cgPathEllipse(r.lensRing.rect)));
}

/** Rasterizes the three layers for a screen (video) rect in card space (Y-down px). */
export function makeDeviceSprites(device: GPUDevice, videoRect: Rect, bodyRect: Rect, isPhone: boolean): DeviceSprites {
  const margin = Math.max(4, videoRect.width * 0.03);
  return {
    bezel: makeSprite(device, outset(bodyRect, margin), (c) => drawBezel(c, videoRect), "device-bezel"),
    side: makeSprite(device, outset(bodyRect, 2), (c) => drawSide(c, videoRect), "device-side"),
    island: isPhone ? makeSprite(device, outset(videoRect, 2), (c) => drawIsland(c, videoRect), "device-island") : null,
  };
}
