import { describe, expect, it } from "vitest";
import {
  MAX_SIGNABLE_UPLOAD_BYTES,
  ReplaceCompleteBodySchema,
  ReplaceVideoBodySchema,
  UploadVideoBodySchema,
} from "./upload-schemas";
import { parseValue } from "./validate";

const good = { fileName: "demo.mp4", fileSizeBytes: 1024 };

function fail(raw: unknown) {
  const r = parseValue(raw, UploadVideoBodySchema);
  if (r.ok) throw new Error("expected failure");
  return r.error;
}
function pass(raw: unknown) {
  const r = parseValue(raw, UploadVideoBodySchema);
  if (!r.ok) throw new Error(r.error);
  return r.data;
}

describe("UploadVideoBodySchema — scalars are strict", () => {
  it("fills defaults for a minimal body", () => {
    const d = pass(good);
    expect(d.contentType).toBe("video/mp4");
    expect(d.durationSeconds).toBe(0);
    expect(d.commentsEnabled).toBe(false);
    expect(d.annotations).toBeNull();
    expect(d.projectId).toBeNull();
    expect(d.transcript).toBeUndefined();
    expect(d.aiTitle).toBeNull();
    expect(d.aiChapters).toEqual([]);
  });

  it("fileName: required, trimmed, bounded to 200", () => {
    expect(fail({ fileSizeBytes: 1 })).toContain("fileName");
    expect(fail({ ...good, fileName: "   " })).toContain("fileName");
    expect(pass({ ...good, fileName: " x".padEnd(300, "y") }).fileName.length).toBe(200);
  });

  it("fileSizeBytes: positive integer, at most 5 GB signable", () => {
    expect(fail({ ...good, fileSizeBytes: 0 })).toContain("fileSizeBytes");
    expect(fail({ ...good, fileSizeBytes: 1.5 })).toContain("fileSizeBytes");
    expect(fail({ ...good, fileSizeBytes: "1024" })).toContain("fileSizeBytes");
    expect(fail({ ...good, fileSizeBytes: MAX_SIGNABLE_UPLOAD_BYTES + 1 })).toContain("5 GB");
    expect(pass({ ...good, fileSizeBytes: MAX_SIGNABLE_UPLOAD_BYTES }).fileSizeBytes).toBe(MAX_SIGNABLE_UPLOAD_BYTES);
  });

  it("contentType: empty means mp4, anything off-list is rejected", () => {
    expect(pass({ ...good, contentType: "" }).contentType).toBe("video/mp4");
    expect(pass({ ...good, contentType: "video/webm" }).contentType).toBe("video/webm");
    expect(fail({ ...good, contentType: "application/x-sh" })).toBe("contentType: Invalid content type");
  });

  it("durationSeconds: non-negative finite number", () => {
    expect(fail({ ...good, durationSeconds: -1 })).toContain("durationSeconds");
    expect(fail({ ...good, durationSeconds: Number.POSITIVE_INFINITY })).toContain("durationSeconds");
    expect(fail({ ...good, durationSeconds: "12" })).toContain("durationSeconds");
  });

  it("projectId: a UUID is upper-cased, anything else is dropped to null", () => {
    expect(pass({ ...good, projectId: "6f1c2a3b-4d5e-4f60-8a71-9b8c7d6e5f40" }).projectId).toBe(
      "6F1C2A3B-4D5E-4F60-8A71-9B8C7D6E5F40",
    );
    expect(pass({ ...good, projectId: "not-a-uuid" }).projectId).toBeNull();
    expect(pass({ ...good, projectId: 42 }).projectId).toBeNull();
  });

  it("ai text: trimmed, bounded, blank → null", () => {
    const d = pass({ ...good, aiTitle: "  Hello  ", aiSummary: "s".repeat(1000) });
    expect(d.aiTitle).toBe("Hello");
    expect(d.aiSummary?.length).toBe(600);
    expect(pass({ ...good, aiTitle: "   " }).aiTitle).toBeNull();
    expect(fail({ ...good, aiTitle: 7 })).toContain("aiTitle");
  });

  it("a non-JSON-object body is rejected", () => {
    expect(fail("nope")).toBeTruthy();
    expect(fail(null)).toBeTruthy();
  });
});

describe("markers — lenient per item, never stored verbatim", () => {
  it("drops malformed markers, clamps and rounds the rest", () => {
    const d = pass({
      ...good,
      annotations: [
        { start: 1.23456, end: 2.5, label: "  Intro  ", autoPause: true, pauseDuration: 99, extra: "dropped" },
        { start: 5, end: 4 }, // end < start
        { start: "1", end: 2 }, // wrong type
        "garbage",
        { start: -3, end: -1 }, // clamps to 0..0
        { start: 1, end: 2, autoPause: true }, // default pause
      ],
    });
    expect(JSON.parse(d.annotations!)).toEqual([
      { start: 1.235, end: 2.5, label: "Intro", autoPause: true, pauseDuration: 30 },
      { start: 0, end: 0 },
      { start: 1, end: 2, autoPause: true, pauseDuration: 2 },
    ]);
  });

  it("nothing surviving → null, and caps at 100", () => {
    expect(pass({ ...good, annotations: ["x", 1] }).annotations).toBeNull();
    const many = Array.from({ length: 150 }, (_, i) => ({ start: i, end: i + 1 }));
    expect(JSON.parse(pass({ ...good, annotations: many }).annotations!).length).toBe(100);
  });

  it("a non-array annotations field is a 400", () => {
    expect(fail({ ...good, annotations: { start: 1, end: 2 } })).toContain("annotations");
  });
});

describe("transcript — lenient per segment and per word", () => {
  it("drops bad segments and zero-duration words, bounds text", () => {
    const d = pass({
      ...good,
      transcript: [
        { start: 0, end: 1.004, text: "  hi  ", words: [{ start: 0, end: 0, text: "hi" }, { start: 0, end: 0.5, text: " hi " }] },
        { start: 2, end: 1, text: "backwards" },
        { start: 3, end: 4, text: "   " },
        { start: 5, end: 6, text: "t".repeat(600) },
      ],
    });
    expect(d.transcript).toEqual([
      { start: 0, end: 1, text: "hi", words: [{ start: 0, end: 0.5, text: "hi" }] },
      { start: 5, end: 6, text: "t".repeat(500) },
    ]);
  });
});

describe("chapters", () => {
  it("keeps well-formed chapters, clamps start, bounds label, caps at 12", () => {
    const d = pass({
      ...good,
      aiChapters: [{ start: -1, label: "x".repeat(100) }, { start: 1 }, ...Array.from({ length: 20 }, (_, i) => ({ start: i, label: `c${i}` }))],
    });
    expect(d.aiChapters[0]).toEqual({ start: 0, label: "x".repeat(60) });
    expect(d.aiChapters.length).toBe(12);
  });
});

describe("replace bodies", () => {
  it("replace: size required, duration optional (absent = keep current)", () => {
    const r = parseValue({ fileSizeBytes: 10 }, ReplaceVideoBodySchema);
    expect(r.ok && r.data.durationSeconds).toBeUndefined();
    expect(parseValue({}, ReplaceVideoBodySchema).ok).toBe(false);
  });

  it("replace-complete: everything optional; annotations absent vs empty are distinct", () => {
    const empty = parseValue({}, ReplaceCompleteBodySchema);
    expect(empty.ok && empty.data.annotations).toBeUndefined();
    const cleared = parseValue({ annotations: [] }, ReplaceCompleteBodySchema);
    expect(cleared.ok && cleared.data.annotations).toBeNull();
  });
});
