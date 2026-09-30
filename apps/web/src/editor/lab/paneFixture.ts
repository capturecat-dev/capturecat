/**
 * DEV-ONLY fixture for the inspector panes in /editor-lab/shell.
 *
 * `paneProbeProject()` is the core-model twin of the Mac probe project
 * (EditorShellProbeHarness.makeProject + its `--pane-shots` additions):
 * 4 s recording, zoom 0.5–1.5 s, 2× speed 2.0–3.0 s, a "Probe label" text
 * annotation, a camera track, and the regions the selection states need.
 * `paneState(name)` reproduces each `--pane-shots` state (tab + settings +
 * selection), so the web pane and the Mac capture `panes-<theme>/<name>.png`
 * are the same fixture: `?tab=<tab>&pane=<name>`.
 */
import type { Annotation, Project, ProjectSettings } from "../core/model";
import {
  newAnnotation,
  newBlurRegion,
  newFocusRegion,
  newHighlightRegion,
  newProject,
  newSpeedRegion,
  newSubtitleSegment,
  newTiltRegion,
  newZoomRegion,
} from "../core/model";
import type { PaneSelection } from "../ui/panes/types";
import type { InspectorTabId } from "../ui/shell/types";

export function paneProbeProject(): Project {
  const p = newProject({ id: "lab-pane-probe", name: "Shell Probe", duration: 4, videoURL: "lab://screen.mov", cameraVideoURL: "lab://screen.mov" });
  p.trimStart = 0;
  p.trimEnd = 4;
  p.settings.muteRecordedAudio = true;
  p.settings.showCamera = true;
  p.zoomRegions = [newZoomRegion(0.5, 1.5, "zoom-1")];
  p.speedRegions = [newSpeedRegion(2, 3, "speed-1")];
  const text = newAnnotation("text", 1, 2.5, "anno-1");
  text.text = "Probe label";
  const arrow = newAnnotation("arrow", 0.2, 0.9, "anno-arrow");
  const rect = newAnnotation("rectangle", 2.6, 3.4, "anno-rect");
  const drawing: Annotation = {
    ...newAnnotation("drawing", 3.0, 3.8, "anno-drawing"),
    drawingStrokes: [
      [
        { x: 0.2, y: 0.2 },
        { x: 0.3, y: 0.3 },
      ],
      [
        { x: 0.5, y: 0.5 },
        { x: 0.6, y: 0.4 },
      ],
    ],
  };
  const tap = newAnnotation("tap", 3.4, 3.9, "anno-tap");
  p.annotations = [text, arrow, rect, drawing, tap];
  p.highlightRegions = [newHighlightRegion(2.6, 3.2, "hl-1")];
  p.blurRegions = [{ ...newBlurRegion(1.6, 2.4, "blur-1"), style: "Pixelate" }];
  p.focusRegions = [newFocusRegion(0.2, 1.2, "focus-1")];
  return p;
}

export interface PaneState {
  tab: InspectorTabId;
  settings?: Partial<ProjectSettings>;
  selection?: PaneSelection;
  edit?: (p: Project) => void;
}

/** The Mac `--pane-shots` states, by name. */
export const PANE_STATES: Record<string, PaneState> = {
  background: { tab: "background" },
  cursor: { tab: "cursor" },
  "cursor-all": { tab: "cursor", settings: { autoHideCursor: true, smoothCursor: true, clickSoundEnabled: true, keySoundEnabled: true } },
  camera: { tab: "camera" },
  audio: { tab: "audio" },
  effects: { tab: "effects" },
  "effects-all": { tab: "effects", settings: { introSlideStyle: "Bottom", curtainUnveilCorner: "Top Left", parallaxStrength: 0.4, motionBlur: true } },
  "effects-zoom": { tab: "effects", selection: { zoomId: "zoom-1" } },
  "effects-tilt": {
    tab: "effects",
    selection: { zoomId: "zoom-1", tiltId: "tilt-1" },
    edit: (p) => {
      p.tiltRegions = [{ ...newTiltRegion(0.5, 1.5, "tilt-1"), pitch: 12, yaw: 0, roll: -3 }];
    },
  },
  "effects-highlight": { tab: "effects", selection: { highlightId: "hl-1" } },
  "effects-blur": { tab: "effects", selection: { blurId: "blur-1" } },
  "effects-focus": { tab: "effects", selection: { depthFocusId: "focus-1" } },
  motion: { tab: "motion" },
  subtitles: { tab: "subtitles" },
  "subtitles-on": {
    tab: "subtitles",
    settings: { showSubtitles: true },
    edit: (p) => {
      p.subtitles = [newSubtitleSegment(0.2, 1.4, "Welcome to the probe", "sub-1"), newSubtitleSegment(1.6, 3.1, "Second caption line", "sub-2")];
    },
  },
  brand: { tab: "brand" },
  "brand-on": { tab: "brand", settings: { showWatermark: true, watermarkFileName: "watermark-probe.png" } },
  annotations: { tab: "annotations" },
  "annotations-text": { tab: "annotations", selection: { annotationId: "anno-1" } },
  "annotations-arrow": { tab: "annotations", selection: { annotationId: "anno-arrow" } },
  "annotations-rectangle": { tab: "annotations", selection: { annotationId: "anno-rect" } },
  "annotations-drawing": { tab: "annotations", selection: { annotationId: "anno-drawing" } },
  "annotations-tap": { tab: "annotations", selection: { annotationId: "anno-tap" } },
};

/** Project + selection for a named state (unknown names = the plain fixture). */
export function paneStateProject(name: string | null): { project: Project; selection: PaneSelection | null; tab: InspectorTabId | null } {
  const project = paneProbeProject();
  const state = name ? PANE_STATES[name] : undefined;
  if (!state) return { project, selection: null, tab: null };
  state.edit?.(project);
  if (state.settings) project.settings = { ...project.settings, ...state.settings };
  return { project, selection: state.selection ?? null, tab: state.tab };
}
