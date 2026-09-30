/**
 * Defaults for NEW objects and decode fallbacks — mirrors of the Swift
 * initializers (`ProjectSettings()`, `ExportSettings()`, `Project(...)`,
 * region/annotation inits). Locked by the `modelDefaults` golden vectors.
 *
 * NSColor system colours (systemPurple/Blue/Yellow) are appearance-dependent
 * in AppKit; the values here are what the Mac resolves headlessly (the
 * `modelDefaults` vectors record them). White/black are exact.
 */
import type { AnnotationType, RecordingSourceKind } from "./enums";
import type {
  Annotation,
  BlurRegion,
  CameraLayoutRegion,
  CodableColor,
  ExportSettings,
  FocusRegion,
  HighlightRegion,
  Project,
  ProjectSettings,
  SubtitleSegment,
  TiltRegion,
  VideoSpeedRegion,
  VoiceOverClip,
  ZoomRegion,
} from "./types";
import { smax } from "../math/swift";

export const DEFAULT_COLORS = {
  white: { red: 1, green: 1, blue: 1, opacity: 1 },
  black: { red: 0, green: 0, blue: 0, opacity: 1 },
  systemPurple: { red: 0.8588235294117647, green: 0.20392156862745098, blue: 0.9490196078431372, opacity: 1 },
  systemBlue: { red: 0, green: 0.5686274509803921, blue: 1, opacity: 1 },
  systemYellow: { red: 1, green: 0.8392156862745098, blue: 0, opacity: 1 },
} as const satisfies Record<string, CodableColor>;

/** FocusMath.defaultCornerRadius */
export const FOCUS_DEFAULT_CORNER_RADIUS = 0.24;

/** StillMovieWriter.defaultDuration */
export const STILL_DEFAULT_DURATION = 8;

const color = (c: CodableColor): CodableColor => ({ red: c.red, green: c.green, blue: c.blue, opacity: c.opacity });

/** A new random UUID in Swift's `uuidString` form (uppercase). */
export function newUUID(): string {
  const c = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
  if (c?.randomUUID) return c.randomUUID().toUpperCase();
  // Fallback (non-crypto contexts): RFC 4122 v4 layout from Math.random.
  const hex = Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16));
  hex[12] = "4";
  hex[16] = ((parseInt(hex[16], 16) & 0x3) | 0x8).toString(16);
  const s = hex.join("").toUpperCase();
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`;
}

/** Swift `Date()` as seconds since the 2001 reference date. */
export function swiftNow(): number {
  return Date.now() / 1000 - SWIFT_REFERENCE_EPOCH_OFFSET;
}

/** Seconds between 1970-01-01 and 2001-01-01 (Foundation's reference date). */
export const SWIFT_REFERENCE_EPOCH_OFFSET = 978307200;

/** Swift Date (seconds since 2001) → JS Date. */
export function dateFromSwift(seconds: number): Date {
  return new Date((seconds + SWIFT_REFERENCE_EPOCH_OFFSET) * 1000);
}

/** JS Date → Swift Date seconds. */
export function swiftFromDate(date: Date): number {
  return date.getTime() / 1000 - SWIFT_REFERENCE_EPOCH_OFFSET;
}

/** `ExportSettings()` */
export function defaultExportSettings(): ExportSettings {
  return {
    format: "MP4",
    resolution: "1080p",
    fps: 60,
    quality: 0.85,
    customWidth: 1920,
    customHeight: 1080,
    collapseStaticSpans: true,
  };
}

/** `ProjectSettings()` */
export function defaultProjectSettings(): ProjectSettings {
  return {
    backgroundType: "Gradient",
    gradientStartColor: color(DEFAULT_COLORS.systemPurple),
    gradientEndColor: color(DEFAULT_COLORS.systemBlue),
    solidColor: color(DEFAULT_COLORS.black),
    backgroundImagePath: null,
    backgroundPadding: 48,
    videoPlacement: "Center",
    cornerRadius: 12,
    windowCornerRadius: 8,
    frameShape: "Rounded Rectangle",
    shadowRadius: 20,
    shadowOpacity: 0.5,
    backgroundBlur: 0,
    backgroundBrightness: 0,
    backgroundSaturation: 1,
    backgroundTintColor: { red: 0, green: 0, blue: 0, opacity: 1 },
    backgroundTintOpacity: 0,
    backgroundVignette: 0,
    backgroundPixelate: 0,
    backgroundHalftone: 0,
    backgroundNoise: 0,
    backgroundContrast: 1,
    backgroundHue: 0,
    showCursor: true,
    cursorStyle: "macOS Arrow",
    cursorScale: 1.5,
    autoHideCursor: false,
    autoHideDelay: 3.0,
    smoothCursor: false,
    smoothingFactor: 0.15,
    cursorTilt: 0,
    cursorStretch: 0,
    cursorDrag: 0,
    cursorWeight: 1.0,
    cursorFluidEnabled: true,
    cursorTension: 220,
    cursorFriction: 24,
    cursorMass: 1.0,
    showClickRipple: true,
    cursorLoopToStart: false,
    cursorStopAtEnd: false,
    clickSoundEnabled: false,
    clickSoundVolume: 0.7,
    clickSoundStyle: "Soft Tick",
    keySoundEnabled: false,
    keySoundVolume: 0.6,
    keySoundStyle: "Thock",
    showKeystrokes: true,
    keystrokeOverlaySize: 1.0,
    keystrokeOverlayPosition: "bottomCenter",
    keystrokeOverlayAnimation: "slideUp",
    keystrokeOverlayScopeToRecordedApp: true,
    clickRippleColor: color(DEFAULT_COLORS.white),
    clickRippleSize: 40,
    showCamera: false,
    cameraPosition: "Bottom Right",
    cameraSize: 120,
    cameraShape: "Circle",
    cameraOrientation: "Auto",
    cameraMirrored: false,
    cameraBrightness: 0,
    cameraContrast: 1,
    cameraSaturation: 1,
    cameraHue: 0,
    cameraFilter: "None",
    cameraRingLight: 0,
    cameraCornerRadius: 12,
    cameraBorderWidth: 2,
    cameraOpacity: 1,
    cameraTiltPitch: 0,
    cameraTiltYaw: 0,
    cameraTagText: "",
    cameraTagSubtext: "",
    cameraTagTextColor: color(DEFAULT_COLORS.white),
    cameraTagBackgroundColor: { red: 0, green: 0, blue: 0, opacity: 0.55 },
    cameraTagPosition: "Below",
    showDeviceFrame: true,
    showWatermark: false,
    watermarkX: 1.0,
    watermarkY: 1.0,
    watermarkSize: 120,
    watermarkOpacity: 0.9,
    menuBarReplacement: "Original",
    menuBarTitle: "CaptureCat",
    menuBarTitleAlignment: "Left",
    menuBarShowStatusIcons: true,
    menuBarClock: "9:41",
    menuBarHeight: 3.8,
    systemAudioVolume: 1.0,
    microphoneVolume: 1.0,
    voiceOverVolume: 1.0,
    animationSpeed: "Mellow",
    motionBlur: false,
    motionBlurStrength: 0.5,
    parallaxStrength: 0,
    autoZoomLevel: 2.0,
    introSlideStyle: "Off",
    introSlideDuration: 0.9,
    introSlideStart: 0,
    introSlideBounce: 0.5,
    introSlideSpeed: 1.0,
    introSlideDepth: false,
    curtainUnveilCorner: "Off",
    curtainUnveilDuration: 1.6,
    curtainUnveilStart: 0,
    curtainLogoOpacity: 1.0,
    curtainLogoScale: 0.25,
    cameraFollowSpeed: 0.5,
    screenTiltMode: "Off",
    screenTiltAngle: 20,
    screenTiltYaw: 0,
    screenTiltRoll: 0,
    showSubtitles: true,
    subtitleFontSize: 32,
    subtitlePosition: "Bottom",
    subtitleStyle: "Outline",
    subtitleWeight: "Bold",
    subtitleUppercase: false,
    subtitleColor: color(DEFAULT_COLORS.white),
    subtitleBackgroundColor: color(DEFAULT_COLORS.black),
    highlightWords: false,
    subtitleHighlightColor: color(DEFAULT_COLORS.systemYellow),
    aspectRatio: "16:9",
    muteRecordedAudio: false,
    exportSettings: defaultExportSettings(),
  };
}

export interface NewProjectOptions {
  id?: string;
  name?: string;
  videoURL?: string | null;
  cursorDataURL?: string | null;
  cameraVideoURL?: string | null;
  cameraTimeOffset?: number;
  duration?: number;
  recordingSourceKind?: RecordingSourceKind;
  createdAt?: number;
}

/** `Project(id:name:videoURL:cursorDataURL:cameraVideoURL:cameraTimeOffset:duration:recordingSourceKind:)` */
export function newProject(o: NewProjectOptions = {}): Project {
  const settings = defaultProjectSettings();
  const cameraVideoURL = o.cameraVideoURL ?? null;
  settings.showCamera = cameraVideoURL !== null;
  return {
    id: o.id ?? newUUID(),
    name: o.name ?? "Untitled Recording",
    createdAt: o.createdAt ?? swiftNow(),
    videoURL: o.videoURL ?? null,
    cursorDataURL: o.cursorDataURL ?? null,
    cameraVideoURL,
    cameraTimeOffset: o.cameraTimeOffset ?? 0,
    settings,
    zoomRegions: [],
    tiltRegions: [],
    blurRegions: [],
    highlightRegions: [],
    focusRegions: [],
    cameraLayoutRegions: [],
    annotations: [],
    voiceOverClips: [],
    subtitles: [],
    speedRegions: [],
    splitPoints: [],
    videoClipSegments: [],
    duration: o.duration ?? 0,
    trimStart: 0,
    trimEnd: 0,
    recordingSourceKind: o.recordingSourceKind ?? "display",
    sourceSegments: [],
    isStillCapture: false,
    stillTreatment: "image",
  };
}

/** `Annotation(id:type:startTime:endTime:)` — the designated initializer's
 * values (NOT the toolbar's per-type `applyNewAnnotationDefaults`). */
export function newAnnotation(type: AnnotationType, startTime: number, endTime: number, id = newUUID()): Annotation {
  return {
    id,
    type,
    startTime,
    endTime,
    x: 0.5,
    y: 0.38,
    arrowEndX: 0.65,
    arrowEndY: 0.55,
    text: "Label",
    fontSize: 18,
    showBackground: true,
    color: color(DEFAULT_COLORS.white),
    backgroundColor: { red: 0, green: 0, blue: 0, opacity: 0.55 },
    lineWidth: 4,
    drawingStrokes: [],
    fontWeight: "Semibold",
    uppercase: false,
    opacity: 1,
    cornerRadius: 8,
    animatesIn: true,
    showShadow: true,
    enterEffect: "Pop",
    exitEffect: "Fade",
    backdropOpacity: 0,
  };
}

/** `ZoomRegion(startTime:endTime:)` */
export function newZoomRegion(startTime: number, endTime: number, id = newUUID()): ZoomRegion {
  return { id, startTime, endTime, zoomLevel: 2.0, focalPoint: { x: 0.5, y: 0.5 } };
}

/** `TiltRegion(startTime:endTime:)` */
export function newTiltRegion(startTime: number, endTime: number, id = newUUID()): TiltRegion {
  return { id, startTime, endTime, pitch: 20, yaw: 0, roll: 0 };
}

/** `BlurRegion(startTime:endTime:)` */
export function newBlurRegion(startTime: number, endTime: number, id = newUUID()): BlurRegion {
  return {
    id,
    startTime,
    endTime,
    label: "Blur",
    rect: { x: 0.3, y: 0.3, width: 0.4, height: 0.15 },
    intensity: 0.6,
    style: "Blur",
    animated: false,
  };
}

/** `HighlightRegion(startTime:endTime:)` */
export function newHighlightRegion(startTime: number, endTime: number, id = newUUID()): HighlightRegion {
  return {
    id,
    startTime,
    endTime,
    label: "Highlight",
    rect: { x: 0.2, y: 0.18, width: 0.42, height: 0.2 },
    opacity: 0.55,
  };
}

/** `FocusRegion(startTime:endTime:)` */
export function newFocusRegion(startTime: number, endTime: number, id = newUUID()): FocusRegion {
  return {
    id,
    startTime,
    endTime,
    label: "Focus",
    rect: { x: 0.28, y: 0.3, width: 0.44, height: 0.34 },
    intensity: 0.7,
    falloff: 0.45,
    style: "Area",
    angle: 0,
    cornerRadius: FOCUS_DEFAULT_CORNER_RADIUS,
  };
}

/** `CameraLayoutRegion(startTime:endTime:)` */
export function newCameraLayoutRegion(startTime: number, endTime: number, id = newUUID()): CameraLayoutRegion {
  return { id, startTime, endTime, mode: "cameraOnly" };
}

/** `VideoSpeedRegion(startTime:endTime:)` */
export function newSpeedRegion(startTime: number, endTime: number, id = newUUID()): VideoSpeedRegion {
  return { id, startTime, endTime, speed: 2.0 };
}

/** `VoiceOverClip(fileName:startTime:sourceStartTime:duration:sourceDuration:gain:label:)` */
export function newVoiceOverClip(
  fileName: string,
  startTime: number,
  duration: number,
  opts: { id?: string; sourceStartTime?: number; sourceDuration?: number; gain?: number; label?: string } = {},
): VoiceOverClip {
  return {
    id: opts.id ?? newUUID(),
    fileName,
    startTime,
    sourceStartTime: smax(0, opts.sourceStartTime ?? 0),
    duration,
    sourceDuration: smax(duration, opts.sourceDuration ?? duration),
    gain: opts.gain ?? 1.0,
    label: opts.label ?? "Voice Over",
  };
}

/** `SubtitleSegment(startTime:endTime:text:words:)` */
export function newSubtitleSegment(startTime: number, endTime: number, text: string, id = newUUID()): SubtitleSegment {
  return { id, startTime, endTime, text, words: [] };
}
