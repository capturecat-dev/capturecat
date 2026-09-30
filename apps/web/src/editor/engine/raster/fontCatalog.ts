/**
 * Web twin of Services/FontCatalog.swift `font(named:size:weight:)` + the
 * CoreText text metrics `AnnotationRenderer.TextLine` reads
 * (`NSAttributedString.size()`, `round(font.ascender)`), for Canvas2D in the
 * render worker.
 *
 * # Face resolution (FontCatalog.font)
 *
 *  - nil / "" / "System" → the system face (SF Pro) at the weight. Chrome's
 *    `system-ui` on macOS is the same variable SF; NSFont's weights sit at
 *    wght Regular 400, Medium 510, Semibold 590, Bold 700, Heavy 860 — the
 *    CSS 500/600/800 instances are measurably narrower/wider (calibrated
 *    against the `annotationTextMetrics` vectors: with these values every
 *    Latin string lands within 0.01 px at 6–24 pt and ≤ 0.3 % at 128 pt).
 *  - A named family → `NSFontManager.font(withFamily:traits:weight:size:)`,
 *    which picks family members by AppKit's weight index (NOT CSS font
 *    matching: e.g. Helvetica Neue Heavy → HelveticaNeue-CondensedBlack,
 *    Futura Regular → Futura-Medium). `MAC_FAMILY_FACES` is that resolution
 *    for the curated menu faces and the other stock macOS families, generated
 *    on macOS 26 with the exact FontCatalog call (weights index 5/6/8/9/11,
 *    bold trait for Bold/Heavy) and cross-checked against the vectors'
 *    `resolvedFont`. A listed face loads by PostScript name via
 *    `local("<PostScript>")`; "system" means NSFontManager found no such
 *    family on the Mac either (→ system face, like FontCatalog's fallback).
 *  - A family not in the table → CSS family matching at the CSS weight,
 *    system-ui after it (FontCatalog falls back to the system face when the
 *    family is missing; Chrome does the same per glyph).
 *
 * # Metrics (TextLine)
 *
 *  - width  = canvas `measureText().width` (CoreText advance incl. kerning).
 *  - baselineFromTop = round(ascender) = Chrome's `fontBoundingBoxAscent`
 *    (Blink rounds the CoreText ascent; 960/960 vectors match).
 *  - height = NSAttributedString line height = round(ascent) + round(descent)
 *    = `fontBoundingBoxAscent + fontBoundingBoxDescent`, except the system
 *    face below 21 pt, whose descent row is ceil(|descender|) (see
 *    `sfDescentRow`; swept exhaustively, and 925/925 non-empty vectors).
 *  - the empty string measures 0 × 14 (NSAttributedString("").size() — the
 *    default 12 pt Helvetica line, independent of the annotation font).
 *
 * Residual (documented, not modelled): glyphs from FALLBACK fonts — emoji
 * (Chrome rounds Apple Color Emoji advances: −1…−5 px), CJK below 18 pt
 * (−0.1 px/pt), polytonic/uppercase Greek in SF (−0.06…−0.25 px/pt) and the
 * ⌘/⇧ symbols in non-system faces (−1.95 px at 18 pt) — measure a little
 * differently because CoreText's cascade list and Chrome's fallback pick
 * different faces.
 */
import type { SubtitleWeight } from "../../core/model/enums";

/** NSFont.Weight → SF variable-font wght. */
const SF_WGHT: Record<SubtitleWeight, number> = {
  Regular: 400,
  Medium: 510,
  Semibold: 590,
  Bold: 700,
  Heavy: 860,
};
/** CSS weights for family matching of faces not in the table. */
const CSS_WEIGHT: Record<SubtitleWeight, number> = {
  Regular: 400,
  Medium: 500,
  Semibold: 600,
  Bold: 700,
  Heavy: 800,
};
const WEIGHT_INDEX: Record<SubtitleWeight, number> = { Regular: 0, Medium: 1, Semibold: 2, Bold: 3, Heavy: 4 };

/** FontCatalog.font(named:weight:) as resolved by NSFontManager on macOS
 *  (Regular, Medium, Semibold, Bold, Heavy). See the module doc. */
export const MAC_FAMILY_FACES: Readonly<Record<string, readonly [string, string, string, string, string]>> = {
  "American Typewriter": ["AmericanTypewriter", "AmericanTypewriter", "AmericanTypewriter-Semibold", "AmericanTypewriter-Bold", "AmericanTypewriter-Bold"],
  Arial: ["ArialMT", "ArialMT", "Arial-BoldMT", "Arial-BoldMT", "Arial-BoldMT"],
  Avenir: ["Avenir-Book", "Avenir-Medium", "Avenir-Medium", "Avenir-Heavy", "Avenir-Black"],
  "Avenir Next": ["AvenirNext-Regular", "AvenirNext-Medium", "AvenirNext-DemiBold", "AvenirNext-Bold", "AvenirNext-Heavy"],
  Baskerville: ["Baskerville", "Baskerville", "Baskerville-SemiBold", "Baskerville-Bold", "Baskerville-Bold"],
  "Big Caslon": ["BigCaslon-Medium", "BigCaslon-Medium", "BigCaslon-Medium", "BigCaslon-Medium", "BigCaslon-Medium"],
  "Bodoni 72": ["BodoniSvtyTwoITCTT-Book", "BodoniSvtyTwoITCTT-Book", "BodoniSvtyTwoITCTT-Bold", "BodoniSvtyTwoITCTT-Bold", "BodoniSvtyTwoITCTT-Bold"],
  "Chalkboard SE": ["ChalkboardSE-Regular", "ChalkboardSE-Regular", "ChalkboardSE-Bold", "ChalkboardSE-Bold", "ChalkboardSE-Bold"],
  Charter: ["Charter-Roman", "Charter-Roman", "Charter-Bold", "Charter-Bold", "Charter-Black"],
  Cochin: ["Cochin", "Cochin", "Cochin-Bold", "Cochin-Bold", "Cochin-Bold"],
  Copperplate: ["Copperplate", "Copperplate", "Copperplate-Bold", "Copperplate-Bold", "Copperplate-Bold"],
  "Courier New": ["CourierNewPSMT", "CourierNewPSMT", "CourierNewPS-BoldMT", "CourierNewPS-BoldMT", "CourierNewPS-BoldMT"],
  Didot: ["Didot", "Didot", "Didot-Bold", "Didot-Bold", "Didot-Bold"],
  Futura: ["Futura-Medium", "Futura-Medium", "Futura-Bold", "Futura-Bold", "Futura-CondensedExtraBold"],
  Georgia: ["Georgia", "Georgia", "Georgia-Bold", "Georgia-Bold", "Georgia-Bold"],
  "Gill Sans": ["GillSans", "GillSans", "GillSans-SemiBold", "GillSans-Bold", "GillSans-UltraBold"],
  Helvetica: ["Helvetica", "Helvetica", "Helvetica-Bold", "Helvetica-Bold", "Helvetica-Bold"],
  "Helvetica Neue": ["HelveticaNeue", "HelveticaNeue-Medium", "HelveticaNeue-Bold", "HelveticaNeue-Bold", "HelveticaNeue-CondensedBlack"],
  "Hoefler Text": ["HoeflerText-Regular", "HoeflerText-Regular", "HoeflerText-Black", "HoeflerText-Black", "HoeflerText-Black"],
  Impact: ["Impact", "Impact", "Impact", "Impact", "Impact"],
  "Marker Felt": ["MarkerFelt-Thin", "MarkerFelt-Thin", "MarkerFelt-Wide", "MarkerFelt-Wide", "MarkerFelt-Wide"],
  Menlo: ["Menlo-Regular", "Menlo-Regular", "Menlo-Bold", "Menlo-Bold", "Menlo-Bold"],
  "New York": ["system", "system", "system", "system", "system"],
  Noteworthy: ["Noteworthy-Light", "Noteworthy-Light", "Noteworthy-Bold", "Noteworthy-Bold", "Noteworthy-Bold"],
  Optima: ["Optima-Regular", "Optima-Regular", "Optima-Bold", "Optima-Bold", "Optima-ExtraBlack"],
  Palatino: ["Palatino-Roman", "Palatino-Roman", "Palatino-Bold", "Palatino-Bold", "Palatino-Bold"],
  Rockwell: ["Rockwell-Regular", "Rockwell-Regular", "Rockwell-Bold", "Rockwell-Bold", "Rockwell-Bold"],
  "SF Mono": ["SFMono-Regular", "SFMono-Medium", "SFMono-Semibold", "SFMono-Bold", "SFMono-Heavy"],
  "SF Pro": ["system", "system", "system", "system", "system"],
  "SF Pro Rounded": ["system", "system", "system", "system", "system"],
  Tahoma: ["Tahoma", "Tahoma", "Tahoma-Bold", "Tahoma-Bold", "Tahoma-Bold"],
  "Times New Roman": ["TimesNewRomanPSMT", "TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT", "TimesNewRomanPS-BoldMT", "TimesNewRomanPS-BoldMT"],
  "Trebuchet MS": ["TrebuchetMS", "TrebuchetMS", "TrebuchetMS-Bold", "TrebuchetMS-Bold", "TrebuchetMS-Bold"],
  Verdana: ["Verdana", "Verdana", "Verdana-Bold", "Verdana-Bold", "Verdana-Bold"],
};

/** `FontCatalog.systemName` */
export const SYSTEM_NAME = "System";

export type FaceSpec =
  | { kind: "system"; wght: number }
  /** A concrete face loaded by PostScript name (FontFace alias). */
  | { kind: "postscript"; postscript: string; family: string; cssWeight: number; wght: number }
  /** CSS family matching (face not in the table). */
  | { kind: "family"; family: string; cssWeight: number; wght: number };

/** `FontCatalog.font(named:weight:)` → which face to draw with. */
export function resolveFace(name: string | null | undefined, weight: SubtitleWeight): FaceSpec {
  const w = SF_WGHT[weight] ?? 400;
  if (!name || name === SYSTEM_NAME) return { kind: "system", wght: w };
  const row = MAC_FAMILY_FACES[name];
  const cssWeight = CSS_WEIGHT[weight] ?? 400;
  if (row) {
    const ps = row[WEIGHT_INDEX[weight] ?? 0];
    if (ps === "system") return { kind: "system", wght: w };
    return { kind: "postscript", postscript: ps, family: name, cssWeight, wght: w };
  }
  return { kind: "family", family: name, cssWeight, wght: w };
}

// ── Loading (FontFace in the worker / window) ───────────────────────────────

type FontSetLike = { add(face: FontFace): unknown };
const fontSet = (): FontSetLike | null => {
  const g = globalThis as unknown as { fonts?: FontSetLike; document?: { fonts?: FontSetLike } };
  return g.fonts ?? g.document?.fonts ?? null;
};

/** PostScript name → load state of its `local()` alias. */
const faces = new Map<string, { state: "loading" | "ready" | "failed"; promise: Promise<boolean> }>();

function alias(ps: string): string {
  return `cc-ps-${ps}`;
}

/** Starts (or joins) the load of one PostScript face; resolves true when usable. */
export function loadFace(ps: string): Promise<boolean> {
  const hit = faces.get(ps);
  if (hit) return hit.promise;
  const set = fontSet();
  const entry = { state: "loading" as "loading" | "ready" | "failed", promise: Promise.resolve(false) };
  if (typeof FontFace === "undefined" || !set) {
    entry.state = "failed";
    faces.set(ps, entry);
    return entry.promise;
  }
  const face = new FontFace(alias(ps), `local("${ps.replace(/"/g, "")}")`);
  entry.promise = face.load().then(
    () => {
      set.add(face);
      entry.state = "ready";
      return true;
    },
    () => {
      entry.state = "failed";
      return false;
    },
  );
  faces.set(ps, entry);
  return entry.promise;
}

/** Every face a set of (fontName, weight) pairs needs, loaded. */
export async function ensureFaces(specs: Iterable<{ fontName?: string | null; fontWeight: SubtitleWeight }>): Promise<void> {
  const loads: Promise<boolean>[] = [];
  for (const s of specs) {
    const f = resolveFace(s.fontName, s.fontWeight);
    if (f.kind === "postscript") loads.push(loadFace(f.postscript));
  }
  await Promise.all(loads);
}

/** True while some face of `specs` is still loading (draw again later). */
export function facesPending(specs: Iterable<{ fontName?: string | null; fontWeight: SubtitleWeight }>): boolean {
  for (const s of specs) {
    const f = resolveFace(s.fontName, s.fontWeight);
    if (f.kind === "postscript" && faces.get(f.postscript)?.state !== "ready" && faces.get(f.postscript)?.state !== "failed") {
      return true;
    }
  }
  return false;
}

const quote = (family: string) => `"${family.replace(/["\\]/g, "")}"`;

/** Canvas `font` shorthand for a face at `px` (pixel == point in a raster). */
export function canvasFont(face: FaceSpec, px: number): string {
  switch (face.kind) {
    case "system":
      return `${face.wght} ${px}px system-ui`;
    case "postscript":
    case "family": {
      if (face.kind === "postscript" && faces.get(face.postscript)?.state === "ready") {
        return `400 ${px}px ${quote(alias(face.postscript))}, system-ui`;
      }
      // Not in the table / not installed as that PostScript face: CSS family
      // matching; a family this machine lacks falls back to the system face
      // at the SF weight, like FontCatalog's fallback.
      if (!familyAvailable(face.family)) return `${face.wght} ${px}px system-ui`;
      return `${face.cssWeight} ${px}px ${quote(face.family)}, system-ui`;
    }
  }
}

const familyCache = new Map<string, boolean>();

/** Whether `family` resolves to an installed face (vs the generic fallback). */
export function familyAvailable(family: string): boolean {
  const hit = familyCache.get(family);
  if (hit !== undefined) return hit;
  let ok = true;
  try {
    const ctx = ctx2d();
    const probe = "mmmmmmmmmmlliiWW@#0123";
    const width = (f: string) => {
      ctx.font = f;
      return ctx.measureText(probe).width;
    };
    ok = ["monospace", "serif"].some((g) => width(`72px ${quote(family)}, ${g}`) !== width(`72px ${g}`));
  } catch {
    ok = true;
  }
  familyCache.set(family, ok);
  return ok;
}

// ── Metrics ─────────────────────────────────────────────────────────────────

/** SF's |descender| per point (432 / 2048 em; NSFont.descender of the system face). */
const SF_DESCENDER_PER_PT = 432 / 2048;

export interface LineMetrics {
  width: number;
  height: number;
  baselineFromTop: number;
}

let measureCtx: OffscreenCanvasRenderingContext2D | null = null;
function ctx2d(): OffscreenCanvasRenderingContext2D {
  if (!measureCtx) {
    const c = new OffscreenCanvas(8, 8);
    const ctx = c.getContext("2d");
    if (!ctx) throw new Error("Canvas2D unavailable (text metrics)");
    // CoreText kerns every pair, spaces included; Chrome's "auto" shapes word
    // by word and drops space kerning (", " measured 2 px wider at 37 pt).
    ctx.fontKerning = "normal";
    measureCtx = ctx;
  }
  return measureCtx;
}

/** `TextLine(a, scale:)` measurements for `text` in `face` at `pointSize`. */
export function measureLine(text: string, face: FaceSpec, pointSize: number): LineMetrics {
  const ctx = ctx2d();
  ctx.font = canvasFont(face, pointSize);
  const m = ctx.measureText(text.length ? text : "x");
  const ascent = m.fontBoundingBoxAscent;
  const descent = m.fontBoundingBoxDescent;
  if (text.length === 0) return { width: 0, height: 14, baselineFromTop: ascent };
  return { width: m.width, height: ascent + (drawsSystemFace(face) ? sfDescentRow(pointSize, descent) : descent), baselineFromTop: ascent };
}

/** True when `face` ends up drawn with the system face (see `canvasFont`). */
function drawsSystemFace(face: FaceSpec): boolean {
  if (face.kind === "system") return true;
  if (face.kind === "postscript" && faces.get(face.postscript)?.state === "ready") return false;
  return !familyAvailable(face.family);
}

/**
 * The descent row NSAttributedString's line adds for the system face:
 * ceil(|descender|) below 21 pt (SF's text optical sizes), round above —
 * swept on macOS 26 at 0.01 pt steps from 1 to 80 pt, every weight: exact
 * (the named faces are plain round(ascender) + round(|descender|)).
 */
export function sfDescentRow(pointSize: number, roundedDescent: number): number {
  if (!(pointSize < 21)) return roundedDescent;
  return Math.ceil(pointSize * SF_DESCENDER_PER_PT - 1e-9);
}
