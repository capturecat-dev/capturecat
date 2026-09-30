/**
 * Subtitle text layout (subtitleText.ts) — the rules that do not depend on a
 * browser's glyph advances: AppKit's line-fragment height for every face
 * FontCatalog resolves (against the `exportSubtitleTextMetrics` AppKit
 * reference), face resolution, and word-wrap semantics (with a
 * deterministic fake measurer). Advance widths are validated in the browser
 * against the same vectors (see the engine lab notes): system face 400/510/
 * 590/700/860 wght reproduce AppKit to ≤ 0.2 px mean.
 */
import { describe, expect, it } from "vitest";
import { loadVectors } from "../../core/vectors/harness";
import { layoutSubtitleText, lineMetrics, resolveSubtitleFont, type TextMeasurer } from "./subtitleText";

/** Every char advances 10 px (spaces 5); ascent/descent from the size. */
const fake = (installed: string[] = ["Helvetica Neue", "Georgia", "Menlo", "Avenir Next"]): TextMeasurer => ({
  measure: (font, text) => {
    const size = Number(/(\d+(?:\.\d+)?)px/.exec(font)![1]);
    let w = 0;
    for (const ch of text) w += ch === " " ? 5 : 10;
    return { width: w, ascent: Math.round(size * 0.9), descent: Math.round(size * 0.2) };
  },
  hasFamily: (n) => installed.includes(n),
  face: () => "ready",
});

const req = (text: string, constraintWidth: number, fontName: string | null = null) => ({
  runs: [{ text, color: { r: 1, g: 1, b: 1, a: 1 }, active: null }],
  fontName,
  fontSize: 32,
  weight: "Bold" as const,
  constraintWidth,
});

describe("line fragment height = round(ascender) + round(|descender|) + leading", () => {
  it("matches AppKit for every face/size in exportSubtitleTextMetrics", () => {
    const vec = loadVectors("exportSubtitleTextMetrics");
    let checked = 0;
    for (const c of vec.cases) {
      const m = c.output.measured;
      const font = resolveSubtitleFont(c.input.fontName, c.input.weight, c.output.fontSize, fake(c.input.fontName === "No Such Font" ? [] : undefined));
      if (!font.em || c.input.text === "") continue;
      // (NSLayoutManager.defaultLineHeight is itself rounded — 38 for
      // Helvetica Neue 32 pt — the bounding rect carries the unrounded leading.)
      const lh = lineMetrics(font, fake()).lineHeight;
      const lines = m.boundingRect.height / lh;
      expect(Math.abs(lines - Math.round(lines)), JSON.stringify(c.input)).toBeLessThan(1e-6);
      expect(Math.round(lines)).toBeGreaterThanOrEqual(1);
      checked++;
    }
    expect(checked).toBeGreaterThan(800);
  });
});

describe("FontCatalog resolution", () => {
  it("system face for nil / System / missing families, at AppKit's wght", () => {
    expect(resolveSubtitleFont(null, "Heavy", 36, fake()).css).toBe("860 36px system-ui");
    expect(resolveSubtitleFont("System", "Medium", 20, fake()).css).toBe("510 20px system-ui");
    expect(resolveSubtitleFont("No Such Font", "Semibold", 20, fake()).system).toBe(true);
  });
  it("the exact Mac face when loaded (Helvetica Neue Heavy = CondensedBlack)", () => {
    const f = resolveSubtitleFont("Helvetica Neue", "Heavy", 32, fake());
    expect(f.face).toBe("HelveticaNeue-CondensedBlack");
    const loading = resolveSubtitleFont("Helvetica Neue", "Heavy", 32, { ...fake(), face: () => "loading" });
    expect(loading.face).toBeNull();
    expect(loading.pending).toBe(true);
  });
});

describe("word wrap (NSLineBreakByWordWrapping)", () => {
  const m = fake();
  it("single line = its advance; no wrap when it fits", () => {
    const l = layoutSubtitleText(m, req("Hello world", 1000));
    expect(l.lines.map((x) => x.text)).toEqual(["Hello world"]);
    expect(l.width).toBe(105);
  });
  it("greedy breaks at spaces; the bounding width includes the wrapped line's trailing space", () => {
    const l = layoutSubtitleText(m, req("Hello world", 80));
    expect(l.lines.map((x) => x.text)).toEqual(["Hello", "world"]);
    expect(l.lines[0].width).toBe(50);
    expect(l.lines[0].usedWidth).toBe(55);
    expect(l.width).toBe(55);
    expect(l.height).toBe(2 * l.lineHeight);
  });
  it("breaks inside a word longer than the line, and honours hard newlines", () => {
    const l = layoutSubtitleText(m, req("abcdefghij\nxy", 45));
    expect(l.lines.map((x) => x.text)).toEqual(["abcd", "efgh", "ij", "xy"]);
    expect(l.width).toBeLessThanOrEqual(45);
    const joined = l.text;
    for (const line of l.lines) expect(joined.slice(line.start, line.end)).toBe(line.text);
  });
});
