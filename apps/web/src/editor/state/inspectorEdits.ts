/**
 * The Effects inspector's own edits — ports of the Motion pane context
 * closures in `Views/Editor/InspectorKit/InspectorPaneContexts.swift`
 * (`onAddZoomBlockAtPlayhead`, `onAddTiltBlockAtPlayhead`,
 * `onJoinSlideToSelectedBlock`, `freeEffectSlot`).
 *
 * These are NOT the timeline's context-menu adds (edits.addZoomRegion /
 * addTiltRegion): the inspector takes the playhead in SOURCE seconds
 * (`playback.currentTime` — `EditEnv.playheadSource` here, never an OUTPUT
 * time converted twice), places the block with `freeEffectSlot` and, when
 * the EFFECTS lane has no usable gap, refuses (the Mac beeps) instead of
 * stacking. A plain `ZoomRegion(startTime:endTime:)` / `TiltRegion(…,
 * pitch: 12)` is added — no Motion-tab skew seeding.
 */
import { newTiltRegion, newZoomRegion, type Project } from "../core/model";
import { smax, smin } from "../core/math/swift";
import { effectLaneSpans, fullTimeMap, type Edit } from "./edits";
import { assignAll } from "./selection";

/**
 * `freeEffectSlot(project:at:want:minDuration:)` — gap-based slot on the
 * EFFECTS lane (SOURCE seconds): the gap containing `time` if any, else the
 * nearest one, shrunk to fit. null when the lane has no usable gap.
 */
export function freeEffectSlot(p: Project, time: number, want = 3, minDuration = 0.8): [number, number] | null {
  // Swift `sorted { $0.0 < $1.0 }` over zoom spans then tilt spans; JS sort is stable.
  const spans = [...effectLaneSpans(p)].sort((a, b) => (a[0] < b[0] ? -1 : b[0] < a[0] ? 1 : 0));
  const gaps: Array<[number, number]> = [];
  let cursor = 0.0;
  for (const span of spans) {
    if (span[0] - cursor >= minDuration) gaps.push([cursor, span[0]]);
    cursor = smax(cursor, span[1]);
  }
  if (p.duration - cursor >= minDuration) gaps.push([cursor, p.duration]);
  if (gaps.length === 0) return null;
  let gap = gaps.find((g) => time >= g[0] && time < g[1]);
  if (!gap) {
    // `gaps.min { … }` — the first minimum wins.
    const dist = (g: [number, number]) => smin(Math.abs(g[0] - time), Math.abs(g[1] - time));
    gap = gaps[0];
    for (const g of gaps) if (dist(g) < dist(gap)) gap = g;
  }
  const length = smin(want, gap[1] - gap[0]);
  const start = smin(smax(time, gap[0]), gap[1] - length);
  return [start, start + length];
}

/** `onAddZoomBlockAtPlayhead` — null (the Mac's `NSSound.beep()`) when the lane is full. */
export const addZoomBlockAtPlayhead: Edit = (p, sel, env) => {
  const slot = freeEffectSlot(p, env.playheadSource);
  if (!slot) return null;
  const region = newZoomRegion(slot[0], slot[1]);
  p.zoomRegions.push(region);
  return { label: "Add Zoom", selection: assignAll(sel, ["tilt", null], ["zoom", region.id]) };
};

/** `onAddTiltBlockAtPlayhead` — `TiltRegion(startTime:endTime:pitch: 12)`; null = beep. */
export const addTiltBlockAtPlayhead: Edit = (p, sel, env) => {
  const slot = freeEffectSlot(p, env.playheadSource);
  if (!slot) return null;
  const region = newTiltRegion(slot[0], slot[1]);
  region.pitch = 12;
  region.yaw = 0;
  region.roll = 0;
  p.tiltRegions.push(region);
  return { label: "Add Tilt", selection: assignAll(sel, ["zoom", null], ["tilt", region.id]) };
};

/**
 * `onJoinSlideToSelectedBlock` — Slide switched on with an EFFECTS block
 * selected: the slide takes that block's span, converted SOURCE → OUTPUT
 * through the trim + speed map (`introSlideStart` / `introSlideDuration` are
 * OUTPUT seconds). null = no block selected (a plain global slide).
 */
export const joinSlideToSelectedBlock: Edit = (p, sel) => {
  const zoom = sel.zoomId ? p.zoomRegions.find((r) => r.id === sel.zoomId) : undefined;
  const tilt = !zoom && sel.tiltId ? p.tiltRegions.find((r) => r.id === sel.tiltId) : undefined;
  const block = zoom ?? tilt;
  if (!block) return null;
  const map = fullTimeMap(p);
  const s0 = map.outputTime(block.startTime);
  const s1 = map.outputTime(block.endTime);
  if (p.settings.introSlideStyle === "Off") p.settings.introSlideStyle = "Bottom";
  p.settings.introSlideStart = s0;
  p.settings.introSlideDuration = smax(0.3, s1 - s0);
  return { label: "Slide" };
};
