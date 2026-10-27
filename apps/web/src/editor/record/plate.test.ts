import { describe, expect, it } from "vitest";

import {
  BEACON,
  RectHold,
  SHADOW_PAD,
  capturedDisplay,
  checkRegion,
  composite,
  findBeacon,
  plateTarget,
  toFramePixels,
  verifyPlacement,
  type Display,
  type PixelRect,
  type PlateCanvas,
  type UnitRect,
  type WindowGeometry,
} from "./plate";

// ── a tiny RGBA raster and a 2D context that blits like a canvas (nearest) ──

interface Img {
  width: number;
  height: number;
  px: Uint8ClampedArray;
}

function image(width: number, height: number, fill: (x: number, y: number) => [number, number, number]): Img {
  const px = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const [r, g, b] = fill(x, y);
      const i = (y * width + x) * 4;
      px[i] = r;
      px[i + 1] = g;
      px[i + 2] = b;
      px[i + 3] = 255;
    }
  }
  return { width, height, px };
}

class FakeCtx implements PlateCanvas<Img> {
  readonly out: Img;
  calls = 0;
  constructor(width: number, height: number) {
    this.out = image(width, height, () => [0, 0, 0]);
  }
  drawImage(img: Img, ...a: number[]): void {
    this.calls++;
    const [sx, sy, sw, sh, dx, dy, dw, dh] = a.length === 4 ? [0, 0, img.width, img.height, ...a] : a;
    for (let y = 0; y < dh; y++) {
      for (let x = 0; x < dw; x++) {
        const tx = dx + x;
        const ty = dy + y;
        if (tx < 0 || ty < 0 || tx >= this.out.width || ty >= this.out.height) continue;
        const fx = Math.floor(sx + ((x + 0.5) * sw) / dw);
        const fy = Math.floor(sy + ((y + 0.5) * sh) / dh);
        const s = (fy * img.width + fx) * 4;
        const d = (ty * this.out.width + tx) * 4;
        for (let k = 0; k < 4; k++) this.out.px[d + k] = img.px[s + k];
      }
    }
  }
}

const CYAN: [number, number, number] = [0, 255, 255];
const RED: [number, number, number] = [255, 59, 48];
const DARK: [number, number, number] = [5, 5, 5];
const TITLE: [number, number, number] = [58, 58, 60];

/** Largest 4-connected blob of cyan (the gate's structural check, not a mean). */
function cyanBlob(img: Img): number {
  const { width: w, height: h, px } = img;
  const mask = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) if (px[i * 4] <= 40 && px[i * 4 + 1] >= 220 && px[i * 4 + 2] >= 220) mask[i] = 1;
  let best = 0;
  const stack: number[] = [];
  for (let i = 0; i < w * h; i++) {
    if (mask[i] !== 1) continue;
    let size = 0;
    stack.push(i);
    mask[i] = 2;
    while (stack.length) {
      const j = stack.pop()!;
      size++;
      const x = j % w;
      for (const k of [x > 0 ? j - 1 : -1, x < w - 1 ? j + 1 : -1, j - w, j + w]) {
        if (k >= 0 && k < w * h && mask[k] === 1) {
          mask[k] = 2;
          stack.push(k);
        }
      }
    }
    best = Math.max(best, size);
  }
  return best;
}

/**
 * A synthetic display frame: busy background (every pixel distinct-ish), and
 * the floating window at `geom` (CSS px) drawn the way it looks on screen —
 * a title bar, the beacon (red stripe, dark band), then the controls (cyan:
 * the marker the gate looks for).
 */
function displayFrame(frame: { width: number; height: number }, display: Display, geom: WindowGeometry | null, seed = 0): Img {
  const scale = frame.width / display.width;
  // Busy, but never marker cyan (red stays ≥ 64).
  const img = image(frame.width, frame.height, (x, y) => [64 + ((x * 7 + seed) % 192), (y * 5 + seed * 3) & 255, (x ^ y) & 255]);
  if (!geom) return img;
  const side = (geom.width - geom.innerWidth) / 2;
  const title = geom.height - geom.innerHeight - side;
  const fill = (cx: number, cy: number, cw: number, ch: number, c: [number, number, number]) => {
    const x0 = Math.round((cx - display.left) * scale);
    const y0 = Math.round((cy - display.top) * scale);
    const x1 = Math.round((cx + cw - display.left) * scale);
    const y1 = Math.round((cy + ch - display.top) * scale);
    for (let y = Math.max(0, y0); y < Math.min(frame.height, y1); y++) {
      for (let x = Math.max(0, x0); x < Math.min(frame.width, x1); x++) {
        const i = (y * frame.width + x) * 4;
        img.px[i] = c[0];
        img.px[i + 1] = c[1];
        img.px[i + 2] = c[2];
      }
    }
  };
  fill(geom.x, geom.y, geom.width, geom.height, TITLE);
  const cx = geom.x + side;
  const cy = geom.y + title;
  fill(cx, cy, geom.innerWidth, geom.innerHeight, CYAN);
  fill(cx, cy, geom.innerWidth, BEACON.stripe, RED);
  fill(cx, cy + BEACON.stripe, geom.innerWidth, BEACON.band, DARK);
  return img;
}

function crop(img: Img, r: PixelRect): Uint8ClampedArray {
  const out = new Uint8ClampedArray(r.w * r.h * 4);
  for (let y = 0; y < r.h; y++) out.set(img.px.subarray(((r.y + y) * img.width + r.x) * 4, ((r.y + y) * img.width + r.x + r.w) * 4), y * r.w * 4);
  return out;
}

const inRect = (x: number, y: number, r: PixelRect) => x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;

// ── the captured display ────────────────────────────────────────────────────

describe("capturedDisplay", () => {
  it("one display: the frames show it, origin at 0,0, in CSS px", () => {
    expect(capturedDisplay({ width: 1440, height: 900, isExtended: false }, { width: 2880, height: 1800 })).toEqual({ left: 0, top: 0, width: 1440, height: 900 });
    // A 16-inch MacBook (3456×2234) captured within the 3840×2160 cap: scaled, same shape.
    expect(capturedDisplay({ width: 1728, height: 1117, isExtended: false }, { width: 3341, height: 2160 })).not.toBeNull();
    // Windows at 150 %: 2560×1440 → 1707×960 CSS px.
    expect(capturedDisplay({ width: 1707, height: 960, isExtended: false }, { width: 2560, height: 1440 })).not.toBeNull();
  });

  it("several displays — or a browser that doesn't say — is ambiguous: no display", () => {
    expect(capturedDisplay({ width: 1440, height: 900, isExtended: true }, { width: 2880, height: 1800 })).toBeNull();
    expect(capturedDisplay({ width: 1440, height: 900 }, { width: 2880, height: 1800 })).toBeNull();
  });

  it("frames of another shape aren't this display", () => {
    expect(capturedDisplay({ width: 1440, height: 900, isExtended: false }, { width: 1920, height: 1080 })).toBeNull();
    expect(capturedDisplay({ width: 1440, height: 900, isExtended: false }, { width: 0, height: 0 })).toBeNull();
  });
});

// ── the rect ────────────────────────────────────────────────────────────────

describe("plateTarget → toFramePixels (screen CSS px → frame px)", () => {
  const display: Display = { left: 0, top: 0, width: 1440, height: 900 };
  const geom: WindowGeometry = { x: 960, y: 760, width: 440, height: 100, innerWidth: 440, innerHeight: 72 };

  it("pads for the shadow and maps through the capture's scale (Retina 2×)", () => {
    const t = plateTarget(geom, display);
    expect(t.kind).toBe("paint");
    const rect = (t as { rect: UnitRect }).rect;
    const px = toFramePixels(rect, 2880, 1800)!;
    // (960−12 … 1400+12) × 2, (760−10 … 860+20) × 2 — outward by at most one even step.
    const want = { x0: 948 * 2, y0: 750 * 2, x1: 1412 * 2, y1: 880 * 2 };
    expect(px.x).toBeLessThanOrEqual(want.x0);
    expect(px.y).toBeLessThanOrEqual(want.y0);
    expect(px.x + px.w).toBeGreaterThanOrEqual(want.x1);
    expect(px.y + px.h).toBeGreaterThanOrEqual(want.y1);
    expect(want.x0 - px.x + (px.x + px.w - want.x1)).toBeLessThanOrEqual(4);
    expect(want.y0 - px.y + (px.y + px.h - want.y1)).toBeLessThanOrEqual(4);
  });

  it("rounds outward to even pixels at a fractional scale — the window is always covered", () => {
    const frame = { width: 3341, height: 2160 };
    const d: Display = { left: 0, top: 0, width: 1728, height: 1117 };
    const g: WindowGeometry = { x: 1001.3, y: 501.7, width: 441, height: 99, innerWidth: 441, innerHeight: 71 };
    const px = toFramePixels((plateTarget(g, d) as { rect: UnitRect }).rect, frame.width, frame.height)!;
    for (const v of [px.x, px.y, px.w, px.h]) expect(v % 2).toBe(0);
    const s = frame.width / d.width;
    expect(px.x).toBeLessThanOrEqual((g.x - SHADOW_PAD.left) * s);
    expect(px.y).toBeLessThanOrEqual((g.y - SHADOW_PAD.top) * (frame.height / d.height));
    expect(px.x + px.w).toBeGreaterThanOrEqual((g.x + g.width + SHADOW_PAD.right) * s);
    expect(px.y + px.h).toBeGreaterThanOrEqual((g.y + g.height + SHADOW_PAD.bottom) * (frame.height / d.height));
  });

  it("clamps a window running off the display; one fully off it is outside", () => {
    const off = plateTarget({ ...geom, x: 1300 }, display);
    const px = toFramePixels((off as { rect: UnitRect }).rect, 2880, 1800)!;
    expect(px.x + px.w).toBe(2880);
    expect(plateTarget({ ...geom, x: 1500 }, display).kind).toBe("outside");
    expect(plateTarget({ ...geom, y: -200 }, display).kind).toBe("outside");
    // An odd-sized frame still clamps to its edge.
    expect(toFramePixels({ x: 0.9, y: 0.9, w: 0.2, h: 0.2 }, 1279, 719)).toEqual({ x: 1150, y: 646, w: 129, h: 73 });
  });

  it("geometry that can't be placed is unknown", () => {
    expect(plateTarget({ ...geom, width: 0 }, display).kind).toBe("unknown");
    expect(plateTarget({ ...geom, x: Number.NaN }, display).kind).toBe("unknown");
  });
});

describe("RectHold", () => {
  const a: UnitRect = { x: 0.1, y: 0.1, w: 0.1, h: 0.1 };
  const b: UnitRect = { x: 0.5, y: 0.6, w: 0.1, h: 0.1 };

  it("paints every rect current in the last holdMs (bounding box), then only the newest", () => {
    const hold = new RectHold(300);
    expect(hold.at(0)).toBeNull();
    hold.set(a, 1000);
    expect(hold.at(1100)).toEqual(a);
    hold.set(b, 2000);
    const both = hold.at(2100)!;
    expect(both.x).toBeCloseTo(0.1);
    expect(both.y).toBeCloseTo(0.1);
    expect(both.x + both.w).toBeCloseTo(0.6);
    expect(both.y + both.h).toBeCloseTo(0.7);
    expect(hold.at(2301)).toEqual(b);
  });

  it("a closed window (null) keeps its last rect for the hold, then nothing", () => {
    const hold = new RectHold(300);
    hold.set(a, 0);
    hold.set(null, 1000);
    expect(hold.at(1200)).toEqual(a);
    expect(hold.at(1301)).toBeNull();
  });
});

// ── the composite ───────────────────────────────────────────────────────────

describe("composite", () => {
  const W = 320;
  const H = 200;
  const live = image(W, H, (x, y) => [(x * 13) & 255, (y * 7) & 255, ((x + y) * 3) & 255]);
  const plate = image(W, H, (x, y) => [(x * 3 + 1) & 255, (y * 11 + 2) & 255, 77]);
  const rect: PixelRect = { x: 200, y: 140, w: 96, h: 50 };

  it("the plate's pixels over the rect; every other pixel bit-identical to the live frame", () => {
    const ctx = new FakeCtx(W, H);
    composite(ctx, live, { width: W, height: H }, { image: plate, width: W, height: H }, rect);
    let other = 0;
    let wrong = 0;
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        const i = (y * W + x) * 4;
        const src = inRect(x, y, rect) ? plate : live;
        for (let k = 0; k < 4; k++) if (ctx.out.px[i + k] !== src.px[i + k]) wrong++;
        if (!inRect(x, y, rect)) other++;
      }
    }
    expect(wrong).toBe(0);
    expect(other).toBe(W * H - rect.w * rect.h);
  });

  it("no rect (the window is elsewhere) or no plate: the live frame as it is", () => {
    for (const [p, r] of [[null, rect], [{ image: plate, width: W, height: H }, null]] as const) {
      const ctx = new FakeCtx(W, H);
      composite(ctx, live, { width: W, height: H }, p, r);
      expect(Array.from(ctx.out.px)).toEqual(Array.from(live.px));
      expect(ctx.calls).toBe(1);
    }
  });

  it("a plate of another size (the display changed resolution) is scaled onto the rect", () => {
    const small = image(W / 2, H / 2, () => [9, 9, 9]);
    const ctx = new FakeCtx(W, H);
    composite(ctx, live, { width: W, height: H }, { image: small, width: W / 2, height: H / 2 }, rect);
    expect(Array.from(crop(ctx.out, rect)).filter((_, i) => i % 4 !== 3).every((v) => v === 9)).toBe(true);
  });
});

// ── the beacon ──────────────────────────────────────────────────────────────

describe("findBeacon / verifyPlacement", () => {
  const display: Display = { left: 0, top: 0, width: 640, height: 400 };
  const frame = { width: 1280, height: 800 }; // 2×
  const scale = 2;
  const geom: WindowGeometry = { x: 380, y: 300, width: 220, height: 64, innerWidth: 220, innerHeight: 40 };
  const paintedFor = (g: WindowGeometry): PixelRect => toFramePixels((plateTarget(g, display) as { rect: UnitRect }).rect, frame.width, frame.height)!;

  function check(raw: Img, painted: PixelRect, g = geom) {
    const region = checkRegion(painted, g, scale, 24 * scale, frame)!;
    return verifyPlacement({ px: crop(raw, region), region, painted, frame, scale, geom: g });
  }

  it("finds the stripe: red run, then dark", () => {
    const raw = displayFrame(frame, display, geom);
    const region: PixelRect = { x: 700, y: 560, w: 560, h: 120 };
    const s = findBeacon(crop(raw, region), region.w, region.h, 300)!;
    expect(s).not.toBeNull();
    expect(region.x + s.left).toBe(760);
    expect(region.x + s.right).toBe(1200);
    expect(region.y + s.top).toBe((300 + 24) * 2);
    expect(s.bottom - s.top).toBe(BEACON.stripe * 2);
  });

  it("ok where it's painted; missing or outside when the window isn't there", () => {
    const painted = paintedFor(geom);
    expect(check(displayFrame(frame, display, geom), painted)).toBe("ok");
    // Not on screen at all (closed, covered): nothing to vouch with.
    expect(check(displayFrame(frame, display, null), painted)).toBe("missing");
    // Dragged a little — further than the shadow pad — while the reported position stayed put.
    expect(check(displayFrame(frame, display, { ...geom, x: geom.x - 20 }), painted)).toBe("outside");
    // Dragged far away: the beacon left the region.
    expect(check(displayFrame(frame, display, { ...geom, x: 40, y: 40 }), painted)).toBe("missing");
    // Within the pad: still covered.
    expect(check(displayFrame(frame, display, { ...geom, x: geom.x - 6 }), painted)).toBe("ok");
  });

  it("a red background without the dark band is not the beacon", () => {
    const raw = image(frame.width, frame.height, () => RED);
    expect(check(raw, paintedFor(geom))).toBe("missing");
  });

  it("a window running off the display edge is vouched for by its visible stripe", () => {
    const g = { ...geom, x: 520 }; // 100 CSS px past the right edge
    const painted = paintedFor(g);
    expect(painted.x + painted.w).toBe(frame.width);
    expect(check(displayFrame(frame, display, g), painted)).toBe("ok");
  });

  it("while a move stretches the painted rect (the hold), the window anywhere inside it is ok", () => {
    const moved = { ...geom, x: 300, y: 200 };
    const a = (plateTarget(geom, display) as { rect: UnitRect }).rect;
    const b = (plateTarget(moved, display) as { rect: UnitRect }).rect;
    const hold = new RectHold(300);
    hold.set(a, 0);
    hold.set(b, 100);
    const painted = toFramePixels(hold.at(150)!, frame.width, frame.height)!;
    expect(check(displayFrame(frame, display, geom), painted, moved)).toBe("ok");
    expect(check(displayFrame(frame, display, moved), painted, moved)).toBe("ok");
  });
});

// ── the pipeline, end to end on synthetic display frames ────────────────────

describe("a display take's frames (synthetic): plate over the window, checks vouch for it", () => {
  const display: Display = { left: 0, top: 0, width: 640, height: 400 };
  const frame = { width: 1280, height: 800 };
  const scale = frame.width / display.width;
  const geom: WindowGeometry = { x: 380, y: 300, width: 220, height: 64, innerWidth: 220, innerHeight: 40 };

  /** One frame through the worker's steps: hold → frame px → composite → check. */
  function run(raw: Img, reported: WindowGeometry, plate: Img, hold: RectHold, at: number, paintPlate = true) {
    const t = plateTarget(reported, display);
    if (t.kind === "paint") hold.set(t.rect, at);
    const unit = hold.at(at);
    const painted = unit ? toFramePixels(unit, frame.width, frame.height) : null;
    const ctx = new FakeCtx(frame.width, frame.height);
    composite(ctx, raw, frame, paintPlate ? { image: plate, width: plate.width, height: plate.height } : null, painted);
    const region = painted && checkRegion(painted, reported, scale, 24 * scale, frame);
    const verdict = painted && region ? verifyPlacement({ px: crop(raw, region), region, painted, frame, scale, geom: reported }) : "missing";
    return { out: ctx.out, painted, verdict };
  }

  it("the window is in the raw frames, in no output frame, and the rest of each frame is untouched", () => {
    // The plate: the display before the window opened (seed 0); the take moves on (seeds 1…).
    const plate = displayFrame(frame, display, null, 0);
    const hold = new RectHold();
    for (let k = 1; k <= 3; k++) {
      const raw = displayFrame(frame, display, geom, k);
      expect(cyanBlob(raw)).toBeGreaterThan(1000); // the gate can see it
      const { out, painted, verdict } = run(raw, geom, plate, hold, k * 16);
      expect(verdict).toBe("ok");
      expect(cyanBlob(out)).toBe(0);
      let changed = 0;
      for (let y = 0; y < frame.height; y++) {
        for (let x = 0; x < frame.width; x++) {
          if (inRect(x, y, painted!)) continue;
          const i = (y * frame.width + x) * 4;
          if (out.px[i] !== raw.px[i] || out.px[i + 1] !== raw.px[i + 1] || out.px[i + 2] !== raw.px[i + 2]) changed++;
        }
      }
      expect(changed).toBe(0);
    }
  });

  it("defect — compositing off: the window is in the output (the blob check can fail)", () => {
    const plate = displayFrame(frame, display, null, 0);
    const { out } = run(displayFrame(frame, display, geom, 1), geom, plate, new RectHold(), 16, false);
    expect(cyanBlob(out)).toBeGreaterThan(1000);
  });

  it("a drag the reported position didn't follow leaks past the paint — and the check catches every such frame", () => {
    const plate = displayFrame(frame, display, null, 0);
    const hold = new RectHold();
    run(displayFrame(frame, display, geom, 1), geom, plate, hold, 0);
    // The window travels; screenX/screenY stay where the drag began (macOS reports a move at its end).
    for (let k = 1; k <= 6; k++) {
      const actual = { ...geom, x: geom.x - 40 * k, y: geom.y - 25 * k };
      const { out, verdict } = run(displayFrame(frame, display, actual, k), geom, plate, hold, 1000 + k * 16);
      expect(cyanBlob(out)).toBeGreaterThan(0); // painted over the stale place: it shows…
      expect(verdict).not.toBe("ok"); // …and that frame is cut
    }
    // The move is reported: painted where it is, vouched for again.
    const end = { ...geom, x: geom.x - 240, y: geom.y - 150 };
    const { out, verdict } = run(displayFrame(frame, display, end, 9), end, plate, hold, 3000);
    expect(verdict).toBe("ok");
    expect(cyanBlob(out)).toBe(0);
  });
});
