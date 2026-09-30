/**
 * The share client against the API contract: every request body is parsed
 * by the API's OWN zod schemas (apps/api/src/lib/upload-schemas.ts), and the
 * call sequence is the Mac's ShareJobCenter.runUpload (fresh share, replace
 * in place, replace → fresh fallback, failures + the job mirror). Network is
 * a mocked fetch + fake XHR — nothing leaves the process.
 */
import { describe, expect, it } from "vitest";
import {
  ReplaceCompleteBodySchema,
  ReplaceVideoBodySchema,
  UploadVideoBodySchema,
} from "../../../../api/src/lib/upload-schemas";
import { newProject } from "../core/model/defaults";
import type { Annotation, Project, SubtitleSegment } from "../core/model/types";
import { runShareUpload, transcriptForShare, uploadFile, type ShareState, type XhrLike } from "./share";
import { ShareCenter } from "./shareCenter";

interface Call {
  method: string;
  path: string;
  body: unknown;
  credentials?: RequestCredentials;
}

function api(routes: Record<string, (body: unknown) => { status: number; json: unknown }>) {
  const calls: Call[] = [];
  const fetchImpl = (async (url: string | URL, init?: RequestInit) => {
    const u = new URL(String(url));
    const path = u.pathname.replace(/^\/api/, "");
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ method: init?.method ?? "GET", path, body, credentials: init?.credentials });
    const key = Object.keys(routes).find((k) => new RegExp(`^${k}$`).test(path));
    if (!key) return new Response(JSON.stringify({ error: "no route" }), { status: 404 });
    const r = routes[key](body);
    return new Response(JSON.stringify(r.json), { status: r.status, headers: { "Content-Type": "application/json" } });
  }) as typeof fetch;
  return { calls, fetch: fetchImpl };
}

class FakeXhr implements XhrLike {
  static last: FakeXhr | null = null;
  method = "";
  url = "";
  headers: Record<string, string> = {};
  sent: Blob | null = null;
  status = 0;
  responseText = "";
  upload: XhrLike["upload"] = { onprogress: null };
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onabort: (() => void) | null = null;
  constructor(private readonly respond: number) {
    FakeXhr.last = this;
  }
  open(method: string, url: string) {
    this.method = method;
    this.url = url;
  }
  setRequestHeader(k: string, v: string) {
    this.headers[k] = v;
  }
  send(body: Blob) {
    this.sent = body;
    queueMicrotask(() => {
      const total = body.size;
      for (const f of [0.25, 0.26, 0.5, 1]) this.upload.onprogress?.({ loaded: Math.round(total * f), total, lengthComputable: true });
      this.status = this.respond;
      this.onload?.();
    });
  }
  abort() {
    this.onabort?.();
  }
}

const PROJECT_ID = "5B6C2F5E-1B7D-4E6A-9C3F-2D4B6A8C0E1F";

function fixtureProject(): Project {
  const base = newProject({ id: PROJECT_ID, name: "Demo", videoURL: "file:///x/recording.mov", duration: 12 });
  const note = { ...(base.annotations[0] ?? {}), id: "a1", type: "text", startTime: 2, endTime: 3, text: "Look here", uppercase: false } as unknown as Annotation;
  const sub: SubtitleSegment = {
    id: "s1",
    startTime: 1,
    endTime: 2.5,
    text: " Hello world ",
    words: [
      { id: "w1", startTime: 1, endTime: 1.5, text: "Hello" },
      { id: "w2", startTime: 1.6, endTime: 2.4, text: "world" },
    ],
  } as unknown as SubtitleSegment;
  return { ...base, trimStart: 0.5, trimEnd: 11, annotations: [note], subtitles: [sub] };
}

const file = new Blob([new Uint8Array(10000)], { type: "video/mp4" });

function input(project: Project, replaceVideoId: string | null = null) {
  return {
    file,
    fileName: "Demo.mp4",
    durationSeconds: project.duration,
    commentsEnabled: true,
    annotations: [{ start: 1.5, end: 2.5, label: "Look here" }],
    transcript: transcriptForShare(project),
    projectId: project.id,
    projectName: project.name,
    replaceVideoId,
  };
}

const okRoutes = {
  "/upload/video": () => ({ status: 200, json: { videoId: "vid123", uploadUrl: "https://r2.example/put?sig=1", r2Key: "videos/vid123.mp4" } }),
  "/upload/jobs": () => ({ status: 200, json: { job: { jobId: "job9" } } }),
  "/upload/jobs/job9/progress": () => ({ status: 200, json: { job: { jobId: "job9" } } }),
  "/upload/jobs/job9/complete": () => ({ status: 200, json: { job: { jobId: "job9" } } }),
  "/upload/jobs/job9/fail": () => ({ status: 200, json: { job: { jobId: "job9" } } }),
  "/upload/video/vid123/complete": () => ({ status: 200, json: { videoId: "vid123", url: "https://capturecat.so/share/vid123", status: "ready" } }),
};

describe("share client — API contract", () => {
  it("fresh share: the Mac's sequence, bodies valid per the API's zod schemas, cookie auth", async () => {
    const project = fixtureProject();
    const { calls, fetch } = api(okRoutes);
    const states: ShareState[] = [];
    let clock = 0;
    const result = await runShareUpload(input(project), (s) => states.push(s), {
      fetch,
      xhr: () => new FakeXhr(200),
      now: () => (clock += 100),
    });
    expect(result).toEqual({ url: "https://capturecat.so/share/vid123", videoId: "vid123" });
    expect(calls.map((c) => `${c.method} ${c.path}`)).toEqual([
      "POST /upload/video",
      "POST /upload/jobs",
      "POST /upload/jobs/job9/progress", // 25 %
      "POST /upload/jobs/job9/progress", // 50 % (26 % is throttled: < 5 % and < 2 s)
      "POST /upload/jobs/job9/progress", // 100 %
      "POST /upload/jobs/job9/progress", // completing
      "POST /upload/video/vid123/complete",
      "POST /upload/jobs/job9/complete",
    ]);
    expect(calls.every((c) => c.credentials === "include")).toBe(true);

    const presign = UploadVideoBodySchema.safeParse(calls[0].body);
    expect(presign.success, JSON.stringify(presign.error?.issues)).toBe(true);
    const parsed = presign.data!;
    expect(parsed.contentType).toBe("video/mp4");
    expect(parsed.fileSizeBytes).toBe(10000);
    expect(parsed.durationSeconds).toBe(12);
    expect(parsed.commentsEnabled).toBe(true);
    expect(parsed.projectId).toBe(PROJECT_ID);
    expect(JSON.parse(parsed.annotations!)).toEqual([{ start: 1.5, end: 2.5, label: "Look here" }]);
    // Transcript: output seconds (trim 0.5 → 1 s source = 0.5 s output), trimmed text, words.
    expect(parsed.transcript).toEqual([
      {
        start: 0.5,
        end: 2,
        text: "Hello world",
        words: [
          { start: 0.5, end: 1, text: "Hello" },
          { start: 1.1, end: 1.9, text: "world" },
        ],
      },
    ]);
    expect(calls[1].body).toEqual({ videoId: "vid123", projectId: PROJECT_ID, projectName: "Demo", fileName: "Demo.mp4", fileSizeBytes: 10000 });
    expect(calls[5].body).toEqual({ progress: 1, completing: true });
    expect(calls[7].body).toEqual({ shareUrl: "https://capturecat.so/share/vid123" });

    // PUT straight to the presigned URL with the signed content type.
    expect(FakeXhr.last!.method).toBe("PUT");
    expect(FakeXhr.last!.url).toBe("https://r2.example/put?sig=1");
    expect(FakeXhr.last!.headers["Content-Type"]).toBe("video/mp4");
    expect(FakeXhr.last!.sent).toBe(file);

    // UI states: uploading (with progress) → completing → done.
    expect(states[0]).toEqual({ phase: "uploading", progress: 0 });
    expect(states.filter((s) => s.phase === "uploading").map((s) => (s as { progress: number }).progress)).toEqual([0, 0.25, 0.26, 0.5, 1, 1]);
    expect(states.at(-2)).toEqual({ phase: "completing" });
    expect(states.at(-1)).toEqual({ phase: "done", url: "https://capturecat.so/share/vid123" });
  });

  it("minimal body: no comments / markers / transcript keys when empty", async () => {
    const project = { ...fixtureProject(), subtitles: [] };
    const { calls, fetch } = api(okRoutes);
    await runShareUpload({ ...input(project), commentsEnabled: false, annotations: [], transcript: [] }, () => {}, { fetch, xhr: () => new FakeXhr(200) });
    expect(Object.keys(calls[0].body as object).sort()).toEqual(["contentType", "durationSeconds", "fileName", "fileSizeBytes", "projectId"]);
    expect(UploadVideoBodySchema.safeParse(calls[0].body).success).toBe(true);
  });

  it("re-share replaces the video in place (same link), metadata on the replace completion", async () => {
    const project = fixtureProject();
    const { calls, fetch } = api({
      ...okRoutes,
      "/upload/video/old42/replace": () => ({ status: 200, json: { videoId: "old42", version: 3, uploadUrl: "https://r2.example/v3", r2Key: "videos/old42/v3.mp4" } }),
      "/upload/jobs": () => ({ status: 200, json: { job: { jobId: "job9" } } }),
      "/upload/video/old42/replace/3/complete": () => ({ status: 200, json: { videoId: "old42", version: 3, url: "https://capturecat.so/share/old42", status: "ready" } }),
    });
    const result = await runShareUpload(input(project, "old42"), () => {}, { fetch, xhr: () => new FakeXhr(200) });
    expect(result).toEqual({ url: "https://capturecat.so/share/old42", videoId: "old42" });
    expect(calls[0].path).toBe("/upload/video/old42/replace");
    expect(ReplaceVideoBodySchema.safeParse(calls[0].body).success).toBe(true);
    expect(calls.some((c) => c.path === "/upload/video")).toBe(false);
    const done = calls.find((c) => c.path === "/upload/video/old42/replace/3/complete")!;
    const parsed = ReplaceCompleteBodySchema.safeParse(done.body);
    expect(parsed.success).toBe(true);
    expect(JSON.parse(parsed.data!.annotations!)).toEqual([{ start: 1.5, end: 2.5, label: "Look here" }]);
    expect(parsed.data!.transcript!.length).toBe(1);
  });

  it("a replace the server refuses falls back to a fresh link", async () => {
    const project = fixtureProject();
    const { calls, fetch } = api({
      ...okRoutes,
      "/upload/video/gone/replace": () => ({ status: 404, json: { error: "Video not found" } }),
    });
    const result = await runShareUpload(input(project, "gone"), () => {}, { fetch, xhr: () => new FakeXhr(200) });
    expect(result.videoId).toBe("vid123");
    expect(calls.slice(0, 2).map((c) => c.path)).toEqual(["/upload/video/gone/replace", "/upload/video"]);
  });

  it("signed out → the Mac's message; nothing else is called", async () => {
    const { calls, fetch } = api({ "/upload/video": () => ({ status: 401, json: { error: "Invalid or expired session" } }) });
    const states: ShareState[] = [];
    await expect(runShareUpload(input(fixtureProject()), (s) => states.push(s), { fetch, xhr: () => new FakeXhr(200) })).rejects.toThrow(
      "You must be signed in to share videos.",
    );
    expect(calls.length).toBe(1);
    expect(states.at(-1)).toEqual({ phase: "failed", message: "You must be signed in to share videos." });
  });

  it("plan limit errors surface the API's message; a failed PUT fails the mirrored job", async () => {
    const limit = api({ "/upload/video": () => ({ status: 413, json: { error: "This video is larger than your plan allows (2 GB)." } }) });
    await expect(runShareUpload(input(fixtureProject()), () => {}, { fetch: limit.fetch, xhr: () => new FakeXhr(200) })).rejects.toThrow(
      "This video is larger than your plan allows (2 GB).",
    );

    const { calls, fetch } = api(okRoutes);
    const states: ShareState[] = [];
    await expect(runShareUpload(input(fixtureProject()), (s) => states.push(s), { fetch, xhr: () => new FakeXhr(403) })).rejects.toThrow(
      "Upload failed (HTTP 403)",
    );
    expect(calls.at(-1)).toMatchObject({ path: "/upload/jobs/job9/fail", body: { error: "Upload failed (HTTP 403)" } });
    expect(calls.some((c) => c.path.endsWith("/complete"))).toBe(false);
    expect(states.at(-1)).toEqual({ phase: "failed", message: "Upload failed (HTTP 403)" });
  });

  it("the job mirror is never fatal", async () => {
    const { fetch } = api({ ...okRoutes, "/upload/jobs": () => ({ status: 500, json: { error: "DO down" } }) });
    const result = await runShareUpload(input(fixtureProject()), () => {}, { fetch, xhr: () => new FakeXhr(200) });
    expect(result.url).toBe("https://capturecat.so/share/vid123");
  });

  it("uploadFile reports byte progress and rejects on abort", async () => {
    const seen: number[] = [];
    await uploadFile("https://r2.example/x", file, (p) => seen.push(p), { xhr: () => new FakeXhr(200) });
    expect(seen).toEqual([0.25, 0.26, 0.5, 1, 1]);
    const ac = new AbortController();
    const p = uploadFile("https://r2.example/x", file, () => {}, {
      signal: ac.signal,
      xhr: () => {
        const x = new FakeXhr(200);
        x.send = () => {};
        return x;
      },
    });
    ac.abort();
    await expect(p).rejects.toMatchObject({ name: "AbortError" });
  });
});

describe("ShareCenter", () => {
  function center(project: Project, uploads: { replaceVideoId: string | null; commentsEnabled: boolean }[], fail = false) {
    const store = new Map<string, string>();
    const copied: string[] = [];
    let exports = 0;
    const c = new ShareCenter({
      project: () => project,
      exportMovie: async (onProgress) => {
        exports++;
        onProgress(0.5);
        onProgress(1);
        return { blob: file, fileName: "Demo.mp4" };
      },
      copy: async (t) => void copied.push(t),
      storage: { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => void store.set(k, v) },
      upload: async (inp, onState) => {
        uploads.push({ replaceVideoId: inp.replaceVideoId, commentsEnabled: inp.commentsEnabled });
        onState({ phase: "uploading", progress: 0.5 });
        if (fail) {
          onState({ phase: "failed", message: "Upload failed (HTTP 500)" });
          throw new Error("Upload failed (HTTP 500)");
        }
        onState({ phase: "completing" });
        onState({ phase: "done", url: "https://capturecat.so/share/v1" });
        return { url: "https://capturecat.so/share/v1", videoId: "v1" };
      },
    });
    return { c, copied, exports: () => exports };
  }

  it("top-bar Share: exporting → uploading → done; Copy; a re-share replaces in place", async () => {
    const uploads: { replaceVideoId: string | null; commentsEnabled: boolean }[] = [];
    const { c, copied, exports } = center(fixtureProject(), uploads);
    const phases: string[] = [];
    c.subscribe(() => phases.push(c.getState().phase));
    await c.shareProject();
    expect(exports()).toBe(1);
    expect(phases).toEqual(["exporting", "exporting", "exporting", "uploading", "completing", "done"]);
    expect(await c.copyLink()).toBe(true);
    expect(copied).toEqual(["https://capturecat.so/share/v1"]);
    expect(c.sharedURL()).toBe("https://capturecat.so/share/v1");
    await c.shareExported(file, "Demo.mp4", { commentsEnabled: true });
    expect(uploads).toEqual([
      { replaceVideoId: null, commentsEnabled: false }, // the card share: comments off
      { replaceVideoId: "v1", commentsEnabled: true },
    ]);
  });

  it("failure → Retry re-uploads the same file without re-exporting", async () => {
    const uploads: { replaceVideoId: string | null; commentsEnabled: boolean }[] = [];
    const { c, exports } = center(fixtureProject(), uploads, true);
    await c.shareProject();
    expect(c.getState()).toEqual({ phase: "failed", message: "Upload failed (HTTP 500)" });
    await c.retry();
    expect(exports()).toBe(1);
    expect(uploads.length).toBe(2);
  });
});
