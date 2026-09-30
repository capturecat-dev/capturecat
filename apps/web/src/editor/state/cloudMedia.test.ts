import { afterEach, describe, expect, it, vi } from "vitest";

import { sha256Blob } from "../record/sha256";
import type { CloudMediaFile, LoadedCloudProject, UploadTarget } from "./cloud";
import { addCloudProjectFile, manifestWithFile } from "./cloudMedia";
import type { EditorController } from "./controller";
import type { LoadedEditorProject } from "./projectSource";
import type { EditorStore } from "./store";
import { UploadGate } from "./voiceOver";
import { createVoiceOverMedia, registerTabMedia } from "./voiceOverMedia";

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const HEX = (c: string) => c.repeat(64);

function file(path: string, sha: string, contentType = "video/quicktime", source: string | null = null): CloudMediaFile {
  return { path, sha256: sha, bytes: 10, contentType, source, url: `https://r2.test/${path}` };
}

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

const EXISTING = [file("recording.mov", HEX("a")), file("cursor.json", HEX("b"), "application/json"), file("external/0123456789ab.jpg", HEX("c"), "image/jpeg", "/Users/me/Wall.jpg")];

afterEach(() => vi.unstubAllGlobals());

describe("manifestWithFile", () => {
  it("keeps every committed file (with its source) and adds the new one", () => {
    const media = Object.fromEntries(EXISTING.map((f) => [f.path, f]));
    const out = manifestWithFile({ media }, { path: "voiceover-X.m4a", sha256: HEX("d"), bytes: 5, contentType: "audio/mp4" });
    expect(out).toEqual([
      { path: "recording.mov", sha256: HEX("a"), bytes: 10, contentType: "video/quicktime" },
      { path: "cursor.json", sha256: HEX("b"), bytes: 10, contentType: "application/json" },
      { path: "external/0123456789ab.jpg", sha256: HEX("c"), bytes: 10, contentType: "image/jpeg", source: "/Users/me/Wall.jpg" },
      { path: "voiceover-X.m4a", sha256: HEX("d"), bytes: 5, contentType: "audio/mp4" },
    ]);
  });
  it("replaces a same-named file (case-insensitively)", () => {
    const media = { "VoiceOver-X.m4a": file("VoiceOver-X.m4a", HEX("e"), "audio/mp4") };
    const out = manifestWithFile({ media }, { path: "voiceover-x.m4a", sha256: HEX("d"), bytes: 5, contentType: "audio/mp4" });
    expect(out.map((f) => f.path)).toEqual(["voiceover-x.m4a"]);
  });
});

describe("addCloudProjectFile (stage → PUT → finalize)", () => {
  it("stages the full manifest, uploads only the new file, finalizes, refreshes", async () => {
    const blob = new Blob([new Uint8Array([1, 2, 3, 4, 5])], { type: "audio/mp4" });
    const sha = await sha256Blob(blob);
    const calls: Array<{ method: string; url: string; body?: unknown }> = [];
    let finalizeCount = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string, init: RequestInit) => {
        const method = init.method ?? "GET";
        calls.push({ method, url, body: init.body ? JSON.parse(String(init.body)) : undefined });
        if (url.endsWith("/files")) {
          const files = finalizeCount > 0 ? [...EXISTING, { ...file("voiceover-X.m4a", sha, "audio/mp4"), bytes: 5 }] : EXISTING;
          return json(200, { revision: 7, files, urlsExpireAt: "2030-01-01T00:00:00Z" });
        }
        if (method === "PUT" && url.endsWith(ID)) {
          const target: UploadTarget = { sha256: sha, bytes: 5, contentType: "audio/mp4", paths: ["voiceover-X.m4a"], method: "PUT", uploadUrl: "https://r2.test/put", headers: {} };
          return json(200, { projectId: ID, revision: 7, documentSha256: null, missing: [target], presentCount: 3, expiresIn: 900 });
        }
        if (url.endsWith("/finalize")) {
          finalizeCount++;
          return finalizeCount === 1 ? new Response(null, { status: 202 }) : json(200, { revision: 7, fileCount: 4, totalBytes: 35 });
        }
        return json(404, {});
      }),
    );
    const put = vi.fn(async (_t: UploadTarget, b: Blob, onBytes: (n: number) => void) => {
      expect(b).toBe(blob);
      onBytes(5);
    });
    const progress: number[] = [];
    const fresh = await addCloudProjectFile(ID, { name: "Demo", path: "voiceover-X.m4a", file: blob, contentType: "audio/mp4", put, onProgress: (f) => progress.push(f) });

    const stage = calls.find((c) => c.method === "PUT")!;
    expect(stage.body).toEqual({
      name: "Demo",
      files: [
        { path: "recording.mov", sha256: HEX("a"), bytes: 10, contentType: "video/quicktime" },
        { path: "cursor.json", sha256: HEX("b"), bytes: 10, contentType: "application/json" },
        { path: "external/0123456789ab.jpg", sha256: HEX("c"), bytes: 10, contentType: "image/jpeg", source: "/Users/me/Wall.jpg" },
        { path: "voiceover-X.m4a", sha256: sha, bytes: 5, contentType: "audio/mp4" },
      ],
    });
    expect(put).toHaveBeenCalledTimes(1);
    expect(progress).toEqual([1]);
    expect(finalizeCount).toBe(2); // "verifying" → called again
    expect(fresh.media["voiceover-X.m4a"].url).toBe("https://r2.test/voiceover-X.m4a");
    expect(calls.map((c) => `${c.method} ${c.url.split("/cloud-projects")[1]}`)).toEqual([
      `GET /${ID}/files`,
      `PUT /${ID}`,
      `POST /${ID}/finalize`,
      `POST /${ID}/finalize`,
      `GET /${ID}/files`,
    ]);
  });

  it("refuses to commit when the cloud lacks a file this page never had", async () => {
    const blob = new Blob([new Uint8Array([9])]);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string, init: RequestInit) => {
        if (url.endsWith("/files")) return json(200, { revision: 1, files: EXISTING, urlsExpireAt: "2030-01-01T00:00:00Z" });
        if (init.method === "PUT") {
          const lost: UploadTarget = { sha256: HEX("a"), bytes: 10, contentType: "video/quicktime", paths: ["recording.mov"], method: "PUT", uploadUrl: "u", headers: {} };
          return json(200, { projectId: ID, revision: 1, documentSha256: null, missing: [lost], presentCount: 0, expiresIn: 900 });
        }
        throw new Error(`unexpected ${init.method} ${url}`);
      }),
    );
    await expect(addCloudProjectFile(ID, { name: "Demo", path: "voiceover-X.m4a", file: blob, contentType: "audio/mp4", put: async () => undefined })).rejects.toThrow(
      /missing recording\.mov/,
    );
  });
});

describe("createVoiceOverMedia", () => {
  function loadedCloud(access: "owner" | "member" = "owner"): LoadedEditorProject {
    const cloud = { projectId: ID, name: "Demo", access, media: {}, sources: {}, urlsExpireAt: 0 } as unknown as LoadedCloudProject;
    return { id: ID, origin: "cloud", text: "{}", document: {}, revision: 3, mediaUrl: (ref) => (ref === "recording.mov" ? "https://r2/rec" : undefined), cloud };
  }
  const store = { getState: () => ({ project: { name: "Renamed" } }) } as unknown as EditorStore;

  it("registers the take with the engine and the page's resolver", () => {
    const added: Record<string, string> = {};
    const controller = { client: { addMediaFiles: (f: Record<string, string>) => Object.assign(added, f) } } as unknown as EditorController;
    const loaded = loadedCloud();
    const media = createVoiceOverMedia({ loaded, store, controller, uploads: new UploadGate() });
    media.register("voiceover-X.m4a", "blob:x");
    expect(added).toEqual({ "voiceover-X.m4a": "blob:x" });
    expect(loaded.mediaUrl("voiceover-X.m4a")).toBe("blob:x");
    expect(loaded.mediaUrl("recording.mov")).toBe("https://r2/rec");
    registerTabMedia(loaded, "voiceover-Y.m4a", "blob:y");
    expect(loaded.mediaUrl("voiceover-X.m4a")).toBe("blob:x");
    expect(loaded.mediaUrl("voiceover-Y.m4a")).toBe("blob:y");
  });

  it("cloud: uploads under the project's current name, retries transient failures, holds the save gate", async () => {
    const loaded = loadedCloud();
    const uploads = new UploadGate();
    let attempts = 0;
    const upload = vi.fn(async (_id: string, o: { name: string }) => {
      expect(o.name).toBe("Renamed");
      if (++attempts === 1) throw new TypeError("Failed to fetch");
      return { revision: 3, media: { "voiceover-X.m4a": file("voiceover-X.m4a", HEX("d"), "audio/mp4") }, sources: {}, urlsExpireAt: 99 };
    });
    const media = createVoiceOverMedia({ loaded, store, controller: {} as EditorController, uploads, upload: upload as never, sleep: async () => undefined });
    const take = { file: new File([new Uint8Array(2)], "voiceover-X.m4a"), fileName: "voiceover-X.m4a", contentType: "audio/mp4" as const, codec: "aac" as const, duration: 1 };
    const done = media.persist(take);
    expect(uploads.busy).toBe(true);
    await done;
    await uploads.idle();
    expect(attempts).toBe(2);
    expect(loaded.cloud!.media["voiceover-X.m4a"]).toBeTruthy();
    expect(loaded.cloud!.urlsExpireAt).toBe(99);
  });

  it("cloud: a permanent failure rejects with a user-facing message", async () => {
    const { CloudApiError } = await import("./cloud");
    const media = createVoiceOverMedia({
      loaded: loadedCloud(),
      store,
      controller: {} as EditorController,
      uploads: new UploadGate(),
      upload: (async () => {
        throw new CloudApiError(413, { error: "Storage limit reached", code: "storage_limit_reached" });
      }) as never,
      sleep: async () => undefined,
    });
    const take = { file: new File([new Uint8Array(2)], "v.m4a"), fileName: "v.m4a", contentType: "audio/mp4" as const, codec: "aac" as const, duration: 1 };
    await expect(media.persist(take)).rejects.toThrow("The voice over couldn't be uploaded to the cloud. Storage limit reached");
  });

  it("a team member cannot add media (owner-only stage/finalize)", () => {
    const media = createVoiceOverMedia({ loaded: loadedCloud("member"), store, controller: {} as EditorController, uploads: new UploadGate() });
    expect(media.blocker!()).toBe("Only the project's owner can add a voice over.");
  });

  it("local (dev) projects keep the file in the tab", async () => {
    const loaded: LoadedEditorProject = { id: ID, origin: "local", text: "{}", document: {}, revision: null, mediaUrl: () => undefined };
    const upload = vi.fn();
    const media = createVoiceOverMedia({ loaded, store, controller: {} as EditorController, uploads: new UploadGate(), upload: upload as never });
    await media.persist({ file: new File([], "v.m4a"), fileName: "v.m4a", contentType: "audio/mp4", codec: "aac", duration: 1 });
    expect(upload).not.toHaveBeenCalled();
    expect(media.blocker!()).toBeNull();
  });
});
