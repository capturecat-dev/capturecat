/**
 * Port of Services/PreviewMotionModel.swift (`final class PreviewMotionModel`)
 * — the preview's camera-motion state machine: zoom / focal / card-offset /
 * tilt springs. `reset(env:)`, `step(env:)`, `scrub(env:from:)`,
 * `effectiveTiltAmount(...)`, `effectiveTiltAngles(...)`, and the private
 * helpers `targets`, `nearestScroll`, `tiltRegionTarget`, `tiltSpringTarget`
 * (exported here as methods/functions so the web can reuse them).
 *
 * Locked to Swift by the `previewMotionModel` golden vectors: random
 * SEQUENCES of reset/step/scrub calls whose FULL state (incl. the Swift
 * `private` velocities, region memory, tilt-style memory and lastTime, read
 * through Mirror) is recorded after every call, with the vectors asserting
 * mid-flight (non-settled) states are present.
 *
 * The web PREVIEW uses this class exactly like the Mac preview compositor
 * (step once per display tick with the OUTPUT-timeline-derived source time;
 * scrub on seeks). The web EXPORT must NOT use it — use
 * `computeCameraPath` (./exportCameraPath), the exporter's own integrator
 * (no substeps, different snap threshold), which is what the Mac export
 * renders.
 *
 * Swift's `@Observable` is irrelevant here: state is plain fields.
 *
 * Faithful-port oddity (reported, not fixed): even with ≤ 1/60 s substeps the
 * semi-implicit Euler zoom spring diverges for an Instant block at Rapid
 * speed (ω = 2.5/0.3·8 ≈ 66.7 → ω·dt ≈ 1.11 > 1/ζ = 1).
 */
import type { CursorEvent, Point, Size, TiltRegion, ZoomRegion } from "../model/types";
import type { ScreenTiltMode } from "../model/enums";
import { interpolateIfFresh } from "./cursorSmoother";
import { sInt, smax, smin } from "./swift";
import { introAmount, makeTiltStyleMemory, rampOutScale, tiltReturnParams, type TiltStyleMemory } from "./tiltMath";
import {
  blendedFocalPoint,
  makeRegionMemory,
  regionTargets,
  restLandingBand,
  settleTowardRest,
  settleTowardZero,
  type RegionMemory,
} from "./zoomFocalMath";

/** `PreviewMotionModel.Env` — inputs the springs need each tick. */
export interface PreviewMotionEnv {
  currentTime: number;
  zoomRegions: readonly ZoomRegion[];
  tiltRegions: readonly TiltRegion[];
  animationDuration: number;
  screenTiltMode: ScreenTiltMode;
  smoothingFactor: number;
  /** Swift default 0.5. */
  followSpeed?: number;
  /** Sorted scroll-tick timestamps. Swift default []. */
  scrollTimes?: readonly number[];
  /** EFFECTIVE cursor events (already shifted for the Hidden-menu-bar crop). */
  cursorEvents: readonly CursorEvent[];
  /** Resolved (crop-scaled) cursor coordinate space. */
  coordinateSize: Size;
}

export interface TiltAngles {
  pitch: number;
  yaw: number;
  roll: number;
}

interface Targets {
  zoom: number;
  focal: Point;
  omegaMultiplier: number;
  damping: number;
  offset: Point;
}

/** `PreviewMotionModel.nearestScroll(to:in:)` — distance to the nearest
 * scroll tick (binary search over sorted times); +∞ when empty. */
export function nearestScroll(time: number, times: readonly number[]): number {
  if (times.length === 0) return Number.POSITIVE_INFINITY;
  let lo = 0;
  let hi = times.length - 1;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (times[mid] < time) lo = mid + 1;
    else hi = mid;
  }
  let best = Math.abs(times[lo] - time);
  if (lo > 0) best = smin(best, Math.abs(times[lo - 1] - time));
  return best;
}

/** `PreviewMotionModel.tiltRegionTarget(env:)` — the active tilt region's
 * angles scaled by the eased in-block ramp-out; flat outside. */
export function tiltRegionTarget(
  tiltRegions: readonly TiltRegion[],
  currentTime: number,
  animationDuration: number,
): TiltAngles {
  for (const region of tiltRegions) {
    if (currentTime >= region.startTime && currentTime <= region.endTime) {
      const scale = rampOutScale(currentTime, region.startTime, region.endTime, animationDuration);
      return { pitch: region.pitch * scale, yaw: region.yaw * scale, roll: region.roll * scale };
    }
  }
  return { pitch: 0, yaw: 0, roll: 0 };
}

/** `PreviewMotionModel.tiltSpringTarget(forZoomTarget:env:)` */
export function tiltSpringTarget(targetZoom: number, screenTiltMode: ScreenTiltMode): number {
  const mode = screenTiltMode;
  if (!(mode === "Zoomed Out" || mode === "Both")) return 0;
  return targetZoom > 1.0 ? 0 : 1;
}

export class PreviewMotionModel {
  // Spring state — zoom
  zoom = 1.0;
  zoomVel = 0.0;
  // Spring state — focal
  focalX = 0.5;
  focalY = 0.5;
  focalVelX = 0.0;
  focalVelY = 0.0;
  regionMemory: RegionMemory = makeRegionMemory();
  // Spring state — card position excursion (canvas fractions, Y-down)
  cardOffsetX = 0;
  cardOffsetVelX = 0;
  cardOffsetY = 0;
  cardOffsetVelY = 0;
  tiltStyleMemory: TiltStyleMemory = makeTiltStyleMemory();
  // Spring state — screen tilt (normalized 0…1)
  tilt = 0.0;
  tiltVel = 0.0;
  // Spring state — timeline tilt regions (degrees)
  regionPitch = 0.0;
  regionPitchVel = 0.0;
  regionYaw = 0.0;
  regionYawVel = 0.0;
  regionRoll = 0.0;
  regionRollVel = 0.0;
  lastTime: number | null = null;

  get cardOffset(): Point {
    return { x: this.cardOffsetX, y: this.cardOffsetY };
  }

  get focal(): Point {
    return { x: this.focalX, y: this.focalY };
  }

  /** `reset(env:)` — two-pass snap to the current target. */
  reset(env: PreviewMotionEnv): void {
    const first = this.targets(env);
    const targetZoom = first.zoom;
    const offsetTarget = first.offset;
    this.zoom = targetZoom;
    this.zoomVel = 0;
    this.cardOffsetX = offsetTarget.x;
    this.cardOffsetVelX = 0;
    this.cardOffsetY = offsetTarget.y;
    this.cardOffsetVelY = 0;
    const focalTarget = this.targets(env).focal;
    this.focalX = focalTarget.x;
    this.focalY = focalTarget.y;
    this.focalVelX = 0;
    this.focalVelY = 0;
    this.tilt = tiltSpringTarget(targetZoom, env.screenTiltMode);
    this.tiltVel = 0;
    const regionTarget = tiltRegionTarget(env.tiltRegions, env.currentTime, env.animationDuration);
    this.regionPitch = regionTarget.pitch;
    this.regionPitchVel = 0;
    this.regionYaw = regionTarget.yaw;
    this.regionYawVel = 0;
    this.regionRoll = regionTarget.roll;
    this.regionRollVel = 0;
    this.lastTime = env.currentTime;
  }

  /** `step(env:)` — one integrator step to `env.currentTime` (≤1/60 s substeps;
   * snaps when the tick is ≤ 0 or > 1 s). Throws where Swift traps
   * (`Int(NaN)` for a NaN tick). */
  step(env: PreviewMotionEnv): void {
    const t = this.targets(env);
    const targetZoom = t.zoom;
    const focalTarget = t.focal;
    const zoomOmegaMult = t.omegaMultiplier;
    const zoomDamping = t.damping;
    const offsetTarget = t.offset;

    const last = this.lastTime;
    if (last === null) {
      this.zoom = targetZoom;
      this.cardOffsetX = offsetTarget.x;
      this.cardOffsetY = offsetTarget.y;
      this.focalX = focalTarget.x;
      this.focalY = focalTarget.y;
      this.tilt = tiltSpringTarget(targetZoom, env.screenTiltMode);
      const regionTarget = tiltRegionTarget(env.tiltRegions, env.currentTime, env.animationDuration);
      this.regionPitch = regionTarget.pitch;
      this.regionYaw = regionTarget.yaw;
      this.regionRoll = regionTarget.roll;
      this.lastTime = env.currentTime;
      return;
    }

    const tickDt = env.currentTime - last;
    this.lastTime = env.currentTime;

    if (tickDt <= 0 || tickDt > 1.0) {
      this.zoom = targetZoom;
      this.zoomVel = 0;
      this.cardOffsetX = offsetTarget.x;
      this.cardOffsetVelX = 0;
      this.cardOffsetY = offsetTarget.y;
      this.cardOffsetVelY = 0;
      this.focalX = focalTarget.x;
      this.focalY = focalTarget.y;
      this.focalVelX = 0;
      this.focalVelY = 0;
      this.tilt = tiltSpringTarget(targetZoom, env.screenTiltMode);
      this.tiltVel = 0;
      const regionTarget = tiltRegionTarget(env.tiltRegions, env.currentTime, env.animationDuration);
      this.regionPitch = regionTarget.pitch;
      this.regionPitchVel = 0;
      this.regionYaw = regionTarget.yaw;
      this.regionYawVel = 0;
      this.regionRoll = regionTarget.roll;
      this.regionRollVel = 0;
      return;
    }

    const substeps = smax(1, sInt(Math.ceil(tickDt * 60)));
    const subDt = tickDt / substeps;
    for (let i = 0; i < substeps; i++) {
      const dt = subDt;

      // ── Zoom spring
      const animDur = smax(0.2, env.animationDuration);
      const zOmega = (2.5 / animDur) * zoomOmegaMult;
      const zZeta = zoomDamping;
      const zAcc = zOmega * zOmega * (targetZoom - this.zoom) - 2 * zZeta * zOmega * this.zoomVel;
      this.zoomVel += zAcc * dt;
      this.zoom += this.zoomVel * dt;
      this.zoom = smax(0.25, this.zoom);
      if (targetZoom === 1 && Math.abs(this.zoom - 1) < restLandingBand) {
        const r = settleTowardRest(this.zoom, this.zoomVel, dt);
        this.zoom = r.zoom;
        this.zoomVel = r.velocity;
      }

      // ── Tilt springs
      const tiltTarget = tiltSpringTarget(targetZoom, env.screenTiltMode);
      const tAcc = zOmega * zOmega * (tiltTarget - this.tilt) - 2 * zZeta * zOmega * this.tiltVel;
      this.tiltVel += tAcc * dt;
      this.tilt += this.tiltVel * dt;

      const regionTarget = tiltRegionTarget(env.tiltRegions, env.currentTime, env.animationDuration);
      const tiltParams = tiltReturnParams(env.tiltRegions, env.currentTime, animDur, this.tiltStyleMemory);
      const tiltReturning = tiltParams.returning;
      const rOmegaMult = tiltParams.omega;
      const rZeta = tiltParams.damping;
      const rOmega = (2.5 / animDur) * rOmegaMult;
      // springStep(&regionPitch, &regionPitchVel, toward: regionTarget.pitch)
      {
        const acc = rOmega * rOmega * (regionTarget.pitch - this.regionPitch) - 2 * rZeta * rOmega * this.regionPitchVel;
        this.regionPitchVel += acc * dt;
        this.regionPitch += this.regionPitchVel * dt;
      }
      {
        const acc = rOmega * rOmega * (regionTarget.yaw - this.regionYaw) - 2 * rZeta * rOmega * this.regionYawVel;
        this.regionYawVel += acc * dt;
        this.regionYaw += this.regionYawVel * dt;
      }
      {
        const acc = rOmega * rOmega * (regionTarget.roll - this.regionRoll) - 2 * rZeta * rOmega * this.regionRollVel;
        this.regionRollVel += acc * dt;
        this.regionRoll += this.regionRollVel * dt;
      }
      if (tiltReturning) {
        let s = settleTowardZero(this.regionPitch, this.regionPitchVel, dt, 1.5);
        this.regionPitch = s.value;
        this.regionPitchVel = s.velocity;
        s = settleTowardZero(this.regionYaw, this.regionYawVel, dt, 1.5);
        this.regionYaw = s.value;
        this.regionYawVel = s.velocity;
        s = settleTowardZero(this.regionRoll, this.regionRollVel, dt, 1.5);
        this.regionRoll = s.value;
        this.regionRollVel = s.velocity;
      }
      // Card offset rides the ZOOM spring.
      const oxAcc = zOmega * zOmega * (offsetTarget.x - this.cardOffsetX) - 2 * zZeta * zOmega * this.cardOffsetVelX;
      const oyAcc = zOmega * zOmega * (offsetTarget.y - this.cardOffsetY) - 2 * zZeta * zOmega * this.cardOffsetVelY;
      this.cardOffsetVelX += oxAcc * dt;
      this.cardOffsetX += this.cardOffsetVelX * dt;
      this.cardOffsetVelY += oyAcc * dt;
      this.cardOffsetY += this.cardOffsetVelY * dt;

      // ── Focal spring
      const fOmega = 5.5 * (0.4 + 1.2 * smax(0, smin(1, env.followSpeed ?? 0.5)));
      const fZeta = 0.9;
      const fxAcc = fOmega * fOmega * (focalTarget.x - this.focalX) - 2 * fZeta * fOmega * this.focalVelX;
      const fyAcc = fOmega * fOmega * (focalTarget.y - this.focalY) - 2 * fZeta * fOmega * this.focalVelY;
      this.focalVelX += fxAcc * dt;
      this.focalVelY += fyAcc * dt;
      this.focalX = smax(0, smin(1, this.focalX + this.focalVelX * dt));
      this.focalY = smax(0, smin(1, this.focalY + this.focalVelY * dt));
    }
  }

  /** `scrub(env:from:)` — replays ≤ max(3, 5·animationDuration) s of history
   * at 1/60 s ticks from a reset, landing exactly on `targetEnv.currentTime`. */
  scrub(targetEnv: PreviewMotionEnv, projectStart: number): void {
    const targetTime = targetEnv.currentTime;
    const history = smax(3.0, targetEnv.animationDuration * 5.0);
    const replayStart = smax(projectStart, targetTime - history);
    const env: PreviewMotionEnv = { ...targetEnv, currentTime: replayStart };
    this.reset(env);

    const tick = 1.0 / 60.0;
    let time = replayStart;
    while (time + tick < targetTime) {
      time += tick;
      env.currentTime = time;
      this.step(env);
    }
    if (time < targetTime) {
      env.currentTime = targetTime;
      this.step(env);
    }
  }

  /** `targets(env:)` (private in Swift) — discrete zoom target and the
   * cursor-blended focal for `env.currentTime`, using the CURRENT zoom.
   * MUTATES `regionMemory`. */
  targets(env: PreviewMotionEnv): Targets {
    const region = regionTargets(
      env.zoomRegions,
      env.currentTime,
      this.zoom,
      env.animationDuration,
      this.regionMemory,
    );

    const scrolling = nearestScroll(env.currentTime, env.scrollTimes ?? []) < 0.35;
    let cursorPosition: Point | null;
    if (scrolling) {
      cursorPosition = null;
    } else if (env.cursorEvents.length !== 0) {
      // CursorSmoother(factor: env.smoothingFactor).interpolateIfFresh — the
      // factor does not affect interpolation.
      cursorPosition = interpolateIfFresh(env.cursorEvents, env.currentTime);
    } else {
      cursorPosition = null;
    }
    const cs = env.coordinateSize;
    const focalTarget = blendedFocalPoint(
      region.focal,
      cursorPosition,
      cs.width,
      cs.height,
      this.zoom,
      region.envelope,
      region.cursorFollow,
    );
    return {
      zoom: region.zoom,
      focal: focalTarget,
      omegaMultiplier: region.omegaMultiplier,
      damping: region.damping,
      offset: region.offset,
    };
  }

  /** `effectiveTiltAmount(mode:currentTime:effectiveTrimStart:animationDuration:isWithinVisibleVideoClip:)` */
  effectiveTiltAmount(
    mode: ScreenTiltMode,
    currentTime: number,
    effectiveTrimStart: number,
    animationDuration: number,
    isWithinVisibleVideoClip: boolean,
  ): number {
    if (!(mode !== "Off" && isWithinVisibleVideoClip)) return 0;
    let amount = mode === "Zoomed Out" || mode === "Both" ? this.tilt : 0;
    if (mode === "Intro" || mode === "Both") {
      const t = currentTime - effectiveTrimStart;
      amount = smax(amount, introAmount(t, animationDuration));
    }
    return smax(0, smin(1, amount));
  }

  /** `effectiveTiltAngles(mode:settingsAngle:settingsYaw:settingsRoll:currentTime:effectiveTrimStart:animationDuration:isWithinVisibleVideoClip:timelineTiltOverride:)` */
  effectiveTiltAngles(
    mode: ScreenTiltMode,
    settingsAngle: number,
    settingsYaw: number,
    settingsRoll: number,
    currentTime: number,
    effectiveTrimStart: number,
    animationDuration: number,
    isWithinVisibleVideoClip: boolean,
    timelineTiltOverride: TiltAngles | null = null,
  ): TiltAngles {
    if (!isWithinVisibleVideoClip) return { pitch: 0, yaw: 0, roll: 0 };
    const amount = this.effectiveTiltAmount(
      mode,
      currentTime,
      effectiveTrimStart,
      animationDuration,
      isWithinVisibleVideoClip,
    );
    const timelineTilt = timelineTiltOverride ?? {
      pitch: this.regionPitch,
      yaw: this.regionYaw,
      roll: this.regionRoll,
    };
    return {
      pitch: amount * settingsAngle + timelineTilt.pitch,
      yaw: amount * settingsYaw + timelineTilt.yaw,
      roll: amount * settingsRoll + timelineTilt.roll,
    };
  }
}
