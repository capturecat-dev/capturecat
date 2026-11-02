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

  it("Effects → Cutout / Pop-out card: a 4 s Bubble region with the look, and segmentation is kicked", () => {
    const { store, controller } = setup();
    let kicked = 0;
    controller.hooks.cameraLookAdded = () => void kicked++;
    void controller.effectsPick("cameraCutout");
    const regions = store.getState().project!.cameraLayoutRegions;
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({ mode: "bubble", look: "cutout", startTime: 0, endTime: 4 });
    expect(store.getState().selection.cameraLayoutId).toBe(regions[0]!.id);
    void controller.effectsPick("cameraPopOut");
    const second = store.getState().project!.cameraLayoutRegions[1]!;
    expect(second).toMatchObject({ mode: "bubble", look: "popOut" });
    expect(second.startTime).toBeGreaterThanOrEqual(4);
    expect(kicked).toBe(2);
    store.undo();
    expect(store.getState().project!.cameraLayoutRegions).toHaveLength(1);
  });

  it("camera-layout block menu: Copy / Paste Layout (mode, look, side; one undo step) and Camera on Left / Right", () => {
    const { store, controller } = setup();
    let kicked = 0;
    controller.hooks.cameraLookAdded = () => void kicked++;
    void controller.effectsPick("cameraPopOut"); // 0–4 s
    controller.seek(4); // output 4 = source 6
    void controller.effectsPick("cameraSideBySide");
    const [pop, split] = store.getState().project!.cameraLayoutRegions;
    expect(controller.timelineIntents().hasCameraLayoutClipboard?.()).toBe(false);

    controller.timelineAction({ type: "setCameraSide", regionId: split!.id, side: "leading" });
    expect(store.getState().project!.cameraLayoutRegions[1]).toMatchObject({ mode: "sideBySide", cameraSide: "leading" });
    expect(store.getState().undoLabel).toBe("Camera on Left");
    controller.timelineAction({ type: "setCameraSide", regionId: split!.id, side: "trailing" });
    expect(store.getState().project!.cameraLayoutRegions[1]!.cameraSide).toBeUndefined();
    controller.timelineAction({ type: "setCameraSide", regionId: split!.id, side: "leading" });

    // Copy the split, paste onto the pop-out block: its id, start and end stay.
    controller.timelineAction({ type: "copyCameraLayout", regionId: split!.id });
    expect(controller.timelineIntents().hasCameraLayoutClipboard?.()).toBe(true);
    kicked = 0;
    controller.timelineAction({ type: "pasteCameraLayout", regionId: pop!.id });
    const pasted = store.getState().project!.cameraLayoutRegions[0]!;
    expect(pasted).toEqual({ id: pop!.id, startTime: pop!.startTime, endTime: pop!.endTime, mode: "sideBySide", cameraSide: "leading" });
    expect(store.getState().undoLabel).toBe("Paste Layout");
    expect(kicked).toBe(0);
    store.undo();
    expect(store.getState().project!.cameraLayoutRegions[0]).toMatchObject({ mode: "bubble", look: "popOut" });

    // Copy the look the other way: pasting a look kicks segmentation.
    controller.timelineAction({ type: "copyCameraLayout", regionId: pop!.id });
    controller.timelineAction({ type: "pasteCameraLayout", regionId: split!.id });
    const second = store.getState().project!.cameraLayoutRegions[1]!;
    expect(second).toMatchObject({ id: split!.id, mode: "bubble", look: "popOut" });
    expect(second.cameraSide).toBeUndefined();
    expect(kicked).toBe(1);
  });

  it("Effects → Split Screen: a Side by Side block with the full-height split; Full Height / Tiles; Copy / Paste carries it", () => {
    const { store, controller } = setup();
    void controller.effectsPick("cameraSplitScreen");
    const [split] = store.getState().project!.cameraLayoutRegions;
    expect(split).toMatchObject({ mode: "sideBySide", splitStyle: "full", startTime: 0, endTime: 4 });
    controller.timelineAction({ type: "setSplitStyle", regionId: split!.id, style: "tiles" });
    expect(store.getState().project!.cameraLayoutRegions[0]!.splitStyle).toBeUndefined();
    expect(store.getState().undoLabel).toBe("Tiles");
    controller.timelineAction({ type: "setSplitStyle", regionId: split!.id, style: "full" });
    expect(store.getState().undoLabel).toBe("Full Height");

    controller.seek(4); // output 4 = source 6
    void controller.effectsPick("cameraFull");
    const other = store.getState().project!.cameraLayoutRegions[1]!;
    controller.timelineAction({ type: "copyCameraLayout", regionId: split!.id });
    controller.timelineAction({ type: "pasteCameraLayout", regionId: other.id });
    expect(store.getState().project!.cameraLayoutRegions[1]).toEqual({
      id: other.id,
      startTime: other.startTime,
      endTime: other.endTime,
      mode: "sideBySide",
      splitStyle: "full",
    });
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
