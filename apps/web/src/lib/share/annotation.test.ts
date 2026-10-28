import { describe, expect, it } from "vitest";
import {
  ANNOTATION_LIMITS,
  canonicalShape,
  containRect,
  drawAnnotation,
  fontSize,
  readAnnotation,
  roundCoord,
  serializeAnnotation,
  simplifyStroke,
  strokeWidth,
  toBox,
  toFrame,
  wrapLabel,
  type AnnotationShape,
  type Ctx2D,
  type Point,
} from "./annotation";

describe("geometry — normalized to the video frame, not the box", () => {
  it("letterboxes a 4:3 video inside a 16:9 box", () => {
    expect(containRect(1600, 900, 640, 480)).toEqual({ x: 200, y: 0, w: 1200, h: 900 });
  });

  it("pillarboxes nothing when aspect ratios match, and falls back to the box without metadata", () => {
    expect(containRect(1280, 720, 1920, 1080)).toEqual({ x: 0, y: 0, w: 1280, h: 720 });
    expect(containRect(800, 450)).toEqual({ x: 0, y: 0, w: 800, h: 450 });
    expect(containRect(800, 450, 0, 0)).toEqual({ x: 0, y: 0, w: 800, h: 450 });
  });

  it("box pixels ↔ frame coordinates round-trip, clamped to the frame", () => {
    const rect = containRect(1600, 900, 640, 480);
    expect(toFrame(200, 0, rect)).toEqual([0, 0]);
    expect(toFrame(1400, 900, rect)).toEqual([1, 1]);
    expect(toFrame(800, 450, rect)).toEqual([0.5, 0.5]);
    // In the letterbox bars → pinned to the frame edge.
    expect(toFrame(50, 450, rect)).toEqual([0, 0.5]);
    expect(toBox([0.25, 0.5], rect)).toEqual([500, 450]);
  });

  it("the same normalized point lands on the same spot of the picture at any size", () => {
    const p: Point = [0.3, 0.7];
    const small = containRect(320, 180, 1920, 1080);
    const large = containRect(2560, 1440, 1920, 1080);
    const [sx, sy] = toBox(p, small);
    const [lx, ly] = toBox(p, large);
    expect(sx / small.w).toBeCloseTo(lx / large.w, 10);
    expect(sy / small.h).toBeCloseTo(ly / large.h, 10);
  });

  it("stroke widths and fonts scale with the frame (resolution independent)", () => {
    const a = containRect(640, 360);
    const b = containRect(1920, 1080);
    expect(strokeWidth("pen", 2, b) / strokeWidth("pen", 2, a)).toBeCloseTo(3, 10);
    expect(fontSize(3, b) / fontSize(3, a)).toBeCloseTo(3, 10);
    expect(strokeWidth("highlight", 2, a)).toBeGreaterThan(strokeWidth("pen", 3, a));
    expect(strokeWidth("pen", 1, a)).toBeLessThan(strokeWidth("pen", 3, a));
  });
});

describe("serialization", () => {
  it("rounds coordinates to 4 decimals and clamps to [0, 1]", () => {
    expect(roundCoord(0.123456)).toBe(0.1235);
    expect(roundCoord(-3)).toBe(0);
    expect(roundCoord(1.2)).toBe(1);
  });

  it("produces the exact v1 wire shape with colours lower-cased", () => {
    const { annotation, json, tooLarge } = serializeAnnotation([
      { kind: "pen", color: "#FBBF24", size: 2, points: [[0.1, 0.1], [0.2, 0.2], [0.3, 0.1]] },
      { kind: "arrow", color: "#EF4444", size: 1, from: [0.1, 0.1], to: [0.5, 0.5] },
      { kind: "text", color: "#ffffff", size: 3, at: [0.2, 0.2], text: "  Look\nhere " },
    ]);
    expect(tooLarge).toBe(false);
    expect(JSON.parse(json!)).toEqual(annotation);
    expect(annotation).toEqual({
      v: 1,
      shapes: [
        { kind: "pen", color: "#fbbf24", size: 2, points: [[0.1, 0.1], [0.2, 0.2], [0.3, 0.1]] },
        { kind: "arrow", color: "#ef4444", size: 1, from: [0.1, 0.1], to: [0.5, 0.5] },
        { kind: "text", color: "#ffffff", size: 3, at: [0.2, 0.2], text: "Look here" },
      ],
    });
  });

  it("drops shapes with nothing to draw", () => {
    const { annotation } = serializeAnnotation([
      { kind: "arrow", color: "#ffffff", size: 2, from: [0.5, 0.5], to: [0.5005, 0.5] },
      { kind: "rect", color: "#ffffff", size: 2, from: [0.1, 0.1], to: [0.6, 0.1] },
      { kind: "text", color: "#ffffff", size: 2, at: [0.1, 0.1], text: "   " },
    ]);
    expect(annotation).toBeNull();
  });

  it("an empty drawing serializes to nothing", () => {
    expect(serializeAnnotation([])).toEqual({ annotation: null, json: null, bytes: 0, tooLarge: false });
  });

  it("keeps a single tap as a dot", () => {
    const shape = canonicalShape({ kind: "pen", color: "#ffffff", size: 2, points: [[0.4, 0.4]] });
    expect(shape).toEqual({ kind: "pen", color: "#ffffff", size: 2, points: [[0.4, 0.4]] });
  });

  it("caps text labels at 140 characters", () => {
    const shape = canonicalShape({ kind: "text", color: "#ffffff", size: 2, at: [0, 0], text: "x".repeat(400) });
    expect((shape as { text: string }).text).toHaveLength(ANNOTATION_LIMITS.maxTextLength);
  });

  it("simplifies a dense freehand stroke without moving its ends", () => {
    // 3 000 samples along a gentle curve.
    const pts: Point[] = Array.from({ length: 3000 }, (_, i) => {
      const t = i / 2999;
      return [0.1 + 0.8 * t, 0.5 + 0.2 * Math.sin(t * Math.PI)];
    });
    const simple = simplifyStroke(pts);
    expect(simple.length).toBeLessThan(200);
    expect(simple[0]).toEqual(pts[0]);
    expect(simple[simple.length - 1]).toEqual(pts[pts.length - 1]);
    const { annotation, tooLarge } = serializeAnnotation([{ kind: "pen", color: "#ffffff", size: 2, points: pts }]);
    expect(tooLarge).toBe(false);
    expect((annotation!.shapes[0] as { points: Point[] }).points.length).toBeLessThanOrEqual(
      ANNOTATION_LIMITS.maxPointsPerStroke
    );
  });

  it("flags a drawing the API would refuse", () => {
    const many: AnnotationShape[] = Array.from({ length: ANNOTATION_LIMITS.maxShapes + 1 }, (_, i) => ({
      kind: "arrow",
      color: "#ffffff",
      size: 2,
      from: [0.1, (i % 50) / 100],
      to: [0.6, 0.9],
    }));
    expect(serializeAnnotation(many).tooLarge).toBe(true);
  });
});

describe("readAnnotation — the viewer's second fence", () => {
  it("round-trips a serialized drawing", () => {
    const { annotation } = serializeAnnotation([
      { kind: "ellipse", color: "#22c55e", size: 3, from: [0.2, 0.2], to: [0.4, 0.5] },
    ]);
    expect(readAnnotation(JSON.parse(JSON.stringify(annotation)))).toEqual(annotation);
  });

  it("drops malformed shapes instead of throwing", () => {
    const read = readAnnotation({
      v: 1,
      shapes: [
        { kind: "pen", color: "red", size: 2, points: [[0, 0]] },
        { kind: "rect", color: "#ffffff", size: 2, from: [0, 0] },
        { kind: "zap", color: "#ffffff", size: 2 },
        { kind: "pen", color: "#ffffff", size: 2, points: [[0.2, 0.2], ["x", 1]] },
      ],
    });
    expect(read).toEqual({ v: 1, shapes: [{ kind: "pen", color: "#ffffff", size: 2, points: [[0.2, 0.2]] }] });
    expect(readAnnotation(null)).toBeNull();
    expect(readAnnotation({ v: 2, shapes: [] })).toBeNull();
  });
});

describe("renderer", () => {
  /** A recording stub: captures the path calls in box pixels. */
  function recorder() {
    const calls: Array<[string, ...number[]]> = [];
    const ctx = {
      save() {}, restore() {}, beginPath() {}, closePath() {}, stroke() { calls.push(["stroke"]); },
      fill() { calls.push(["fill"]); }, fillText() { calls.push(["fillText"]); },
      moveTo(x: number, y: number) { calls.push(["moveTo", x, y]); },
      lineTo(x: number, y: number) { calls.push(["lineTo", x, y]); },
      quadraticCurveTo(a: number, b: number, c: number, d: number) { calls.push(["quad", a, b, c, d]); },
      arc(x: number, y: number, r: number) { calls.push(["arc", x, y, r]); },
      ellipse(x: number, y: number, rx: number, ry: number) { calls.push(["ellipse", x, y, rx, ry]); },
      rect(x: number, y: number, w: number, h: number) { calls.push(["rect", x, y, w, h]); },
      roundRect(x: number, y: number, w: number, h: number) { calls.push(["roundRect", x, y, w, h]); },
      measureText: (s: string) => ({ width: s.length * 10 }),
      lineWidth: 1, lineCap: "butt", lineJoin: "miter", strokeStyle: "", fillStyle: "", globalAlpha: 1,
      font: "", textBaseline: "alphabetic", textAlign: "start", shadowColor: "", shadowBlur: 0, shadowOffsetY: 0,
    };
    return { ctx: ctx as unknown as Ctx2D, calls };
  }

  it("draws the same shape at proportional positions on any player size", () => {
    const shapes: AnnotationShape[] = [
      { kind: "rect", color: "#ffffff", size: 2, from: [0.25, 0.25], to: [0.75, 0.5] },
      { kind: "ellipse", color: "#ffffff", size: 2, from: [0.1, 0.1], to: [0.3, 0.5] },
    ];
    const a = recorder();
    const b = recorder();
    drawAnnotation(a.ctx, shapes, containRect(640, 360, 1920, 1080));
    drawAnnotation(b.ctx, shapes, containRect(1280, 720, 1920, 1080));
    expect(a.calls.length).toBe(b.calls.length);
    a.calls.forEach((call, i) => {
      const other = b.calls[i];
      expect(other[0]).toBe(call[0]);
      call.slice(1).forEach((v, j) => expect(other[j + 1] as number).toBeCloseTo((v as number) * 2, 6));
    });
    expect(a.calls).toContainEqual(["rect", 160, 90, 320, 90]);
  });

  it("offsets into the letterboxed frame", () => {
    const r = recorder();
    drawAnnotation(r.ctx, [{ kind: "pen", color: "#ffffff", size: 1, points: [[0, 0]] }], containRect(1600, 900, 640, 480));
    expect(r.calls[0].slice(0, 3)).toEqual(["arc", 200, 0]);
  });

  it("does nothing on an empty frame", () => {
    const r = recorder();
    drawAnnotation(r.ctx, [{ kind: "pen", color: "#ffffff", size: 1, points: [[0.5, 0.5]] }], { x: 0, y: 0, w: 0, h: 0 });
    expect(r.calls).toEqual([]);
  });

  it("wraps labels by word, and breaks words that cannot fit", () => {
    const measure = (s: string) => s.length;
    expect(wrapLabel("one two three", 7, measure)).toEqual(["one two", "three"]);
    expect(wrapLabel("abcdefghij", 4, measure)).toEqual(["abcd", "efgh", "ij"]);
  });
});
