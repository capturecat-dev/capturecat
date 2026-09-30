/**
 * `parseProject(json)` — the web twin of `JSONDecoder().decode(Project.self)`.
 *
 * Every `init(from decoder:)` in apps/macos/CaptureCat/Models is mirrored
 * line-for-line: which keys are required (a missing one fails the whole
 * project, exactly like the Mac), which fall back to a default, which are
 * lenient (`try?` — an unknown enum raw value becomes the default), and the
 * normalisations Swift applies on decode (forced-off smoothCursor /
 * autoHideCursor, showCamera requires a camera file, VoiceOverClip source
 * clamps, legacy annotation effect defaults, uppercase UUIDs).
 *
 * Keys a type does not know are kept in `$extra` and re-emitted verbatim by
 * `serializeProject`, so the web never drops data written by a newer Mac.
 *
 * Locked to Swift by the `projectDecode` + `modelDefaults` golden vectors.
 */
import {
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
  enumValues,
  ExportFormat,
  ExportResolution,
  FocusRegionStyle,
  FrameShape,
  IntroSlideStyle,
  KeySoundStyle,
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
import type {
  Annotation,
  BlurRegion,
  CameraLayoutRegion,
  CodableColor,
  CodablePoint,
  ExportSettings,
  FocusRegion,
  HighlightRegion,
  Project,
  ProjectSettings,
  ProjectSourceSegment,
  SubtitleSegment,
  TiltRegion,
  VideoClipSegment,
  VideoSpeedRegion,
  VoiceOverClip,
  WordTiming,
  ZoomRegion,
} from "./types";
import {
  dArray,
  dBool,
  dCGPoint,
  dDate,
  dDouble,
  dEnum,
  dInt,
  dString,
  dURL,
  dUUID,
  type Decode,
  Keyed,
  withExtra,
} from "./codec";
import { DEFAULT_COLORS, FOCUS_DEFAULT_CORNER_RADIUS, newUUID } from "./defaults";
import {
  ANNOTATION_KEYS,
  BLUR_REGION_KEYS,
  CAMERA_LAYOUT_REGION_KEYS,
  CODABLE_COLOR_KEYS,
  CODABLE_POINT_KEYS,
  EXPORT_SETTINGS_KEYS,
  FOCUS_REGION_KEYS,
  HIGHLIGHT_REGION_KEYS,
  PROJECT_KEYS,
  PROJECT_SETTINGS_KEYS,
  SOURCE_SEGMENT_KEYS,
  SPEED_REGION_KEYS,
  SUBTITLE_SEGMENT_KEYS,
  TILT_REGION_KEYS,
  VIDEO_CLIP_SEGMENT_KEYS,
  VOICE_OVER_CLIP_KEYS,
  WORD_TIMING_KEYS,
  ZOOM_REGION_KEYS,
} from "./keys";
import { smax } from "../math/swift";

const e = <T extends Record<string, string>>(x: T) => dEnum(enumValues(x));

const eBackgroundType = e(BackgroundType);
const eVideoPlacement = e(VideoPlacement);
const eFrameShape = e(FrameShape);
const eCursorStyle = e(CursorStyle);
const eClickSoundStyle = e(ClickSoundStyle);
const eKeySoundStyle = e(KeySoundStyle);
const eKeystrokePosition = e(KeystrokeOverlayPosition);
const eKeystrokeAnimation = e(KeystrokeOverlayAnimation);
const eCameraPosition = e(CameraPosition);
const eCameraShape = e(CameraShape);
const eCameraOrientation = e(CameraOrientation);
const eCameraFilter = e(CameraFilterStyle);
const eCameraTagPosition = e(CameraTagPosition);
const eMenuBarReplacement = e(MenuBarReplacement);
const eMenuBarTitleAlignment = e(MenuBarTitleAlignment);
const eAnimationSpeed = e(AnimationSpeed);
const eIntroSlideStyle = e(IntroSlideStyle);
const eCurtainCorner = e(CurtainUnveilCorner);
const eScreenTiltMode = e(ScreenTiltMode);
const eSubtitlePosition = e(SubtitlePosition);
const eSubtitleStyle = e(SubtitleStyle);
const eSubtitleWeight = e(SubtitleWeight);
const eAspectRatio = e(AspectRatio);
const eFormat = e(ExportFormat);
const eResolution = e(ExportResolution);
const eZoomStyle = e(ZoomAnimationStyle);
const eBlurStyle = e(BlurStyle);
const eFocusStyle = e(FocusRegionStyle);
const eCameraLayoutMode = e(CameraLayoutMode);
const eAnnotationType = e(AnnotationType);
const eAnnotationEffect = e(AnnotationEffect);
const eSourceKind = e(RecordingSourceKind);
const eStillTreatment = e(StillTreatment);

// ── Leaf types ──────────────────────────────────────────────────────────────

/** Extensions/Color+Codable.swift — synthesized: four required Doubles. */
export const decodeCodableColor: Decode<CodableColor> = (v, path) => {
  const c = new Keyed(v, path, CODABLE_COLOR_KEYS);
  return withExtra(
    {
      red: c.decode("red", dDouble),
      green: c.decode("green", dDouble),
      blue: c.decode("blue", dDouble),
      opacity: c.decode("opacity", dDouble),
    },
    c.extra(),
  );
};

const decodeCodablePoint: Decode<CodablePoint> = (v, path) => {
  const c = new Keyed(v, path, CODABLE_POINT_KEYS);
  return withExtra({ x: c.decode("x", dDouble), y: c.decode("y", dDouble) }, c.extra());
};

/** Models/ExportSettings.swift — every field decodeIfPresent with a default. */
export const decodeExportSettings: Decode<ExportSettings> = (v, path) => {
  const c = new Keyed(v, path, EXPORT_SETTINGS_KEYS);
  return withExtra(
    {
      format: c.decodeIfPresent("format", eFormat) ?? "MP4",
      resolution: c.decodeIfPresent("resolution", eResolution) ?? "1080p",
      fps: c.decodeIfPresent("fps", dInt) ?? 60,
      quality: c.decodeIfPresent("quality", dDouble) ?? 0.85,
      customWidth: c.decodeIfPresent("customWidth", dInt) ?? 1920,
      customHeight: c.decodeIfPresent("customHeight", dInt) ?? 1080,
      collapseStaticSpans: c.decodeIfPresent("collapseStaticSpans", dBool) ?? true,
    },
    c.extra(),
  );
};

// ── ProjectSettings ─────────────────────────────────────────────────────────

/** Models/ProjectSettings.swift `init(from:)`, in source order. `showCamera`
 * is further normalised by `decodeProject` (needs the camera URL). */
export const decodeProjectSettings: Decode<ProjectSettings> = (v, path) => {
  const c = new Keyed(v, path, PROJECT_SETTINGS_KEYS);
  const color = decodeCodableColor;
  const s: ProjectSettings = {
    backgroundType: c.decode("backgroundType", eBackgroundType),
    gradientStartColor: c.decode("gradientStartColor", color),
    gradientEndColor: c.decode("gradientEndColor", color),
    solidColor: c.decode("solidColor", color),
    backgroundImagePath: c.decodeIfPresent("backgroundImagePath", dString) ?? null,
    backgroundPadding: c.decode("backgroundPadding", dDouble),
    videoPlacement: c.decodeIfPresent("videoPlacement", eVideoPlacement) ?? "Center",
    videoCustomX: c.decodeIfPresent("videoCustomX", dDouble),
    videoCustomY: c.decodeIfPresent("videoCustomY", dDouble),
    cornerRadius: c.decode("cornerRadius", dDouble),
    windowCornerRadius: c.decodeIfPresent("windowCornerRadius", dDouble) ?? 8,
    frameShape: c.decodeIfPresent("frameShape", eFrameShape) ?? "Rounded Rectangle",
    shadowRadius: c.decode("shadowRadius", dDouble),
    shadowOpacity: c.decode("shadowOpacity", dDouble),
    gradientAngle: c.decodeIfPresent("gradientAngle", dDouble),
    backgroundBlur: c.decodeIfPresent("backgroundBlur", dDouble) ?? 0,
    backgroundBrightness: c.decodeIfPresent("backgroundBrightness", dDouble) ?? 0,
    backgroundSaturation: c.decodeIfPresent("backgroundSaturation", dDouble) ?? 1,
    backgroundTintColor: c.decodeIfPresent("backgroundTintColor", color) ?? { red: 0, green: 0, blue: 0, opacity: 1 },
    backgroundTintOpacity: c.decodeIfPresent("backgroundTintOpacity", dDouble) ?? 0,
    backgroundVignette: c.decodeIfPresent("backgroundVignette", dDouble) ?? 0,
    backgroundPixelate: c.decodeIfPresent("backgroundPixelate", dDouble) ?? 0,
    backgroundHalftone: c.decodeIfPresent("backgroundHalftone", dDouble) ?? 0,
    backgroundNoise: c.decodeIfPresent("backgroundNoise", dDouble) ?? 0,
    backgroundContrast: c.decodeIfPresent("backgroundContrast", dDouble) ?? 1,
    backgroundHue: c.decodeIfPresent("backgroundHue", dDouble) ?? 0,
    showCursor: c.decodeIfPresent("showCursor", dBool) ?? true,
    // Lenient: a since-removed style falls back to the system arrow.
    cursorStyle: c.tryDecodeIfPresent("cursorStyle", eCursorStyle) ?? "macOS Arrow",
    cursorScale: c.decode("cursorScale", dDouble),
    // Forced off for every project (the stored value is read, then ignored).
    autoHideCursor: (c.decodeIfPresent("autoHideCursor", dBool), false),
    autoHideDelay: c.decode("autoHideDelay", dDouble),
    // One-time correction: deliberately ignores the stored value.
    smoothCursor: (c.decodeIfPresent("smoothCursor", dBool), false),
    smoothingFactor: c.decode("smoothingFactor", dDouble),
    cursorTilt: c.decodeIfPresent("cursorTilt", dDouble) ?? 0,
    cursorStretch: c.decodeIfPresent("cursorStretch", dDouble) ?? 0,
    cursorDrag: c.decodeIfPresent("cursorDrag", dDouble) ?? 0,
    cursorWeight: c.decodeIfPresent("cursorWeight", dDouble) ?? 1.0,
    cursorFluidEnabled: c.decodeIfPresent("cursorFluidEnabled", dBool) ?? true,
    cursorTension: c.decodeIfPresent("cursorTension", dDouble) ?? 220,
    cursorFriction: c.decodeIfPresent("cursorFriction", dDouble) ?? 24,
    cursorMass: c.decodeIfPresent("cursorMass", dDouble) ?? 1.0,
    showClickRipple: c.decodeIfPresent("showClickRipple", dBool) ?? true,
    cursorLoopToStart: c.decodeIfPresent("cursorLoopToStart", dBool) ?? false,
    cursorStopAtEnd: c.decodeIfPresent("cursorStopAtEnd", dBool) ?? false,
    clickSoundEnabled: c.decodeIfPresent("clickSoundEnabled", dBool) ?? false,
    clickSoundVolume: c.decodeIfPresent("clickSoundVolume", dDouble) ?? 0.7,
    clickSoundStyle: c.tryDecodeIfPresent("clickSoundStyle", eClickSoundStyle) ?? "Soft Tick",
    keySoundEnabled: c.decodeIfPresent("keySoundEnabled", dBool) ?? false,
    keySoundVolume: c.decodeIfPresent("keySoundVolume", dDouble) ?? 0.6,
    keySoundStyle: c.tryDecodeIfPresent("keySoundStyle", eKeySoundStyle) ?? "Thock",
    showKeystrokes: c.decodeIfPresent("showKeystrokes", dBool) ?? true,
    keystrokeOverlaySize: c.decodeIfPresent("keystrokeOverlaySize", dDouble) ?? 1.0,
    keystrokeOverlayPosition: c.tryDecodeIfPresent("keystrokeOverlayPosition", eKeystrokePosition) ?? "bottomCenter",
    keystrokeOverlayAnimation: c.tryDecodeIfPresent("keystrokeOverlayAnimation", eKeystrokeAnimation) ?? "slideUp",
    keystrokeOverlayScopeToRecordedApp: c.decodeIfPresent("keystrokeOverlayScopeToRecordedApp", dBool) ?? true,
    clickRippleColor: c.decodeIfPresent("clickRippleColor", color) ?? { ...DEFAULT_COLORS.white },
    clickRippleSize: c.decodeIfPresent("clickRippleSize", dDouble) ?? 40,
    showCamera: c.decode("showCamera", dBool),
    cameraPosition: c.decode("cameraPosition", eCameraPosition),
    cameraCustomX: c.decodeIfPresent("cameraCustomX", dDouble),
    cameraCustomY: c.decodeIfPresent("cameraCustomY", dDouble),
    cameraSize: c.decode("cameraSize", dDouble),
    cameraShape: c.decode("cameraShape", eCameraShape),
    cameraOrientation: c.tryDecodeIfPresent("cameraOrientation", eCameraOrientation) ?? "Auto",
    cameraMirrored: c.decodeIfPresent("cameraMirrored", dBool) ?? false,
    cameraBrightness: c.decodeIfPresent("cameraBrightness", dDouble) ?? 0,
    cameraContrast: c.decodeIfPresent("cameraContrast", dDouble) ?? 1,
    cameraSaturation: c.decodeIfPresent("cameraSaturation", dDouble) ?? 1,
    cameraHue: c.decodeIfPresent("cameraHue", dDouble) ?? 0,
    cameraFilter: c.tryDecodeIfPresent("cameraFilter", eCameraFilter) ?? "None",
    cameraRingLight: c.decodeIfPresent("cameraRingLight", dDouble) ?? 0,
    cameraCornerRadius: c.decodeIfPresent("cameraCornerRadius", dDouble) ?? 12,
    cameraBorderWidth: c.decodeIfPresent("cameraBorderWidth", dDouble) ?? 2,
    cameraBorderColor: c.decodeIfPresent("cameraBorderColor", color),
    cameraOpacity: c.decodeIfPresent("cameraOpacity", dDouble) ?? 1,
    cameraTiltPitch: c.decodeIfPresent("cameraTiltPitch", dDouble) ?? 0,
    cameraTiltYaw: c.decodeIfPresent("cameraTiltYaw", dDouble) ?? 0,
    cameraTagText: c.decodeIfPresent("cameraTagText", dString) ?? "",
    cameraTagSubtext: c.decodeIfPresent("cameraTagSubtext", dString) ?? "",
    cameraTagFontName: c.decodeIfPresent("cameraTagFontName", dString),
    cameraTagTextColor: c.decodeIfPresent("cameraTagTextColor", color) ?? { ...DEFAULT_COLORS.white },
    cameraTagBackgroundColor:
      c.decodeIfPresent("cameraTagBackgroundColor", color) ?? { red: 0, green: 0, blue: 0, opacity: 0.55 },
    cameraTagPosition: c.tryDecodeIfPresent("cameraTagPosition", eCameraTagPosition) ?? "Below",
    showDeviceFrame: c.decodeIfPresent("showDeviceFrame", dBool) ?? true,
    showWatermark: c.decodeIfPresent("showWatermark", dBool) ?? false,
    watermarkFileName: c.decodeIfPresent("watermarkFileName", dString),
    watermarkX: c.decodeIfPresent("watermarkX", dDouble) ?? 1.0,
    watermarkY: c.decodeIfPresent("watermarkY", dDouble) ?? 1.0,
    watermarkSize: c.decodeIfPresent("watermarkSize", dDouble) ?? 120,
    watermarkOpacity: c.decodeIfPresent("watermarkOpacity", dDouble) ?? 0.9,
    menuBarReplacement: c.decodeIfPresent("menuBarReplacement", eMenuBarReplacement) ?? "Original",
    menuBarTitle: c.decodeIfPresent("menuBarTitle", dString) ?? "CaptureCat",
    menuBarTitleAlignment: c.decodeIfPresent("menuBarTitleAlignment", eMenuBarTitleAlignment) ?? "Left",
    menuBarShowStatusIcons: c.decodeIfPresent("menuBarShowStatusIcons", dBool) ?? true,
    menuBarClock: c.decodeIfPresent("menuBarClock", dString) ?? "9:41",
    menuBarHeight: c.decodeIfPresent("menuBarHeight", dDouble) ?? 3.8,
    systemAudioVolume: c.decode("systemAudioVolume", dDouble),
    microphoneVolume: c.decode("microphoneVolume", dDouble),
    voiceOverVolume: c.decodeIfPresent("voiceOverVolume", dDouble) ?? 1.0,
    animationSpeed: c.decode("animationSpeed", eAnimationSpeed),
    motionBlur: c.decode("motionBlur", dBool),
    motionBlurStrength: c.decodeIfPresent("motionBlurStrength", dDouble) ?? 0.5,
    parallaxStrength: c.decodeIfPresent("parallaxStrength", dDouble) ?? 0,
    autoZoomLevel: c.decodeIfPresent("autoZoomLevel", dDouble) ?? 2.0,
    introSlideStyle: c.decodeIfPresent("introSlideStyle", eIntroSlideStyle) ?? "Off",
    introSlideDuration: c.decodeIfPresent("introSlideDuration", dDouble) ?? 0.9,
    introSlideStart: c.decodeIfPresent("introSlideStart", dDouble) ?? 0,
    introSlideBounce: c.decodeIfPresent("introSlideBounce", dDouble) ?? 0.5,
    introSlideSpeed: c.decodeIfPresent("introSlideSpeed", dDouble) ?? 1.0,
    introSlideDepth: c.decodeIfPresent("introSlideDepth", dBool) ?? false,
    curtainUnveilCorner: c.decodeIfPresent("curtainUnveilCorner", eCurtainCorner) ?? "Off",
    curtainUnveilDuration: c.decodeIfPresent("curtainUnveilDuration", dDouble) ?? 1.6,
    curtainUnveilStart: c.decodeIfPresent("curtainUnveilStart", dDouble) ?? 0,
    curtainLogoFileName: c.decodeIfPresent("curtainLogoFileName", dString),
    curtainLogoOpacity: c.decodeIfPresent("curtainLogoOpacity", dDouble) ?? 1.0,
    curtainLogoScale: c.decodeIfPresent("curtainLogoScale", dDouble) ?? 0.25,
    curtainLogoTint: c.decodeIfPresent("curtainLogoTint", color),
    curtainColor: c.decodeIfPresent("curtainColor", color),
    cameraFollowSpeed: c.decodeIfPresent("cameraFollowSpeed", dDouble) ?? 0.5,
    screenTiltMode: c.decodeIfPresent("screenTiltMode", eScreenTiltMode) ?? "Off",
    screenTiltAngle: c.decodeIfPresent("screenTiltAngle", dDouble) ?? 20,
    screenTiltYaw: c.decodeIfPresent("screenTiltYaw", dDouble) ?? 0,
    screenTiltRoll: c.decodeIfPresent("screenTiltRoll", dDouble) ?? 0,
    showSubtitles: c.decodeIfPresent("showSubtitles", dBool) ?? true,
    subtitleFontSize: c.decodeIfPresent("subtitleFontSize", dDouble) ?? 32,
    subtitlePosition: c.decodeIfPresent("subtitlePosition", eSubtitlePosition) ?? "Bottom",
    subtitleStyle: c.decodeIfPresent("subtitleStyle", eSubtitleStyle) ?? "Outline",
    subtitleCustomX: c.decodeIfPresent("subtitleCustomX", dDouble),
    subtitleCustomY: c.decodeIfPresent("subtitleCustomY", dDouble),
    subtitleWeight: c.tryDecodeIfPresent("subtitleWeight", eSubtitleWeight) ?? "Bold",
    subtitleUppercase: c.decodeIfPresent("subtitleUppercase", dBool) ?? false,
    subtitleFontName: c.decodeIfPresent("subtitleFontName", dString),
    subtitleColor: c.decodeIfPresent("subtitleColor", color) ?? { ...DEFAULT_COLORS.white },
    subtitleBackgroundColor: c.decodeIfPresent("subtitleBackgroundColor", color) ?? { ...DEFAULT_COLORS.black },
    highlightWords: c.decodeIfPresent("highlightWords", dBool) ?? false,
    subtitleHighlightColor: c.decodeIfPresent("subtitleHighlightColor", color) ?? { ...DEFAULT_COLORS.systemYellow },
    aspectRatio: c.decode("aspectRatio", eAspectRatio),
    muteRecordedAudio: c.decodeIfPresent("muteRecordedAudio", dBool) ?? false,
    exportSettings: c.decode("exportSettings", decodeExportSettings),
  };
  return withExtra(dropUndefined(s), c.extra());
};

// ── Regions ─────────────────────────────────────────────────────────────────

/** Models/ZoomRegion.swift — synthesized Codable. */
export const decodeZoomRegion: Decode<ZoomRegion> = (v, path) => {
  const c = new Keyed(v, path, ZOOM_REGION_KEYS);
  return withExtra(
    dropUndefined({
      id: c.decode("id", dUUID),
      startTime: c.decode("startTime", dDouble),
      endTime: c.decode("endTime", dDouble),
      zoomLevel: c.decode("zoomLevel", dDouble),
      focalPoint: c.decode("focalPoint", dCGPoint),
      animationStyle: c.decodeIfPresent("animationStyle", eZoomStyle),
      cardOffsetX: c.decodeIfPresent("cardOffsetX", dDouble),
      cardOffsetY: c.decodeIfPresent("cardOffsetY", dDouble),
      followsCursor: c.decodeIfPresent("followsCursor", dBool),
      isAuto: c.decodeIfPresent("isAuto", dBool),
    }),
    c.extra(),
  );
};

/** Models/TiltRegion.swift — synthesized Codable. */
export const decodeTiltRegion: Decode<TiltRegion> = (v, path) => {
  const c = new Keyed(v, path, TILT_REGION_KEYS);
  return withExtra(
    dropUndefined({
      id: c.decode("id", dUUID),
      startTime: c.decode("startTime", dDouble),
      endTime: c.decode("endTime", dDouble),
      pitch: c.decode("pitch", dDouble),
      yaw: c.decode("yaw", dDouble),
      roll: c.decode("roll", dDouble),
      animationStyle: c.decodeIfPresent("animationStyle", eZoomStyle),
    }),
    c.extra(),
  );
};

function decodeRect(c: Keyed, dx: number, dy: number, dw: number, dh: number) {
  return {
    x: c.decodeIfPresent("rectX", dDouble) ?? dx,
    y: c.decodeIfPresent("rectY", dDouble) ?? dy,
    width: c.decodeIfPresent("rectW", dDouble) ?? dw,
    height: c.decodeIfPresent("rectH", dDouble) ?? dh,
  };
}

/** Models/BlurRegion.swift */
export const decodeBlurRegion: Decode<BlurRegion> = (v, path) => {
  const c = new Keyed(v, path, BLUR_REGION_KEYS);
  const id = c.decode("id", dUUID);
  const startTime = c.decode("startTime", dDouble);
  const endTime = c.decode("endTime", dDouble);
  const label = c.decode("label", dString);
  const intensity = c.decodeIfPresent("intensity", dDouble) ?? 0.6;
  const style = c.decodeIfPresent("style", eBlurStyle) ?? "Blur";
  const animated = c.decodeIfPresent("animated", dBool) ?? false;
  const rect = decodeRect(c, 0.3, 0.3, 0.4, 0.15);
  return withExtra({ id, startTime, endTime, label, rect, intensity, style, animated }, c.extra());
};

/** Models/HighlightRegion.swift */
export const decodeHighlightRegion: Decode<HighlightRegion> = (v, path) => {
  const c = new Keyed(v, path, HIGHLIGHT_REGION_KEYS);
  const id = c.decode("id", dUUID);
  const startTime = c.decode("startTime", dDouble);
  const endTime = c.decode("endTime", dDouble);
  const label = c.decodeIfPresent("label", dString) ?? "Highlight";
  const opacity = c.decodeIfPresent("opacity", dDouble) ?? 0.55;
  const rect = decodeRect(c, 0.2, 0.18, 0.42, 0.2);
  return withExtra({ id, startTime, endTime, label, rect, opacity }, c.extra());
};

/** Models/FocusRegion.swift */
export const decodeFocusRegion: Decode<FocusRegion> = (v, path) => {
  const c = new Keyed(v, path, FOCUS_REGION_KEYS);
  const id = c.decode("id", dUUID);
  const startTime = c.decode("startTime", dDouble);
  const endTime = c.decode("endTime", dDouble);
  const label = c.decodeIfPresent("label", dString) ?? "Focus";
  const intensity = c.decodeIfPresent("intensity", dDouble) ?? 0.7;
  const falloff = c.decodeIfPresent("falloff", dDouble) ?? 0.45;
  const style = c.decodeIfPresent("style", eFocusStyle) ?? "Area";
  const angle = c.decodeIfPresent("angle", dDouble) ?? 0;
  const cornerRadius = c.decodeIfPresent("cornerRadius", dDouble) ?? FOCUS_DEFAULT_CORNER_RADIUS;
  const rect = decodeRect(c, 0.28, 0.3, 0.44, 0.34);
  return withExtra(
    { id, startTime, endTime, label, rect, intensity, falloff, style, angle, cornerRadius },
    c.extra(),
  );
};

/** Models/CameraLayoutRegion.swift — every field optional; a missing id gets
 * a FRESH random UUID (as Swift's `?? UUID()` does). */
export const decodeCameraLayoutRegion: Decode<CameraLayoutRegion> = (v, path) => {
  const c = new Keyed(v, path, CAMERA_LAYOUT_REGION_KEYS);
  return withExtra(
    {
      id: c.decodeIfPresent("id", dUUID) ?? newUUID(),
      startTime: c.decodeIfPresent("startTime", dDouble) ?? 0,
      endTime: c.decodeIfPresent("endTime", dDouble) ?? 0,
      mode: c.decodeIfPresent("mode", eCameraLayoutMode) ?? "cameraOnly",
    },
    c.extra(),
  );
};

/** Models/Annotation.swift `init(from:)` (custom decoder). */
export const decodeAnnotation: Decode<Annotation> = (v, path) => {
  const c = new Keyed(v, path, ANNOTATION_KEYS);
  const id = c.decode("id", dUUID);
  const type = c.decode("type", eAnnotationType);
  const startTime = c.decode("startTime", dDouble);
  const endTime = c.decode("endTime", dDouble);
  const x = c.decode("x", dDouble);
  const y = c.decode("y", dDouble);
  const arrowEndX = c.decode("arrowEndX", dDouble);
  const arrowEndY = c.decode("arrowEndY", dDouble);
  const text = c.decode("text", dString);
  const fontSize = c.decode("fontSize", dDouble);
  const showBackground = c.decode("showBackground", dBool);
  const color = c.decode("color", decodeCodableColor);
  const backgroundColor = c.decode("backgroundColor", decodeCodableColor);
  const lineWidth = c.decode("lineWidth", dDouble);
  const drawingStrokes = c.tryDecode("drawingStrokes", dArray(dArray(decodeCodablePoint))) ?? [];
  const fontWeight = c.tryDecodeIfPresent("fontWeight", eSubtitleWeight) ?? "Semibold";
  const uppercase = c.tryDecodeIfPresent("uppercase", dBool) ?? false;
  const fontName = c.tryDecodeIfPresent("fontName", dString);
  const opacity = c.tryDecodeIfPresent("opacity", dDouble) ?? 1;
  const cornerRadius = c.tryDecodeIfPresent("cornerRadius", dDouble) ?? 8;
  const animatesIn = c.tryDecodeIfPresent("animatesIn", dBool) ?? true;
  const showShadow = c.tryDecodeIfPresent("showShadow", dBool) ?? true;
  // Effects default from the legacy toggle: fade preserved the old look.
  const legacyDefault: AnnotationEffect = animatesIn ? "Fade" : "None";
  const enterEffect = c.tryDecodeIfPresent("enterEffect", eAnnotationEffect) ?? legacyDefault;
  const exitEffect = c.tryDecodeIfPresent("exitEffect", eAnnotationEffect) ?? "None";
  const backdropOpacity = c.tryDecodeIfPresent("backdropOpacity", dDouble) ?? 0;
  return withExtra(
    dropUndefined({
      id,
      type,
      startTime,
      endTime,
      x,
      y,
      arrowEndX,
      arrowEndY,
      text,
      fontSize,
      showBackground,
      color,
      backgroundColor,
      lineWidth,
      drawingStrokes,
      fontWeight,
      uppercase,
      fontName,
      opacity,
      cornerRadius,
      animatesIn,
      showShadow,
      enterEffect,
      exitEffect,
      backdropOpacity,
    }),
    c.extra(),
  );
};

/** Models/VoiceOverClip.swift `init(from:)` (clamps source fields). */
export const decodeVoiceOverClip: Decode<VoiceOverClip> = (v, path) => {
  const c = new Keyed(v, path, VOICE_OVER_CLIP_KEYS);
  const id = c.decode("id", dUUID);
  const fileName = c.decode("fileName", dString);
  const startTime = c.decode("startTime", dDouble);
  const duration = c.decode("duration", dDouble);
  const sourceStartTime = smax(0, c.decodeIfPresent("sourceStartTime", dDouble) ?? 0);
  const sourceDuration = smax(duration, c.decodeIfPresent("sourceDuration", dDouble) ?? duration);
  const gain = c.decodeIfPresent("gain", dDouble) ?? 1.0;
  const label = c.decodeIfPresent("label", dString) ?? "Voice Over";
  return withExtra(
    { id, fileName, startTime, sourceStartTime, duration, sourceDuration, gain, label },
    c.extra(),
  );
};

/** Models/SubtitleSegment.swift `WordTiming` — synthesized. */
const decodeWordTiming: Decode<WordTiming> = (v, path) => {
  const c = new Keyed(v, path, WORD_TIMING_KEYS);
  return withExtra(
    {
      id: c.decode("id", dUUID),
      startTime: c.decode("startTime", dDouble),
      endTime: c.decode("endTime", dDouble),
      text: c.decode("text", dString),
    },
    c.extra(),
  );
};

/** Models/SubtitleSegment.swift `init(from:)`. */
export const decodeSubtitleSegment: Decode<SubtitleSegment> = (v, path) => {
  const c = new Keyed(v, path, SUBTITLE_SEGMENT_KEYS);
  return withExtra(
    {
      id: c.decode("id", dUUID),
      startTime: c.decode("startTime", dDouble),
      endTime: c.decode("endTime", dDouble),
      text: c.decode("text", dString),
      words: c.decodeIfPresent("words", dArray(decodeWordTiming)) ?? [],
    },
    c.extra(),
  );
};

/** Models/VideoSpeedRegion.swift — synthesized. */
export const decodeSpeedRegion: Decode<VideoSpeedRegion> = (v, path) => {
  const c = new Keyed(v, path, SPEED_REGION_KEYS);
  return withExtra(
    {
      id: c.decode("id", dUUID),
      startTime: c.decode("startTime", dDouble),
      endTime: c.decode("endTime", dDouble),
      speed: c.decode("speed", dDouble),
    },
    c.extra(),
  );
};

/** Models/Project.swift `VideoClipSegment` — synthesized. */
export const decodeVideoClipSegment: Decode<VideoClipSegment> = (v, path) => {
  const c = new Keyed(v, path, VIDEO_CLIP_SEGMENT_KEYS);
  return withExtra(
    {
      id: c.decode("id", dUUID),
      startTime: c.decode("startTime", dDouble),
      endTime: c.decode("endTime", dDouble),
    },
    c.extra(),
  );
};

/** Models/Project.swift `ProjectSourceSegment` — synthesized. */
export const decodeSourceSegment: Decode<ProjectSourceSegment> = (v, path) => {
  const c = new Keyed(v, path, SOURCE_SEGMENT_KEYS);
  return withExtra(
    {
      startTime: c.decode("startTime", dDouble),
      duration: c.decode("duration", dDouble),
      kind: c.decode("kind", eSourceKind),
      contentX: c.decode("contentX", dDouble),
      contentY: c.decode("contentY", dDouble),
      contentWidth: c.decode("contentWidth", dDouble),
      contentHeight: c.decode("contentHeight", dDouble),
    },
    c.extra(),
  );
};

// ── Project ─────────────────────────────────────────────────────────────────

/** Models/Project.swift `init(from:)`. */
export const decodeProject: Decode<Project> = (v, path) => {
  const c = new Keyed(v, path, PROJECT_KEYS);
  const id = c.decode("id", dUUID);
  const name = c.decode("name", dString);
  const createdAt = c.decode("createdAt", dDate);
  const videoURL = c.decodeIfPresent("videoURL", dURL) ?? null;
  const cursorDataURL = c.decodeIfPresent("cursorDataURL", dURL) ?? null;
  const keystrokeDataURL = c.decodeIfPresent("keystrokeDataURL", dURL);
  const cameraVideoURL = c.decodeIfPresent("cameraVideoURL", dURL) ?? null;
  const cameraTimeOffset = c.decodeIfPresent("cameraTimeOffset", dDouble) ?? 0;
  const settings = c.decode("settings", decodeProjectSettings);
  settings.showCamera = cameraVideoURL !== null && settings.showCamera;
  const zoomRegions = c.decode("zoomRegions", dArray(decodeZoomRegion));
  const tiltRegions = c.decodeIfPresent("tiltRegions", dArray(decodeTiltRegion)) ?? [];
  const blurRegions = c.decodeIfPresent("blurRegions", dArray(decodeBlurRegion)) ?? [];
  const highlightRegions = c.decodeIfPresent("highlightRegions", dArray(decodeHighlightRegion)) ?? [];
  const focusRegions = c.decodeIfPresent("focusRegions", dArray(decodeFocusRegion)) ?? [];
  const cameraLayoutRegions = c.decodeIfPresent("cameraLayoutRegions", dArray(decodeCameraLayoutRegion)) ?? [];
  const annotations = c.decodeIfPresent("annotations", dArray(decodeAnnotation)) ?? [];
  const voiceOverClips = c.decodeIfPresent("voiceOverClips", dArray(decodeVoiceOverClip)) ?? [];
  const subtitles = c.decodeIfPresent("subtitles", dArray(decodeSubtitleSegment)) ?? [];
  const speedRegions = c.decodeIfPresent("speedRegions", dArray(decodeSpeedRegion)) ?? [];
  const splitPoints = c.decodeIfPresent("splitPoints", dArray(dDouble)) ?? [];
  const videoClipSegments = c.decodeIfPresent("videoClipSegments", dArray(decodeVideoClipSegment)) ?? [];
  const duration = c.decode("duration", dDouble);
  const trimStart = c.decodeIfPresent("trimStart", dDouble) ?? 0;
  const trimEnd = c.decodeIfPresent("trimEnd", dDouble) ?? 0;
  const recordingSourceKind = c.decodeIfPresent("recordingSourceKind", eSourceKind) ?? "display";
  const recordedAppBundleID = c.decodeIfPresent("recordedAppBundleID", dString);
  const sourceSegments = c.decodeIfPresent("sourceSegments", dArray(decodeSourceSegment)) ?? [];
  const reminderDate = c.decodeIfPresent("reminderDate", dDate);
  const isStillCapture = c.decodeIfPresent("isStillCapture", dBool) ?? false;
  const stillTreatment = c.decodeIfPresent("stillTreatment", eStillTreatment) ?? "image";
  return withExtra(
    dropUndefined({
      id,
      name,
      createdAt,
      videoURL,
      cursorDataURL,
      keystrokeDataURL,
      cameraVideoURL,
      cameraTimeOffset,
      settings,
      zoomRegions,
      tiltRegions,
      blurRegions,
      highlightRegions,
      focusRegions,
      cameraLayoutRegions,
      annotations,
      voiceOverClips,
      subtitles,
      speedRegions,
      splitPoints,
      videoClipSegments,
      duration,
      trimStart,
      trimEnd,
      recordingSourceKind,
      recordedAppBundleID,
      sourceSegments,
      reminderDate,
      isStillCapture,
      stillTreatment,
    }),
    c.extra(),
  );
};

/**
 * Parses a project.json value (already `JSON.parse`d) exactly as the Mac app
 * decodes it. Throws `ProjectDecodeError` wherever Swift's decoder throws.
 */
export function parseProject(json: unknown): Project {
  return decodeProject(json, "");
}

/** Parses project.json TEXT. Prefer this over `parseProject(JSON.parse(..))`
 * only for convenience — both are identical. */
export function parseProjectText(text: string): Project {
  return parseProject(JSON.parse(text));
}

function dropUndefined<T extends object>(o: T): T {
  for (const k of Object.keys(o) as Array<keyof T>) {
    if (o[k] === undefined) delete o[k];
  }
  return o;
}
