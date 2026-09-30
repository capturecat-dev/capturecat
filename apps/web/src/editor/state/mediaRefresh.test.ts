/**
 * Presigned media URL refresh — proves the editor keeps reading media after
 * the ~15-minute presigned GETs expire, without reopening anything:
 *
 *   • MediaUrlRefresher fetches fresh URLs MEDIA_URL_REFRESH_MARGIN_MS before
 *     expiry (fake timers), retries with backoff while offline, and pushes
 *     them through ProjectMedia → the engine binding (setMediaFiles).
 *   • liveFetch: a reader holding an OLD URL follows the refreshed one; a
 *     known-expired URL refreshes before fetching; a 403 (R2's "Request has
 *     expired") refreshes and retries exactly once.
 *   • mediabunny: a demuxer opened on the first URL keeps reading byte
 *     ranges after the server starts refusing that URL (real fixture file).
 *
 * The "server" is a mocked fetch: media URLs carry `?v=<n>` and a version
 * is refused with 403 once it is expired, exactly like R2.
 */
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { ALL_FORMATS, EncodedPacketSink, Input } from "mediabunny";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { API_URL } from "@/lib/api-url";
import { currentUrl, liveFetch, liveUrlEntries, liveUrlSource, LiveUrlTable, resetLiveUrlsForTests } from "../engine/media/liveUrls";
import { MEDIA_URL_REFRESH_MARGIN_MS, type CloudMediaFile, type LoadedCloudProject } from "./cloud";
import { MediaUrlRefresher } from "./mediaRefresh";
import { ProjectMedia, type EngineMediaMap } from "./projectMedia";

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const TTL = 15 * 60_000;
const T0 = Date.parse("2026-09-30T12:00:00Z");

/** A fake R2 + API: versioned presigned URLs that expire. */
class FakeCloud {
  version = 1;
  expiresAt = new Map<number, number>();
  /** Versions the server refuses regardless of time (a skewed clock). */
  revoked = new Set<number>();
  refreshCalls = 0;
  mediaRequests: string[] = [];
  refused = 0;
  offline = false;
  bodies = new Map<string, Uint8Array>();

  constructor(private readonly paths: string[]) {
    this.expiresAt.set(1, Date.now() + TTL);
  }

  url(path: string, v = this.version): string {
    return `https://r2.test/${path}?v=${v}`;
  }

  files(v = this.version): CloudMediaFile[] {
    return this.paths.map((path) => ({
      path,
      sha256: path.padEnd(64, "0").slice(0, 64).replace(/[^0-9a-f]/g, "a"),
      bytes: this.bodies.get(path)?.byteLength ?? 4,
      contentType: path.endsWith(".mov") || path.endsWith(".mp4") ? "video/quicktime" : "application/json",
      source: null,
      url: this.url(path, v),
    }));
  }

  loaded(): LoadedCloudProject {
    const media: Record<string, CloudMediaFile> = {};
    for (const f of this.files()) media[f.path] = f;
    return {
      projectId: ID,
      name: "Demo",
      revision: 3,
      documentSha256: null,
      access: "owner",
      isOwner: true,
      orgId: null,
      updatedAt: new Date().toISOString(),
      document: "{}",
      media,
      sources: {},
      urlsExpireAt: this.expiresAt.get(1)!,
    };
  }

  fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url === `${API_URL}/api/cloud-projects/${encodeURIComponent(ID)}/files`) {
      if (this.offline) throw new TypeError("Failed to fetch");
      this.refreshCalls++;
      this.version++;
      const exp = Date.now() + TTL;
      this.expiresAt.set(this.version, exp);
      return new Response(JSON.stringify({ revision: 3, files: this.files(), urlsExpireAt: new Date(exp).toISOString() }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    const m = /^https:\/\/r2\.test\/(.+)\?v=(\d+)$/.exec(url);
    if (!m) return new Response("not found", { status: 404 });
    this.mediaRequests.push(url);
    const v = Number(m[2]);
    if (this.revoked.has(v) || Date.now() > (this.expiresAt.get(v) ?? 0)) {
      this.refused++;
      return new Response("<Error><Code>AccessDenied</Code><Message>Request has expired</Message></Error>", { status: 403 });
    }
    const body = this.bodies.get(m[1]) ?? new TextEncoder().encode(`{"v":${v}}`);
    const range = new Headers(init?.headers).get("Range");
    const r = range ? /^bytes=(\d+)-(\d*)$/.exec(range) : null;
    if (!r) return new Response(body.slice(), { status: 200, headers: { "Content-Length": String(body.byteLength) } });
    const start = Number(r[1]);
    const end = r[2] ? Math.min(Number(r[2]), body.byteLength - 1) : body.byteLength - 1;
    // Streamed in 64 KiB chunks like a real server, so a reader that has
    // what it wants aborts and later reads need NEW range requests.
    let at = start;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (at > end) return controller.close();
        const next = Math.min(end + 1, at + 64 * 1024);
        controller.enqueue(body.slice(at, next));
        at = next;
      },
    });
    return new Response(stream, {
      status: 206,
      headers: { "Content-Range": `bytes ${start}-${end}/${body.byteLength}`, "Content-Length": String(end - start + 1) },
    });
  };
}

/** The engine side (EngineClient/Engine): a LiveUrlTable fed by ProjectMedia.bindEngine. */
function bindFakeEngine(media: ProjectMedia) {
  const expiredListeners = new Set<() => void>();
  const pushes: EngineMediaMap[] = [];
  const table = new LiveUrlTable({ onExpired: () => expiredListeners.forEach((l) => l()) });
  const doc = { videoURL: `file:///CaptureCat/Projects/${ID}/recording.mov`, cursorDataURL: "cursor.json", settings: {} };
  // As EngineClient.load: the URLs the engine opened with, before any expiry is known.
  table.update(liveUrlEntries({ video: media.mediaUrl(doc.videoURL), files: { "cursor.json": media.mediaUrl("cursor.json")! } }));
  const unbind = media.bindEngine(
    {
      setMediaFiles: (m) => {
        pushes.push(m);
        table.update(liveUrlEntries(m), m.expiresAt);
      },
      onMediaExpired: (l) => {
        expiredListeners.add(l);
        return () => expiredListeners.delete(l);
      },
    },
    { subscribe: () => () => undefined, getState: () => ({ project: null }), documentJSON: () => doc },
  );
  return { table, pushes, unbind, doc };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
  resetLiveUrlsForTests();
});

describe("presigned media URL refresh (fake timers)", () => {
  beforeEach(() => {
    vi.useFakeTimers({ now: T0 });
  });

  it("refreshes MEDIA_URL_REFRESH_MARGIN_MS before expiry and pushes the new URLs into the engine", async () => {
    const cloud = new FakeCloud(["recording.mov", "cursor.json"]);
    vi.stubGlobal("fetch", cloud.fetch);
    const media = new ProjectMedia({ projectId: ID, origin: "cloud", cloud: cloud.loaded() });
    const engine = bindFakeEngine(media);
    const stop = media.start();
    const oldCursor = media.mediaUrl("cursor.json")!;
    expect(oldCursor).toBe(cloud.url("cursor.json", 1));
    expect(engine.pushes).toHaveLength(1); // bind tells the engine the expiry

    await vi.advanceTimersByTimeAsync(TTL - MEDIA_URL_REFRESH_MARGIN_MS - 1_000);
    expect(cloud.refreshCalls).toBe(0);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(cloud.refreshCalls).toBe(1);
    expect(media.mediaUrl("cursor.json")).toBe(cloud.url("cursor.json", 2));
    // The engine got the new map; readers holding the OLD URL now follow the new one.
    expect(engine.pushes.at(-1)!.files["cursor.json"]).toBe(cloud.url("cursor.json", 2));
    expect(engine.pushes.at(-1)!.video).toBe(cloud.url("recording.mov", 2));
    expect(currentUrl(oldCursor)).toBe(cloud.url("cursor.json", 2));

    // Well past the first URLs' expiry, a reader still holding v1 reads fine.
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    const res = await liveFetch(oldCursor);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ v: 2 });
    expect(cloud.refused).toBe(0);

    // …and the schedule keeps going (one refresh per TTL).
    await vi.advanceTimersByTimeAsync(TTL);
    expect(cloud.refreshCalls).toBe(2);
    stop();
    engine.unbind();
  });

  it("a tab that slept past expiry refreshes before its first read (no 403 at all)", async () => {
    const cloud = new FakeCloud(["recording.mov", "cursor.json"]);
    vi.stubGlobal("fetch", cloud.fetch);
    const media = new ProjectMedia({ projectId: ID, origin: "cloud", cloud: cloud.loaded() });
    bindFakeEngine(media); // no start(): the timer never ran (the tab was asleep)
    const oldCursor = media.mediaUrl("cursor.json")!;
    vi.setSystemTime(T0 + TTL + 60_000);

    const res = await liveFetch(oldCursor);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ v: 2 });
    expect(cloud.refreshCalls).toBe(1);
    expect(cloud.refused).toBe(0);
    expect(cloud.mediaRequests).toEqual([cloud.url("cursor.json", 2)]);
  });

  it("a 403 on a URL the client thought was valid refreshes and retries exactly once", async () => {
    const cloud = new FakeCloud(["recording.mov", "cursor.json"]);
    vi.stubGlobal("fetch", cloud.fetch);
    const media = new ProjectMedia({ projectId: ID, origin: "cloud", cloud: cloud.loaded() });
    bindFakeEngine(media);
    cloud.revoked.add(1); // the server's clock disagrees with ours

    const res = await liveFetch(media.mediaUrl("cursor.json")!);
    expect(res.status).toBe(200);
    expect(cloud.refused).toBe(1);
    expect(cloud.refreshCalls).toBe(1);
    expect(cloud.mediaRequests).toEqual([cloud.url("cursor.json", 1), cloud.url("cursor.json", 2)]);

    // Still refused after the refresh → the 403 is returned, no retry loop.
    cloud.revoked.add(2);
    cloud.revoked.add(3);
    const again = await liveFetch(cloud.url("cursor.json", 2));
    expect(again.status).toBe(403);
    expect(cloud.refreshCalls).toBe(2);
    expect(cloud.mediaRequests.slice(2)).toEqual([cloud.url("cursor.json", 2), cloud.url("cursor.json", 3)]);
  });

  it("backs off while offline, then recovers", async () => {
    const cloud = new FakeCloud(["recording.mov"]);
    vi.stubGlobal("fetch", cloud.fetch);
    const refresher = new MediaUrlRefresher(ID, { media: {}, sources: {}, urlsExpireAt: T0 + TTL });
    const seen: number[] = [];
    refresher.subscribe((u) => seen.push(u.urlsExpireAt));
    refresher.start();
    cloud.offline = true;
    await vi.advanceTimersByTimeAsync(TTL - MEDIA_URL_REFRESH_MARGIN_MS + 1);
    expect(seen).toEqual([]);
    cloud.offline = false;
    await vi.advanceTimersByTimeAsync(5_000);
    expect(seen).toHaveLength(1);
    expect(seen[0]).toBeGreaterThan(T0 + TTL);
    refresher.stop();
  });

  it("concurrent expired readers share ONE refresh", async () => {
    const cloud = new FakeCloud(["recording.mov", "cursor.json"]);
    vi.stubGlobal("fetch", cloud.fetch);
    const media = new ProjectMedia({ projectId: ID, origin: "cloud", cloud: cloud.loaded() });
    bindFakeEngine(media);
    cloud.revoked.add(1);
    const url = media.mediaUrl("cursor.json")!;
    const results = await Promise.all([liveFetch(url), liveFetch(url), liveFetch(url)]);
    expect(results.map((r) => r.status)).toEqual([200, 200, 200]);
    expect(cloud.refreshCalls).toBe(1);
  });
});

const FIXTURE = resolve(__dirname, "../../../.fixtures/h264-1080p.mp4");

describe("an open demuxer across a URL expiry (mediabunny UrlSource)", () => {
  it.skipIf(!existsSync(FIXTURE))("keeps reading byte ranges after its first URL is refused — no reopen", async () => {
    const cloud = new FakeCloud(["recording.mov", "cursor.json"]);
    cloud.bodies.set("recording.mov", new Uint8Array(readFileSync(FIXTURE)));
    vi.stubGlobal("fetch", cloud.fetch);
    const media = new ProjectMedia({ projectId: ID, origin: "cloud", cloud: cloud.loaded() });
    bindFakeEngine(media);

    // As DemuxedVideo.open: a small cache so late reads must hit the network again.
    const input = new Input({ formats: ALL_FORMATS, source: liveUrlSource(cloud.url("recording.mov", 1), { maxCacheSize: 256 * 1024 }) });
    const track = (await input.getPrimaryVideoTrack())!;
    const sink = new EncodedPacketSink(track);
    const first = await sink.getFirstPacket();
    expect(first?.data.byteLength).toBeGreaterThan(0);
    const before = cloud.mediaRequests.length;

    cloud.revoked.add(1); // 15 minutes later: R2 refuses v1
    const duration = await track.computeDuration();
    const late = await sink.getKeyPacket(duration / 2);
    expect(late?.data.byteLength).toBeGreaterThan(0);
    expect(cloud.refreshCalls).toBe(1);
    expect(cloud.refused).toBeGreaterThanOrEqual(1);
    // Every read after the refusal went to the refreshed URL, through the SAME Input.
    const after = cloud.mediaRequests.slice(before).filter((u) => !cloud.revoked.has(Number(u.split("v=")[1])));
    expect(after.length).toBeGreaterThan(0);
    expect(after.every((u) => u === cloud.url("recording.mov", 2))).toBe(true);
    input.dispose();
  });
});
