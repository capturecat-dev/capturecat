/**
 * The exporter's per-EXPORT cursor/keystroke setup (VideoExporter.export
 * ≈ lines 119–165 and 339–403), derived once per Scene and shared by the
 * cursor, click-ripple and keystroke passes (and, through `soundCues`, the
 * audio mix):
 *
 *   cursor.json → [smoothCursor? CursorSmoother] → CursorSpringMath →
 *   CursorEndBehaviorMath(effectiveTrimEnd)       (core cursorChain)
 *   → hidden-menu-bar crop shift                  (core shiftForMenuBarCrop)
 *   fullCursorCoordinateSize / sourceToOutputScale / maximumZoom /
 *   cursorRasterScale / resolvedCursorCoordinateSize (core exportCursorSetup)
 *   makeCursorAsset(style, rasterScale)            (core makeCursorAsset)
 *   keys.json → KeystrokeOverlayMath.displayEvents(scopedTo:) when showKeystrokes
 *
 * `outputSize` is the pass target (the preview canvas or the export frame),
 * `naturalSize` the recording's display size, `canvasScale` the geometry's
 * (output ÷ reference canvas) — exactly the exporter's inputs.
 */
import type { CursorEvent, KeystrokeEvent, Project, ProjectSettings, Rect, Size } from "../../../core/model/types";
import { effectiveTrimEnd } from "../../../core/time/clips";
import { processCursorEvents, recordingCoordinateSize, shiftForMenuBarCrop } from "../../../core/math/cursorChain";
import { exportCursorSetup, makeCursorAsset, type ExportCursorAsset, type ExportCursorSetup } from "../../../core/math/exportCursor";
import { displayEventsScoped, type DisplayEvent } from "../../../core/math/keystrokeOverlay";
import type { Scene } from "../types";
import { decodeCursorRecording, decodeKeystrokeRecording } from "./recordings";

export interface CursorSceneData {
  project: Project;
  settings: ProjectSettings;
  /** The exporter's `cursorEvents` after the chain AND the menu-bar shift. */
  events: CursorEvent[];
  /** `resolvedCursorCoordinateSize` (cropped) — every cursor consumer's space. */
  coordinateSize: Size;
  setup: ExportCursorSetup;
  /** Sprite sizing (`rasterPixelSize` null only when the style has no size). */
  asset: ExportCursorAsset;
  outputSize: Size;
  canvasScale: number;
  /** `layout.videoRect` in CoreImage Y-UP output pixels. */
  layoutVideoRect: Rect;
  /** Shortcut-pill display list (empty unless `showKeystrokes`). */
  keystrokeDisplay: DisplayEvent[];
}

/** Chain-processed cursor events (before the menu-bar shift) + the recorded
 * coordinate size — shared with the sound cues (the exporter derives its
 * click times from exactly this list). */
export function chainedCursorEvents(project: Project, cursorJson: unknown): { events: CursorEvent[]; recordedSize: Size } {
  const recording = decodeCursorRecording(cursorJson);
  if (!recording) return { events: [], recordedSize: { width: 0, height: 0 } };
  return {
    events: processCursorEvents(recording.events, project.settings, effectiveTrimEnd(project)),
    recordedSize: recordingCoordinateSize(recording),
  };
}

export function keystrokeEvents(keysJson: unknown): KeystrokeEvent[] {
  return decodeKeystrokeRecording(keysJson)?.events ?? [];
}

const cache = new WeakMap<Scene, CursorSceneData | null>();

/** Memoized per Scene object (a new Scene is built on every project / size change). */
export function cursorSceneData(scene: Scene): CursorSceneData | null {
  if (cache.has(scene)) return cache.get(scene)!;
  const data = build(scene);
  cache.set(scene, data);
  return data;
}

function build(scene: Scene): CursorSceneData | null {
  const project = scene.extras.project;
  if (!project) return null;
  const settings = project.settings;
  const outputSize = scene.target;
  const naturalSize = scene.sourceSize;

  // `project.cursorDataURL` present → loadRecording; `try?` → [] on failure.
  const { events: chained, recordedSize } = project.cursorDataURL
    ? chainedCursorEvents(project, scene.extras.assets.cursor)
    : { events: [], recordedSize: { width: 0, height: 0 } };
  const setup = exportCursorSetup(recordedSize, naturalSize, outputSize, settings, project);
  const events = shiftForMenuBarCrop(chained, setup.fullCursorCoordinateSize, setup.menuBarCrop);
  const asset = makeCursorAsset(settings.cursorStyle, setup.cursorRasterScale);

  const vr = scene.geometry.videoRect; // Y-down
  const layoutVideoRect: Rect = { x: vr.x, y: outputSize.height - vr.y - vr.height, width: vr.width, height: vr.height };

  const keystrokeDisplay =
    settings.showKeystrokes && project.keystrokeDataURL
      ? displayEventsScoped(keystrokeEvents(scene.extras.assets.keystrokes), project)
      : [];

  return {
    project,
    settings,
    events,
    coordinateSize: setup.resolvedCursorCoordinateSize,
    setup,
    asset,
    outputSize,
    canvasScale: scene.geometry.canvasScale,
    layoutVideoRect,
    keystrokeDisplay,
  };
}
