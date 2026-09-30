/**
 * Port of Services/CursorPhysicsMath.swift `CursorPhysicsMath` — cursor
 * motion physics (tilt, squash-and-stretch, body drag) as a PURE function of
 * the recorded path and the timeline clock: `pose(events:at:coordinateSize:
 * videoRect:spriteHeight:tilt:stretch:drag:weight:)`, `Pose.yFlipped()`,
 * `Pose.isIdentity`, `affineTransform(pose:tip:spriteHeight:)` + constants.
 *
 * Spaces: poses are produced in Y-DOWN view space. A Y-up consumer (the Mac
 * exporter's CIImage space) uses `yFlipped(pose)` — negated rotation,
 * bodyOffset.dy and motionAngle. The transform's FIXED POINT is `tip`
 * (`M(tip) == tip` by construction), in the same space as the pose.
 *
 * Locked to Swift by `cursorPhysicsPose` and `cursorPhysicsTransform`.
 * libm: `atan2`, `sin`/`cos` (inside CGAffineTransform rotations) and `sqrt`
 * are used; sqrt is correctly rounded everywhere, atan2/sin/cos may differ by
 * ≤1 ulp between Darwin libm and V8 — far inside the 1e-9 contract.
 */
import type { CursorEvent, Point, Rect, Size } from "../model/types";
import {
  concatTransform,
  identityTransform,
  rectHeight,
  rectWidth,
  rotatedBy,
  scaledBy,
  translationTransform,
  type AffineTransform,
} from "./geometry";
import { interpolate } from "./cursorSmoother";
import { smax, smin } from "./swift";

/** Velocity sampling window (s) — central difference over a fixed interval. */
export const velocityWindow = 1.0 / 30.0;
/** Response caps at full sliders and weight 1. */
export const maxTiltRadians = (18 * Math.PI) / 180;
export const maxStretch = 0.3;
/** Max body trail, as a fraction of the cursor sprite's height. */
export const maxDragFraction = 0.45;
/** Speed at which each response saturates, in VIDEO-WIDTHS per second. */
export const saturationSpeed = 1.25;

/** `CGVector`. */
export interface Vector {
  dx: number;
  dy: number;
}

/** `CursorPhysicsMath.Pose`. */
export interface Pose {
  /** Sprite-body trail, view points, Y-down (folded into the tip-pinned shear). */
  bodyOffset: Vector;
  /** Lean into horizontal motion. Y-down positive = clockwise on screen. */
  rotation: number;
  /** Scale along the motion direction (perpendicular compressed by 1/√stretch). */
  stretch: number;
  /** Motion direction the stretch is aligned to. */
  motionAngle: number;
}

/** `Pose()` — the identity pose. */
export function identityPose(): Pose {
  return { bodyOffset: { dx: 0, dy: 0 }, rotation: 0, stretch: 1, motionAngle: 0 };
}

/** `pose.isIdentity` (`bodyOffset == .zero && rotation == 0 && stretch == 1`;
 * −0 compares equal to 0, like Swift). */
export function isIdentity(pose: Pose): boolean {
  return pose.bodyOffset.dx === 0 && pose.bodyOffset.dy === 0 && pose.rotation === 0 && pose.stretch === 1;
}

/** `pose.yFlipped()` — the same pose for a Y-up consumer. */
export function yFlipped(pose: Pose): Pose {
  return {
    bodyOffset: { dx: pose.bodyOffset.dx, dy: -pose.bodyOffset.dy },
    rotation: -pose.rotation,
    stretch: pose.stretch,
    motionAngle: -pose.motionAngle,
  };
}

/** `CursorPhysicsMath.pose(events:at:coordinateSize:videoRect:spriteHeight:tilt:stretch:drag:weight:)`. */
export function pose(
  events: readonly CursorEvent[],
  time: number,
  coordinateSize: Size,
  videoRect: Rect,
  spriteHeight: number,
  tilt: number,
  stretch: number,
  drag: number,
  weight: number,
): Pose {
  const tiltAmount = smax(0, smin(1, tilt));
  const stretchAmount = smax(0, smin(1, stretch));
  const dragAmount = smax(0, smin(1, drag));
  const weightAmount = smax(0.5, smin(3, weight));
  if (
    !(
      (tiltAmount > 0 || stretchAmount > 0 || dragAmount > 0) &&
      events.length > 1 &&
      coordinateSize.width > 0 &&
      coordinateSize.height > 0 &&
      rectWidth(videoRect) > 0 &&
      rectHeight(videoRect) > 0
    )
  ) {
    return identityPose();
  }

  // Central difference around `time`; heavier cursors sample a wider window.
  const dt = velocityWindow * weightAmount;
  const before = interpolate(events, time - dt / 2);
  const after = interpolate(events, time + dt / 2);

  // Velocity in VIDEO-WIDTHS per second.
  const vw = rectWidth(videoRect);
  const scaleX = vw / coordinateSize.width;
  const scaleY = rectHeight(videoRect) / coordinateSize.height;
  const vx = ((after.x - before.x) * scaleX) / vw / dt;
  const vy = ((after.y - before.y) * scaleY) / vw / dt;
  const speed = Math.sqrt(vx * vx + vy * vy);
  if (!(speed > 0.002)) return identityPose();

  const response = smin(1, (speed * weightAmount) / saturationSpeed);

  const p = identityPose();
  p.motionAngle = Math.atan2(vy, vx);
  // Tilt follows HORIZONTAL motion only.
  const horizontal = smax(-1, smin(1, (vx * weightAmount) / saturationSpeed));
  p.rotation = maxTiltRadians * horizontal * tiltAmount;
  p.stretch = 1 + maxStretch * response * stretchAmount;
  const trail = maxDragFraction * spriteHeight * response * dragAmount;
  p.bodyOffset = {
    dx: -(vx / speed) * trail,
    dy: -(vy / speed) * trail,
  };
  return p;
}

/**
 * `CursorPhysicsMath.affineTransform(pose:tip:spriteHeight:)` — CG layout
 * (x' = a·x + c·y + tx, y' = b·x + d·y + ty):
 *
 *   linear = R(motionAngle) → S(stretch, 1/max(1e-4, √stretch)) → R(−motionAngle) → R(rotation)
 *            (each step is CG `rotated(by:)` / `scaledBy` = pre-concatenation)
 *            then `.concatenating(shear)` with shear = (a 1, b dy/h, c dx/h, d 1)
 *            when bodyOffset ≠ 0 and spriteHeight > 0;
 *   result = T(−tip) · linear · T(tip)   (`concatenating` order: apply left first).
 */
export function affineTransform(p: Pose, tip: Point, spriteHeight: number): AffineTransform {
  if (isIdentity(p)) return { ...identityTransform };

  let linear = rotatedBy(identityTransform, p.motionAngle);
  linear = scaledBy(linear, p.stretch, 1 / smax(0.0001, Math.sqrt(p.stretch)));
  linear = rotatedBy(linear, -p.motionAngle);
  linear = rotatedBy(linear, p.rotation);

  if (!(p.bodyOffset.dx === 0 && p.bodyOffset.dy === 0) && spriteHeight > 0) {
    const shear: AffineTransform = {
      a: 1,
      b: p.bodyOffset.dy / spriteHeight,
      c: p.bodyOffset.dx / spriteHeight,
      d: 1,
      tx: 0,
      ty: 0,
    };
    linear = concatTransform(linear, shear);
  }

  return concatTransform(
    concatTransform(translationTransform(-tip.x, -tip.y), linear),
    translationTransform(tip.x, tip.y),
  );
}
