/**
 * Timeline data in / intents out — the web twin of TimelineCanvasSnapshot +
 * TimelineCanvasCallbacks (Views/Editor/TimelineCanvasView.swift) and the
 * VIDEO/VOICE row models.
 *
 * ALL TIMES ARE OUTPUT SECONDS (post trim + speed map). The store converts to
 * source time at the intent boundary with the SpeedTimeMap port, exactly like
 * TimelineViewController's wrappers — the timeline never sees the model or
 * the time map.
 */
import type { ProjectSourceSegment, VoiceOverClip } from "../../core/model";

export interface EffectBlock {
  /** Stable key: "e:<zoomId|->:<tiltId|->". */
  key: string;
  zoomId?: string;
  tiltId?: string;
  start: number;
  end: number;
  zoomLevel?: number;
  pitch: number;
  yaw: number;
  roll: number;
  /** The Slide rides this block (linked) — shows the slide glyph. */
  hasSlide?: boolean;
  selected: boolean;
}

/** Settings-backed chips on the EFFECTS lane (Intro Slide, Curtain Unveil). */
export interface SettingsChip {
  start: number;
  end: number;
  label: string;
  /** SF symbol name. */
  icon: string;
  selected: boolean;
}

export interface FocusBlock {
  id: string;
  /** Highlight (purple) vs blur/depth-focus/camera-layout (slate). */
  isHighlight: boolean;
  start: number;
  end: number;
  label: string;
  selected: boolean;
}

export interface AnnotateBlock {
  id: string;
  start: number;
  end: number;
  label: string;
  /** SF symbol (TimelineViewController.annotationLaneIcon). */
  icon: string;
  selected: boolean;
}

export interface VideoClip {
  id: string;
  outputStart: number;
  outputEnd: number;
  sourceStart: number;
  sourceEnd: number;
  selected: boolean;
  /** Dominant speed readout for the info pill ("2x"), absent at 1×. */
  pillSpeedLabel?: string;
  /** One speed region covers the clip edge-to-edge → one retimed slab. */
  fillSpeed?: number;
  fillRegionId?: string;
}

export interface VideoSegment {
  id: string;
  clipId: string;
  outputStart: number;
  outputEnd: number;
  sourceStart: number;
  sourceEnd: number;
  speed: number;
  regionId?: string;
  /** "3s · 2x" (TimelineVideoRowModel.segmentLabel). */
  label: string;
  showsLeadingDivider: boolean;
  startsAtSplit: boolean;
}

/** Joined boundary between two touching clips (the two-sided resize hotspot). */
export interface VideoBoundary {
  id: string;
  leftClipId: string;
  rightClipId: string;
  outputTime: number;
}

export interface VideoRow {
  /** Trim window in output time — the block's committed span. */
  regionStart: number;
  regionEnd: number;
  /** Single-clip mode: the whole block trims as one. */
  usesWholeTrackDrag: boolean;
  clips: VideoClip[];
  segments: VideoSegment[];
  muted: boolean;
  hasAudio: boolean;
  /** TimelineVideoRowModel.boundaries (multi-clip mode). */
  boundaries?: VideoBoundary[];
  /** OUTPUT-time snap candidates for VideoTrackEditMath — WITHOUT the
   *  playhead (the renderer appends the live playhead at drag start). */
  snapCandidates?: number[];
}

export interface VoiceClip {
  id: string;
  start: number;
  end: number;
  label: string;
  selected: boolean;
  waveform?: ArrayLike<number>;
  /** The clip in OUTPUT time (VoiceTrackCommits.outputClip) — the value
   *  VoiceTrackEditMath resolves drags against. */
  value?: VoiceOverClip;
}

export interface VoiceRow {
  clips: VoiceClip[];
  /** OUTPUT-time snap candidates (TimelineVoiceRowModel) — WITHOUT the playhead. */
  snapCandidates?: number[];
  /** The live "Recording Voice Over" block while recording. */
  live?: { start: number; end: number; samples: ArrayLike<number> };
}

/** One decoded filmstrip frame (TimelineThumbnail): its requested source time + pixel size. */
export interface TimelineThumbnailImage {
  time: number;
  image: CanvasImageSource;
  width: number;
  height: number;
}

/** Heavy, non-diffed media the lanes draw (filmstrip, waveform). */
export interface TimelineAssets {
  /** Bumps whenever any asset below changes (triggers a redraw). */
  version: number;
  /** Decoded thumbnails ascending by time — tiled exactly like the Mac
   *  (core/time/filmstrip layoutFilmstrip). Takes precedence over `thumbnailAt`. */
  thumbnails?: readonly TimelineThumbnailImage[];
  /** project.sourceSegments: device-source tiles crop to their content rect. */
  sourceSegments?: readonly ProjectSourceSegment[];
  /** Filmstrip tile for a SOURCE time; null = not decoded yet. */
  thumbnailAt?: (sourceSeconds: number) => CanvasImageSource | null;
  /** width / height of a thumbnail (source video aspect). */
  thumbnailAspect?: number;
  /** Peak samples (0…1) spanning the trim window in source time. */
  audioSamples?: ArrayLike<number>;
  trimSourceStart?: number;
  trimSourceEnd?: number;
}

export interface TimelineSnapshot {
  outputDuration: number;
  trimStartOutput: number;
  trimEndOutput: number;
  effects: EffectBlock[];
  intro?: SettingsChip;
  curtain?: SettingsChip;
  focus: FocusBlock[];
  annotate: AnnotateBlock[];
  video?: VideoRow;
  voice?: VoiceRow;
  /** Slice tool armed: the VIDEO lane shows the cut indicator. */
  sliceArmed?: boolean;
  /** Image treatment, nothing timed: bare ruler, idle playhead hidden. */
  timeless?: boolean;
  /** Image treatment WITH timed effects: ticks dimmed (labels legible). */
  dimmedRuler?: boolean;
  assets?: TimelineAssets;
}

export type TimelineTarget =
  | { lane: "effects"; key: string; zoomId?: string; tiltId?: string }
  | { lane: "focus"; id: string; isHighlight: boolean }
  | { lane: "annotate"; id: string }
  | { lane: "video"; clipId: string }
  | { lane: "voice"; clipId: string }
  | { lane: "intro" }
  | { lane: "curtain" };

export type LaneId = "video" | "voice" | "effects" | "focus" | "annotate";

/** Context-menu actions (the lanes' right-click menus, 1:1 with the Mac). */
export type TimelineAction =
  | { type: "addZoomAt"; time: number }
  | { type: "addTiltAt"; time: number }
  | { type: "addHighlightAt"; time: number }
  | { type: "addBlurAt"; time: number }
  | {
      type: "addAnnotationAt";
      time: number;
      annotation: "text" | "arrow" | "callout" | "drawing" | "rectangle" | "ellipse" | "tap";
    }
  | { type: "setZoomLevel"; zoomId: string; level: number }
  | { type: "addTiltToBlock"; zoomId: string }
  | { type: "addZoomToBlock"; tiltId: string }
  | { type: "removeZoom"; zoomId: string }
  | { type: "removeTilt"; tiltId: string }
  | { type: "delete"; target: TimelineTarget }
  | { type: "setSpeed"; sourceStart: number; sourceEnd: number; speed: number }
  | { type: "changeSpeed"; regionId: string; speed: number }
  | { type: "removeSpeed"; regionId: string }
  | { type: "removeSplit"; outputTime: number }
  | { type: "toggleMute" };

export interface TimelineIntents {
  /** Live scrub while dragging (inexact seek). */
  scrub(outputSeconds: number): void;
  /** Committed seek on release (exact). */
  seek(outputSeconds: number): void;
  /** Select a block, or clear one lane's selection (target null + lane). */
  select(target: TimelineTarget | null, lane?: LaneId): void;
  /** Move/resize committed on mouse-up (only when the gesture dragged). */
  commitTimes(target: TimelineTarget, start: number, end: number): void;
  /** Optional live preview during a drag (the store may ignore it). */
  previewTimes?(target: TimelineTarget, start: number, end: number): void;
  /** Settings chips: click opens their pane; drags edit live. */
  openChip?(chip: "intro" | "curtain"): void;
  moveChip?(chip: "intro" | "curtain", newStart: number): void;
  resizeChip?(chip: "intro" | "curtain", newEnd: number): void;
  /** Whole-track trim of the VIDEO block (single-clip mode), committed on release. */
  trimVideo?(edge: "start" | "end", outputSeconds: number): void;
  /** Slice tool click: split the clip at this output time. */
  sliceAt?(outputSeconds: number): void;
  action?(action: TimelineAction): void;
  /** Horizontal zoom changed by pinch (the toolbar slider mirrors it). */
  scaleChanged?(scale: number): void;

  // VIDEO row (VideoTrackCommits) — OUTPUT times resolved by the core
  // VideoTrackEditMath, exactly like TimelineCanvasView.videoMouseUp.
  /** Whole-track trim/slip (≤ 1 clip): mode, raw delta, resolved span. */
  videoCommitWhole?(mode: "move" | "resizeLeft" | "resizeRight", delta: number, resolvedStart: number, resolvedEnd: number): void;
  /** Per-clip move (multi-clip mode). */
  videoCommitClipMove?(clipId: string, resolvedOutputStart: number): void;
  /** Per-clip edge / joined-boundary resize. */
  videoCommitClipEdge?(clipId: string, side: "left" | "right", resolvedOutput: number): void;
  /** VOICE clip drag (VoiceTrackEditMath.resolvedClip, OUTPUT time). */
  voiceCommit?(clipId: string, outputValue: VoiceOverClip): void;
}
