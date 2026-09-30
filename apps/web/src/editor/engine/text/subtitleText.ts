/**
 * Subtitle TEXT — the web twin of the exporter's AppKit text path
 * (`renderSubtitle`: FontCatalog.font(named:size:weight:) +
 * NSAttributedString.boundingRect(.usesLineFragmentOrigin, .usesFontLeading)
 * + `draw(in:)`, centred paragraph). Pure TS: the caller supplies a Canvas2D
 * measurer, so the layout rules are unit-tested against the AppKit reference
 * vectors (`exportSubtitleTextMetrics`) without a browser.
 *
 * Calibrated on this Mac against those vectors (Chrome, Canvas2D):
 *  - System face (nil / "System" / missing family) = `system-ui` (SF Pro,
 *    optical sizes automatic). AppKit's NSFont.Weight instances sit at wght
 *    400 / 510 / 590 / 700 / 860 on SF's variable axis — CSS 500/600/800
 *    would be 0.1–0.8 % off; with these the advances match to ≤ 0.2 px mean.
 *  - Line height = round(ascender) + round(|descender|) + leading — AppKit's
 *    line fragment (e.g. SF 32 pt: 31 + 7 + 0 = 38; Helvetica Neue 32 pt:
 *    30 + 7 + 0.896 = 37.896). Ascender / descender / leading come from the
 *    Mac faces' em metrics where known (table below), else from Chrome's
 *    fontBoundingBox (already rounded) with leading 0.
 *  - Width = the widest line's advance without trailing whitespace; greedy
 *    word wrap at the constraint width (NSLineBreakByWordWrapping), words
 *    longer than a line break between characters.
 */
import type { SubtitleWeight } from "../../core/model/enums";
import type { SubtitleMeasureRequest, SubtitleRun } from "../../core/math/exportText";

/** CSS weights reproducing AppKit's system-font instances (see header). */
export const SYSTEM_CSS_WEIGHT: Record<SubtitleWeight, number> = {
  Regular: 400,
  Medium: 510,
  Semibold: 590,
  Bold: 700,
  Heavy: 860,
};
/** Named families: plain CSS weights (NSFontManager picks the nearest face, like CSS). */
export const FAMILY_CSS_WEIGHT: Record<SubtitleWeight, number> = {
  Regular: 400,
  Medium: 500,
  Semibold: 600,
  Bold: 700,
  Heavy: 800,
};

interface EmMetrics {
  ascender: number;
  descender: number;
  leading: number;
}

/** AppKit em metrics of the faces FontCatalog resolves (exportSubtitleTextMetrics). */
const SYSTEM_EM: EmMetrics = { ascender: 0.966796875, descender: 0.2109375, leading: 0 };
const FAMILY_EM: Record<string, Partial<Record<SubtitleWeight, EmMetrics>> & { default: EmMetrics }> = {
  "Helvetica Neue": {
    default: { ascender: 0.975006103515625, descender: 0.2169952392578125, leading: 0.0290069580078125 },
    Regular: { ascender: 0.951995849609375, descender: 0.2129974365234375, leading: 0.0279998779296875 },
    Heavy: { ascender: 0.9720001220703125, descender: 0.2270050048828125, leading: 0.0279998779296875 },
  },
  Georgia: { default: { ascender: 0.9169921875, descender: 0.21923828125, leading: 0 } },
  Menlo: { default: { ascender: 0.92822265625, descender: 0.23583984375, leading: 0 } },
  "Avenir Next": { default: { ascender: 1.0, descender: 0.365997314453125, leading: 0 } },
};

/**
 * The exact face NSFontManager.font(withFamily:traits:weight:size:) picks
 * (exportSubtitleTextMetrics `resolvedFontName`), loaded by PostScript name
 * with `local()` — CSS weight matching alone disagrees (Helvetica Neue Heavy
 * is HelveticaNeue-CondensedBlack on the Mac, a condensed face CSS never
 * selects; with the exact face the advances match to the 1/100 px).
 */
const MAC_FACES: Record<string, Record<SubtitleWeight, string>> = {
  "Helvetica Neue": {
    Regular: "HelveticaNeue",
    Medium: "HelveticaNeue-Medium",
    Semibold: "HelveticaNeue-Bold",
    Bold: "HelveticaNeue-Bold",
    Heavy: "HelveticaNeue-CondensedBlack",
  },
  Georgia: { Regular: "Georgia", Medium: "Georgia", Semibold: "Georgia-Bold", Bold: "Georgia-Bold", Heavy: "Georgia-Bold" },
  Menlo: { Regular: "Menlo-Regular", Medium: "Menlo-Regular", Semibold: "Menlo-Bold", Bold: "Menlo-Bold", Heavy: "Menlo-Bold" },
  "Avenir Next": {
    Regular: "AvenirNext-Regular",
    Medium: "AvenirNext-Medium",
    Semibold: "AvenirNext-DemiBold",
    Bold: "AvenirNext-Bold",
    Heavy: "AvenirNext-Heavy",
  },
};

export type FaceState = "ready" | "loading" | "failed";

export interface TextMeasurer {
  /** Advance width + (rounded) font ascent/descent of `text` in the CSS `font`. */
  measure(font: string, text: string): { width: number; ascent: number; descent: number };
  /** Whether a named family is installed (FontCatalog falls back to the system face). */
  hasFamily(name: string): boolean;
  /** Exact-face availability (`local(<PostScript name>)`), loading it on first ask. */
  face?(postScriptName: string): FaceState;
}

export interface ResolvedFont {
  /** CSS font shorthand at `size` px. */
  css: string;
  family: string | null;
  system: boolean;
  size: number;
  em: EmMetrics | null;
  /** The exact Mac face in use, or null (CSS weight matching). */
  face: string | null;
  /** True while the exact face is still loading (the result is provisional). */
  pending: boolean;
}

/** The family CSS name a loaded exact face is registered under. */
export const faceFamily = (postScriptName: string) => `cc-face-${postScriptName}`;

/** FontCatalog.font(named:size:weight:) as a CSS font. */
export function resolveSubtitleFont(
  fontName: string | null | undefined,
  weight: SubtitleWeight,
  size: number,
  m: Pick<TextMeasurer, "hasFamily" | "face">,
): ResolvedFont {
  const system = !fontName || fontName === "System" || !m.hasFamily(fontName);
  if (system) {
    return {
      css: `${SYSTEM_CSS_WEIGHT[weight]} ${size}px system-ui`,
      family: null, system: true, size, em: SYSTEM_EM, face: null, pending: false,
    };
  }
  const table = FAMILY_EM[fontName!];
  const em = table ? (table[weight] ?? table.default) : null;
  const ps = MAC_FACES[fontName!]?.[weight] ?? null;
  const state = ps && m.face ? m.face(ps) : "failed";
  if (ps && state === "ready") {
    return { css: `${size}px "${faceFamily(ps)}", system-ui`, family: fontName!, system: false, size, em, face: ps, pending: false };
  }
  const quoted = `"${fontName!.replace(/"/g, "")}"`;
  return {
    css: `${FAMILY_CSS_WEIGHT[weight]} ${size}px ${quoted}, system-ui`,
    family: fontName!, system: false, size, em, face: null, pending: state === "loading",
  };
}

/** AppKit line fragment metrics for the resolved face. */
export function lineMetrics(font: ResolvedFont, m: Pick<TextMeasurer, "measure">): { ascent: number; descent: number; leading: number; lineHeight: number } {
  let ascent: number;
  let descent: number;
  let leading = 0;
  if (font.em) {
    ascent = Math.round(font.em.ascender * font.size);
    descent = Math.round(font.em.descender * font.size);
    leading = font.em.leading * font.size;
  } else {
    const t = m.measure(font.css, "Hg");
    ascent = Math.round(t.ascent);
    descent = Math.round(t.descent);
  }
  return { ascent, descent, leading, lineHeight: ascent + descent + leading };
}

export interface SubtitleLine {
  /** [start, end) into the joined run text, trailing whitespace excluded. */
  start: number;
  end: number;
  text: string;
  /** Advance without trailing whitespace — what centring uses. */
  width: number;
  /** Advance WITH the line's trailing whitespace — AppKit's used rect (bounding width). */
  usedWidth: number;
}

export interface SubtitleTextLayout {
  font: ResolvedFont;
  text: string;
  lines: SubtitleLine[];
  ascent: number;
  lineHeight: number;
  width: number;
  height: number;
}

const CJK = /[⺀-鿿가-힯豈-﫿＀-￯　-〿]/u;
const BREAK_AFTER = /[-‐–—/]/u;

/** Break units of one paragraph: a word (or CJK char) + its trailing spaces. */
function segments(p: string): string[] {
  const out: string[] = [];
  let cur = "";
  const chars = [...p];
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i];
    const next = chars[i + 1];
    cur += ch;
    const ws = /\s/u.test(ch);
    const endWord =
      (ws && (next === undefined || !/\s/u.test(next))) ||
      (!ws && (CJK.test(ch) || BREAK_AFTER.test(ch)) && next !== undefined && !/\s/u.test(next)) ||
      (!ws && next !== undefined && CJK.test(next));
    if (endWord) {
      out.push(cur);
      cur = "";
    }
  }
  if (cur) out.push(cur);
  return out;
}

const trimEnd = (s: string) => s.replace(/\s+$/u, "");

const GRAPHEMES = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** NSAttributedString("").boundingRect height (AppKit's default 12 pt line). */
export const EMPTY_STRING_HEIGHT = 14;

/** NSAttributedString.boundingRect + line breaks for a subtitle request. */
export function layoutSubtitleText(m: TextMeasurer, req: SubtitleMeasureRequest): SubtitleTextLayout {
  const font = resolveSubtitleFont(req.fontName, req.weight, req.fontSize, m);
  const lm = lineMetrics(font, m);
  const text = req.runs.map((r: SubtitleRun) => r.text).join("");
  if (text === "") {
    // An empty NSAttributedString carries no font: boundingRect falls back to
    // the 12 pt default face — 14 px tall at every size (vectors).
    return { font, text, lines: [], ascent: lm.ascent, lineHeight: lm.lineHeight, width: 0, height: EMPTY_STRING_HEIGHT };
  }
  const width = (s: string) => (s ? m.measure(font.css, s).width : 0);
  const lines: SubtitleLine[] = [];
  const limit = req.constraintWidth + 1e-6;
  let offset = 0;
  for (const para of text.split("\n")) {
    const base = offset;
    offset += para.length + 1;
    let lineStart = base;
    let line = "";
    const push = () => {
      const t = trimEnd(line);
      const w = width(t);
      lines.push({ start: lineStart, end: lineStart + t.length, text: t, width: w, usedWidth: t === line ? w : width(line) });
      lineStart += line.length;
      line = "";
    };
    for (const seg of segments(para)) {
      if (line && width(trimEnd(line + seg)) <= limit) {
        line += seg;
        continue;
      }
      if (line) push();
      if (width(trimEnd(seg)) <= limit) {
        line = seg;
        continue;
      }
      // A word wider than the line: break between characters (graphemes).
      for (const { segment: ch } of GRAPHEMES.segment(seg)) {
        if (line && !/^\s+$/u.test(ch) && width(trimEnd(line + ch)) > limit) push();
        line += ch;
      }
    }
    push();
  }
  // AppKit's bounding width: the widest line's used rect, trailing space
  // included (measured: "Hello world" wrapped at 48 pt = width("Hello ")),
  // never wider than the container.
  const w = lines.reduce((a, l) => Math.max(a, l.usedWidth), 0);
  return {
    font,
    text,
    lines,
    ascent: lm.ascent,
    lineHeight: lm.lineHeight,
    width: Math.min(w, req.constraintWidth),
    height: lines.length * lm.lineHeight,
  };
}

// ── Exact Mac faces via local() (one registry per worker / window) ──────────

const faces = new Map<string, FaceState>();
const faceListeners = new Set<() => void>();

/** Called once whenever an exact face finishes loading (re-raster + re-render). */
export function onFaceLoaded(cb: () => void): () => void {
  faceListeners.add(cb);
  return () => faceListeners.delete(cb);
}

function faceState(ps: string): FaceState {
  const s = faces.get(ps);
  if (s) return s;
  // Worker: self.fonts; window: document.fonts.
  const g = globalThis as unknown as { fonts?: FontFaceSet; document?: { fonts?: FontFaceSet } };
  const scope = { fonts: g.fonts ?? g.document?.fonts };
  if (typeof FontFace === "undefined" || !scope.fonts) {
    faces.set(ps, "failed");
    return "failed";
  }
  faces.set(ps, "loading");
  const f = new FontFace(faceFamily(ps), `local("${ps}")`);
  f.load().then(
    (loaded) => {
      scope.fonts!.add(loaded);
      faces.set(ps, "ready");
      for (const cb of faceListeners) cb();
    },
    () => {
      faces.set(ps, "failed");
      for (const cb of faceListeners) cb();
    },
  );
  return "loading";
}

/** A Canvas2D-backed measurer (worker or main thread). */
export function canvasMeasurer(): TextMeasurer {
  const canvas = new OffscreenCanvas(8, 8);
  const c = canvas.getContext("2d")!;
  const families = new Map<string, boolean>();
  return {
    face: faceState,
    measure(font, text) {
      if (c.font !== font) c.font = font;
      const t = c.measureText(text);
      return { width: t.width, ascent: t.fontBoundingBoxAscent, descent: t.fontBoundingBoxDescent };
    },
    hasFamily(name) {
      let v = families.get(name);
      if (v === undefined) {
        const probe = "mmmmmmmmmlliWW@#0123456789abcdefghijklmnopqrstuvwxyz";
        const q = `"${name.replace(/"/g, "")}"`;
        v = false;
        for (const generic of ["monospace", "serif", "sans-serif"]) {
          c.font = `72px ${generic}`;
          const a = c.measureText(probe).width;
          c.font = `72px ${q}, ${generic}`;
          if (Math.abs(c.measureText(probe).width - a) > 0.01) {
            v = true;
            break;
          }
        }
        families.set(name, v);
      }
      return v;
    },
  };
}
