/**
 * The inspector panes' contract with the store.
 *
 * Every pane is a PURE React component: it renders from `settings` (+ the
 * selected region read out of `project`) and reports every edit through a
 * callback — it never owns model state. Field names and enum raw values are
 * the core model's (= Swift's), so the store applies patches verbatim:
 *
 *   onSettingsChange({ cursorScale: 2 })             → project.settings
 *   onRegionChange("zoom", id, { zoomLevel: 2.4 })   → project.zoomRegions[id]
 *   actions.onAction({ type: "removeZoom", zoomId }) → the timeline's own
 *                                                      action vocabulary
 *
 * Optional keys are cleared with `undefined` (the serializer omits them —
 * Swift `encodeIfPresent`). Drags stream `onSettingsChange` /
 * `onRegionChange`; `onCommit` marks the undo-batch boundary (slider
 * release, discrete picks), exactly like BackgroundPane's original API.
 */
import type {
  Annotation,
  BlurRegion,
  CameraLayoutRegion,
  FocusRegion,
  HighlightRegion,
  Project,
  ProjectSettings,
  SubtitleSegment,
  TiltRegion,
  ZoomRegion,
} from "../../core/model";
import type { ClickSoundStyle, KeySoundStyle } from "../../core/model/enums";
import type { TimelineAction, TimelineTarget } from "../timeline/types";

export type RegionKind = "zoom" | "tilt" | "highlight" | "blur" | "focus" | "annotation" | "subtitle" | "cameraLayout";

export interface RegionPatchMap {
  zoom: Partial<ZoomRegion>;
  tilt: Partial<TiltRegion>;
  highlight: Partial<HighlightRegion>;
  blur: Partial<BlurRegion>;
  focus: Partial<FocusRegion>;
  annotation: Partial<Annotation>;
  subtitle: Partial<SubtitleSegment>;
  cameraLayout: Partial<CameraLayoutRegion>;
}

export type RegionChange = <K extends RegionKind>(kind: K, id: string, patch: RegionPatchMap[K]) => void;

/** The store's selection (state/selection.ts = the Mac EditorShellSelection).
 *  Structural so either `undefined` or `null` means "none". */
export interface PaneSelection {
  zoomId?: string | null;
  tiltId?: string | null;
  highlightId?: string | null;
  depthFocusId?: string | null;
  blurId?: string | null;
  annotationId?: string | null;
  cameraLayoutId?: string | null;
  voiceOverId?: string | null;
  speedId?: string | null;
  clipId?: string | null;
  introSelected?: boolean;
  curtainSelected?: boolean;
}

/** Project-level patch (store.updateProject) — the panes only write
 *  `subtitles` (Delete / Regenerate). */
export type ProjectPatch = Partial<Pick<Project, "subtitles">>;

/** Side effects a pane can ask for that are not plain field writes. All
 *  optional — a missing handler leaves its button visible but inert. */
export interface PaneActions {
  /** Timeline actions (addZoomAt / addTiltAt / addTiltToBlock /
   *  addZoomToBlock / removeZoom / removeTilt / delete). */
  onAction?(action: TimelineAction): void;
  /** Current playhead (OUTPUT seconds) — "At Playhead", add-at-playhead. */
  playheadTime?(): number;
  /** Slide switched on with a block selected: snap the slide onto that
   *  block's span (MotionPaneContext.onJoinSlideToSelectedBlock). Return
   *  false for a plain global slide. */
  onJoinSlideToSelectedBlock?(): boolean;
  onChooseBackgroundImage?(): void;
  onChooseWatermark?(): void;
  onRemoveWatermark?(): void;
  onChooseCurtainLogo?(): void;
  onRemoveCurtainLogo?(): void;
  onGenerateSubtitles?(): void;
  /** Transcribe again; the current cues are replaced only on success. */
  onRegenerateSubtitles?(): void;
  onDeleteSubtitles?(): void;
  /** Stop a running transcription (nothing is written). */
  onCancelSubtitles?(): void;
  /** Transcription progress (TranscriptionService) while generating. */
  subtitleStatus?: { busy: boolean; progress?: string; error?: string | null };
  onPlayClickSound?(style: ClickSoundStyle, volume: number): void;
  onPlayKeySound?(style: KeySoundStyle, volume: number): void;
  onRequestKeyPermission?(): void;
  /** Resolve a project-folder file (watermark / curtain logo) to a URL. */
  assetUrl?(fileName: string): string | undefined;
}

/** Recording facts the panes gate on. Derived from `project` when present;
 *  pass explicitly to override (e.g. keys.json shortcut data once loaded). */
export interface PaneFacts {
  hasRecordedCamera: boolean;
  isDeviceRecording: boolean;
  supportsMenuBar: boolean;
  hasKeystrokeData: boolean;
  /** keys.json carries at least one recorded shortcut (opt-in capture). */
  hasShortcutData: boolean;
  isWindowRecording: boolean;
  /** Input Monitoring is granted (Mac-only; the web has no permission). */
  hasKeyPermission: boolean;
}

export interface PaneProps {
  settings: ProjectSettings;
  /** Live patch (drags stream these). */
  onSettingsChange(patch: Partial<ProjectSettings>): void;
  /** Undo-batch boundary (slider release, discrete picks). */
  onCommit?(): void;
  /** The store's selection (EditorShellSelection shape). */
  selection?: PaneSelection | null;
  project?: Project;
  onRegionChange?: RegionChange;
  onProjectChange?(patch: ProjectPatch): void;
  actions?: PaneActions;
  facts?: Partial<PaneFacts>;
}

export function resolveFacts(project: Project | undefined, overrides?: Partial<PaneFacts>): PaneFacts {
  const kind = project?.recordingSourceKind;
  const base: PaneFacts = {
    hasRecordedCamera: project ? project.cameraVideoURL != null : false,
    isDeviceRecording: kind === "device" || (project?.sourceSegments ?? []).some((s) => s.kind === "device"),
    supportsMenuBar: kind !== "device",
    hasKeystrokeData: project?.keystrokeDataURL != null,
    hasShortcutData: false,
    isWindowRecording: kind === "window",
    hasKeyPermission: true,
  };
  return { ...base, ...overrides };
}

/** The selected regions, resolved from the timeline selection. */
export interface SelectedRegions {
  zoom?: ZoomRegion;
  tilt?: TiltRegion;
  highlight?: HighlightRegion;
  blur?: BlurRegion;
  focus?: FocusRegion;
  cameraLayout?: CameraLayoutRegion;
  annotation?: Annotation;
}

export function selectedRegions(selection: PaneSelection | null | undefined, project: Project | undefined): SelectedRegions {
  if (!selection || !project) return {};
  const find = <T extends { id: string }>(list: readonly T[], id: string | null | undefined) =>
    id ? list.find((r) => r.id === id) : undefined;
  return {
    zoom: find(project.zoomRegions, selection.zoomId),
    tilt: find(project.tiltRegions, selection.tiltId),
    highlight: find(project.highlightRegions, selection.highlightId),
    blur: find(project.blurRegions, selection.blurId),
    focus: find(project.focusRegions, selection.depthFocusId),
    cameraLayout: find(project.cameraLayoutRegions, selection.cameraLayoutId),
    annotation: find(project.annotations, selection.annotationId),
  };
}

/** The timeline's target → the store selection shape (for hosts that only
 *  track the timeline's TimelineTarget, e.g. the dev lab). */
export function selectionFromTarget(target: TimelineTarget | null | undefined, project?: Project): PaneSelection {
  if (!target) return {};
  switch (target.lane) {
    case "effects":
      return { zoomId: target.zoomId ?? null, tiltId: target.tiltId ?? null };
    case "focus": {
      if (target.isHighlight) return { highlightId: target.id };
      if (project?.focusRegions.some((r) => r.id === target.id)) return { depthFocusId: target.id };
      if (project?.cameraLayoutRegions.some((r) => r.id === target.id)) return { cameraLayoutId: target.id };
      return { blurId: target.id };
    }
    case "annotate":
      return { annotationId: target.id };
    case "voice":
      return { voiceOverId: target.clipId };
    case "video":
      return { clipId: target.clipId };
    case "intro":
      return { introSelected: true };
    case "curtain":
      return { curtainSelected: true };
  }
}
