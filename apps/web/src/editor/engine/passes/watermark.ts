/**
 * WatermarkPass (stage "overlay", registered LAST) — the exporter's brand
 * watermark: static for the whole export, composited over every frame after
 * the camera bubble (topmost), with or without a video frame.
 *
 * `watermarkStatic` (VideoExporter.export):
 *   edgePad = 20 · canvasScale
 *   targetW = min(watermarkSize · canvasScale, max(1, W − 2·edgePad))
 *   scale   = targetW / rawW,  targetH = rawH · scale
 *   usable  = max(0, W|H − 2·edgePad − target)
 *   origin  = edgePad + clamp01(x) · usableW,  edgePad + clamp01(y) · usableH  (Y-down)
 *   fadeImage(raw, watermarkOpacity) → premultiplied RGB × opacity², alpha × opacity
 * then `transformed(by: scale · translate)` (bilinear, CIAffineTransform) and
 * cropped to the output rect. The image is `assets.images[watermarkFileName]`
 * (the file lives next to the recording, `Project.watermarkImageURL`).
 */
import { smax, smin } from "../../core/math/swift";
import { IDENTITY } from "../mat3";
import { watermarkPlacement } from "../raster/watermarkLayout";
import { RasterOverlay } from "./rasterOverlay";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "./types";

export class WatermarkPass implements RenderPass {
  readonly name = "watermark";
  readonly stage = "overlay" as const;
  private overlay = new RasterOverlay("watermark");
  private uploaded: { bitmap: ImageBitmap; space: string } | null = null;

  sceneChanged(ctx: PassContext): void {
    const bmp = this.bitmap(ctx);
    if (!bmp) return;
    if (this.uploaded?.bitmap === bmp && this.uploaded.space === ctx.scene.workingSpace) return;
    this.overlay.ensure(ctx.device, bmp.width, bmp.height);
    this.overlay.upload(ctx.device, bmp, ctx.scene.workingSpace);
    this.uploaded = { bitmap: bmp, space: ctx.scene.workingSpace };
  }

  private bitmap(ctx: PassContext): ImageBitmap | null {
    const p = ctx.scene.extras.project;
    const s = p?.settings;
    if (!s || !s.showWatermark || !s.watermarkFileName) return null;
    return ctx.scene.extras.assets.images.get(s.watermarkFileName) ?? null;
  }

  encode(ctx: PassContext, _frame: FrameState, enc: FrameEncoder): void {
    const bmp = this.bitmap(ctx);
    if (!bmp || this.uploaded?.bitmap !== bmp) return;
    const s = ctx.scene.extras.project!.settings;
    const place = watermarkPlacement(bmp, ctx.scene.target, ctx.scene.geometry.canvasScale, s);
    if (!place) return;
    const opacity = smin(1, smax(0, s.watermarkOpacity));
    if (!(opacity > 0)) return;
    this.overlay.draw(ctx, enc, place, IDENTITY, opacity, true);
  }

  destroy(): void {
    this.overlay.destroy();
    this.uploaded = null;
  }
}
