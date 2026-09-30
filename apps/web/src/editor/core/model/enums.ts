/**
 * Every persisted Swift enum, raw values BYTE-FOR-BYTE.
 *
 * Swift enum raw values are persistence identity (CLAUDE.md): never rename a
 * value here, never "tidy" the casing. Each enum is a `const` object whose
 * keys are the Swift case names and whose values are the raw values written to
 * project.json, plus a string-union type of the raw values. `values(...)`
 * lists the raw values for validation.
 *
 * Source of truth: apps/macos/CaptureCat/Models/*.swift and the Services that
 * declare persisted enums (IntroSlideMath, CurtainUnveilMath, KeystrokeOverlay,
 * ClickSoundPlayer, KeySoundPlayer, KeystrokeTracker).
 */

type ValueOf<T> = T[keyof T];

export function enumValues<T extends Record<string, string>>(e: T): ReadonlyArray<ValueOf<T>> {
  return Object.values(e) as ValueOf<T>[];
}

// ── Project.swift ────────────────────────────────────────────────────────────
export const RecordingSourceKind = {
  display: "display",
  window: "window",
  area: "area",
  device: "device",
} as const;
export type RecordingSourceKind = ValueOf<typeof RecordingSourceKind>;

export const StillTreatment = { image: "image", video: "video" } as const;
export type StillTreatment = ValueOf<typeof StillTreatment>;

// ── ProjectSettings.swift (nested enums) ────────────────────────────────────
export const BackgroundType = {
  gradient: "Gradient",
  mesh: "Mesh",
  solid: "Solid Color",
  image: "Image",
  wallpaper: "Wallpaper",
  transparent: "Transparent",
} as const;
export type BackgroundType = ValueOf<typeof BackgroundType>;

export const MenuBarTitleAlignment = { left: "Left", center: "Center", right: "Right" } as const;
export type MenuBarTitleAlignment = ValueOf<typeof MenuBarTitleAlignment>;

export const MenuBarReplacement = {
  off: "Original",
  hidden: "Hidden",
  dark: "Clean Dark",
  light: "Clean Light",
} as const;
export type MenuBarReplacement = ValueOf<typeof MenuBarReplacement>;

export const CursorStyle = {
  system: "macOS Arrow",
  inverted: "White Arrow",
  hand: "Hand",
  dot: "Dot",
  ring: "Ring",
} as const;
export type CursorStyle = ValueOf<typeof CursorStyle>;

export const CameraPosition = {
  topLeft: "Top Left",
  topRight: "Top Right",
  bottomLeft: "Bottom Left",
  bottomRight: "Bottom Right",
} as const;
export type CameraPosition = ValueOf<typeof CameraPosition>;

export const CameraShape = {
  circle: "Circle",
  squircle: "Squircle",
  roundedRect: "Rounded Rectangle",
  square: "Square",
} as const;
export type CameraShape = ValueOf<typeof CameraShape>;

export const CameraFilterStyle = {
  none: "None",
  mono: "Mono",
  noir: "Noir",
  warm: "Warm",
  cool: "Cool",
  fade: "Fade",
} as const;
export type CameraFilterStyle = ValueOf<typeof CameraFilterStyle>;

export const CameraOrientation = { auto: "Auto", vertical: "Vertical", wide: "Wide" } as const;
export type CameraOrientation = ValueOf<typeof CameraOrientation>;

export const CameraTagPosition = {
  below: "Below",
  above: "Above",
  overlapBottom: "Overlap Bottom",
} as const;
export type CameraTagPosition = ValueOf<typeof CameraTagPosition>;

export const SubtitlePosition = { top: "Top", center: "Center", bottom: "Bottom" } as const;
export type SubtitlePosition = ValueOf<typeof SubtitlePosition>;

export const SubtitleStyle = {
  outline: "Outline",
  background: "Background",
  glow: "Glow",
  plain: "Plain",
} as const;
export type SubtitleStyle = ValueOf<typeof SubtitleStyle>;

export const SubtitleWeight = {
  regular: "Regular",
  medium: "Medium",
  semibold: "Semibold",
  bold: "Bold",
  heavy: "Heavy",
} as const;
export type SubtitleWeight = ValueOf<typeof SubtitleWeight>;

export const VideoPlacement = {
  center: "Center",
  topLeft: "Top Left",
  top: "Top",
  topRight: "Top Right",
  left: "Left",
  right: "Right",
  bottomLeft: "Bottom Left",
  bottom: "Bottom",
  bottomRight: "Bottom Right",
} as const;
export type VideoPlacement = ValueOf<typeof VideoPlacement>;

export const FrameShape = {
  roundedRect: "Rounded Rectangle",
  squircle: "Squircle",
  rectangle: "Rectangle",
} as const;
export type FrameShape = ValueOf<typeof FrameShape>;

export const ScreenTiltMode = {
  off: "Off",
  intro: "Intro",
  zoomedOut: "Zoomed Out",
  both: "Both",
} as const;
export type ScreenTiltMode = ValueOf<typeof ScreenTiltMode>;

export const AnimationSpeed = { slow: "Slow", mellow: "Mellow", quick: "Quick", rapid: "Rapid" } as const;
export type AnimationSpeed = ValueOf<typeof AnimationSpeed>;

/** `ProjectSettings.AnimationSpeed.duration`. */
export function animationSpeedDuration(speed: AnimationSpeed): number {
  switch (speed) {
    case "Slow":
      return 1.2;
    case "Mellow":
      return 0.8;
    case "Quick":
      return 0.5;
    case "Rapid":
      return 0.3;
  }
}

// ── ExportSettings.swift ────────────────────────────────────────────────────
export const ExportFormat = { mp4: "MP4", mov: "MOV", gif: "GIF" } as const;
export type ExportFormat = ValueOf<typeof ExportFormat>;

export const ExportResolution = {
  hd720: "720p",
  hd1080: "1080p",
  uhd4k: "4K",
  custom: "Custom",
} as const;
export type ExportResolution = ValueOf<typeof ExportResolution>;

// ── AspectRatio.swift ───────────────────────────────────────────────────────
export const AspectRatio = {
  auto: "Auto",
  widescreen: "16:9",
  standard: "4:3",
  square: "1:1",
  vertical: "9:16",
  ultrawide: "21:9",
  tallVertical: "4:5",
} as const;
export type AspectRatio = ValueOf<typeof AspectRatio>;

// ── ZoomRegion.swift ────────────────────────────────────────────────────────
export const ZoomAnimationStyle = {
  instant: "Instant",
  snappy: "Snappy",
  smooth: "Smooth",
  slowGlide: "Slow Glide",
  cinematic: "Cinematic",
} as const;
export type ZoomAnimationStyle = ValueOf<typeof ZoomAnimationStyle>;

/** `ZoomAnimationStyle.omegaMultiplier`. */
export function zoomStyleOmegaMultiplier(style: ZoomAnimationStyle): number {
  switch (style) {
    case "Instant":
      return 8.0;
    case "Snappy":
      return 1.5;
    case "Smooth":
      return 1.0;
    case "Slow Glide":
      return 0.75;
    case "Cinematic":
      return 0.6;
  }
}

/** `ZoomAnimationStyle.damping`. */
export function zoomStyleDamping(style: ZoomAnimationStyle): number {
  switch (style) {
    case "Instant":
      return 1.0;
    case "Snappy":
      return 0.72;
    case "Smooth":
      return 0.88;
    case "Slow Glide":
      return 1.0;
    case "Cinematic":
      return 1.05;
  }
}

// ── BlurRegion.swift / FocusRegion.swift ────────────────────────────────────
export const BlurStyle = { blur: "Blur", pixelate: "Pixelate" } as const;
export type BlurStyle = ValueOf<typeof BlurStyle>;

export const FocusRegionStyle = { area: "Area", tiltShift: "Tilt Shift" } as const;
export type FocusRegionStyle = ValueOf<typeof FocusRegionStyle>;

// ── Annotation.swift ────────────────────────────────────────────────────────
export const AnnotationEffect = {
  none: "None",
  fade: "Fade",
  pop: "Pop",
  scaleUp: "Scale",
  slideUp: "Slide Up",
  drop: "Drop",
  explode: "Explode",
  drawOn: "Draw On",
} as const;
export type AnnotationEffect = ValueOf<typeof AnnotationEffect>;

export const AnnotationType = {
  text: "text",
  arrow: "arrow",
  callout: "callout",
  drawing: "drawing",
  rectangle: "rectangle",
  ellipse: "ellipse",
  tap: "tap",
} as const;
export type AnnotationType = ValueOf<typeof AnnotationType>;

// ── CameraLayoutRegion.swift ────────────────────────────────────────────────
export const CameraLayoutMode = {
  bubble: "bubble",
  cameraOnly: "cameraOnly",
  sideBySide: "sideBySide",
  screenOnly: "screenOnly",
} as const;
export type CameraLayoutMode = ValueOf<typeof CameraLayoutMode>;

// ── Services-declared persisted enums ───────────────────────────────────────
/** Services/ClickSoundPlayer.swift */
export const ClickSoundStyle = {
  softTick: "Soft Tick",
  clicky: "Clicky",
  deep: "Deep",
  pop: "Pop",
} as const;
export type ClickSoundStyle = ValueOf<typeof ClickSoundStyle>;

/** Services/KeySoundPlayer.swift */
export const KeySoundStyle = {
  thock: "Thock",
  clacky: "Clacky",
  soft: "Soft",
  cream: "Cream",
  blueClick: "Blue Click",
  typewriter: "Typewriter",
  membrane: "Membrane",
} as const;
export type KeySoundStyle = ValueOf<typeof KeySoundStyle>;

/** Services/KeystrokeOverlay.swift */
export const KeystrokeOverlayPosition = {
  bottomCenter: "bottomCenter",
  bottomLeft: "bottomLeft",
  bottomRight: "bottomRight",
  topCenter: "topCenter",
} as const;
export type KeystrokeOverlayPosition = ValueOf<typeof KeystrokeOverlayPosition>;

/** Services/KeystrokeOverlay.swift */
export const KeystrokeOverlayAnimation = { slideUp: "slideUp", fade: "fade", pop: "pop" } as const;
export type KeystrokeOverlayAnimation = ValueOf<typeof KeystrokeOverlayAnimation>;

/** Services/IntroSlideMath.swift */
export const IntroSlideStyle = {
  off: "Off",
  top: "Top",
  bottom: "Bottom",
  left: "Left",
  right: "Right",
} as const;
export type IntroSlideStyle = ValueOf<typeof IntroSlideStyle>;

/** Services/CurtainUnveilMath.swift */
export const CurtainUnveilCorner = {
  off: "Off",
  topLeft: "Top Left",
  topRight: "Top Right",
  bottomLeft: "Bottom Left",
  bottomRight: "Bottom Right",
} as const;
export type CurtainUnveilCorner = ValueOf<typeof CurtainUnveilCorner>;

/** Services/KeystrokeTracker.swift — `KeystrokeEvent.Category` (keys.json). */
export const KeystrokeCategory = {
  key: "key",
  space: "space",
  return: "return",
  delete: "delete",
  modifier: "modifier",
  scroll: "scroll",
} as const;
export type KeystrokeCategory = ValueOf<typeof KeystrokeCategory>;
