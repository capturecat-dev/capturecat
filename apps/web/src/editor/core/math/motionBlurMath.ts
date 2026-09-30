/**
 * Port of Services/MotionBlurMath.swift (`enum MotionBlurMath`) —
 * CameraSample, Blur, the constants, `mappedCenter` (private in Swift) and
 * `blur(previous:current:dt:strength:)`.
 *
 * Locked to Swift by the `motionBlurMath` golden vectors
 * (WebVectors+CameraMotion.swift).
 *
 * Inputs are two adjacent camera samples on the OUTPUT timeline (the
 * exporter feeds consecutive `CameraKey`s — see ./exportCameraPath) and the
 * output-time gap between them. Stateless and closed-form.
 *
 * GPU contract — what the Mac exporter does with the result
 * (Services/VideoExporter.swift ≈2131–2165 at da569841):
 * - only when `settings.motionBlur` and `frameIndex > 0`; `previous`/`current`
 *   are `cameraPath[frameIndex-1]` / `cameraPath[frameIndex]` (zoom, focalX,
 *   focalY, offsetX, offsetY of the exporter CameraKeys), `dt` is the OUTPUT
 *   frame-time delta, `strength` is `settings.motionBlurStrength`;
 * - applied to the CARD layer after zoom/offset/intro-slide and BEFORE
 *   compositing over the background (the backdrop stays crisp);
 * - CIMotionBlur with `inputImage = card.clampedToExtent()`,
 *   `inputRadius = radius × outputWidth` (pixels), `inputAngle = -angle`
 *   (MotionBlurMath is Y-DOWN, Core Image is Y-up), then cropped back to the
 *   output rect. A Y-down WebGPU directional-blur pass uses `angle` as-is and
 *   must reproduce CIMotionBlur's kernel and edge clamping (render parity is
 *   gated by the exporter frames, not by these vectors).
 */
import { smax, smin } from "./swift";

/** `MotionBlurMath.CameraSample` */
export interface CameraSample {
  zoom: number;
  focalX: number;
  focalY: number;
  offsetX: number;
  offsetY: number;
}

/** `MotionBlurMath.Blur` */
export interface Blur {
  /** Fraction of canvas width. 0 when inactive. */
  radius: number;
  /** Radians, Y-down canvas space. */
  angle: number;
  active: boolean;
}

/** `Blur.none` (a fresh copy). */
export function noBlur(): Blur {
  return { radius: 0, angle: 0, active: false };
}

export const velocityThreshold = 0.06;
export const velocityAtMax = 1.2;
export const maxRadiusFraction = 0.025;
export const zoomLeverArm = 0.25;
export const maxSampleGap = 0.5;

/** `MotionBlurMath.mappedCenter(_:)` (private in Swift) — where the canvas
 * centre lands after the card transform (canvas fractions, Y-down). */
export function mappedCenter(s: CameraSample): { x: number; y: number } {
  const q = 0.5;
  const x = s.focalX + s.zoom * (q - s.focalX) + s.offsetX;
  const y = s.focalY + s.zoom * (q - s.focalY) + s.offsetY;
  return { x, y };
}

/** `MotionBlurMath.blur(previous:current:dt:strength:)` */
export function blur(previous: CameraSample, current: CameraSample, dt: number, strength: number): Blur {
  if (!(strength > 0.001 && dt > 1e-6 && dt <= maxSampleGap)) return noBlur();
  const p0 = mappedCenter(previous);
  const p1 = mappedCenter(current);
  const vx = (p1.x - p0.x) / dt;
  const vy = (p1.y - p0.y) / dt;
  const translational = Math.sqrt(vx * vx + vy * vy);
  const zoomSpeed = (Math.abs(current.zoom - previous.zoom) / dt) * zoomLeverArm;
  const speed = translational + zoomSpeed;
  if (!(speed > velocityThreshold)) return noBlur();
  const t = smin(1, (speed - velocityThreshold) / (velocityAtMax - velocityThreshold));
  const eased = t * t * (3 - 2 * t);
  const radius = eased * maxRadiusFraction * smin(1, smax(0, strength));
  if (!(radius > 0.0002)) return noBlur();
  const angle = translational > 1e-9 ? Math.atan2(vy, vx) : 0;
  return { radius, angle, active: true };
}
