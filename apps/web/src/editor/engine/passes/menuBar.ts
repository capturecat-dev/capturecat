/**
 * MenuBarPass (stage "card", right after the video) — the replacement menu
 * bar (`cachedMenuBar`, VideoExporter 987-1010 + MenuBarRenderer.image):
 * "Clean Dark" / "Clean Light" draw a bar of height max(4, vr.height ×
 * menuBarHeight / 100) over the video rect's top strip; "Hidden" is the
 * source crop in `cardGeometry` (no bar); "Original" draws nothing. The bar
 * is hidden while a stitched device segment fills the frame, and never drawn
 * for a framed device take.
 *
 * Layout numbers are the golden-locked core port (`menuBarLayout`); the text
 * is MEASURED in the browser with the same face (system-ui = SF Pro on macOS;
 * clock medium, title bold, Apple logo U+F8FF regular). The SF Symbols
 * (battery.100, wifi) are drawn as vector look-alikes in their measured boxes
 * (sizes from the `menuBarTextMetrics` calibration table, AppKit on macOS 26).
 * Like the Mac export (an NSImage rasterised at the 2× backing scale, then
 * CI-scaled onto the rect), the bar is rasterised at 2 px per card px.
 */
import { menuBarFonts, menuBarLayout, barColorSRGB, textColorSRGB, type MenuBarMeasured, type MenuBarSpec } from "../../core/math/menuBarRenderer";
import { deviceSegmentActive, segmentDeviceAssets, type SegmentDeviceAssets } from "../../core/math/deviceSegmentDip";
import type { ProjectSettings } from "../../core/model/types";
import { cssColor, destroySprites, makeSprite, SpriteDrawer, type Sprite } from "./sprite";
import type { FrameEncoder, FrameState, PassContext, RenderPass, Scene } from "./types";

/** AppKit SF Symbol boxes (pt) per bar height, from the menuBarTextMetrics vectors. */
const SYMBOL_TABLE: [number, number, number, number, number][] = [
  // barH, battery w, h, wifi w, h
  [8, 7, 4, 6, 5], [12, 10, 6, 8, 6], [16, 14, 7, 11, 8], [20, 17, 9, 14, 11], [22, 19, 10, 15, 11],
  [24, 21, 11, 16, 12], [28, 24, 12, 18, 14], [32, 28, 14, 22, 17], [36, 31, 16, 24, 18],
  [44, 37, 19, 29, 22], [56, 48, 24, 37, 28], [72, 62, 31, 47, 36],
];

function symbolBoxes(h: number): { battery: { width: number; height: number }; wifi: { width: number; height: number } } {
  const t = SYMBOL_TABLE;
  let i = 0;
  while (i < t.length - 2 && h > t[i + 1][0]) i++;
  const a = t[i];
  const b = t[i + 1];
  const f = (h - a[0]) / (b[0] - a[0]);
  const at = (k: number) => Math.max(1, Math.round(a[k] + (b[k] - a[k]) * f));
  return { battery: { width: at(1), height: at(2) }, wifi: { width: at(3), height: at(4) } };
}

/** SF Pro metrics (ascender / descender per point, `.AppleSystemUIFont`). */
const ASCENDER = 0.966796875;
const DESCENDER = 0.2109375;
const lineBox = (size: number) => Math.ceil(size * (ASCENDER + DESCENDER) - 1e-6);

type Ctx = OffscreenCanvasRenderingContext2D;

function font(weight: number, size: number) {
  return `${weight} ${size}px system-ui, -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif`;
}

function measure(ctx: Ctx, text: string, weight: number, size: number) {
  ctx.font = font(weight, size);
  return { width: ctx.measureText(text).width, height: lineBox(size) };
}

/**
 * battery.100 (medium): rounded body outline, full charge fill, terminal nub.
 * The glyph's ink occupies ~84% × 81% of the symbol box (measured against
 * AppKit: 26×13 ink in a 31×16 box at a 36-pt bar).
 */
function drawBattery(ctx: Ctx, bx: number, by: number, bw: number, bh: number) {
  const x = bx + bw * 0.03;
  const y = by + bh * 0.125;
  const w = bw * 0.84;
  const h = bh * 0.81;
  const stroke = Math.max(0.6, h * 0.1);
  const nubW = w * 0.075;
  const bodyW = w - nubW - stroke * 0.4;
  const r = h * 0.3;
  ctx.lineWidth = stroke;
  ctx.beginPath();
  ctx.roundRect(x + stroke / 2, y + stroke / 2, bodyW - stroke, h - stroke, r);
  ctx.globalAlpha = 0.6;
  ctx.stroke();
  ctx.globalAlpha = 1;
  const inset = stroke * 2;
  ctx.beginPath();
  ctx.roundRect(x + inset, y + inset, bodyW - inset * 2, h - inset * 2, Math.max(0, r - inset * 0.6));
  ctx.fill();
  ctx.beginPath();
  const nh = h * 0.34;
  ctx.roundRect(x + bodyW + stroke * 0.2, y + (h - nh) / 2, nubW, nh, [0, nubW / 1.5, nubW / 1.5, 0]);
  ctx.globalAlpha = 0.6;
  ctx.fill();
  ctx.globalAlpha = 1;
}

/** wifi (medium): two arcs over a wedge, fanned ±45° about the vertical (ink 21×15 in a 24×18 box at 36 pt). */
function drawWifi(ctx: Ctx, x: number, y: number, w: number, h: number) {
  const cx = x + w / 2 - w * 0.02;
  const cy = y + h * 0.92;
  const thick = h * 0.14;
  const a0 = -Math.PI / 2 - Math.PI / 4;
  const a1 = -Math.PI / 2 + Math.PI / 4;
  ctx.lineCap = "round";
  ctx.lineWidth = thick;
  for (const r of [h * 0.73, h * 0.47]) {
    ctx.beginPath();
    ctx.arc(cx, cy, r, a0, a1);
    ctx.stroke();
  }
  ctx.beginPath();
  ctx.moveTo(cx, cy);
  ctx.arc(cx, cy, h * 0.245, a0, a1);
  ctx.closePath();
  ctx.fill();
}

/** Paints `MenuBarRenderer.image(for:)` in its own point space (Y-down). */
function paintBar(ctx: Ctx, spec: MenuBarSpec): void {
  const H = spec.height;
  const f = menuBarFonts(H);
  const syms = symbolBoxes(H);
  const measured: MenuBarMeasured = {
    clock: spec.clock ? measure(ctx, spec.clock, f.clock.weight, f.clock.size) : null,
    symbols: [
      { name: "battery.100", size: syms.battery },
      { name: "wifi", size: syms.wifi },
    ],
    logo: measure(ctx, "", f.logo.weight, f.logo.size),
    title: spec.title ? measure(ctx, spec.title, f.title.weight, f.title.size) : null,
  };
  const layout = menuBarLayout(spec, measured);
  if (!layout) return;
  const dark = spec.style === "Clean Dark";
  ctx.fillStyle = cssColor(dark ? barColorSRGB.dark : barColorSRGB.light);
  ctx.fillRect(0, 0, spec.width, H);
  const ink = cssColor(textColorSRGB(spec.style));
  ctx.fillStyle = ink;
  ctx.strokeStyle = ink;
  ctx.textBaseline = "alphabetic";
  // NSImage space is Y-up; every element is vertically centred, so its
  // Y-down box top is H − y − h. Text baseline sits `descender` above the
  // box bottom (NSAttributedString.draw(at:)).
  const text = (s: string, weight: number, size: number, r: { x: number; y: number; height: number }) => {
    ctx.font = font(weight, size);
    const bottom = H - r.y;
    ctx.fillText(s, r.x, bottom - size * DESCENDER);
  };
  if (layout.clock && spec.clock) text(spec.clock, f.clock.weight, f.clock.size, layout.clock);
  for (const icon of layout.icons) {
    const top = H - icon.rect.y - icon.rect.height;
    if (icon.name === "battery.100") drawBattery(ctx, icon.rect.x, top, icon.rect.width, icon.rect.height);
    else drawWifi(ctx, icon.rect.x, top, icon.rect.width, icon.rect.height);
  }
  text("", f.logo.weight, f.logo.size, layout.logo);
  if (layout.title && spec.title) text(spec.title, f.title.weight, f.title.size, layout.title);
}

export class MenuBarPass implements RenderPass {
  readonly name = "menu-bar";
  readonly stage = "card" as const;
  private sprite: Sprite | null = null;
  private segments: SegmentDeviceAssets | null = null;
  private drawer = new SpriteDrawer();
  private key = "";

  sceneChanged(ctx: PassContext): void {
    const scene = ctx.scene;
    const project = scene.extras.project;
    const settings = project?.settings;
    const g = scene.geometry;
    const vr = g.videoRect;
    const key = settings
      ? JSON.stringify([
          settings.menuBarReplacement, settings.menuBarHeight, settings.menuBarTitle, settings.menuBarTitleAlignment,
          settings.menuBarShowStatusIcons, settings.menuBarClock, vr, !!g.device,
        ])
      : "";
    if (key === this.key) return;
    this.key = key;
    destroySprites(ctx.device, [this.sprite]);
    this.sprite = null;
    this.segments = null;
    if (!settings || !project || g.device) return;
    if (settings.menuBarReplacement !== "Clean Dark" && settings.menuBarReplacement !== "Clean Light") return;
    this.sprite = rasterizeMenuBar(ctx.device, scene, settings);
    this.segments = segmentDeviceAssets(project.recordingSourceKind, settings.showDeviceFrame, project.sourceSegments, {
      // Only the ranges are used here; the rect is irrelevant for visibility.
      x: vr.x, y: vr.y, width: vr.width, height: vr.height,
    });
  }

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    if (!this.sprite) return;
    // Hidden while a device segment fills the frame (VideoExporter 1722).
    if (deviceSegmentActive(this.segments, frame.sourceTime)) return;
    this.drawer.begin();
    this.drawer.draw(ctx, enc.pass!, enc.format, enc.cardToTarget, ctx.scene.target, this.sprite);
  }

  destroy(): void {
    this.drawer.destroy();
    this.sprite?.texture.destroy();
  }
}

/** The bar raster for a scene (null when the renderer returns nil). */
export function rasterizeMenuBar(device: GPUDevice, scene: Scene, settings: ProjectSettings): Sprite | null {
  const vr = scene.geometry.videoRect;
  const barH = Math.max(4, (vr.height * settings.menuBarHeight) / 100);
  const spec: MenuBarSpec = {
    style: settings.menuBarReplacement,
    title: settings.menuBarTitle,
    titleAlignment: settings.menuBarTitleAlignment,
    showStatusIcons: settings.menuBarShowStatusIcons,
    clock: settings.menuBarClock,
    width: Math.round(vr.width),
    height: Math.round(barH),
  };
  if (!(spec.width > 4 && spec.height > 4)) return null;
  const rect = { x: vr.x, y: vr.y, width: vr.width, height: barH };
  return makeSprite(
    device,
    rect,
    (ctx) => {
      // The NSImage (spec.width × spec.height pt) is stretched onto the exact rect.
      ctx.translate(rect.x, rect.y);
      ctx.scale(rect.width / spec.width, rect.height / spec.height);
      ctx.beginPath();
      ctx.rect(0, 0, spec.width, spec.height);
      ctx.clip();
      paintBar(ctx, spec);
    },
    "menu-bar",
    2,
  );
}
