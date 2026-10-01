import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CloudApiError,
  deleteProjectVersion,
  freeUpHistory,
  getProjectVersion,
  historyHeaders,
  listProjectVersions,
  loadCloudProject,
  mediaUrlsNeedRefresh,
  nameProjectVersion,
  resolveMediaRef,
  restoreProjectVersion,
  saveCloudProject,
  webClientId,
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
      headVersionId: null,
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

describe("project history wire (docs/project-history.md §6)", () => {
  it("sends the X-CC-* save headers, dropping malformed ones", async () => {
    const fetchMock = vi.fn(async () => jsonResponse(200, { revision: 6, documentSha256: "cd", updatedAt: "t", version: { id: "v9", seq: 9, extended: true } }));
    vi.stubGlobal("fetch", fetchMock);
    const r = await saveCloudProject(ID, "{}", 5, {
      history: { client: "web", clientId: "1b4e28ba-2fa1-11d2-883f-0016d3cca427", source: "mixed", change: "eyJ2IjoxfQ", checkpoint: "merge", mergedFrom: 5 },
    });
    expect(r).toMatchObject({ ok: true, revision: 6, version: { id: "v9", seq: 9, extended: true } });
    const headers = (fetchMock.mock.calls[0] as unknown as [string, RequestInit])[1].headers as Record<string, string>;
    expect(headers).toMatchObject({
      "If-Match": '"5"',
      "X-CC-Client": "web",
      "X-CC-Client-Id": "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
      "X-CC-Source": "mixed",
      "X-CC-Change": "eyJ2IjoxfQ",
      "X-CC-Checkpoint": "merge",
      "X-CC-Merged-From": "5",
    });
    expect(historyHeaders({ clientId: "has space", change: "x".repeat(8193), mergedFrom: -1 })).toEqual({});
    expect(historyHeaders(undefined)).toEqual({});
  });

  it("webClientId: one opaque random id per browser, kept in storage", () => {
    const mem = new Map<string, string>();
    const storage = { getItem: (k: string) => mem.get(k) ?? null, setItem: (k: string, v: string) => void mem.set(k, v) };
    const a = webClientId(storage);
    expect(a).toMatch(/^[A-Za-z0-9_-]{1,64}$/);
    expect(webClientId(storage)).toBe(a);
    const blocked = { getItem: () => { throw new Error("blocked"); }, setItem: () => { throw new Error("blocked"); } };
    const s1 = webClientId(blocked);
    expect(s1).toMatch(/^[A-Za-z0-9_-]{1,64}$/);
    expect(webClientId(blocked)).toBe(s1); // stable for the page session
  });

  /** The API's `V` (docs/project-history.md §6.1), exactly. */
  const V = (o: Record<string, unknown>) => ({
    id: "v1", seq: 1, kind: "edit", label: null, namedBy: null, namedAt: null, actor: { uid: "u1", name: "Ana" },
    client: "web", source: "human", firstRevision: 1, revision: 1, documentBytes: 120, documentSha256: "ab".repeat(32),
    change: null, restoredFrom: null, mergedFromRevision: null, openedAt: "2026-09-30T10:00:00Z", updatedAt: "2026-09-30T10:00:00Z", isHead: false,
    ...o,
  });

  it("lists versions (§6.1 shape): V objects, access, retention, pinned + freeable bytes, nextBefore; limit 1–200", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse(200, {
        projectId: ID,
        revision: 7,
        headVersionId: "v2",
        access: "member",
        versions: [
          V({ id: "v2", seq: 2, revision: 7, firstRevision: 5, kind: "merge", label: "Final", namedBy: { uid: "u2", name: "Ben" }, namedAt: "t", source: "agent", change: { v: 1, items: {}, settings: { background: ["backgroundPadding"] }, fields: [] }, mergedFromRevision: 6, isHead: true }),
          V({ id: "v1", kind: "upload", actor: { uid: "u2", name: null }, client: "mac" }),
        ],
        nextBefore: 1,
        retention: { maxHistoryDays: 30, maxNamedVersions: 25, namedCount: 1 },
        pinnedMediaBytes: 1234,
        freeableBytes: 1000,
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const list = await listProjectVersions(ID, { before: "5", limit: 500 });
    expect(String((fetchMock.mock.calls[0] as unknown as [string])[0])).toMatch(/\/versions\?before=5&limit=200$/);
    expect(list.versions.map((v) => [v.id, v.kind, v.actorName, v.clientKind, v.source, v.isHead])).toEqual([
      ["v2", "merge", "Ana", "web", "agent", true],
      ["v1", "upload", null, "mac", "human", false],
    ]);
    expect(list.versions[0]).toMatchObject({ label: "Final", namedBy: "Ben", firstRevision: 5, mergedFromRevision: 6, docBytes: 120 });
    expect(list).toMatchObject({ headVersionId: "v2", access: "member", revision: 7, retention: { days: 30, maxNamed: 25, namedCount: 1 }, pinnedMediaBytes: 1234, freeableBytes: 1000, nextBefore: "1" });
  });

  it("gets a version (document, files, missingPaths); restore sends If-Match + client headers; 409s and 410s", async () => {
    const doc = '{ "id" : "X", "name":"old" }';
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse(200, { projectId: ID, version: V({}), document: doc, files: [mediaFile("recording.mov")], missingPaths: ["logo.png"], urlsExpireAt: "2026-09-29T00:15:00.000Z" })),
    );
    const d = await getProjectVersion(ID, "v1");
    expect(d.document).toBe(doc);
    expect(d.missingPaths).toEqual(["logo.png"]);
    expect(d.media["recording.mov"].url).toBe("https://r2.test/recording.mov");
    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(410, { error: "gone", code: "version_document_missing" })));
    expect(await getProjectVersion(ID, "v1").catch((e: CloudApiError) => [e.status, e.code])).toEqual([410, "version_document_missing"]);

    const fetchMock = vi.fn(async () => jsonResponse(200, { projectId: ID, revision: 12, documentSha256: "cd", updatedAt: "u", restoredFrom: "v1", version: { id: "v5", seq: 5, extended: false }, fileCount: 3 }));
    vi.stubGlobal("fetch", fetchMock);
    expect(await restoreProjectVersion(ID, "v1", 11, { history: { client: "web", clientId: "abc", source: "human" } })).toEqual({
      ok: true, revision: 12, documentSha256: "cd", updatedAt: "u", restoredFrom: "v1", version: { id: "v5", seq: 5, extended: false }, fileCount: 3,
    });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toMatch(/\/versions\/v1\/restore$/);
    expect(init.method).toBe("POST");
    expect(init.headers).toMatchObject({ "If-Match": '"11"', "X-CC-Client": "web", "X-CC-Client-Id": "abc", "X-CC-Source": "human" });

    vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(409, { code: "revision_conflict", revision: 13, updatedAt: "w", headVersionId: "v9", document: "{}" })));
    expect(await restoreProjectVersion(ID, "v1", 11)).toMatchObject({ ok: false, conflict: true, revision: 13, document: "{}", headVersionId: "v9" });
    for (const [status, code] of [[409, "files_changed"], [409, "version_media_missing"], [428, "revision_required"], [410, "version_document_missing"]] as const) {
      vi.stubGlobal("fetch", vi.fn(async () => jsonResponse(status, { error: "x", code })));
      expect(await restoreProjectVersion(ID, "v1", 11).catch((e: CloudApiError) => [e.status, e.code])).toEqual([status, code]);
    }
  });

  it("frees up history (POST …/history/free-up)", async () => {
    const fetchMock = vi.fn(async () => jsonResponse(200, { projectId: ID, deletedVersions: ["v1", "v2"], releasedBytes: 500, pinnedMediaBytes: 100, freeableBytes: 0 }));
    vi.stubGlobal("fetch", fetchMock);
    expect(await freeUpHistory(ID)).toEqual({ deletedVersions: ["v1", "v2"], releasedBytes: 500, pinnedMediaBytes: 100, freeableBytes: 0 });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toMatch(new RegExp(`/cloud-projects/${ID}/history/free-up$`));
    expect(init.method).toBe("POST");
  });

  it("names (PATCH) and deletes versions", async () => {
    const fetchMock = vi.fn(async (_u: string, init?: RequestInit) =>
      init?.method === "PATCH" ? jsonResponse(200, { projectId: ID, version: V({ label: "Pitch cut" }) }) : jsonResponse(200, { projectId: ID, deleted: true, versionId: "v1", releasedBytes: 42 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    expect((await nameProjectVersion(ID, "v1", "Pitch cut"))?.label).toBe("Pitch cut");
    expect((fetchMock.mock.calls[0] as unknown as [string, RequestInit])[1].body).toBe('{"label":"Pitch cut"}');
    expect(await deleteProjectVersion(ID, "v1")).toEqual({ releasedBytes: 42 });
    expect((fetchMock.mock.calls[1] as unknown as [string, RequestInit])[1].method).toBe("DELETE");
  });
});
