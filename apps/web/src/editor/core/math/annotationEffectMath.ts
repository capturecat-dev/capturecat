/**
 * Port of Models/Annotation.swift — `AnnotationEffectMath` (Phase, duration,
 * drawOnDuration, effectDuration, phase(effect:progress:),
 * combined(enter:exit:start:end:at:)) plus the `Annotation` helpers both
 * renderers read: `effectAnchor`, `displayText`, `effectPhase(at:)`, `duration`.
 *
 * AnnotationEffectMath is a CLAUDE.md §2 shared source of truth (preview ==
 * export): progress derives only from the timeline clock, so scrub, playback
 * and export agree.
 *
 * Locked to Swift by the golden-vector units `annotationEffectPhase`,
 * `annotationEffectCombined` and `annotationDisplayText`
 * (apps/macos/CaptureCat/Services/WebVectors/WebVectors+Overlay.swift).
 *
 * `displayText`: Swift `String.uppercased()` is Unicode full (locale-free)
 * case mapping; JS `String.prototype.toUpperCase()` is the same mapping
 * (SpecialCasing unconditional: ß → SS, ŉ → ʼN, ΐ → Ϊ́, ﬁ → FI, ǆ/ǅ → Ǆ;
 * Turkish i → I, ı → I, İ unchanged). The `annotationDisplayText` unit
 * vectors those strings — any Unicode-version drift between the two engines
 * would fail it.
 */
import type { Annotation, Point } from "../model/types";
import type { AnnotationEffect } from "../model/enums";
import { smax, smin } from "./swift";

/** `AnnotationEffectMath.Phase` — defaults are the settled (fully shown) look. */
export interface AnnotationEffectPhase {
  alpha: number;
  scale: number;
  /** Positive = downward, in canvas points at 1× (the exporter scales it). */
  offsetY: number;
  /** Fraction of the drawing's strokes revealed (Draw On only). */
  strokeProgress: number;
}

/** `AnnotationEffectMath.Phase()` */
export function settledPhase(): AnnotationEffectPhase {
  return { alpha: 1, scale: 1, offsetY: 0, strokeProgress: 1 };
}

function makePhase(p: Partial<AnnotationEffectPhase>): AnnotationEffectPhase {
  return { ...settledPhase(), ...p };
}

/** `AnnotationEffectMath.duration` */
export const duration = 0.3;
/** `AnnotationEffectMath.drawOnDuration` */
export const drawOnDuration = 1.0;

/** `AnnotationEffectMath.effectDuration(_:)` */
export function effectDuration(effect: AnnotationEffect): number {
  return effect === "Draw On" ? drawOnDuration : duration;
}

/** `AnnotationEffectMath.phase(effect:progress:)` — progress 0 = fully out, 1 = fully shown. */
export function phase(effect: AnnotationEffect, p: number): AnnotationEffectPhase {
  const t = smin(1, smax(0, p));
  switch (effect) {
    case "None":
      return settledPhase();
    case "Fade":
      return makePhase({ alpha: t });
    case "Pop": {
      // Ease-out-back overshoot, analytic.
      const c = 1.70158;
      const u = t - 1;
      const s = 1 + (c + 1) * u * u * u + c * u * u;
      return makePhase({ alpha: smin(1, t * 2), scale: smax(0.001, 0.4 + 0.6 * s) });
    }
    case "Scale":
      return makePhase({ alpha: t, scale: smax(0.001, t) });
    case "Slide Up": {
      const e = 1 - Math.pow(1 - t, 3);
      return makePhase({ alpha: t, offsetY: (1 - e) * 28 });
    }
    case "Drop": {
      const e = 1 - Math.pow(1 - t, 3);
      return makePhase({ alpha: t, offsetY: -(1 - e) * 44 });
    }
    case "Explode":
      return makePhase({ alpha: t, scale: 1 + (1 - t) * 0.9 });
    case "Draw On":
      return makePhase({ alpha: smin(1, t * 5), strokeProgress: t });
  }
}

/** `AnnotationEffectMath.combined(enter:exit:start:end:at:)` */
export function combined(
  enter: AnnotationEffect,
  exit: AnnotationEffect,
  start: number,
  end: number,
  time: number,
): AnnotationEffectPhase {
  const inP = enter === "None" ? 1 : smin(1, smax(0, (time - start) / effectDuration(enter)));
  const outP = exit === "None" ? 1 : smin(1, smax(0, (end - time) / effectDuration(exit)));
  if (inP < 1) return phase(enter, inP);
  if (outP < 1) return phase(exit, outP);
  return settledPhase();
}

type AnchorFields = Pick<Annotation, "type" | "x" | "y" | "arrowEndX" | "arrowEndY">;

/** `Annotation.effectAnchor` — normalized point the build effects scale about. */
export function effectAnchor(a: AnchorFields): Point {
  switch (a.type) {
    case "arrow":
    case "rectangle":
    case "ellipse":
      return { x: (a.x + a.arrowEndX) / 2, y: (a.y + a.arrowEndY) / 2 };
    default:
      return { x: a.x, y: a.y };
  }
}

/** `Annotation.displayText` — the string both renderers draw. */
export function displayText(a: Pick<Annotation, "text" | "uppercase">): string {
  return a.uppercase ? a.text.toUpperCase() : a.text;
}

/** `Annotation.effectPhase(at:)` */
export function effectPhase(
  a: Pick<Annotation, "enterEffect" | "exitEffect" | "startTime" | "endTime">,
  time: number,
): AnnotationEffectPhase {
  return combined(a.enterEffect, a.exitEffect, a.startTime, a.endTime, time);
}

/** `Annotation.duration` */
export function annotationDuration(a: Pick<Annotation, "startTime" | "endTime">): number {
  return a.endTime - a.startTime;
}
