/**
 * Card-space sprites — scene-static rasters (device bezel, side slab,
 * Dynamic Island, replacement menu bar) drawn as textured quads through
 * `FrameEncoder.cardToTarget`, so they ride the camera warp with the card.
 *
 * Rasters are made ONCE per scene with Canvas2D (OffscreenCanvas works in the
 * worker), carry a transparent margin so bilinear sampling fades to clear at
 * the edges (CoreImage clear-outside), and are uploaded premultiplied.
 */
import { invert, toRows, type Mat3 } from "../mat3";
import { L, Uniforms } from "../gpu/resources";
import type { PathElement } from "../../core/math/styleSupport";
import type { PassContext } from "./types";

export interface Sprite {
  texture: GPUTexture;
  view: GPUTextureView;
  /** Card-space rect (Y-down px) the whole texture covers. */
  x: number;
  y: number;
  width: number;
  height: number;
}

type AnyPathElement = PathElement | { type: PathElement["op"]; points: { x: number; y: number }[] };

/** Path elements (core CGPath ports — either element shape, any space) → Path2D. */
export function toPath2D(elements: readonly AnyPathElement[], path = new Path2D()): Path2D {
  for (const e of elements) {
    const p = "pts" in e ? e.pts : e.points;
    const op = "op" in e ? e.op : e.type;
    switch (op) {
      case "move":
        path.moveTo(p[0].x, p[0].y);
        break;
      case "line":
        path.lineTo(p[0].x, p[0].y);
        break;
      case "quad":
        path.quadraticCurveTo(p[0].x, p[0].y, p[1].x, p[1].y);
        break;
      case "curve":
        path.bezierCurveTo(p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y);
        break;
      case "close":
        path.closePath();
        break;
    }
  }
  return path;
}

/** CSS colour for straight sRGB 0…1 components. */
export function cssColor(c: { red: number; green: number; blue: number; alpha: number }): string {
  const q = (v: number) => (Math.max(0, Math.min(1, v)) * 255).toFixed(3);
  return `rgba(${q(c.red)}, ${q(c.green)}, ${q(c.blue)}, ${Math.max(0, Math.min(1, c.alpha))})`;
}

/**
 * Rasterizes `draw` over the card-space `bounds` at `scale` raster px per card
 * px (1 = pixel-aligned to the target grid), with a 2-raster-px clear margin,
 * and uploads it. `draw` receives a context already translated/scaled so it
 * can paint in card-space coordinates.
 */
export function makeSprite(
  device: GPUDevice,
  bounds: { x: number; y: number; width: number; height: number },
  draw: (ctx: OffscreenCanvasRenderingContext2D) => void,
  label: string,
  scale = 1,
): Sprite | null {
  if (!(bounds.width > 0 && bounds.height > 0)) return null;
  const x0 = Math.floor(bounds.x) - 2 / scale;
  const y0 = Math.floor(bounds.y) - 2 / scale;
  const x1 = Math.ceil(bounds.x + bounds.width) + 2 / scale;
  const y1 = Math.ceil(bounds.y + bounds.height) + 2 / scale;
  const w = Math.max(1, Math.round((x1 - x0) * scale));
  const h = Math.max(1, Math.round((y1 - y0) * scale));
  const canvas = new OffscreenCanvas(w, h);
  const ctx = canvas.getContext("2d", { colorSpace: "srgb" });
  if (!ctx) return null;
  ctx.setTransform(scale, 0, 0, scale, -x0 * scale, -y0 * scale);
  draw(ctx);
  const texture = device.createTexture({
    label,
    size: { width: w, height: h },
    format: "rgba8unorm",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
  });
  device.queue.copyExternalImageToTexture(
    { source: canvas },
    { texture, colorSpace: "srgb", premultipliedAlpha: true },
    { width: w, height: h },
  );
  return { texture, view: texture.createView(), x: x0, y: y0, width: w / scale, height: h / scale };
}

/** Destroys sprites after the GPU finished with any frame that used them. */
export function destroySprites(device: GPUDevice, sprites: (Sprite | null | undefined)[]): void {
  const live = sprites.filter((s): s is Sprite => !!s);
  if (live.length) device.queue.onSubmittedWorkDone().then(() => live.forEach((s) => s.texture.destroy()));
}

export const spriteWGSL = /* wgsl */ `
struct SpriteU {
  fwd0: vec4f, fwd1: vec4f, fwd2: vec4f,   // card → target
  inv0: vec4f, inv1: vec4f, inv2: vec4f,   // target → card
  tgt: vec4f,     // target size.xy, opacity, 0
  rect: vec4f,    // card-space rect the texture covers
  offset: vec4f,  // extra card-space translation (device side slab), 0, 0
};
@group(0) @binding(0) var<uniform> u: SpriteU;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var tex: texture_2d<f32>;

struct Out { @builtin(position) pos: vec4f };

@vertex fn vs_sprite(@builtin(vertex_index) i: u32) -> Out {
  let b = vec4f(u.rect.xy + u.offset.xy - vec2f(1.0), u.rect.zw + vec2f(2.0));
  var corners = array<vec2f, 6>(
    b.xy, b.xy + vec2f(b.z, 0.0), b.xy + vec2f(0.0, b.w),
    b.xy + vec2f(0.0, b.w), b.xy + vec2f(b.z, 0.0), b.xy + b.zw);
  let c = corners[i];
  let h = vec3f(dot(u.fwd0.xyz, vec3f(c, 1.0)), dot(u.fwd1.xyz, vec3f(c, 1.0)), dot(u.fwd2.xyz, vec3f(c, 1.0)));
  var o: Out;
  o.pos = vec4f(h.x / u.tgt.x * 2.0 - h.z, h.z - h.y / u.tgt.y * 2.0, 0.0, h.z);
  return o;
}

@fragment fn fs_sprite(in: Out) -> @location(0) vec4f {
  let p = in.pos.xy;
  let h = vec3f(dot(u.inv0.xyz, vec3f(p, 1.0)), dot(u.inv1.xyz, vec3f(p, 1.0)), dot(u.inv2.xyz, vec3f(p, 1.0)));
  let q = h.xy / h.z - u.offset.xy;
  let uv = (q - u.rect.xy) / u.rect.zw;
  if (any(uv < vec2f(0.0)) || any(uv > vec2f(1.0))) { discard; }
  return textureSampleLevel(tex, samp, uv, 0.0) * u.tgt.z;
}
`;

/** Draws sprites into the current render pass of a card-stage (or bake) encoder. */
export class SpriteDrawer {
  private us: Uniforms[] = [];
  private used = 0;
  private groups = new Map<number, WeakMap<GPUTextureView, GPUBindGroup>>();

  /** Call once per frame before the first `draw`. */
  begin(): void {
    this.used = 0;
  }

  draw(
    ctx: Pick<PassContext, "device" | "pipelines" | "scene">,
    pass: GPURenderPassEncoder,
    format: GPUTextureFormat,
    cardToTarget: Mat3,
    target: { width: number; height: number },
    sprite: Sprite,
    opts: { offsetX?: number; offsetY?: number; opacity?: number } = {},
  ): void {
    const fwd = cardToTarget;
    const inv = invert(fwd);
    if (this.used >= this.us.length) this.us.push(new Uniforms(ctx.device, 36, "sprite-u"));
    const u = this.us[this.used++];
    u.write([
      ...toRows(fwd),
      ...toRows(inv),
      target.width, target.height, opts.opacity ?? 1, 0,
      sprite.x, sprite.y, sprite.width, sprite.height,
      opts.offsetX ?? 0, opts.offsetY ?? 0, 0, 0,
    ]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "card-sprite",
      code: spriteWGSL,
      vertexEntry: "vs_sprite",
      fragmentEntry: "fs_sprite",
      format,
      blend: "premultipliedOver",
      entries: [L.uniform(0, true), L.sampler(1), L.texture(2)],
    });
    // Bind groups are keyed by (uniform slot, sprite view) and survive frames.
    const slot = this.used - 1;
    let bySlot = this.groups.get(slot);
    if (!bySlot) {
      bySlot = new WeakMap();
      this.groups.set(slot, bySlot);
    }
    let group = bySlot.get(sprite.view);
    if (!group) {
      group = ctx.device.createBindGroup({
        layout,
        entries: [
          { binding: 0, resource: { buffer: u.buffer } },
          { binding: 1, resource: ctx.pipelines.linearSampler() },
          { binding: 2, resource: sprite.view },
        ],
      });
      bySlot.set(sprite.view, group);
    }
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, group);
    pass.draw(6);
  }

  destroy(): void {
    this.us.forEach((u) => u.destroy());
    this.us = [];
    this.groups.clear();
  }
}
