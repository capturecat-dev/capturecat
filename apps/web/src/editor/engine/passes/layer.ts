/**
 * LayerComposePass — the card layer resampled through the camera homography
 * over the backdrop (Mac: tilt warp → card-only zoom about the focal point →
 * crop to the canvas → offset → intro slide → motion blur, then
 * `composited(over: frameBackground)`).
 *
 * Bilinear with clear outside. (The Mac switches to Lanczos for zoom < 1;
 * bilinear here.)
 *
 * Motion blur (FrameState.motionBlur) needs the warped card as a texture, so
 * `prepare` — encoded BEFORE the canvas pass — warps into an intermediate and,
 * for large radii, box-prefilters it along the motion; `encode` then draws the
 * Gaussian taps over the backdrop. Without blur `prepare` is a no-op and
 * `encode` warps straight onto the canvas.
 */
import { L, Uniforms, type PooledTexture } from "../gpu/resources";
import { layerComposeWGSL, motionBlurWGSL } from "../gpu/shaders";
import { apply, IDENTITY, invert, toRows, type Mat3 } from "../mat3";
import type { FrameEncoder, FrameState, PassContext } from "./types";

const RT = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;

/** σ above which the blur switches to box prefilter + sparse Gaussian taps. */
const DIRECT_SIGMA = 6;
/** Sparse Gaussian: taps per σ each side (step = σ / TAPS_PER_SIGMA). */
const TAPS_PER_SIGMA = 6;
/** Kernel support in σ each side (CI's measured span is ≈ 3.5–4 σ). */
const SUPPORT = 4;

/** CIMotionBlur's total weight by radius band (impulse response, macOS 26). */
export function motionBlurGain(radius: number): number {
  if (radius < 3.97) return 1;
  if (radius < 16.2) return 0.9934;
  if (radius < 60) return 0.99767;
  return 0.9891;
}

interface BlurPlan {
  dir: [number, number];
  sigma: number;
  gain: number;
  /** Box prefilter width (px) — 0 when the Gaussian taps run at unit steps. */
  box: number;
  step: number;
  n: number;
}

export function planMotionBlur(radius: number, angle: number): BlurPlan {
  const dir: [number, number] = [Math.cos(angle), Math.sin(angle)];
  const gain = motionBlurGain(radius);
  if (radius <= DIRECT_SIGMA) {
    return { dir, sigma: Math.max(radius, 1e-3), gain, box: 0, step: 1, n: Math.max(1, Math.ceil(SUPPORT * radius)) };
  }
  const step = radius / TAPS_PER_SIGMA;
  // The box adds step²/12 of variance; the Gaussian makes up the rest.
  const sigma = Math.sqrt(Math.max(1e-6, radius * radius - (step * step) / 12));
  return { dir, sigma, gain, box: step, step, n: SUPPORT * TAPS_PER_SIGMA };
}

const NO_CLAMP = [-1e9, -1e9, 1e9, 1e9];

/**
 * Pixel-centre clamp bounds of the card's extent in target space: the canvas
 * rect carried through the post-crop transforms (offset / intro), bounding
 * box rounded OUT to whole pixels (CI's integral extent).
 */
export function clampBounds(clip: Mat3 | null | undefined, width: number, height: number): number[] {
  const post = clip ? invert(clip) : IDENTITY;
  const pts = [apply(post, 0, 0), apply(post, width, 0), apply(post, 0, height), apply(post, width, height)];
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  const eps = 1e-6;
  return [
    Math.floor(Math.min(...xs) + eps) + 0.5,
    Math.floor(Math.min(...ys) + eps) + 0.5,
    Math.ceil(Math.max(...xs) - eps) - 0.5,
    Math.ceil(Math.max(...ys) - eps) - 0.5,
  ];
}

export class LayerComposePass {
  readonly name = "layer-compose";
  private u: Uniforms | null = null;
  private warpU: Uniforms | null = null;
  private boxU: Uniforms | null = null;
  private tapU: Uniforms | null = null;
  private warped: PooledTexture | null = null;
  private boxed: PooledTexture | null = null;
  private plan: BlurPlan | null = null;
  private ext: number[] = NO_CLAMP;

  private writeWarp(u: Uniforms, frame: FrameState, ctx: PassContext): void {
    const clip = frame.cameraClip ?? null;
    const { width, height } = ctx.scene.target;
    u.write([
      ...toRows(invert(frame.camera)),
      ...toRows(clip ?? IDENTITY),
      width, height, clip ? 1 : 0, 0,
    ]);
  }

  private drawWarp(ctx: PassContext, pass: GPURenderPassEncoder, format: GPUTextureFormat, blend: "replace" | "premultipliedOver", u: Uniforms, layer: PooledTexture): void {
    const { pipeline, layout } = ctx.pipelines.get({
      id: "layer-compose", code: layerComposeWGSL, format, blend,
      entries: [L.uniform(0), L.texture(1)],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: u.buffer } },
        { binding: 1, resource: layer.view },
      ],
    }));
    pass.draw(3);
  }

  private drawBlur(ctx: PassContext, pass: GPURenderPassEncoder, format: GPUTextureFormat, blend: "replace" | "premultipliedOver", u: Uniforms, src: PooledTexture): void {
    const { pipeline, layout } = ctx.pipelines.get({
      id: "motion-blur", code: motionBlurWGSL, format, blend,
      entries: [L.uniform(0), L.sampler(1), L.texture(2)],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: u.buffer } },
        { binding: 1, resource: ctx.pipelines.linearSampler() },
        { binding: 2, resource: src.view },
      ],
    }));
    pass.draw(3);
  }

  /** Before the canvas pass: warp (+ box prefilter) into intermediates when the frame is motion-blurred. */
  prepare(ctx: PassContext, frame: FrameState, enc: FrameEncoder, layer: PooledTexture): void {
    this.plan = null;
    const mb = frame.motionBlur;
    if (!mb || !frame.video) return;
    const plan = planMotionBlur(mb.radius, mb.angle);
    const { width, height } = ctx.scene.target;
    const ext = clampBounds(frame.cameraClip, width, height);
    this.warped = ctx.pool.acquire(width, height, "rgba16float", RT, "card-warped");
    this.warpU ??= new Uniforms(ctx.device, 28, "layer-warp-u");
    this.writeWarp(this.warpU, frame, ctx);
    const wp = enc.beginPass({
      label: "card-warp",
      colorAttachments: [{ view: this.warped.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
    });
    this.drawWarp(ctx, wp, "rgba16float", "replace", this.warpU, layer);
    wp.end();
    if (plan.box > 0) {
      this.boxed = ctx.pool.acquire(width, height, "rgba16float", RT, "card-blur-box");
      this.boxU ??= new Uniforms(ctx.device, 12, "motion-blur-box-u");
      this.boxU.write([plan.dir[0], plan.dir[1], plan.box, Math.max(1, Math.ceil(plan.box)), 0, 1, 1, 0, ...ext]);
      const bp = enc.beginPass({
        label: "card-blur-box",
        colorAttachments: [{ view: this.boxed.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      });
      this.drawBlur(ctx, bp, "rgba16float", "replace", this.boxU, this.warped);
      bp.end();
    }
    this.plan = plan;
    // The prefiltered texture already holds the clamped image everywhere.
    this.ext = plan.box > 0 ? NO_CLAMP : ext;
  }

  /** Inside the canvas pass: the warped (and blurred) card over the backdrop. */
  encode(ctx: PassContext, frame: FrameState, pass: GPURenderPassEncoder, format: GPUTextureFormat, layer: PooledTexture) {
    const plan = this.plan;
    if (plan && this.warped) {
      this.tapU ??= new Uniforms(ctx.device, 12, "motion-blur-tap-u");
      this.tapU.write([plan.dir[0], plan.dir[1], plan.step, plan.n, plan.sigma, plan.gain, 0, 0, ...this.ext]);
      this.drawBlur(ctx, pass, format, "premultipliedOver", this.tapU, this.boxed ?? this.warped);
      return;
    }
    this.u ??= new Uniforms(ctx.device, 28, "layer-u");
    this.writeWarp(this.u, frame, ctx);
    this.drawWarp(ctx, pass, format, "premultipliedOver", this.u, layer);
  }

  /** After the canvas pass is encoded: return the intermediates to the pool. */
  finish(ctx: PassContext): void {
    ctx.pool.release(this.warped);
    ctx.pool.release(this.boxed);
    this.warped = null;
    this.boxed = null;
    this.plan = null;
  }

  destroy(): void {
    this.u?.destroy();
    this.warpU?.destroy();
    this.boxU?.destroy();
    this.tapU?.destroy();
  }
}
