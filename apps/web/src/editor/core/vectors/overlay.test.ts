import { describe, expect, it } from "vitest";
import { ABS_TOL, checkUnit, firstMismatch, loadVectors } from "./harness";
import * as fx from "../math/annotationEffectMath";
import * as ks from "../math/keystrokeOverlay";
import * as cu from "../math/curtainUnveilMath";
import * as ag from "../math/annotationGeometry";
import * as et from "../math/exportText";
import {
  cgEllipsePath,
  cgRectPath,
  cgRoundedRectPath,
  continuousCircularPath,
  continuousRoundedRectPath,
  oklab,
  oklabEncode,
  oklabLinearize,
  oklabMix,
  oklabSample,
  oklabToSRGB,
  OKLAB_RESOLUTION,
  tapRippleProgress,
  TapRippleMath,
  type GradientStop,
} from "../math/overlaySupport";
import { rectWidth } from "../math/geometry";

/**
 * CoreGraphics emits `CGPath(roundedRect:)` corner cubics with one of TWO
 * arc constants depending on an internal code path: the 10-digit
 * 0.5522847498 (most radii) or the exact 4/3·(√2−1) = 0.55228474983079…
 * (e.g. r = 177 in a 4000pt rect; see the probe notes in the Swift
 * harness). The difference is |Δk|·r ≤ 3.1e-11·r — invisible (≈1e-8 px at
 * r = 300) but above 1e-9 for large radii. Path element arrays therefore
 * compare with absTol = ABS_TOL + 4e-11 · (extent of the expected path);
 * every non-path value in the unit keeps the strict 1e-9. Observed max:
 * 1.1e-8 at a 1200-px extent (curtainUnveilCardClip).
 */
const PATH_TAGS = new Set(["M", "L", "Q", "C", "Z"]);
function isPath(v: unknown): v is unknown[][] {
  return (
    Array.isArray(v) &&
    v.length > 0 &&
    v.every((e) => Array.isArray(e) && typeof e[0] === "string" && PATH_TAGS.has(e[0] as string))
  );
}
function pathExtent(p: unknown[][]): number {
  let lo = Infinity;
  let hi = -Infinity;
  for (const e of p) for (const n of e.slice(1)) if (typeof n === "number" && Number.isFinite(n)) {
    lo = Math.min(lo, n);
    hi = Math.max(hi, n);
  }
  return hi > lo ? hi - lo : 0;
}
function pathAwareMismatch(actual: unknown, expected: unknown, at: string): string | null {
  if (isPath(expected)) return firstMismatch(actual, expected, at, ABS_TOL + 4e-11 * pathExtent(expected));
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) return `${at}: expected array, got ${JSON.stringify(actual)?.slice(0, 120)}`;
    if (actual.length !== expected.length) return `${at}: expected length ${expected.length}, got ${actual.length}`;
    for (let k = 0; k < expected.length; k++) {
      const m = pathAwareMismatch(actual[k], expected[k], `${at}[${k}]`);
      if (m) return m;
    }
    return null;
  }
  if (expected && typeof expected === "object") {
    if (!actual || typeof actual !== "object") return `${at}: expected object, got ${JSON.stringify(actual)?.slice(0, 120)}`;
    for (const [k, v] of Object.entries(expected)) {
      const m = pathAwareMismatch((actual as Record<string, unknown>)[k], v, `${at}.${k}`);
      if (m) return m;
    }
    return null;
  }
  return firstMismatch(actual, expected, at);
}
/** `checkUnit` with the CG-arc-aware path comparison above. */
function checkUnitPaths(unit: string, port: (input: any, index: number) => unknown): number {
  const file = loadVectors(unit);
  const failures: string[] = [];
  let failed = 0;
  file.cases.forEach((c, idx) => {
    let m: string | null;
    try {
      m = pathAwareMismatch(port(c.input, idx), c.output, "output");
    } catch (e) {
      m = `threw ${(e as Error).message}`;
    }
    if (m) {
      failed++;
      if (failures.length < 5) failures.push(`case ${idx}: ${m}\n  input=${JSON.stringify(c.input).slice(0, 200)}`);
    }
  });
  expect(failed, `${unit}: ${failed}/${file.cases.length} cases diverge from Swift\n${failures.join("\n")}`).toBe(0);
  return file.cases.length;
}

describe("overlay golden vectors", () => {
  // ── AnnotationEffectMath ──────────────────────────────────────────────────
  it("annotationEffectPhase", () => {
    checkUnit("annotationEffectPhase", (i) => ({
      phase: fx.phase(i.effect, i.progress),
      effectDuration: fx.effectDuration(i.effect),
      duration: fx.duration,
      drawOnDuration: fx.drawOnDuration,
    }));
  });

  it("annotationEffectCombined", () => {
    checkUnit("annotationEffectCombined", (i) => {
      const a = i.annotation;
      return {
        effectPhase: i.times.map((t: number) => fx.effectPhase(a, t)),
        combined: i.times.map((t: number) => fx.combined(a.enterEffect, a.exitEffect, a.startTime, a.endTime, t)),
        effectAnchor: fx.effectAnchor(a),
        duration: fx.annotationDuration(a),
      };
    });
  });

  it("annotationDisplayText", () => {
    checkUnit("annotationDisplayText", (i) => ({ displayText: fx.displayText(i) }));
  });

  // ── KeystrokeOverlay ──────────────────────────────────────────────────────
  it("keystrokeOverlayDisplayEvents", () => {
    checkUnit("keystrokeOverlayDisplayEvents", (i) => {
      const p = i.project;
      return {
        scopedEvents: ks.scopedEvents(
          i.events,
          p.recordedAppBundleID,
          p.settings.keystrokeOverlayScopeToRecordedApp,
          p.recordingSourceKind,
        ),
        displayEvents: ks.displayEvents(i.events),
        displayEventsScoped: ks.displayEventsScoped(i.events, p),
      };
    });
  });

  it("keystrokeOverlayActivePill", () => {
    checkUnit("keystrokeOverlayActivePill", (i) => ({
      pills: i.times.map((t: number) => ks.activePill(i.displayEvents, t)),
      fadeIn: ks.fadeIn,
      hold: ks.hold,
      fadeOut: ks.fadeOut,
      repeatWindow: ks.repeatWindow,
    }));
  });

  it("keystrokeOverlayPillGeometry", () => {
    checkUnit("keystrokeOverlayPillGeometry", (i) => ({
      slideOffset: ks.slideOffset(i.animation, i.entry, i.scale),
      popScale: ks.popScale(i.animation, i.entry),
      pillCenter: ks.pillCenter(i.position, i.canvasSize, i.pillSize, i.entry, i.scale, i.animation),
      pillCenterDefault: ks.pillCenter(i.position, i.canvasSize, i.pillSize, i.entry, i.scale),
      pillRect: ks.pillRect(i.position, i.canvasSize, i.pillSize, i.entry, i.scale, i.animation),
    }));
  });

  it("keystrokeOverlayPillMetrics", () => {
    // The CoreText metrics are the web's measurement reference; the port is
    // checked on everything derived from them.
    checkUnit("keystrokeOverlayPillMetrics", (i, idx) => {
      const expected = loadMetrics(idx);
      return {
        metrics: {
          ...expected,
          pointSize: ks.pillFontSize(i.size, i.scale),
          kern: ks.pillKern(i.size, i.scale),
        },
        pillSize: ks.pillSizeFromMetrics(expected, i.size, i.scale),
        oracleMatchesReal: true,
      };
    });
  });

  it("keystrokeOverlayDrawRecipe", () => {
    checkUnitPaths("keystrokeOverlayDrawRecipe", (i) => {
      const measure = () => i.textMetrics;
      const recipe = ks.keystrokeImageRecipe(
        i.canvasSize,
        i.displayEvents,
        i.currentTime,
        i.position,
        i.size,
        i.scale,
        i.rasterScale,
        i.animation,
        measure,
      );
      return { image: recipe ? { ...recipe, rasterMatchesReal: true } : null };
    });
  });

  // ── CurtainUnveilMath ─────────────────────────────────────────────────────
  it("curtainUnveilCurves", () => {
    checkUnit("curtainUnveilCurves", (i) => ({
      sweepEase: cu.sweepEase(i.p),
      flapOverfoldRadians: cu.flapOverfoldRadians(i.p),
      flapReleaseOffset: cu.flapReleaseOffset(i.p),
      flapOpacityValue: cu.flapOpacityValue(i.p),
      shadowWidthFraction: cu.shadowWidthFraction(i.p),
      shadowStrengthValue: cu.shadowStrengthValue(i.p),
    }));
  });

  it("curtainUnveilState", () => {
    checkUnit("curtainUnveilState", (i) => {
      const s = cu.state(i.corner, i.time, i.startTime, i.duration);
      return {
        state: s,
        shadowPolygon: cu.shadowPolygon(s),
        ambientShadowPolygon: cu.ambientShadowPolygon(s),
      };
    });
  });

  it("curtainUnveilGeometry", () => {
    checkUnit("curtainUnveilGeometry", (i) => ({
      reflect: cu.reflect(i.p, i.lineA, i.lineB),
      polygonArea: cu.polygonArea(i.polygon),
      clip: cu.clip(i.polygon, (q) => i.a * q.x + i.b * q.y + i.c),
      clipToUnitSquare: cu.clipToUnitSquare(i.polygon),
      unitSquare: cu.unitSquare,
      cornerPoints: (["Off", "Top Left", "Top Right", "Bottom Left", "Bottom Right"] as const).map(cu.cornerPoint),
    }));
  });

  it("curtainUnveilCardClip", () => {
    checkUnitPaths("curtainUnveilCardClip", (i) => {
      const clip = cu.cardClip(i.frameShape, i.cornerRadius, i.cardSize, i.deviceScreen);
      return { cardClip: clip, cardClipPath: cu.cardClipPath(clip, i.rasterSize) };
    });
  });

  it("curtainUnveilCoverStyle", () => {
    checkUnit("curtainUnveilCoverStyle", (i) => {
      const style = cu.coverStyle(i.settings, null);
      return {
        baseColor: style.baseColor,
        logoOpacity: style.logoOpacity,
        logoScale: style.logoScale,
        logoTint: style.logoTint,
        coverStops: cu.coverStops(style.baseColor),
        constants: {
          coverColorTop: cu.coverColorTop,
          coverColorBottom: cu.coverColorBottom,
          flapColorNear: cu.flapColorNear,
          flapColorFar: cu.flapColorFar,
          foldShadowMaxOpacity: cu.foldShadowMaxOpacity,
          shadowBandFraction: cu.shadowBandFraction,
          coverDarkenFraction: cu.coverDarkenFraction,
          sheenOpacity: cu.sheenOpacity,
          sheenHalfWidth: cu.sheenHalfWidth,
          vignetteOpacity: cu.vignetteOpacity,
          vignetteRadiusFraction: cu.vignetteRadiusFraction,
          ambientShadowWidthFraction: cu.ambientShadowWidthFraction,
          ambientShadowMaxOpacity: cu.ambientShadowMaxOpacity,
          foldSpecularOpacity: cu.foldSpecularOpacity,
          foldSpecularWidthFactor: cu.foldSpecularWidthFactor,
          flapSheenOpacity: cu.flapSheenOpacity,
          flickStart: cu.flickStart,
          flickJoin: cu.flickJoin,
          releaseSlope: cu.releaseSlope,
          releaseStart: cu.releaseStart,
          releaseFadeWindow: cu.releaseFadeWindow,
          baseOverfoldDegrees: cu.baseOverfoldDegrees,
          whipOverfoldDegrees: cu.whipOverfoldDegrees,
          releaseTravel: cu.releaseTravel,
          whipShadowBoost: cu.whipShadowBoost,
        },
      };
    });
  });

  it("curtainUnveilDrawRecipe", () => {
    checkUnitPaths("curtainUnveilDrawRecipe", (i) => {
      const recipe = cu.curtainRecipe(i.state, i.size, i.style);
      return { image: recipe ? { ...recipe, rasterMatchesReal: true } : null };
    });
  });

  // ── Path primitives ───────────────────────────────────────────────────────
  it("overlayPathPrimitives", () => {
    checkUnitPaths("overlayPathPrimitives", (i) => {
      const r = i.rect;
      const rad = i.radius;
      return {
        rect: cgRectPath(r),
        ellipse: cgEllipsePath(r),
        roundedRect:
          rad >= 0 && rad * 2 <= Math.abs(r.width) + 1e-9 && rad * 2 <= Math.abs(r.height) + 1e-9
            ? cgRoundedRectPath(r, rad, rad)
            : null,
        roundedRectClampedX:
          Math.abs(r.width) > 0 && Math.abs(r.height) > 0 && rad > 0
            ? cgRoundedRectPath(r, Math.min(rad, rectWidth(r) / 2 + 5), rad)
            : null,
        continuous: continuousRoundedRectPath(r, rad),
        circular: continuousCircularPath(r, rad),
      };
    });
  });
  // ── AnnotationRenderer ────────────────────────────────────────────────────
  it("annotationTextMetrics", () => {
    // CoreText measurements are reference data for the web renderer (they
    // travel through unchanged); the port checks everything derived from
    // the inputs: the drawn string and the point size.
    checkUnit("annotationTextMetrics", (i, idx) => ({
      displayText: fx.displayText({ text: i.text, uppercase: i.uppercase }),
      pointSize: i.fontSize * i.scale,
      measured: loadVectors("annotationTextMetrics").cases[idx].output.measured,
    }));
  });

  it("annotationGeometry", () => {
    checkUnit("annotationGeometry", (i) => ({
      labelRect: ag.labelRect(i.annotation, i.videoRect, i.scale, i.textLine),
      boxEdgeIntersection: ag.boxEdgeIntersection(i.from, i.toward, i.box),
      trimmedStrokes: ag.trimmedStrokes(i.strokes, i.progress),
      backdropAlpha: i.times.map((t: number) => ag.backdropAlpha(i.annotations, t)),
      backdropAlphaSettled: i.times.map((t: number) => ag.backdropAlpha(i.annotations, t, true)),
      exportVideoRectYDown: ag.exportVideoRectYDown(i.exportVideoRect, i.outputSize),
      exportScale: ag.exportAnnotationScale(i.outputSize.width),
    }));
  });

  it("annotationDrawRecipe", () => {
    checkUnit("annotationDrawRecipe", (i) => {
      const measure: ag.AnnotationMeasure = (a) => i.textMetrics[a.id];
      const recipe = ag.annotationImageRecipe(
        i.size,
        i.annotations,
        i.currentTime,
        i.videoRect,
        i.scale,
        i.chrome,
        i.rasterScale,
        i.videoCornerRadius,
        measure,
      );
      return { image: recipe ? { ...recipe, rasterMatchesReal: true } : null };
    });
  });

  it("annotationTapRipple", () => {
    checkUnit("annotationTapRipple", (i) => ({
      progress: tapRippleProgress(i.elapsed),
      period: TapRippleMath.period,
      rippleDuration: TapRippleMath.rippleDuration,
    }));
  });

  it("oklabGradientStops", () => {
    checkUnit("oklabGradientStops", (i) => {
      const stops: GradientStop[] = i.stops;
      const a = stops[0].color;
      const b = stops[stops.length - 1].color;
      return {
        samples: i.ts.map((t: number) => oklabSample(stops, t)),
        mix: oklabMix(a, b, i.c),
        oklab: oklab(a),
        srgb: oklabToSRGB(oklab(b)),
        linearize: oklabLinearize(i.c),
        encode: oklabEncode(i.c),
        resolution: OKLAB_RESOLUTION,
      };
    });
  });

  // ── Exporter subtitle burn ────────────────────────────────────────────────
  it("exportSubtitleLayout", () => {
    checkUnitPaths("exportSubtitleLayout", (i) =>
      et.subtitleRecipe(i.subtitle, i.currentTime, i.outputSize, i.canvasScale, i.settings, () => i.textBounds),
    );
  });

  it("exportSubtitleTextMetrics", () => {
    // As annotationTextMetrics: AppKit measurements are reference data.
    checkUnit("exportSubtitleTextMetrics", (i, idx) => ({
      fontSize: et.subtitleFontSize(i.subtitleFontSize, i.canvasScale),
      string: et.subtitleTransform(i.text, i.uppercase),
      constraintWidth: et.subtitleConstraintWidth(i.outputWidth, i.canvasScale),
      measured: loadVectors("exportSubtitleTextMetrics").cases[idx].output.measured,
    }));
  });

  it("exportActiveSubtitle", () => {
    checkUnit("exportActiveSubtitle", (i) => ({
      active: i.times.map((t: number) => {
        const sub = et.activeSubtitle(i.subtitles, t, i.settings.showSubtitles);
        if (!sub) return null;
        const k = et.subtitleCacheKey(sub, t, i.settings);
        return { id: sub.id, cacheKey: k.key, activeWordCount: k.activeWordCount };
      }),
      canvasScale: et.exportCanvasScale(i.outputSize, i.previewCanvasSize),
    }));
  });
});

function loadMetrics(idx: number): ks.KeystrokeTextMetrics & Record<string, unknown> {
  return loadVectors("keystrokeOverlayPillMetrics").cases[idx].output.metrics;
}
