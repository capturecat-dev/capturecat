/**
 * The camera looks against the CONTRACT's own formulas (docs/camera-cutout.md),
 * so the port is checked before the Mac's golden vectors exist (those lock it
 * to Swift: core/vectors/cameraLooks.test.ts).
 */
import { describe, expect, it } from "vitest";
import { parseProject, serializeProject, newProject, type CameraLayoutRegion } from "../model";
import { decodeCameraLayoutRegion } from "../model/parse";
import { ease, lookWeights, resolve, transitionDuration } from "./cameraLayoutMath";
import { bubbleWeight, cutoutGeometry, maskIsFresh, personRect } from "./cameraCutoutMath";
import { producerMaskSize } from "../mask/conditionAlpha";

const R = (startTime: number, endTime: number, mode: CameraLayoutRegion["mode"], look?: CameraLayoutRegion["look"]): CameraLayoutRegion => ({
  id: `00000000-0000-0000-0000-${String(Math.round(startTime * 1000)).padStart(12, "0")}`,
  startTime,
  endTime,
  mode,
  ...(look ? { look } : {}),
});

describe("CameraLayoutRegion.look — model (§1)", () => {
  const decode = (raw: Record<string, unknown>) => decodeCameraLayoutRegion(raw, "r");

  it("decodes look leniently: missing / null / unknown / mistyped → absent", () => {
    expect(decode({ mode: "bubble" }).look).toBeUndefined();
    expect(decode({ mode: "bubble", look: null }).look).toBeUndefined();
    expect(decode({ mode: "bubble", look: "glow" }).look).toBeUndefined();
    expect(decode({ mode: "bubble", look: 3 }).look).toBeUndefined();
    expect(decode({ mode: "bubble", look: "cutout" }).look).toBe("cutout");
    expect(decode({ mode: "sideBySide", look: "popOut" }).look).toBe("popOut");
  });

  it("missing mode → cameraOnly; unknown mode → bubble; a non-string mode still throws", () => {
    expect(decode({}).mode).toBe("cameraOnly");
    expect(decode({ mode: null }).mode).toBe("cameraOnly");
    expect(decode({ mode: "Bogus Future Value" }).mode).toBe("bubble");
    expect(() => decode({ mode: 5 })).toThrow();
  });

  it("look is not an unknown key (no $extra) and encodes only when set", () => {
    const p = newProject({ id: "8A0C2F5E-1B7D-4E6A-9C3F-2D4B6A8C0E1F", name: "looks", videoURL: "file:///x/recording.mov", duration: 20 });
    p.cameraLayoutRegions = [R(1, 3, "bubble", "cutout"), R(5, 8, "cameraOnly")];
    const json = serializeProject(p) as { cameraLayoutRegions: Record<string, unknown>[] };
    expect(json.cameraLayoutRegions[0]).toEqual({ id: p.cameraLayoutRegions[0]!.id, startTime: 1, endTime: 3, mode: "bubble", look: "cutout" });
    expect("look" in json.cameraLayoutRegions[1]!).toBe(false);
    const back = parseProject(json);
    expect(back.cameraLayoutRegions[0]!.look).toBe("cutout");
    expect(back.cameraLayoutRegions[0]!.$extra).toBeUndefined();
    expect(serializeProject(back)).toEqual(json);
  });
});

describe("lookWeights (§4)", () => {
  it("no regions / outside every region / non-bubble mode → no look", () => {
    expect(lookWeights(3, [])).toEqual({ cutout: 0, popOut: 0 });
    const regions = [R(2, 4, "sideBySide", "cutout")];
    expect(lookWeights(3, regions)).toEqual({ cutout: 0, popOut: 0 });
    expect(lookWeights(10, regions)).toEqual({ cutout: 0, popOut: 0 });
  });

  it("settles on the containing bubble region's look", () => {
    const regions = [R(2, 6, "bubble", "popOut")];
    expect(lookWeights(2 + transitionDuration + 0.01, regions)).toEqual({ cutout: 0, popOut: 1 });
  });

  it("eases in at the start edge with smootherstep over 0.45 s", () => {
    const regions = [R(2, 6, "bubble", "cutout")];
    for (const dt of [0, 0.1, 0.2, 0.3, 0.44]) {
      const w = lookWeights(2 + dt, regions);
      expect(w.cutout).toBeCloseTo(ease(dt / transitionDuration), 12);
      expect(w.popOut).toBe(0);
    }
    const mid = lookWeights(2.225, regions).cutout;
    expect(mid).toBeGreaterThan(0);
    expect(mid).toBeLessThan(1);
  });

  it("eases out after the end edge", () => {
    const regions = [R(2, 6, "bubble", "cutout")];
    expect(lookWeights(6, regions).cutout).toBe(1); // closed interval: still inside
    const w = lookWeights(6.1, regions);
    expect(w.cutout).toBeCloseTo(1 - ease(0.1 / transitionDuration), 12);
    expect(lookWeights(6 + transitionDuration, regions).cutout).toBe(0);
  });

  it("look → look cross-fades, summing to 1", () => {
    const regions = [R(2, 4, "bubble", "cutout"), R(4, 8, "bubble", "popOut")];
    const w = lookWeights(4.2, regions);
    const p = ease(0.2 / transitionDuration);
    expect(w.cutout).toBeCloseTo(1 - p, 12);
    expect(w.popOut).toBeCloseTo(p, 12);
    expect(w.cutout + w.popOut).toBeCloseTo(1, 12);
    expect(bubbleWeight(w)).toBeCloseTo(0, 12);
  });

  it("a look fades out across a mode morph that resolve also morphs", () => {
    const regions = [R(2, 4, "bubble", "cutout"), R(4, 8, "cameraOnly")];
    const w = lookWeights(4.2, regions);
    expect(w.cutout).toBeCloseTo(1 - ease(0.2 / transitionDuration), 12);
    const r = resolve(4.2, regions, { x: 0, y: 0, width: 100, height: 60 }, { x: 70, y: 40, width: 20, height: 20 }, 10, 4, true);
    expect(r.isPlainBubble).toBe(false);
  });

  it("no morph at edges ≤ 0.05 s (no intro morph at t = 0)", () => {
    const regions = [R(0, 4, "bubble", "popOut")];
    expect(lookWeights(0, regions)).toEqual({ cutout: 0, popOut: 1 });
    expect(lookWeights(0.1, regions)).toEqual({ cutout: 0, popOut: 1 });
    const near = [R(0.05, 4, "bubble", "popOut")];
    expect(lookWeights(0.1, near)).toEqual({ cutout: 0, popOut: 1 });
  });

  it("a non-bubble region's look is ignored, and so is its edge", () => {
    const regions = [R(2, 4, "bubble"), R(4, 6, "screenOnly", "cutout")];
    expect(lookWeights(4.1, regions)).toEqual({ cutout: 0, popOut: 0 });
  });
});

describe("cutout geometry (§3)", () => {
  const B = { x: 100, y: 200, width: 300, height: 300 };

  it("person rect = the exporter's aspect fill of the camera into B", () => {
    const wide = personRect(B, 16 / 9);
    expect(wide.width).toBeCloseTo(300 * 16 / 9, 9);
    expect(wide.height).toBe(300);
    expect(wide.x + wide.width / 2).toBeCloseTo(250, 9);
    expect(wide.y).toBe(200);
    const tall = { x: 0, y: 0, width: 200, height: 100 };
    const p = personRect(tall, 1);
    expect(p).toEqual({ x: 0, y: -50, width: 200, height: 200 });
  });

  it("cutout: clip = B, no card, radii 0", () => {
    const g = cutoutGeometry("cutout", B, 16 / 9);
    expect(g.clipRect).toEqual(B);
    expect(g.cardRect).toBeNull();
    expect(g.clipBottomCornerRadius).toBe(0);
    expect(g.cardCornerRadius).toBe(0);
  });

  it("pop-out: card = B minus 22% headroom at the top, r = 16% of the card's short side", () => {
    const g = cutoutGeometry("popOut", B, 16 / 9);
    const headroom = 0.22 * 300;
    expect(g.cardRect).toEqual({ x: 100, y: 200 + headroom, width: 300, height: 300 - headroom });
    expect(g.cardCornerRadius).toBeCloseTo(0.16 * (300 - headroom), 12);
    expect(g.clipBottomCornerRadius).toBe(g.cardCornerRadius);
    expect(g.clipRect).toEqual(B);
  });
});

describe("mask track rules (§2)", () => {
  it("resolution: height 192, width round(192 × aspect) capped at 341 (producer rule)", () => {
    expect(producerMaskSize(16 / 9)).toEqual({ width: 341, height: 192 });
    expect(producerMaskSize(4 / 3)).toEqual({ width: 256, height: 192 });
    expect(producerMaskSize(9 / 16)).toEqual({ width: 108, height: 192 });
    expect(producerMaskSize(21 / 9)).toEqual({ width: 341, height: 192 });
    expect(producerMaskSize(Number.NaN)).toEqual({ width: 192, height: 192 });
  });

  it("staleness: same byte size and duration within 0.05 s", () => {
    const h = { sourceByteSize: 1234, sourceDuration: 10 };
    expect(maskIsFresh(h, { byteSize: 1234, duration: 10.04 })).toBe(true);
    expect(maskIsFresh(h, { byteSize: 1234, duration: 9.96 })).toBe(true);
    expect(maskIsFresh(h, { byteSize: 1234, duration: 10.051 })).toBe(false);
    expect(maskIsFresh(h, { byteSize: 1235, duration: 10 })).toBe(false);
    expect(maskIsFresh(h, { byteSize: null, duration: 10 })).toBe(false);
  });
});
