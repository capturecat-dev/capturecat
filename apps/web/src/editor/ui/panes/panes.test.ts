import { describe, expect, it } from "vitest";

import { newBlurRegion, newFocusRegion, newHighlightRegion, newProject, newTiltRegion, newZoomRegion } from "../../core/model";
import { rowMargins } from "./stackSpacing";
import { resolveFacts, selectedRegions, selectionFromTarget } from "./types";

describe("inspector stack spacing (NSStackView custom spacing)", () => {
  it("attached rows sit 6pt under their predecessor", () => {
    expect(rowMargins([{}, { attached: true }, {}])).toEqual([0, 6, 16]);
  });

  it("a hidden attached row keeps the tight spacing after its predecessor (Camera: Shape → Mirror)", () => {
    // position, shape, orientation chips (attached, hidden for Circle), mirror
    expect(rowMargins([{}, {}, { attached: true, show: false }, {}])).toEqual([0, 16, 6, 6]);
  });

  it("Padding hugs the placement pad while Reset to Center is hidden", () => {
    // placement, pad (attached), reset (attached, hidden), padding
    expect(rowMargins([{}, { attached: true }, { attached: true, show: false }, {}])).toEqual([0, 6, 6, 6]);
  });

  it("leading hidden rows do not add spacing", () => {
    expect(rowMargins([{ show: false }, { show: false }, {}, {}])).toEqual([0, 0, 0, 16]);
  });

  it("pane-level stacks use 24pt", () => {
    expect(rowMargins([{}, { show: false }, {}], 24)).toEqual([0, 24, 24]);
  });
});

describe("pane selection", () => {
  const p = newProject({ duration: 4 });
  p.zoomRegions = [newZoomRegion(0, 1, "z")];
  p.tiltRegions = [newTiltRegion(0, 1, "t")];
  p.highlightRegions = [newHighlightRegion(1, 2, "h")];
  p.focusRegions = [newFocusRegion(1, 2, "f")];
  p.blurRegions = [newBlurRegion(1, 2, "b")];

  it("resolves the store selection to regions", () => {
    const r = selectedRegions({ zoomId: "z", tiltId: "t", depthFocusId: "f" }, p);
    expect(r.zoom?.id).toBe("z");
    expect(r.tilt?.id).toBe("t");
    expect(r.focus?.id).toBe("f");
    expect(r.blur).toBeUndefined();
  });

  it("maps a FOCUS-lane timeline target by array membership", () => {
    expect(selectionFromTarget({ lane: "focus", id: "h", isHighlight: true }, p)).toEqual({ highlightId: "h" });
    expect(selectionFromTarget({ lane: "focus", id: "f", isHighlight: false }, p)).toEqual({ depthFocusId: "f" });
    expect(selectionFromTarget({ lane: "focus", id: "b", isHighlight: false }, p)).toEqual({ blurId: "b" });
    expect(selectionFromTarget({ lane: "intro" }, p)).toEqual({ introSelected: true });
  });

  it("derives recording facts like InspectorColumnAppKit", () => {
    const d = newProject({ recordingSourceKind: "device", cameraVideoURL: "file:///cam.mov" });
    expect(resolveFacts(d)).toMatchObject({ isDeviceRecording: true, supportsMenuBar: false, hasRecordedCamera: true, hasShortcutData: false });
    expect(resolveFacts(p, { hasShortcutData: true }).hasShortcutData).toBe(true);
  });
});
