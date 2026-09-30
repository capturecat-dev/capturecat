/**
 * The card CAMERA — zoom, tilt, card offset and intro slide — exactly as the
 * Mac EXPORTER composes it (VideoExporter.export frame loop, the
 * "Screen tilt + zoom" block):
 *
 *   1. perspective tilt of the card about the video-rect centre
 *   2. card-only zoom (cover-compensated) about the TILT-PROJECTED focal point
 *   3. card offset excursion (canvas fractions, Y-down)
 *   4. intro slide: translate + scale about the canvas centre, then the rise
 *      entrance's forward tip OUTERMOST
 *
 * The per-frame values come from `computeCameraPath` — the exporter's own
 * spring pre-pass, locked to Swift by golden vectors and cross-checked
 * against the real exporter's camera dump. One CameraKey per EXPORT frame
 * (i / fps on the CMTime clock); the preview samples the key of the export
 * frame at the playhead, so preview == export on the web by construction.
 *
 * Everything folds into ONE Y-down homography (card px → canvas px) that the
 * frame graph applies to the card layer — shadow, video and every card-space
 * overlay (cursor, annotations, regions…) ride it as one plane. Two more
 * per-frame outputs complete the exporter's block:
 *   - `clip`: the exporter crops the zoomed card to the canvas BEFORE the
 *     offset / intro transforms, so an offset reveals background at the
 *     leading edge (canvas → crop-space map; coverage = CI's resampled edge);
 *   - `parallax`: the background scaled about the zoom anchor
 *     (ZoomFocalMath.parallaxScale of the cover-compensated zoom);
 * plus `motionBlurAt` — MotionBlurMath over consecutive export keys, drawn
 * as CIMotionBlur (a 1D Gaussian, σ = radius, clamped to the canvas).
 *
 * The keynote dip across stitched device segments is NOT here: it depends on
 * the SOURCE clock, and the FrameGraph folds it in as the innermost factor of
 * this matrix (passes/frameGraph.ts `withDeviceSegment`, core
 * deviceSegmentDip). Not yet: Lanczos minification for zoom < 1 (bilinear
 * today).
 */
import type { CursorEvent, CursorRecording, KeystrokeEvent, Project } from "../core/model";
import { computeCameraPath, type CameraKey } from "../core/math/exportCameraPath";
import { processCursorEvents, recordingCoordinateSize, shiftForMenuBarCrop } from "../core/math/cursorChain";
import { exportCursorSetup } from "../core/math/exportCursor";
import { exportFrameTimes } from "../core/math/exportLayout";
import { state as introSlideState } from "../core/math/introSlideMath";
import {
  effectiveCoverZoom,
  perspectiveDistance,
  projectedPoint,
  projectionTransform,
  type Homography,
} from "../core/math/tiltMath";
import { blur as motionBlur } from "../core/math/motionBlurMath";
import { parallaxScale } from "../core/math/zoomFocalMath";
import { effectiveTrimEnd } from "../core/time/clips";
import type { CardGeometry, Size } from "./layout";
import { IDENTITY, invert, multiply, scaleAbout, translate, type Mat3 } from "./mat3";
import type { SceneAssets } from "./media/assets";
import type { TimeMap } from "./time";

export interface CameraPath {
  /** Export frame times (OUTPUT seconds, CMTime-truncated like the Mac). */
  times: number[];
  keys: CameraKey[];
  /** True when any key moves the camera (skip the layer path otherwise). */
  moves: boolean;
}

const REST: CameraKey = { zoom: 1, focalX: 0.5, focalY: 0.5, offsetX: 0, offsetY: 0, tiltPitch: 0, tiltYaw: 0, tiltRoll: 0 };

function asRecording(raw: unknown): CursorRecording | null {
  const r = raw as Partial<CursorRecording> | null;
  if (!r || !Array.isArray(r.events)) return null;
  return {
    version: typeof r.version === "number" ? r.version : 1,
    coordinateWidth: typeof r.coordinateWidth === "number" ? r.coordinateWidth : 0,
    coordinateHeight: typeof r.coordinateHeight === "number" ? r.coordinateHeight : 0,
    events: (r.events as CursorEvent[]).filter((e) => e && typeof e.timestamp === "number"),
  };
}

function scrollTimesOf(raw: unknown): number[] {
  const events = (raw as { events?: KeystrokeEvent[] } | null)?.events;
  if (!Array.isArray(events)) return [];
  return events
    .filter((e) => e && e.category === "scroll" && typeof e.timestamp === "number")
    .map((e) => e.timestamp)
    .sort((a, b) => a - b);
}

/**
 * The exporter's camera path for this project: cursor chain (smoothing →
 * springs → end behaviour → menu-bar crop), scroll ticks, the export frame
 * clock, then the spring pre-pass. Pure; rebuilt when the project changes.
 */
export function buildCameraPath(
  project: Project,
  assets: SceneAssets,
  timeMap: TimeMap,
  fps: number,
  naturalSize: Size,
  outputSize: Size,
): CameraPath {
  const settings = project.settings;
  const recording = asRecording(assets.cursor);
  const coordinateSize = recordingCoordinateSize(recording);
  const setup = exportCursorSetup(coordinateSize, naturalSize, outputSize, settings, project);
  const chained = recording ? processCursorEvents(recording.events, settings, effectiveTrimEnd(project)) : [];
  const cursorEvents = shiftForMenuBarCrop(chained, setup.fullCursorCoordinateSize, setup.menuBarCrop);

  const times = exportFrameTimes(Math.max(0.0001, timeMap.outputDuration), Math.max(1, fps));
  const keys = computeCameraPath({
    zoomRegions: project.zoomRegions,
    tiltRegions: project.tiltRegions,
    settings,
    outputFrameTimes: times,
    timelineSourceTimes: times.map((t) => timeMap.sourceTime(t)),
    cursorEvents,
    displayWidth: setup.resolvedCursorCoordinateSize.width,
    displayHeight: setup.resolvedCursorCoordinateSize.height,
    scrollTimes: scrollTimesOf(assets.keystrokes),
  });
  const moves = keys.some(
    (k) =>
      Math.abs(k.zoom - 1) > 0.001 ||
      Math.abs(k.offsetX) > 0.0005 ||
      Math.abs(k.offsetY) > 0.0005 ||
      Math.max(Math.abs(k.tiltPitch), Math.abs(k.tiltYaw), Math.abs(k.tiltRoll)) > 0.05,
  );
  return { times, keys, moves };
}

/** Index of the export frame showing at `outputTime` (last frame time ≤ t); -1 without a path. */
export function cameraIndexAt(path: CameraPath | null, outputTime: number): number {
  if (!path || path.keys.length === 0) return -1;
  const times = path.times;
  if (outputTime <= times[0]) return 0;
  let lo = 0;
  let hi = times.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (times[mid] <= outputTime + 1e-9) lo = mid;
    else hi = mid - 1;
  }
  return Math.min(lo, path.keys.length - 1);
}

/** The key of the export frame showing at `outputTime` (last frame time ≤ t). */
export function cameraKeyAt(path: CameraPath | null, outputTime: number): CameraKey {
  const i = cameraIndexAt(path, outputTime);
  return i < 0 ? REST : path!.keys[i];
}

export interface MotionBlurFrame {
  /** CIMotionBlur inputRadius in target pixels (= the Gaussian σ). */
  radius: number;
  /** Radians, Y-down. */
  angle: number;
}

/**
 * The exporter's motion blur for the export frame at `outputTime`:
 * MotionBlurMath over keys[i-1] → keys[i] and their output-time gap. Null on
 * frame 0, when disabled, or below the velocity threshold.
 */
export function motionBlurAt(
  path: CameraPath | null,
  outputTime: number,
  settings: { motionBlur: boolean; motionBlurStrength: number },
  targetWidth: number,
): MotionBlurFrame | null {
  if (!settings.motionBlur) return null;
  const i = cameraIndexAt(path, outputTime);
  if (i < 1) return null;
  const prev = path!.keys[i - 1];
  const cur = path!.keys[i];
  const b = motionBlur(
    { zoom: prev.zoom, focalX: prev.focalX, focalY: prev.focalY, offsetX: prev.offsetX, offsetY: prev.offsetY },
    { zoom: cur.zoom, focalX: cur.focalX, focalY: cur.focalY, offsetX: cur.offsetX, offsetY: cur.offsetY },
    path!.times[i] - path!.times[i - 1],
    settings.motionBlurStrength,
  );
  if (!b.active) return null;
  const radius = b.radius * targetWidth;
  return radius > 0.05 ? { radius, angle: b.angle } : null;
}

/** Core row-vector homography ((x, y, 1) · H) → engine Mat3 (M · (x, y, 1)). */
function toMat3(h: Homography): Mat3 {
  return [h.m11, h.m21, h.m31, h.m12, h.m22, h.m32, h.m13, h.m23, h.m33];
}

export interface CameraSettings {
  parallaxStrength: number;
  introSlideStyle: Project["settings"]["introSlideStyle"];
  introSlideStart: number;
  introSlideDuration: number;
  introSlideBounce: number;
  introSlideDepth: boolean;
  introSlideSpeed: number;
}

export interface CameraFrame {
  /** Card → canvas homography (Y-down px). */
  matrix: Mat3;
  /**
   * Canvas → crop space of the exporter's post-zoom `cropped(to: outputRect)`
   * (the inverse of offset ∘ intro ∘ tip); null when the frame has no zoom.
   */
  clip: Mat3 | null;
  /** Canvas → background sample point (parallax scale about the zoom anchor); null at rest. */
  parallax: Mat3 | null;
}

/**
 * Card → canvas homography for one frame (Y-down px of the target), the
 * exporter's composition order. Identity when nothing moves.
 */
export function cameraHomography(
  key: CameraKey,
  geometry: CardGeometry,
  settings: CameraSettings,
  outputTime: number,
): Mat3 {
  return cameraFrame(key, geometry, settings, outputTime).matrix;
}

/** The exporter's whole per-frame camera: warp, post-zoom crop and background parallax. */
export function cameraFrame(
  key: CameraKey,
  geometry: CardGeometry,
  settings: CameraSettings,
  outputTime: number,
): CameraFrame {
  const { width: W, height: H } = geometry.target;
  const vr = geometry.videoRect;
  const center = { x: vr.x + vr.width / 2, y: vr.y + vr.height / 2 };
  let m: Mat3 = IDENTITY;
  let parallaxAnchor = { x: W / 2, y: H / 2 };

  // 1. Perspective tilt about the video-rect centre.
  const tilted = Math.max(Math.abs(key.tiltPitch), Math.abs(key.tiltYaw), Math.abs(key.tiltRoll)) > 0.05;
  const distance = perspectiveDistance({ width: vr.width, height: vr.height });
  if (tilted) {
    m = toMat3(projectionTransform(key.tiltPitch, key.tiltYaw, key.tiltRoll, center, distance));
  }

  // 2. Card-only zoom, cover-compensated, about the (tilt-projected) focal
  //    point — then the exporter crops to the canvas.
  const zoom = effectiveCoverZoom(key.zoom, key.tiltPitch, key.tiltYaw, key.tiltRoll, W / Math.max(1, H));
  const zoomed = Math.abs(zoom - 1) > 0.001;
  if (zoomed) {
    let anchor = { x: vr.x + key.focalX * vr.width, y: vr.y + key.focalY * vr.height };
    if (tilted) {
      anchor = projectedPoint(anchor, center, key.tiltPitch, key.tiltYaw, key.tiltRoll, distance, false);
    }
    parallaxAnchor = anchor;
    m = multiply(scaleAbout(zoom, anchor.x, anchor.y), m);
  }
  let post: Mat3 = IDENTITY;

  // 3. Card offset excursion (canvas fractions, Y-down).
  if (Math.abs(key.offsetX) > 0.0005 || Math.abs(key.offsetY) > 0.0005) {
    post = multiply(translate(key.offsetX * W, key.offsetY * H), post);
  }

  // 4. Intro slide: translate + scale about the canvas centre, tip outermost.
  const intro = introSlideState(
    settings.introSlideStyle,
    outputTime,
    settings.introSlideStart,
    settings.introSlideDuration,
    settings.introSlideBounce,
    settings.introSlideDepth,
    settings.introSlideSpeed,
  );
  if (intro.active) {
    const cx = W / 2;
    const cy = H / 2;
    const slide: Mat3 = multiply(
      translate(cx + intro.offset.x * W, cy + intro.offset.y * H),
      multiply([intro.scale, 0, 0, 0, intro.scale, 0, 0, 0, 1], translate(-cx, -cy)),
    );
    post = multiply(slide, post);
    if (Math.abs(intro.pitch) > 0.01) {
      const tip = projectionTransform(intro.pitch, 0, 0, { x: cx, y: cy }, perspectiveDistance({ width: W, height: H }));
      post = multiply(toMat3(tip), post);
    }
  }

  // Background parallax (the backdrop stays put otherwise).
  const p = parallaxScale(zoom, settings.parallaxStrength);
  const parallax = p > 1.001 ? invert(scaleAbout(p, parallaxAnchor.x, parallaxAnchor.y)) : null;

  return {
    matrix: multiply(post, m),
    clip: zoomed ? invert(post) : null,
    parallax,
  };
}

/** The camera half of a FrameState — ONE function for preview and export. */
export interface CameraState {
  camera: Mat3;
  cameraClip: Mat3 | null;
  parallax: Mat3 | null;
  motionBlur: MotionBlurFrame | null;
  /** The raw export key (the webcam bubble reacts to its smoothed zoom); absent at rest. */
  cameraKey?: CameraKey;
  /** Screen tilt this frame (`cam.tiltPitch/tiltYaw`) — the device side slab follows it. */
  tilt?: { pitch: number; yaw: number };
}

export const CAMERA_REST: CameraState = { camera: IDENTITY, cameraClip: null, parallax: null, motionBlur: null };

export function cameraStateAt(
  path: CameraPath | null,
  geometry: CardGeometry,
  settings: (CameraSettings & { motionBlur: boolean; motionBlurStrength: number }) | null,
  outputTime: number,
): CameraState {
  if (!path || !settings) return CAMERA_REST;
  // Evaluated even when the path is static: the intro slide is a pure
  // function of time and settings.
  const key = cameraKeyAt(path, outputTime);
  const f = cameraFrame(key, geometry, settings, outputTime);
  return {
    cameraKey: key,
    tilt: { pitch: key.tiltPitch, yaw: key.tiltYaw },
    camera: f.matrix,
    cameraClip: f.clip,
    parallax: f.parallax,
    motionBlur: path.moves ? motionBlurAt(path, outputTime, settings, geometry.target.width) : null,
  };
}
