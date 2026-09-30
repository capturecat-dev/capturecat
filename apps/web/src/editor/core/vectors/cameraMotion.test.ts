/**
 * CameraMotion cluster golden vectors — the exporter's per-frame camera path,
 * ZoomFocalMath, TiltMath, PreviewMotionModel, Easing, IntroSlideMath and
 * MotionBlurMath, each locked to the REAL Swift (or, for inline/private Swift,
 * its verbatim oracle) by apps/macos/CaptureCat/Services/WebVectors/
 * WebVectors+CameraMotion.swift. Missing vectors FAIL (see harness.ts).
 */
import { describe, expect, it } from "vitest";
import { checkUnit, loadVectors } from "./harness";
import { computeCameraPath } from "../math/exportCameraPath";
import {
  easeInCubic,
  easeInOutCubic,
  easeOutCubic,
  easeOutExpo,
  easeOutQuart,
  regionEnvelope,
  smootherStep,
  spring,
  zoomEnvelope,
  zoomLevel,
} from "../math/easing";
import {
  blendedFocalPoint,
  cardOffsetLimit,
  clampCardOffset,
  clampedUnitPoint,
  cursorFollowBlend,
  parallaxScale,
  regionTargets,
  restLandingBand,
  restSnapVelocityEpsilon,
  restSnapZoomEpsilon,
  returnOmega,
  scaledRect,
  settleTowardRest,
  settleTowardZero,
  smoothstep,
  temporalSmoothFocal,
  type RegionMemory,
} from "../math/zoomFocalMath";
import {
  caTransform3D,
  caTransform3DArray,
  coverZoomMultiplier,
  deviceSideOffset,
  effectiveCoverZoom,
  Homography,
  introAmount,
  perspectiveDistance,
  projectedPoint,
  projectionTransform,
  rampOutLead,
  rampOutScale,
  springStep,
  tiltReturnParams,
  tiltStyleParams,
  type TiltStyleMemory,
} from "../math/tiltMath";
import { PreviewMotionModel, type PreviewMotionEnv } from "../math/previewMotionModel";
import {
  arriving,
  depthStartPitch,
  depthStartScale,
  easeOutBack,
  introSlideVector,
  pulling,
  restingIntroSlideState,
  startScale,
  state as introSlideState,
  travel,
} from "../math/introSlideMath";
import {
  blur,
  mappedCenter,
  maxRadiusFraction,
  maxSampleGap,
  noBlur,
  velocityAtMax,
  velocityThreshold,
  zoomLeverArm,
} from "../math/motionBlurMath";

function snapshot(m: PreviewMotionModel) {
  return {
    zoom: m.zoom,
    zoomVel: m.zoomVel,
    focalX: m.focalX,
    focalY: m.focalY,
    focalVelX: m.focalVelX,
    focalVelY: m.focalVelY,
    regionMemory: { ...m.regionMemory, focal: { ...m.regionMemory.focal } },
    cardOffsetX: m.cardOffsetX,
    cardOffsetVelX: m.cardOffsetVelX,
    cardOffsetY: m.cardOffsetY,
    cardOffsetVelY: m.cardOffsetVelY,
    tiltStyleMemory: { ...m.tiltStyleMemory },
    tilt: m.tilt,
    tiltVel: m.tiltVel,
    regionPitch: m.regionPitch,
    regionPitchVel: m.regionPitchVel,
    regionYaw: m.regionYaw,
    regionYawVel: m.regionYawVel,
    regionRoll: m.regionRoll,
    regionRollVel: m.regionRollVel,
    lastTime: m.lastTime,
  };
}

describe("cameraMotion golden vectors", () => {
  it("exportCameraPath", () => {
    checkUnit("exportCameraPath", (i) => computeCameraPath(i));

    // The vectors must exercise the springs MID-FLIGHT and the snap branch,
    // not only settled frames.
    const file = loadVectors("exportCameraPath");
    let midZoom = 0;
    let midOffset = 0;
    let midTilt = 0;
    let snaps = 0;
    for (const c of file.cases) {
      const levels: number[] = c.input.zoomRegions.map((r: { zoomLevel: number }) => r.zoomLevel);
      for (const k of c.output as { zoom: number; offsetX: number; tiltPitch: number }[]) {
        if (Math.abs(k.zoom - 1) > 1e-3 && levels.every((z) => Math.abs(k.zoom - z) > 1e-3)) midZoom++;
        if (Math.abs(k.offsetX) > 1e-3 && Math.abs(Math.abs(k.offsetX) - cardOffsetLimit) > 1e-3) midOffset++;
        if (Math.abs(k.tiltPitch) > 1e-3) midTilt++;
      }
      const ts: number[] = c.input.timelineSourceTimes;
      for (let j = 1; j < ts.length; j++) if (!(ts[j] - ts[j - 1] > 0 && ts[j] - ts[j - 1] <= 0.35)) snaps++;
    }
    expect(midZoom, "mid-flight zoom frames").toBeGreaterThan(2000);
    expect(midOffset, "mid-flight card-offset frames").toBeGreaterThan(500);
    expect(midTilt, "tilted frames").toBeGreaterThan(2000);
    expect(snaps, "snap-branch frames (dt ≤ 0 or > 0.35)").toBeGreaterThan(50);
  });

  it("zoomFocalMathScalars", () => {
    checkUnit("zoomFocalMathScalars", (i) => ({
      constants: { cardOffsetLimit, restSnapZoomEpsilon, restSnapVelocityEpsilon, restLandingBand },
      clampCardOffset: clampCardOffset(i.v),
      returnOmega: returnOmega(i.time, i.rampStart, i.lead, i.style),
      parallaxScale: parallaxScale(i.parallaxZoom, i.parallaxStrength),
      clampedUnitPoint: clampedUnitPoint(i.point),
      cursorFollowBlend: cursorFollowBlend(i.blendZoom),
      blendedFocalPoint: blendedFocalPoint(
        i.regionFocal,
        i.cursorPosition,
        i.displayWidth,
        i.displayHeight,
        i.zoom,
        i.envelope,
        i.followCursor,
      ),
      blendedFocalPointDefaults: blendedFocalPoint(
        i.regionFocal,
        i.cursorPosition,
        i.displayWidth,
        i.displayHeight,
        i.zoom,
      ),
      temporalSmoothFocal: temporalSmoothFocal(
        i.target,
        i.previous,
        i.deltaTime,
        i.smoothCursor,
        i.smoothingFactor,
        i.smoothZoom,
      ),
      temporalSmoothFocalDefaultZoom: temporalSmoothFocal(
        i.target,
        i.previous,
        i.deltaTime,
        i.smoothCursor,
        i.smoothingFactor,
      ),
      scaledRect: scaledRect(i.rect, i.scale, i.anchor),
    }));
  });

  it("zoomFocalMathSettle", () => {
    checkUnit("zoomFocalMathSettle", (i) => {
      let zoom: number = i.zoom;
      let velocity: number = i.velocity;
      const rest = (i.dts as number[]).map((dt) => {
        ({ zoom, velocity } = settleTowardRest(zoom, velocity, dt));
        return { zoom, velocity };
      });
      let value: number = i.value;
      let vv: number = i.valueVelocity;
      const zero = (i.dts as number[]).map((dt) => {
        const r = settleTowardZero(value, vv, dt, i.band);
        value = r.value;
        vv = r.velocity;
        return { value, velocity: vv };
      });
      return { rest, zero };
    });
  });

  it("zoomFocalMathRegionTargets", () => {
    checkUnit("zoomFocalMathRegionTargets", (i) => {
      const memory: RegionMemory = { ...i.memory, focal: { ...i.memory.focal } };
      return (i.queries as { time: number; currentZoom: number }[]).map((q) => ({
        targets: regionTargets(i.zoomRegions, q.time, q.currentZoom, i.animationDuration ?? undefined, memory),
        memory: { ...memory, focal: { ...memory.focal } },
      }));
    });
  });

  it("zoomFocalMathSmoothstepOracle", () => {
    checkUnit("zoomFocalMathSmoothstepOracle", (i) => smoothstep(i.edge0, i.edge1, i.x));
  });

  it("tiltMathScalars", () => {
    checkUnit("tiltMathScalars", (i) => ({
      perspectiveDistance: perspectiveDistance(i.size),
      introAmount: introAmount(i.introTime, i.introDuration),
      springStep: springStep(i.springT, i.response, i.damping),
      deviceSideOffset: deviceSideOffset(i.sidePitch, i.sideYaw, i.videoWidth),
      rampOutLead: rampOutLead(i.blockStart, i.blockEnd, i.animationDuration),
      rampOutScale: rampOutScale(i.rampTime, i.blockStart, i.blockEnd, i.animationDuration),
      coverZoomMultiplier: coverZoomMultiplier(i.pitch, i.yaw, i.roll, i.aspect),
      effectiveCoverZoom: effectiveCoverZoom(i.zoom, i.pitch, i.yaw, i.roll, i.aspect),
    }));
  });

  it("tiltMathStyleParams", () => {
    checkUnit("tiltMathStyleParams", (i) => {
      const styleMemory: TiltStyleMemory = { ...i.memory };
      const returnMemory: TiltStyleMemory = { ...i.memory };
      return (i.times as number[]).map((t) => {
        const style = tiltStyleParams(i.tiltRegions, t, styleMemory);
        const ret = tiltReturnParams(i.tiltRegions, t, i.animationDuration, returnMemory);
        return {
          style,
          styleMemory: { ...styleMemory },
          return: ret,
          returnMemory: { ...returnMemory },
        };
      });
    });
  });

  it("tiltMathHomography", () => {
    checkUnit("tiltMathHomography", (i) => {
      const h1 = Homography.fromAffine(i.affine);
      const h2 = i.homography;
      const inv1 = Homography.inverted(h1);
      const inv2 = Homography.inverted(h2);
      const pts = i.points as { x: number; y: number }[];
      return {
        identity: Homography.identity(),
        fromAffine: h1,
        appliedAffine: pts.map((p) => Homography.applied(h1, p)),
        applied: pts.map((p) => Homography.applied(h2, p)),
        invertedAffine: inv1,
        inverted: inv2,
        concatenating12: Homography.concatenating(h1, h2),
        concatenating21: Homography.concatenating(h2, h1),
        roundTrip: inv2 ? pts.map((p) => Homography.applied(inv2, Homography.applied(h2, p))) : null,
      };
    });
  });

  it("tiltMathProjection", () => {
    checkUnit("tiltMathProjection", (i) => {
      const h = projectionTransform(i.pitch, i.yaw, i.roll, i.center, i.distance);
      const pts = i.points as { x: number; y: number }[];
      return {
        projection: h,
        caTransform3D: caTransform3D(h),
        caTransform3DArray: caTransform3DArray(h),
        appliedProjection: pts.map((p) => Homography.applied(h, p)),
        projectedDown: pts.map((p) => projectedPoint(p, i.center, i.pitch, i.yaw, i.roll, i.distance, false)),
        projectedUp: pts.map((p) => projectedPoint(p, i.center, i.pitch, i.yaw, i.roll, i.distance, true)),
      };
    });
  });

  it("previewMotionModel", () => {
    checkUnit("previewMotionModel", (i) => {
      const e = i.env;
      const env: PreviewMotionEnv = {
        currentTime: 0,
        zoomRegions: e.zoomRegions,
        tiltRegions: e.tiltRegions,
        animationDuration: e.animationDuration,
        screenTiltMode: e.screenTiltMode,
        smoothingFactor: e.smoothingFactor,
        followSpeed: e.followSpeed,
        scrollTimes: e.scrollTimes,
        cursorEvents: e.cursorEvents,
        coordinateSize: e.coordinateSize,
      };
      const model = new PreviewMotionModel();
      return (i.ops as any[]).map((op) => {
        env.currentTime = op.time;
        if (op.op === "step") model.step(env);
        else if (op.op === "reset") model.reset(env);
        else if (op.op === "scrub") model.scrub(env, op.projectStart);
        else throw new Error(`unknown op ${op.op}`);
        const q = op.query;
        return {
          state: snapshot(model),
          tiltAmount: model.effectiveTiltAmount(
            q.mode,
            q.currentTime,
            q.effectiveTrimStart,
            q.animationDuration,
            q.isWithinVisibleVideoClip,
          ),
          tiltAngles: model.effectiveTiltAngles(
            q.mode,
            q.settingsAngle,
            q.settingsYaw,
            q.settingsRoll,
            q.currentTime,
            q.effectiveTrimStart,
            q.animationDuration,
            q.isWithinVisibleVideoClip,
            q.timelineTiltOverride,
          ),
        };
      });
    });

    // Sequences must cover springs in flight (not only snapped/settled states).
    const file = loadVectors("previewMotionModel");
    let zoomInFlight = 0;
    let focalInFlight = 0;
    let tiltRegionInFlight = 0;
    let offsetInFlight = 0;
    let modeTiltInFlight = 0;
    const ops = new Map<string, number>();
    for (const c of file.cases) {
      for (const op of c.input.ops) ops.set(op.op, (ops.get(op.op) ?? 0) + 1);
      for (const r of c.output as { state: ReturnType<typeof snapshot> }[]) {
        const s = r.state;
        if (Math.abs(s.zoomVel) > 1e-3 && Math.abs(s.zoom - 1) > 1e-3) zoomInFlight++;
        if (Math.abs(s.focalVelX) > 1e-3) focalInFlight++;
        if (Math.abs(s.regionPitchVel) > 1e-2) tiltRegionInFlight++;
        if (Math.abs(s.cardOffsetVelX) > 1e-3) offsetInFlight++;
        if (Math.abs(s.tiltVel) > 1e-3) modeTiltInFlight++;
      }
    }
    expect(zoomInFlight, "zoom springs mid-flight").toBeGreaterThan(1000);
    expect(focalInFlight, "focal springs mid-flight").toBeGreaterThan(1000);
    expect(tiltRegionInFlight, "tilt-region springs mid-flight").toBeGreaterThan(300);
    expect(offsetInFlight, "card-offset springs mid-flight").toBeGreaterThan(300);
    expect(modeTiltInFlight, "mode-tilt spring mid-flight").toBeGreaterThan(200);
    expect(ops.get("reset") ?? 0, "reset ops").toBeGreaterThan(50);
    expect(ops.get("scrub") ?? 0, "scrub ops").toBeGreaterThan(50);
  });

  it("easingCurves", () => {
    checkUnit("easingCurves", (i) => ({
      easeInOutCubic: easeInOutCubic(i.t),
      smootherStep: smootherStep(i.t),
      easeOutCubic: easeOutCubic(i.t),
      easeInCubic: easeInCubic(i.t),
      easeOutQuart: easeOutQuart(i.t),
      easeOutExpo: easeOutExpo(i.t),
      springDefault: spring(i.t),
      spring: spring(i.t, i.damping, i.frequency),
    }));
  });

  it("easingEnvelopes", () => {
    checkUnit("easingEnvelopes", (i) => ({
      regionEnvelope: regionEnvelope(i.time, i.startTime, i.endTime, i.transitionDuration),
      zoomEnvelope: zoomEnvelope(i.time, i.startTime, i.endTime, i.transitionDuration),
    }));
  });

  it("easingZoomLevel", () => {
    checkUnit("easingZoomLevel", (i) =>
      (i.times as number[]).map((t) => zoomLevel(t, i.zoomRegions, i.transitionDuration)),
    );
  });

  it("introSlideMath", () => {
    checkUnit("introSlideMath", (i) => {
      if (i.constants) {
        return { travel, startScale, depthStartScale, depthStartPitch, resting: restingIntroSlideState() };
      }
      const st = i.useDefaults
        ? introSlideState(i.style, i.outputTime, undefined, i.duration)
        : introSlideState(i.style, i.outputTime, i.startTime, i.duration, i.bounce, i.depth, i.speed);
      return { state: st, vector: introSlideVector(i.style) };
    });
  });

  it("introSlideMathHelpersOracle", () => {
    checkUnit("introSlideMathHelpersOracle", (i) => ({
      easeOutBack: easeOutBack(i.p, i.bounce),
      pulling: pulling(i.p, i.v, i.bounce),
      arriving: arriving(i.e, i.v, i.startScale, i.startPitch),
    }));
  });

  it("motionBlurMath", () => {
    checkUnit("motionBlurMath", (i) => {
      if (i.constants) {
        return { velocityThreshold, velocityAtMax, maxRadiusFraction, zoomLeverArm, maxSampleGap, none: noBlur() };
      }
      return {
        blur: blur(i.previous, i.current, i.dt, i.strength),
        mappedCenterPrevious: mappedCenter(i.previous),
        mappedCenterCurrent: mappedCenter(i.current),
      };
    });
    // Coverage: active blurs, threshold rejections and the pure-zoom angle-0 branch.
    const file = loadVectors("motionBlurMath");
    let active = 0;
    let pureZoom = 0;
    for (const c of file.cases) {
      if (c.output.blur?.active) {
        active++;
        if (c.output.blur.angle === 0) pureZoom++;
      }
    }
    expect(active).toBeGreaterThan(300);
    expect(pureZoom).toBeGreaterThan(20);
  });
});
