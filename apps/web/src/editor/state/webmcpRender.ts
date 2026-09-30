/**
 * `render_frames` pixels for WebMCP. Argument validation, sample times,
 * captions, header and contact-sheet layout are the Mac's
 * (webmcp/ops/render.ts, proved against the real server); this module only
 * produces the pixels: the web preview and web export run the SAME passes,
 * so a paused, exactly-seeked engine snapshot at an OUTPUT time is the export
 * frame (at preview resolution, downscaled to maxWidth like the Mac's
 * `generator.maximumSize`).
 */
import type { EngineClient } from "../engine/client";
import type { SnapshotResult } from "../engine/protocol";
import {
  clampFrameTime,
  contactSheetLabel,
  contactSheetLayout,
  frameCaption,
  renderFramesHeader,
  renderFrameTimes,
  resultJSON,
  ToolError,
  type RenderFramesRequest,
} from "../webmcp/ops";

export type McpContent = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };

function snapshotCanvas(s: SnapshotResult): OffscreenCanvas {
  const c = new OffscreenCanvas(s.width, s.height);
  const ctx = c.getContext("2d")!;
  // Snapshot pixels are premultiplied; ImageData wants straight alpha.
  const src = new Uint8ClampedArray(s.rgba);
  const out = new Uint8ClampedArray(src.length);
  for (let i = 0; i < src.length; i += 4) {
    const a = src[i + 3];
    const k = a > 0 ? 255 / a : 0;
    out[i] = src[i] * k;
    out[i + 1] = src[i + 1] * k;
    out[i + 2] = src[i + 2] * k;
    out[i + 3] = a;
  }
  ctx.putImageData(new ImageData(out, s.width, s.height, { colorSpace: s.colorSpace }), 0, 0);
  return c;
}

async function encode(canvas: OffscreenCanvas, jpeg: boolean, quality: number): Promise<string> {
  const blob = await canvas.convertToBlob(jpeg ? { type: "image/jpeg", quality } : { type: "image/png" });
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

/** Aspect-fit into maxW × maxH (never upscales), like maximumSize. */
function fit(src: OffscreenCanvas, maxW: number, maxH: number): OffscreenCanvas {
  const k = Math.min(1, maxW / src.width, maxH / src.height);
  if (k >= 1) return src;
  const c = new OffscreenCanvas(Math.max(1, Math.round(src.width * k)), Math.max(1, Math.round(src.height * k)));
  const ctx = c.getContext("2d")!;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(src, 0, 0, c.width, c.height);
  return c;
}

/**
 * Renders the request through the engine. `duration` is the engine's export
 * length (OUTPUT); `sourceOf` maps OUTPUT → SOURCE for the captions.
 */
export async function renderFrames(
  client: EngineClient,
  request: RenderFramesRequest,
  duration: number,
  sourceOf: (t: number) => number,
): Promise<McpContent[]> {
  if (!(duration > 0)) throw new ToolError("the render has no duration — nothing to show");
  const times = renderFrameTimes(request, duration);

  const wasPlaying = !!client.transport?.playing;
  const restoreTime = client.transport?.time ?? 0;
  if (wasPlaying) client.pause();
  const frames: Array<{ canvas: OffscreenCanvas; output: number; source: number }> = [];
  try {
    for (const t of times) {
      const seeked = await client.seek(clampFrameTime(t, duration));
      const snap = await client.snapshot();
      const output = seeked.time;
      frames.push({ canvas: snapshotCanvas(snap), output, source: sourceOf(output) });
    }
  } finally {
    await client.seek(restoreTime);
  }

  const aspect = frames[0] ? frames[0].canvas.width / Math.max(1, frames[0].canvas.height) : 16 / 9;
  const mime = request.jpeg ? "image/jpeg" : "image/png";
  const sheetLayout = request.sheet ? contactSheetLayout(frames.length, aspect, request.maxEdge) : null;
  const header = renderFramesHeader({ freshlyRendered: true, duration, layout: request.layout, frames, sheetLayout });
  // The web renders live (no export cache) — say what it is.
  header.render = "web engine (preview == export passes)";

  if (sheetLayout) {
    const L = sheetLayout;
    const sheet = new OffscreenCanvas(Math.trunc(L.size.width), Math.trunc(L.size.height));
    const ctx = sheet.getContext("2d")!;
    ctx.fillStyle = "rgb(28,28,31)"; // sRGB (0.11, 0.11, 0.12)
    ctx.fillRect(0, 0, sheet.width, sheet.height);
    ctx.imageSmoothingQuality = "high";
    frames.forEach((f, index) => {
      const column = index % L.columns;
      const row = Math.floor(index / L.columns);
      const x = L.gap + column * (L.tile.width + L.gap);
      const y = L.gap + row * (L.tile.height + L.captionHeight + L.gap);
      const imageAspect = f.canvas.width / Math.max(1, f.canvas.height);
      let [dx, dy, dw, dh] = [x, y, L.tile.width, L.tile.height];
      if (imageAspect > L.tile.width / L.tile.height) {
        dh = L.tile.width / imageAspect;
        dy = y + (L.tile.height - dh) / 2;
      } else {
        dw = L.tile.height * imageAspect;
        dx = x + (L.tile.width - dw) / 2;
      }
      ctx.drawImage(f.canvas, dx, dy, dw, dh);
      const cy = y + L.tile.height;
      ctx.fillStyle = "#000";
      ctx.fillRect(x, cy, L.tile.width, L.captionHeight);
      ctx.save();
      ctx.beginPath();
      ctx.rect(x, cy, L.tile.width, L.captionHeight);
      ctx.clip();
      ctx.fillStyle = "#fff";
      ctx.font = `600 ${L.fontSize}px -apple-system, system-ui, sans-serif`;
      ctx.textBaseline = "middle";
      ctx.fillText(contactSheetLabel(index, f.output, f.source), x + L.fontSize * 0.5, cy + L.captionHeight / 2);
      ctx.restore();
    });
    return [
      { type: "text", text: resultJSON(header) },
      { type: "image", data: await encode(sheet, request.jpeg, request.quality), mimeType: mime },
    ];
  }

  const content: McpContent[] = [{ type: "text", text: resultJSON(header) }];
  for (const [index, f] of frames.entries()) {
    content.push({ type: "text", text: frameCaption(index, f.output, f.source) });
    content.push({ type: "image", data: await encode(fit(f.canvas, request.maxEdge, request.maxEdge), request.jpeg, request.quality), mimeType: mime });
  }
  return content;
}
