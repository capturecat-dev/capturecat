/**
 * The cross-platform contract for comment drawings: annotation.fixtures.json
 * is what THIS serializer and renderer produce for a fixed set of inputs.
 * The iOS app ports the same maths (apps/ios/Core/ShareAnnotation.swift) and
 * its core self-test (apps/ios/scripts/core-selftest.sh) must reproduce every
 * byte and every draw call in the file — so a drawing posted from an iPhone
 * is exactly what the web would post, and lands on the same pixels.
 *
 * This test fails when the web drifts from the file. If the change is meant,
 * regenerate it and re-run the iOS self-test:
 *
 *   UPDATE_ANNOTATION_FIXTURES=1 npx vitest run src/lib/share/annotation.fixtures.test.ts
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  containRect,
  drawAnnotation,
  fontSize,
  labelMetrics,
  readAnnotation,
  serializeAnnotation,
  strokeWidth,
  toBox,
  toFrame,
  type AnnotationShape,
  type Ctx2D,
  type Point,
  type Rect,
} from "./annotation";

const FILE = fileURLToPath(new URL("./annotation.fixtures.json", import.meta.url));

/** A stand-in label font: 0.56 em per character, the same in Swift. */
const measure = (text: string, px: number) => [...text].length * px * 0.56;

function recorder(fontPx: () => number) {
  const calls: Array<Array<string | number>> = [];
  const ctx = {
    save() {}, restore() {}, beginPath() {}, closePath() {},
    stroke() { calls.push(["stroke", ctx.lineWidth]); },
    fill() { calls.push(["fill", ctx.fillStyle]); },
    fillText(text: string, x: number, y: number) { calls.push(["fillText", text, x, y]); },
    moveTo(x: number, y: number) { calls.push(["moveTo", x, y]); },
    lineTo(x: number, y: number) { calls.push(["lineTo", x, y]); },
    quadraticCurveTo(a: number, b: number, c: number, d: number) { calls.push(["quad", a, b, c, d]); },
    arc(x: number, y: number, r: number) { calls.push(["arc", x, y, r]); },
    ellipse(x: number, y: number, rx: number, ry: number) { calls.push(["ellipse", x, y, rx, ry]); },
    rect(x: number, y: number, w: number, h: number) { calls.push(["rect", x, y, w, h]); },
    roundRect(x: number, y: number, w: number, h: number, r: number) { calls.push(["roundRect", x, y, w, h, r]); },
    measureText: (s: string) => ({ width: measure(s, fontPx()) }),
    lineWidth: 1, lineCap: "butt", lineJoin: "miter", strokeStyle: "", fillStyle: "", globalAlpha: 1,
    font: "", textBaseline: "alphabetic", textAlign: "start", shadowColor: "", shadowBlur: 0, shadowOffsetY: 0,
  };
  return { ctx, calls };
}

/** Inputs as a viewer's drawing would produce them, before canonicalising. */
const dense: Point[] = Array.from({ length: 400 }, (_, i) => {
  const t = i / 399;
  return [0.12 + 0.7 * t + 0.00003 * Math.sin(i * 7), 0.4 + 0.18 * Math.sin(t * Math.PI * 2)];
});

const SERIALIZE: Array<{ name: string; shapes: AnnotationShape[] }> = [
  { name: "every kind", shapes: [
    { kind: "pen", color: "#FBBF24", size: 2, points: [[0.1, 0.1], [0.2, 0.2], [0.3, 0.1]] },
    { kind: "highlight", color: "#22C55E", size: 3, points: [[0.2, 0.7], [0.35, 0.72], [0.5, 0.7]] },
    { kind: "arrow", color: "#EF4444", size: 1, from: [0.1, 0.1], to: [0.5, 0.5] },
    { kind: "rect", color: "#3b82f6", size: 2, from: [0.6, 0.6], to: [0.25, 0.3] },
    { kind: "ellipse", color: "#ffffff", size: 3, from: [0.2, 0.2], to: [0.4, 0.5] },
    { kind: "text", color: "#111111", size: 2, at: [0.2, 0.2], text: "  Look\nhere " },
  ] },
  { name: "rounding and clamping", shapes: [
    { kind: "arrow", color: "#abcdef", size: 2, from: [0.123456, -0.2], to: [1.7, 0.98765] },
    { kind: "pen", color: "#ffffff", size: 2, points: [[0.33333333, 0.66666666], [0.33334, 0.66667], [0.5, 0.25]] },
    { kind: "rect", color: "#ffffff", size: 2, from: [0.00005, 0.99995], to: [0.5000049, 0.1] },
  ] },
  { name: "dense freehand stroke", shapes: [{ kind: "pen", color: "#ef4444", size: 2, points: dense }] },
  { name: "a tap is a dot", shapes: [{ kind: "pen", color: "#ffffff", size: 1, points: [[0.4, 0.4], [0.4, 0.4]] }] },
  { name: "bad colour and size fall back", shapes: [
    { kind: "rect", color: "red", size: 7 as 2, from: [0.1, 0.1], to: [0.3, 0.3] },
    { kind: "ellipse", color: "#12345G", size: 0 as 2, from: [0.1, 0.1], to: [0.3, 0.3] },
  ] },
  { name: "text: escapes, unicode, caps", shapes: [
    { kind: "text", color: "#ffffff", size: 1, at: [0.5, 0.5], text: "Say \"hi\" \\ to ünïcode — 👋🏽 here\u0007now‮ok" },
    { kind: "text", color: "#ffffff", size: 3, at: [0.1, 0.9], text: "x".repeat(200) + "😀".repeat(5) },
    { kind: "text", color: "#ffffff", size: 2, at: [0.1, 0.1], text: " \t\n " },
  ] },
  { name: "accidental taps are dropped", shapes: [
    { kind: "arrow", color: "#ffffff", size: 2, from: [0.5, 0.5], to: [0.5005, 0.5] },
    { kind: "rect", color: "#ffffff", size: 2, from: [0.1, 0.1], to: [0.6, 0.1] },
    { kind: "ellipse", color: "#ffffff", size: 2, from: [0.1, 0.1], to: [0.1035, 0.6] },
  ] },
  { name: "too many shapes", shapes: Array.from({ length: 101 }, (_, i) => ({
    kind: "arrow" as const, color: "#ffffff", size: 2 as const, from: [0.1, (i % 50) / 100] as Point, to: [0.6, 0.9] as Point,
  })) },
];

const BOXES: Array<{ box: [number, number]; media: [number, number] | null }> = [
  { box: [1600, 900], media: [640, 480] },
  { box: [393, 221], media: [640, 360] },
  { box: [874, 402], media: [640, 360] },
  { box: [402, 874], media: [1080, 1920] },
  { box: [800, 450], media: null },
];

const RENDER: Array<{ name: string; shapes: AnnotationShape[]; rect: Rect; minStrokePx?: number }> = [
  { name: "every kind, letterboxed", rect: containRect(874, 402, 640, 360), shapes: SERIALIZE[0].shapes },
  { name: "dot, long arrow, short arrow", rect: containRect(393, 221, 640, 360), shapes: [
    { kind: "pen", color: "#ffffff", size: 3, points: [[0.5, 0.5]] },
    { kind: "arrow", color: "#ef4444", size: 2, from: [0.05, 0.9], to: [0.95, 0.1] },
    { kind: "arrow", color: "#ef4444", size: 3, from: [0.5, 0.5], to: [0.52, 0.5] },
  ] },
  { name: "labels wrap and pin inside the frame", rect: { x: 79.5, y: 0, w: 714.67, h: 402 }, shapes: [
    { kind: "text", color: "#fbbf24", size: 3, at: [0.92, 0.95], text: "A label near the corner that wraps onto lines" },
    { kind: "text", color: "#111111", size: 1, at: [0.0, 0.0], text: "Supercalifragilisticexpialidocious-and-then-some" },
  ] },
  { name: "cropped fill (frame larger than the box)", rect: { x: 0, y: -44.8125, w: 874, h: 491.625 }, shapes: [
    { kind: "rect", color: "#22c55e", size: 2, from: [0.3, 0.3], to: [0.7, 0.6] },
  ] },
  { name: "thumbnail floor", rect: containRect(64, 36, 640, 360), minStrokePx: 1.1, shapes: [
    { kind: "pen", color: "#ffffff", size: 1, points: [[0.1, 0.1], [0.5, 0.5], [0.9, 0.2]] },
  ] },
];

function build() {
  return {
    note: "Generated by annotation.fixtures.test.ts from the web's annotation.ts. Read by apps/ios/Tests/CoreSelfTest.swift. Do not edit by hand.",
    measure: "label advance = Unicode code points × fontPx × 0.56",
    serialize: SERIALIZE.map(({ name, shapes }) => {
      const s = serializeAnnotation(shapes);
      return { name, shapes, json: s.json, bytes: s.bytes, tooLarge: s.tooLarge };
    }),
    read: SERIALIZE.slice(0, 2).map(({ name, shapes }) => {
      const input = JSON.parse(serializeAnnotation(shapes).json!);
      return { name, input, output: readAnnotation(input) };
    }),
    geometry: BOXES.map(({ box, media }) => {
      const rect = containRect(box[0], box[1], media?.[0], media?.[1]);
      return {
        box, media, rect,
        stroke: { pen: [1, 2, 3].map((s) => strokeWidth("pen", s as 1, rect)), highlight: strokeWidth("highlight", 2, rect) },
        font: [1, 2, 3].map((s) => fontSize(s as 1, rect)),
        label: labelMetrics(2, rect),
        toBox: toBox([0.3, 0.7], rect),
        toFrame: toFrame(box[0] * 0.25, box[1] * 0.9, rect),
      };
    }),
    render: RENDER.map(({ name, shapes, rect, minStrokePx }) => {
      let px = 0;
      const { ctx, calls } = recorder(() => px);
      // The font is set per label before measuring; read it back off ctx.font.
      Object.defineProperty(ctx, "font", {
        get: () => `${px}px`,
        set: (v: string) => { px = parseFloat(v.replace(/^\d+\s+/, "")); },
      });
      drawAnnotation(ctx as unknown as Ctx2D, shapes, rect, { minStrokePx });
      return { name, shapes, rect, minStrokePx: minStrokePx ?? 0, calls };
    }),
  };
}

describe("annotation fixtures (the iOS port's contract)", () => {
  it("the web still produces exactly annotation.fixtures.json", () => {
    const fresh = JSON.stringify(build(), null, 1) + "\n";
    if (process.env.UPDATE_ANNOTATION_FIXTURES === "1") writeFileSync(FILE, fresh);
    expect(readFileSync(FILE, "utf8")).toBe(fresh);
  });

  it("covers what the port must get right", () => {
    const f = build();
    expect(f.serialize.find((s) => s.name === "too many shapes")?.tooLarge).toBe(true);
    expect(f.serialize.find((s) => s.name === "accidental taps are dropped")?.json).toBeNull();
    expect(f.render.every((r) => r.calls.length > 0)).toBe(true);
  });
});
