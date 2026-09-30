/**
 * VideoFitPass (stage "prepare") — `compositeFrame`'s downscale.
 *
 * The Mac fits the recording into the card with `CILanczosScaleTransform`
 * whenever `videoScale < 0.999` (plain affine upscale otherwise). This is the
 * separable two-pass twin: horizontal straight from the decoded frame
 * (texture_external, zero-copy) into rgba16float, then vertical into an
 * rgba8unorm "fitted" texture the card pass samples at its fractional
 * position. The fitted texture is reused while the frame and layout are
 * unchanged (paused, or 30 fps content on a 60 Hz display).
 */
import { L, Uniforms, type PooledTexture } from "../gpu/resources";
import { fitHorizontalWGSL, fitVerticalWGSL } from "../gpu/shaders";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "./types";

const RT = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;

export const LANCZOS_THRESHOLD = 0.999;

export class VideoFitPass implements RenderPass {
  readonly name = "video-fit";
  readonly stage = "prepare" as const;
  private hU: Uniforms | null = null;
  private vU: Uniforms | null = null;
  private hTex: PooledTexture | null = null;
  private fitted: PooledTexture | null = null;
  private key = "";
  private vGroup: GPUBindGroup | null = null;
  /** Frames actually re-fitted (vs. reused) — surfaced in stats. */
  fits = 0;
  private tables: { key: string; h: GPUBuffer; v: GPUBuffer; taps: number } | null = null;
  private vGroupKey = "";

  sceneChanged(ctx: PassContext): void {
    this.key = "";
    ctx.pool.release(this.hTex);
    ctx.pool.release(this.fitted);
    this.hTex = null;
    this.fitted = null;
    this.vGroup = null;
  }

  invalidate(): void {
    this.key = "";
  }

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const g = ctx.scene.geometry;
    const video = frame.video;
    if (!video || !enc.resources.external || g.videoScale >= LANCZOS_THRESHOLD) {
      enc.resources.fitted = null;
      return;
    }
    const srcW = video.frame.displayWidth;
    const srcH = video.frame.displayHeight;
    const s = g.videoScale;
    const dstW = Math.max(1, Math.ceil(srcW * s - 1e-4));
    const dstH = Math.max(1, Math.ceil(srcH * s - 1e-4));
    const key = `${video.index}|${video.frame.timestamp}|${srcW}x${srcH}|${s}|${ctx.scene.version}`;
    if (key === this.key && this.fitted) {
      enc.resources.fitted = this.fitted;
      return;
    }
    if (!this.hTex || this.hTex.width !== dstW || this.hTex.height !== srcH) {
      ctx.pool.release(this.hTex);
      this.hTex = ctx.pool.acquire(dstW, srcH, "rgba16float", RT, "fit-h");
      this.vGroup = null;
    }
    if (!this.fitted || this.fitted.width !== dstW || this.fitted.height !== dstH) {
      ctx.pool.release(this.fitted);
      this.fitted = ctx.pool.acquire(dstW, dstH, "rgba8unorm", RT, "fit-v");
    }
    const tables = this.weightTables(ctx.device, srcW, srcH, dstW, dstH, s);
    this.hU ??= new Uniforms(ctx.device, 4, "fit-h-u");
    this.vU ??= new Uniforms(ctx.device, 4, "fit-v-u");
    this.hU.write([tables.taps, srcW - 1, 0, 0]);
    this.vU.write([tables.taps, srcH - 1, 0, 0]);

    const h = ctx.pipelines.get({
      id: "fit-h", code: fitHorizontalWGSL, format: "rgba16float", blend: "replace",
      entries: [L.uniform(0), L.external(1), L.storage(2)],
    });
    const hp = enc.beginPass({
      label: "video-fit-h",
      colorAttachments: [{ view: this.hTex.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
    });
    hp.setPipeline(h.pipeline);
    hp.setBindGroup(0, ctx.device.createBindGroup({
      layout: h.layout,
      entries: [
        { binding: 0, resource: { buffer: this.hU.buffer } },
        { binding: 1, resource: enc.resources.external },
        { binding: 2, resource: { buffer: tables.h } },
      ],
    }));
    hp.draw(3);
    hp.end();

    const v = ctx.pipelines.get({
      id: "fit-v", code: fitVerticalWGSL, format: "rgba8unorm", blend: "replace",
      entries: [L.uniform(0), L.texture(1), L.storage(2)],
    });
    const vKey = `${tables.key}|${this.hTex.key}`;
    if (!this.vGroup || this.vGroupKey !== vKey) {
      this.vGroup = ctx.device.createBindGroup({
        layout: v.layout,
        entries: [
          { binding: 0, resource: { buffer: this.vU.buffer } },
          { binding: 1, resource: this.hTex.view },
          { binding: 2, resource: { buffer: tables.v } },
        ],
      });
      this.vGroupKey = vKey;
    }
    const vp = enc.beginPass({
      label: "video-fit-v",
      colorAttachments: [{ view: this.fitted.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
    });
    vp.setPipeline(v.pipeline);
    vp.setBindGroup(0, this.vGroup);
    vp.draw(3);
    vp.end();

    this.key = key;
    this.fits++;
    enc.resources.fitted = this.fitted;
  }

  /**
   * Tap tables for both axes: per output pixel `[first, w0 … wN−1]`. Built on
   * the CPU once per (source size, scale) with the kernel of
   * `testing/cpuReference.lanczosEdge` — out-of-extent taps count in the
   * normaliser but carry weight 0 (CoreImage clear-outside semantics).
   */
  private weightTables(device: GPUDevice, srcW: number, srcH: number, dstW: number, dstH: number, s: number) {
    const key = `${srcW}x${srcH}|${dstW}x${dstH}|${s}`;
    if (this.tables?.key === key) return this.tables;
    this.tables?.h.destroy();
    this.tables?.v.destroy();
    const taps = Math.ceil((2 * 3) / s) + 1;
    const build = (dst: number, srcLen: number) => {
      const data = new Float32Array(dst * (taps + 1));
      for (let o = 0; o < dst; o++) {
        const row = lanczosRow(o, s, srcLen, taps);
        data.set(row, o * (taps + 1));
      }
      const buf = device.createBuffer({ size: data.byteLength, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
      device.queue.writeBuffer(buf, 0, data);
      return buf;
    };
    this.tables = { key, h: build(dstW, srcW), v: build(dstH, srcH), taps };
    this.vGroup = null;
    return this.tables;
  }

  destroy(): void {
    this.hU?.destroy();
    this.vU?.destroy();
    this.tables?.h.destroy();
    this.tables?.v.destroy();
  }
}

function lanczos3(x: number): number {
  const ax = Math.abs(x);
  if (ax < 1e-6) return 1;
  if (ax >= 3) return 0;
  const px = Math.PI * x;
  return (3 * Math.sin(px) * Math.sin(px / 3)) / (px * px);
}

/**
 * One output pixel's taps: `[first, w…]` with `taps` weights. The kernel is
 * centred on the output pixel's source-space centre c = (o + ½)/s and spans
 * 3/s source pixels each side (Lanczos-3 stretched for minification).
 */
export function lanczosRow(o: number, s: number, srcLen: number, taps: number): Float32Array {
  const out = new Float32Array(taps + 1);
  const c = (o + 0.5) / s;
  const support = 3 / s;
  const i0 = Math.ceil(c - 0.5 - support);
  const i1 = Math.floor(c - 0.5 + support);
  let sum = 0;
  for (let i = i0; i <= i1; i++) sum += lanczos3((i + 0.5 - c) * s);
  out[0] = i0;
  for (let i = i0; i <= i1 && i - i0 < taps; i++) {
    const w = lanczos3((i + 0.5 - c) * s) / sum;
    out[1 + i - i0] = i >= 0 && i < srcLen ? w : 0;
  }
  return out;
}
