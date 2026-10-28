/**
 * Requested visibility on a share (WebMCP share_project — the Mac's
 * `ShareJobCenter.runUpload(visibility:)`): the link must never be MORE
 * visible than approved at any instant. Narrowing (private, unlisted) lands
 * before a byte goes up; widening a replaced link waits until the new cut is
 * live; a share without a requested privacy (the user's own Share button)
 * touches no visibility route at all. Mocked fetch + fake XHR, one ordered
 * log — nothing leaves the process.
 */
import { describe, expect, it } from "vitest";

import { runShareUpload, type ShareUploadInput, type ShareVisibility, type XhrLike } from "./share";

const VIDEO = "abc1234567";

function harness(opts: { failPatch?: "privacy" | "settings" } = {}) {
  const log: string[] = [];
  const fetchImpl = (async (url: string | URL, init?: RequestInit) => {
    const path = new URL(String(url)).pathname.replace(/^\/api/, "");
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    log.push(`${method} ${path}${method === "PATCH" ? ` ${JSON.stringify(body)}` : ""}`);
    const ok = (json: unknown) => new Response(JSON.stringify(json), { status: 200 });
    if (method === "PATCH") {
      if (opts.failPatch && path.endsWith(`/${opts.failPatch}`)) return new Response("{}", { status: 500 });
      return ok({ videoId: VIDEO });
    }
    if (path === "/upload/video") return ok({ videoId: VIDEO, uploadUrl: "https://r2.example/put" });
    if (path === `/upload/video/${VIDEO}/replace`) return ok({ version: 2, uploadUrl: "https://r2.example/put2" });
    if (path === `/upload/video/${VIDEO}/complete`) return ok({ url: `https://capturecat.so/share/${VIDEO}` });
    if (path === `/upload/video/${VIDEO}/replace/2/complete`) return ok({ url: `https://capturecat.so/share/${VIDEO}` });
    if (path === "/upload/jobs") return ok({ job: { jobId: "j1" } });
    return ok({});
  }) as typeof fetch;
  const xhr = (): XhrLike => {
    const x: XhrLike & { status: number } = {
      status: 0,
      responseText: "",
      upload: { onprogress: null },
      onload: null,
      onerror: null,
      onabort: null,
      open: () => undefined,
      setRequestHeader: () => undefined,
      abort: () => undefined,
      send: () => {
        log.push("PUT bytes");
        queueMicrotask(() => {
          x.status = 200;
          x.onload?.();
        });
      },
    };
    return x;
  };
  return { log, fetch: fetchImpl, xhr };
}

function input(privacy: ShareVisibility | undefined, replace: boolean): ShareUploadInput {
  return {
    file: new Blob([new Uint8Array(64)], { type: "video/mp4" }),
    fileName: "Demo.mp4",
    durationSeconds: 4,
    commentsEnabled: false,
    annotations: [],
    transcript: [],
    projectId: "5B6C2F5E-1B7D-4E6A-9C3F-2D4B6A8C0E1F",
    projectName: "Demo",
    replaceVideoId: replace ? VIDEO : null,
    ...(privacy ? { privacy } : {}),
  };
}

const patches = (log: string[]) => log.filter((l) => l.startsWith("PATCH"));
const before = (log: string[], a: string, b: string) => log.findIndex((l) => l.startsWith(a)) < log.indexOf(b);

describe("runShareUpload — requested visibility", () => {
  it("no privacy (the Share button) touches no visibility route", async () => {
    for (const replace of [false, true]) {
      const h = harness();
      await runShareUpload(input(undefined, replace), () => undefined, { fetch: h.fetch, xhr: h.xhr });
      expect(patches(h.log)).toEqual([]);
    }
  });

  it("private: owner-only BEFORE the bytes go up, fresh or replaced", async () => {
    for (const replace of [false, true]) {
      const h = harness();
      await runShareUpload(input("private", replace), () => undefined, { fetch: h.fetch, xhr: h.xhr });
      expect(patches(h.log)).toEqual([`PATCH /video/${VIDEO}/privacy {"isPrivate":true}`]);
      expect(before(h.log, "PATCH", "PUT bytes")).toBe(true);
    }
  });

  it("unlisted: unlisted before upload; a replaced link is opened to the link only once live", async () => {
    const fresh = harness();
    await runShareUpload(input("unlisted", false), () => undefined, { fetch: fresh.fetch, xhr: fresh.xhr });
    expect(patches(fresh.log)).toEqual([`PATCH /video/${VIDEO}/settings {"profileVisible":false}`]);
    expect(before(fresh.log, "PATCH", "PUT bytes")).toBe(true);

    const replaced = harness();
    await runShareUpload(input("unlisted", true), () => undefined, { fetch: replaced.fetch, xhr: replaced.xhr });
    expect(patches(replaced.log)).toEqual([
      `PATCH /video/${VIDEO}/settings {"profileVisible":false}`,
      `PATCH /video/${VIDEO}/privacy {"isPrivate":false}`,
    ]);
    const widen = replaced.log.indexOf(`PATCH /video/${VIDEO}/privacy {"isPrivate":false}`);
    expect(widen).toBeGreaterThan(replaced.log.indexOf(`POST /upload/video/${VIDEO}/replace/2/complete`));
  });

  it("public: a fresh link needs nothing; a replaced one widens only after the new cut is live", async () => {
    const fresh = harness();
    await runShareUpload(input("public", false), () => undefined, { fetch: fresh.fetch, xhr: fresh.xhr });
    expect(patches(fresh.log)).toEqual([]);

    const replaced = harness();
    await runShareUpload(input("public", true), () => undefined, { fetch: replaced.fetch, xhr: replaced.xhr });
    const confirm = replaced.log.indexOf(`POST /upload/video/${VIDEO}/replace/2/complete`);
    expect(patches(replaced.log)).toEqual([
      `PATCH /video/${VIDEO}/privacy {"isPrivate":false}`,
      `PATCH /video/${VIDEO}/settings {"profileVisible":true}`,
    ]);
    expect(replaced.log.findIndex((l) => l.startsWith("PATCH"))).toBeGreaterThan(confirm);
  });

  it("a failed narrowing step stops the share before any bytes go up", async () => {
    const h = harness({ failPatch: "privacy" });
    const states: string[] = [];
    await expect(
      runShareUpload(input("private", false), (s) => states.push(s.phase), { fetch: h.fetch, xhr: h.xhr }),
    ).rejects.toThrow();
    expect(h.log).not.toContain("PUT bytes");
    expect(states.at(-1)).toBe("failed");
  });

  it("a failed widening step still finishes — less visible, with a warning", async () => {
    const h = harness({ failPatch: "settings" });
    const result = await runShareUpload(input("public", true), () => undefined, { fetch: h.fetch, xhr: h.xhr });
    expect(result.url).toBe(`https://capturecat.so/share/${VIDEO}`);
    expect(result.warning).toMatch(/could not be widened to public/);
  });
});
