/**
 * Animated-GIF output policy — the port of `GIFExportPolicy`
 * (apps/macos/CaptureCat/Services/ExportFormats.swift), locked to the Swift by
 * the `gifPolicy` golden vectors (`CaptureCat --export-formats-test`,
 * ./golden/exportFormats.golden.json). The Mac's documented choice, verbatim:
 *
 *  • Frame rate: GIF delays are whole CENTISECONDS and browsers clamp delays
 *    under 2 cs up to 10 cs, so only 50, 25, 20, 10, 5, 4, 2, 1 fps keep time.
 *    A GIF runs at the fastest of those ≤ both the export fps and 20 fps
 *    (30 / 60 fps settings → 20 fps, 5 cs per frame).
 *  • Size: the export's resolved output size scaled down uniformly until the
 *    long edge is ≤ 960 px, each side rounded (Swift `.rounded()`), then made
 *    even (+1 when odd), minimum 2. 720p / 1080p / 4K at 16:9 → 960×540.
 *  • Frames: dense, frame i at output time i / fps, `max(1, ceil(duration ×
 *    fps))` frames — never collapsed. sRGB. Loops forever.
 *
 * Only palette quantization differs between the platforms (ImageIO on the
 * Mac, the median-cut encoder in engine/export/gif on the web).
 */
import { srounded } from "../math/swift";

export const GIF_MAX_FRAME_RATE = 20;
export const GIF_MAX_LONG_EDGE = 960;
/** Frame rates with an exact whole-centisecond period ≥ 2 cs, fastest first. */
export const GIF_FRAME_RATES: readonly number[] = [50, 25, 20, 10, 5, 4, 2, 1];

/** `GIFExportPolicy.frameRate(forRequested:)` */
export function gifFrameRate(requestedFps: number): number {
  const limit = Math.min(Math.max(1, Math.trunc(requestedFps)), GIF_MAX_FRAME_RATE);
  return GIF_FRAME_RATES.find((r) => r <= limit) ?? 1;
}

/** `GIFExportPolicy.delayCentiseconds(frameRate:)` */
export function gifDelayCentiseconds(frameRate: number): number {
  return Math.trunc(100 / Math.max(1, frameRate));
}

/** `GIFExportPolicy.frameSize(for:)` */
export function gifFrameSize(size: { width: number; height: number }): { width: number; height: number } {
  const width = Math.max(1, size.width);
  const height = Math.max(1, size.height);
  const scale = Math.min(1, GIF_MAX_LONG_EDGE / Math.max(width, height));
  const even = (side: number) => {
    const value = Math.max(2, Math.trunc(srounded(side * scale)));
    return value % 2 === 0 ? value : value + 1;
  };
  return { width: even(width), height: even(height) };
}

/** `GIFExportPolicy.frameCount(duration:frameRate:)` */
export function gifFrameCount(duration: number, frameRate: number): number {
  return Math.max(1, Math.ceil(Math.max(0, duration) * Math.max(1, frameRate)));
}

/** `GIFExportPolicy.caption(outputSize:requestedFPS:)` — the sheet's caption for GIF. */
export function gifCaption(outputSize: { width: number; height: number }, requestedFps: number): string {
  const s = gifFrameSize(outputSize);
  return `GIF • ${s.width}x${s.height} @ ${gifFrameRate(requestedFps)} fps • loops`;
}
