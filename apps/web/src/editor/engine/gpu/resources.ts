/**
 * Pipeline + bind-group-layout caching and a texture pool.
 *
 * Pipelines are created once per (shader, target format, blend) and reused
 * for the device's lifetime — creation is the expensive part of WebGPU and
 * must never happen per frame. Textures for intermediates come from the pool
 * keyed by (size, format, usage) so resizes / re-bakes recycle memory
 * instead of churning allocations.
 */

export type BlendMode = "replace" | "premultipliedOver" | "add";

const PREMULTIPLIED_OVER: GPUBlendState = {
  color: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
  alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
};

/** (one, one) — accumulating weighted layers (Depth Focus levels). */
const ADDITIVE: GPUBlendState = {
  color: { srcFactor: "one", dstFactor: "one", operation: "add" },
  alpha: { srcFactor: "one", dstFactor: "one", operation: "add" },
};

export interface PipelineSpec {
  /** Stable id of the WGSL source (the cache key — not the source text). */
  id: string;
  code: string;
  vertexEntry?: string;
  fragmentEntry?: string;
  format: GPUTextureFormat;
  blend: BlendMode;
  /** Explicit layout entries for group 0 (explicit layouts let bind groups be shared). */
  entries: GPUBindGroupLayoutEntry[];
}

export class PipelineCache {
  private modules = new Map<string, GPUShaderModule>();
  private pipelines = new Map<string, { pipeline: GPURenderPipeline; layout: GPUBindGroupLayout }>();
  private sampler?: GPUSampler;
  constructor(private readonly device: GPUDevice) {}

  get(spec: PipelineSpec): { pipeline: GPURenderPipeline; layout: GPUBindGroupLayout } {
    const key = `${spec.id}|${spec.format}|${spec.blend}|${spec.vertexEntry ?? "vs_fullscreen"}`;
    const hit = this.pipelines.get(key);
    if (hit) return hit;
    let module = this.modules.get(spec.id);
    if (!module) {
      module = this.device.createShaderModule({ label: spec.id, code: spec.code });
      this.modules.set(spec.id, module);
    }
    const layout = this.device.createBindGroupLayout({ label: `${spec.id}-bgl`, entries: spec.entries });
    const pipeline = this.device.createRenderPipeline({
      label: key,
      layout: this.device.createPipelineLayout({ bindGroupLayouts: [layout] }),
      vertex: { module, entryPoint: spec.vertexEntry ?? "vs_fullscreen" },
      fragment: {
        module,
        entryPoint: spec.fragmentEntry ?? "fs_main",
        targets: [{
          format: spec.format,
          blend: spec.blend === "premultipliedOver" ? PREMULTIPLIED_OVER : spec.blend === "add" ? ADDITIVE : undefined,
        }],
      },
      primitive: { topology: "triangle-list" },
    });
    const entry = { pipeline, layout };
    this.pipelines.set(key, entry);
    return entry;
  }

  /** Shared linear/clamp sampler (CoreImage's default sampler is linear). */
  linearSampler(): GPUSampler {
    this.sampler ??= this.device.createSampler({
      label: "linear-clamp",
      magFilter: "linear",
      minFilter: "linear",
      addressModeU: "clamp-to-edge",
      addressModeV: "clamp-to-edge",
    });
    return this.sampler;
  }
}

// ── Bind group layout entry helpers ─────────────────────────────────────────

const FS = GPUShaderStage.FRAGMENT;
export const L = {
  uniform: (binding: number, vertexToo = false): GPUBindGroupLayoutEntry => ({
    binding,
    visibility: vertexToo ? FS | GPUShaderStage.VERTEX : FS,
    buffer: { type: "uniform" },
  }),
  texture: (binding: number, sampleType: GPUTextureSampleType = "float"): GPUBindGroupLayoutEntry => ({
    binding,
    visibility: FS,
    texture: { sampleType },
  }),
  unfilterable: (binding: number): GPUBindGroupLayoutEntry => ({
    binding,
    visibility: FS,
    texture: { sampleType: "unfilterable-float" },
  }),
  external: (binding: number): GPUBindGroupLayoutEntry => ({ binding, visibility: FS, externalTexture: {} }),
  storage: (binding: number): GPUBindGroupLayoutEntry => ({ binding, visibility: FS, buffer: { type: "read-only-storage" } }),
  sampler: (binding: number): GPUBindGroupLayoutEntry => ({ binding, visibility: FS, sampler: { type: "filtering" } }),
};

// ── Texture pool ────────────────────────────────────────────────────────────

export interface PooledTexture {
  texture: GPUTexture;
  view: GPUTextureView;
  width: number;
  height: number;
  format: GPUTextureFormat;
  key: string;
}

export class TexturePool {
  private free = new Map<string, PooledTexture[]>();
  private live = new Set<PooledTexture>();
  private bytes = 0;
  constructor(private readonly device: GPUDevice) {}

  acquire(width: number, height: number, format: GPUTextureFormat, usage: number, label: string): PooledTexture {
    const w = Math.max(1, Math.ceil(width));
    const h = Math.max(1, Math.ceil(height));
    const key = `${w}x${h}|${format}|${usage}`;
    const list = this.free.get(key);
    const reused = list?.pop();
    if (reused) {
      this.live.add(reused);
      return reused;
    }
    const texture = this.device.createTexture({ label, size: { width: w, height: h }, format, usage });
    const t: PooledTexture = { texture, view: texture.createView(), width: w, height: h, format, key };
    this.bytes += w * h * bytesPerPixel(format);
    this.live.add(t);
    return t;
  }

  release(t: PooledTexture | null | undefined): void {
    if (!t || !this.live.has(t)) return;
    this.live.delete(t);
    const list = this.free.get(t.key) ?? [];
    list.push(t);
    this.free.set(t.key, list);
  }

  /** Destroys every free texture (after a resize the old sizes are dead weight). */
  trim(): void {
    for (const list of this.free.values()) {
      for (const t of list) {
        this.bytes -= t.width * t.height * bytesPerPixel(t.format);
        t.texture.destroy();
      }
    }
    this.free.clear();
  }

  get residentBytes(): number {
    return this.bytes;
  }

  destroy(): void {
    this.trim();
    for (const t of this.live) t.texture.destroy();
    this.live.clear();
    this.bytes = 0;
  }
}

function bytesPerPixel(format: GPUTextureFormat): number {
  switch (format) {
    case "r8unorm":
      return 1;
    case "r16float":
      return 2;
    case "rgba16float":
      return 8;
    case "rgba32float":
      return 16;
    default:
      return 4;
  }
}

/** A uniform buffer with a CPU mirror; `write` uploads only on change. */
export class Uniforms {
  readonly buffer: GPUBuffer;
  private readonly data: Float32Array<ArrayBuffer>;
  private last: Float32Array<ArrayBuffer>;
  constructor(private readonly device: GPUDevice, floats: number, label: string) {
    this.data = new Float32Array(new ArrayBuffer(floats * 4));
    this.last = new Float32Array(new ArrayBuffer(floats * 4)).fill(Number.NaN);
    this.buffer = device.createBuffer({ label, size: floats * 4, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  }
  write(values: ArrayLike<number>): void {
    this.data.set(values);
    let same = true;
    for (let i = 0; i < this.data.length; i++) {
      if (this.data[i] !== this.last[i]) {
        same = false;
        break;
      }
    }
    if (same) return;
    this.last.set(this.data);
    this.device.queue.writeBuffer(this.buffer, 0, this.data);
  }
  destroy(): void {
    this.buffer.destroy();
  }
}
