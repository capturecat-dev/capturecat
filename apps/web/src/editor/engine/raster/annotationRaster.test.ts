/**
 * Checks the web text/overlay helpers against Swift-measured reference data:
 *  - FontCatalog face resolution vs the `annotationTextMetrics` vectors'
 *    `resolvedFont` (NSFontManager / NSFont.systemFont on the Mac);
 *  - the TextLine height rule vs the vectors' measured heights (the ≥ 17 pt
 *    branch is round(ascender) + round(|descender|) — what Chrome's rounded
 *    fontBoundingBox metrics add up to; the browser half is verified in the
 *    lab calibration, see fontCatalog.ts);
 *  - CoreText's probed glyph-phase table;
 *  - the exporter's watermark placement formula.
 */
import { describe, expect, it } from "vitest";
import { loadVectors } from "../../core/vectors/harness";
import { cgGlyphPhases } from "./annotationText";
import { MAC_FAMILY_FACES, resolveFace, sfDescentRow } from "./fontCatalog";
import { watermarkPlacement } from "./watermarkLayout";

const swiftRound = (v: number) => (v < 0 ? -Math.round(-v) : Math.round(v));

describe("annotation text (FontCatalog / TextLine)", () => {
  const vectors = loadVectors("annotationTextMetrics");

  it("resolves the same face as FontCatalog.font(named:size:weight:)", () => {
    const sysWght: Record<string, string> = {
      ".AppleSystemUIFont": "Regular",
      ".AppleSystemUIFontMedium": "Medium",
      ".AppleSystemUIFontDemi": "Semibold",
      ".AppleSystemUIFontBold": "Bold",
      ".AppleSystemUIFontHeavy": "Heavy",
    };
    const wght: Record<string, number> = { Regular: 400, Medium: 510, Semibold: 590, Bold: 700, Heavy: 860 };
    for (const c of vectors.cases) {
      const face = resolveFace(c.input.fontName, c.input.fontWeight);
      const ps: string = c.output.measured.resolvedFont;
      if (ps.startsWith(".AppleSystemUIFont")) {
        // A family outside the table resolves at draw time: missing on the
        // machine → the system face at the same SF weight (familyAvailable).
        const unknownFamily = face.kind === "family" && !(c.input.fontName in MAC_FAMILY_FACES);
        expect(face.kind === "system" || unknownFamily, `${c.input.fontName}/${c.input.fontWeight}`).toBe(true);
        if (face.kind !== "postscript") expect(face.wght).toBe(wght[sysWght[ps]]);
      } else {
        expect(face.kind === "postscript" ? face.postscript : face.kind, `${c.input.fontName}/${c.input.fontWeight}`).toBe(ps);
      }
    }
  });

  it("line height rule reproduces NSAttributedString.size().height", () => {
    let checked = 0;
    for (const c of vectors.cases) {
      const m = c.output.measured;
      const size = c.input.fontSize * c.input.scale;
      if (c.output.displayText === "") {
        expect(m.height).toBe(14);
        continue;
      }
      const system = String(m.resolvedFont).startsWith(".AppleSystemUIFont");
      const height = swiftRound(m.ascender) + (system ? sfDescentRow(size, swiftRound(-m.descender)) : swiftRound(-m.descender));
      expect(height, `${c.input.text} ${m.resolvedFont} ${size}`).toBe(m.height);
      expect(swiftRound(m.ascender)).toBe(m.baselineFromTop);
      checked++;
    }
    expect(checked).toBeGreaterThan(800);
  });
});

describe("CoreText glyph phases (probed on macOS 26)", () => {
  it("matches the sweep table", () => {
    // size → horizontal phases (cgphases.swift sweep, 1/120 px steps).
    const table: [number, number][] = [
      [3, 5], [8.25, 5], [8.32, 5], [8.35, 4], [9, 4], [11.09, 4], [11.13, 3], [12, 3], [16.64, 3],
      [16.69, 2], [24, 2], [33.3, 2], [33.36, 1], [37.33, 1], [90, 1],
    ];
    for (const [size, n] of table) expect(cgGlyphPhases(size).h, `size ${size}`).toBe(n);
    for (const [size, n] of [[2, 5], [4, 3], [8, 2], [8.5, 1], [40, 1]] as const) expect(cgGlyphPhases(size).v, `v ${size}`).toBe(n);
  });
});

describe("watermarkStatic placement", () => {
  it("follows VideoExporter's origin interpolation (Y-down)", () => {
    const raw = { width: 800, height: 200 };
    const out = { width: 1920, height: 1080 };
    // canvasScale 1, size 120 → 120 × 30 at the bottom-right inside a 20 px pad.
    expect(watermarkPlacement(raw, out, 1, { watermarkSize: 120, watermarkX: 1, watermarkY: 1 })).toEqual({
      x: 1920 - 20 - 120,
      y: 1080 - 20 - 30,
      width: 120,
      height: 30,
    });
    expect(watermarkPlacement(raw, out, 2, { watermarkSize: 120, watermarkX: 0, watermarkY: 0 })).toEqual({
      x: 40,
      y: 40,
      width: 240,
      height: 60,
    });
    // Clamps: fractions to 0…1, width to the padded canvas.
    const p = watermarkPlacement(raw, { width: 200, height: 100 }, 1, { watermarkSize: 999, watermarkX: 2, watermarkY: -1 })!;
    expect(p.width).toBe(160);
    expect(p.x).toBe(20);
    expect(p.y).toBe(20);
    expect(watermarkPlacement({ width: 0, height: 10 }, out, 1, { watermarkSize: 120, watermarkX: 1, watermarkY: 1 })).toBeNull();
  });
});
