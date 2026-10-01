import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { diff, type Json, type MergeConflict } from "../core/merge";
import { newProject, newZoomRegion, serializeProjectText } from "../core/model";
import { CloudApiError, type ProjectVersion, type RestoreResult, type VersionDetail, type VersionList } from "./cloud";
import {
  compareDocuments,
  daySections,
  describeConflict,
  formatBytes,
  historyErrorMessage,
  HistoryController,
  mergedCalloutTitle,
  versionAuthor,
  versionBadges,
  versionCaption,
  type HistoryApi,
} from "./history";
import { HistoryStorageError, ProjectMedia } from "./projectMedia";
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
    documentSha256: null,
    isHead: false,
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

/** A versions page with the real list's fields. */
function page(p: Partial<VersionList> & Pick<VersionList, "versions">): VersionList {
  return { headVersionId: null, access: "owner", revision: 4, retention: null, pinnedMediaBytes: 0, freeableBytes: 0, nextBefore: null, ...p };
}

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
      list: vi.fn(opts.list ?? (async () => page({ versions, headVersionId: "v3", access: opts.isOwner === false ? "member" : "owner", retention: { days: 30, maxNamed: 25, namedCount: 1 }, pinnedMediaBytes: 2048, freeableBytes: 1024 }))),
      get: vi.fn(async (id: string): Promise<VersionDetail> => ({
        version: versions.find((v) => v.id === id)!,
        document: old,
        media: { "recording.mov": { path: "recording.mov", sha256: "0", bytes: 1, contentType: "video/mp4", source: null, url: "https://r2.test/old.mov" } },
        sources: {},
        urlsExpireAt: 0,
        missingPaths: [],
      })),
      name: vi.fn(async (id: string, label: string | null) => ({ ...versions.find((v) => v.id === id)!, label })),
      restore: vi.fn(async (): Promise<RestoreResult> => ({ ok: true, revision: 6, documentSha256: null, updatedAt: "u", restoredFrom: "v2", version: null, fileCount: 2 })),
      remove: vi.fn(async () => ({ releasedBytes: 0 })),
      freeUp: vi.fn(async () => ({ deletedVersions: ["v1"], releasedBytes: 1024, pinnedMediaBytes: 1024, freeableBytes: 0 })),
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
    const free = setup({ list: async () => page({ versions: [], retention: { days: 0, maxNamed: 0, namedCount: 0 } }) });
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
    expect(owner.h.getState()).toMatchObject({ pinnedMediaBytes: 2048, freeableBytes: 1024 });
    expect(await owner.h.freeUp()).toBe(1024); // POST …/history/free-up — the server picks the versions
    expect(owner.api.freeUp).toHaveBeenCalledTimes(1);
    expect(owner.api.remove).not.toHaveBeenCalled();
    expect(owner.confirm).toHaveBeenCalledWith(expect.objectContaining({ title: "Free up 1 KB?" }));
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
          ++n === 1
            ? { ok: false, conflict: true, revision: 2, document: doc(), updatedAt: "2026-09-30T11:00:00Z", headVersionId: "v2" }
            : { ok: true, revision: 3 },
      },
    });
    const api: HistoryApi = {
      list: vi.fn(async () => page({ versions: [version("v2", 2, { revision: 2, actorName: "Ben", clientKind: "mac" })], headVersionId: "v2" })),
      get: async () => { throw new Error("unused"); },
      name: async () => null,
      restore: async () => { throw new Error("unused"); },
      remove: async () => ({ releasedBytes: 0 }),
      freeUp: async () => ({ deletedVersions: [], releasedBytes: 0, pinnedMediaBytes: 0, freeableBytes: 0 }),
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
    // The cheapest call: the newest version alone (the head the 409 named).
    expect(api.list).toHaveBeenCalledWith({ limit: 1 });
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

describe("history errors (§6.1 codes)", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("says each refusal plainly", () => {
    const e = (status: number, body: Record<string, unknown>) => historyErrorMessage(new CloudApiError(status, { error: "raw", ...body }));
    expect(e(428, { code: "revision_required" })).toMatch(/reload the project/);
    expect(e(409, { code: "files_changed" })).toBe("The project’s media changed while restoring — try again.");
    expect(e(409, { code: "version_media_missing", missing: ["recording.mov", "cursor.json"] })).toBe(
      "Some of this version’s media is no longer stored (recording.mov, cursor.json), so it can’t be restored.",
    );
    expect(e(410, { code: "version_document_missing" })).toMatch(/no longer stored/);
    expect(e(402, { code: "named_version_limit", limit: 0 })).toBe("Named versions are part of Pro — upgrade to keep versions by name.");
    expect(e(402, { code: "named_version_limit", limit: 25, error: "This project already has 25 named versions — the most the Pro plan keeps. Remove a name first." })).toBe(
      "This project already has 25 named versions — the most the Pro plan keeps. Remove a name first.",
    );
    expect(e(400, { code: "invalid_label" })).toBe("Names can be up to 100 characters, on one line.");
    expect(e(409, { code: "head_version" })).toBe("The current version can’t be deleted.");
    expect(e(403, { error: "Account blocked" })).toBe("This account is blocked.");
  });

  it("restore retries once when a media commit raced it (files_changed)", async () => {
    const store = new EditorStore();
    store.load({ text: doc(), origin: "cloud", revision: 4, persistence: { save: async () => ({ ok: true, revision: 5 }) } });
    const v = version("v1", 1);
    const restore = vi
      .fn<HistoryApi["restore"]>()
      .mockRejectedValueOnce(new CloudApiError(409, { error: "x", code: "files_changed" }))
      .mockResolvedValueOnce({ ok: true, revision: 6, documentSha256: null, updatedAt: "u", restoredFrom: "v1", version: null, fileCount: 1 });
    const api: HistoryApi = {
      list: async () => page({ versions: [v] }),
      get: async () => ({ version: v, document: doc((j) => (j.name = "Old")), media: {}, sources: {}, urlsExpireAt: 0, missingPaths: [] }),
      name: async () => null,
      restore,
      remove: async () => ({ releasedBytes: 0 }),
      freeUp: async () => ({ deletedVersions: [], releasedBytes: 0, pinnedMediaBytes: 0, freeableBytes: 0 }),
    };
    const h = new HistoryController({ store, api, isOwner: true });
    await h.refresh();
    expect(await h.restore("v1")).toBe(true);
    expect(restore).toHaveBeenCalledTimes(2);
    expect(store.getState()).toMatchObject({ revision: 6, undoLabel: "Restore Version" });

    restore.mockRejectedValueOnce(new CloudApiError(409, { error: "x", code: "version_media_missing", missing: ["logo.png"] }));
    expect(await h.restore("v1")).toBe(false);
    expect(h.getState().message).toBe("Couldn’t restore. Some of this version’s media is no longer stored (logo.png), so it can’t be restored.");
  });
});

describe("ProjectMedia — the storage cap vs history", () => {
  const loadedCloud = (media: Record<string, { sha256: string; contentType: string }>) => ({
    projectId: PID,
    name: "P",
    revision: 1,
    documentSha256: null,
    access: "owner" as const,
    isOwner: true,
    orgId: null,
    updatedAt: "t",
    document: "{}",
    media: Object.fromEntries(Object.entries(media).map(([path, m]) => [path, { path, bytes: 1, source: null, url: `https://r2.test/${path}`, ...m }])),
    sources: {},
    urlsExpireAt: Date.now() + 3600_000,
  });
  const cap = () => new CloudApiError(413, { error: "Storage limit reached (1 GB).", code: "storage_limit_reached" });

  it("a 413 while history keeps removed media → HistoryStorageError; nothing freeable → the API's message", async () => {
    const make = (freeableBytes: number) =>
      new ProjectMedia({
        projectId: PID,
        origin: "cloud",
        cloud: loadedCloud({}),
        createObjectURL: () => "blob:x",
        commitFiles: async () => {
          throw cap();
        },
        historyStats: async () => ({ freeableBytes }),
        refresher: { current: null, subscribe: () => () => {}, stop: () => {}, refreshNow: async () => true } as never,
      });
    const add = (m: ProjectMedia) => m.addFile({ ref: "logo.png", path: "logo.png", blob: new Blob(["x"]), sha256: "a".repeat(64), contentType: "image/png" }).catch((e: unknown) => e);
    const freeable = make(356 * 1024 * 1024);
    const e1 = await add(freeable);
    expect(e1).toBeInstanceOf(HistoryStorageError);
    expect((e1 as Error).message).toBe("History is keeping 356 MB of removed media — Free up history to make room.");
    expect(freeable.historyBlock).toBe(e1);
    const full = make(0);
    const e2 = await add(full);
    expect(e2).not.toBeInstanceOf(HistoryStorageError);
    expect((e2 as Error).message).toBe("Storage limit reached (1 GB).");
    expect(full.historyBlock).toBeNull();
  });

  it("Free up → the failed upload retries (through the page's handler when wired)", async () => {
    let fail = true;
    const commits = vi.fn(async () => {
      if (fail) throw cap();
      return {} as never;
    });
    const m = new ProjectMedia({
      projectId: PID,
      origin: "cloud",
      cloud: loadedCloud({ "recording.mov": { sha256: "b".repeat(64), contentType: "video/quicktime" } }),
      createObjectURL: () => "blob:x",
      commitFiles: commits,
      historyStats: async () => ({ freeableBytes: 0 }),
    });
    m.refresher?.stop();
    const e = await m
      .addFile({ ref: "recording.mov", path: "recording.mov", blob: new Blob(["c"]), sha256: "c".repeat(64), contentType: "video/quicktime" })
      .catch((x: unknown) => x);
    expect((e as Error).message).toBe("History is keeping the old recording — Free up history to replace it.");
    const handler = vi.fn(async () => {
      fail = false;
      m.retryUploads();
      return 1;
    });
    m.freeUpHandler = handler;
    vi.spyOn(m, "refreshNow").mockResolvedValue(true);
    await m.requestFreeUp();
    expect(handler).toHaveBeenCalledTimes(1);
    expect(commits).toHaveBeenCalledTimes(2);
    expect(m.historyBlock).toBeNull();
  });
});
