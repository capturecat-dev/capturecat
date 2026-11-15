/**
 * Studio 2e on the web engine: a reference-canvas project lays out the same
 * at every stage size and exactly like its export; a project from before 2e
 * keeps following the stage, as on the Mac. Pure geometry (no WebGPU) — the
 * same `cardGeometry` the stage (engine.ts `reference()`) and the exporter
 * (export/exporter.ts) feed.
 */
import { describe, expect, it } from "vitest";
import { adoptNewProjectReferenceCanvas, exportReferenceCanvas, NEW_PROJECT_BOX } from "../core/math/referenceCanvas";
import { newProject, serializeProject } from "../core/model";
import { renderProjectFromJSON, type RenderProject } from "./contract";
import { cardGeometry, previewReferenceCanvas, resolvedOutputSize, type Rect, type Size } from "./layout";

const SOURCE: Size = { width: 1280, height: 800 };

function project(reference: boolean, aspect: "16:9" | "9:16" | "Auto" = "16:9"): RenderProject {
  const p = newProject({ name: "t", duration: 3, videoURL: "file:///CaptureCat/Projects/x/recording.mov" });
  p.settings.aspectRatio = aspect;
  if (reference) adoptNewProjectReferenceCanvas(p);
  return renderProjectFromJSON(serializeProject(p));
}

/** The card's video rect as fractions of its target — comparable across sizes. */
function normalizedVideoRect(rp: RenderProject, target: Size, reference: Size | null): Rect {
  const g = cardGeometry(SOURCE, target, rp.settings, reference);
  return {
    x: g.videoRect.x / target.width,
    y: g.videoRect.y / target.height,
    width: g.videoRect.width / target.width,
    height: g.videoRect.height / target.height,
  };
}

/** Fractions within `pixels` of `target` (frame layouts snap to whole pixels). */
function expectRectClose(a: Rect, b: Rect, target: Size, pixels = 1) {
  const tx = pixels / target.width;
  const ty = pixels / target.height;
  expect(Math.abs(a.x - b.x)).toBeLessThanOrEqual(tx);
  expect(Math.abs(a.y - b.y)).toBeLessThanOrEqual(ty);
  expect(Math.abs(a.width - b.width)).toBeLessThanOrEqual(tx);
  expect(Math.abs(a.height - b.height)).toBeLessThanOrEqual(ty);
}

/** Stage sizes (CSS px of the letterboxed card) and their backing stores. */
const STAGES: Array<{ reference: Size; target: Size }> = [
  { reference: { width: 330 * (16 / 9), height: 330 }, target: { width: 1173, height: 660 } },
  { reference: { width: 764, height: 430 }, target: { width: 1528, height: 860 } },
  { reference: { width: 1029, height: 579 }, target: { width: 2058, height: 1158 } },
];

describe("reference canvas on the web engine (Studio 2e)", () => {
  it("the contract carries the box (sanitized), null before 2e", () => {
    expect(project(true).referenceCanvasSize).toEqual(NEW_PROJECT_BOX);
    expect(project(false).referenceCanvasSize).toBeNull();
    expect(renderProjectFromJSON({ referenceCanvasSize: [0, 330] }).referenceCanvasSize).toBeNull();
    expect(renderProjectFromJSON({ referenceCanvasSize: [803, 330, 9] }).referenceCanvasSize).toEqual(NEW_PROJECT_BOX);
    expect(renderProjectFromJSON({ referenceCanvasSize: "803x330" }).referenceCanvasSize).toBeNull();
  });

  it("the stage's reference is the project's canvas at the OUTPUT aspect, whatever the stage", () => {
    const rp = project(true);
    for (const stage of [...STAGES.map((s) => s.reference), null]) {
      const r = previewReferenceCanvas(rp.referenceCanvasSize, rp.settings, SOURCE, stage)!;
      expect(r.width).toBeCloseTo(330 * (16 / 9), 9);
      expect(r.height).toBe(330);
    }
    // Auto follows the 16:10 source; 9:16 takes the box's 9:16 canvas.
    const auto = project(true, "Auto");
    expect(previewReferenceCanvas(auto.referenceCanvasSize, auto.settings, SOURCE, null)).toEqual({ width: 528, height: 330 });
    const vertical = project(true, "9:16");
    const out = resolvedOutputSize(vertical.settings.exportSettings, "9:16", SOURCE);
    expect(previewReferenceCanvas(vertical.referenceCanvasSize, vertical.settings, SOURCE, null)!.width).toBeCloseTo(
      330 * (out.width / out.height),
      9,
    );
  });

  it("a pre-2e project keeps the stage's own canvas", () => {
    const rp = project(false);
    for (const { reference } of STAGES) {
      expect(previewReferenceCanvas(rp.referenceCanvasSize, rp.settings, SOURCE, reference)).toBe(reference);
    }
  });

  it("reference project: the card lays out the same at every stage size, and exactly like the export", () => {
    const rp = project(true);
    const output = resolvedOutputSize(rp.settings.exportSettings, rp.settings.aspectRatio, SOURCE);
    const exported = normalizedVideoRect(
      rp,
      output,
      exportReferenceCanvas(rp.referenceCanvasSize, STAGES[2].reference, output),
    );
    for (const { reference, target } of STAGES) {
      const preview = normalizedVideoRect(rp, target, previewReferenceCanvas(rp.referenceCanvasSize, rp.settings, SOURCE, reference));
      // Layouts snap to whole pixels: within 1 px of this stage's backing store.
      expectRectClose(preview, exported, target);
    }
    // Headless (no stage at all) exports the same frame.
    const headless = normalizedVideoRect(rp, output, exportReferenceCanvas(rp.referenceCanvasSize, null, output));
    expect(headless).toEqual(exported);
  });

  it("pre-2e project: the stage size still changes the layout (the check can see a difference)", () => {
    const rp = project(false);
    const small = normalizedVideoRect(rp, STAGES[0].target, STAGES[0].reference);
    const large = normalizedVideoRect(rp, STAGES[2].target, STAGES[2].reference);
    // 48 pt of padding is a larger share of a smaller canvas.
    expect(large.width - small.width).toBeGreaterThan(0.02);
  });
});
