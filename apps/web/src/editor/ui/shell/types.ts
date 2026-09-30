/**
 * The editor shell's contract with the rest of the editor.
 *
 * The shell is PRESENTATION: it owns layout, chrome state (inspector
 * visibility/width, preview zoom, open popovers) and turns every user gesture
 * into a call on `EditorShellCallbacks`. It never touches the project model.
 * The store (editor/state) and engine (editor/engine) plug in through:
 *
 *   • `EditorShellProps.project`  — the few presentation facts the chrome
 *     shows (name, aspect, capabilities); re-render on change.
 *   • `PlayheadChannel`           — per-frame output time; subscribers write
 *     to the DOM/canvas directly, React never re-renders per frame.
 *   • `StageMount`                — the engine's slot on the stage.
 *   • `TimelineSnapshot` (timeline/types.ts) + `TimelineIntents`.
 */
import type { ReactNode } from "react";

import type { TimelineIntents, TimelineSnapshot } from "../timeline/types";

// ── Inspector tabs (InspectorTab.swift — order, titles, SF symbols) ─────

export type InspectorTabId =
  | "background"
  | "cursor"
  | "camera"
  | "audio"
  | "effects"
  | "motion"
  | "subtitles"
  | "brand"
  | "annotations";

export const INSPECTOR_TABS: ReadonlyArray<{ id: InspectorTabId; title: string; icon: string; filledIcon?: string }> = [
  { id: "background", title: "Background", icon: "paintpalette", filledIcon: "paintpalette.fill" },
  { id: "cursor", title: "Cursor", icon: "cursorarrow" },
  { id: "camera", title: "Camera", icon: "camera", filledIcon: "camera.fill" },
  { id: "audio", title: "Audio", icon: "speaker.wave.2", filledIcon: "speaker.wave.2.fill" },
  { id: "effects", title: "Effects", icon: "wand.and.stars" },
  { id: "motion", title: "Motion", icon: "figure.walk.motion" },
  { id: "subtitles", title: "Subtitles", icon: "captions.bubble", filledIcon: "captions.bubble.fill" },
  { id: "brand", title: "Brand", icon: "checkmark.seal", filledIcon: "checkmark.seal.fill" },
  { id: "annotations", title: "Annotate", icon: "pencil.tip" },
];

// ── Aspect ratios (Models/AspectRatio.swift raw values + hints) ─────────

export const ASPECT_RATIOS: ReadonlyArray<{ id: string; title: string; hint: string; ratio: number | null }> = [
  { id: "Auto", title: "Auto", hint: "Match the recording", ratio: null },
  { id: "16:9", title: "16:9", hint: "YouTube · X · LinkedIn", ratio: 16 / 9 },
  { id: "4:3", title: "4:3", hint: "Slides · legacy displays", ratio: 4 / 3 },
  { id: "1:1", title: "1:1", hint: "Instagram · LinkedIn feed", ratio: 1 },
  { id: "9:16", title: "9:16", hint: "TikTok · Shorts · Reels", ratio: 9 / 16 },
  { id: "21:9", title: "21:9", hint: "Cinematic · ultrawide", ratio: 21 / 9 },
  { id: "4:5", title: "4:5", hint: "Instagram feed portrait", ratio: 4 / 5 },
];

// ── Presentation facts the chrome needs ─────────────────────────────────

export type SyncState = "saved" | "saving" | "offline" | "conflict" | "local";

export interface ShellProjectInfo {
  name: string;
  /** AspectRatio raw value ("Auto", "16:9", …). */
  aspectRatio: string;
  /** Output canvas aspect (w/h) the stage letterboxes to — resolved by the
   *  store from aspect + export size + source size (Auto = source). */
  canvasAspect: number;
  /** Still capture: shows the Image | Video treatment switch in the top bar. */
  isImageCapture?: boolean;
  stillTreatment?: "image" | "video";
  hasCursorData?: boolean;
  hasRecordedCamera?: boolean;
  /** Cloud sync affordance (placeholder until state/cloud.ts lands). */
  syncState?: SyncState;
}

/** Transport/tool state the toolbar reflects (re-render on change — NOT per frame). */
export interface TransportState {
  isPlaying: boolean;
  canUndo: boolean;
  canRedo: boolean;
  /** Something deletable is selected (enables the red trash key). */
  canDelete: boolean;
  sliceArmed: boolean;
  isRecordingVoiceOver: boolean;
  /** Output duration (seconds) for the "total" timecode. */
  duration: number;
  /** Image treatment with nothing timed: timecodes hide (Mac hidesTimelinePlayhead). */
  hidesTime?: boolean;
  /** Image treatment: the timeline zoom is pinned (presentsTimelessTimeline). */
  timelessTimeline?: boolean;
}

/** Per-frame output time. Subscribers write straight to DOM/canvas. */
export interface PlayheadChannel {
  get(): number;
  subscribe(listener: (outputSeconds: number) => void): () => void;
}

/** A trivial PlayheadChannel for callers that only have a value. */
export function createPlayheadChannel(initial = 0): PlayheadChannel & { set(t: number): void } {
  let value = initial;
  const listeners = new Set<(t: number) => void>();
  return {
    get: () => value,
    set(t: number) {
      if (t === value) return;
      value = t;
      for (const l of listeners) l(t);
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

// ── Stage slot (where the engine mounts) ────────────────────────────────

/**
 * The stage hands the engine a host element that is EXACTLY the letterboxed
 * output canvas rect (project aspect, centred in the stage card, scaled by
 * the preview zoom). The engine creates its own <canvas> inside it (and may
 * `transferControlToOffscreen()` it) and returns a cleanup.
 *
 *   mount(host, viewport) → cleanup
 *   onViewport(viewport)  → called on every resize/zoom/DPR change
 *
 * The host is `position: relative; overflow: hidden`, sized in CSS px; the
 * engine should size its backing store to cssWidth·dpr × cssHeight·dpr.
 */
export interface StageViewport {
  cssWidth: number;
  cssHeight: number;
  dpr: number;
  /** Preview magnification (0.25…4). */
  zoom: number;
}

export interface StageMount {
  mount(host: HTMLDivElement, viewport: StageViewport): () => void;
  onViewport?(viewport: StageViewport): void;
}

// ── Toolbar pickers (TimelinePickerPopover rows) ────────────────────────

export type EffectsPick =
  | "motion"
  | "autoZoom"
  | "zoomIn"
  | "showcase"
  | "scaleDown"
  | "tilt"
  | "slide"
  | "curtain"
  | "cameraFull"
  | "cameraSideBySide"
  | "cameraHide";
export type FocusPick = "blur" | "pixelate" | "highlight" | "depthFocus";
export type AnnotationPick = "text" | "arrow" | "callout" | "drawing" | "rectangle" | "ellipse" | "tap";

// ── Callbacks (everything the user can DO in the chrome) ────────────────

export interface EditorShellCallbacks {
  /** "Captures" — back to the project picker. */
  onShowProjects?(): void;
  onExport?(): void;
  /** Placeholder share/web-sync affordances (wired by state/cloud later). */
  onShare?(): void;
  onSyncRetry?(): void;
  onRename?(name: string): void;
  onAspectChange?(aspectId: string): void;
  onStillTreatmentChange?(treatment: "image" | "video"): void;

  // Transport cluster (TimelineViewController.buildToolbar order)
  onGoToStart?(): void;
  onTogglePlay?(): void;
  onGoToEnd?(): void;
  onUndo?(): void;
  onRedo?(): void;
  onDelete?(): void;
  onEffectsPick?(pick: EffectsPick): void;
  onFocusPick?(pick: FocusPick): void;
  onToggleSlice?(): void;
  onSplitAtPlayhead?(): void;
  onAnnotationPick?(pick: AnnotationPick): void;
  onToggleVoiceOver?(): void;

  // Keyboard (TimelineViewController.handleKeyDown / handleCommandKey)
  /** ←/→ nudge in OUTPUT seconds (1/30 s, ⇧ = 1 s). */
  onStep?(deltaSeconds: number): void;
  onDuplicate?(): void;
  /** Esc with a clip selected. */
  onEscape?(): void;

  /** Inspector tab changes (the store may also drive `inspectorTab`). */
  onInspectorTabChange?(tab: InspectorTabId): void;
  onPreviewZoomChange?(zoom: number): void;
}

export interface EditorShellProps {
  project: ShellProjectInfo;
  transport: TransportState;
  playhead: PlayheadChannel;
  callbacks: EditorShellCallbacks;
  timeline: TimelineSnapshot;
  timelineIntents: TimelineIntents;
  stage?: StageMount;
  /** Controlled inspector tab (optional; uncontrolled otherwise). */
  inspectorTab?: InspectorTabId;
  /** One pane per tab — the shell only hosts them. */
  panes: Partial<Record<InspectorTabId, ReactNode>>;
  /** Extra top-bar content right of the sync affordance (dev toggles). */
  topBarAccessory?: ReactNode;
}
