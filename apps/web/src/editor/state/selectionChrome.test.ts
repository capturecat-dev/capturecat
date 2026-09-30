import { describe, expect, it } from "vitest";

import { newAnnotation, newBlurRegion, newProject, newZoomRegion, serializeProjectText } from "../core/model";
import { EditorController } from "./controller";
import { escapeSelection } from "./escapeSelection";
import { revealsInspector } from "./inspectorReveal";
import { assign, EMPTY_SELECTION } from "./selection";
import { EditorStore } from "./store";

describe("Esc deselects everything (PreviewInteractionView.deselectAll + the timeline's clip Esc)", () => {
  it("clears blur / highlight / depth focus / annotation / clip", () => {
    for (const lane of ["blur", "highlight", "depthFocus", "annotation", "clip"] as const) {
      const sel = assign(EMPTY_SELECTION, lane, "X");
      const next = escapeSelection(sel);
      expect(next).not.toBeNull();
      expect(next).toEqual(EMPTY_SELECTION);
    }
  });

  it("leaves EFFECTS blocks alone and reports nothing to do", () => {
    const sel = { ...EMPTY_SELECTION, zoomId: "Z", tiltId: "T" };
    expect(escapeSelection(sel)).toBeNull();
    expect(escapeSelection(EMPTY_SELECTION)).toBeNull();
  });

  it("the shell's Esc goes through the store", () => {
    const p = newProject({ duration: 10 });
    const blur = newBlurRegion(1, 3);
    const ann = newAnnotation("text", 2, 4);
    p.blurRegions.push(blur);
    p.annotations.push(ann);
    const store = new EditorStore();
    store.load({ text: serializeProjectText(p), origin: "local", revision: null });
    const controller = new EditorController(store);
    controller.selectFocus(blur.id, false);
    controller.shellCallbacks().onEscape!();
    expect(store.getState().selection.blurId).toBeNull();
    controller.selectAnnotation(ann.id);
    controller.shellCallbacks().onEscape!();
    expect(store.getState().selection.annotationId).toBeNull();
  });
});

describe("a selection re-shows a collapsed inspector", () => {
  it("regions, effects and annotations that become selected", () => {
    for (const lane of ["zoom", "tilt", "blur", "highlight", "depthFocus", "annotation"] as const) {
      expect(revealsInspector(EMPTY_SELECTION, assign(EMPTY_SELECTION, lane, "A"))).toBe(true);
      // Re-selecting a different one reveals again; the same one does not.
      expect(revealsInspector(assign(EMPTY_SELECTION, lane, "A"), assign(EMPTY_SELECTION, lane, "B"))).toBe(true);
      expect(revealsInspector(assign(EMPTY_SELECTION, lane, "A"), assign(EMPTY_SELECTION, lane, "A"))).toBe(false);
    }
  });

  it("the intro / curtain chips, but not clips, voice-overs or deselection", () => {
    expect(revealsInspector(EMPTY_SELECTION, { ...EMPTY_SELECTION, introSelected: true })).toBe(true);
    expect(revealsInspector(EMPTY_SELECTION, { ...EMPTY_SELECTION, curtainSelected: true })).toBe(true);
    expect(revealsInspector(EMPTY_SELECTION, assign(EMPTY_SELECTION, "clip", "C"))).toBe(false);
    expect(revealsInspector(EMPTY_SELECTION, assign(EMPTY_SELECTION, "voiceOver", "V"))).toBe(false);
    expect(revealsInspector(assign(EMPTY_SELECTION, "zoom", "Z"), EMPTY_SELECTION)).toBe(false);
  });

  it("follows real store selections (timeline select of a zoom block)", () => {
    const p = newProject({ duration: 10 });
    const z = newZoomRegion(1, 4);
    p.zoomRegions.push(z);
    const store = new EditorStore();
    store.load({ text: serializeProjectText(p), origin: "local", revision: null });
    const controller = new EditorController(store);
    const prev = store.getState().selection;
    controller.selectTarget({ lane: "effects", key: z.id, zoomId: z.id, tiltId: null } as never);
    expect(revealsInspector(prev, store.getState().selection)).toBe(true);
    expect(store.getState().inspectorTab).toBe("effects");
  });
});
