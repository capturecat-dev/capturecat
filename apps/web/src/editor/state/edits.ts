/**
 * The Mac editor's timeline edits, ported rule-for-rule from
 * `Views/Editor/TimelineViewController.swift` ("Ported edit logic" + every
 * add/delete/duplicate), `VideoTrackRowNative.swift` (`VideoTrackCommits`),
 * `VoiceTrackRowNative.swift` (`VoiceTrackCommits`) and the canvas callbacks
 * that convert OUTPUT → SOURCE time.
 *
 * Every function mutates a DRAFT project in place (Swift's Project is a
 * reference type — the ported bodies read naturally that way; the store
 * copies-on-write around them) and returns an `EditOutcome` describing the
 * undo label and the selection the Mac leaves behind, or `null` when the Mac
 * would do nothing (guard fails, lane full → NSSound.beep()).
 *
 * All model times are SOURCE seconds; parameters named `output…` are OUTPUT
 * seconds (post trim + speed), converted with the SAME `fullTimeMap` the Mac
 * builds: `SpeedTimeMap(effectiveTrimStart, max(start, effectiveTrimEnd), speedRegions)`.
 */
import type {
  AnnotationType,
  BlurStyle,
  CameraLayoutMode,
  CodableColor,
  Project,
  Rect,
  VideoClipSegment,
  VoiceOverClip,
  ZoomRegion,
} from "../core/model";
import {
  newAnnotation,
  newBlurRegion,
  newCameraLayoutRegion,
  newFocusRegion,
  newHighlightRegion,
  newSpeedRegion,
  newTiltRegion,
  newUUID,
  newZoomRegion,
} from "../core/model";
import { applyAutoZoom, applyStillMotion, type AutoZoomInputs } from "../core/edit/autoZoom";
import { smax, smin } from "../core/math/swift";
import { effectiveTrimEnd, effectiveTrimStart, effectiveVideoClipSegments } from "../core/time/clips";
import { SpeedTimeMap } from "../core/time/speedTimeMap";
import { isSliceable } from "../core/time/videoSliceMath";
import type { TrackSide, VideoDragMode } from "../core/time/videoTrackEditMath";
import { voiceCommit } from "../core/time/voiceTrackEditMath";
import { assign, assignAll, type Selection } from "./selection";

export interface EditEnv {
  /** The playhead in SOURCE seconds (the Mac's `playback.currentTime`). */
  playheadSource: number;
}

export interface EditOutcome {
  /** Undo action name (the Mac's `setActionName`). */
  label: string;
  /** Selection after the edit (defaults to the current one). */
  selection?: Selection;
  /** Disarm the slice tool (a successful slice). */
  disarmSlice?: boolean;
  /** The Mac also forces the inspector to a tab (intro/curtain entry points). */
  inspectorTab?: "effects" | "annotations";
}

export type Edit = (p: Project, sel: Selection, env: EditEnv) => EditOutcome | null;

// ── Shared helpers ──────────────────────────────────────────────────────

/** TimelineViewController.fullTimeMap */
export function fullTimeMap(p: Project): SpeedTimeMap {
  const start = effectiveTrimStart(p);
  return new SpeedTimeMap(start, smax(start, effectiveTrimEnd(p)), p.speedRegions);
}

/** `outputDuration` — max(0.0001, fullTimeMap.outputDuration). */
export function timelineOutputDuration(p: Project): number {
  return smax(0.0001, fullTimeMap(p).outputDuration);
}

type Span = readonly [number, number];

/** Every span on the EFFECTS lane (zoom + tilt), SOURCE time. */
export function effectLaneSpans(p: Project): Span[] {
  return [...p.zoomRegions.map((r) => [r.startTime, r.endTime] as const), ...p.tiltRegions.map((r) => [r.startTime, r.endTime] as const)];
}

/** blur + highlight + depth focus + camera layout (the FOCUS lane, SOURCE). */
function focusLaneSpans(p: Project): Span[] {
  return [
    ...p.blurRegions.map((r) => [r.startTime, r.endTime] as const),
    ...p.highlightRegions.map((r) => [r.startTime, r.endTime] as const),
    ...p.focusRegions.map((r) => [r.startTime, r.endTime] as const),
    ...p.cameraLayoutRegions.map((r) => [r.startTime, r.endTime] as const),
  ];
}

/**
 * `findNonOverlappingSlot` — gap-based placement: the gap holding the desired
 * start wins, else the nearest gap; the block shrinks to fit down to
 * `minDuration`. Returns [0, 0] only when no gap of `minDuration` exists.
 */
export function findNonOverlappingSlot(desired: Span, existing: readonly Span[], duration: number, minDuration = 0.8): [number, number] {
  const want = smax(minDuration, desired[1] - desired[0]);
  // Swift `sorted { $0.0 < $1.0 }` — stable in practice (introsort on small
  // arrays is insertion sort); JS sort is stable.
  const spans = [...existing].sort((a, b) => (a[0] < b[0] ? -1 : b[0] < a[0] ? 1 : 0));
  const gaps: Array<[number, number]> = [];
  let cursor = 0.0;
  for (const span of spans) {
    if (span[0] - cursor >= minDuration) gaps.push([cursor, span[0]]);
    cursor = smax(cursor, span[1]);
  }
  if (duration - cursor >= minDuration) gaps.push([cursor, duration]);
  if (gaps.length === 0) return [0, 0];

  let gap = gaps.find((g) => desired[0] >= g[0] && desired[0] < g[1]);
  if (!gap) {
    // `gaps.min { a < b }` — first minimum wins.
    const dist = (g: [number, number]) => smin(Math.abs(g[0] - desired[0]), Math.abs(g[1] - desired[0]));
    gap = gaps[0];
    for (const g of gaps) if (dist(g) < dist(gap)) gap = g;
  }
  const length = smin(want, gap[1] - gap[0]);
  const start = smin(smax(desired[0], gap[0]), gap[1] - length);
  return [start, start + length];
}

/** `duplicateSlot` — a copy right after the source, sliding past `existing`. */
function duplicateSlot(p: Project, source: Span, existing: readonly Span[]): [number, number] | null {
  const length = smax(0.1, source[1] - source[0]);
  const desiredStart = smin(source[1], smax(0, p.duration - length));
  const [start, end] = findNonOverlappingSlot([desiredStart, smin(desiredStart + length, p.duration)], existing, p.duration);
  if (!(start < end)) return null;
  return [start, end];
}

function desiredStartAt(p: Project, env: EditEnv, at?: number): number {
  return smax(0, smin(at ?? env.playheadSource, p.duration));
}

function hasSkew(p: Project): boolean {
  const s = p.settings;
  return smax(Math.abs(s.screenTiltAngle), Math.abs(s.screenTiltYaw), Math.abs(s.screenTiltRoll)) > 0.01;
}

function seededTilt(p: Project, start: number, end: number) {
  const s = p.settings;
  const skew = hasSkew(p);
  const region = newTiltRegion(start, end);
  region.pitch = skew ? s.screenTiltAngle : 20;
  region.yaw = skew ? s.screenTiltYaw : 0;
  region.roll = skew ? s.screenTiltRoll : 0;
  return region;
}

/** `ZoomRegion(startTime:endTime:zoomLevel:focalPoint:animationStyle:)`. */
function zoom(start: number, end: number, o: Partial<Pick<ZoomRegion, "zoomLevel" | "focalPoint" | "animationStyle">> = {}): ZoomRegion {
  const r = newZoomRegion(start, end);
  if (o.zoomLevel !== undefined) r.zoomLevel = o.zoomLevel;
  if (o.focalPoint) r.focalPoint = { x: o.focalPoint.x, y: o.focalPoint.y };
  if (o.animationStyle) r.animationStyle = o.animationStyle;
  return r;
}

// ── EFFECTS lane: adds ──────────────────────────────────────────────────

/** addZoomRegion(at:) — `at` is SOURCE time (default: playhead). */
export function addZoomRegion(at?: number): Edit {
  return (p, sel, env) => {
    const desiredStart = desiredStartAt(p, env, at);
    const desiredEnd = smin(desiredStart + 3, p.duration);
    let [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], effectLaneSpans(p), p.duration);
    // No free slot → keep the desired span; overlapping effects stack into sub-rows.
    if (start >= end) [start, end] = [desiredStart, desiredEnd];
    if (!(start < end)) return null;
    const region = zoom(start, end);
    p.zoomRegions.push(region);
    return { label: "Add Zoom", selection: assignAll(sel, ["tilt", null], ["zoom", region.id]) };
  };
}

/** addShowcaseBlock — zoom 1.35 @ (0.5, 0.45) Slow Glide + tilt (10, −6, −2). */
export const addShowcaseBlock: Edit = (p, sel, env) => {
  const desiredStart = desiredStartAt(p, env);
  const desiredEnd = smin(desiredStart + 3, p.duration);
  let [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], effectLaneSpans(p), p.duration);
  if (start >= end) [start, end] = [desiredStart, desiredEnd];
  if (!(start < end)) return null;
  const z = zoom(start, end, { zoomLevel: 1.35, focalPoint: { x: 0.5, y: 0.45 }, animationStyle: "Slow Glide" });
  const t = newTiltRegion(start, end);
  t.pitch = 10;
  t.yaw = -6;
  t.roll = -2;
  p.zoomRegions.push(z);
  p.tiltRegions.push(t);
  return { label: "Add Showcase", selection: assignAll(sel, ["tilt", t.id], ["zoom", z.id]) };
};

/** addScaleDownBlock — zoom 0.85, Smooth. */
export const addScaleDownBlock: Edit = (p, sel, env) => {
  const desiredStart = desiredStartAt(p, env);
  const desiredEnd = smin(desiredStart + 3, p.duration);
  let [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], effectLaneSpans(p), p.duration);
  if (start >= end) [start, end] = [desiredStart, desiredEnd];
  if (!(start < end)) return null;
  const region = zoom(start, end, { zoomLevel: 0.85, animationStyle: "Smooth" });
  p.zoomRegions.push(region);
  return { label: "Add Scale Down", selection: assignAll(sel, ["tilt", null], ["zoom", region.id]) };
};

/** addTiltRegion(at:) — seeded with the Motion tab's skew, else pitch 20. */
export function addTiltRegion(at?: number): Edit {
  return (p, sel, env) => {
    const desiredStart = desiredStartAt(p, env, at);
    const desiredEnd = smin(desiredStart + 3, p.duration);
    let [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], effectLaneSpans(p), p.duration);
    if (start >= end) [start, end] = [desiredStart, desiredEnd];
    if (!(start < end)) return null;
    const region = seededTilt(p, start, end);
    p.tiltRegions.push(region);
    return { label: "Add Tilt", selection: assignAll(sel, ["zoom", null], ["tilt", region.id]) };
  };
}

/** enableIntroSlide — turns the Slide on (Bottom) and selects its chip. */
export const enableIntroSlide: Edit = (p, sel) => {
  if (p.settings.introSlideStyle === "Off") p.settings.introSlideStyle = "Bottom";
  return {
    label: "Slide",
    selection: { ...sel, zoomId: null, tiltId: null, curtainSelected: false, introSelected: true },
    inspectorTab: "effects",
  };
};

/** enableCurtainUnveil — turns the peel on (Top Left) and selects its chip. */
export const enableCurtainUnveil: Edit = (p, sel) => {
  if (p.settings.curtainUnveilCorner === "Off") p.settings.curtainUnveilCorner = "Top Left";
  return {
    label: "Curtain Unveil",
    selection: { ...sel, zoomId: null, tiltId: null, introSelected: false, curtainSelected: true },
    inspectorTab: "effects",
  };
};

/** addCameraLayoutRegion(mode:) — near-start snaps to 0; 4 s; FOCUS lane slot. */
export function addCameraLayoutRegion(mode: CameraLayoutMode): Edit {
  return (p, sel, env) => {
    let desiredStart = smax(0, smin(env.playheadSource, p.duration));
    if (desiredStart < 0.75) desiredStart = 0;
    const desiredEnd = smin(desiredStart + 4, p.duration);
    const [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], focusLaneSpans(p), p.duration);
    if (!(start < end)) return null; // lane full (beep)
    const region = newCameraLayoutRegion(start, end);
    region.mode = mode;
    p.cameraLayoutRegions.push(region);
    return { label: "Add Camera Layout", selection: assign(sel, "cameraLayout", region.id) };
  };
}

/** autoZoom() — AutoZoomApplier (only earlier AUTO regions are replaced);
 *  nothing zoom-worthy → no change. */
export function autoZoom(inputs: AutoZoomInputs): Edit {
  return (p, sel) => {
    if (applyAutoZoom(p, inputs) <= 0) return null;
    return { label: "Auto Zoom", selection: assign(sel, "zoom", null) };
  };
}

/** runStillMotion() — StillMotionApplier (image captures' corner tour). */
export const stillMotion: Edit = (p, sel) => {
  if (applyStillMotion(p) <= 0) return null;
  return { label: "Motion", selection: assignAll(sel, ["zoom", null], ["tilt", null]) };
};

// ── EFFECTS lane: block edits ───────────────────────────────────────────

/** commitEffectBlockTimes — OUTPUT span → SOURCE, written to both halves;
 *  a joined Slide rides the block it matched before the edit. */
export function commitEffectBlockTimes(zoomId: string | null | undefined, tiltId: string | null | undefined, outputStart: number, outputEnd: number): Edit {
  return (p) => {
    const map = fullTimeMap(p);
    const start = map.sourceTime(outputStart);
    const end = map.sourceTime(outputEnd);
    const previousZooms = p.zoomRegions.map((z) => ({ ...z }));
    const previousTilts = p.tiltRegions.map((t) => ({ ...t }));
    let changed = false;
    const zi = zoomId ? p.zoomRegions.findIndex((z) => z.id === zoomId) : -1;
    if (zi >= 0) {
      p.zoomRegions[zi].startTime = start;
      p.zoomRegions[zi].endTime = end;
      changed = true;
    }
    const ti = tiltId ? p.tiltRegions.findIndex((t) => t.id === tiltId) : -1;
    if (ti >= 0) {
      p.tiltRegions[ti].startTime = start;
      p.tiltRegions[ti].endTime = end;
      changed = true;
    }
    if (!changed) return null;
    if (p.settings.introSlideStyle !== "Off") {
      // `fullTimeMap` is re-read AFTER the region write (speed regions unchanged → same map).
      const s0 = p.settings.introSlideStart;
      const prevSpans = [
        ...previousZooms.filter((z) => z.id === zoomId).map((z) => [z.startTime, z.endTime] as const),
        ...previousTilts.filter((t) => t.id === tiltId).map((t) => [t.startTime, t.endTime] as const),
      ];
      if (prevSpans.some((s) => Math.abs(map.outputTime(s[0]) - s0) < 0.05)) {
        p.settings.introSlideStart = map.outputTime(start);
        p.settings.introSlideDuration = smax(0.3, map.outputTime(end) - map.outputTime(start));
      }
    }
    return { label: "Move Effect" };
  };
}

export function setZoomLevel(id: string, level: number): Edit {
  return (p) => {
    const z = p.zoomRegions.find((r) => r.id === id);
    if (!z || !(Math.abs(z.zoomLevel - level) > 0.0001)) return null;
    z.zoomLevel = level;
    return { label: "Zoom Level" };
  };
}

/** addTiltToBlock — a tilt exactly co-spanning an existing zoom. */
export function addTiltToBlock(zoomId: string): Edit {
  return (p, sel) => {
    const z = p.zoomRegions.find((r) => r.id === zoomId);
    if (!z) return null;
    const region = seededTilt(p, z.startTime, z.endTime);
    p.tiltRegions.push(region);
    return { label: "Add Tilt to Block", selection: assignAll(sel, ["zoom", zoomId], ["tilt", region.id]) };
  };
}

/** addZoomToBlock — a zoom (settings.autoZoomLevel) co-spanning a tilt. */
export function addZoomToBlock(tiltId: string): Edit {
  return (p, sel) => {
    const t = p.tiltRegions.find((r) => r.id === tiltId);
    if (!t) return null;
    const region = zoom(t.startTime, t.endTime, { zoomLevel: p.settings.autoZoomLevel });
    p.zoomRegions.push(region);
    return { label: "Add Zoom to Block", selection: assignAll(sel, ["zoom", region.id], ["tilt", tiltId]) };
  };
}

export function deleteZoomRegion(id: string): Edit {
  return (p, sel) => {
    const index = p.zoomRegions.findIndex((r) => r.id === id);
    if (index < 0) return null;
    p.zoomRegions.splice(index, 1);
    return { label: "Delete Zoom", selection: sel.zoomId === id ? assign(sel, "zoom", null) : sel };
  };
}

export function deleteTiltRegion(id: string): Edit {
  return (p, sel) => {
    const index = p.tiltRegions.findIndex((r) => r.id === id);
    if (index < 0) return null;
    p.tiltRegions.splice(index, 1);
    return { label: "Delete Tilt", selection: sel.tiltId === id ? assign(sel, "tilt", null) : sel };
  };
}

/** deleteEffectBlock — every half of a block as one undo step. */
export function deleteEffectBlock(zoomId: string | null | undefined, tiltId: string | null | undefined): Edit {
  return (p, sel) => {
    if (!zoomId && !tiltId) return null;
    let next = sel;
    if (zoomId) {
      p.zoomRegions = p.zoomRegions.filter((r) => r.id !== zoomId);
      if (next.zoomId === zoomId) next = assign(next, "zoom", null);
    }
    if (tiltId) {
      p.tiltRegions = p.tiltRegions.filter((r) => r.id !== tiltId);
      if (next.tiltId === tiltId) next = assign(next, "tilt", null);
    }
    return { label: "Delete Effect", selection: next };
  };
}

// ── FOCUS lane ──────────────────────────────────────────────────────────

/** addBlurRegion(at:) — BlurRegion defaults, label "Blur". */
export function addBlurRegion(at?: number): Edit {
  return (p, sel, env) => {
    const desiredStart = desiredStartAt(p, env, at);
    const desiredEnd = smin(desiredStart + 3, p.duration);
    const [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], focusLaneSpans(p), p.duration);
    if (!(start < end)) return null;
    const region = newBlurRegion(start, end);
    region.label = "Blur";
    p.blurRegions.push(region);
    return { label: "Add Blur", selection: assign(sel, "blur", region.id) };
  };
}

/** createBlurRegion(rect:style:) — the drag-to-draw entry (preview marquee). */
export function createBlurRegion(rect: Rect, style: BlurStyle): Edit {
  return (p, sel, env) => {
    const desiredStart = smax(0, smin(env.playheadSource, p.duration));
    const desiredEnd = smin(desiredStart + 3, p.duration);
    const [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], focusLaneSpans(p), p.duration);
    if (!(start < end)) return null;
    const label = style === "Pixelate" ? "Pixelate" : "Blur";
    const region = newBlurRegion(start, end);
    region.label = label;
    region.rect = { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
    region.style = style;
    p.blurRegions.push(region);
    return { label: `Add ${label}`, selection: assign(sel, "blur", region.id) };
  };
}

export function addDepthFocusRegion(at?: number): Edit {
  return (p, sel, env) => {
    const desiredStart = desiredStartAt(p, env, at);
    const desiredEnd = smin(desiredStart + 3, p.duration);
    const [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], focusLaneSpans(p), p.duration);
    if (!(start < end)) return null;
    const region = newFocusRegion(start, end);
    p.focusRegions.push(region);
    return { label: "Add Depth Focus", selection: assign(sel, "depthFocus", region.id) };
  };
}

/** addHighlightRegion(at:) — note the Mac's slot search here ignores
 *  camera-layout spans (highlight + blur + depth focus only). */
export function addHighlightRegion(at?: number): Edit {
  return (p, sel, env) => {
    const desiredStart = desiredStartAt(p, env, at);
    const desiredEnd = smin(desiredStart + 3, p.duration);
    const existing: Span[] = [
      ...p.highlightRegions.map((r) => [r.startTime, r.endTime] as const),
      ...p.blurRegions.map((r) => [r.startTime, r.endTime] as const),
      ...p.focusRegions.map((r) => [r.startTime, r.endTime] as const),
    ];
    const [start, end] = findNonOverlappingSlot([desiredStart, desiredEnd], existing, p.duration);
    if (!(start < end)) return null;
    const region = newHighlightRegion(start, end);
    region.label = "Highlight";
    p.highlightRegions.push(region);
    return { label: "Add Highlight", selection: assign(sel, "highlight", region.id) };
  };
}

/** commitFocusTimes — OUTPUT span → SOURCE; the id picks the array. */
export function commitFocusTimes(id: string, isHighlight: boolean, outputStart: number, outputEnd: number): Edit {
  return (p) => {
    const map = fullTimeMap(p);
    const s = map.sourceTime(outputStart);
    const e = map.sourceTime(outputEnd);
    const set = (r: { startTime: number; endTime: number } | undefined) => {
      if (!r) return false;
      r.startTime = s;
      r.endTime = e;
      return true;
    };
    let ok: boolean;
    if (isHighlight) ok = set(p.highlightRegions.find((r) => r.id === id));
    else
      ok =
        set(p.focusRegions.find((r) => r.id === id)) ||
        set(p.cameraLayoutRegions.find((r) => r.id === id)) ||
        set(p.blurRegions.find((r) => r.id === id));
    // The Mac writes these straight into the model (no undo registration);
    // on the web every edit is undoable.
    return ok ? { label: "Move Region" } : null;
  };
}

function deleteById<K extends "blurRegions" | "highlightRegions" | "focusRegions" | "cameraLayoutRegions" | "speedRegions" | "annotations" | "voiceOverClips">(
  key: K,
  label: string,
  lane: Parameters<typeof assign>[1],
  field: keyof Selection,
) {
  return (id: string): Edit =>
    (p, sel) => {
      const list = p[key] as Array<{ id: string }>;
      const index = list.findIndex((r) => r.id === id);
      if (index < 0) return null;
      list.splice(index, 1);
      return { label, selection: sel[field] === id ? assign(sel, lane, null) : sel };
    };
}

export const deleteBlurRegion = deleteById("blurRegions", "Delete Blur", "blur", "blurId");
export const deleteHighlightRegion = deleteById("highlightRegions", "Delete Highlight", "highlight", "highlightId");
export const deleteDepthFocusRegion = deleteById("focusRegions", "Delete Depth Focus", "depthFocus", "depthFocusId");
export const deleteCameraLayoutRegion = deleteById("cameraLayoutRegions", "Delete Camera Layout", "cameraLayout", "cameraLayoutId");
export const deleteSpeedRegion = deleteById("speedRegions", "Delete Speed", "speed", "speedId");
export const deleteAnnotation = deleteById("annotations", "Delete Annotation", "annotation", "annotationId");
/** The Mac also deletes the clip's audio file (restored on undo); the web
 *  keeps cloud media untouched and only edits the project. */
export const deleteVoiceOverClip = deleteById("voiceOverClips", "Delete Voice Over", "voiceOver", "voiceOverId");

/** Focus-lane delete: the id picks the array (deleteFocus callback). */
export function deleteFocusItem(id: string, isHighlight: boolean): Edit {
  return (p, sel, env) => {
    if (isHighlight) return deleteHighlightRegion(id)(p, sel, env);
    if (p.focusRegions.some((r) => r.id === id)) return deleteDepthFocusRegion(id)(p, sel, env);
    if (p.cameraLayoutRegions.some((r) => r.id === id)) return deleteCameraLayoutRegion(id)(p, sel, env);
    return deleteBlurRegion(id)(p, sel, env);
  };
}

// ── ANNOTATE lane ───────────────────────────────────────────────────────

/** `Annotation.applyNewAnnotationDefaults()` (Models/Annotation.swift). */
export function applyNewAnnotationDefaults(a: ReturnType<typeof newAnnotation>): void {
  switch (a.type) {
    case "text":
      a.text = "Label";
      break;
    case "arrow":
      a.x = 0.35;
      a.y = 0.45;
      a.arrowEndX = 0.55;
      a.arrowEndY = 0.55;
      break;
    case "rectangle":
    case "ellipse":
      a.x = 0.35;
      a.y = 0.375;
      a.arrowEndX = 0.65;
      a.arrowEndY = 0.625;
      a.color = { red: 1, green: 1, blue: 1, opacity: 1 };
      a.backgroundColor = { red: 1, green: 1, blue: 1, opacity: 0.25 };
      a.showBackground = false;
      a.lineWidth = 4;
      break;
    case "tap":
      a.x = 0.5;
      a.y = 0.5;
      a.fontSize = 60;
      break;
    case "callout":
      a.x = 0.4;
      a.y = 0.3;
      a.arrowEndX = 0.55;
      a.arrowEndY = 0.5;
      a.text = "Look here";
      break;
    case "drawing":
      a.enterEffect = "Fade";
      a.exitEffect = "Fade";
      break;
  }
}

/** TimelineViewController.annotationLaneLabel(for:) */
export function annotationLaneLabel(a: { type: AnnotationType; text: string }): string {
  switch (a.type) {
    case "text":
    case "callout": {
      const trimmed = a.text.replace(/^[\s\x85]+|[\s\x85]+$/g, "");
      return trimmed === "" ? "Text" : trimmed;
    }
    case "arrow":
      return "Arrow";
    case "drawing":
      return "Drawing";
    case "rectangle":
      return "Rectangle";
    case "ellipse":
      return "Ellipse";
    case "tap":
      return "Tap";
  }
}

/** addAnnotation(type:atSource:) — at the playhead (or the lane's clicked
 *  SOURCE time), 3 s (drawing 10 s), per-type defaults, pill colour wins. */
export function addAnnotation(type: AnnotationType, atSource?: number, pillColor?: CodableColor | null): Edit {
  return (p, sel, env) => {
    const start = smax(0, smin(atSource ?? env.playheadSource, smax(0, p.duration - 0.5)));
    const defaultDuration = type === "drawing" ? 10 : 3;
    const end = smax(start + 0.5, smin(p.duration, start + defaultDuration));
    const a = newAnnotation(type, start, end);
    applyNewAnnotationDefaults(a);
    if (pillColor) a.color = { ...pillColor };
    p.annotations.push(a);
    return { label: `Add ${annotationLaneLabel(a)}`, selection: assign(sel, "annotation", a.id) };
  };
}

/** commitAnnotationTimes — OUTPUT span → SOURCE; ≥ 0.25 s. */
export function commitAnnotationTimes(id: string, outputStart: number, outputEnd: number): Edit {
  return (p) => {
    const map = fullTimeMap(p);
    const start = map.sourceTime(outputStart);
    const end = map.sourceTime(outputEnd);
    const a = p.annotations.find((x) => x.id === id);
    if (!a) return null;
    if (!(Math.abs(a.startTime - start) > 0.0001 || Math.abs(a.endTime - end) > 0.0001)) return null;
    a.startTime = start;
    a.endTime = smax(start + 0.25, end);
    return { label: "Edit Annotation Timing" };
  };
}

// ── Intro Slide / Curtain chips (settings, OUTPUT time) ──────────────────

export function resizeIntro(outputEnd: number): Edit {
  return (p) => {
    p.settings.introSlideDuration = smax(0.3, outputEnd - p.settings.introSlideStart);
    return { label: "Slide Length" };
  };
}

export function moveIntro(outputStart: number): Edit {
  return (p) => {
    const outputDuration = fullTimeMap(p).outputTime(p.duration);
    p.settings.introSlideStart = smin(smax(0, outputStart), smax(0, outputDuration - p.settings.introSlideDuration));
    return { label: "Move Slide" };
  };
}

export function resizeCurtain(outputEnd: number): Edit {
  return (p) => {
    p.settings.curtainUnveilDuration = smax(0.3, outputEnd - p.settings.curtainUnveilStart);
    return { label: "Curtain Length" };
  };
}

export function moveCurtain(outputStart: number): Edit {
  return (p) => {
    const outputDuration = fullTimeMap(p).outputTime(p.duration);
    p.settings.curtainUnveilStart = smin(smax(0, outputStart), smax(0, outputDuration - p.settings.curtainUnveilDuration));
    return { label: "Move Curtain" };
  };
}

export const deleteIntroSlide: Edit = (p, sel) => {
  if (p.settings.introSlideStyle === "Off") return null;
  p.settings.introSlideStyle = "Off";
  return { label: "Delete Slide", selection: { ...sel, introSelected: false } };
};

export const deleteCurtainUnveil: Edit = (p, sel) => {
  if (p.settings.curtainUnveilCorner === "Off") return null;
  p.settings.curtainUnveilCorner = "Off";
  return { label: "Delete Curtain Unveil", selection: { ...sel, curtainSelected: false } };
};

// ── VIDEO lane: clips, splits, trim ─────────────────────────────────────

/** splitVideoClip(at:) — SOURCE time; > 0.1 s from both clip edges. */
export function splitVideoClip(sourceTime: number): Edit {
  return (p) => {
    const clips = effectiveVideoClipSegments(p);
    const index = clips.findIndex((c) => sourceTime > c.startTime + 0.1 && sourceTime < c.endTime - 0.1);
    if (index < 0) return null;
    const clip = clips[index];
    clips.splice(index, 1);
    clips.splice(index, 0, { id: newUUID(), startTime: sourceTime, endTime: clip.endTime });
    clips.splice(index, 0, { id: newUUID(), startTime: clip.startTime, endTime: sourceTime });
    p.videoClipSegments = clips.map(stripClip);
    if (!p.splitPoints.some((s) => Math.abs(s - sourceTime) < 0.1)) {
      p.splitPoints.push(sourceTime);
      p.splitPoints.sort((a, b) => a - b);
    }
    return { label: "Split Clip", disarmSlice: true };
  };
}

function stripClip(c: VideoClipSegment): VideoClipSegment {
  return c.$extra ? { id: c.id, startTime: c.startTime, endTime: c.endTime, $extra: c.$extra } : { id: c.id, startTime: c.startTime, endTime: c.endTime };
}

/** TimelineViewController.isSliceableOutputTime (delegates to VideoSliceMath). */
export function isSliceableOutputTime(p: Project, outputTime: number): boolean {
  const map = fullTimeMap(p);
  const spans = effectiveVideoClipSegments(p).map((c) => ({ id: c.id, outputStart: map.outputTime(c.startTime), outputEnd: map.outputTime(c.endTime) }));
  return isSliceable(outputTime, 0, map.outputDuration, spans);
}

/** splitAtPlayhead (⌘B) */
export const splitAtPlayhead: Edit = (p, sel, env) => {
  const outputCurrent = fullTimeMap(p).outputTime(env.playheadSource);
  if (!isSliceableOutputTime(p, outputCurrent)) return null;
  const outcome = splitVideoClip(env.playheadSource)(p, sel, env);
  // ⌘B does not touch the slice tool.
  return outcome ? { label: outcome.label } : null;
};

/** Slice tool click at an OUTPUT time. */
export function sliceAt(outputTime: number): Edit {
  return (p, sel, env) => splitVideoClip(fullTimeMap(p).sourceTime(outputTime))(p, sel, env);
}

/** removeSplit(nearOutputTime:) */
export function removeSplit(outputTime: number): Edit {
  return (p) => {
    const sourceTime = fullTimeMap(p).sourceTime(outputTime);
    if (p.videoClipSegments.length > 0) {
      const clips = [...p.videoClipSegments].sort((a, b) => (a.startTime < b.startTime ? -1 : b.startTime < a.startTime ? 1 : 0));
      const trimStart = effectiveTrimStart(p);
      const idx = clips.findIndex((c) => c.startTime > trimStart + 0.01 && Math.abs(c.startTime - sourceTime) < 0.2);
      if (idx <= 0) return null;
      clips[idx - 1] = { ...clips[idx - 1], endTime: smax(clips[idx - 1].endTime, clips[idx].endTime) };
      clips.splice(idx, 1);
      p.videoClipSegments = clips;
      p.splitPoints = clips.slice(1).map((c) => c.startTime).sort((a, b) => a - b);
    } else {
      const idx = p.splitPoints.findIndex((s) => Math.abs(s - sourceTime) < 0.2);
      if (idx < 0) return null;
      p.splitPoints.splice(idx, 1);
    }
    return { label: "Remove Split" };
  };
}

/** A clip can only be lifted while another one remains. */
export function canDeleteClip(p: Project, id: string | null): boolean {
  if (!id) return false;
  const clips = effectiveVideoClipSegments(p);
  return clips.length > 1 && clips.some((c) => c.id === id);
}

/** deleteVideoClip — lifts a clip out, leaving a gap (never a ripple). */
export function deleteVideoClip(id: string): Edit {
  return (p, sel) => {
    const clips = effectiveVideoClipSegments(p);
    if (!(clips.length > 1 && clips.some((c) => c.id === id))) return null;
    const remaining = clips.filter((c) => c.id !== id);
    p.videoClipSegments = remaining.map(stripClip);
    p.splitPoints = remaining.slice(1).map((c) => c.startTime).sort((a, b) => a - b);
    return { label: "Delete Clip", selection: assign(sel, "clip", null) };
  };
}

export const toggleMute: Edit = (p) => {
  p.settings.muteRecordedAudio = !p.settings.muteRecordedAudio;
  return { label: p.settings.muteRecordedAudio ? "Mute Audio" : "Unmute Audio" };
};

const VIDEO_MIN_DURATION = 0.5;
const EDGE_ATTACHMENT_TOLERANCE = 1.0 / 15.0;

/** VideoTrackCommits.commitWholeDrag — times are OUTPUT (resolved by VideoTrackEditMath.resolvedTimes). */
export function commitWholeDrag(mode: VideoDragMode, delta: number, resolvedStart: number, resolvedEnd: number): Edit {
  return (p) => {
    if (mode === "none") return null;
    const map = fullTimeMap(p);
    const outputDuration = timelineOutputDuration(p);
    const sourceStart = effectiveTrimStart(p);
    const sourceEnd = effectiveTrimEnd(p);
    switch (mode) {
      case "move": {
        const windowLength = smax(VIDEO_MIN_DURATION, sourceEnd - sourceStart);
        const newStart = smin(smax(0, sourceStart + delta), smax(0, p.duration - windowLength));
        p.trimStart = newStart;
        p.trimEnd = newStart + windowLength;
        break;
      }
      case "resizeLeft": {
        const newSourceStart = resolvedStart >= 0 ? map.sourceTime(resolvedStart) : smax(0, sourceStart + resolvedStart);
        p.trimStart = smin(newSourceStart, sourceEnd - VIDEO_MIN_DURATION);
        break;
      }
      case "resizeRight": {
        const newSourceEnd =
          resolvedEnd <= outputDuration ? map.sourceTime(resolvedEnd) : smin(p.duration, sourceEnd + (resolvedEnd - outputDuration));
        p.trimEnd = smax(newSourceEnd, sourceStart + VIDEO_MIN_DURATION);
        break;
      }
    }
    return { label: mode === "move" ? "Slip Clip" : "Trim" };
  };
}

/** A clip span in both clocks (VideoClipRef). */
export interface VideoClipRef {
  id: string;
  sourceStart: number;
  sourceEnd: number;
  outputStart: number;
  outputEnd: number;
}

/** VideoTrackCommits.commitClipMove */
export function commitClipMove(clip: VideoClipRef, resolvedOutputStart: number): Edit {
  return (p) => {
    if (!(Math.abs(resolvedOutputStart - clip.outputStart) > 0.001)) return null;
    const map = fullTimeMap(p);
    const resolvedEnd = resolvedOutputStart + (clip.outputEnd - clip.outputStart);
    return updateClip(p, clip, "Move Clip", null, (seg) => {
      seg.startTime = map.sourceTime(resolvedOutputStart);
      seg.endTime = map.sourceTime(resolvedEnd);
    });
  };
}

/** VideoTrackCommits.commitClipEdge */
export function commitClipEdge(clip: VideoClipRef, side: TrackSide, resolvedOutput: number): Edit {
  return (p) => {
    const original = side === "left" ? clip.outputStart : clip.outputEnd;
    if (!(Math.abs(resolvedOutput - original) > 0.001)) return null;
    const map = fullTimeMap(p);
    if (side === "left") {
      const sourceStart = smin(map.sourceTime(resolvedOutput), clip.sourceEnd - VIDEO_MIN_DURATION);
      return updateClip(p, clip, "Resize Clip", "left", (seg) => {
        seg.startTime = sourceStart;
      });
    }
    const sourceEnd = smax(map.sourceTime(resolvedOutput), clip.sourceStart + VIDEO_MIN_DURATION);
    return updateClip(p, clip, "Resize Clip", "right", (seg) => {
      seg.endTime = sourceEnd;
    });
  };
}

/** VideoTrackCommits.updateClip — the single mutation funnel. */
function updateClip(p: Project, clip: VideoClipRef, label: string, edgeSide: TrackSide | null, mutate: (seg: VideoClipSegment) => void): EditOutcome | null {
  const clips = (p.videoClipSegments.length === 0 ? effectiveVideoClipSegments(p) : p.videoClipSegments).map((c) => ({ ...c }));
  const index = clips.findIndex(
    (c) => c.id === clip.id || (Math.abs(c.startTime - clip.sourceStart) < 0.01 && Math.abs(c.endTime - clip.sourceEnd) < 0.01),
  );
  if (index < 0) return null;
  mutate(clips[index]);
  clips[index].startTime = smax(0, smin(clips[index].startTime, p.duration));
  clips[index].endTime = smax(clips[index].startTime + VIDEO_MIN_DURATION, smin(clips[index].endTime, p.duration));
  p.videoClipSegments = clips;
  if (edgeSide) updateSpeedRegionsAnchoredToClipEdge(p, clip, clips[index], edgeSide);
  p.splitPoints = clips.slice(1).map((c) => c.startTime).sort((a, b) => a - b);
  return { label };
}

function updateSpeedRegionsAnchoredToClipEdge(p: Project, original: VideoClipRef, updated: VideoClipSegment, side: TrackSide) {
  const tol = EDGE_ATTACHMENT_TOLERANCE;
  const overlapping = p.speedRegions
    .map((_, i) => i)
    .filter((i) => p.speedRegions[i].startTime < original.sourceEnd + tol && p.speedRegions[i].endTime > original.sourceStart - tol);
  if (overlapping.length === 0) return;
  const only = overlapping.length === 1;
  for (const i of overlapping) {
    const region = p.speedRegions[i];
    const startsAtClipStart = Math.abs(region.startTime - original.sourceStart) <= tol;
    const endsAtClipEnd = Math.abs(region.endTime - original.sourceEnd) <= tol;
    if (side === "left") {
      if (!(endsAtClipEnd || (only && startsAtClipStart))) continue;
      region.startTime = smin(updated.startTime, region.endTime - VIDEO_MIN_DURATION);
    } else {
      if (!(startsAtClipStart || (only && endsAtClipEnd))) continue;
      region.endTime = smax(updated.endTime, region.startTime + VIDEO_MIN_DURATION);
    }
  }
}

// ── Speed regions ───────────────────────────────────────────────────────

/** addSpeedRegion(start:end:speed:) — SOURCE range (a clip segment's). */
export function addSpeedRegion(rawStart: number, rawEnd: number, speed: number): Edit {
  return (p, sel) => {
    const desiredStart = smax(0, smin(rawStart, p.duration));
    const desiredEnd = smax(desiredStart + 0.1, smin(rawEnd, p.duration));
    const [start, end] = findNonOverlappingSlot(
      [desiredStart, desiredEnd],
      p.speedRegions.map((r) => [r.startTime, r.endTime] as const),
      p.duration,
    );
    if (!(start < end)) return null;
    const region = newSpeedRegion(start, end);
    region.speed = speed;
    p.speedRegions.push(region);
    return { label: "Add Speed", selection: assign(sel, "speed", region.id) };
  };
}

export function changeSpeedRegion(id: string, speed: number): Edit {
  return (p) => {
    const r = p.speedRegions.find((x) => x.id === id);
    if (!r) return null;
    r.speed = speed;
    return { label: "Change Speed" };
  };
}

// ── VOICE lane ──────────────────────────────────────────────────────────

/** VoiceTrackCommits.commit — an OUTPUT-time clip value written back as SOURCE. */
export function commitVoiceClip(id: string, outputValue: VoiceOverClip): Edit {
  return (p) => {
    const idx = p.voiceOverClips.findIndex((c) => c.id === id);
    if (idx < 0) return null;
    p.voiceOverClips[idx] = voiceCommit(p.voiceOverClips[idx], outputValue, fullTimeMap(p));
    return { label: "Move Voice Over" };
  };
}

// ── ⌘D / ⌫ ──────────────────────────────────────────────────────────────

/** duplicateSelectedRegion (⌘D). */
export const duplicateSelectedRegion: Edit = (p, sel) => {
  if (sel.zoomId && sel.tiltId) {
    const z = p.zoomRegions.find((r) => r.id === sel.zoomId);
    const t = p.tiltRegions.find((r) => r.id === sel.tiltId);
    if (!z || !t) return null;
    const slot = duplicateSlot(p, [z.startTime, z.endTime], effectLaneSpans(p));
    if (!slot) return null;
    const zc = zoom(slot[0], slot[1], { zoomLevel: z.zoomLevel, focalPoint: z.focalPoint });
    const tc = newTiltRegion(slot[0], slot[1]);
    tc.pitch = t.pitch;
    tc.yaw = t.yaw;
    tc.roll = t.roll;
    p.zoomRegions.push(zc);
    p.tiltRegions.push(tc);
    return { label: "Duplicate Effect", selection: assignAll(sel, ["zoom", zc.id], ["tilt", tc.id]) };
  }
  if (sel.zoomId) {
    const source = p.zoomRegions.find((r) => r.id === sel.zoomId);
    if (source) {
      const slot = duplicateSlot(p, [source.startTime, source.endTime], effectLaneSpans(p));
      if (!slot) return null;
      const copy = zoom(slot[0], slot[1], { zoomLevel: source.zoomLevel, focalPoint: source.focalPoint });
      p.zoomRegions.push(copy);
      return { label: "Duplicate Zoom", selection: assign(sel, "zoom", copy.id) };
    }
  }
  if (sel.tiltId) {
    const source = p.tiltRegions.find((r) => r.id === sel.tiltId);
    if (source) {
      const slot = duplicateSlot(p, [source.startTime, source.endTime], effectLaneSpans(p));
      if (!slot) return null;
      const copy = newTiltRegion(slot[0], slot[1]);
      copy.pitch = source.pitch;
      copy.yaw = source.yaw;
      copy.roll = source.roll;
      p.tiltRegions.push(copy);
      return { label: "Duplicate Tilt", selection: assign(sel, "tilt", copy.id) };
    }
  }
  if (sel.blurId) {
    const source = p.blurRegions.find((r) => r.id === sel.blurId);
    if (source) {
      const slot = duplicateSlot(p, [source.startTime, source.endTime], [
        ...p.blurRegions.map((r) => [r.startTime, r.endTime] as const),
        ...p.highlightRegions.map((r) => [r.startTime, r.endTime] as const),
      ]);
      if (!slot) return null;
      // BlurRegion(startTime:endTime:label:rect:intensity:) — style/animated take their defaults.
      const copy = newBlurRegion(slot[0], slot[1]);
      copy.label = source.label;
      copy.rect = { ...source.rect };
      copy.intensity = source.intensity;
      p.blurRegions.push(copy);
      return { label: "Duplicate Blur", selection: assign(sel, "blur", copy.id) };
    }
  }
  if (sel.highlightId) {
    const source = p.highlightRegions.find((r) => r.id === sel.highlightId);
    if (source) {
      const slot = duplicateSlot(p, [source.startTime, source.endTime], [
        ...p.highlightRegions.map((r) => [r.startTime, r.endTime] as const),
        ...p.blurRegions.map((r) => [r.startTime, r.endTime] as const),
      ]);
      if (!slot) return null;
      const copy = newHighlightRegion(slot[0], slot[1]);
      copy.label = source.label;
      copy.rect = { ...source.rect };
      copy.opacity = source.opacity;
      p.highlightRegions.push(copy);
      return { label: "Duplicate Highlight", selection: assign(sel, "highlight", copy.id) };
    }
  }
  if (sel.speedId) {
    const source = p.speedRegions.find((r) => r.id === sel.speedId);
    if (source) {
      const slot = duplicateSlot(p, [source.startTime, source.endTime], p.speedRegions.map((r) => [r.startTime, r.endTime] as const));
      if (!slot) return null;
      const copy = newSpeedRegion(slot[0], slot[1]);
      copy.speed = source.speed;
      p.speedRegions.push(copy);
      return { label: "Duplicate Speed", selection: assign(sel, "speed", copy.id) };
    }
  }
  return null;
};

/** deleteSelectedRegion (⌫ / trash) — same priority order as the Mac. */
export const deleteSelectedRegion: Edit = (p, sel, env) => {
  if (sel.introSelected) return deleteIntroSlide(p, sel, env);
  if (sel.curtainSelected) return deleteCurtainUnveil(p, sel, env);
  if (sel.zoomId && sel.tiltId) return deleteEffectBlock(sel.zoomId, sel.tiltId)(p, sel, env);
  if (sel.zoomId) return deleteZoomRegion(sel.zoomId)(p, sel, env);
  if (sel.blurId) return deleteBlurRegion(sel.blurId)(p, sel, env);
  if (sel.voiceOverId) return deleteVoiceOverClip(sel.voiceOverId)(p, sel, env);
  if (sel.highlightId) return deleteHighlightRegion(sel.highlightId)(p, sel, env);
  if (sel.depthFocusId) return deleteDepthFocusRegion(sel.depthFocusId)(p, sel, env);
  if (sel.cameraLayoutId) return deleteCameraLayoutRegion(sel.cameraLayoutId)(p, sel, env);
  if (sel.speedId) return deleteSpeedRegion(sel.speedId)(p, sel, env);
  if (sel.tiltId) return deleteTiltRegion(sel.tiltId)(p, sel, env);
  if (sel.clipId) return deleteVideoClip(sel.clipId)(p, sel, env);
  if (sel.annotationId) return deleteAnnotation(sel.annotationId)(p, sel, env);
  return null;
};
