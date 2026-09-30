/**
 * RasterOverlay — a CPU raster (Canvas2D / ImageBitmap) on the GPU, placed
 * in CARD space (or canvas space for overlay passes) and composited
 * premultiplied source-over. The exporter's
 * `CIImage(cgImage:).transformed(by: scale+translate).composited(over:)`:
 *
 *  - upload: `copyExternalImageToTexture` colour-matches the sRGB raster into
 *    the working space (CI colour-matches the CGImage the same way) and keeps
 *    it premultiplied.
 *  - placement: `dest` is where the raster's extent lands (card-space Y-down
 *    px); the fragment maps back through `cardToTarget⁻¹` and resamples
 *    BILINEARLY with clear-outside edges (CIAffineTransform's default
 *    sampler). A raster placed 1:1 on integer pixels samples texel centres,
 *    i.e. it is copied exactly.
 *  - `opacity` multiplies premultiplied RGBA; with `fadeImage: true` it is
 *    the exporter's `fadeImage` instead — CIColorMatrix on UNpremultiplied
 *    colour, so premultiplied RGB scales by opacity² and alpha by opacity
 *    (CoreImage: (200,100,50,255) at 0.5 → (50,25,13,128)).
 */
import type { WorkingSpace } from "../color";
import { L, Uniforms } from "../gpu/resources";
import type { Rect } from "../layout";
import { invert, toRows, type Mat3 } from "../mat3";
import type { FrameEncoder, PassContext } from "./types";

export const rasterOverlayWGSL = /* wgsl */ `
struct U {
  fwd0: vec4f, fwd1: vec4f, fwd2: vec4f,   // placement space → target homography rows
  inv0: vec4f, inv1: vec4f, inv2: vec4f,   // target → placement space
  tgt: vec4f,    // target size.xy, opacity, fadeImage (1 = RGB × opacity²)
  dest: vec4f,   // raster extent in placement space (x, y, w, h)
  tex: vec4f,    // texture size.xy, 0, 0
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var src: texture_2d<f32>;

struct VSOut { @builtin(position) pos: vec4f };

@vertex fn vs_quad(@builtin(vertex_index) i: u32) -> VSOut {
  let b = vec4f(u.dest.xy - vec2f(1.0), u.dest.zw + vec2f(2.0));
  var corners = array<vec2f, 6>(
    b.xy, b.xy + vec2f(b.z, 0.0), b.xy + vec2f(0.0, b.w),
    b.xy + vec2f(0.0, b.w), b.xy + vec2f(b.z, 0.0), b.xy + b.zw);
  let c = corners[i];
  let h = vec3f(dot(u.fwd0.xyz, vec3f(c, 1.0)), dot(u.fwd1.xyz, vec3f(c, 1.0)), dot(u.fwd2.xyz, vec3f(c, 1.0)));
  let ndc = vec2f(h.x / u.tgt.x * 2.0 - h.z, h.z - h.y / u.tgt.y * 2.0);
  var o: VSOut;
  o.pos = vec4f(ndc, 0.0, h.z);
  return o;
}

fn loadClear4(ip: vec2i, dims: vec2i) -> vec4f {
  if (ip.x < 0 || ip.y < 0 || ip.x >= dims.x || ip.y >= dims.y) { return vec4f(0.0); }
  return textureLoad(src, ip, 0);
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = in.pos.xy;
  let h = vec3f(dot(u.inv0.xyz, vec3f(p, 1.0)), dot(u.inv1.xyz, vec3f(p, 1.0)), dot(u.inv2.xyz, vec3f(p, 1.0)));
  if (h.z <= 0.0) { discard; }
  let q = h.xy / h.z;
  let local = (q - u.dest.xy) * u.tex.xy / u.dest.zw;
  let dims = vec2i(u.tex.xy);
  let s = local - vec2f(0.5);
  let i0 = vec2i(floor(s));
  let f = s - floor(s);
  let a = loadClear4(i0, dims);
  let b = loadClear4(i0 + vec2i(1, 0), dims);
  let c = loadClear4(i0 + vec2i(0, 1), dims);
  let d = loadClear4(i0 + vec2i(1, 1), dims);
  let px = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
  let rgbScale = select(u.tgt.z, u.tgt.z * u.tgt.z, u.tgt.w > 0.5);
  return vec4f(px.rgb * rgbScale, px.a * u.tgt.z);
}
`;

const USAGE = GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT;

export class RasterOverlay {
  private texture: GPUTexture | null = null;
  private view: GPUTextureView | null = null;
  private u: Uniforms | null = null;
  private group: { layout: GPUBindGroupLayout; view: GPUTextureView; group: GPUBindGroup } | null = null;
  width = 0;
  height = 0;

  constructor(private readonly label: string) {}

  /** (Re)allocates the texture for a `w × h` raster; returns true when it changed. */
  ensure(device: GPUDevice, w: number, h: number): boolean {
    const W = Math.max(1, Math.round(w));
    const H = Math.max(1, Math.round(h));
    if (this.texture && this.width === W && this.height === H) return false;
    this.texture?.destroy();
    this.texture = device.createTexture({ label: this.label, size: { width: W, height: H }, format: "rgba8unorm", usage: USAGE });
    this.view = this.texture.createView();
    this.group = null;
    this.width = W;
    this.height = H;
    return true;
  }

  get ready(): boolean {
    return this.texture !== null;
  }

  /**
   * Uploads `source` (a Canvas2D canvas or an ImageBitmap in sRGB) into the
   * texture, colour-matched into `space`. `rect` limits the copy (texture
   * and source share coordinates); defaults to the whole raster.
   */
  upload(
    device: GPUDevice,
    source: OffscreenCanvas | ImageBitmap,
    space: WorkingSpace,
    rect?: { x: number; y: number; width: number; height: number },
  ): void {
    if (!this.texture) return;
    const x = Math.max(0, Math.floor(rect?.x ?? 0));
    const y = Math.max(0, Math.floor(rect?.y ?? 0));
    const x1 = Math.min(this.width, Math.ceil((rect?.x ?? 0) + (rect?.width ?? this.width)));
    const y1 = Math.min(this.height, Math.ceil((rect?.y ?? 0) + (rect?.height ?? this.height)));
    if (x1 <= x || y1 <= y) return;
    device.queue.copyExternalImageToTexture(
      { source, origin: { x, y } },
      { texture: this.texture, origin: { x, y }, premultipliedAlpha: true, colorSpace: space },
      { width: x1 - x, height: y1 - y },
    );
  }

  /**
   * Draws the raster with its extent at `dest` (placement space), mapped to
   * the target by `toTarget` (the card → target transform for card passes,
   * identity for canvas-space overlays).
   */
  draw(ctx: PassContext, enc: FrameEncoder, dest: Rect, toTarget: Mat3, opacity = 1, fadeImage = false): void {
    if (!this.texture || !this.view || !enc.pass || !(dest.width > 0 && dest.height > 0)) return;
    const t = ctx.scene.target;
    this.u ??= new Uniforms(ctx.device, 36, `${this.label}-u`);
    this.u.write([
      ...toRows(toTarget),
      ...toRows(invert(toTarget)),
      t.width, t.height, opacity, fadeImage ? 1 : 0,
      dest.x, dest.y, dest.width, dest.height,
      this.width, this.height, 0, 0,
    ]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "raster-overlay",
      code: rasterOverlayWGSL,
      vertexEntry: "vs_quad",
      format: enc.format,
      blend: "premultipliedOver",
      entries: [L.uniform(0, true), L.unfilterable(1)],
    });
    if (!this.group || this.group.layout !== layout || this.group.view !== this.view) {
      this.group = {
        layout,
        view: this.view,
        group: ctx.device.createBindGroup({
          layout,
          entries: [
            { binding: 0, resource: { buffer: this.u.buffer } },
            { binding: 1, resource: this.view },
          ],
        }),
      };
    }
    enc.pass.setPipeline(pipeline);
    enc.pass.setBindGroup(0, this.group.group);
    enc.pass.draw(6);
  }

  destroy(): void {
    // Frames already submitted may still sample it; destroy after they finish.
    const tex = this.texture;
    this.texture = null;
    this.view = null;
    this.group = null;
    this.width = 0;
    this.height = 0;
    tex?.destroy();
    this.u?.destroy();
    this.u = null;
  }
}
