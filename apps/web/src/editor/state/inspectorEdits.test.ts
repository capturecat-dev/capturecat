import { describe, expect, it } from "vitest";

import { newProject, newSpeedRegion, newTiltRegion, newZoomRegion, serializeProjectText } from "../core/model";
import { editorPaneActions } from "../ui/editorPageWiring";
import { EditorController } from "./controller";
import { fullTimeMap } from "./edits";
import { freeEffectSlot } from "./inspectorEdits";
import { EditorStore } from "./store";

/**
 * A trimmed, sped-up take: 30 s recorded, trimmed to [4, 26], the first
 * 4 s of what's left (source 4…8) at 2× — so OUTPUT t = 2 + (source − 8)
 * past the speed region, and output ≠ source everywhere.
 */
function setup(mutate?: (p: ReturnType<typeof newProject>) => void) {
  const p = newProject({ id: "11111111-2222-4333-8444-555555555555", duration: 30 });
  p.trimStart = 4;
  p.trimEnd = 26;
  p.speedRegions.push({ ...newSpeedRegion(4, 8), speed: 2 });
  mutate?.(p);
  const store = new EditorStore();
  store.load({ text: serializeProjectText(p), origin: "local", revision: null });
  const controller = new EditorController(store);
  const beeps: number[] = [];
  const actions = editorPaneActions(controller, () => beeps.push(1));
  return { store, controller, actions, beeps };
}

describe("freeEffectSlot (InspectorPaneContexts)", () => {
  const project = (spans: Array<[number, number]>, duration = 20) => {
    const p = newProject({ duration });
    for (const [s, e] of spans) p.zoomRegions.push(newZoomRegion(s, e));
    return p;
  };

  it("takes the gap holding the time, 3 s long", () => {
    expect(freeEffectSlot(project([]), 5)).toEqual([5, 8]);
  });

  it("shrinks to the gap and slides left to fit before the next block", () => {
    // Gap [2, 4) holds t = 3: length min(3, 2) = 2 → start min(max(3, 2), 4 − 2) = 2.
    expect(freeEffectSlot(project([[0, 2], [4, 10]]), 3)).toEqual([2, 4]);
  });

  it("jumps to the nearest gap when the time sits inside a block", () => {
    // t = 6 is inside [4, 10]; gaps [0.9? no] → [0, 4) is 2 away, [10, 20) 4 away.
    expect(freeEffectSlot(project([[4, 10]]), 6)).toEqual([1, 4]);
  });

  it("counts tilt blocks too, and ignores gaps under 0.8 s", () => {
    const p = project([[0, 5]]);
    p.tiltRegions.push(newTiltRegion(5.5, 20));
    expect(freeEffectSlot(p, 5.2)).toBeNull();
  });

  it("is null (beep) when the lane is full", () => {
    expect(freeEffectSlot(project([[0, 20]]), 3)).toBeNull();
  });
});

describe("Effects pane: add zoom / tilt at playhead on a trimmed, sped-up take", () => {
  it("places the zoom block at the SOURCE playhead (not re-converted as output)", () => {
    const { store, controller, actions } = setup();
    controller.seek(5); // OUTPUT 5 → past the 2× region: source 8 + (5 − 2) = 11
    const source = store.playheadSource();
    expect(source).toBeCloseTo(11, 12);
    actions.onAddZoomBlockAtPlayhead!();
    const z = store.getState().project!.zoomRegions;
    expect(z).toHaveLength(1);
    expect(z[0].startTime).toBeCloseTo(11, 12);
    expect(z[0].endTime).toBeCloseTo(14, 12);
    expect(z[0].zoomLevel).toBe(2);
    expect(store.getState().selection.zoomId).toBe(z[0].id);
    expect(store.getState().selection.tiltId).toBeNull();
    // The old path fed that SOURCE 11 through outputTime→source again: 8 + (11 − 2) = 17.
    expect(fullTimeMap(store.getState().project!).sourceTime(source)).toBeCloseTo(17, 12);
  });

  it("inside the sped-up span too (output 1 → source 6)", () => {
    const { store, controller, actions } = setup();
    controller.seek(1);
    actions.onAddTiltBlockAtPlayhead!();
    const t = store.getState().project!.tiltRegions;
    expect(t).toHaveLength(1);
    expect([t[0].startTime, t[0].endTime]).toEqual([6, 9]);
    // `TiltRegion(startTime:endTime:pitch: 12)` — not the timeline's seeded tilt.
    expect([t[0].pitch, t[0].yaw, t[0].roll]).toEqual([12, 0, 0]);
    expect(store.getState().selection.tiltId).toBe(t[0].id);
    expect(store.getState().inspectorTab).toBe("effects");
    store.undo();
    expect(store.getState().project!.tiltRegions).toHaveLength(0);
  });

  it("beeps and adds nothing when the EFFECTS lane is full", () => {
    const { store, controller, actions, beeps } = setup((p) => p.zoomRegions.push(newZoomRegion(0, 30)));
    controller.seek(3);
    actions.onAddZoomBlockAtPlayhead!();
    actions.onAddTiltBlockAtPlayhead!();
    expect(beeps).toHaveLength(2);
    expect(store.getState().project!.zoomRegions).toHaveLength(1);
    expect(store.getState().project!.tiltRegions).toHaveLength(0);
    expect(store.getState().canUndo).toBe(false);
  });
});

describe("Effects pane: Slide joins the selected block (onJoinSlideToSelectedBlock)", () => {
  it("snaps the slide onto the block's OUTPUT span", () => {
    const { store, controller, actions } = setup((p) => p.zoomRegions.push(newZoomRegion(6, 12, "AAAAAAAA-0000-4000-8000-000000000001")));
    controller.selectEffect("AAAAAAAA-0000-4000-8000-000000000001", null);
    expect(actions.onJoinSlideToSelectedBlock!()).toBe(true);
    const s = store.getState().project!.settings;
    expect(s.introSlideStyle).toBe("Bottom");
    // source 6 → output 1 (2×), source 12 → output 2 + 4 = 6
    expect(s.introSlideStart).toBeCloseTo(1, 12);
    expect(s.introSlideDuration).toBeCloseTo(5, 12);
  });

  it("keeps an existing slide style, floors the length at 0.3 s, and uses a lone tilt", () => {
    const { store, controller, actions } = setup((p) => {
      p.settings.introSlideStyle = "Left";
      p.tiltRegions.push(newTiltRegion(9, 9.2, "BBBBBBBB-0000-4000-8000-000000000002"));
    });
    controller.selectEffect(null, "BBBBBBBB-0000-4000-8000-000000000002");
    expect(actions.onJoinSlideToSelectedBlock!()).toBe(true);
    const s = store.getState().project!.settings;
    expect(s.introSlideStyle).toBe("Left");
    expect(s.introSlideStart).toBeCloseTo(3, 12);
    expect(s.introSlideDuration).toBe(0.3);
  });

  it("returns false with no block selected (a plain global slide)", () => {
    const { store, actions } = setup();
    expect(actions.onJoinSlideToSelectedBlock!()).toBe(false);
    expect(store.getState().project!.settings.introSlideStyle).toBe("Off");
  });
});
