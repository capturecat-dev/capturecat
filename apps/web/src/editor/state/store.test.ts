import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { newProject, newSpeedRegion, newZoomRegion, parseProjectText, serializeProjectText, type Project } from "../core/model";
import { deepClone, reconcile } from "./draft";
import * as E from "./edits";
import { EMPTY_SELECTION } from "./selection";
import { decodeChangeHeader, diff, encodeChangeHeader } from "../core/merge";
import { EditorStore, type Persistence, type SaveMeta, type SaveResult } from "./store";
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

    // No server document → no merge base: the two-way Keep mine / Load theirs fallback.
    next = { ok: false, conflict: true, revision: 5, document: null, updatedAt: "now" };
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

// ── Project history (docs/project-history.md §7) ──────────────────────────

describe("EditorStore — project history", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  const T = Date.parse("2026-09-30T12:00:00.000Z");
  type Call = { doc: string; rev: number; meta: SaveMeta | undefined };

  /** A cloud store at revision 1 whose saves are recorded and answered by `answer`. */
  function cloud(text: string, answer: (call: Call, n: number) => SaveResult, clock = () => T) {
    const calls: Call[] = [];
    const store = new EditorStore({ clock });
    store.load({
      text,
      origin: "cloud",
      revision: 1,
      persistence: {
        save: async (doc, rev, meta) => {
          const call = { doc, rev, meta };
          calls.push(call);
          return answer(call, calls.length);
        },
      },
    });
    return { store, calls };
  }

  /** `fixture()` with a JSON-level edit (theirs). */
  function edited(text: string, mut: (j: Record<string, any>) => void): string {
    const j = JSON.parse(text);
    mut(j);
    return JSON.stringify(j, null, 2);
  }

  const Z1 = "AAAAAAAA-BBBB-4CCC-8DDD-000000000001";
  const withZoom = () => fixture((p) => p.zoomRegions.push(newZoomRegion(2, 5, Z1)));

  it("preview never marks the project dirty or saves; exit restores the live project", async () => {
    const text = fixture();
    const { store, calls } = cloud(text, () => ({ ok: true, revision: 2 }));
    const old = edited(text, (j) => {
      j.name = "Old cut";
      j.settings.backgroundPadding = 3;
    });
    store.previewVersion({ versionId: "v1", title: "Sep 28, 3:42 PM — Ana on Web", text: old });
    expect(store.getState()).toMatchObject({ dirty: false, canUndo: false, preview: { versionId: "v1" } });
    expect(store.getState().project!.name).toBe("Old cut");
    expect(store.documentText()).toBe(old); // the engine renders the version's exact document

    // Every edit path is off while previewing.
    store.updateSettings({ backgroundPadding: 99 });
    store.updateProject({ name: "nope" });
    expect(store.apply(E.addZoomRegion())).toBeNull();
    expect(() => store.transact("Agent: x", (d) => void (d.name = "agent"))).toThrow(/read-only/);
    expect(store.undo()).toBeNull();
    await vi.advanceTimersByTimeAsync(5000);
    await store.flush();
    expect(calls).toHaveLength(0);
    expect(store.getState()).toMatchObject({ dirty: false, sync: "saved" });
    expect(store.getState().project!.settings.backgroundPadding).toBe(3);

    store.exitPreview();
    expect(store.getState().preview).toBeNull();
    expect(store.documentText()).toBe(text);
    await vi.advanceTimersByTimeAsync(5000);
    expect(calls).toHaveLength(0);
  });

  it("unsaved live edits wait out a preview, then save the LIVE document", async () => {
    const text = fixture();
    const { store, calls } = cloud(text, () => ({ ok: true, revision: 2 }));
    store.updateSettings({ backgroundPadding: 21 });
    store.previewVersion({ versionId: "v1", title: "t", text: edited(text, (j) => (j.name = "Old")) });
    await vi.advanceTimersByTimeAsync(3000);
    expect(calls).toHaveLength(0);
    expect(store.getState().dirty).toBe(true); // still the LIVE flag
    store.exitPreview();
    await vi.advanceTimersByTimeAsync(900);
    expect(calls).toHaveLength(1);
    expect(JSON.parse(calls[0].doc)).toMatchObject({ name: "Untitled Recording", settings: { backgroundPadding: 21 } });
    expect(store.getState().canUndo).toBe(true);
  });

  it("a clean merge on 409 saves exactly once, with the merge headers", async () => {
    const text = fixture();
    const theirs = edited(text, (j) => (j.name = "Renamed by Ana"));
    const { store, calls } = cloud(text, (_c, n) =>
      n === 1 ? { ok: false, conflict: true, revision: 5, document: theirs, updatedAt: "2026-09-30T11:00:00.000Z" } : { ok: true, revision: 6 },
    );
    store.updateSettings({ backgroundPadding: 30 });
    await vi.advanceTimersByTimeAsync(900);
    await vi.advanceTimersByTimeAsync(2000);
    expect(calls).toHaveLength(2);
    const [first, second] = calls;
    expect(first.rev).toBe(1);
    expect(first.meta).toMatchObject({ source: "human" });
    expect(first.meta!.checkpoint).toBeUndefined();
    // The merge save: against theirs, both edits in, a merge checkpoint.
    expect(second.rev).toBe(5);
    const merged = JSON.parse(second.doc);
    expect(merged).toMatchObject({ name: "Renamed by Ana", settings: { backgroundPadding: 30 } });
    expect(merged.futureKey).toEqual({ nested: [1, 2, 3] });
    expect(second.meta).toMatchObject({ checkpoint: "merge", mergedFrom: 5, source: "human" });
    expect(second.meta!.change).toBe(encodeChangeHeader(diff(JSON.parse(theirs), merged)));
    expect(decodeChangeHeader(second.meta!.change!)).toMatchObject({ settings: { background: ["backgroundPadding"] } });
    expect(store.getState()).toMatchObject({ sync: "saved", revision: 6, dirty: false, conflict: null, review: null });
    expect(store.getState().mergeNotice).toMatchObject({ count: 1, serverRevision: 5 });
    // ONE undo entry for the merge; undoing it steps back to mine-only.
    expect(store.getState().undoLabel).toBe("Merge Changes");
    store.undo();
    expect(store.getState().project!.name).toBe("Untitled Recording");
    expect(store.getState().project!.settings.backgroundPadding).toBe(30);
  });

  it("mineWins: ties go to theirs; a later local edit wins", async () => {
    const text = fixture();
    const run = async (serverAt: number) => {
      const theirs = edited(text, (j) => (j.settings.backgroundPadding = 77));
      const { store, calls } = cloud(text, (_c, n) =>
        n === 1 ? { ok: false, conflict: true, revision: 3, document: theirs, updatedAt: new Date(serverAt).toISOString() } : { ok: true, revision: 4 },
      );
      store.updateSettings({ backgroundPadding: 11 }); // local edit at T
      await vi.advanceTimersByTimeAsync(900);
      await vi.advanceTimersByTimeAsync(900);
      return { store, calls };
    };
    // Same instant → theirs (nothing left to save: merged == theirs).
    const tie = await run(T);
    expect(tie.store.getState().project!.settings.backgroundPadding).toBe(77);
    expect(tie.calls).toHaveLength(1);
    expect(tie.store.getState()).toMatchObject({ dirty: false, revision: 3, sync: "saved" });
    // Server saved before the local edit → mine.
    const mine = await run(T - 1);
    expect(mine.store.getState().project!.settings.backgroundPadding).toBe(11);
    expect(mine.calls).toHaveLength(2);
    expect(mine.calls[1].meta).toMatchObject({ checkpoint: "merge", mergedFrom: 3 });
    // Server saved after → theirs.
    const later = await run(T + 1);
    expect(later.store.getState().project!.settings.backgroundPadding).toBe(77);
  });

  it("real conflicts → review: nothing saves until resolved, then one merge save", async () => {
    const text = withZoom();
    const theirs = edited(text, (j) => (j.zoomRegions = [])); // they deleted Z1
    const { store, calls } = cloud(text, (_c, n) =>
      n === 1 ? { ok: false, conflict: true, revision: 9, document: theirs, updatedAt: "2026-09-30T11:00:00.000Z" } : { ok: true, revision: 10 },
    );
    store.updateRegion("zoom", Z1, { zoomLevel: 3 }); // we edited it
    await vi.advanceTimersByTimeAsync(900);
    expect(store.getState().sync).toBe("review");
    const review = store.getState().review!;
    expect(review.conflicts).toHaveLength(1);
    expect(review.conflicts[0]).toMatchObject({ kind: "deleteVsModify", deletedBy: "theirs", defaultResolution: "mine" });
    expect(store.reviewDocuments()).not.toBeNull();

    // More edits while reviewing still never save.
    store.updateSettings({ backgroundPadding: 50 });
    await vi.advanceTimersByTimeAsync(5000);
    await store.flush();
    expect(calls).toHaveLength(1);
    expect(store.getState().sync).toBe("review");

    // Pick theirs (delete), apply → exactly one save, a merge checkpoint.
    store.setReviewChoice(review.conflicts[0].id, "theirs");
    expect(store.getState().review!.conflicts[0].resolution).toBe("theirs");
    expect(store.applyReview()).toBe(true);
    await vi.advanceTimersByTimeAsync(900);
    expect(calls).toHaveLength(2);
    const saved = JSON.parse(calls[1].doc);
    expect(saved.zoomRegions).toEqual([]);
    expect(saved.settings.backgroundPadding).toBe(50);
    expect(calls[1]).toMatchObject({ rev: 9, meta: { checkpoint: "merge", mergedFrom: 9 } });
    expect(store.getState()).toMatchObject({ sync: "saved", review: null, conflict: null, revision: 10 });
  });

  it("restore is ONE undo step, 'Restore Version'; undoing it re-saves the previous document", async () => {
    const text = fixture();
    const { store, calls } = cloud(text, () => ({ ok: true, revision: 8 }));
    store.updateSettings({ backgroundPadding: 12 });
    await vi.advanceTimersByTimeAsync(900);
    expect(calls).toHaveLength(1);
    const depth = store.history().length;
    const old = edited(text, (j) => (j.name = "September cut"));
    store.previewVersion({ versionId: "v1", title: "t", text: old });
    store.applyRestore({ text: old, revision: 7 });
    expect(store.getState()).toMatchObject({ preview: null, revision: 7, dirty: false, sync: "saved", undoLabel: "Restore Version" });
    expect(store.history()).toHaveLength(depth + 1);
    expect(store.documentText()).toBe(old); // the server's bytes, verbatim
    await vi.advanceTimersByTimeAsync(2000);
    expect(calls).toHaveLength(1); // the API saved it — no PUT
    store.undo();
    expect(store.getState().project!.settings.backgroundPadding).toBe(12);
    expect(store.getState().dirty).toBe(true);
    await vi.advanceTimersByTimeAsync(900);
    expect(calls).toHaveLength(2);
    expect(calls[1].rev).toBe(7);
  });

  it("X-CC-Source comes from the undo entries: human, agent, mixed", async () => {
    const { store, calls } = cloud(fixture(), (_c, n) => ({ ok: true, revision: 1 + n }));
    store.transact("Agent: set_style", (d) => void (d.settings.backgroundPadding = 5), { source: "mcp", forceEntry: true });
    await vi.advanceTimersByTimeAsync(900);
    store.updateSettings({ backgroundPadding: 6 });
    await vi.advanceTimersByTimeAsync(900);
    store.transact("Agent: x", (d) => void (d.settings.backgroundPadding = 7), { source: "mcp" });
    store.updateSettings({ shadowRadius: 9 } as never);
    await vi.advanceTimersByTimeAsync(900);
    store.undo({ source: "mcp" }); // the WebMCP undo tool
    await vi.advanceTimersByTimeAsync(900);
    expect(calls.map((c) => c.meta!.source)).toEqual(["agent", "human", "mixed", "agent"]);
    expect(decodeChangeHeader(calls[0].meta!.change!)).toMatchObject({ settings: { background: ["backgroundPadding"] } });
  });
});
