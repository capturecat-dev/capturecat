/**
 * The render engine's INPUT contract — the minimal subset of a Mac
 * `project.json` the engine currently draws, read straight from the raw JSON
 * keys (Swift `CodingKeys`, byte-for-byte).
 *
 * # Why this is not the project model
 *
 * The lossless project model (`editor/core/model`) is being ported in
 * parallel. This file deliberately does NOT define model types there; it
 * reads only what the engine needs, with the SAME defaults the Swift
 * `init(from:)` uses, so it can be swapped for `core/model` at merge time by
 * replacing `renderProjectFromJSON` with a selector over the parsed model.
 * Nothing in the engine reads raw JSON except this file.
 *
 * Sources (Swift → key → default):
 *   Project.trimStart / trimEnd  — decodeIfPresent ?? 0 (0 = "to the end")
 *   Project.duration             — decode (required)
 *   ProjectSettings.backgroundType        "Gradient" | "Mesh" | "Solid Color" | "Image" | "Wallpaper" | "Transparent"
 *   ProjectSettings.gradientStartColor / gradientEndColor / solidColor  CodableColor {red,green,blue,opacity} (sRGB)
 *   ProjectSettings.gradientAngle         decodeIfPresent → nil = legacy topLeading→bottomTrailing diagonal
 *   ProjectSettings.backgroundPadding     decode (default 48)
 *   ProjectSettings.videoPlacement        decodeIfPresent ?? "Center"
 *   ProjectSettings.videoCustomX / Y      decodeIfPresent → nil
 *   ProjectSettings.cornerRadius          decode (default 12)
 *   ProjectSettings.windowCornerRadius    decodeIfPresent ?? 8
 *   ProjectSettings.frameShape            decodeIfPresent ?? "Rounded Rectangle"
 *   ProjectSettings.shadowRadius          decode (default 20)
 *   ProjectSettings.shadowOpacity         decode (default 0.5)
 *   ProjectSettings.aspectRatio           decode ("Auto" | "16:9" | "4:3" | "1:1" | "9:16" | "21:9" | "4:5")
 *   ProjectSettings.exportSettings        ExportSettings {format, resolution, fps, quality, customWidth, customHeight, collapseStaticSpans}
 *   ProjectSettings.background* look keys, backgroundImagePath, menuBar* —
 *     read by the passes from the lossless core model (`Scene.extras.project`).
 *   Derived here: `deviceFrameActive` (recordingSourceKind + showDeviceFrame)
 *     and `menuBarCrop` (Hidden menu bar) — they change the card geometry.
 */

// ── Enum raw values (persistence identity — never rename) ───────────────────

export type BackgroundType =
  | "Gradient"
  | "Mesh"
  | "Solid Color"
  | "Image"
  | "Wallpaper"
  | "Transparent";

export type FrameShape = "Rounded Rectangle" | "Squircle" | "Rectangle";

export type VideoPlacement =
  | "Center"
  | "Top Left"
  | "Top"
  | "Top Right"
  | "Left"
  | "Right"
  | "Bottom Left"
  | "Bottom"
  | "Bottom Right";

export type AspectRatioId = "Auto" | "16:9" | "4:3" | "1:1" | "9:16" | "21:9" | "4:5";

export type ExportResolution = "720p" | "1080p" | "4K" | "Custom";

export type ExportFormat = "MP4" | "MOV" | "GIF";

/** `CodableColor` — straight-alpha sRGB doubles. */
export interface CodableColor {
  red: number;
  green: number;
  blue: number;
  opacity: number;
}

export interface RenderExportSettings {
  format: ExportFormat;
  resolution: ExportResolution;
  fps: number;
  quality: number;
  customWidth: number;
  customHeight: number;
}

export interface RenderSettings {
  backgroundType: BackgroundType;
  gradientStartColor: CodableColor;
  gradientEndColor: CodableColor;
  /** CSS degrees (0 = bottom→top, 90 = left→right). null = legacy diagonal. */
  gradientAngle: number | null;
  solidColor: CodableColor;
  backgroundPadding: number;
  videoPlacement: VideoPlacement;
  videoCustomX: number | null;
  videoCustomY: number | null;
  cornerRadius: number;
  windowCornerRadius: number;
  frameShape: FrameShape;
  shadowRadius: number;
  shadowOpacity: number;
  aspectRatio: AspectRatioId;
  exportSettings: RenderExportSettings;
  /**
   * DERIVED (project-level): the whole take is a framed device recording —
   * `recordingSourceKind == .device && settings.showDeviceFrame`
   * (VideoExporter `deviceFrameActive`).
   */
  deviceFrameActive: boolean;
  /**
   * DERIVED: the Hidden-menu-bar crop fraction of the source's top strip
   * (core exportLayout.menuBarCrop; 0 = none).
   */
  menuBarCrop: number;
}

export interface RenderProject {
  duration: number;
  trimStart: number;
  trimEnd: number;
  settings: RenderSettings;
  /**
   * Features present in the project that this engine does not draw yet.
   * Surfaced in the lab HUD / load result and, in the editor, as a notice over
   * the stage (ui/shell/UnsupportedNotice) so a silent mismatch is impossible.
   */
  unsupportedFeatures: string[];
}

// ── Defaults (Swift property initialisers) ──────────────────────────────────

/** `CodableColor(NSColor.systemPurple)` / `.systemBlue` resolved to sRGB (aqua, light). */
const SYSTEM_PURPLE: CodableColor = { red: 0.6862745, green: 0.3215686, blue: 0.8705882, opacity: 1 };
const SYSTEM_BLUE: CodableColor = { red: 0, green: 0.4784314, blue: 1, opacity: 1 };
const BLACK: CodableColor = { red: 0, green: 0, blue: 0, opacity: 1 };

export const DEFAULT_EXPORT_SETTINGS: RenderExportSettings = {
  format: "MP4",
  resolution: "1080p",
  fps: 60,
  quality: 0.85,
  customWidth: 1920,
  customHeight: 1080,
};

export const DEFAULT_RENDER_SETTINGS: RenderSettings = {
  backgroundType: "Gradient",
  gradientStartColor: SYSTEM_PURPLE,
  gradientEndColor: SYSTEM_BLUE,
  gradientAngle: null,
  solidColor: BLACK,
  backgroundPadding: 48,
  videoPlacement: "Center",
  videoCustomX: null,
  videoCustomY: null,
  cornerRadius: 12,
  windowCornerRadius: 8,
  frameShape: "Rounded Rectangle",
  shadowRadius: 20,
  shadowOpacity: 0.5,
  aspectRatio: "16:9",
  exportSettings: DEFAULT_EXPORT_SETTINGS,
  deviceFrameActive: false,
  menuBarCrop: 0,
};

// ── Parse (raw project.json → RenderProject) ────────────────────────────────

type Json = Record<string, unknown>;

const isObj = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);
const num = (v: unknown, fallback: number): number =>
  typeof v === "number" && Number.isFinite(v) ? v : fallback;
const optNum = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) ? v : null;
function oneOf<T extends string>(v: unknown, allowed: readonly T[], fallback: T): T {
  return typeof v === "string" && (allowed as readonly string[]).includes(v) ? (v as T) : fallback;
}
function color(v: unknown, fallback: CodableColor): CodableColor {
  if (!isObj(v)) return fallback;
  return {
    red: num(v.red, fallback.red),
    green: num(v.green, fallback.green),
    blue: num(v.blue, fallback.blue),
    opacity: num(v.opacity, fallback.opacity),
  };
}

const BACKGROUND_TYPES = ["Gradient", "Mesh", "Solid Color", "Image", "Wallpaper", "Transparent"] as const;
const FRAME_SHAPES = ["Rounded Rectangle", "Squircle", "Rectangle"] as const;
const PLACEMENTS = [
  "Center", "Top Left", "Top", "Top Right", "Left", "Right", "Bottom Left", "Bottom", "Bottom Right",
] as const;
const ASPECTS = ["Auto", "16:9", "4:3", "1:1", "9:16", "21:9", "4:5"] as const;
const RESOLUTIONS = ["720p", "1080p", "4K", "Custom"] as const;
const FORMATS = ["MP4", "MOV", "GIF"] as const;

/**
 * Reads the engine's subset out of a raw project.json object. Never throws on
 * a missing key (falls back to the Swift default) — a hard-fail decode is the
 * model port's job, not the renderer's.
 */
export function renderProjectFromJSON(raw: unknown): RenderProject {
  const p: Json = isObj(raw) ? raw : {};
  const s: Json = isObj(p.settings) ? p.settings : {};
  const e: Json = isObj(s.exportSettings) ? s.exportSettings : {};
  const d = DEFAULT_RENDER_SETTINGS;

  const settings: RenderSettings = {
    backgroundType: oneOf(s.backgroundType, BACKGROUND_TYPES, d.backgroundType),
    gradientStartColor: color(s.gradientStartColor, d.gradientStartColor),
    gradientEndColor: color(s.gradientEndColor, d.gradientEndColor),
    gradientAngle: optNum(s.gradientAngle),
    solidColor: color(s.solidColor, d.solidColor),
    backgroundPadding: num(s.backgroundPadding, d.backgroundPadding),
    videoPlacement: oneOf(s.videoPlacement, PLACEMENTS, d.videoPlacement),
    videoCustomX: optNum(s.videoCustomX),
    videoCustomY: optNum(s.videoCustomY),
    cornerRadius: num(s.cornerRadius, d.cornerRadius),
    windowCornerRadius: num(s.windowCornerRadius, d.windowCornerRadius),
    frameShape: oneOf(s.frameShape, FRAME_SHAPES, d.frameShape),
    shadowRadius: num(s.shadowRadius, d.shadowRadius),
    shadowOpacity: num(s.shadowOpacity, d.shadowOpacity),
    aspectRatio: oneOf(s.aspectRatio, ASPECTS, d.aspectRatio),
    exportSettings: {
      format: oneOf(e.format, FORMATS, DEFAULT_EXPORT_SETTINGS.format),
      resolution: oneOf(e.resolution, RESOLUTIONS, DEFAULT_EXPORT_SETTINGS.resolution),
      fps: Math.round(num(e.fps, DEFAULT_EXPORT_SETTINGS.fps)),
      quality: num(e.quality, DEFAULT_EXPORT_SETTINGS.quality),
      customWidth: Math.round(num(e.customWidth, DEFAULT_EXPORT_SETTINGS.customWidth)),
      customHeight: Math.round(num(e.customHeight, DEFAULT_EXPORT_SETTINGS.customHeight)),
    },
    deviceFrameActive: p.recordingSourceKind === "device" && s.showDeviceFrame !== false,
    menuBarCrop: hiddenMenuBarCrop(p, s),
  };

  return {
    duration: num(p.duration, 0),
    trimStart: num(p.trimStart, 0),
    trimEnd: num(p.trimEnd, 0),
    settings,
    unsupportedFeatures: detectUnsupported(p, s),
  };
}

/**
 * `VideoExporter.export` menuBarCrop (core exportLayout.menuBarCrop): Hidden
 * on a non-device take (no device source segment) removes
 * min(0.12, max(0, menuBarHeight / 100)) of the source's top.
 * ProjectSettings defaults: menuBarReplacement "Original", menuBarHeight 3.8.
 */
function hiddenMenuBarCrop(p: Json, s: Json): number {
  if (s.menuBarReplacement !== "Hidden" || p.recordingSourceKind === "device") return 0;
  const segs = Array.isArray(p.sourceSegments) ? (p.sourceSegments as Json[]) : [];
  if (segs.some((g) => isObj(g) && g.kind === "device")) return 0;
  return Math.min(0.12, Math.max(0, num(s.menuBarHeight, 3.8) / 100));
}

/** Everything the Mac exporter draws that this engine does not yet. */
function detectUnsupported(p: Json, _s: Json): string[] {
  const out: string[] = [];
  const nonEmpty = (k: string) => Array.isArray(p[k]) && (p[k] as unknown[]).length > 0;
  // Add a project key here (and its name to UNSUPPORTED_FEATURE_NAMES) for any
  // Mac-drawn feature the engine cannot draw yet — the editor shows a notice.
  const unsupportedKeys: string[] = [
    // Zoom/tilt (camera), blur/highlight/focus, subtitles, speed + clips (time
    // map), voice-overs (audio mix) and stitched device segments (per-frame
    // bezel switch + keynote dip — core deviceSegmentDip, parity fixtures 14
    // and 15) all render on the web now.
  ];
  for (const k of unsupportedKeys) {
    if (nonEmpty(k)) out.push(k);
  }
  // Backgrounds + every look filter, menu bar, device frames (passes/background,
  // menuBar, device), screen tilt / intro slide / motion blur (camera) all
  // render on the web now.
  return out;
}

/**
 * The unsupported-feature ids for a raw project.json — the SAME detection the
 * engine reports in `LoadedInfo.unsupportedFeatures`, callable on the main
 * thread so the editor's notice follows edits live.
 */
export function unsupportedFeatures(raw: unknown): string[] {
  const p: Json = isObj(raw) ? raw : {};
  return detectUnsupported(p, isObj(p.settings) ? p.settings : {});
}

/**
 * How the editor names each unsupported feature (Mac vocabulary, sentence
 * case). Ids the table does not know fall back to the key, de-camel-cased.
 */
export const UNSUPPORTED_FEATURE_NAMES: Readonly<Record<string, string>> = {
  sourceSegments: "Stitched iPhone segments",
};

export function unsupportedFeatureName(id: string): string {
  const known = UNSUPPORTED_FEATURE_NAMES[id];
  if (known) return known;
  const words = id.replace(/([a-z0-9])([A-Z])/g, "$1 $2").toLowerCase();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

// ── Media ───────────────────────────────────────────────────────────────────

/** URLs the engine loads. At merge time these are the presigned GETs. */
export interface RenderMedia {
  /** The screen recording (MP4/MOV, H.264 or HEVC). */
  video: string;
  /**
   * Every OTHER file the project references, keyed by the reference string
   * exactly as project.json spells it (cursorDataURL, keystrokeDataURL,
   * cameraVideoURL, settings.backgroundImagePath, settings.watermarkFileName,
   * settings.curtainLogoFileName, voice-over fileName …) → fetchable URL.
   * See media/assets.ts `refsOf`.
   */
  files?: Record<string, string>;
}
