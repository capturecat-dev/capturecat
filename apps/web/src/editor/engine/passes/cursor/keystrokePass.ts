/**
 * KeystrokePillPass (stage "card") — the shortcut-overlay pill ("⌘⇧S") the
 * exporter burns after subtitles and before annotations
 * (`KeystrokeOverlayRenderer.image(canvasSize: outputSize, …, scale:
 * canvasScale, rasterScale: 1)` composited over the card, so it rides the
 * camera warp).
 *
 * Numbers — which pill, alpha, entry, pop, slide, rect, pill size, font size,
 * kern, baseline — come from core/math/keystrokeOverlay (locked to Swift).
 * Pixels: the pill is replayed on a Canvas2D exactly as `drawPill` paints it
 * (stadium path, fill sRGB (0.07, 0.07, 0.08, 0.82), centred 1·scale stroke
 * white 0.14, white semibold system text with CoreText kern), with the pop
 * scale in the CTM; the pill's alpha (the CG transparency layer's composite
 * alpha) is applied on the GPU, quantized like the 8-bit CG raster.
 *
 * Text: CoreText's SF Pro (`.AppleSystemUIFontDemi`) vs the browser's
 * `system-ui` 600 — the same face on macOS; metrics are measured with
 * Canvas2D (`letterSpacing` = kern, which Chrome adds after every glyph like
 * CT's trailing kern). Glyph AA may differ by a few levels; elsewhere
 * `system-ui` is not SF and widths differ.
 */
import { L, Uniforms } from "../../gpu/resources";
import {
  activePill,
  drawKeystrokePill,
  pillFontSize,
  pillKern,
  type KeystrokeTextMetrics,
} from "../../../core/math/keystrokeOverlay";
import { RecordingContext, type DrawOp, type PathElements } from "../../../core/math/overlaySupport";
import type { Size } from "../../../core/model/types";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "../types";
import { quadBlock } from "./passMath";
import { cursorSceneData } from "./cursorScene";
import { keystrokeWGSL } from "./shaders";

export const PILL_FONT_FAMILY = 'system-ui, -apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif';

let measureCtx: OffscreenCanvasRenderingContext2D | null = null;
const metricsCache = new Map<string, KeystrokeTextMetrics>();

function font(size: number, scale: number): string {
  return `600 ${pillFontSize(size, scale)}px ${PILL_FONT_FAMILY}`;
}

/**
 * SF Pro's line metrics as CoreText reports them for the pill's line
 * (`CTLineGetTypographicBounds` ascent / descent = hhea 1980/2048 and
 * 432/2048 of the point size — every non-empty string in the 600
 * `keystrokeOverlayPillMetrics` vectors, fallback glyphs like ⌫ ⎋ included;
 * 0 for an empty line). The browser's `fontBoundingBox*` are rounded to whole
 * px, which moved the pill height by 1 px and the baseline by up to 0.5 px.
 */
export const SF_ASCENT = 1980 / 2048;
export const SF_DESCENT = 432 / 2048;

/**
 * CTLineGetTypographicBounds of the pill's line: width measured by the
 * browser (SF on macOS; within ≈ 0.001 em per glyph of CoreText's advances,
 * so ≤ 0.8 px on the longest vector strings), ascent/descent from SF_*.
 */
export function measurePillText(text: string, size: number, scale: number): KeystrokeTextMetrics {
  const key = `${text}|${size}|${scale}`;
  const hit = metricsCache.get(key);
  if (hit) return hit;
  measureCtx ??= new OffscreenCanvas(1, 1).getContext("2d");
  const g = measureCtx!;
  g.font = font(size, scale);
  g.letterSpacing = `${pillKern(size, scale)}px`;
  const m = g.measureText(text);
  const fs = pillFontSize(size, scale);
  const out = text.length === 0 ? { width: 0, ascent: 0, descent: 0 } : { width: m.width, ascent: SF_ASCENT * fs, descent: SF_DESCENT * fs };
  if (metricsCache.size > 512) metricsCache.clear();
  metricsCache.set(key, out);
  return out;
}

function tracePath(g: OffscreenCanvasRenderingContext2D, path: PathElements): void {
  g.beginPath();
  for (const e of path) {
    switch (e[0]) {
      case "M": g.moveTo(e[1], e[2]); break;
      case "L": g.lineTo(e[1], e[2]); break;
      case "Q": g.quadraticCurveTo(e[1], e[2], e[3], e[4]); break;
      case "C": g.bezierCurveTo(e[1], e[2], e[3], e[4], e[5], e[6]); break;
      case "Z": g.closePath(); break;
    }
  }
}

const css = (c: { r: number; g: number; b: number; a: number }) => `rgba(${c.r * 255}, ${c.g * 255}, ${c.b * 255}, ${c.a})`;

/**
 * Replays the pill's recorded CG ops (y-down canvas space, the raster base
 * transform dropped) into `g`, whose transform already maps canvas px →
 * raster px. Transparency-layer alpha is NOT applied here (the GPU does it).
 */
function replay(g: OffscreenCanvasRenderingContext2D, ops: DrawOp[]): number {
  let alpha = 1;
  for (const op of ops) {
    switch (op.op) {
      case "save": g.save(); break;
      case "restore": g.restore(); break;
      case "translate": g.translate(op.x, op.y); break;
      case "scale": g.scale(op.x, op.y); break;
      case "alpha": alpha = op.alpha; break;
      case "fill":
        tracePath(g, op.path);
        g.fillStyle = css(op.color);
        g.fill(op.evenOdd ? "evenodd" : "nonzero");
        break;
      case "stroke":
        tracePath(g, op.path);
        g.strokeStyle = css(op.color);
        g.lineWidth = op.lineWidth;
        g.lineJoin = op.join;
        g.lineCap = op.cap;
        g.miterLimit = op.miterLimit;
        g.stroke();
        break;
      case "ctText": {
        const t = op as unknown as { text: string; size: number; scale: number; kern: number; x: number; y: number; color: { r: number; g: number; b: number; a: number } };
        g.font = font(t.size, t.scale);
        g.letterSpacing = `${t.kern}px`;
        g.textBaseline = "alphabetic";
        g.textAlign = "left";
        g.fillStyle = css(t.color);
        g.fillText(t.text, t.x, t.y);
        break;
      }
      default:
        break; // beginLayer / endLayer: one layer, composited with `alpha` on the GPU
    }
  }
  return alpha;
}

interface PillRaster {
  key: string;
  x: number;
  y: number;
  width: number;
  height: number;
  alpha: number;
}

export class KeystrokePillPass implements RenderPass {
  readonly name = "keystroke-pill";
  readonly stage = "card" as const;
  private u: Uniforms | null = null;
  private texture: GPUTexture | null = null;
  private view: GPUTextureView | null = null;
  private texW = 0;
  private texH = 0;
  private canvas: OffscreenCanvas | null = null;
  private raster: PillRaster | null = null;

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const data = cursorSceneData(ctx.scene);
    if (!data || data.keystrokeDisplay.length === 0) return;
    const t = frame.sourceTime;
    const pill = activePill(data.keystrokeDisplay, t);
    if (!pill) return;
    const s = data.settings;
    const canvasSize: Size = data.outputSize;
    const scale = data.canvasScale;

    // Record the exact CG call sequence of KeystrokeOverlayRenderer.draw (y-down).
    const rec = new RecordingContext();
    drawKeystrokePill(rec, pill, canvasSize, s.keystrokeOverlayPosition, s.keystrokeOverlaySize, scale, s.keystrokeOverlayAnimation, measurePillText);
    const ops = rec.ops;
    const bounds = pillBounds(ops, scale);
    if (!bounds) return;
    const key = JSON.stringify([ops.filter((o) => o.op !== "alpha"), bounds]);
    let alpha = pill.alpha;
    if (this.raster?.key !== key) {
      const w = bounds.x1 - bounds.x0;
      const h = bounds.y1 - bounds.y0;
      if (!this.canvas || this.canvas.width < w || this.canvas.height < h) {
        this.canvas = new OffscreenCanvas(Math.max(w, this.canvas?.width ?? 0), Math.max(h, this.canvas?.height ?? 0));
      }
      const g = this.canvas.getContext("2d", { colorSpace: "srgb", willReadFrequently: true })!; // CPU raster: analytic AA
      g.setTransform(1, 0, 0, 1, 0, 0);
      g.clearRect(0, 0, this.canvas.width, this.canvas.height);
      g.translate(-bounds.x0, -bounds.y0);
      alpha = replay(g, ops);
      if (!this.texture || this.texW < this.canvas.width || this.texH < this.canvas.height) {
        this.texture?.destroy();
        this.texW = this.canvas.width;
        this.texH = this.canvas.height;
        this.texture = ctx.device.createTexture({
          label: "keystroke-pill",
          size: { width: this.texW, height: this.texH },
          format: "rgba8unorm",
          usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
        });
        this.view = this.texture.createView();
      }
      ctx.device.queue.copyExternalImageToTexture(
        { source: this.canvas, origin: { x: 0, y: 0 } },
        { texture: this.texture, premultipliedAlpha: true },
        { width: w, height: h },
      );
      this.raster = { key, x: bounds.x0, y: bounds.y0, width: w, height: h, alpha };
    }
    const r = this.raster!;
    this.u ??= new Uniforms(ctx.device, 40, "keystroke-u");
    this.u.write([
      ...quadBlock(enc.cardToTarget, ctx.scene.target, { x: r.x, y: r.y, w: r.width, h: r.height }),
      r.x, r.y, pill.alpha, ctx.scene.workingSpace === "display-p3" ? 1 : 0,
      r.width, r.height, 0, 0,
    ]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "keystroke-pill", code: keystrokeWGSL, vertexEntry: "vs_quad", format: enc.format,
      blend: "premultipliedOver", entries: [L.uniform(0, true), L.texture(1)],
    });
    const pass = enc.pass!;
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout,
      entries: [{ binding: 0, resource: { buffer: this.u.buffer } }, { binding: 1, resource: this.view! }],
    }));
    pass.draw(6);
  }

  destroy(): void {
    this.u?.destroy();
    this.texture?.destroy();
  }
}

/** Integer raster bounds (canvas px) of the recorded pill: every path point
 * through the op stream's CTM, padded for the stroke and AA. */
function pillBounds(ops: DrawOp[], scale: number): { x0: number; y0: number; x1: number; y1: number } | null {
  // CTM: translate/scale ops (pop about the rect centre); text sits inside the path.
  let m = { a: 1, d: 1, tx: 0, ty: 0 };
  const stack: (typeof m)[] = [];
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const op of ops) {
    if (op.op === "save") stack.push({ ...m });
    else if (op.op === "restore") m = stack.pop() ?? m;
    else if (op.op === "translate") m = { a: m.a, d: m.d, tx: m.tx + m.a * op.x, ty: m.ty + m.d * op.y };
    else if (op.op === "scale") m = { a: m.a * op.x, d: m.d * op.y, tx: m.tx, ty: m.ty };
    else if (op.op === "fill" || op.op === "stroke") {
      for (const e of op.path) {
        for (let i = 1; i + 1 < e.length; i += 2) {
          const x = m.a * (e[i] as number) + m.tx;
          const y = m.d * (e[i + 1] as number) + m.ty;
          x0 = Math.min(x0, x);
          y0 = Math.min(y0, y);
          x1 = Math.max(x1, x);
          y1 = Math.max(y1, y);
        }
      }
    }
  }
  if (!(x1 > x0 && y1 > y0)) return null;
  const pad = Math.ceil(scale) + 2;
  return { x0: Math.floor(x0) - pad, y0: Math.floor(y0) - pad, x1: Math.ceil(x1) + pad, y1: Math.ceil(y1) + pad };
}
