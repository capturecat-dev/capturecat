/**
 * The shared cursor-event chain and the exporter's hidden-menu-bar crop.
 *
 * `processCursorEvents` is the chain BOTH Mac renderers run on the recorded
 * events (confirmed identical at commit da569841):
 *
 *   - Services/VideoExporter.swift `export` (lines 125–143):
 *       settings.smoothCursor ? CursorSmoother(factor: smoothingFactor).smooth : events
 *       → CursorSpringMath.apply(events:settings:)
 *       → CursorEndBehaviorMath.apply(trimEnd: project.effectiveTrimEnd,
 *            loopToStart: cursorLoopToStart, stopAtEnd: cursorStopAtEnd)
 *   - Views/AppKitSurfaces/EditorPlaybackController.swift
 *     `applyCursorSmoothing(settings:trimEnd:)` — the same three calls; every
 *     caller passes `project.effectiveTrimEnd`.
 *
 * Note: `smoothCursor` is forced false on every project decode (see
 * ProjectSettings.init(from:)), but the chain still honours it.
 *
 * `menuBarCrop` / `shiftForMenuBarCrop` / `menuBarCroppedSize` port the
 * exporter's hidden-menu-bar crop (VideoExporter.export lines 382–408; the
 * preview's PreviewCompositorView.menuBarCropFraction / effectiveCursorEvents /
 * resolvedCursorCoordinateSize are identical): the top strip of a pure display
 * recording is removed, so layout uses the shrunken size and every cursor
 * event's Y shifts up by the strip (Y-DOWN recording points).
 *
 * `recordingCoordinateSize` is the loader's
 * `recording.hasValidCoordinateSpace ? recording.coordinateSize : .zero`.
 *
 * Locked to Swift by `cursorChain` (chain) and `cursorMenuBarCrop` (verbatim
 * oracle of the inline crop — it lives inside `export`).
 */
import { menuBarCrop as exportMenuBarCrop } from "./exportLayout";
import type { CursorEvent, CursorRecording, Project, ProjectSettings, Size } from "../model/types";
import { MenuBarReplacement, RecordingSourceKind } from "../model/enums";
import { smooth } from "./cursorSmoother";
import { apply as applySpring } from "./cursorSpringMath";
import { apply as applyEndBehavior } from "./cursorEndBehaviorMath";
import { smax, smin } from "./swift";

export type CursorChainSettings = Pick<
  ProjectSettings,
  | "smoothCursor"
  | "smoothingFactor"
  | "cursorFluidEnabled"
  | "cursorTension"
  | "cursorFriction"
  | "cursorMass"
  | "cursorLoopToStart"
  | "cursorStopAtEnd"
>;

/**
 * smooth? → spring → end behaviour. `effectiveTrimEnd` is
 * `Project.effectiveTrimEnd` (core/time/clips.ts `effectiveTrimEnd(project)`).
 */
export function processCursorEvents(
  events: readonly CursorEvent[],
  settings: CursorChainSettings,
  effectiveTrimEnd: number,
): CursorEvent[] {
  const smoothed = settings.smoothCursor ? smooth(events, settings.smoothingFactor) : events.slice();
  const sprung = applySpring(smoothed, settings);
  return applyEndBehavior(sprung, effectiveTrimEnd, settings.cursorLoopToStart, settings.cursorStopAtEnd);
}

/** `recording.hasValidCoordinateSpace == true ? recording.coordinateSize : .zero`
 * (null recording → zero). */
export function recordingCoordinateSize(
  recording: Pick<CursorRecording, "coordinateWidth" | "coordinateHeight"> | null | undefined,
): Size {
  if (recording && recording.coordinateWidth > 0 && recording.coordinateHeight > 0) {
    return { width: recording.coordinateWidth, height: recording.coordinateHeight };
  }
  return { width: 0, height: 0 };
}

/** The exporter's menuBarCrop fraction (0 when no crop applies) — single
 * source: exportLayout.menuBarCrop. */
export function menuBarCrop(
  settings: Pick<ProjectSettings, "menuBarReplacement" | "menuBarHeight">,
  project: Pick<Project, "recordingSourceKind" | "sourceSegments">,
): number {
  return exportMenuBarCrop(settings, project.recordingSourceKind, project.sourceSegments.map((s) => s.kind));
}

/** `CGSize(width: size.width, height: size.height * (1 - crop))` — used for
 * both `effectiveNaturalSize` (from the video's natural size) and
 * `resolvedCursorCoordinateSize` (from `fullCursorCoordinateSize`). */
export function menuBarCroppedSize(size: Size, crop: number): Size {
  return { width: size.width, height: size.height * (1 - crop) };
}

/** `if menuBarCrop > 0 { shift = fullCursorCoordinateSize.height * menuBarCrop; y -= shift }`.
 * Returns a copy (unchanged events when there is no crop). */
export function shiftForMenuBarCrop(
  events: readonly CursorEvent[],
  fullCursorCoordinateSize: Size,
  crop: number,
): CursorEvent[] {
  if (!(crop > 0)) return events.slice();
  const shift = fullCursorCoordinateSize.height * crop;
  return events.map((e) => ({ timestamp: e.timestamp, x: e.x, y: e.y - shift, isClick: e.isClick }));
}
