import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CloudApiError,
  loadCloudProject,
  mediaUrlsNeedRefresh,
  resolveMediaRef,
  saveCloudProject,
  type CloudMediaFile,
} from "./cloud";

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";

function mediaFile(path: string, source: string | null = null): CloudMediaFile {
  return { path, sha256: "0".repeat(64), bytes: 1, contentType: "video/quicktime", source, url: `https://r2.test/${path}` };
}

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });
}

afterEach(() => vi.unstubAllGlobals());

describe("resolveMediaRef", () => {
  const urls = {
    media: {
      "recording.mov": mediaFile("recording.mov"),
      "voiceover-1.m4a": mediaFile("voiceover-1.m4a"),
      "external/0123456789ab.jpg": mediaFile("external/0123456789ab.jpg", "/Users/me/Pictures/My Wall.jpg"),
    },
    sources: { "/Users/me/Pictures/My Wall.jpg": "external/0123456789ab.jpg" },
  };

  it("maps a Mac file:// URL to its project-relative file", () => {
    const ref = `file:///Users/me/Library/Application%20Support/CaptureCat/Projects/${ID}/recording.mov`;
    expect(resolveMediaRef(urls, ref)?.path).toBe("recording.mov");
  });
  it("maps a URL from ANOTHER Mac's folder the same way", () => {
    const ref = `file:///Users/someone-else/Library/Application%20Support/CaptureCat/Projects/${ID}/recording.mov`;
    expect(resolveMediaRef(urls, ref)?.path).toBe("recording.mov");
  });
  it("uses the recorded source for an absolute path outside the folder", () => {
    expect(resolveMediaRef(urls, "/Users/me/Pictures/My Wall.jpg")?.path).toBe("external/0123456789ab.jpg");
    expect(resolveMediaRef(urls, "file:///Users/me/Pictures/My%20Wall.jpg")?.path).toBe("external/0123456789ab.jpg");
  });
  it("follows the Mac's conversion of browser-undecodable images (HEIC → PNG)", () => {
    const converted = {
      media: {
        "logo.heic.png": mediaFile("logo.heic.png", "logo.heic"),
        "external/aaaabbbbcccc.png": mediaFile("external/aaaabbbbcccc.png", "/Users/me/Pictures/Sonoma.heic"),
      },
      sources: { "logo.heic": "logo.heic.png", "/Users/me/Pictures/Sonoma.heic": "external/aaaabbbbcccc.png" },
    };
    // In-folder reference, spelled as a bare name, a Mac URL, or another Mac's URL.
    expect(resolveMediaRef(converted, "logo.heic")?.path).toBe("logo.heic.png");
    const mine = `file:///Users/me/Library/Application%20Support/CaptureCat/Projects/${ID}/logo.heic`;
    const theirs = `file:///Users/you/Library/Application%20Support/CaptureCat/Projects/${ID}/logo.heic`;
    expect(resolveMediaRef(converted, mine)?.path).toBe("logo.heic.png");
    expect(resolveMediaRef(converted, theirs)?.path).toBe("logo.heic.png");
    // External wallpaper: the exact backgroundImagePath string.
    expect(resolveMediaRef(converted, "/Users/me/Pictures/Sonoma.heic")?.path).toBe("external/aaaabbbbcccc.png");
  });
  it("accepts bare relative names and says undefined for anything not uploaded", () => {
    expect(resolveMediaRef(urls, "voiceover-1.m4a")?.path).toBe("voiceover-1.m4a");
    expect(resolveMediaRef(urls, "missing.png")).toBeUndefined();
    expect(resolveMediaRef(urls, null)).toBeUndefined();
  });
});

describe("mediaUrlsNeedRefresh", () => {
  it("refreshes inside the margin and never trusts a bad timestamp", () => {
    expect(mediaUrlsNeedRefresh({ urlsExpireAt: 1_000_000 }, 1_000_000 - 200_000)).toBe(false);
    expect(mediaUrlsNeedRefresh({ urlsExpireAt: 1_000_000 }, 1_000_000 - 60_000)).toBe(true);
    expect(mediaUrlsNeedRefresh({ urlsExpireAt: Number.NaN })).toBe(true);
  });
});

describe("loadCloudProject", () => {
  it("returns the document text untouched and indexes media by path and source", async () => {
    const document = '{\n  "id" : "X",  "unknownKey" : [1, 2.50]\n}';
    const fetchMock = vi.fn(async () =>
      jsonResponse(200, {
        projectId: ID,
        name: "Demo",
        revision: 4,
        documentSha256: "ab",
        access: "owner",
        isOwner: true,
        orgId: null,
        updatedAt: "2026-09-29T00:00:00.000Z",
        document,
        files: [mediaFile("recording.mov"), mediaFile("external/a.png", "/abs/a.png")],
        urlsExpireAt: "2026-09-29T00:15:00.000Z",
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const loaded = await loadCloudProject(ID);
    expect(loaded.document).toBe(document);
    expect(loaded.revision).toBe(4);
    expect(Object.keys(loaded.media)).toEqual(["recording.mov", "external/a.png"]);
    expect(loaded.sources).toEqual({ "/abs/a.png": "external/a.png" });
    expect(loaded.urlsExpireAt).toBe(Date.parse("2026-09-29T00:15:00.000Z"));
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toMatch(new RegExp(`/api/cloud-projects/${ID}$`));
    expect(init.credentials).toBe("include");
  });
});

describe("saveCloudProject", () => {
  it("sends the text verbatim with If-Match and returns the new revision", async () => {
    const fetchMock = vi.fn(async () => jsonResponse(200, { revision: 5, documentSha256: "cd", updatedAt: "t" }));
    vi.stubGlobal("fetch", fetchMock);
    const text = '{"id":"X"}';
    expect(await saveCloudProject(ID, text, 4)).toEqual({ ok: true, revision: 5, documentSha256: "cd", updatedAt: "t" });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toMatch(/\/project$/);
    expect(init.method).toBe("PUT");
    expect(init.body).toBe(text);
    expect((init.headers as Record<string, string>)["If-Match"]).toBe('"4"');
    expect(init.credentials).toBe("include");
  });

  it("turns a revision conflict into a result carrying the cloud's copy", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse(409, { code: "revision_conflict", revision: 7, documentSha256: "ef", updatedAt: "u", document: "{}" }),
      ),
    );
    expect(await saveCloudProject(ID, "{}", 4)).toEqual({
      ok: false,
      conflict: true,
      revision: 7,
      documentSha256: "ef",
      updatedAt: "u",
      document: "{}",
    });
  });

  it("throws CloudApiError with the API's code for everything else", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(413, { error: "Storage limit reached", code: "storage_limit_reached" })));
    const err = await saveCloudProject(ID, "{}", 1).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(CloudApiError);
    expect((err as CloudApiError).status).toBe(413);
    expect((err as CloudApiError).code).toBe("storage_limit_reached");
    expect((err as CloudApiError).message).toBe("Storage limit reached");
  });
});
