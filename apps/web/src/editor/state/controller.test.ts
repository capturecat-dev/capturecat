import { describe, expect, it } from "vitest";

import { newAnnotation, newProject, newSpeedRegion, serializeProjectText } from "../core/model";
import { EditorController } from "./controller";
import { EditorStore } from "./store";

const ANN = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";

function setup() {
  const p = newProject({ id: "11111111-2222-4333-8444-555555555555", duration: 20 });
  p.speedRegions.push({ ...newSpeedRegion(0, 4), speed: 2 });
  p.annotations.push(newAnnotation("text", 10, 12, ANN));
  const store = new EditorStore();
  store.load({ text: serializeProjectText(p), origin: "local", revision: null });
  const controller = new EditorController(store);
  return { store, controller };
}

describe("EditorController (canvas callbacks)", () => {
  it("selecting an annotation outside the playhead seeks into it (SOURCE → OUTPUT)", () => {
    const { store, controller } = setup();
    controller.selectTarget({ lane: "annotate", id: ANN });
    expect(store.getState().selection.annotationId).toBe(ANN);
    expect(store.getState().inspectorTab).toBe("annotations");
    // source 10.05 → output 2 + 6.05
    expect(controller.playhead.get()).toBeCloseTo(8.05, 12);
  });

  it("context-menu adds convert OUTPUT → SOURCE", () => {
    const { store, controller } = setup();
    controller.timelineAction({ type: "addZoomAt", time: 1 }); // output 1 = source 2
    expect(store.getState().project!.zoomRegions[0]).toMatchObject({ startTime: 2, endTime: 5 });
    controller.timelineAction({ type: "addAnnotationAt", time: 3, annotation: "tap" }); // source 5
    const tap = store.getState().project!.annotations.find((a) => a.type === "tap")!;
    expect([tap.startTime, tap.endTime, tap.fontSize, tap.x]).toEqual([5, 8, 60, 0.5]);
  });

  it("a speed edit keeps the SOURCE frame under the playhead", () => {
    const { store, controller } = setup();
    controller.seek(5); // source 7
    controller.timelineAction({ type: "removeSpeed", regionId: store.getState().project!.speedRegions[0].id });
    expect(controller.playhead.get()).toBeCloseTo(7, 12);
    store.undo();
    expect(controller.playhead.get()).toBeCloseTo(5, 12);
  });

  it("intro chip: open selects + Effects tab; delete turns it off, undo restores", () => {
    const { store, controller } = setup();
    void controller.effectsPick("slide");
    expect(store.getState().project!.settings.introSlideStyle).toBe("Bottom");
    expect(store.getState().selection.introSelected).toBe(true);
    controller.timelineAction({ type: "delete", target: { lane: "intro" } });
    expect(store.getState().project!.settings.introSlideStyle).toBe("Off");
    store.undo();
    expect(store.getState().project!.settings.introSlideStyle).toBe("Bottom");
  });

  it("⌘D duplicates the selected linked block into the next free slot", () => {
    const { store, controller } = setup();
    controller.seek(2); // source 4
    void controller.effectsPick("showcase");
    const cb = controller.shellCallbacks();
    cb.onDuplicate!();
    const p = store.getState().project!;
    expect(p.zoomRegions.map((z) => [z.startTime, z.endTime])).toEqual([
      [4, 7],
      [7, 10],
    ]);
    expect(p.tiltRegions.map((t) => [t.startTime, t.endTime, t.pitch])).toEqual([
      [4, 7, 10],
      [7, 10, 10],
    ]);
    expect(store.getState().selection.zoomId).toBe(p.zoomRegions[1].id);
    cb.onDelete!();
    expect(store.getState().project!.zoomRegions).toHaveLength(1);
    expect(store.getState().project!.tiltRegions).toHaveLength(1);
  });
});
