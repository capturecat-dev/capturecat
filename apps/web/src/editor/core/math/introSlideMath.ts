/**
 * Port of Services/IntroSlideMath.swift — `IntroSlideStyle.vector` (as
 * `introSlideVector`; the persisted enum itself lives in ../model/enums) and
 * `enum IntroSlideMath`: State, travel / startScale / depthStartScale /
 * depthStartPitch, `state(style:at:startTime:duration:bounce:depth:speed:)`,
 * and the private helpers easeOutBack, pulling, arriving.
 *
 * Locked to Swift by the `introSlideMath` golden vectors (the REAL
 * `IntroSlideMath.state` + `IntroSlideStyle.vector`) and
 * `introSlideMathHelpersOracle` (verbatim oracle of the three private
 * helpers) in WebVectors+CameraMotion.swift.
 *
 * Deterministic from OUTPUT time (t = 0 is the trim start). The state rides
 * the card transform on both renderers: `offset` is a canvas-fraction
 * translation (Y-down, same space as the card offset), `scale` scales the
 * card, and `pitch` (degrees, TiltMath sign convention) is applied as a
 * perspective warp about the canvas centre through the shared TiltMath
 * homography (./tiltMath projectionTransform).
 */
import type { Point } from "../model/types";
import type { IntroSlideStyle } from "../model/enums";
import { smax, smin } from "./swift";

/** `IntroSlideMath.State` */
export interface IntroSlideState {
  /** Canvas-fraction translation, Y-down. */
  offset: Point;
  scale: number;
  /** Forward-tip angle, DEGREES. */
  pitch: number;
  /** False once the entrance has fully settled. */
  active: boolean;
}

/** `IntroSlideMath.State()` (defaults). */
export function restingIntroSlideState(): IntroSlideState {
  return { offset: { x: 0, y: 0 }, scale: 1, pitch: 0, active: false };
}

/** `IntroSlideStyle.vector` — unit direction the card ARRIVES FROM
 * (canvas fractions, Y-down). */
export function introSlideVector(style: IntroSlideStyle): Point {
  switch (style) {
    case "Off":
      return { x: 0, y: 0 };
    case "Top":
      return { x: 0, y: -1 };
    case "Bottom":
      return { x: 0, y: 1 };
    case "Left":
      return { x: -1, y: 0 };
    case "Right":
      return { x: 1, y: 0 };
  }
}

export const travel = 1.2;
export const startScale = 0.9;
export const depthStartScale = 0.42;
export const depthStartPitch = 20;

/**
 * `IntroSlideMath.state(style:at:startTime:duration:bounce:depth:speed:)`.
 * Argument order is Swift's; pass `undefined` for `startTime` to use its
 * default (0).
 */
export function state(
  style: IntroSlideStyle,
  outputTime: number,
  startTime: number = 0,
  rawDuration: number,
  bounce = 0.5,
  depth = false,
  speed = 1.0,
): IntroSlideState {
  const duration = rawDuration / smax(1.0, speed);
  if (!(style !== "Off" && duration > 0.05)) return restingIntroSlideState();
  const v = introSlideVector(style);
  const entryScale = depth ? depthStartScale : startScale;
  const entryPitch = depth ? depthStartPitch : 0;
  if (startTime <= 0.01) {
    const p = outputTime / duration;
    if (!(p < 1)) return restingIntroSlideState();
    if (!(p > 0)) {
      return {
        offset: { x: v.x * travel, y: v.y * travel },
        scale: entryScale,
        pitch: entryPitch,
        active: true,
      };
    }
    if (depth) return pulling(p, v, bounce);
    return arriving(easeOutBack(p, bounce), v, entryScale, entryPitch);
  }
  // Mid-timeline: out (0…0.45), offscreen beat (0.45…0.55), in (0.55…1).
  const p = (outputTime - startTime) / duration;
  if (!(p > 0 && p < 1)) return restingIntroSlideState();
  if (p < 0.45) {
    const q = p / 0.45;
    const eased = q * q * (3 - 2 * q);
    return {
      offset: { x: v.x * travel * eased, y: v.y * travel * eased },
      scale: 1 + (entryScale - 1) * eased,
      pitch: entryPitch * eased,
      active: true,
    };
  }
  if (p < 0.55) {
    return {
      offset: { x: v.x * travel, y: v.y * travel },
      scale: entryScale,
      pitch: entryPitch,
      active: true,
    };
  }
  if (depth) return pulling((p - 0.55) / 0.45, v, bounce);
  return arriving(easeOutBack((p - 0.55) / 0.45, bounce), v, entryScale, entryPitch);
}

/** `IntroSlideMath.easeOutBack(_:bounce:)` (private in Swift). */
export function easeOutBack(p: number, bounce: number): number {
  const c1 = 3.4 * smax(0, smin(1, bounce));
  const c3 = c1 + 1;
  return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2);
}

/** `IntroSlideMath.pulling(_:_:bounce:)` (private in Swift) — depth entrance. */
export function pulling(p: number, v: Point, bounce: number): IntroSlideState {
  const slide = easeOutBack(p, bounce);
  const remaining = 1 - slide;
  const q = smax(0, smin(1, p));
  const pull = q * q * (3 - 2 * q);
  return {
    offset: { x: v.x * travel * remaining, y: v.y * travel * remaining },
    scale: depthStartScale + (1 - depthStartScale) * pull,
    pitch: depthStartPitch * (1 - pull),
    active: true,
  };
}

/** `IntroSlideMath.arriving(_:_:startScale:startPitch:)` (private in Swift). */
export function arriving(e: number, v: Point, startScale: number, startPitch: number): IntroSlideState {
  const remaining = 1 - e;
  const settled = smax(0, smin(1, e));
  return {
    offset: { x: v.x * travel * remaining, y: v.y * travel * remaining },
    scale: startScale + (1 - startScale) * settled,
    pitch: startPitch * (1 - settled),
    active: true,
  };
}
