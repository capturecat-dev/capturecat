import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { newProject, newSpeedRegion, newZoomRegion, parseProjectText, serializeProjectText, type Project } from "../core/model";
import { deepClone, reconcile } from "./draft";
import * as E from "./edits";
import { EMPTY_SELECTION } from "./selection";
import { EditorStore, type Persistence, type SaveResult } from "./store";
import { timelineSnapshot } from "./timeline";

function fixture(mut?: (p: Project) => void): string {
  const p = newProject({ id: "11111111-2222-4333-8444-555555555555", duration: 20, videoURL: "file:///tmp/r.mp4" });
  mut?.(p);
  // A key the model doesn't know must survive every save.
  const json = JSON.parse(serializeProjectText(p));
  json.futureKey = { nested: [1, 2, 3] };
  return JSON.stringify(json, null, 2);
}

function loaded(text = fixture(), persistence: Persistence | null = null) {
  const store = new EditorStore();
  store.load({ text, origin: persistence ? "cloud" : "local", revision: persistence ? 1 : null, persistence });
  return store;
}

describe("draft / reconcile", () => {
  it("returns the base when nothing changed and shares untouched subtrees", () => {
    const base = parseProjectText(fixture((p) => p.zoomRegions.push(newZoomRegion(1, 2))));
    const same = reconcile(base, deepClone(base));
    expect(same).toBe(base);
    const draft = deepClone(base);
    draft.zoomRegions[0].zoomLevel = 3;
    const next = reconcile(base, draft);
    expect(next).not.toBe(base);
    expect(next.settings).toBe(base.settings);
    expect(next.subtitles).toBe(base.subtitles);
    expect(next.zoomRegions).not.toBe(base.zoomRegions);
  });
});

describe("EditorStore — lossless + undo", () => {
  it("serializes the ORIGINAL text while untouched, and again after undoing back", () => {
    const text = fixture();
    const store = loaded(text);
    expect(store.documentText()).toBe(text);
    store.setPlayheadProvider(() => 2);
    expect(store.apply(E.addZoomRegion())).not.toBeNull();
    const edited = store.documentText();
    expect(edited).not.toBe(text);
    expect(JSON.parse(edited).futureKey).toEqual({ nested: [1, 2, 3] });
    expect(store.getState().dirty).toBe(true);
    store.undo();
    expect(store.documentText()).toBe(text);
    expect(store.getState().dirty).toBe(false);
    store.redo();
    expect(store.getState().project!.zoomRegions).toHaveLength(1);
  });

  it("adds at the playhead (SOURCE time through the speed map) and selects like the Mac", () => {
    const store = loaded(fixture((p) => p.speedRegions.push({ ...newSpeedRegion(0, 4), speed: 2 })));
    // Output 3 s = source 4 + 1 = 5 s (first 4 s of source play in 2 s).
    store.setPlayheadProvider(() => 3);
    expect(store.playheadSource()).toBeCloseTo(5, 12);
    store.apply(E.addZoomRegion());
    const z = store.getState().project!.zoomRegions[0];
    expect([z.startTime, z.endTime]).toEqual([5, 8]);
    expect(store.getState().selection.zoomId).toBe(z.id);
    expect(store.getState().inspectorTab).toBe("effects");
    expect(store.getState().undoLabel).toBe("Add Zoom");
  });

  it("coalesces slider drags into one undo step", () => {
    const store = loaded();
    for (let i = 0; i < 10; i++) store.updateSettings({ backgroundPadding: 40 + i });
    expect(store.getState().project!.settings.backgroundPadding).toBe(49);
    store.undo();
    expect(store.getState().project!.settings.backgroundPadding).toBe(parseProjectText(fixture()).settings.backgroundPadding);
    expect(store.getState().canUndo).toBe(false);
  });

  it("transact is all-or-nothing", () => {
    const store = loaded();
    const before = store.getState().project;
    expect(() =>
      store.transact("batch", (d) => {
        d.zoomRegions.push(newZoomRegion(1, 2));
        throw new Error("op 2 failed");
      }),
    ).toThrow("op 2 failed");
    expect(store.getState().project).toBe(before);
    expect(store.getState().canUndo).toBe(false);
  });

  it("undo restores the selection and prunes deleted ids", () => {
    const store = loaded();
    store.setPlayheadProvider(() => 1);
    store.apply(E.addBlurRegion());
    const id = store.getState().selection.blurId!;
    store.apply(E.deleteSelectedRegion);
    expect(store.getState().selection.blurId).toBeNull();
    store.undo();
    expect(store.getState().selection.blurId).toBe(id);
    store.undo();
    expect(store.getState().selection.blurId).toBeNull();
  });
});

describe("EditorStore — cloud autosave", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("debounces saves with If-Match revisions and surfaces conflicts", async () => {
    const calls: Array<[string, number]> = [];
    let next: SaveResult = { ok: true, revision: 2 };
    const store = loaded(fixture(), {
      save: async (doc, rev) => {
        calls.push([doc, rev]);
        return next;
      },
    });
    store.updateSettings({ backgroundPadding: 12 });
    store.updateSettings({ backgroundPadding: 13 });
    expect(store.getState().sync).toBe("saving");
    await vi.advanceTimersByTimeAsync(900);
    expect(calls).toHaveLength(1);
    expect(calls[0][1]).toBe(1);
    expect(JSON.parse(calls[0][0]).settings.backgroundPadding).toBe(13);
    expect(store.getState()).toMatchObject({ sync: "saved", revision: 2, dirty: false });

    next = { ok: false, conflict: true, revision: 5, document: fixture(), updatedAt: "now" };
    store.updateSettings({ backgroundPadding: 30 });
    await vi.advanceTimersByTimeAsync(900);
    expect(store.getState().sync).toBe("conflict");
    expect(calls[1][1]).toBe(2);

    next = { ok: true, revision: 6 };
    store.resolveConflict("keepMine");
    await vi.advanceTimersByTimeAsync(10);
    expect(calls[2][1]).toBe(5);
    expect(store.getState()).toMatchObject({ sync: "saved", revision: 6, conflict: null });
  });

  it("a per-gesture key stays one undo step across a mid-drag pause", async () => {
    const store = loaded();
    const move = (x: number) => store.transact("Move", (d) => void (d.settings.backgroundPadding = x), { coalesceKey: "stage-gesture:7" });
    move(10);
    await vi.advanceTimersByTimeAsync(3000);
    move(20);
    store.endCoalescing();
    move(30); // a NEW gesture reusing the key after release → new step
    store.undo();
    expect(store.getState().project!.settings.backgroundPadding).toBe(20);
    store.undo();
    expect(store.getState().canUndo).toBe(false);
  });

  it("local projects never save", async () => {
    const store = loaded();
    store.updateSettings({ backgroundPadding: 12 });
    await vi.advanceTimersByTimeAsync(2000);
    expect(store.getState()).toMatchObject({ readOnly: true, sync: "local", dirty: true });
  });
});

describe("timeline edits (TimelineViewController rules)", () => {
  const env = { playheadSource: 0 };
  const run = (p: Project, edit: E.Edit, sel = EMPTY_SELECTION) => {
    const draft = deepClone(p);
    const out = edit(draft, sel, env);
    return { p: draft, out };
  };

  it("findNonOverlappingSlot: containing gap, nearest gap, shrink, full", () => {
    expect(E.findNonOverlappingSlot([2, 5], [[4, 6]], 20)).toEqual([1, 4]); // slides back to keep the full 3 s
    expect(E.findNonOverlappingSlot([5, 8], [[4, 6]], 20)).toEqual([1, 4]); // tie → the first gap (Swift min(by:))
    expect(E.findNonOverlappingSlot([5.5, 8.5], [[4, 6]], 20)).toEqual([6, 9]);
    expect(E.findNonOverlappingSlot([0, 3], [[0, 19.5]], 20)).toEqual([0, 0]);
    expect(E.findNonOverlappingSlot([18, 21], [], 20)).toEqual([17, 20]);
  });

  it("zoom adds stack instead of failing on a full lane", () => {
    const p = parseProjectText(fixture((q) => q.zoomRegions.push(newZoomRegion(0, 20))));
    const { p: next, out } = run(p, E.addZoomRegion(3));
    expect(out?.label).toBe("Add Zoom");
    expect(next.zoomRegions[1]).toMatchObject({ startTime: 3, endTime: 6 });
  });

  it("blur on a full FOCUS lane is refused (beep)", () => {
    const p = parseProjectText(fixture());
    p.highlightRegions.push({ id: "H", startTime: 0, endTime: 20, label: "Highlight", rect: { x: 0, y: 0, width: 1, height: 1 }, opacity: 0.5 });
    expect(run(p, E.addBlurRegion(3)).out).toBeNull();
  });

  it("split → remove split → delete clip (no ripple)", () => {
    const p = parseProjectText(fixture());
    const a = run(p, E.splitVideoClip(8));
    expect(a.p.videoClipSegments.map((c) => [c.startTime, c.endTime])).toEqual([[0, 8], [8, 20]]);
    expect(a.p.splitPoints).toEqual([8]);
    const b = run(a.p, E.removeSplit(8));
    expect(b.p.videoClipSegments.map((c) => [c.startTime, c.endTime])).toEqual([[0, 20]]);
    const c = run(a.p, E.deleteVideoClip(a.p.videoClipSegments[0].id));
    expect(c.p.videoClipSegments.map((x) => [x.startTime, x.endTime])).toEqual([[8, 20]]);
    expect(c.p.splitPoints).toEqual([]);
    // never the last clip
    expect(run(c.p, E.deleteVideoClip(c.p.videoClipSegments[0].id)).out).toBeNull();
  });

  it("whole-track trim converts OUTPUT → SOURCE through speed regions", () => {
    const p = parseProjectText(fixture((q) => q.speedRegions.push({ ...newSpeedRegion(0, 4), speed: 2 })));
    // Output duration: 2 + 16 = 18. Trim the left edge to output 1 → source 2.
    const { p: next } = run(p, E.commitWholeDrag("resizeLeft", 1, 1, 18));
    expect(next.trimStart).toBeCloseTo(2, 12);
    const r = run(p, E.commitWholeDrag("resizeRight", -3, 0, 15));
    expect(r.p.trimEnd).toBeCloseTo(17, 12);
  });

  it("a linked zoom+tilt block moves as one and drags a joined Slide along", () => {
    const p = parseProjectText(fixture());
    p.zoomRegions.push(newZoomRegion(2, 5, "Z"));
    p.tiltRegions.push({ id: "T", startTime: 2, endTime: 5, pitch: 10, yaw: 0, roll: 0 });
    p.settings.introSlideStyle = "Bottom";
    p.settings.introSlideStart = 2;
    p.settings.introSlideDuration = 3;
    const { p: next } = run(p, E.commitEffectBlockTimes("Z", "T", 6, 9));
    expect([next.zoomRegions[0].startTime, next.tiltRegions[0].endTime]).toEqual([6, 9]);
    expect([next.settings.introSlideStart, next.settings.introSlideDuration]).toEqual([6, 3]);
  });

  it("the timeline retimes every lane through the speed map", () => {
    const p = parseProjectText(fixture((q) => q.speedRegions.push({ ...newSpeedRegion(0, 4), speed: 2 })));
    p.zoomRegions.push(newZoomRegion(4, 8, "Z"));
    const snap = timelineSnapshot({ project: p, selection: EMPTY_SELECTION, sliceArmed: false, hasAudio: true });
    expect(snap.outputDuration).toBeCloseTo(18, 12);
    expect(snap.effects[0]).toMatchObject({ start: 2, end: 6 });
    expect(snap.video!.segments.map((s) => [s.outputStart, s.outputEnd, s.speed, s.label])).toEqual([
      [0, 2, 2, "4s · 2x"],
      [2, 18, 1, "16s · 1x"],
    ]);
  });
});
