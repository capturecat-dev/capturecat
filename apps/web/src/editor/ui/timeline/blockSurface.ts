/**
 * drawBlockSurface (TimelineCanvasView.drawBlockSurface) on <canvas>, made
 * cheap enough for hundreds of blocks at 60 fps:
 *
 * The 2026 look (Mac 2026-10-27): a soft rounded bar (radius 10), a nearly
 * flat colour — the lane pair with only a whisper of top light (+0.025 top,
 * −0.015 bottom; +0.06 selected / +0.03 hovered) — a hairline that follows
 * the corners (black .18 dark / .08 light, the inner half of a 1px stroke),
 * a soft contact shadow (black .28 dark / .10 light, blur 4, 1 down) and a
 * 2px white .85 inset border when selected. No top highlight line, no sheen.
 * Every one of those is UNIFORM horizontally between the corners — so each variant is
 * rendered ONCE into a 9-slice sprite and blitted with three drawImage calls
 * (left cap, stretched middle, right cap). Blocks narrower than two caps fall
 * back to painting the path directly (same code that renders the sprite).
 */
import type { RGBA } from "../kit/theme";
import { M } from "./metrics";

const PAD = 6; // shadow margin around the slab (css px)
const CAP = PAD + 12; // cap width incl. margin: ≥ the radius 10 corner
const MID = 4; // uniform middle columns baked into the sprite (css px)

export const brighten = (c: RGBA, delta: number): RGBA => ({
  r: Math.max(0, Math.min(255, c.r + delta * 255)),
  g: Math.max(0, Math.min(255, c.g + delta * 255)),
  b: Math.max(0, Math.min(255, c.b + delta * 255)),
  a: c.a,
});

const css = (c: RGBA, a = c.a) => `rgba(${Math.round(c.r)},${Math.round(c.g)},${Math.round(c.b)},${a})`;

function roundedPath(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, rx: number, ry: number) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, [{ x: rx, y: ry }]);
}

/** Paints one slab directly (css px coordinates; ctx already DPR-scaled). */
export function paintBlockSurface(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  top: RGBA,
  bottom: RGBA,
  selected: boolean,
  hovering: boolean,
  dpr: number,
  dark = true,
) {
  const b = selected ? 0.06 : hovering ? 0.03 : 0;
  const topC = brighten(top, b + 0.025);
  const botC = brighten(bottom, b - 0.015);
  const r = M.blockCornerRadius;
  const rx = Math.min(r, w / 2);

  // Soft contact shadow (CG offset −1 in unflipped base space = 1pt below).
  ctx.save();
  ctx.shadowOffsetX = 0;
  ctx.shadowOffsetY = 1 * dpr;
  ctx.shadowBlur = 4 * dpr;
  ctx.shadowColor = dark ? "rgba(0,0,0,0.28)" : "rgba(0,0,0,0.10)";
  roundedPath(ctx, x, y, w, h, rx, r);
  ctx.fillStyle = css(botC);
  ctx.fill();
  ctx.restore();

  // Near-flat vertical gradient, then the hairline that follows the corners
  // (stroked inside the clip, so only its inner half shows).
  ctx.save();
  roundedPath(ctx, x, y, w, h, rx, r);
  ctx.clip();
  const g = ctx.createLinearGradient(0, y, 0, y + h);
  g.addColorStop(0, css(topC));
  g.addColorStop(1, css(botC));
  ctx.fillStyle = g;
  ctx.fillRect(x, y, w, h);
  roundedPath(ctx, x, y, w, h, rx, r);
  ctx.strokeStyle = dark ? "rgba(0,0,0,0.18)" : "rgba(0,0,0,0.08)";
  ctx.lineWidth = 1;
  ctx.stroke();
  ctx.restore();

  if (selected) {
    const ir = Math.min(r - 1, w / 2);
    roundedPath(ctx, x + 1, y + 1, w - 2, h - 2, ir, r - 1);
    ctx.strokeStyle = "rgba(255,255,255,0.85)";
    ctx.lineWidth = 2;
    ctx.stroke();
  }
}

interface Sprite {
  canvas: HTMLCanvasElement;
  /** device px */
  capPx: number;
  midPx: number;
  heightPx: number;
}

export class BlockSpriteCache {
  private sprites = new Map<string, Sprite>();

  clear() {
    this.sprites.clear();
  }

  private sprite(top: RGBA, bottom: RGBA, selected: boolean, hovering: boolean, h: number, dpr: number, dark: boolean): Sprite {
    const key = `${top.r},${top.g},${top.b}|${bottom.r},${bottom.g},${bottom.b}|${+selected}${+hovering}|${h}|${dpr}|${+dark}`;
    let s = this.sprites.get(key);
    if (s) return s;
    const cssW = CAP * 2 + MID;
    const cssH = h + PAD * 2;
    const canvas = document.createElement("canvas");
    canvas.width = Math.ceil(cssW * dpr);
    canvas.height = Math.ceil(cssH * dpr);
    const ctx = canvas.getContext("2d")!;
    ctx.scale(dpr, dpr);
    paintBlockSurface(ctx, PAD, PAD, cssW - PAD * 2, h, top, bottom, selected, hovering, dpr, dark);
    s = { canvas, capPx: Math.round(CAP * dpr), midPx: Math.round(MID * dpr), heightPx: canvas.height };
    this.sprites.set(key, s);
    return s;
  }

  /** Blits a slab at (x, y, w, h) in css px (ctx is DPR-scaled). */
  draw(
    ctx: CanvasRenderingContext2D,
    x: number,
    y: number,
    w: number,
    h: number,
    top: RGBA,
    bottom: RGBA,
    selected: boolean,
    hovering: boolean,
    dpr: number,
    dark = true,
  ) {
    const content = CAP - PAD; // cap width inside the slab
    if (w < content * 2 + 1) {
      paintBlockSurface(ctx, x, y, w, h, top, bottom, selected, hovering, dpr, dark);
      return;
    }
    const s = this.sprite(top, bottom, selected, hovering, h, dpr, dark);
    const capCss = s.capPx / dpr;
    const hCss = s.heightPx / dpr;
    const dy = y - PAD;
    const left = x - PAD;
    const right = x + w + PAD;
    // left cap
    ctx.drawImage(s.canvas, 0, 0, s.capPx, s.heightPx, left, dy, capCss, hCss);
    // stretched middle — sample strictly inside the uniform columns
    const midSrcX = s.capPx + 1;
    const midSrcW = Math.max(1, s.midPx - 2);
    ctx.drawImage(s.canvas, midSrcX, 0, midSrcW, s.heightPx, left + capCss, dy, right - left - capCss * 2, hCss);
    // right cap
    ctx.drawImage(s.canvas, s.capPx + s.midPx, 0, s.capPx, s.heightPx, right - capCss, dy, capCss, hCss);
  }
}
