/**
 * On-canvas editing chrome — the web twin of the Mac preview's editor-only
 * decoration, drawn into the stage overlay's 2D canvas (canvas backing px):
 *
 * - `SelectionChromeKit` (Services/SelectionChromeKit.swift): the ONE region
 *   selection chrome for blur / highlight / depth focus — 2pt accent outline
 *   inside the box, eight 8pt resize dots, the floating value pill (icons +
 *   CCSlider-style ticks and bar thumb). Selected region only.
 * - `AnnotationRenderer.Chrome` (Services/AnnotationRenderer.swift): the
 *   accent selection ring (1.5pt, 3pt off the shape), Keynote grab handles
 *   (10pt white discs; unselected annotations' handles at 0.55), the tap's
 *   dashed ring. Paused only (`showsHandles = !isPlaying`).
 * - The zoom block's focal reticle (PreviewCompositorView focalReticleLayer).
 * - The armed blur-draw marquee (PreviewInteractionView.blurMarquee).
 *
 * The Mac draws all but the marquee INSIDE the warped card layer (content
 * space), so they ride the zoom and tilt. Here every card-space shape goes
 * through the frame's camera homography: outlines/rings are projected
 * exactly (`projectPath`), small glyphs (dots, handles, pill, reticle) are
 * drawn in card units under the camera's local affine at their centre
 * (exact for affine cameras). Units: card px, 1 Mac point = `u` card px.
 */
import type { Mat3 } from "../../engine/mat3";
import type { Annotation, Rect } from "../../core/model";
import { cgEllipsePath, continuousCircularPath, continuousRoundedRectPath, type PathElements } from "../../core/math/overlaySupport";
import { SWIFTUI_SHADOW_BLUR_FACTOR } from "../../core/math/overlaySupport";
import { smax, smin } from "../../core/math/swift";
import { focalReticleRadius, insetRect, isActiveAt, pillIconSize, regionPillLayout, regionPixelRect, videoPoint, RegionHandleChrome, type HitGeometry } from "./stageGeometry";
import { cardToCanvas, localAffine, localScale, projectPath, projectRect, type Pt } from "./stageMapping";

type Ctx = CanvasRenderingContext2D;

export interface ChromeTheme {
  /** NSColor.controlAccentColor (`--cc-primary`). */
  accent: string;
  /** EditorThemeKit.panelElevated (`--cc-elevated`). */
  elevated: string;
  /** EditorThemeKit.hairline (`--cc-border`). */
  hairline: string;
  /** EditorThemeKit.textSecondary (`--cc-muted`). */
  muted: string;
  /** CCTheme.isDark — the slider's hard-contrast ink (white on dark). */
  dark: boolean;
}

export const DEFAULT_THEME: ChromeTheme = {
  accent: "#007aff",
  elevated: "#232327",
  hairline: "rgba(255,255,255,0.07)",
  muted: "rgba(255,255,255,0.55)",
  dark: true,
};

/** Reads the CCKit tokens off the element's `.cc-theme` ancestor. */
export function readChromeTheme(el: Element): ChromeTheme {
  if (typeof getComputedStyle !== "function") return DEFAULT_THEME;
  const cs = getComputedStyle(el);
  const v = (name: string, fallback: string) => cs.getPropertyValue(name).trim() || fallback;
  const ink = v("--cc-ink", "#ffffff").toLowerCase();
  return {
    accent: v("--cc-primary", DEFAULT_THEME.accent),
    elevated: v("--cc-elevated", DEFAULT_THEME.elevated),
    hairline: v("--cc-border", DEFAULT_THEME.hairline),
    muted: v("--cc-muted", DEFAULT_THEME.muted),
    dark: ink === "#ffffff" || ink === "#fff" || ink.startsWith("rgb(255"),
  };
}

/** The frame a chrome pass draws against. */
export interface ChromeFrame extends HitGeometry {
  /** Card → overlay-canvas px. */
  camera: Mat3;
}

/** AnnotationRenderer's fixed chrome blue — sRGB (0, 122, 255). */
const SELECTION_BLUE = "rgb(0 122 255)";

// ── Path helpers ────────────────────────────────────────────────────────────

function trace(ctx: Ctx, els: PathElements): void {
  ctx.beginPath();
  for (const el of els) {
    switch (el[0]) {
      case "M":
        ctx.moveTo(el[1], el[2]);
        break;
      case "L":
        ctx.lineTo(el[1], el[2]);
        break;
      case "Q":
        ctx.quadraticCurveTo(el[1], el[2], el[3], el[4]);
        break;
      case "C":
        ctx.bezierCurveTo(el[1], el[2], el[3], el[4], el[5], el[6]);
        break;
      case "Z":
        ctx.closePath();
        break;
    }
  }
}

function rectCenter(r: Rect): Pt {
  return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
}

/** Strokes a CARD-space path through the camera, line width in card px. */
function strokeCardPath(ctx: Ctx, f: ChromeFrame, els: PathElements, lineWidthCard: number, color: string, anchor: Pt, dash?: number[]): void {
  const s = localScale(f.camera, anchor);
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  trace(ctx, projectPath(els, f.camera));
  ctx.lineWidth = lineWidthCard * s;
  ctx.strokeStyle = color;
  if (dash) ctx.setLineDash(dash.map((d) => d * s));
  ctx.stroke();
  ctx.restore();
}

/** Runs `draw` with the context in CARD px under the camera's local affine at `anchor`. */
function inCard(ctx: Ctx, f: ChromeFrame, anchor: Pt, draw: () => void): void {
  ctx.save();
  const [a, b, c, d, e, g] = localAffine(f.camera, anchor);
  ctx.setTransform(a, b, c, d, e, g);
  draw();
  ctx.restore();
}

/** Clips to the projected video rect (the Mac's overlayClip card mask). */
function clipToVideo(ctx: Ctx, f: ChromeFrame): void {
  const q = projectRect(f.videoRect, f.camera);
  ctx.beginPath();
  ctx.moveTo(q[0].x, q[0].y);
  for (let i = 1; i < 4; i++) ctx.lineTo(q[i].x, q[i].y);
  ctx.closePath();
  ctx.clip();
}

// ── Region selection chrome (SelectionChromeKit) ────────────────────────────

export interface RegionChromeSpec {
  /** Normalized, Y-down (region.rect). */
  rect: Rect;
  /** Outline corner radius, card px. */
  cornerRadius: number;
  sliderValue: number;
  sliderRange: [number, number];
  leadingIcon: string;
  trailingIcon: string;
}

export function drawRegionChrome(ctx: Ctx, f: ChromeFrame, theme: ChromeTheme, spec: RegionChromeSpec): void {
  const u = f.u;
  const r = regionPixelRect(spec.rect, f);
  ctx.save();
  clipToVideo(ctx, f);

  // The ONE outline spec: 2pt accent stroke INSIDE the box, radius matching the shape.
  const outline = continuousRoundedRectPath(insetRect(r, u, u), smax(0, spec.cornerRadius - u));
  strokeCardPath(ctx, f, outline, 2 * u, theme.accent, rectCenter(r));

  // Eight dots pinned inside the box (`.frame(alignment:)`).
  const dot = RegionHandleChrome.dotSize * u;
  for (const [fx, fy] of [
    [0, 0],
    [1, 0],
    [0, 1],
    [1, 1],
    [0.5, 0],
    [0.5, 1],
    [0, 0.5],
    [1, 0.5],
  ] as const) {
    const c = { x: r.x + dot / 2 + fx * (r.width - dot), y: r.y + dot / 2 + fy * (r.height - dot) };
    inCard(ctx, f, c, () => drawDot(ctx, c, dot, u));
  }

  drawPill(ctx, f, theme, spec, r);
  ctx.restore();
}

/** White 90% with a 1pt black 40% inner ring — never theme-inked (floats over video). */
function drawDot(ctx: Ctx, c: Pt, size: number, u: number): void {
  ctx.beginPath();
  ctx.ellipse(c.x, c.y, size / 2, size / 2, 0, 0, Math.PI * 2);
  ctx.fillStyle = "rgba(255,255,255,0.9)";
  ctx.fill();
  ctx.beginPath();
  ctx.ellipse(c.x, c.y, size / 2 - u / 2, size / 2 - u / 2, 0, 0, Math.PI * 2);
  ctx.strokeStyle = "rgba(0,0,0,0.4)";
  ctx.lineWidth = u;
  ctx.stroke();
}

function drawPill(ctx: Ctx, f: ChromeFrame, theme: ChromeTheme, spec: RegionChromeSpec, r: Rect): void {
  const u = f.u;
  const layout = regionPillLayout(r, f, spec.leadingIcon, spec.trailingIcon);
  const pill = layout.pill;
  const pillHeight = RegionHandleChrome.pillHeight * u;
  inCard(ctx, f, rectCenter(pill), () => {
    trace(ctx, continuousCircularPath(pill, pillHeight / 2));
    ctx.fillStyle = theme.elevated;
    ctx.fill();
    trace(ctx, continuousCircularPath(insetRect(pill, u / 2, u / 2), pillHeight / 2 - u / 2));
    ctx.strokeStyle = theme.hairline;
    ctx.lineWidth = u;
    ctx.stroke();

    drawIcon(ctx, spec.leadingIcon, layout.leadingCenter, u, theme.muted, theme.elevated);
    drawSliderTrack(ctx, layout.slider, spec.sliderValue, spec.sliderRange, u, theme.dark);
    drawIcon(ctx, spec.trailingIcon, layout.trailingCenter, u, theme.muted, theme.elevated);
  });
}

/** CCSlider idle metrics: faint 1×8pt ticks ~18pt apart, a 4×18pt bar thumb. */
function drawSliderTrack(ctx: Ctx, rect: Rect, value: number, range: [number, number], u: number, dark: boolean): void {
  const [lo, hi] = range;
  const span = hi - lo;
  const clamped = smin(smax(value, lo), hi);
  const fraction = span > 0 ? (clamped - lo) / span : 0;
  const ink = dark ? 255 : 0;
  const widthPt = rect.width / u;
  const visibleTicks = widthPt < 54 ? 0 : Math.min(9, Math.trunc(widthPt / 18));
  if (visibleTicks > 0) {
    ctx.fillStyle = `rgba(${ink},${ink},${ink},0.22)`;
    const midY = rect.y + rect.height / 2;
    for (let i = 0; i < visibleTicks; i++) {
      const t = (i + 1) / (visibleTicks + 1);
      ctx.fillRect(rect.x + rect.width * t, midY - 4 * u, u, 8 * u);
    }
  }
  const barW = 4 * u;
  const barH = 18 * u;
  const bar = { x: rect.x + (rect.width - barW) * fraction, y: rect.y + rect.height / 2 - barH / 2, width: barW, height: barH };
  ctx.save();
  // SwiftUIShadow(radius 3, y 0, black .35) — CG blur = radius · 2.2 · device scale.
  ctx.shadowColor = "rgba(0,0,0,0.35)";
  ctx.shadowBlur = 3 * SWIFTUI_SHADOW_BLUR_FACTOR * u;
  ctx.fillStyle = `rgba(${ink},${ink},${ink},${dark ? 1 : 0.85})`;
  trace(ctx, continuousRoundedRectPath(bar, 2 * u));
  ctx.fill();
  ctx.restore();
}

/**
 * The pill's SF Symbols (9pt regular), vector-drawn so they stay crisp under
 * the zoom: eye / eye.slash.fill (blur), circle.dashed / camera.aperture
 * (depth focus), circle.lefthalf.filled / circle.fill (highlight).
 */
function drawIcon(ctx: Ctx, name: string, c: Pt, u: number, color: string, bg: string): void {
  const size = pillIconSize(name);
  const w = size.width * u;
  const h = size.height * u;
  const lw = 1.1 * u;
  ctx.save();
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = lw;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  const almond = (hw: number, hh: number) => {
    ctx.beginPath();
    ctx.moveTo(c.x - hw, c.y);
    ctx.quadraticCurveTo(c.x, c.y - hh * 2, c.x + hw, c.y);
    ctx.quadraticCurveTo(c.x, c.y + hh * 2, c.x - hw, c.y);
    ctx.closePath();
  };
  const r = Math.min(w, h) / 2 - lw / 2;
  switch (name) {
    case "eye": {
      almond(w / 2 - lw / 2, h / 2 - lw / 2);
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(c.x, c.y, h * 0.24, 0, Math.PI * 2);
      ctx.fill();
      break;
    }
    case "eye.slash.fill": {
      const hh = h * 0.38;
      almond(w / 2 - lw / 2, hh);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(c.x, c.y, hh * 0.5, 0, Math.PI * 2);
      ctx.fillStyle = bg;
      ctx.fill();
      const a = { x: c.x - w * 0.38, y: c.y - h / 2 + lw / 2 };
      const b = { x: c.x + w * 0.38, y: c.y + h / 2 - lw / 2 };
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.strokeStyle = bg;
      ctx.lineWidth = lw * 2.6;
      ctx.stroke();
      ctx.strokeStyle = color;
      ctx.lineWidth = lw;
      ctx.stroke();
      break;
    }
    case "circle.dashed": {
      ctx.beginPath();
      ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
      const circ = 2 * Math.PI * r;
      const n = 12;
      ctx.setLineDash([(circ / n) * 0.55, (circ / n) * 0.45]);
      ctx.lineCap = "butt";
      ctx.stroke();
      break;
    }
    case "camera.aperture": {
      ctx.beginPath();
      ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
      ctx.stroke();
      ctx.lineWidth = lw * 0.85;
      for (let k = 0; k < 6; k++) {
        const t = (k * Math.PI) / 3 - Math.PI / 2;
        const t2 = t + (Math.PI * 5) / 9;
        ctx.beginPath();
        ctx.moveTo(c.x + r * Math.cos(t), c.y + r * Math.sin(t));
        ctx.lineTo(c.x + r * 0.42 * Math.cos(t2), c.y + r * 0.42 * Math.sin(t2));
        ctx.stroke();
      }
      break;
    }
    case "circle.lefthalf.filled": {
      ctx.beginPath();
      ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(c.x, c.y, r, Math.PI / 2, (Math.PI * 3) / 2);
      ctx.closePath();
      ctx.fill();
      break;
    }
    case "circle.fill":
    default: {
      ctx.beginPath();
      ctx.arc(c.x, c.y, Math.min(w, h) / 2, 0, Math.PI * 2);
      ctx.fill();
      break;
    }
  }
  ctx.restore();
}

// ── Annotation chrome (AnnotationRenderer.Chrome) ───────────────────────────

export interface AnnotationChromeInput {
  annotations: readonly Annotation[];
  /** SOURCE seconds shown. */
  time: number;
  selectedId: string | null;
  /** Omitted entirely (the in-place editor replaces it). */
  editingId: string | null;
  /** Card-px label rect of a text/callout (the renderer's pill/box). */
  labelRect: (a: Annotation) => Rect | null;
}

/**
 * Handles + selection rings of every annotation live at `time` (paused
 * editor only — the caller skips this while playing). Same order and alpha
 * as `AnnotationRenderer.draw`: project order, whole-annotation opacity
 * (settled phase — the paused editor renders annotations settled).
 */
export function drawAnnotationChrome(ctx: Ctx, f: ChromeFrame, input: AnnotationChromeInput): void {
  const u = f.u;
  const vr = f.videoRect;
  for (const a of input.annotations) {
    if (!isActiveAt(a, input.time)) continue;
    if (input.editingId != null && input.editingId === a.id) continue;
    const alpha = smax(0, smin(1, a.opacity));
    if (!(alpha > 0.001)) continue;
    const selected = input.selectedId != null && input.selectedId === a.id;
    ctx.save();
    ctx.globalAlpha = alpha;
    const radius = smax(0, a.cornerRadius) * u;
    const outset = 3 * u;
    switch (a.type) {
      case "text": {
        const pill = input.labelRect(a);
        if (selected && pill) {
          strokeCardPath(ctx, f, continuousRoundedRectPath(insetRect(pill, -outset, -outset), radius + outset), 1.5 * u, SELECTION_BLUE, rectCenter(pill));
        }
        break;
      }
      case "arrow": {
        const h = selected ? 1 : 0.55;
        drawHandle(ctx, f, videoPoint(a.x, a.y, vr), 10 * u, h);
        drawHandle(ctx, f, videoPoint(a.arrowEndX, a.arrowEndY, vr), 10 * u, h);
        break;
      }
      case "callout": {
        const box = input.labelRect(a);
        if (selected && box) {
          strokeCardPath(ctx, f, continuousRoundedRectPath(insetRect(box, -outset, -outset), radius + outset), 1.5 * u, SELECTION_BLUE, rectCenter(box));
        }
        drawHandle(ctx, f, videoPoint(a.arrowEndX, a.arrowEndY, vr), 10 * u, selected ? 1 : 0.55);
        break;
      }
      case "rectangle":
      case "ellipse": {
        const p1 = videoPoint(smin(a.x, a.arrowEndX), smin(a.y, a.arrowEndY), vr);
        const p2 = videoPoint(smax(a.x, a.arrowEndX), smax(a.y, a.arrowEndY), vr);
        const rect = { x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y };
        if (selected) {
          const ring = insetRect(rect, -outset, -outset);
          const path = a.type === "ellipse" ? cgEllipsePath(ring) : continuousRoundedRectPath(ring, radius + outset);
          strokeCardPath(ctx, f, path, 1.5 * u, SELECTION_BLUE, rectCenter(rect));
        }
        const h = selected ? 1 : 0.55;
        for (const [nx, ny] of [
          [a.x, a.y],
          [a.arrowEndX, a.y],
          [a.x, a.arrowEndY],
          [a.arrowEndX, a.arrowEndY],
        ] as const) {
          drawHandle(ctx, f, videoPoint(nx, ny, vr), 10 * u, h);
        }
        break;
      }
      case "tap": {
        const center = videoPoint(a.x, a.y, vr);
        const size = smax(20, a.fontSize) * u;
        const ring = insetRect({ x: center.x - size / 2, y: center.y - size / 2, width: size, height: size }, u / 2, u / 2);
        strokeCardPath(ctx, f, cgEllipsePath(ring), u, `rgba(255,255,255,${selected ? 0.8 : 0.3})`, center, [3 * u, 3 * u]);
        break;
      }
      default:
        break;
    }
    ctx.restore();
  }
}

/** Keynote grab handle: white disc, hairline grey rim, soft drop shadow
 * (raw CG shadow offset (0, 1) in Y-UP base space = 1 device px UP). */
function drawHandle(ctx: Ctx, f: ChromeFrame, p: Pt, diameter: number, alpha: number): void {
  inCard(ctx, f, p, () => {
    ctx.globalAlpha *= alpha;
    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,0.35)";
    ctx.shadowOffsetY = -1;
    ctx.shadowBlur = 3;
    ctx.beginPath();
    ctx.ellipse(p.x, p.y, diameter / 2, diameter / 2, 0, 0, Math.PI * 2);
    ctx.fillStyle = "#ffffff";
    ctx.fill();
    ctx.restore();
    ctx.beginPath();
    ctx.ellipse(p.x, p.y, diameter / 2 - f.u / 2, diameter / 2 - f.u / 2, 0, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(0,0,0,0.2)";
    ctx.lineWidth = f.u;
    ctx.stroke();
  });
}

// ── Zoom focal reticle ──────────────────────────────────────────────────────

/**
 * The selected zoom block's aim point: ring + four ticks (0.62r…1.38r) + a
 * centre dot, white, 2pt, round caps, black 0.6 shadow (radius 2). Content
 * space with r = 16 / max(1, zoom) — screen-constant while zoomed in.
 */
export function drawFocalReticle(ctx: Ctx, f: ChromeFrame, focal: Pt): void {
  const u = f.u;
  const center = videoPoint(focal.x, focal.y, f.videoRect);
  const zoom = localScale(f.camera, center);
  const r = focalReticleRadius(zoom) * u;
  ctx.save();
  clipToVideo(ctx, f);
  inCard(ctx, f, center, () => {
    ctx.beginPath();
    ctx.arc(center.x, center.y, r, 0, Math.PI * 2);
    for (const [dx, dy] of [
      [1, 0],
      [-1, 0],
      [0, 1],
      [0, -1],
    ] as const) {
      ctx.moveTo(center.x + dx * r * 0.62, center.y + dy * r * 0.62);
      ctx.lineTo(center.x + dx * r * 1.38, center.y + dy * r * 1.38);
    }
    const dotR = r * 0.12;
    ctx.moveTo(center.x + dotR, center.y);
    ctx.arc(center.x, center.y, dotR, 0, Math.PI * 2);
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = (2 / smax(1, zoom)) * u;
    ctx.lineCap = "round";
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 2 * u;
    ctx.stroke();
  });
  ctx.restore();
}

// ── Armed blur-draw marquee (canvas space) ──────────────────────────────────

/** Accent 12% fill, 90% 1.5pt dashed [5, 3] stroke — view space, never zoomed. */
export function drawMarquee(ctx: Ctx, a: Pt, b: Pt, u: number): void {
  const x = Math.min(a.x, b.x);
  const y = Math.min(a.y, b.y);
  const w = Math.abs(b.x - a.x);
  const h = Math.abs(b.y - a.y);
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = "rgba(0,122,255,0.12)";
  ctx.fillRect(x, y, w, h);
  ctx.strokeStyle = "rgba(0,122,255,0.9)";
  ctx.lineWidth = 1.5 * u;
  ctx.setLineDash([5 * u, 3 * u]);
  ctx.strokeRect(x, y, w, h);
  ctx.restore();
}

/** Where a card point lands on the overlay (for tests / probes). */
export function chromeAnchor(f: ChromeFrame, p: Pt): Pt {
  return cardToCanvas(f.camera, p);
}
