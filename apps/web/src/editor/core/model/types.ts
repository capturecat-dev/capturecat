/**
 * In-memory project model — a 1:1 mirror of the Swift types that
 * `Project.encode(to:)` writes to project.json.
 *
 * Conventions (see ../../ARCHITECTURE.md):
 * - Field names are the Swift property names. Where the on-disk encoding
 *   differs from the in-memory shape it is noted and handled by
 *   `parse.ts` / `serialize.ts` (e.g. ZoomRegion.focalPoint is `[x, y]` on disk;
 *   Blur/Highlight/Focus `rect` is `rectX/rectY/rectW/rectH` on disk).
 * - Swift `Optional` that is ENCODED as JSON null (`c.encode(optional)`) is
 *   `T | null`; Optional that is `encodeIfPresent` (key omitted when nil) is
 *   `T | undefined` (`?:`). This distinction is persistence identity.
 * - `Date` is Swift's default JSONEncoder encoding: a Double of seconds since
 *   the 2001-01-01T00:00:00Z reference date (see `swiftDate.ts`).
 * - `URL` is its `absoluteString` (JSONEncoder special-cases URL).
 * - `UUID` is its `uuidString` (uppercase when written by Swift).
 * - `$extra` holds keys this model does not know (written by a newer Mac build
 *   or legacy keys Swift ignores). They are re-emitted verbatim on serialize so
 *   the web never drops data. Never read or write `$extra` from feature code.
 */
import type {
  AnimationSpeed,
  AnnotationEffect,
  AnnotationType,
  AspectRatio,
  BackgroundType,
  BlurStyle,
  CameraFilterStyle,
  CameraLayoutMode,
  CameraOrientation,
  CameraPosition,
  CameraShape,
  CameraTagPosition,
  ClickSoundStyle,
  CurtainUnveilCorner,
  CursorStyle,
  ExportFormat,
  ExportResolution,
  FocusRegionStyle,
  FrameShape,
  IntroSlideStyle,
  KeySoundStyle,
  KeystrokeCategory,
  KeystrokeOverlayAnimation,
  KeystrokeOverlayPosition,
  MenuBarReplacement,
  MenuBarTitleAlignment,
  RecordingSourceKind,
  ScreenTiltMode,
  StillTreatment,
  SubtitlePosition,
  SubtitleStyle,
  SubtitleWeight,
  VideoPlacement,
  ZoomAnimationStyle,
} from "./enums";

/** Unknown-key bag, preserved verbatim across parse → serialize. */
export type ExtraKeys = Record<string, unknown>;

export interface HasExtra {
  /** Keys unknown to this model (kept verbatim; see module doc). */
  $extra?: ExtraKeys;
}

/** Swift `UUID.uuidString`. */
export type UUIDString = string;

/** CoreGraphics value types (plain data). */
export interface Point {
  x: number;
  y: number;
}
export interface Size {
  width: number;
  height: number;
}
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** Extensions/Color+Codable.swift — four stored sRGB doubles. */
export interface CodableColor extends HasExtra {
  red: number;
  green: number;
  blue: number;
  opacity: number;
}

/** Annotation.swift `CodablePoint` — synthesized `{x, y}`. */
export interface CodablePoint extends HasExtra {
  x: number;
  y: number;
}

/** ExportSettings.swift */
export interface ExportSettings extends HasExtra {
  format: ExportFormat;
  resolution: ExportResolution;
  /** Swift `Int`. */
  fps: number;
  quality: number;
  /** Swift `Int`. */
  customWidth: number;
  /** Swift `Int`. */
  customHeight: number;
  collapseStaticSpans: boolean;
}

/** ProjectSettings.swift — every persisted key, in `encode(to:)` order. */
export interface ProjectSettings extends HasExtra {
  backgroundType: BackgroundType;
  gradientStartColor: CodableColor;
  gradientEndColor: CodableColor;
  solidColor: CodableColor;
  /** Encoded as null when nil. */
  backgroundImagePath: string | null;
  backgroundPadding: number;
  videoPlacement: VideoPlacement;
  videoCustomX?: number;
  videoCustomY?: number;
  cornerRadius: number;
  windowCornerRadius: number;
  frameShape: FrameShape;
  shadowRadius: number;
  shadowOpacity: number;
  gradientAngle?: number;
  backgroundBlur: number;
  backgroundBrightness: number;
  backgroundSaturation: number;
  backgroundTintColor: CodableColor;
  backgroundTintOpacity: number;
  backgroundVignette: number;
  backgroundPixelate: number;
  backgroundHalftone: number;
  backgroundNoise: number;
  backgroundContrast: number;
  backgroundHue: number;
  showCursor: boolean;
  cursorStyle: CursorStyle;
  cursorScale: number;
  /** Forced false on every decode (see ProjectSettings.init(from:)). */
  autoHideCursor: boolean;
  autoHideDelay: number;
  /** Forced false on every decode (see ProjectSettings.init(from:)). */
  smoothCursor: boolean;
  smoothingFactor: number;
  cursorTilt: number;
  cursorStretch: number;
  cursorDrag: number;
  cursorWeight: number;
  cursorFluidEnabled: boolean;
  cursorTension: number;
  cursorFriction: number;
  cursorMass: number;
  showClickRipple: boolean;
  cursorLoopToStart: boolean;
  cursorStopAtEnd: boolean;
  clickSoundEnabled: boolean;
  clickSoundVolume: number;
  clickSoundStyle: ClickSoundStyle;
  keySoundEnabled: boolean;
  keySoundVolume: number;
  keySoundStyle: KeySoundStyle;
  showKeystrokes: boolean;
  keystrokeOverlaySize: number;
  keystrokeOverlayPosition: KeystrokeOverlayPosition;
  keystrokeOverlayAnimation: KeystrokeOverlayAnimation;
  keystrokeOverlayScopeToRecordedApp: boolean;
  clickRippleColor: CodableColor;
  clickRippleSize: number;
  /** Normalized on Project decode: `cameraVideoURL != nil && showCamera`. */
  showCamera: boolean;
  cameraPosition: CameraPosition;
  cameraCustomX?: number;
  cameraCustomY?: number;
  cameraSize: number;
  cameraShape: CameraShape;
  cameraOrientation: CameraOrientation;
  cameraMirrored: boolean;
  cameraBrightness: number;
  cameraContrast: number;
  cameraSaturation: number;
  cameraHue: number;
  cameraFilter: CameraFilterStyle;
  cameraRingLight: number;
  cameraCornerRadius: number;
  cameraBorderWidth: number;
  cameraBorderColor?: CodableColor;
  cameraOpacity: number;
  cameraTiltPitch: number;
  cameraTiltYaw: number;
  cameraTagText: string;
  cameraTagSubtext: string;
  cameraTagFontName?: string;
  cameraTagTextColor: CodableColor;
  cameraTagBackgroundColor: CodableColor;
  cameraTagPosition: CameraTagPosition;
  showDeviceFrame: boolean;
  showWatermark: boolean;
  watermarkFileName?: string;
  watermarkX: number;
  watermarkY: number;
  watermarkSize: number;
  watermarkOpacity: number;
  menuBarReplacement: MenuBarReplacement;
  menuBarTitle: string;
  menuBarTitleAlignment: MenuBarTitleAlignment;
  menuBarShowStatusIcons: boolean;
  menuBarClock: string;
  menuBarHeight: number;
  systemAudioVolume: number;
  microphoneVolume: number;
  voiceOverVolume: number;
  animationSpeed: AnimationSpeed;
  motionBlur: boolean;
  motionBlurStrength: number;
  parallaxStrength: number;
  autoZoomLevel: number;
  introSlideStyle: IntroSlideStyle;
  introSlideDuration: number;
  introSlideStart: number;
  introSlideBounce: number;
  introSlideSpeed: number;
  introSlideDepth: boolean;
  curtainUnveilCorner: CurtainUnveilCorner;
  curtainUnveilDuration: number;
  curtainUnveilStart: number;
  curtainLogoFileName?: string;
  curtainLogoOpacity: number;
  curtainLogoScale: number;
  curtainLogoTint?: CodableColor;
  curtainColor?: CodableColor;
  cameraFollowSpeed: number;
  screenTiltMode: ScreenTiltMode;
  screenTiltAngle: number;
  screenTiltYaw: number;
  screenTiltRoll: number;
  showSubtitles: boolean;
  subtitleFontSize: number;
  subtitlePosition: SubtitlePosition;
  subtitleStyle: SubtitleStyle;
  subtitleCustomX?: number;
  subtitleCustomY?: number;
  subtitleWeight: SubtitleWeight;
  subtitleUppercase: boolean;
  subtitleFontName?: string;
  subtitleColor: CodableColor;
  subtitleBackgroundColor: CodableColor;
  highlightWords: boolean;
  subtitleHighlightColor: CodableColor;
  aspectRatio: AspectRatio;
  muteRecordedAudio: boolean;
  exportSettings: ExportSettings;
}

/** ZoomRegion.swift (synthesized Codable). `focalPoint` is `[x, y]` on disk. */
export interface ZoomRegion extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  zoomLevel: number;
  focalPoint: Point;
  animationStyle?: ZoomAnimationStyle;
  cardOffsetX?: number;
  cardOffsetY?: number;
  followsCursor?: boolean;
  isAuto?: boolean;
}

/** TiltRegion.swift (synthesized Codable). */
export interface TiltRegion extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  pitch: number;
  yaw: number;
  roll: number;
  animationStyle?: ZoomAnimationStyle;
}

/** BlurRegion.swift. `rect` is rectX/rectY/rectW/rectH on disk (Y-down, 0–1). */
export interface BlurRegion extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  label: string;
  rect: Rect;
  intensity: number;
  style: BlurStyle;
  animated: boolean;
}

/** HighlightRegion.swift. `rect` is rectX/rectY/rectW/rectH on disk. */
export interface HighlightRegion extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  label: string;
  rect: Rect;
  opacity: number;
}

/** FocusRegion.swift. `rect` is rectX/rectY/rectW/rectH on disk. */
export interface FocusRegion extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  label: string;
  rect: Rect;
  intensity: number;
  falloff: number;
  style: FocusRegionStyle;
  angle: number;
  cornerRadius: number;
}

/** CameraLayoutRegion.swift */
export interface CameraLayoutRegion extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  mode: CameraLayoutMode;
}

/** Annotation.swift (custom decoder, synthesized encoder). */
export interface Annotation extends HasExtra {
  id: UUIDString;
  type: AnnotationType;
  startTime: number;
  endTime: number;
  x: number;
  y: number;
  arrowEndX: number;
  arrowEndY: number;
  text: string;
  fontSize: number;
  showBackground: boolean;
  color: CodableColor;
  backgroundColor: CodableColor;
  lineWidth: number;
  drawingStrokes: CodablePoint[][];
  fontWeight: SubtitleWeight;
  uppercase: boolean;
  fontName?: string;
  opacity: number;
  cornerRadius: number;
  animatesIn: boolean;
  showShadow: boolean;
  enterEffect: AnnotationEffect;
  exitEffect: AnnotationEffect;
  backdropOpacity: number;
}

/** VoiceOverClip.swift */
export interface VoiceOverClip extends HasExtra {
  id: UUIDString;
  fileName: string;
  startTime: number;
  sourceStartTime: number;
  duration: number;
  sourceDuration: number;
  gain: number;
  label: string;
}

/** SubtitleSegment.swift `WordTiming` (synthesized Codable). */
export interface WordTiming extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  text: string;
}

/** SubtitleSegment.swift (custom decoder, synthesized encoder). */
export interface SubtitleSegment extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  text: string;
  words: WordTiming[];
}

/** VideoSpeedRegion.swift (synthesized Codable). */
export interface VideoSpeedRegion extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
  speed: number;
}

/** Project.swift `VideoClipSegment` (synthesized Codable). */
export interface VideoClipSegment extends HasExtra {
  id: UUIDString;
  startTime: number;
  endTime: number;
}

/** Project.swift `ProjectSourceSegment` (synthesized Codable). */
export interface ProjectSourceSegment extends HasExtra {
  startTime: number;
  duration: number;
  kind: RecordingSourceKind;
  contentX: number;
  contentY: number;
  contentWidth: number;
  contentHeight: number;
}

/** Project.swift — the root of project.json. */
export interface Project extends HasExtra {
  id: UUIDString;
  name: string;
  /** Seconds since 2001-01-01T00:00:00Z (Swift default Date encoding). */
  createdAt: number;
  /** Encoded as null when nil. */
  videoURL: string | null;
  /** Encoded as null when nil. */
  cursorDataURL: string | null;
  /** Omitted when nil. */
  keystrokeDataURL?: string;
  /** Encoded as null when nil. */
  cameraVideoURL: string | null;
  cameraTimeOffset: number;
  settings: ProjectSettings;
  zoomRegions: ZoomRegion[];
  tiltRegions: TiltRegion[];
  blurRegions: BlurRegion[];
  highlightRegions: HighlightRegion[];
  focusRegions: FocusRegion[];
  cameraLayoutRegions: CameraLayoutRegion[];
  annotations: Annotation[];
  voiceOverClips: VoiceOverClip[];
  subtitles: SubtitleSegment[];
  speedRegions: VideoSpeedRegion[];
  splitPoints: number[];
  videoClipSegments: VideoClipSegment[];
  duration: number;
  trimStart: number;
  trimEnd: number;
  recordingSourceKind: RecordingSourceKind;
  recordedAppBundleID?: string;
  sourceSegments: ProjectSourceSegment[];
  /** Seconds since 2001 reference date; omitted when nil. */
  reminderDate?: number;
  isStillCapture: boolean;
  stillTreatment: StillTreatment;
}

// ── Sidecar recordings (not in project.json, referenced by URL) ─────────────

/** Models/CursorEvent.swift (synthesized Codable). Coordinates are the
 * recording's coordinate space (points, Y-down). */
export interface CursorEvent {
  timestamp: number;
  x: number;
  y: number;
  isClick: boolean;
}

/** Models/CursorRecording.swift — cursor.json */
export interface CursorRecording {
  version: number;
  coordinateWidth: number;
  coordinateHeight: number;
  events: CursorEvent[];
}

/** Services/KeystrokeTracker.swift `KeystrokeEvent` — keys.json events. */
export interface KeystrokeEvent {
  timestamp: number;
  category: KeystrokeCategory;
  shortcut?: string;
  frontmostBundleID?: string;
}

/** Services/KeystrokeTracker.swift `KeystrokeRecording` — keys.json */
export interface KeystrokeRecording {
  version: number;
  events: KeystrokeEvent[];
}
