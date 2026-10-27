import { describe, expect, it } from "vitest";
import {
  ANNOTATION_LIMITS,
  annotationFromStored,
  checkReplyParent,
  cleanLabel,
  commentAuthorName,
  isCommentId,
  parseCommentAnnotation,
  sessionAvatar,
  toPublicComment,
} from "./comments";

const pen = { kind: "pen", color: "#FF0000", size: 2, points: [[0.1, 0.2], [0.3, 0.4]] };
const arrow = { kind: "arrow", color: "#00ff00", size: 1, from: [0.1, 0.1], to: [0.5, 0.5] };
const text = { kind: "text", color: "#ffffff", size: 3, at: [0.2, 0.8], text: "Fix this" };

function ok(raw: unknown) {
  const r = parseCommentAnnotation(raw);
  if (!r.ok) throw new Error(r.error);
  return r;
}
function bad(raw: unknown) {
  const r = parseCommentAnnotation(raw);
  if (r.ok) throw new Error("expected a rejection");
  return r.error;
}

describe("parseCommentAnnotation — what counts as no drawing", () => {
  it("absent, null and an empty shape list are all 'no drawing'", () => {
    for (const raw of [undefined, null, { v: 1, shapes: [] }]) {
      const r = ok(raw);
      expect(r.annotation).toBeNull();
      expect(r.json).toBeNull();
    }
  });
});

describe("parseCommentAnnotation — canonical form", () => {
  it("accepts every kind and rebuilds it canonically", () => {
    const shapes = [
      pen,
      { ...pen, kind: "highlight" },
      arrow,
      { ...arrow, kind: "rect" },
      { ...arrow, kind: "ellipse" },
      text,
    ];
    const r = ok({ v: 1, shapes });
    expect(r.annotation!.shapes.map((s) => s.kind)).toEqual([
      "pen", "highlight", "arrow", "rect", "ellipse", "text",
    ]);
    // Colours lower-cased; stored JSON is exactly the canonical object.
    expect(r.annotation!.shapes[0].color).toBe("#ff0000");
    expect(JSON.parse(r.json!)).toEqual(r.annotation);
  });

  it("drops unknown keys instead of storing them", () => {
    const r = ok({ v: 1, extra: "x", shapes: [{ ...pen, onclick: "alert(1)", style: "x" }] });
    expect(Object.keys(r.annotation!)).toEqual(["v", "shapes"]);
    expect(Object.keys(r.annotation!.shapes[0]).sort()).toEqual(["color", "kind", "points", "size"]);
  });

  it("clamps coordinates to [0, 1] and rounds to 4 decimals", () => {
    const r = ok({
      v: 1,
      shapes: [{ ...pen, points: [[-0.5, 1.7], [0.123456789, 0.98765]] }],
    });
    const shape = r.annotation!.shapes[0] as { points: [number, number][] };
    expect(shape.points).toEqual([[0, 1], [0.1235, 0.9877]]);
  });

  it("cleans text labels: controls and bidi overrides stripped, whitespace collapsed", () => {
    const r = ok({ v: 1, shapes: [{ ...text, text: "  a\n\tb‮c\u0000  " }] });
    expect((r.annotation!.shapes[0] as { text: string }).text).toBe("a b c");
  });

  it("a single-point pen stroke (a dot) is valid", () => {
    ok({ v: 1, shapes: [{ ...pen, points: [[0.5, 0.5]] }] });
  });
});

describe("parseCommentAnnotation — strict rejections", () => {
  it("refuses non-objects, wrong versions and missing shapes", () => {
    expect(bad("x")).toContain("object");
    expect(bad([pen])).toContain("object");
    expect(bad({ v: 2, shapes: [pen] })).toContain("v must be 1");
    expect(bad({ shapes: [pen] })).toContain("v must be 1");
    expect(bad({ v: 1, shapes: "pen" })).toContain("array");
  });

  it("refuses kinds off the allowlist", () => {
    expect(bad({ v: 1, shapes: [{ ...pen, kind: "image" }] })).toContain("kind");
    expect(bad({ v: 1, shapes: [{ ...pen, kind: undefined }] })).toContain("kind");
  });

  it("refuses colours that are not #rrggbb", () => {
    for (const color of ["red", "#fff", "#ff000080", "rgb(0,0,0)", "#gg0000", "", 0xff0000]) {
      expect(bad({ v: 1, shapes: [{ ...pen, color }] })).toContain("color");
    }
  });

  it("refuses sizes other than 1, 2 or 3", () => {
    for (const size of [0, 4, 1.5, "2", null]) {
      expect(bad({ v: 1, shapes: [{ ...pen, size }] })).toContain("size");
    }
  });

  it("refuses malformed points", () => {
    for (const points of [[], [[0.1]], [[0.1, 0.2, 0.3]], [["0.1", 0.2]], [[NaN, 0.2]], [[Infinity, 0]], "x"]) {
      expect(bad({ v: 1, shapes: [{ ...pen, points }] })).toContain("points");
    }
    expect(bad({ v: 1, shapes: [{ ...arrow, to: undefined }] })).toContain("from and .to");
    expect(bad({ v: 1, shapes: [{ ...text, at: [0.1] }] })).toContain("at");
  });

  it("refuses empty or over-long text labels", () => {
    expect(bad({ v: 1, shapes: [{ ...text, text: " \n " }] })).toContain("empty");
    expect(bad({ v: 1, shapes: [{ ...text, text: 5 }] })).toContain("string");
    const long = "x".repeat(ANNOTATION_LIMITS.maxTextLength + 1);
    expect(bad({ v: 1, shapes: [{ ...text, text: long }] })).toContain("longer than");
    ok({ v: 1, shapes: [{ ...text, text: "x".repeat(ANNOTATION_LIMITS.maxTextLength) }] });
    // Counted in characters, not UTF-16 units: 140 emoji is fine.
    ok({ v: 1, shapes: [{ ...text, text: "🐱".repeat(ANNOTATION_LIMITS.maxTextLength) }] });
  });

  it("caps the number of shapes", () => {
    const many = Array.from({ length: ANNOTATION_LIMITS.maxShapes + 1 }, () => arrow);
    expect(bad({ v: 1, shapes: many })).toContain("shapes");
    ok({ v: 1, shapes: many.slice(1) });
  });

  it("caps points per stroke and in total", () => {
    const stroke = (n: number) => ({ ...pen, points: Array.from({ length: n }, (_, i) => [i / n, 0.5]) });
    expect(bad({ v: 1, shapes: [stroke(ANNOTATION_LIMITS.maxPointsPerStroke + 1)] })).toContain("points");
    // Three max-length strokes = 6000 points > 5000 total.
    const three = [1, 2, 3].map(() => stroke(ANNOTATION_LIMITS.maxPointsPerStroke));
    expect(bad({ v: 1, shapes: three })).toMatch(/more than 5000 points|too large/);
  });

  it("caps the serialized size at 32 KB", () => {
    // 1 900 points with ugly coordinates ≈ 30+ KB per stroke; two blow it.
    const ugly = (n: number) => Array.from({ length: n }, (_, i) => [0.1234 + i * 1e-7, 0.5678]);
    const r = parseCommentAnnotation({ v: 1, shapes: [{ ...pen, points: ugly(1900) }, { ...pen, points: ugly(1900) }] });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.error).toContain("too large");
  });
});

describe("annotationFromStored", () => {
  it("round-trips a stored annotation and ignores garbage rows", () => {
    const { json, annotation } = ok({ v: 1, shapes: [pen, text] });
    expect(annotationFromStored(json)).toEqual(annotation);
    expect(annotationFromStored(null)).toBeNull();
    expect(annotationFromStored("{not json")).toBeNull();
    expect(annotationFromStored(JSON.stringify({ v: 9, shapes: [] }))).toBeNull();
  });
});

describe("threading — one level deep, same video", () => {
  it("accepts a top-level parent on the same video", () => {
    expect(checkReplyParent({ videoId: "vid1", parentId: null }, "vid1")).toEqual({ ok: true });
  });

  it("refuses a missing parent", () => {
    const r = checkReplyParent(null, "vid1");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.status).toBe(404);
  });

  it("refuses a parent on another video exactly like a missing one", () => {
    const missing = checkReplyParent(null, "vid1");
    const elsewhere = checkReplyParent({ videoId: "vid2", parentId: null }, "vid1");
    expect(elsewhere).toEqual(missing);
  });

  it("refuses replying to a reply (no deeper nesting)", () => {
    const r = checkReplyParent({ videoId: "vid1", parentId: "abc123def0" }, "vid1");
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.status).toBe(400);
  });

  it("comment ids are generateId() shaped", () => {
    expect(isCommentId("abc123def0")).toBe(true);
    for (const v of ["", "ABC123DEF0", "abc", "a/b/c/d/e/f", "x".repeat(40), 12, null]) {
      expect(isCommentId(v)).toBe(false);
    }
  });
});

describe("identity", () => {
  it("session avatar: https only, bounded", () => {
    expect(sessionAvatar("https://lh3.googleusercontent.com/a/x=s96-c")).toBe(
      "https://lh3.googleusercontent.com/a/x=s96-c"
    );
    expect(sessionAvatar("http://example.com/a.png")).toBeNull();
    expect(sessionAvatar("javascript:alert(1)")).toBeNull();
    expect(sessionAvatar("data:image/png;base64,xx")).toBeNull();
    expect(sessionAvatar("https://x.test/" + "a".repeat(1100))).toBeNull();
    expect(sessionAvatar(null)).toBeNull();
  });

  it("author name: session name wins, then the typed name, then Anonymous", () => {
    expect(commentAuthorName("Mike G", "Somebody")).toBe("Mike G");
    expect(commentAuthorName(null, "  Ann  ")).toBe("Ann");
    expect(commentAuthorName("", "")).toBe("Anonymous");
    expect(commentAuthorName(undefined, 42)).toBe("Anonymous");
    expect(commentAuthorName(null, "x".repeat(80))).toHaveLength(40);
    expect(cleanLabel("a\u0000b")).toBe("a b");
  });

  it("public shape: author uid reduced to isOwner, never serialized", () => {
    const base = {
      commentId: "c1",
      authorName: "Mike",
      body: "hi",
      videoTime: 3,
      createdAt: "2026-10-27T00:00:00.000Z",
    };
    const owner = toPublicComment({ ...base, authorUid: "u-owner" }, "u-owner");
    expect(owner.isOwner).toBe(true);
    expect(JSON.stringify(owner)).not.toContain("u-owner");
    expect(toPublicComment({ ...base, authorUid: "u-other" }, "u-owner").isOwner).toBe(false);
    // A pre-0031 row: every new field absent.
    expect(toPublicComment(base, "u-owner")).toEqual({
      ...base,
      parentId: null,
      authorImage: null,
      isOwner: false,
      annotation: null,
    });
  });
});
