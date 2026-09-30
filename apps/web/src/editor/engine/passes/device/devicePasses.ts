/**
 * Framed device take (iPhone/iPad bezel) — the exporter's per-frame device
 * layers, as card-stage passes around the card shadow and the video:
 *
 *   DeviceSidePass   (before CardShadowPass, layer path only) — the extruded
 *                    side faces UNDER the card statics, translated by
 *                    `TiltMath.deviceSideOffset(pitch, yaw, videoWidth)` when
 *                    max(|pitch|, |yaw|) > 0.05°. The offset is expressed in
 *                    the preview's Y-DOWN space (the exporter negates y for
 *                    CI), so it is used as-is here. Needs `FrameState.tilt`
 *                    from the camera stage; absent → no slab (no tilt).
 *   DeviceBezelPass  (after CardShadowPass, layer path only) — the bezel over
 *                    the shadow (`cachedCardStatics` = shadow + bezel). In the
 *                    direct path the bezel is baked into the base with the
 *                    shadow (`cachedBaseFrame`, StaticLayers).
 *   DeviceIslandPass (after the video + menu bar, both paths) — screen seam +
 *                    Dynamic Island + lens (`cachedDeviceIsland`).
 *
 * The sprites are rasterized once per scene in StaticLayers (deviceRaster.ts).
 */
import { deviceSideOffset } from "../../../core/math/tiltMath";
import { SpriteDrawer } from "../sprite";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "../types";

export class DeviceSidePass implements RenderPass {
  readonly name = "device-side";
  readonly stage = "card" as const;
  private drawer = new SpriteDrawer();

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const side = ctx.statics.device?.side;
    const g = ctx.scene.geometry.device;
    const tilt = frame.tilt;
    if (!enc.layerMode || !side || !g || !tilt) return;
    if (!(Math.max(Math.abs(tilt.pitch), Math.abs(tilt.yaw)) > 0.05)) return;
    const off = deviceSideOffset(tilt.pitch, tilt.yaw, g.screenRect.width);
    this.drawer.begin();
    this.drawer.draw(ctx, enc.pass!, enc.format, enc.cardToTarget, ctx.scene.target, side, {
      offsetX: off.width,
      offsetY: off.height,
    });
  }

  destroy(): void {
    this.drawer.destroy();
  }
}

export class DeviceBezelPass implements RenderPass {
  readonly name = "device-bezel";
  readonly stage = "card" as const;
  private drawer = new SpriteDrawer();

  encode(ctx: PassContext, _frame: FrameState, enc: FrameEncoder): void {
    const bezel = ctx.statics.device?.bezel;
    if (!enc.layerMode || !bezel) return;
    this.drawer.begin();
    this.drawer.draw(ctx, enc.pass!, enc.format, enc.cardToTarget, ctx.scene.target, bezel);
  }

  destroy(): void {
    this.drawer.destroy();
  }
}

export class DeviceIslandPass implements RenderPass {
  readonly name = "device-island";
  readonly stage = "card" as const;
  private drawer = new SpriteDrawer();

  encode(ctx: PassContext, _frame: FrameState, enc: FrameEncoder): void {
    const island = ctx.statics.device?.island;
    if (!island) return;
    this.drawer.begin();
    this.drawer.draw(ctx, enc.pass!, enc.format, enc.cardToTarget, ctx.scene.target, island);
  }

  destroy(): void {
    this.drawer.destroy();
  }
}
