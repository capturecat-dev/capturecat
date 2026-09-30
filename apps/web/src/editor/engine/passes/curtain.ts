/**
 * CurtainPass (stage "card", the LAST card overlay) — the exporter's Curtain
 * Unveil block: `CurtainUnveilMath.state(corner:at: OUTPUT time …)`; when
 * active, `renderImage(state:, size: round(videoRect.size), style:)` with the
 * cover style (curtainColor, logo from `assets.images[curtainLogoFileName]`,
 * logo opacity / scale / tint) and the card clip (`cardClip(frameShape:
 * cornerRadius: outerCornerRadius, cardSize:, deviceScreen:)` — the device
 * screen is a framed take's whole card, or a stitched take's segment screen
 * while its device segment is framed: core `curtainDeviceScreen`), scaled back
 * onto the (fractional) video rect and composited — before the camera warp,
 * so the peel rides zoom / tilt / the intro slide like the Mac.
 *
 * The raster comes from the core recipe (`curtainRecipe`, locked to Swift by
 * the curtainUnveilDrawRecipe vectors) replayed by `raster/curtainReplay`.
 */
import {
  cardClip,
  coverStyle,
  curtainRecipe,
  state as curtainState,
} from "../../core/math/curtainUnveilMath";
import { curtainDeviceScreen, deviceFrameActive } from "../../core/math/deviceSegmentDip";
import { flipRectY } from "../../core/math/geometry";
import { swiftRound } from "../layout";
import { replayCurtain, type CurtainLogo } from "../raster/curtainReplay";
import type { Ctx2D } from "../raster/cgReplay";
import { outerCornerRadius } from "./annotations";
import { RasterOverlay } from "./rasterOverlay";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "./types";

export class CurtainPass implements RenderPass {
  readonly name = "curtain-unveil";
  readonly stage = "card" as const;
  private overlay = new RasterOverlay("curtain");
  private canvas: OffscreenCanvas | null = null;
  private ctx2d: Ctx2D | null = null;
  private logo: CurtainLogo | null = null;
  private key = "";

  sceneChanged(ctx: PassContext): void {
    this.key = "";
    const p = ctx.scene.extras.project;
    const ref = p?.settings.curtainLogoFileName;
    const bmp = ref ? ctx.scene.extras.assets.images.get(ref) ?? null : null;
    if (bmp !== this.logo?.image) this.logo = bmp ? { image: bmp, tinted: new Map() } : null;
  }

  invalidate(): void {
    this.key = "";
  }

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const scene = ctx.scene;
    const project = scene.extras.project;
    if (!project) return;
    const s = project.settings;
    if (s.curtainUnveilCorner === "Off") return;
    const st = curtainState(s.curtainUnveilCorner, frame.outputTime, s.curtainUnveilStart, s.curtainUnveilDuration);
    if (!st.active) return;

    const vr = scene.geometry.videoRect;
    const w = Math.trunc(swiftRound(vr.width));
    const h = Math.trunc(swiftRound(vr.height));
    if (!(w > 0 && h > 0)) return;

    // The device screen the peel is confined to changes at a stitched take's cuts.
    const segmentActive = frame.deviceSegment === true;
    const key = `${scene.version}|${w}x${h}|${st.progress}|${this.logo ? "L" : ""}|${segmentActive ? "S" : ""}`;
    if (key !== this.key) {
      this.key = key;
      const deviceScreen = curtainDeviceScreen(
        ctx.statics.segment?.framing.assets ?? null,
        segmentActive,
        deviceFrameActive(project.recordingSourceKind, s.showDeviceFrame),
        // The exporter's (CI Y-UP) static video rect; the result is card-local Y-DOWN.
        flipRectY(vr, scene.target.height),
      );
      const style = coverStyle(
        s,
        this.logo ? { width: this.logo.image.width, height: this.logo.image.height } : null,
        cardClip(s.frameShape, outerCornerRadius(scene), { width: vr.width, height: vr.height }, deviceScreen),
      );
      const recipe = curtainRecipe(st, { width: vr.width, height: vr.height }, style);
      if (!recipe) return;
      if (!this.canvas || this.canvas.width !== recipe.width || this.canvas.height !== recipe.height) {
        this.canvas = new OffscreenCanvas(recipe.width, recipe.height);
        this.ctx2d = this.canvas.getContext("2d") as Ctx2D;
      }
      const c2d = this.ctx2d!;
      c2d.setTransform(1, 0, 0, 1, 0, 0);
      c2d.clearRect(0, 0, recipe.width, recipe.height);
      replayCurtain(c2d, recipe.ops, recipe.width, recipe.height, this.logo);
      this.overlay.ensure(ctx.device, recipe.width, recipe.height);
      this.overlay.upload(ctx.device, this.canvas, scene.workingSpace);
    }
    // CI: scale (vr / raster) then translate to the video rect's origin.
    this.overlay.draw(ctx, enc, vr, enc.cardToTarget);
  }

  destroy(): void {
    this.overlay.destroy();
    this.canvas = null;
    this.ctx2d = null;
    this.logo = null;
  }
}
