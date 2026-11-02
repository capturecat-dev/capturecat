/**
 * Camera styles (docs/camera-cutout.md §12) against the CONTRACT's own
 * formulas — model keys, pop-out geometry, the border ring, Side by Side
 * camera side and its morph, Shrink during zoom, the resolved card style —
 * before the Mac's regenerated golden vectors lock them to Swift
 * (core/vectors/cameraLooks.test.ts, style.test.ts, model.test.ts).
 */
import { describe, expect, it } from "vitest";
import { newProject, parseProject, serializeProject, type CameraLayoutRegion, type ProjectSettings } from "../model";
import { decodeCameraLayoutRegion } from "../model/parse";
import {
  arrangement,
  cardTransform,
  columns,
  ease,
  lookWeights,
  resolve,
  stackActive,
  stackRatio,
  stackRows,
  transitionDuration,
} from "./cameraLayoutMath";
import { exportCameraStatics, exportFrameCamera } from "./exportCameraBubble";
import { applyTransform } from "./geometry";
import { defaultProjectSettings } from "../model";
import { setAspectRatio } from "../../state/edits";
import { rectApplying } from "./geometry";
import { cardBorderInner, cutoutGeometry, headroomForAmount, popOutCardBottom, popOutCardTop } from "./cameraCutoutMath";
import { blurSigma, borderColors, cameraCardStyle, geometryBorderWidth, imageFillRect, processesMaskEdge } from "./cameraCardStyle";
import { layoutZoom } from "./reactiveCameraLayout";

const ID = "8A0C2F5E-1B7D-4E6A-9C3F-2D4B6A8C0E1F";
const project = () => newProject({ id: ID, name: "styles", videoURL: "file:///x/recording.mov", duration: 20 });

/** Every §12.1 settings key, in contract order, with a valid value. */
const STYLE_VALUES: Partial<ProjectSettings> = {
  cameraPopOutAmount: 0.8,
  cameraCardFill: "camera",
  cameraCardGradientStart: { red: 1, green: 0, blue: 0, opacity: 1 },
  cameraCardGradientEnd: { red: 0, green: 0, blue: 1, opacity: 0.5 },
  cameraCardColor: { red: 0.2, green: 0.3, blue: 0.4, opacity: 1 },
  cameraCardImagePath: "/CaptureCat/Projects/X/card.png",
  cameraBackgroundBlur: 0.6,
  cameraEdgeSoftness: 0.4,
  cameraEdgeInset: 0.3,
  cameraCardBorder: "aurora",
  cameraCardBorderWidth: 0.25,
  cameraCardBorderColor: { red: 1, green: 1, blue: 1, opacity: 1 },
  cameraShrinkOnZoom: false,
};
const STYLE_KEYS = Object.keys(STYLE_VALUES);

const R = (startTime: number, endTime: number, mode: CameraLayoutRegion["mode"], cameraSide?: CameraLayoutRegion["cameraSide"]): CameraLayoutRegion => ({
  id: `00000000-0000-0000-0000-${String(Math.round(startTime * 1000)).padStart(12, "0")}`,
  startTime,
  endTime,
  mode,
  ...(cameraSide ? { cameraSide } : {}),
});

describe("model (§12.1)", () => {
  it("untouched projects carry none of the keys", () => {
    const json = serializeProject(project()) as { settings: Record<string, unknown> };
    for (const k of STYLE_KEYS) expect(k in json.settings, k).toBe(false);
  });

  it("every key round-trips, written only when set, in contract order right after cameraLook", () => {
    const p = project();
    p.settings.cameraLook = "popOut";
    Object.assign(p.settings, STYLE_VALUES);
    const json = serializeProject(p) as { settings: Record<string, unknown> };
    const keys = Object.keys(json.settings);
    const at = keys.indexOf("cameraLook");
    expect(keys.slice(at + 1, at + 1 + STYLE_KEYS.length)).toEqual(STYLE_KEYS);
    for (const k of STYLE_KEYS) expect(json.settings[k], k).toEqual((STYLE_VALUES as Record<string, unknown>)[k]);
    const back = parseProject(json);
    expect(back.settings).toMatchObject(STYLE_VALUES);
    expect(back.settings.$extra).toBeUndefined();
    expect(serializeProject(back)).toEqual(json);
  });

  it("without cameraLook the keys follow cameraMirrored", () => {
    const p = project();
    p.settings.cameraEdgeInset = 0.5;
    const keys = Object.keys((serializeProject(p) as { settings: Record<string, unknown> }).settings);
    expect(keys.indexOf("cameraEdgeInset")).toBe(keys.indexOf("cameraMirrored") + 1);
  });

  it("decodes leniently: missing, null, unknown or mistyped → absent, never a failed decode", () => {
    const json = serializeProject(project()) as { settings: Record<string, unknown> };
    const garbage: Record<string, unknown[]> = {
      cameraPopOutAmount: [null, "0.5", true, [1]],
      cameraCardFill: [null, "wallpaper", "Gradient", 2],
      cameraCardGradientStart: [null, "#FF0000", { red: 1, green: 0, blue: 0 }, 4],
      cameraCardGradientEnd: [null, { red: "1", green: 0, blue: 0, opacity: 1 }],
      cameraCardColor: [null, [0.1, 0.1, 0.1]],
      cameraCardImagePath: [null, 7, { path: "x" }],
      cameraBackgroundBlur: [null, "lots"],
      cameraEdgeSoftness: [null, false],
      cameraEdgeInset: [null, {}],
      cameraCardBorder: [null, "silver", 1],
      cameraCardBorderWidth: [null, "thick"],
      cameraCardBorderColor: [null, "white"],
      cameraShrinkOnZoom: [null, 0, 1, "false"],
    };
    for (const [key, values] of Object.entries(garbage)) {
      for (const bad of values) {
        const back = parseProject({ ...json, settings: { ...json.settings, [key]: bad } });
        expect((back.settings as unknown as Record<string, unknown>)[key], `${key} = ${JSON.stringify(bad)}`).toBeUndefined();
        expect(back.settings.$extra).toBeUndefined();
      }
    }
  });

  it("numbers are stored as given (clamped where used, never at decode)", () => {
    const json = serializeProject(project()) as { settings: Record<string, unknown> };
    const back = parseProject({ ...json, settings: { ...json.settings, cameraPopOutAmount: 3, cameraEdgeSoftness: -2, cameraCardImagePath: "" } });
    expect(back.settings.cameraPopOutAmount).toBe(3);
    expect(back.settings.cameraEdgeSoftness).toBe(-2);
    expect(back.settings.cameraCardImagePath).toBe("");
    expect(cameraCardStyle(back.settings)).toMatchObject({ popOutAmount: 1, edgeSoftness: 0, imagePath: null });
  });

  it("region cameraSide: leading / trailing round-trip, anything else → absent; encoded only when set", () => {
    const decode = (raw: Record<string, unknown>) => decodeCameraLayoutRegion(raw, "r");
    expect(decode({ mode: "sideBySide", cameraSide: "leading" }).cameraSide).toBe("leading");
    expect(decode({ mode: "sideBySide", cameraSide: "trailing" }).cameraSide).toBe("trailing");
    for (const bad of [undefined, null, "left", "Leading", 1, true]) {
      const r = decode({ mode: "sideBySide", cameraSide: bad });
      expect(r.cameraSide).toBeUndefined();
      expect(r.$extra).toBeUndefined();
    }
    // Kept (but ignored) on any other mode.
    expect(decode({ mode: "bubble", cameraSide: "leading" }).cameraSide).toBe("leading");

    const p = project();
    p.cameraLayoutRegions = [R(1, 3, "sideBySide", "leading"), R(4, 6, "sideBySide", "trailing"), R(7, 9, "sideBySide")];
    p.cameraLayoutRegions[0]!.look = "cutout";
    const json = serializeProject(p) as { cameraLayoutRegions: Record<string, unknown>[] };
    expect(Object.keys(json.cameraLayoutRegions[0]!)).toEqual(["id", "startTime", "endTime", "mode", "look", "cameraSide"]);
    expect(json.cameraLayoutRegions[1]!.cameraSide).toBe("trailing");
    expect("cameraSide" in json.cameraLayoutRegions[2]!).toBe(false);
    expect(serializeProject(parseProject(json))).toEqual(json);
  });
});

describe("pop-out geometry (§12.2)", () => {
  const B = { x: 100, y: 200, width: 300, height: 400 };

  it("headroom = 0.44 × clamp(amount) × B.height; absent = exactly today's 0.22", () => {
    expect(headroomForAmount(null)).toBe(0.22);
    expect(headroomForAmount(0.5)).toBe(0.22);
    expect(headroomForAmount(0)).toBe(0);
    expect(headroomForAmount(1)).toBe(0.44);
    expect(headroomForAmount(7)).toBe(0.44);
    expect(headroomForAmount(-1)).toBe(0);
    expect(cutoutGeometry("popOut", B, 1, 0.5)).toEqual(cutoutGeometry("popOut", B, 1));
  });

  it("amount 0 → the card is B (no breakout); amount 1 → 44 % headroom", () => {
    expect(cutoutGeometry("popOut", B, 1, 0).cardRect).toEqual(B);
    const g = cutoutGeometry("popOut", B, 1, 1);
    expect(g.cardRect).toEqual({ x: 100, y: 200 + 0.44 * 400, width: 300, height: 400 - 0.44 * 400 });
    expect(g.cardCornerRadius).toBeCloseTo(0.16 * Math.min(300, 400 - 0.44 * 400), 12);
    expect(g.clipBottomCornerRadius).toBe(g.cardCornerRadius);
  });

  it("Y-up keeps B's bottom and gives up the top, like §3", () => {
    const g = cutoutGeometry("popOut", B, 1, 1, null, true);
    expect(g.cardRect).toEqual({ x: 100, y: 200, width: 300, height: 400 - 0.44 * 400 });
  });

  it("border: w = clamp(thickness) × 0.08 × min(C.w, C.h); null = no ring; the cutout never has one", () => {
    const card = cutoutGeometry("popOut", B, 1).cardRect!;
    const short = Math.min(card.width, card.height);
    expect(cutoutGeometry("popOut", B, 1).cardBorderWidth).toBe(0);
    expect(cutoutGeometry("popOut", B, 1, null, 1).cardBorderWidth).toBeCloseTo(0.08 * short, 12);
    expect(cutoutGeometry("popOut", B, 1, null, 0.5).cardBorderWidth).toBeCloseTo(0.04 * short, 12);
    expect(cutoutGeometry("popOut", B, 1, null, 3).cardBorderWidth).toBeCloseTo(0.08 * short, 12);
    expect(cutoutGeometry("cutout", B, 1, null, 1).cardBorderWidth).toBe(0);
  });

  it("the ring is inside (C, r) and outside (C inset by w, max(0, r − w)); w ≤ 0 → no ring", () => {
    const g = cutoutGeometry("popOut", B, 1, null, 1);
    const inner = cardBorderInner(g)!;
    const c = g.cardRect!;
    const w = g.cardBorderWidth;
    expect(inner.rect).toEqual({ x: c.x + w, y: c.y + w, width: c.width - 2 * w, height: c.height - 2 * w });
    expect(inner.radius).toBeCloseTo(g.cardCornerRadius - w, 12);
    expect(cardBorderInner(cutoutGeometry("popOut", B, 1, null, 0))).toBeNull();
    expect(cardBorderInner(cutoutGeometry("popOut", B, 1))).toBeNull();
    expect(cardBorderInner(cutoutGeometry("cutout", B, 1, null, 1))).toBeNull();
    // An inner rect with no area → no ring.
    expect(cardBorderInner({ ...g, cardBorderWidth: c.width })).toBeNull();
    // A ring wider than the corner radius → square inner corners.
    expect(cardBorderInner({ ...g, cardBorderWidth: g.cardCornerRadius + 1 })!.radius).toBe(0);
  });
});

describe("Side by Side camera side (§12.6)", () => {
  const V = { x: 40, y: 30, width: 1000, height: 500 };
  const bubble = { x: 900, y: 400, width: 100, height: 100 };

  it("columns leading mirrors trailing: camera first, screen last", () => {
    const t = columns(V);
    const l = columns(V, "leading");
    expect(columns(V, "trailing")).toEqual(t);
    expect(l.camera).toEqual({ x: V.x, y: t.camera.y, width: t.camera.width, height: t.camera.height });
    expect(l.screen).toEqual({ x: V.x + V.width - t.screen.width, y: t.screen.y, width: t.screen.width, height: t.screen.height });
  });

  it("the arrangement is (mode, side while Side by Side, else trailing)", () => {
    const regions = [R(1, 3, "sideBySide", "leading"), R(4, 6, "bubble", "leading"), R(7, 9, "sideBySide", "trailing")];
    expect(arrangement(2, regions)).toEqual({ mode: "sideBySide", side: "leading", split: "tiles", stacked: false });
    expect(arrangement(5, regions)).toEqual({ mode: "bubble", side: "trailing", split: "tiles", stacked: false });
    expect(arrangement(8, regions)).toEqual({ mode: "sideBySide", side: "trailing", split: "tiles", stacked: false });
    expect(arrangement(10, regions)).toEqual({ mode: "bubble", side: "trailing", split: "tiles", stacked: false });
  });

  it("settled leading: the camera on the left, cardTranslationX positive", () => {
    const r = resolve(2, [R(1, 3, "sideBySide", "leading")], V, bubble, 50, 8, true);
    expect(r.cameraRect).toEqual(columns(V, "leading").camera);
    expect(r.cardTranslationX).toBeGreaterThan(0);
    const t = resolve(2, [R(1, 3, "sideBySide")], V, bubble, 50, 8, true);
    expect(t.cardTranslationX).toBeLessThan(0);
    expect(r.cardTranslationX).toBeCloseTo(-t.cardTranslationX, 9);
  });

  it("adjacent splits on opposite sides morph — mid-flight strictly between the endpoints", () => {
    const regions = [R(1, 4, "sideBySide"), R(4, 8, "sideBySide", "leading")];
    const from = resolve(3, regions, V, bubble, 50, 8, true);
    const to = resolve(4 + transitionDuration + 0.01, regions, V, bubble, 50, 8, true);
    const mid = resolve(4 + transitionDuration / 2, regions, V, bubble, 50, 8, true);
    expect(mid.cameraRect!.x).toBeGreaterThan(to.cameraRect!.x);
    expect(mid.cameraRect!.x).toBeLessThan(from.cameraRect!.x);
    expect(mid.cardTranslationX).toBeGreaterThan(from.cardTranslationX);
    expect(mid.cardTranslationX).toBeLessThan(to.cardTranslationX);
    expect(mid.isPlainBubble).toBe(false);
  });

  it("everything else is unchanged: same side, or a side on a non-split block, never morphs", () => {
    const same = [R(1, 4, "sideBySide", "leading"), R(4, 8, "sideBySide", "leading")];
    expect(resolve(4.1, same, V, bubble, 50, 8, true)).toEqual(resolve(6, same, V, bubble, 50, 8, true));
    const ignored = [R(1, 4, "cameraOnly"), R(4, 8, "cameraOnly", "leading")];
    expect(resolve(4.1, ignored, V, bubble, 50, 8, true)).toEqual(resolve(6, ignored, V, bubble, 50, 8, true));
  });
});

describe("full-height split — Split Screen (§12.11)", () => {
  const V = { x: 40, y: 30, width: 1000, height: 500 };
  const bubble = { x: 900, y: 400, width: 100, height: 100 };
  const F = (startTime: number, endTime: number, side?: CameraLayoutRegion["cameraSide"], splitStyle: CameraLayoutRegion["splitStyle"] = "full"): CameraLayoutRegion => ({
    ...R(startTime, endTime, "sideBySide", side),
    splitStyle,
  });
  const at = (t: number, regions: CameraLayoutRegion[]) => resolve(t, regions, V, bubble, 50, 8, true);

  it("model: splitStyle tiles / full round-trip, anything else → absent; encoded only when set, after cameraSide", () => {
    const decode = (raw: Record<string, unknown>) => decodeCameraLayoutRegion(raw, "r");
    expect(decode({ mode: "sideBySide", splitStyle: "full" }).splitStyle).toBe("full");
    expect(decode({ mode: "sideBySide", splitStyle: "tiles" }).splitStyle).toBe("tiles");
    for (const bad of [null, "Full", "split", 9, false]) {
      const r = decode({ mode: "sideBySide", splitStyle: bad });
      expect(r.splitStyle).toBeUndefined();
      expect(r.$extra).toBeUndefined();
    }
    const p = project();
    p.cameraLayoutRegions = [F(1, 3, "leading"), F(4, 6, undefined, "tiles"), R(7, 9, "sideBySide")];
    const json = serializeProject(p) as { cameraLayoutRegions: Record<string, unknown>[] };
    expect(Object.keys(json.cameraLayoutRegions[0]!)).toEqual(["id", "startTime", "endTime", "mode", "cameraSide", "splitStyle"]);
    expect(json.cameraLayoutRegions[1]!.splitStyle).toBe("tiles");
    expect("splitStyle" in json.cameraLayoutRegions[2]!).toBe(false);
    expect(serializeProject(parseProject(json))).toEqual(json);
  });

  it("columns full: both tiles the card's full height at its top, 60 % screen, 3 % gutter; side places them like §12.6", () => {
    const f = columns(V, "trailing", "full");
    expect(f.screen).toEqual({ x: V.x, y: V.y, width: 600, height: 500 });
    expect(f.camera).toEqual({ x: V.x + V.width - (1000 - 600 - 30), y: V.y, width: 370, height: 500 });
    const l = columns(V, "leading", "full");
    expect(l.camera).toEqual({ x: V.x, y: V.y, width: 370, height: 500 });
    expect(l.screen).toEqual({ x: V.x + V.width - 600, y: V.y, width: 600, height: 500 });
    expect(columns(V, "trailing", "tiles")).toEqual(columns(V));
  });

  it("settled full split: card unscaled, slid so the screen's centre sits in its column, clipped to it", () => {
    const r = at(2, [F(1, 3)]);
    const cols = columns(V, "trailing", "full");
    expect(r.cardScale).toBe(1);
    expect(r.cardTranslationX).toBeCloseTo(cols.screen.x + cols.screen.width / 2 - (V.x + V.width / 2), 12);
    expect(r.cameraRect).toEqual(cols.camera);
    expect(r.cameraCornerRadius).toBe(8);
    expect(r.cardClip).toEqual(cols.screen);
    expect(r.cardClipCornerRadius).toBe(8);
    expect(r.chromeOpacity).toBe(0);
    expect(r.isPlainBubble).toBe(false);
    expect(at(2, [F(1, 3, "leading")]).cardClip).toEqual(columns(V, "leading", "full").screen);
  });

  it("no clip anywhere else: tiles, other modes, a full style off sideBySide, a morph between clip-less ends", () => {
    expect(at(2, [R(1, 3, "sideBySide")]).cardClip).toBeNull();
    expect(at(2, [{ ...R(1, 3, "cameraOnly"), splitStyle: "full" }]).cardClip).toBeNull();
    expect(at(5, [F(1, 3)]).cardClip).toBeNull();
    expect(at(3 + transitionDuration / 2, [R(1, 3, "sideBySide"), R(3, 6, "cameraOnly")]).cardClip).toBeNull();
    expect(at(2, []).cardClip).toBeNull();
    expect(resolve(2, [F(1, 3)], V, bubble, 50, 8, false).cardClip).toBeNull();
  });

  it("the arrangement includes the split style, so tiles ↔ full morphs (and same-style splits do not)", () => {
    expect(arrangement(2, [F(1, 3)])).toEqual({ mode: "sideBySide", side: "trailing", split: "full", stacked: false });
    expect(arrangement(2, [{ ...R(1, 3, "bubble"), splitStyle: "full" }])).toEqual({ mode: "bubble", side: "trailing", split: "tiles", stacked: false });
    const same = [F(1, 3), F(3, 6)];
    expect(at(3.1, same)).toEqual(at(5, same));
  });

  it("tiles → full: the clip lerps from the transformed card outline (radius × cardScale) to the screen column", () => {
    const regions = [R(1, 3, "sideBySide"), F(3, 6)];
    const tiles = at(2, regions);
    const full = at(5, regions);
    const t = 3 + transitionDuration / 3;
    const p = ease((t - 3) / transitionDuration);
    const mid = at(t, regions);
    const outline = rectApplying(V, cardTransform(tiles, V));
    const lerp = (a: number, b: number) => a + (b - a) * p;
    expect(mid.cardClip!.x).toBeCloseTo(lerp(outline.x, full.cardClip!.x), 9);
    expect(mid.cardClip!.y).toBeCloseTo(lerp(outline.y, full.cardClip!.y), 9);
    expect(mid.cardClip!.width).toBeCloseTo(lerp(outline.width, full.cardClip!.width), 9);
    expect(mid.cardClip!.height).toBeCloseTo(lerp(outline.height, full.cardClip!.height), 9);
    expect(mid.cardClipCornerRadius).toBeCloseTo(lerp(8 * tiles.cardScale, 8), 12);
    // Strictly mid-flight.
    expect(mid.cardClip!.height).toBeGreaterThan(outline.height);
    expect(mid.cardClip!.height).toBeLessThan(full.cardClip!.height);
    expect(mid.cardScale).toBeGreaterThan(tiles.cardScale);
    expect(mid.cardScale).toBeLessThan(1);
  });

  it("bubble → full opens from the whole card; full → full leading slides between the columns", () => {
    const open = [F(3, 6)];
    expect(at(3, open).cardClip).toEqual({ x: V.x, y: V.y, width: V.width, height: V.height });
    expect(at(3, open).cardClipCornerRadius).toBe(8);
    const swap = [F(1, 3), F(3, 6, "leading")];
    const mid = at(3 + transitionDuration / 2, swap);
    const from = columns(V, "trailing", "full").screen;
    const to = columns(V, "leading", "full").screen;
    expect(mid.cardClip!.x).toBeGreaterThan(from.x);
    expect(mid.cardClip!.x).toBeLessThan(to.x);
    expect(mid.cardClip!.height).toBeCloseTo(V.height, 9);
    expect(mid.cardClipCornerRadius).toBeCloseTo(8, 12);
  });

  it("rectApplying is CGRect.applying: the transformed corners' bounding box, always standardized", () => {
    const flipped = { x: 10, y: 5, width: -100, height: 50 };
    const id = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
    expect(rectApplying(flipped, id)).toEqual({ x: -90, y: 5, width: 100, height: 50 });
    expect(rectApplying(flipped, { ...id, tx: 3 })).toEqual({ x: -87, y: 5, width: 100, height: 50 });
    expect(rectApplying(flipped, { ...id, a: 0.5, d: 0.5 })).toEqual({ x: -45, y: 2.5, width: 50, height: 25 });
  });
});

describe("vertical stack (§12.12)", () => {
  const area = { x: 20, y: 40, width: 1040, height: 1840 };
  const V = { x: 20, y: 700, width: 1040, height: 585 };
  const bubble = { x: 900, y: 1700, width: 120, height: 120 };

  it("model: cameraPortraitStack / cameraStackRatio lenient, written only when set right after cameraShrinkOnZoom", () => {
    const p = project();
    p.settings.cameraShrinkOnZoom = false;
    p.settings.cameraPortraitStack = true;
    p.settings.cameraStackRatio = 0.5;
    const json = serializeProject(p) as { settings: Record<string, unknown> };
    const keys = Object.keys(json.settings);
    const at = keys.indexOf("cameraShrinkOnZoom");
    expect(keys.slice(at + 1, at + 3)).toEqual(["cameraPortraitStack", "cameraStackRatio"]);
    expect(serializeProject(parseProject(json))).toEqual(json);
    const plain = serializeProject(project()) as { settings: Record<string, unknown> };
    expect("cameraPortraitStack" in plain.settings || "cameraStackRatio" in plain.settings).toBe(false);
    for (const [key, bad] of [["cameraPortraitStack", 1], ["cameraPortraitStack", "true"], ["cameraStackRatio", "0.4"], ["cameraStackRatio", null]] as const) {
      const back = parseProject({ ...json, settings: { ...json.settings, [key]: bad } });
      expect((back.settings as unknown as Record<string, unknown>)[key]).toBeUndefined();
      expect(back.settings.$extra).toBeUndefined();
    }
    // Stored as given; clamped at use.
    expect(parseProject({ ...json, settings: { ...json.settings, cameraStackRatio: 0.9 } }).settings.cameraStackRatio).toBe(0.9);
  });

  it("ratio: absent 0.42, clamped to 0.25…0.7", () => {
    expect(stackRatio(undefined)).toBe(0.42);
    expect(stackRatio(0.1)).toBe(0.25);
    expect(stackRatio(0.9)).toBe(0.7);
    expect(stackRatio(0.5)).toBe(0.5);
  });

  it("rows: camera on top, gap 2 % of the area, screen the rest — Y-down and Y-up", () => {
    const gap = 0.02 * 1840;
    const h = (1840 - gap) * 0.5;
    const down = stackRows(area, 0.5, false);
    expect(down.camera).toEqual({ x: 20, y: 40, width: 1040, height: h });
    expect(down.screen).toEqual({ x: 20, y: 40 + h + gap, width: 1040, height: 1840 - h - gap });
    const up = stackRows(area, 0.5, true);
    expect(up.camera).toEqual({ x: 20, y: 40 + 1840 - h, width: 1040, height: h });
    expect(up.screen).toEqual({ x: 20, y: 40, width: 1040, height: 1840 - h - gap });
    // The ratio clamps inside too.
    expect(stackRows(area, 2, false)).toEqual(stackRows(area, 0.7, false));
  });

  it("active only when switched on and the output canvas is portrait", () => {
    expect(stackActive({ cameraPortraitStack: true }, { width: 1080, height: 1920 })).toBe(true);
    expect(stackActive({ cameraPortraitStack: true }, { width: 1920, height: 1080 })).toBe(false);
    expect(stackActive({ cameraPortraitStack: true }, { width: 1080, height: 1080 })).toBe(false);
    expect(stackActive({}, { width: 1080, height: 1920 })).toBe(false);
  });

  it("settled stack: camera fills the top row, the card aspect-fills and is clipped to the screen row", () => {
    const rows = stackRows(area, 0.42, false);
    const r = resolve(3, [], V, bubble, 60, 10, true, rows);
    expect(r.cameraRect).toEqual(rows.camera);
    expect(r.cameraCornerRadius).toBe(10);
    expect(r.chromeOpacity).toBe(0);
    expect(r.cardScale).toBeCloseTo(Math.max(rows.screen.width / V.width, rows.screen.height / V.height), 12);
    expect(r.cardTranslationX).toBeCloseTo(rows.screen.x + rows.screen.width / 2 - (V.x + V.width / 2), 12);
    expect(r.cardTranslationY).toBeCloseTo(rows.screen.y + rows.screen.height / 2 - (V.y + V.height / 2), 12);
    expect(r.cardClip).toEqual(rows.screen);
    expect(r.cardClipCornerRadius).toBe(10);
    expect(r.isPlainBubble).toBe(false);
    // The card's centre lands on the screen row's centre; the row is covered.
    const t = cardTransform(r, V);
    const c = applyTransform(t, { x: V.x + V.width / 2, y: V.y + V.height / 2 });
    expect(c.x).toBeCloseTo(rows.screen.x + rows.screen.width / 2, 9);
    expect(c.y).toBeCloseTo(rows.screen.y + rows.screen.height / 2, 9);
    expect(V.height * r.cardScale).toBeGreaterThanOrEqual(rows.screen.height - 1e-9);
    // Y-up: the same geometry mirrored, translation Y in that space.
    const H = 1920;
    const flip = (q: { x: number; y: number; width: number; height: number }) => ({ ...q, y: H - q.y - q.height });
    const up = resolve(3, [], flip(V), flip(bubble), 60, 10, true, stackRows(flip(area), 0.42, true));
    expect(up.cardTranslationY).toBeCloseTo(-r.cardTranslationY, 9);
    expect(up.cardClip!.y).toBeCloseTo(flip(rows.screen).y, 9);
  });

  it("arrangement: outside regions and Side by Side regions stack; Bubble / Camera Only / Screen Only do not", () => {
    const regions = [R(2, 4, "bubble"), { ...R(5, 7, "sideBySide", "leading"), splitStyle: "full" as const }, R(8, 9, "cameraOnly")];
    expect(arrangement(1, regions, true).stacked).toBe(true);
    expect(arrangement(3, regions, true)).toEqual({ mode: "bubble", side: "trailing", split: "tiles", stacked: false });
    expect(arrangement(6, regions, true)).toEqual({ mode: "sideBySide", side: "trailing", split: "tiles", stacked: true });
    expect(arrangement(8.5, regions, true).stacked).toBe(false);
    expect(arrangement(1, regions).stacked).toBe(false);
    const rows = stackRows(area, 0.42, false);
    expect(resolve(6, regions, V, bubble, 60, 10, true, rows)).toEqual(resolve(1, regions, V, bubble, 60, 10, true, rows));
  });

  it("entering a Bubble block morphs out of the stack, mid-flight strictly between", () => {
    const rows = stackRows(area, 0.42, false);
    const regions = [R(2, 6, "bubble")];
    const stacked = resolve(1, regions, V, bubble, 60, 10, true, rows);
    const plain = resolve(5, regions, V, bubble, 60, 10, true, rows);
    expect(plain.isPlainBubble).toBe(true);
    expect(plain.cardClip).toBeNull();
    const mid = resolve(2 + transitionDuration / 2, regions, V, bubble, 60, 10, true, rows);
    expect(mid.cardScale).toBeLessThan(stacked.cardScale);
    expect(mid.cardScale).toBeGreaterThan(1);
    expect(mid.cardTranslationY).toBeGreaterThan(Math.min(0, stacked.cardTranslationY));
    expect(mid.cardTranslationY).toBeLessThan(Math.max(0, stacked.cardTranslationY));
    // The clip closes onto the bubble arrangement's whole card (videoRect at scale 1).
    expect(mid.cardClip!.height).toBeGreaterThan(Math.min(rows.screen.height, V.height));
    expect(mid.cardClip!.height).toBeLessThan(Math.max(rows.screen.height, V.height));
  });

  it("the stacked camera row wears the default look, outside regions and on Side by Side; a Bubble block keeps its own", () => {
    expect(lookWeights(3, [], "popOut", true)).toEqual({ cutout: 0, popOut: 1 });
    expect(lookWeights(3, [], "cutout", false)).toEqual({ cutout: 1, popOut: 0 });
    const regions = [{ ...R(2, 6, "bubble"), look: "popOut" as const }, R(7, 9, "sideBySide"), R(10, 12, "cameraOnly")];
    expect(lookWeights(1, regions, "cutout", true)).toEqual({ cutout: 1, popOut: 0 });
    expect(lookWeights(4, regions, "cutout", true)).toEqual({ cutout: 0, popOut: 1 });
    expect(lookWeights(8, regions, "cutout", true)).toEqual({ cutout: 1, popOut: 0 });
    expect(lookWeights(8, regions, "cutout", false)).toEqual({ cutout: 0, popOut: 0 });
    expect(lookWeights(11, regions, "cutout", true)).toEqual({ cutout: 0, popOut: 0 });
  });

  it("exportFrameCamera stacks only in a portrait output with a camera and a content rect", () => {
    const s = { ...defaultProjectSettings(), cameraPortraitStack: true };
    const measure = () => ({ width: 0, height: 0 });
    const portrait = { width: 1080, height: 1920 };
    const statics = exportCameraStatics(s, portrait, { width: 0, height: 0 }, { width: 1280, height: 720 }, true, measure);
    const input = { currentTime: 1, zoom: 1, sourceVisible: true, cameraFrameDecoded: true, posterAvailable: false };
    const content = { x: 48, y: 48, width: 984, height: 1824 };
    const cam = exportFrameCamera(statics, s, [], V, portrait, 0, input, content);
    expect(cam.stack).toEqual(stackRows(content, 0.42, true));
    expect(cam.layout.cardClip).toEqual(cam.stack!.screen);
    expect(cam.path).toBe("override");
    expect(exportFrameCamera(statics, s, [], V, portrait, 0, input).stack).toBeNull();
    expect(exportFrameCamera(statics, { ...s, cameraPortraitStack: undefined }, [], V, portrait, 0, input, content).stack).toBeNull();
    const landscape = { width: 1920, height: 1080 };
    const wide = exportCameraStatics(s, landscape, { width: 0, height: 0 }, { width: 1280, height: 720 }, true, measure);
    expect(exportFrameCamera(wide, s, [], V, landscape, 0, input, content).stack).toBeNull();
    const noCamera = exportCameraStatics(s, portrait, { width: 0, height: 0 }, { width: 1280, height: 720 }, false, measure);
    expect(exportFrameCamera(noCamera, s, [], V, portrait, 0, input, content).stack).toBeNull();
  });

  it("the aspect picker turns the stack on when a camera project moves to a portrait canvas", () => {
    const p = project();
    p.cameraVideoURL = "file:///x/camera.mov";
    const env = { playheadSource: 0 };
    setAspectRatio("9:16", { width: 1920, height: 1080 })(p, {} as never, env);
    expect(p.settings).toMatchObject({ aspectRatio: "9:16", cameraPortraitStack: true });
    // Already portrait → portrait: it does not switch it back on.
    p.settings.cameraPortraitStack = undefined;
    setAspectRatio("4:5", { width: 1920, height: 1080 })(p, {} as never, env);
    expect(p.settings.cameraPortraitStack).toBeUndefined();
    // Auto follows the recording: a portrait recording counts.
    const q = project();
    q.cameraVideoURL = "file:///x/camera.mov";
    q.settings.aspectRatio = "16:9";
    setAspectRatio("Auto", { width: 1080, height: 1920 })(q, {} as never, env);
    expect(q.settings.cameraPortraitStack).toBe(true);
    // No camera → untouched.
    const n = project();
    setAspectRatio("9:16", null)(n, {} as never, env);
    expect(n.settings.cameraPortraitStack).toBeUndefined();
  });
});

describe("Shrink during zoom (§12.5)", () => {
  it("layoutZoom passes the zoom through only while shrinking", () => {
    expect(layoutZoom(2.4, true)).toBe(2.4);
    expect(layoutZoom(2.4, false)).toBe(1);
    expect(layoutZoom(1, false)).toBe(1);
  });
});

describe("the resolved card style (CameraCardStyle)", () => {
  it("absent keys → today's look", () => {
    const style = cameraCardStyle({});
    expect(style).toEqual({
      popOutAmount: null,
      fill: "gradient",
      gradientTop: { r: popOutCardTop.red, g: popOutCardTop.green, b: popOutCardTop.blue },
      gradientBottom: { r: popOutCardBottom.red, g: popOutCardBottom.green, b: popOutCardBottom.blue },
      color: { r: 0.11, g: 0.11, b: 0.13 },
      imagePath: null,
      backgroundBlur: 0,
      edgeSoftness: 0,
      edgeInset: 0,
      border: null,
      borderThickness: 0.5,
      borderColor: { r: 1, g: 1, b: 1 },
      shrinkOnZoom: true,
    });
    expect(geometryBorderWidth(style)).toBeNull();
    expect(processesMaskEdge(style)).toBe(false);
  });

  it("blur only reads for the camera fill; σ = blur × 0.03 × the camera frame's height", () => {
    expect(cameraCardStyle({ cameraBackgroundBlur: 0.6 }).backgroundBlur).toBe(0);
    const style = cameraCardStyle({ cameraCardFill: "camera", cameraBackgroundBlur: 0.6 });
    expect(style.backgroundBlur).toBe(0.6);
    expect(blurSigma(style, 1080)).toBeCloseTo(0.6 * 0.03 * 1080, 12);
    expect(cameraCardStyle({ cameraCardFill: "camera", cameraBackgroundBlur: 4 }).backgroundBlur).toBe(1);
  });

  it("image fill: aspect-filled into the card, centred (s = max(C.w / iw, C.h / ih))", () => {
    const card = { x: 10, y: 20, width: 200, height: 100 };
    expect(imageFillRect({ width: 100, height: 100 }, card)).toEqual({ x: 10, y: -30, width: 200, height: 200 });
    expect(imageFillRect({ width: 400, height: 100 }, card)).toEqual({ x: -90, y: 20, width: 400, height: 100 });
    expect(imageFillRect({ width: 0, height: 100 }, card)).toEqual(card);
  });

  it("border presets: solid uses the colour (alpha dropped), aurora / gold their gradients", () => {
    const solid = cameraCardStyle({ cameraCardBorder: "solid", cameraCardBorderColor: { red: 1, green: 0, blue: 0, opacity: 0.2 } });
    expect(borderColors(solid)).toEqual({ top: { r: 1, g: 0, b: 0 }, bottom: { r: 1, g: 0, b: 0 } });
    expect(geometryBorderWidth(solid)).toBe(0.5);
    expect(borderColors(cameraCardStyle({ cameraCardBorder: "aurora" }))).toEqual({ top: { r: 0.36, g: 0.91, b: 1 }, bottom: { r: 0.29, g: 0.4, b: 1 } });
    expect(borderColors(cameraCardStyle({ cameraCardBorder: "gold" }))).toEqual({ top: { r: 1, g: 0.89, b: 0.52 }, bottom: { r: 0.85, g: 0.55, b: 0.16 } });
  });
});
