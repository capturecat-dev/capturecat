import { describe, expect, it } from "vitest";
import {
  ManifestBodySchema,
  checkLogicalPath,
  checkManifest,
  checkProjectDocument,
  distinctObjects,
  inconsistentSizes,
  normalizeProjectId,
  objectKey,
  documentKey,
  parseIfMatchRevision,
  sha256Hex,
  sha256OfStream,
} from "./cloud-projects";

const ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const SHA = "a".repeat(64);

describe("normalizeProjectId", () => {
  it("accepts either case and returns the Swift uuidString form", () => {
    expect(normalizeProjectId(ID.toLowerCase())).toBe(ID);
    expect(normalizeProjectId(ID)).toBe(ID);
  });
  it("refuses anything that is not a UUID", () => {
    for (const bad of ["", "x", `${ID}x`, "../etc", "3F2504E0-4F89-11D3-9A0C", null, undefined]) {
      expect(normalizeProjectId(bad)).toBeNull();
    }
  });
});

describe("checkLogicalPath", () => {
  it("accepts the files a Mac project folder holds", () => {
    for (const p of [
      "recording.mov",
      "cursor.json",
      "keys.json",
      "camera.mov",
      "camera_poster.png",
      "thumbnail.jpg",
      "voiceover-3F2504E0-4F89-11D3-9A0C-0305E82C3301.m4a",
      "watermark-1a2b3c4d.png",
      "external/0123456789ab.jpg",
    ]) {
      expect(checkLogicalPath(p)).toMatchObject({ ok: true });
    }
  });

  it("refuses traversal, absolute, hidden, deep, unknown-type and the document itself", () => {
    for (const p of [
      "../secret.json",
      "a/../b.json",
      "/abs.mov",
      ".hidden.json",
      "dir/.project.json.bak",
      "a\\b.json",
      "a/b/c/d/e.json",
      "evil.svg",
      "page.html",
      "archive.zip",
      "noext",
      "project.json",
      "Project.JSON",
      "",
      "x".repeat(256),
    ]) {
      expect(checkLogicalPath(p).ok).toBe(false);
    }
  });
});

describe("checkManifest", () => {
  const body = (files: Array<Record<string, unknown>>) =>
    ManifestBodySchema.parse({ name: " Demo ", files });

  it("normalizes hashes and content types, trims the name", () => {
    const parsed = body([{ path: "recording.mov", sha256: SHA.toUpperCase(), bytes: 10, contentType: "Video/QuickTime; x=y" }]);
    expect(parsed.name).toBe("Demo");
    expect(parsed.files[0].sha256).toBe(SHA);
    expect(parsed.files[0].contentType).toBe("video/quicktime");
    expect(checkManifest(parsed)).toBeNull();
  });

  it("refuses a content type the extension does not allow", () => {
    const problem = checkManifest(body([{ path: "cursor.json", sha256: SHA, bytes: 1, contentType: "text/html" }]));
    expect(problem?.status).toBe(400);
    expect(problem?.body.code).toBe("invalid_content_type");
  });

  it("refuses duplicate paths case-insensitively", () => {
    const problem = checkManifest(
      body([
        { path: "a.json", sha256: SHA, bytes: 1, contentType: "application/json" },
        { path: "A.json", sha256: SHA, bytes: 1, contentType: "application/json" },
      ]),
    );
    expect(problem?.body.code).toBe("duplicate_path");
  });

  it("applies the per-kind ceiling (413) before any plan math", () => {
    const problem = checkManifest(
      body([{ path: "bg.png", sha256: SHA, bytes: 64 * 1024 * 1024 + 1, contentType: "image/png" }]),
    );
    expect(problem?.status).toBe(413);
    expect(problem?.body.code).toBe("file_too_large");
  });

  it("dedupes objects by hash and flags one hash with two sizes", () => {
    const files = body([
      { path: "a.json", sha256: SHA, bytes: 5, contentType: "application/json" },
      { path: "b.json", sha256: SHA, bytes: 5, contentType: "application/json" },
    ]).files;
    expect(distinctObjects(files)).toEqual([{ sha256: SHA, bytes: 5, contentType: "application/json", paths: ["a.json", "b.json"] }]);
    expect(inconsistentSizes(files)).toBeNull();
    const lying = body([
      { path: "a.json", sha256: SHA, bytes: 5, contentType: "application/json" },
      { path: "b.json", sha256: SHA, bytes: 6, contentType: "application/json" },
    ]).files;
    expect(inconsistentSizes(lying)).toBe("b.json");
  });
});

describe("keys", () => {
  it("scopes every object under owner + project", () => {
    expect(objectKey("u1", ID, SHA)).toBe(`cloud-projects/u1/${ID}/objects/${SHA}`);
    expect(documentKey("u1", ID, 7, "n0nce")).toBe(`cloud-projects/u1/${ID}/doc/7-n0nce.json`);
  });
});

describe("parseIfMatchRevision", () => {
  it("reads quoted, bare and weak forms", () => {
    expect(parseIfMatchRevision('"12"')).toBe(12);
    expect(parseIfMatchRevision("12")).toBe(12);
    expect(parseIfMatchRevision('W/"0"')).toBe(0);
  });
  it("treats missing, * and junk as absent", () => {
    for (const h of [undefined, null, "", "*", '"abc"', "-1", '"1", "2"']) {
      expect(parseIfMatchRevision(h)).toBeNull();
    }
  });
});

describe("checkProjectDocument", () => {
  const doc = (o: Record<string, unknown>) => JSON.stringify(o);
  const valid = { id: ID, name: "Demo", createdAt: 1, duration: 2, settings: {}, zoomRegions: [] };

  it("accepts a document with the keys Project.init(from:) requires", () => {
    const text = doc({ ...valid, futureKey: { anything: true } });
    expect(checkProjectDocument(text, text.length, ID)).toEqual({ ok: true, name: "Demo" });
  });
  it("refuses another project's id (case-insensitive compare)", () => {
    const text = doc({ ...valid, id: "00000000-0000-0000-0000-000000000000" });
    expect(checkProjectDocument(text, text.length, ID)).toMatchObject({ ok: false, body: { code: "id_mismatch" } });
    const lower = doc({ ...valid, id: ID.toLowerCase() });
    expect(checkProjectDocument(lower, lower.length, ID).ok).toBe(true);
  });
  it("names every missing required key", () => {
    const text = doc({ id: ID });
    const r = checkProjectDocument(text, text.length, ID);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.body.error).toContain("name, createdAt, duration, settings, zoomRegions");
  });
  it("refuses non-JSON, arrays and oversize bodies", () => {
    expect(checkProjectDocument("{", 1, ID).ok).toBe(false);
    expect(checkProjectDocument("[]", 2, ID).ok).toBe(false);
    expect(checkProjectDocument("{}", 17 * 1024 * 1024, ID)).toMatchObject({ ok: false, status: 413 });
  });
});

describe("hashing", () => {
  it("stream and one-shot SHA-256 agree", async () => {
    const bytes = new TextEncoder().encode("hello cloud");
    const stream = new Response(bytes).body!;
    expect(await sha256OfStream(stream)).toBe(await sha256Hex(bytes));
    expect(await sha256Hex("")).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  });
});
