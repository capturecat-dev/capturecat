import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { diff, type Json, type MergeConflict } from "../core/merge";
import { newProject, newZoomRegion, serializeProjectText } from "../core/model";
import { CloudApiError, type ProjectVersion, type VersionDetail, type VersionList } from "./cloud";
import {
  compareDocuments,
  daySections,
  describeConflict,
  formatBytes,
  HistoryController,
  mergedCalloutTitle,
  versionAuthor,
  versionBadges,
  versionCaption,
  type HistoryApi,
} from "./history";
import { ProjectMedia } from "./projectMedia";
import { EditorStore, type SaveResult } from "./store";

const PID = "11111111-2222-4333-8444-555555555555";
const ZA = "AAAAAAAA-BBBB-4CCC-8DDD-00000000000A";

/** One base project (newProject mints random ids — build it once). */
const BASE = (() => {
  const p = newProject({ id: PID, duration: 20, videoURL: "file:///tmp/r.mp4" });
  return serializeProjectText(p);
})();
/** A zoom region exactly as the model serializes it. */
const ZOOM = (() => {
  const p = newProject({ id: PID, duration: 20, videoURL: "file:///tmp/r.mp4" });
  p.zoomRegions.push(newZoomRegion(1, 4, ZA));
  return JSON.parse(serializeProjectText(p)).zoomRegions[0];
})();

function doc(mut?: (j: Record<string, any>) => void): string {
  const j = JSON.parse(BASE);
  mut?.(j);
  return JSON.stringify(j);
}

function version(id: string, seq: number, extra: Partial<ProjectVersion> = {}): ProjectVersion {
  return {
    id,
    seq,
    revision: seq,
    firstRevision: seq,
    kind: "edit",
    label: null,
    namedBy: null,
    namedAt: null,
    actorUid: "u1",
    actorName: "Ana",
    clientKind: "web",
    source: "human",
    change: null,
    restoredFrom: null,
    mergedFromRevision: null,
    openedAt: "2026-09-30T10:00:00.000Z",
    updatedAt: "2026-09-30T10:00:00.000Z",
    docBytes: 100,
    ...extra,
  };
}

describe("history presentation", () => {
  it("day sections: Today / Yesterday / a date", () => {
    const now = new Date(2026, 8, 30, 15, 0);
    const at = (d: number, h: number) => new Date(2026, 8, d, h).toISOString();
    const s = daySections([version("c", 3, { updatedAt: at(30, 9) }), version("b", 2, { updatedAt: at(29, 9) }), version("a", 1, { updatedAt: at(27, 9) })], now);
    expect(s.map((x) => [x.title, x.versions.map((v) => v.id)])).toEqual([
      ["Today", ["c"]],
      ["Yesterday", ["b"]],
      ["Sun, Sep 27", ["a"]],
    ]);
  });

  it("badges, author line, captions", () => {
    expect(versionBadges(version("a", 1, { clientKind: "mac" })).map((b) => b.text)).toEqual(["Mac"]);
    expect(versionBadges(version("a", 1, { source: "agent" })).map((b) => b.text)).toEqual(["Web", "Agent"]);
    expect(versionAuthor(version("a", 1))).toBe("Ana on Web");
    expect(versionAuthor(version("a", 1, { source: "agent", clientKind: "mac" }))).toBe("Agent via Mac (Ana)");
    const cs = diff(JSON.parse(doc()) as Json, JSON.parse(doc((j) => (j.zoomRegions = [{ id: ZA, startTime: 1, endTime: 4, zoomLevel: 2, focalPoint: { x: 0.5, y: 0.5 } }]))) as Json);
    expect(versionCaption(version("a", 1, { change: cs as unknown }))).toBe("Zoom added");
    expect(versionCaption(version("a", 1, { kind: "upload" }))).toBe("Uploaded");
    expect(versionCaption(version("a", 1, { kind: "restore" }))).toBe("Restored an earlier version");
    expect(formatBytes(1_500_000_000)).toBe("1.4 GB");
    expect(mergedCalloutTitle(2, "Ana (Web)")).toBe("Merged 2 changes from Ana (Web)");
    expect(mergedCalloutTitle(1, null)).toBe("Merged 1 change");
  });

  it("compare groups by Timeline, inspector tab, Subtitles and Project; timeline rows seek", () => {
    const a = JSON.parse(doc((j) => (j.settings.backgroundType = "Gradient"))) as Json;
    const b = JSON.parse(
      doc((j) => {
        j.name = "Launch cut";
        j.settings.backgroundType = "Image";
        j.zoomRegions = [{ id: ZA, startTime: 12, endTime: 15, zoomLevel: 2, focalPoint: { x: 0.5, y: 0.5 } }];
        j.subtitles = [{ id: "CCCCCCCC-BBBB-4CCC-8DDD-00000000000C", startTime: 3, endTime: 5, text: "Hello there", words: [] }];
        j.trimStart = 2;
      }),
    ) as Json;
    const groups = compareDocuments(a, b);
    expect(groups.map((g) => g.title)).toEqual(["Timeline", "Background", "Subtitles", "Project"]);
    const timeline = groups[0].rows.map((r) => r.text);
    expect(timeline).toContain("Zoom 0:12–0:15 added");
    expect(timeline).toContain("Trim start: 0:00 → 0:02");
    expect(groups[0].rows.find((r) => r.text.startsWith("Zoom"))!.sourceTime).toBe(12);
    expect(groups[1].rows).toEqual([{ id: "settings:backgroundType", text: "Background: Gradient → Image", tab: "background" }]);
    expect(groups[2].rows[0].text).toBe("Caption “Hello there” 0:03–0:05 added");
    expect(groups[3].rows[0].text).toBe("Renamed: Untitled Recording → Launch cut");
  });

  it("describes a delete-vs-modify conflict from the documents", () => {
    const base = JSON.parse(doc((j) => (j.annotations = [{ id: ZA, startTime: 1, endTime: 2, text: "Click here" }]))) as Json;
    const c: MergeConflict = { id: `deleteVsModify:annotations[${ZA}]`, kind: "deleteVsModify", path: `annotations[${ZA}]`, resolution: "mine", defaultResolution: "mine", deletedBy: "theirs" };
    const d = describeConflict(c, { base, mine: base, theirs: undefined }, "Ana");
    expect(d.title).toBe("Annotation “Click here” 0:01–0:02");
    expect(d.detail).toBe("Ana deleted it; you edited it.");
    expect([d.mine, d.theirs]).toEqual(["Keep your edit", "Delete it"]);
  });
});

describe("HistoryController", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  function setup(opts: { list?: () => Promise<VersionList>; save?: () => SaveResult; isOwner?: boolean; confirm?: number } = {}) {
    const text = doc();
    const store = new EditorStore({ clock: () => Date.parse("2026-09-30T12:00:00Z") });
    const saves: string[] = [];
    store.load({
      text,
      origin: "cloud",
      revision: 4,
      persistence: { save: async (d) => (saves.push(d), opts.save?.() ?? { ok: true, revision: 5 }) },
    });
    const old = doc((j) => (j.name = "Old cut"));
    const versions = [version("v3", 3, { revision: 4 }), version("v2", 2, { label: "Pitch" }), version("v1", 1, { kind: "upload", clientKind: "mac" })];
    const api = {
      list: vi.fn(opts.list ?? (async () => ({ versions, headVersionId: "v3", retention: { days: 30, maxNamed: 25, namedCount: 1 }, pinnedMediaBytes: 2048, nextBefore: null }))),
      get: vi.fn(async (id: string): Promise<VersionDetail> => ({
        version: versions.find((v) => v.id === id)!,
        document: old,
        media: { "recording.mov": { path: "recording.mov", sha256: "0", bytes: 1, contentType: "video/mp4", source: null, url: "https://r2.test/old.mov" } },
        sources: {},
        urlsExpireAt: 0,
      })),
      name: vi.fn(async (id: string, label: string | null) => ({ ...versions.find((v) => v.id === id)!, label })),
      restore: vi.fn(async () => ({ ok: true as const, revision: 6, documentSha256: null, updatedAt: "u", document: null, version: null })),
      remove: vi.fn(async () => undefined),
    } satisfies HistoryApi;
    const media = { override: null as unknown, setOverride(u: unknown) { this.override = u; }, get hasOverride() { return this.override != null; } };
    const confirm = vi.fn(async () => opts.confirm ?? 0);
    const seekSource = vi.fn();
    const h = new HistoryController({ store, api, isOwner: opts.isOwner ?? true, media, confirm, seekSource, refreshDelayMs: 10 });
    return { store, api, h, media, confirm, saves, old, seekSource };
  }

  it("opens, lists, and gates Free plans to an upsell (retention 0 or a plan 403)", async () => {
    const { h } = setup();
    h.open();
    await vi.advanceTimersByTimeAsync(0);
    expect(h.getState()).toMatchObject({ open: true, status: "ready", headVersionId: "v3", pinnedMediaBytes: 2048 });
    const free = setup({ list: async () => ({ versions: [], headVersionId: null, retention: { days: 0, maxNamed: 0, namedCount: null }, pinnedMediaBytes: 0, nextBefore: null }) });
    free.h.open();
    await vi.advanceTimersByTimeAsync(0);
    expect(free.h.getState().status).toBe("gated");
    const forbidden = setup({ list: async () => { throw new CloudApiError(403, { error: "This feature requires a paid plan", tier: "free" }); } });
    forbidden.h.open();
    await vi.advanceTimersByTimeAsync(0);
    expect(forbidden.h.getState().status).toBe("gated");
    const missing = setup({ list: async () => { throw new CloudApiError(404, { error: "Not found" }); } });
    missing.h.open();
    await vi.advanceTimersByTimeAsync(0);
    expect(missing.h.getState().status).toBe("unavailable");
  });

  it("preview resolves media through the version's manifest; back to current drops it", async () => {
    const { h, store, media, saves } = setup();
    await h.refresh();
    await h.preview("v2");
    expect(store.getState().preview).toMatchObject({ versionId: "v2" });
    expect(store.getState().preview!.title).toMatch(/— Ana on Web$/);
    expect(store.getState().project!.name).toBe("Old cut");
    expect((media.override as { media: Record<string, unknown> }).media["recording.mov"]).toBeTruthy();
    h.backToCurrent();
    expect(store.getState().preview).toBeNull();
    expect(media.override).toBeNull();
    await vi.advanceTimersByTimeAsync(3000);
    expect(saves).toHaveLength(0);
  });

  it("restore: confirm → POST with the current revision → one 'Restore Version' undo step", async () => {
    const { h, store, api, confirm } = setup();
    await h.refresh();
    await h.preview("v2");
    expect(await h.restore("v2")).toBe(true);
    expect(confirm).toHaveBeenCalledWith(expect.objectContaining({ title: "Restore this version?" }));
    expect(api.restore).toHaveBeenCalledWith("v2", 4);
    expect(store.getState()).toMatchObject({ preview: null, revision: 6, undoLabel: "Restore Version", dirty: false });
    expect(store.getState().project!.name).toBe("Old cut");
    // Cancelled confirm → nothing.
    const c = setup({ confirm: 1 });
    await c.h.refresh();
    expect(await c.h.restore("v2")).toBe(false);
    expect(c.api.restore).not.toHaveBeenCalled();
  });

  it("restore that loses the race merges the head instead", async () => {
    const { h, store, api } = setup();
    await h.refresh();
    const head = doc((j) => (j.settings.backgroundPadding = 44));
    api.restore.mockResolvedValueOnce({ ok: false, conflict: true, revision: 8, documentSha256: null, updatedAt: "2026-09-30T13:00:00Z", document: head } as never);
    expect(await h.restore("v2")).toBe(false);
    expect(store.getState().project!.settings.backgroundPadding).toBe(44);
    expect(store.getState().revision).toBe(8);
    expect(h.getState().message).toMatch(/restore again/);
  });

  it("names inline (PATCH), deletes (owner only, never the head), frees up unnamed versions", async () => {
    const { h, api } = setup();
    await h.refresh();
    h.startNaming("v1");
    expect(await h.commitName("v1", "  Before intro ")).toBe(true);
    expect(api.name).toHaveBeenCalledWith("v1", "Before intro");
    expect(h.version("v1")!.label).toBe("Before intro");
    expect(await h.remove("v3")).toBe(false); // the head
    expect(await h.remove("v1")).toBe(true);
    expect(api.remove).toHaveBeenCalledWith("v1");
    const member = setup({ isOwner: false });
    await member.h.refresh();
    expect(await member.h.remove("v1")).toBe(false);
    expect(await member.h.freeUp()).toBe(0);
    const owner = setup();
    await owner.h.refresh();
    expect(await owner.h.freeUp()).toBe(1); // v1 only: v2 is named, v3 is current
    expect(owner.api.remove).toHaveBeenCalledWith("v1");
  });

  it("compare with current / with another version; a row seeks", async () => {
    const { h, seekSource } = setup();
    await h.refresh();
    await h.compareWithCurrent("v2");
    expect(h.getState().mode).toBe("compare");
    expect(h.getState().compare!.groups.map((g) => g.title)).toEqual(["Project"]);
    expect(h.getState().compare!.groups[0].rows[0].text).toBe("Renamed: Old cut → Untitled Recording");
    h.armCompare("v1");
    expect(h.pick("v2")).toBe(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(h.getState().compare).toMatchObject({ loading: false });
    h.goTo({ id: "z", text: "Zoom", sourceTime: 12 });
    expect(seekSource).toHaveBeenCalledWith(12);
  });

  it("a review-state merge opens Merge Review; the merge callout learns who", async () => {
    const zoomed = doc((j) => (j.zoomRegions = [ZOOM]));
    const store = new EditorStore({ clock: () => Date.parse("2026-09-30T12:00:00Z") });
    let n = 0;
    store.load({
      text: zoomed,
      origin: "cloud",
      revision: 1,
      persistence: {
        save: async () =>
          ++n === 1 ? { ok: false, conflict: true, revision: 2, document: doc(), updatedAt: "2026-09-30T11:00:00Z" } : { ok: true, revision: 3 },
      },
    });
    const api: HistoryApi = {
      list: async () => ({ versions: [version("v2", 2, { revision: 2, actorName: "Ben", clientKind: "mac" })], headVersionId: "v2", retention: null, pinnedMediaBytes: 0, nextBefore: null }),
      get: async () => { throw new Error("unused"); },
      name: async () => null,
      restore: async () => { throw new Error("unused"); },
      remove: async () => undefined,
    };
    const h = new HistoryController({ store, api, isOwner: true });
    store.updateRegion("zoom", ZA, { zoomLevel: 3 });
    await vi.advanceTimersByTimeAsync(900);
    expect(store.getState().sync).toBe("review");
    expect(h.getState()).toMatchObject({ open: true, mode: "review" });
    store.applyReview();
    await vi.advanceTimersByTimeAsync(900);
    expect(store.getState().sync).toBe("saved");
    expect(h.getState().mode).toBe("list");
    expect(h.getState().mergedFrom).toMatchObject({ who: "Ben (Mac)" });
  });
});

describe("ProjectMedia — a previewed version's manifest", () => {
  it("resolves through the override first, falls through for the rest, and notifies", () => {
    const media = new ProjectMedia({ projectId: PID, origin: "local", localUrl: (ref) => `live:${ref}` });
    const seen = vi.fn();
    media.subscribe(seen);
    const ref = "file:///Users/me/Library/Application%20Support/CaptureCat/Projects/X/recording.mp4";
    expect(media.mediaUrl(ref)).toBe(`live:${ref}`);
    media.setOverride({
      media: { "recording.mp4": { path: "recording.mp4", sha256: "0", bytes: 1, contentType: "video/mp4", source: null, url: "https://r2.test/v1/recording.mp4" } },
      sources: {},
    });
    expect(seen).toHaveBeenCalledTimes(1);
    expect(media.hasOverride).toBe(true);
    expect(media.mediaUrl(ref)).toBe("https://r2.test/v1/recording.mp4");
    expect(media.mediaUrl("logo.png")).toBe("live:logo.png"); // not in that version → live
    media.setOverride(null);
    expect(media.mediaUrl(ref)).toBe(`live:${ref}`);
    expect(seen).toHaveBeenCalledTimes(2);
  });
});
