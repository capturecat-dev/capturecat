/**
 * Region plans in engine space (regionPlan.ts): the space conversion around
 * the core exporter ports, the separable mask, and the measured
 * CIMaskedVariableBlur model. The numbers themselves are locked to Swift by
 * the core vectors (exportRegionBlur / exportRegionHighlight /
 * exportFocusPlan); these tests pin what the engine does with them.
 */
import { describe, expect, it } from "vitest";
import { parseProject, type Project } from "../../core/model";
import { newBlurRegion, newFocusRegion, newHighlightRegion, newProject } from "../../core/model/defaults";
import { serializeProject } from "../../core/model/serialize";
import { exportRegionBlurPlan, regionEnvelope } from "../../core/math/exportRegions";
import { renderProjectFromJSON } from "../contract";
import { cardGeometry } from "../layout";
import {
  blurLevel,
  blurOps,
  exportSpace,
  featherFactors,
  focusOps,
  highlightOps,
  maskedVariableBlurLevels,
  maskedVariableBlurWeights,
  padFor,
  toExportRect,
  videoLayerExtent,
} from "./regionPlan";

const SOURCE = { width: 1920, height: 1080 };

/** The parity fixture 09 regions (synthetic), on a default project. */
function fixture() {
  const p = newProject({ id: "00000000-0000-4000-8000-000000000001" });
  p.settings.backgroundPadding = 48;
  p.settings.cornerRadius = 12;
  p.settings.windowCornerRadius = 8;
  p.settings.animationSpeed = "Mellow";
  p.settings.exportSettings.resolution = "720p";
  p.blurRegions = [
    { ...newBlurRegion(0.2, 2, "00000000-0000-4000-8000-000000000901"), rect: { x: 0.1, y: 0.1, width: 0.35, height: 0.2 }, intensity: 0.8 },
    { ...newBlurRegion(1.2, 3, "00000000-0000-4000-8000-000000000902"), rect: { x: 0.55, y: 0.55, width: 0.3, height: 0.3 }, intensity: 0.6, style: "Pixelate", animated: true },
  ];
  p.highlightRegions = [{ ...newHighlightRegion(2.2, 3.8, "00000000-0000-4000-8000-000000000903"), rect: { x: 0.3, y: 0.35, width: 0.4, height: 0.25 }, opacity: 0.6 }];
  p.focusRegions = [{ ...newFocusRegion(3, 4.5, "00000000-0000-4000-8000-000000000904"), intensity: 0.8, falloff: 0.4 }];
  const doc = serializeProject(p);
  const project = parseProject(doc) as Project;
  const settings = renderProjectFromJSON(doc).settings;
  // Preview and export share the preview's CSS reference canvas (the Mac's
  // previewCanvasSize), so the export layout is the preview's, scaled.
  const reference = { width: 1280, height: 720 };
  const scene = (target: { width: number; height: number }) => {
    const geometry = cardGeometry(SOURCE, target, settings, reference);
    return { settings, sourceSize: SOURCE, target, geometry };
  };
  return { project, scene };
}

describe("exportSpace", () => {
  it("is 1 at the export resolution and scales the preview", () => {
    const { scene } = fixture();
    expect(exportSpace(scene({ width: 1280, height: 720 })).k).toBe(1);
    const half = exportSpace(scene({ width: 640, height: 360 }));
    expect(half.k).toBeCloseTo(0.5, 12);
    expect(half.heightE).toBeCloseTo(720, 9);
  });
});

describe("blurOps", () => {
  it("at k = 1 is the core exporter plan, flipped to Y-down", () => {
    const { project, scene } = fixture();
    const s = scene({ width: 1280, height: 720 });
    const sp = exportSpace(s);
    const ops = blurOps(project, s.geometry.videoRect, 1.5, sp);
    expect(ops.map((o) => o.style)).toEqual(["Blur", "Pixelate"]);
    const container = toExportRect(s.geometry.videoRect, sp);
    const plan = exportRegionBlurPlan(project.blurRegions[0], container, 1.5);
    // The KNOWN Mac export behaviour: blurRadius(in:) is the σ, unhalved.
    expect(ops[0].sigma).toBe(plan.gaussianRadius);
    expect(ops[0].rect.x).toBeCloseTo(plan.pixelRect.x, 9);
    expect(ops[0].rect.y).toBeCloseTo(720 - (plan.pixelRect.y + plan.pixelRect.height), 9);
    expect(ops[0].featherSigma).toBe(plan.featherSigma);
    // Pixelate grid: CI anchors boundaries at inputCenter (Y-up) → Y-down gy = H − cy.
    const px = exportRegionBlurPlan(project.blurRegions[1], container, 1.5).pixellate!;
    expect(ops[1].block).toBe(px.scale);
    expect(ops[1].gx).toBe(px.center.x);
    expect(ops[1].gy).toBeCloseTo(720 - px.center.y, 9);
  });

  it("switches hard at the bounds (inclusive) and animates the pixelate grid per 0.125 s step", () => {
    const { project, scene } = fixture();
    const s = scene({ width: 1280, height: 720 });
    const sp = exportSpace(s);
    expect(blurOps(project, s.geometry.videoRect, 0.1999, sp)).toHaveLength(0);
    expect(blurOps(project, s.geometry.videoRect, 0.2, sp)).toHaveLength(1);
    expect(blurOps(project, s.geometry.videoRect, 2, sp)).toHaveLength(2);
    const a = blurOps(project, s.geometry.videoRect, 1.30, sp)[1];
    const b = blurOps(project, s.geometry.videoRect, 1.32, sp)[1]; // same 0.125 step
    const c = blurOps(project, s.geometry.videoRect, 1.40, sp)[1]; // next step
    expect([b.gx, b.gy]).toEqual([a.gx, a.gy]);
    expect([c.gx, c.gy]).not.toEqual([a.gx, a.gy]);
  });

  it("the preview is the export scaled — absolute clamps are evaluated at the export resolution", () => {
    const { project, scene } = fixture();
    const full = scene({ width: 1280, height: 720 });
    const half = scene({ width: 640, height: 360 });
    const e = blurOps(project, full.geometry.videoRect, 1.5, exportSpace(full));
    const p = blurOps(project, half.geometry.videoRect, 1.5, exportSpace(half));
    expect(e[0].sigma).toBe(36); // clamped 6…36 at the export size
    expect(p[0].sigma).toBeCloseTo(18, 9); // NOT re-clamped at the preview size
    expect(p[1].block).toBeCloseTo(e[1].block / 2, 9);
    expect(p[0].featherSigma).toBeCloseTo(e[0].featherSigma / 2, 9);
  });
});

describe("featherFactors", () => {
  const E = { x: 48, y: 48, width: 400, height: 300 };
  it("hard mask = exact per-pixel area coverage (CI crop)", () => {
    const { mx, my } = featherFactors({ x: 100.25, y: 60.5, width: 50.5, height: 10 }, 0, E);
    expect(mx[100 - 48]).toBeCloseTo(0.75, 6);
    expect(mx[101 - 48]).toBe(1);
    expect(mx[150 - 48]).toBeCloseTo(0.75, 6);
    expect(mx[151 - 48]).toBe(0);
    expect(my[60 - 48]).toBeCloseTo(0.5, 6);
    expect(my[70 - 48]).toBeCloseTo(0.5, 6);
  });
  it("feathering straddles the edge (≈ ½ on it) and is clamped at the extent", () => {
    const { mx } = featherFactors({ x: 148, y: 60, width: 100, height: 40 }, 6, E);
    expect(mx[148 - 48]).toBeGreaterThan(0.45);
    expect(mx[148 - 48]).toBeLessThan(0.6);
    const flush = featherFactors({ x: 48, y: 60, width: 100, height: 40 }, 6, E).mx;
    expect(flush[0]).toBeGreaterThan(0.99); // clampedToExtent: no fade at the frame edge
  });
});

describe("highlightOps", () => {
  it("fades with the shared regionEnvelope and converts the dim to CI's alpha", () => {
    const { project, scene } = fixture();
    const s = scene({ width: 1280, height: 720 });
    const sp = exportSpace(s);
    const t = 2.3333333333333335; // mid fade-in (Mellow = 0.8 s)
    const [op] = highlightOps(project, s.geometry.videoRect, t, sp);
    const env = regionEnvelope(t, 2.2, 3.8, 0.8);
    expect(env).toBeGreaterThan(0);
    expect(env).toBeLessThan(1);
    expect(op.envelope).toBe(env);
    expect(op.alpha).toBeCloseTo(1 - Math.pow(1 - 0.6 * env, 2.2), 12);
    expect(op.dimRect).toEqual(s.geometry.videoRect);
    expect(highlightOps(project, s.geometry.videoRect, 3.9, sp)).toHaveLength(0);
  });
});

describe("focusOps + CIMaskedVariableBlur model", () => {
  it("carries the export-space inputRadius and the exporter's mask cache key", () => {
    const { project, scene } = fixture();
    const full = scene({ width: 1280, height: 720 });
    const half = scene({ width: 640, height: 360 });
    const e = focusOps(project, full.geometry.videoRect, 3.5, exportSpace(full))[0];
    const p = focusOps(project, half.geometry.videoRect, 3.5, exportSpace(half))[0];
    expect(p.radiusE).toBeCloseTo(e.radiusE, 9);
    expect(p.sigma).toBeCloseTo(e.sigma / 2, 9);
    expect(e.maskKey).toBe(p.maskKey);
    const m = e.mask()!;
    expect(m.width).toBe(384);
    expect(m.pixels[0]).toBe(255); // top-left corner: far outside the sharp area
  });

  it("levels double from 1.5 and the log2 weights reproduce the measured CI line-spread sd", () => {
    const levels = maskedVariableBlurLevels(20);
    expect(levels.map((l) => l.r)).toEqual([0.75, 1.5, 3, 6, 12, 24]);
    // Measured on the Mac (radius 20): sd at mask 0.8 (r 16) = 18.303, mask 0.5 (r 10) = 10.944.
    for (const [r, measured] of [[16, 18.303], [10, 10.944], [20, 21.894]] as const) {
      const w = maskedVariableBlurWeights(levels, r);
      expect(w.reduce((a, b) => a + b, 0)).toBeCloseTo(1, 12);
      const variance = w.reduce((a, wi, i) => a + wi * levels[i].sd ** 2, 0);
      expect(Math.sqrt(variance)).toBeCloseTo(measured, 0);
      expect(Math.abs(Math.sqrt(variance) - measured) / measured).toBeLessThan(0.006);
    }
    expect(maskedVariableBlurWeights(levels, 0.5)[0]).toBe(1); // sharp below r 0.75
  });

  it("pyramid levels keep the requested σ (mip + upsample variance corrected)", () => {
    for (const sigma of [4, 9, 22, 36, 60]) {
      const { d, sigmaLow } = blurLevel(sigma, 3);
      const eff = Math.sqrt((sigmaLow * d) ** 2 + (d * d - 1) / 4);
      expect(eff).toBeCloseTo(sigma, 6);
      expect(padFor(sigma, d) % d).toBe(0);
      expect(padFor(sigma, d)).toBeGreaterThanOrEqual(3 * sigma);
    }
  });
});

describe("videoLayerExtent", () => {
  it("is contentRect with a window mask, else videoRect ∩ contentRect — rounded out", () => {
    const vr = { x: 85.33, y: 48, width: 1109.33, height: 624 };
    const cr = { x: 48, y: 48, width: 1184, height: 624 };
    expect(videoLayerExtent(vr, cr, true, { width: 1280, height: 720 })).toEqual({ x: 48, y: 48, width: 1184, height: 624 });
    expect(videoLayerExtent(vr, cr, false, { width: 1280, height: 720 })).toEqual({ x: 85, y: 48, width: 1110, height: 624 });
  });
});
