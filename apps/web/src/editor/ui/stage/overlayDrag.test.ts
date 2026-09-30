import { describe, expect, it } from "vitest";

import { defaultProjectSettings } from "../../core/model";
import type { ProjectSettings } from "../../core/model";
import type { StageHits } from "../../engine/stageHits";
import {
  applySettingsPatch,
  overlayDragFraction,
  overlayDragPatch,
  overlayHitTest,
  overlayInitialFraction,
  overlayReleasePatch,
} from "./overlayDrag";

const settings = (patch: Partial<ProjectSettings> = {}): ProjectSettings => ({ ...defaultProjectSettings(), ...patch });

describe("overlayHitTest (PreviewInteractionView.mouseDown step 1)", () => {
  const hits: StageHits = {
    camera: { rect: { x: 100, y: 100, width: 100, height: 100 }, space: "canvas", usable: { width: 500, height: 300 } },
    watermark: { rect: { x: 150, y: 150, width: 40, height: 20 }, space: "canvas", usable: { width: 560, height: 380 } },
    subtitle: { rect: { x: 300, y: 400, width: 200, height: 40 }, space: "card", usable: { width: 400, height: 360 } },
  };

  it("orders watermark > camera > subtitle", () => {
    expect(overlayHitTest(hits, { x: 160, y: 160 }, { x: 0, y: 0 }, 1)?.kind).toBe("watermark");
    expect(overlayHitTest(hits, { x: 110, y: 110 }, { x: 0, y: 0 }, 1)?.kind).toBe("camera");
  });

  it("uses the Mac slop (watermark 4pt, camera 0, subtitle 6pt) scaled by px/pt", () => {
    // Watermark: 3pt outside at u = 2 (6 px) is inside the 8 px slop.
    expect(overlayHitTest({ watermark: hits.watermark }, { x: 144, y: 160 }, { x: 0, y: 0 }, 2)?.kind).toBe("watermark");
    expect(overlayHitTest({ watermark: hits.watermark }, { x: 141, y: 160 }, { x: 0, y: 0 }, 2)).toBeNull();
    // Camera has no slop.
    expect(overlayHitTest({ camera: hits.camera }, { x: 99, y: 150 }, { x: 0, y: 0 }, 2)).toBeNull();
  });

  it("tests card-space rects against the card point, canvas-space against the canvas point", () => {
    const sub = { subtitle: hits.subtitle };
    expect(overlayHitTest(sub, { x: 320, y: 410 }, { x: 0, y: 0 }, 1)).toBeNull();
    expect(overlayHitTest(sub, { x: 0, y: 0 }, { x: 320, y: 410 }, 1)?.kind).toBe("subtitle");
    expect(overlayHitTest(sub, { x: 0, y: 0 }, { x: 296, y: 410 }, 1)?.kind).toBe("subtitle"); // 4 px < 6 slop
  });
});

describe("overlayInitialFraction", () => {
  it("camera: custom when both set, else the corner fraction", () => {
    expect(overlayInitialFraction("camera", settings({ cameraPosition: "Top Left" }))).toEqual({ x: 0, y: 0 });
    expect(overlayInitialFraction("camera", settings({ cameraPosition: "Top Left", cameraCustomX: 0.3 }))).toEqual({ x: 0, y: 0 });
    expect(overlayInitialFraction("camera", settings({ cameraCustomX: 0.3, cameraCustomY: 0.6 }))).toEqual({ x: 0.3, y: 0.6 });
  });
  it("subtitle: custom, else the anchor (top 0 / center 0.5 / bottom 1)", () => {
    expect(overlayInitialFraction("subtitle", settings({ subtitlePosition: "Top" }))).toEqual({ x: 0.5, y: 0 });
    expect(overlayInitialFraction("subtitle", settings({ subtitlePosition: "Center" }))).toEqual({ x: 0.5, y: 0.5 });
    expect(overlayInitialFraction("subtitle", settings({ subtitlePosition: "Bottom" }))).toEqual({ x: 0.5, y: 1 });
    expect(overlayInitialFraction("subtitle", settings({ subtitleCustomX: 0.2, subtitleCustomY: 0.7 }))).toEqual({ x: 0.2, y: 0.7 });
  });
  it("watermark: its fraction", () => {
    expect(overlayInitialFraction("watermark", settings({ watermarkX: 0.25, watermarkY: 0.75 }))).toEqual({ x: 0.25, y: 0.75 });
  });
});

describe("overlayDragFraction (mouseDragged)", () => {
  it("delta / usable span, clamped to 0…1", () => {
    expect(overlayDragFraction("watermark", { x: 1, y: 1 }, { x: -100, y: -50 }, { width: 400, height: 200 })).toEqual({ x: 0.75, y: 0.75 });
    expect(overlayDragFraction("watermark", { x: 1, y: 1 }, { x: 100, y: -500 }, { width: 400, height: 200 })).toEqual({ x: 1, y: 0 });
  });
  it("no usable span → no write; one zero axis stays put (watermark / subtitle)", () => {
    expect(overlayDragFraction("subtitle", { x: 0.5, y: 1 }, { x: 10, y: 10 }, { width: 0, height: 0 })).toBeNull();
    expect(overlayDragFraction("subtitle", { x: 0.5, y: 1 }, { x: 40, y: -60 }, { width: 0, height: 300 })).toEqual({ x: 0.5, y: 0.8 });
  });
  it("camera divides by max(1, usable)", () => {
    expect(overlayDragFraction("camera", { x: 0.5, y: 0.5 }, { x: 0.25, y: 0 }, { width: 0.5, height: 100 })).toEqual({ x: 0.75, y: 0.5 });
  });
});

describe("overlayReleasePatch (mouseUp magnetism)", () => {
  it("camera: within 0.06 of a corner collapses to the enum", () => {
    expect(overlayReleasePatch("camera", settings({ cameraCustomX: 0.95, cameraCustomY: 0.04 }))).toEqual({
      cameraPosition: "Top Right",
      cameraCustomX: undefined,
      cameraCustomY: undefined,
    });
    expect(overlayReleasePatch("camera", settings({ cameraCustomX: 0.93, cameraCustomY: 0.04 }))).toBeNull();
    expect(overlayReleasePatch("camera", settings())).toBeNull();
  });
  it("watermark: each axis within 0.04 of an edge snaps to it", () => {
    expect(overlayReleasePatch("watermark", settings({ watermarkX: 0.03, watermarkY: 0.97 }))).toEqual({ watermarkX: 0, watermarkY: 1 });
    expect(overlayReleasePatch("watermark", settings({ watermarkX: 0.5, watermarkY: 0.965 }))).toEqual({ watermarkX: 0.5, watermarkY: 1 });
    expect(overlayReleasePatch("watermark", settings({ watermarkX: 0.5, watermarkY: 0.5 }))).toBeNull();
  });
  it("subtitle: centred (|x − 0.5| < 0.06) and near an anchor collapses to the enum", () => {
    expect(overlayReleasePatch("subtitle", settings({ subtitleCustomX: 0.54, subtitleCustomY: 0.03 }))).toEqual({
      subtitlePosition: "Top",
      subtitleCustomX: undefined,
      subtitleCustomY: undefined,
    });
    expect(overlayReleasePatch("subtitle", settings({ subtitleCustomX: 0.5, subtitleCustomY: 0.47 }))?.subtitlePosition).toBe("Center");
    expect(overlayReleasePatch("subtitle", settings({ subtitleCustomX: 0.57, subtitleCustomY: 1 }))).toBeNull();
    expect(overlayReleasePatch("subtitle", settings({ subtitleCustomX: 0.5, subtitleCustomY: 0.8 }))).toBeNull();
  });
});

describe("applySettingsPatch", () => {
  it("sets values and deletes undefined keys (encodeIfPresent omits them)", () => {
    const s = settings({ cameraCustomX: 0.3, cameraCustomY: 0.4 });
    applySettingsPatch(s, { cameraPosition: "Bottom Left", cameraCustomX: undefined, cameraCustomY: undefined });
    expect(s.cameraPosition).toBe("Bottom Left");
    expect("cameraCustomX" in s).toBe(false);
    expect("cameraCustomY" in s).toBe(false);
    applySettingsPatch(s, overlayDragPatch("subtitle", { x: 0.1, y: 0.2 }));
    expect([s.subtitleCustomX, s.subtitleCustomY]).toEqual([0.1, 0.2]);
  });
});
