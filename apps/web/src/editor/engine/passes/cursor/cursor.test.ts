import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { parseProject } from "../../../core/model";
import type { CursorEvent } from "../../../core/model/types";
import { CursorStyle } from "../../../core/model/enums";
import { renderClickRipple } from "../../../core/math/exportCursor";
import { asset as styleAsset } from "../../../core/math/cursorStyleProvider";
import { rasterizeArtwork } from "./artworkRaster";
import { parseCursorArt, resampleRGBA, spriteRaster } from "./cursorArt";
import { rippleWindow } from "./cursorFrame";
import { ciDownsampleLevels, ciGaussianWeights, spriteLevel } from "./passMath";
import { decodeCursorRecording, decodeKeystrokeRecording } from "./recordings";
import { genericRGBToSRGB } from "./rippleColor";
import { soundCues } from "./soundCues";

const WEB = join(__dirname, "../../../../..");
const PARITY = join(WEB, ".fixtures/parity");

describe("ripple colour (CGColor(red:green:blue:) = Generic RGB → sRGB context)", () => {
  // CGColor.converted(to: sRGB) on macOS 26.2 (scratch probe, Swift).
  const cases: [number[], number[]][] = [
    [[0.5, 0.5, 0.5], [0.572307, 0.572307, 0.572307]],
    [[0.1, 0.1, 0.1], [0.132609, 0.132609, 0.132609]],
    [[1, 0, 0], [1, 0.1491, 0]],
    [[0, 1, 0], [0, 0.976789, 0]],
    [[0, 0, 1], [0.016842, 0.198341, 1]],
    [[1, 0.8, 0.1], [1, 0.829102, 0.11872]],
    [[0.2, 0.5, 0.9], [0.247895, 0.584076, 0.92089]],
    [[1, 1, 1], [1, 1, 1]],
  ];
  it("matches ColorSync within 3e-4", () => {
    for (const [inp, want] of cases) {
      const got = genericRGBToSRGB(inp[0], inp[1], inp[2]);
      got.forEach((v, i) => expect(Math.abs(v - want[i])).toBeLessThan(3e-4));
    }
    // The exporter's 8-bit bytes for (1, 0.8, 0.1): BGRA 30 211 255.
    expect(genericRGBToSRGB(1, 0.8, 0.1).map((v) => Math.round(v * 255))).toEqual([255, 211, 30]);
  });
});

describe("CIGaussianBlur kernel", () => {
  // Impulse responses of CIGaussianBlur (float context, macOS 26.2), centre tap first.
  const probed: Record<number, number[]> = {
    0.5: [0.68262, 0.15735, 0.00135],
    1: [0.38281, 0.24182, 0.0607, 0.00605],
    1.5: [0.26099, 0.21106, 0.11053, 0.03793, 0.00853, 0.00125],
    2: [0.19739, 0.17432, 0.12122, 0.06573, 0.02776, 0.00932, 0.00249],
  };
  it("taps and radius match the probe", () => {
    for (const [sigma, want] of Object.entries(probed)) {
      const got = ciGaussianWeights(Number(sigma));
      expect(got.length).toBe(want.length);
      got.forEach((w, i) => expect(Math.abs(w - want[i])).toBeLessThan(6e-4));
    }
  });
});

/** Deterministic synthetic path: moves, clicks (1–4 samples), drags, pauses. */
function syntheticEvents(seed: number, n: number): CursorEvent[] {
  let s = seed >>> 0;
  const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
  const out: CursorEvent[] = [];
  let t = 0;
  let x = 400;
  let y = 300;
  while (out.length < n) {
    const kind = rnd();
    const len = 1 + Math.floor(rnd() * (kind < 0.3 ? 4 : 30));
    const click = kind < 0.3 || (kind > 0.9);
    const drag = kind > 0.9;
    for (let i = 0; i < len && out.length < n; i++) {
      t += 1 / 60 + (rnd() < 0.05 ? rnd() * 0.4 : 0);
      if (!click || drag) {
        x += (rnd() - 0.5) * (drag ? 30 : 12);
        y += (rnd() - 0.5) * (drag ? 30 : 12);
      }
      out.push({ timestamp: t, x, y, isClick: click });
    }
  }
  return out;
}

describe("CoreImage pre-downsample (probed thresholds)", () => {
  it("halves an axis only while its scale is < 0.4375 (0.4375 itself samples bilinearly)", () => {
    const t = (sx: number, sy: number) => ({ a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0 });
    expect(ciDownsampleLevels(t(0.4375, 0.4375))).toEqual({ lx: 0, ly: 0 });
    expect(ciDownsampleLevels(t(0.434, 0.69))).toEqual({ lx: 1, ly: 0 });
    expect(ciDownsampleLevels(t(0.45, 0.4))).toEqual({ lx: 0, ly: 1 });
    expect(ciDownsampleLevels(t(0.22, 0.215))).toEqual({ lx: 1, ly: 2 });
    const r = 0.42; // rotated: column lengths decide
    expect(ciDownsampleLevels({ a: r * Math.cos(0.5), b: r * Math.sin(0.5), c: -r * Math.sin(0.5), d: r * Math.cos(0.5), tx: 0, ty: 0 })).toEqual({ lx: 1, ly: 1 });
  });
  it("box-halves with the odd pixel paired with clear at the END of CI's Y-up axis", () => {
    // 1×3 column, top-down rows [10, 20, 30] (alpha = value): CI Y-up pairs (30,20) and (10, clear).
    const base = new Uint8Array([10, 10, 10, 10, 20, 20, 20, 20, 30, 30, 30, 30]);
    const l = spriteLevel(base, 1, 3, 0, 1);
    expect([l.width, l.height]).toEqual([1, 2]);
    expect(Array.from(l.data.filter((_, i) => i % 4 === 3))).toEqual([5, 25]);
    // base row centre v (top-down) → level: (v + 1) / 2
    expect([l.sy, l.oy]).toEqual([0.5, 0.5]);
  });
});

describe("rippleWindow", () => {
  it("renderClickRipple on the window == on the whole list", () => {
    const rect = { x: 40, y: 60, width: 1100, height: 620 };
    for (const seed of [1, 2, 3, 7, 11]) {
      const events = syntheticEvents(seed, 4000);
      const end = events[events.length - 1].timestamp;
      for (let t = -0.2; t < end + 0.5; t += 0.0137) {
        const full = renderClickRipple(t, events, { width: 1512, height: 982 }, rect, { clickRippleSize: 44 });
        const win = renderClickRipple(t, rippleWindow(events, t), { width: 1512, height: 982 }, rect, { clickRippleSize: 44 });
        expect(win.draws).toBe(full.draws);
        expect(win.dragStrength).toBe(full.dragStrength);
        expect(win.draw).toEqual(full.draw);
      }
    }
  });
});

describe("recordings", () => {
  it("decodes CursorRecording, legacy arrays, and rejects bad files like Swift's try?", () => {
    const ev = { timestamp: 0.5, x: 1, y: 2, isClick: false };
    expect(decodeCursorRecording({ version: 2, coordinateWidth: 10, coordinateHeight: 5, events: [ev] })?.events).toEqual([ev]);
    expect(decodeCursorRecording([ev])).toEqual({ version: 1, coordinateWidth: 0, coordinateHeight: 0, events: [ev] });
    expect(decodeCursorRecording({ version: 2, coordinateWidth: 10, events: [ev] })).toBeNull();
    expect(decodeCursorRecording({ version: 2, coordinateWidth: 10, coordinateHeight: 5, events: [{ ...ev, isClick: 1 }] })).toBeNull();
    expect(decodeKeystrokeRecording({ version: 1, events: [{ timestamp: 1, category: "key", shortcut: "⌘S" }] })?.events).toEqual([
      { timestamp: 1, category: "key", shortcut: "⌘S" },
    ]);
    expect(decodeKeystrokeRecording({ version: 1, events: [{ timestamp: 1, category: "bogus" }] })).toBeNull();
  });
});

const MANIFEST = join(WEB, "public/editor/cursors/manifest.json");

describe("shipped cursor art (CaptureCat --web-cursor-sprites)", () => {
  const art = parseCursorArt(JSON.parse(readFileSync(MANIFEST, "utf8")));
  it("covers every CursorStyle at 1×/2×/3× with the provider's point size + hotspot", () => {
    expect(art).not.toBeNull();
    for (const style of Object.values(CursorStyle)) {
      const s = art!.styles.get(style)!;
      const a = styleAsset(style);
      expect(s.pointSize).toEqual(a.imageSize);
      expect(s.hotSpot).toEqual(a.hotSpot);
      expect(s.rasters.map((r) => [r.scale, r.width, r.height])).toEqual(
        [1, 2, 3].map((k) => [k, a.imageSize.width * k, a.imageSize.height * k]),
      );
      for (const r of s.rasters) {
        for (let i = 0; i < r.rgba.length; i += 4) {
          // premultiplied: colour ≤ alpha
          expect(Math.max(r.rgba[i], r.rgba[i + 1], r.rgba[i + 2]) <= r.rgba[i + 3]).toBe(true);
        }
      }
    }
  });
  it("uses the Swift bytes whenever the export grid matches a shipped raster", () => {
    const r = spriteRaster(CursorStyle.hand, { width: 96, height: 96 }, art);
    expect(r?.origin).toBe("swift");
    expect(spriteRaster(CursorStyle.hand, { width: 107, height: 107 }, art)?.origin).toBe("resampled");
    expect(spriteRaster(CursorStyle.system, { width: 50, height: 70 }, art)?.origin).toBe("analytic");
    const two = art!.styles.get(CursorStyle.hand)!.rasters[1];
    expect(Array.from(resampleRGBA(two, 64, 64))).toEqual(Array.from(two.rgba));
  });
  it("Hand magnification reproduces CG's `.high` filter (2× rep → the REAL 3× raster)", () => {
    const hand = art!.styles.get(CursorStyle.hand)!;
    const up = resampleRGBA(hand.rasters[1], 96, 96);
    let max = 0;
    for (let i = 0; i < up.length; i++) max = Math.max(max, Math.abs(up[i] - hand.rasters[2].rgba[i]));
    expect(max).toBeLessThanOrEqual(2);
  });
});

describe("analytic artwork rasterizer vs the REAL CursorStyleProvider rasters", () => {
  const art = parseCursorArt(JSON.parse(readFileSync(MANIFEST, "utf8")))!;
  // Measured 2026-09-30 (see artworkRaster.ts): arrows mean ≤ 0.19, ovals ≤ 0.73;
  // max ≤ 23 on a few curve pixels (CG's arc flattening is not reproduced exactly).
  const limits: Record<string, { mean: number; max: number }> = {
    "macOS Arrow": { mean: 0.25, max: 24 },
    "White Arrow": { mean: 0.12, max: 16 },
    Dot: { mean: 0.6, max: 20 },
    Ring: { mean: 0.8, max: 24 },
  };
  for (const [style, lim] of Object.entries(limits)) {
    it(`${style} at 1×/2×/3×`, () => {
      for (const ref of art.styles.get(style)!.rasters) {
        const px = rasterizeArtwork(style as CursorStyle, { width: ref.width, height: ref.height })!;
        let max = 0;
        let sum = 0;
        for (let i = 0; i < px.length; i++) {
          const d = Math.abs(px[i] - ref.rgba[i]);
          max = Math.max(max, d);
          sum += d;
        }
        expect(sum / px.length).toBeLessThanOrEqual(lim.mean);
        expect(max).toBeLessThanOrEqual(lim.max);
      }
    });
  }
});

describe("soundCues", () => {
  const fixture = join(PARITY, "01-baseline-gradient");
  it.skipIf(!existsSync(fixture))("maps discrete clicks to OUTPUT time with the 50 ms throttle", () => {
    const doc = JSON.parse(readFileSync(join(fixture, "project.json"), "utf8"));
    doc.settings.clickSoundEnabled = true;
    doc.settings.cursorFluidEnabled = false; // raw path: click times = sample times
    // 60 Hz path, still presses at 1.0, 1.03 (< 50 ms later → throttled), 2.5 and 3.9 s;
    // a DRAG at 3.0 s (moves 40 pt) makes no click sound, exactly like no ripple.
    const events: CursorEvent[] = [];
    for (let i = 0; i <= 300; i++) {
      const t = i / 60;
      const press = [1.0, 1.0333, 2.5, 3.9].some((c) => t >= c - 1e-6 && t < c + 0.02) || (t >= 3.0 && t < 3.1);
      const x = t >= 3.0 && t < 3.1 ? 300 + (t - 3.0) * 400 : 300;
      events.push({ timestamp: t, x, y: 200, isClick: press });
    }
    const cursor = { version: 2, coordinateWidth: 960, coordinateHeight: 540, events };
    doc.trimStart = 0.5;
    doc.speedRegions = [{ id: "5E2B7C1A-0000-4000-8000-000000000001", startTime: 2, endTime: 3, speed: 2 }];
    const cues = soundCues(parseProject(doc), cursor, null);
    // output = (t − 0.5) with the 2 s…3 s span at 2× (2.5 → 1.5 + 0.25).
    const want = [0.5, 1.75, 3.9 - 0.5 - 0.5];
    expect(cues.clicks.length).toBe(want.length);
    cues.clicks.forEach((t, i) => expect(Math.abs(t - want[i])).toBeLessThan(1e-6));
    expect(cues.keys).toEqual([]);
    // Disabled → nothing (the exporter only computes clickTimes when enabled).
    doc.settings.clickSoundEnabled = false;
    expect(soundCues(parseProject(doc), cursor, null).clicks).toEqual([]);
  });
  it("keys: non-scroll events inside the trim, mapped + seeded", () => {
    const fixture01 = join(PARITY, "01-baseline-gradient");
    if (!existsSync(fixture01)) return;
    const doc = JSON.parse(readFileSync(join(fixture01, "project.json"), "utf8"));
    doc.settings.keySoundEnabled = true;
    doc.keystrokeDataURL = "keys.json";
    doc.trimStart = 0.5;
    const keys = {
      version: 1,
      events: [
        { timestamp: 0.2, category: "key" },
        { timestamp: 1.0, category: "space" },
        { timestamp: 1.5, category: "scroll" },
        { timestamp: 2.0, category: "modifier", shortcut: "⌘S" },
      ],
    };
    const cues = soundCues(parseProject(doc), null, keys);
    expect(cues.keyEvents.map((k) => [k.category, k.seed])).toEqual([["space", 1.0], ["modifier", 2.0]]);
    cues.keys.forEach((t, i) => expect(Math.abs(t - [0.5, 1.5][i])).toBeLessThan(1e-9));
  });
});
