/**
 * Adapter / device bring-up with capability errors a user can act on.
 *
 * WebGPU is REQUIRED (architecture contract: no silent WebGL path in v1).
 * Every failure is a typed `EngineCapabilityError` whose message is shown
 * verbatim by the editor's "unsupported browser" screen.
 */

export type CapabilityCode =
  | "no-webgpu"
  | "no-adapter"
  | "device-failed"
  | "device-lost"
  | "no-webcodecs"
  | "codec-unsupported";

export class EngineCapabilityError extends Error {
  readonly code: CapabilityCode;
  constructor(code: CapabilityCode, message: string) {
    super(message);
    this.name = "EngineCapabilityError";
    this.code = code;
  }
}

export const BROWSER_REQUIREMENT = "Use Chrome/Edge 113+, Safari 26+, or Firefox 141+.";

export interface GpuContext {
  device: GPUDevice;
  adapterInfo: { vendor: string; architecture: string; description: string };
  /** `timestamp-query` granted — GPU pass timing is measured when true. */
  timestampQuery: boolean;
  preferredFormat: GPUTextureFormat;
  limits: { maxTextureDimension2D: number };
}

export async function initGpu(onLost: (reason: string) => void): Promise<GpuContext> {
  const gpu = (globalThis.navigator as Navigator | undefined)?.gpu;
  if (!gpu) {
    throw new EngineCapabilityError("no-webgpu", `WebGPU is not available in this browser. ${BROWSER_REQUIREMENT}`);
  }
  if (typeof VideoDecoder === "undefined" || typeof VideoFrame === "undefined") {
    throw new EngineCapabilityError(
      "no-webcodecs",
      `WebCodecs (VideoDecoder) is not available in this browser. ${BROWSER_REQUIREMENT}`,
    );
  }
  const adapter = await gpu.requestAdapter({ powerPreference: "high-performance" });
  if (!adapter) {
    throw new EngineCapabilityError(
      "no-adapter",
      "WebGPU is present but no GPU adapter is available (the GPU may be blocklisted or hardware acceleration disabled in browser settings).",
    );
  }
  const wantTimestamps = adapter.features.has("timestamp-query");
  let device: GPUDevice;
  try {
    device = await adapter.requestDevice({
      requiredFeatures: wantTimestamps ? ["timestamp-query"] : [],
      requiredLimits: {
        // 4K canvases + 4K intermediates; never ask for more than the adapter has.
        maxTextureDimension2D: Math.min(adapter.limits.maxTextureDimension2D, 8192),
      },
    });
  } catch (err) {
    throw new EngineCapabilityError("device-failed", `Could not create a WebGPU device: ${String(err)}`);
  }
  device.lost.then((info) => onLost(`${info.reason}: ${info.message}`));
  device.addEventListener("uncapturederror", (ev) => {
    const e = (ev as GPUUncapturedErrorEvent).error;
    console.error("[engine] WebGPU error:", e.message);
  });
  const info = adapter.info;
  return {
    device,
    adapterInfo: {
      vendor: info?.vendor ?? "",
      architecture: info?.architecture ?? "",
      description: info?.description ?? "",
    },
    timestampQuery: wantTimestamps,
    preferredFormat: gpu.getPreferredCanvasFormat(),
    limits: { maxTextureDimension2D: device.limits.maxTextureDimension2D },
  };
}

/**
 * Configures a canvas for the working space. Premultiplied alpha always (the
 * whole pipeline is premultiplied, like CoreImage). `display-p3` when the
 * source is P3 AND the browser accepts it; the returned space is what the
 * canvas actually got.
 */
export function configureCanvas(
  context: GPUCanvasContext,
  gpu: GpuContext,
  wanted: PredefinedColorSpace,
): PredefinedColorSpace {
  const base: GPUCanvasConfiguration = {
    device: gpu.device,
    format: gpu.preferredFormat,
    alphaMode: "premultiplied",
    // COPY_SRC: snapshots copy the exact presented texture.
    usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
    colorSpace: wanted,
  };
  try {
    context.configure(base);
    const got = context.getConfiguration?.()?.colorSpace;
    return (got as PredefinedColorSpace | undefined) ?? wanted;
  } catch {
    context.configure({ ...base, colorSpace: "srgb" });
    return "srgb";
  }
}
