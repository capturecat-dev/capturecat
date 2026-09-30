/**
 * Port of apps/macos/CaptureCat/Services/MCPServer+Style.swift — the ONE
 * table behind `set_style` (whitelist + validation) and `style_options` (the
 * agent-facing catalog). Same keys, groups, ranges, enum value lists (Swift
 * `allCases` order), notes, `then` side effects, error texts and "did you
 * mean" suggestions.
 */
import {
  AnimationSpeed,
  AspectRatio,
  BackgroundType,
  CameraFilterStyle,
  CameraOrientation,
  CameraPosition,
  CameraShape,
  CameraTagPosition,
  ClickSoundStyle,
  CurtainUnveilCorner,
  CursorStyle,
  FrameShape,
  IntroSlideStyle,
  KeySoundStyle,
  MenuBarReplacement,
  MenuBarTitleAlignment,
  ScreenTiltMode,
  SubtitlePosition,
  SubtitleStyle,
  SubtitleWeight,
  VideoPlacement,
  enumValues,
} from "../../core/model/enums";
import type { CodableColor, Project, ProjectSettings } from "../../core/model/types";
import { smax, smin, srounded } from "../../core/math/swift";
import { ToolError } from "./errors";
import {
  boolValue,
  charCount,
  describeValue,
  doubleValue,
  formatNumber,
  graphemes,
  isJSONBool,
  round3,
  stringValue,
  trimWhitespaces,
} from "./json";
import type { JSONObject } from "./types";

// ── Colours ───────────────────────────────────────────────────────────────

/** Swift `UInt64(s, radix: 16)` — optional sign, hex digits only. */
function parseHexUInt64(s: string): bigint | null {
  let i = 0;
  let negative = false;
  if (s[0] === "+" || s[0] === "-") {
    negative = s[0] === "-";
    i = 1;
  }
  if (i >= s.length) return null;
  let v = 0n;
  for (; i < s.length; i++) {
    if (!/^[0-9a-fA-F]$/.test(s[i])) return null;
    v = v * 16n + BigInt(parseInt(s[i], 16));
  }
  if (negative) return v === 0n ? 0n : null;
  return v <= 0xffffffffffffffffn ? v : null;
}

/** `CodableColor(hex:)` — "#RRGGBB" / "#RRGGBBAA" ("#" optional); null when malformed. */
export function parseHexColor(hex: string): CodableColor | null {
  let chars = graphemes(trimWhitespaces(hex));
  if (chars[0] === "#") chars = chars.slice(1);
  if (chars.length !== 6 && chars.length !== 8) return null;
  const v = parseHexUInt64(chars.join(""));
  if (v === null) return null;
  const hasAlpha = chars.length === 8;
  const byte = (shift: bigint) => Number((v >> shift) & 0xffn);
  const r = hasAlpha ? byte(24n) : byte(16n);
  const g = hasAlpha ? byte(16n) : byte(8n);
  const b = hasAlpha ? byte(8n) : byte(0n);
  const a = hasAlpha ? byte(0n) : 0xff;
  return { red: r / 255, green: g / 255, blue: b / 255, opacity: a / 255 };
}

/** `MCPServer.hexString` — "#RRGGBB", or "#RRGGBBAA" when not fully opaque. */
export function hexString(color: CodableColor): string {
  // Int((min(1, max(0, v)) * 255).rounded()) — Swift min/max map NaN to 0.
  const byte = (v: number) => Math.abs(srounded(smin(1, smax(0, v)) * 255));
  const hex = (n: number) => n.toString(16).toUpperCase().padStart(2, "0");
  const rgb = `#${hex(byte(color.red))}${hex(byte(color.green))}${hex(byte(color.blue))}`;
  return color.opacity >= 0.999 ? rgb : rgb + hex(byte(color.opacity));
}

// ── The table ─────────────────────────────────────────────────────────────

export type StyleKind =
  | { type: "enum"; values: readonly string[] }
  | { type: "number"; min: number; max: number }
  | { type: "boolean" }
  | { type: "string"; maxLength: number }
  | { type: "color" };

type Settings = ProjectSettings & Record<string, unknown>;

export interface StyleKey {
  key: string;
  group: string;
  kind: StyleKind;
  note?: string;
  /** Optional in the model (reads as null when unset). */
  optional?: boolean;
  /** Post-write side effect (`then:` in Swift). */
  then?: (settings: ProjectSettings) => void;
}

/** Groups in display order (style_options and the set_style description). */
export const STYLE_GROUPS: readonly string[] = [
  "canvas",
  "background",
  "cursor",
  "clicksAndKeys",
  "camera",
  "menuBar",
  "motion",
  "intro",
  "audio",
  "subtitles",
  "watermark",
];

const en = (key: string, group: string, values: readonly string[], note?: string, then?: StyleKey["then"]): StyleKey => ({
  key,
  group,
  kind: { type: "enum", values },
  note,
  then,
});
const num = (key: string, group: string, min: number, max: number, note?: string, optional = false): StyleKey => ({
  key,
  group,
  kind: { type: "number", min, max },
  note,
  optional,
});
const bool = (key: string, group: string, note?: string, then?: StyleKey["then"]): StyleKey => ({
  key,
  group,
  kind: { type: "boolean" },
  note,
  then,
});
const text = (key: string, group: string, maxLength: number, note?: string, optional = false): StyleKey => ({
  key,
  group,
  kind: { type: "string", maxLength },
  note,
  optional,
});
const color = (key: string, group: string, note?: string, optional = false): StyleKey => ({
  key,
  group,
  kind: { type: "color" },
  note,
  optional,
});

export const STYLE_KEYS: readonly StyleKey[] = [
  // Canvas / frame.
  en("aspectRatio", "canvas", enumValues(AspectRatio), '"9:16" / "4:5" for vertical social cuts; "Auto" matches the recording'),
  num("backgroundPadding", "canvas", 0, 300, "space around the video card, canvas points"),
  en("videoPlacement", "canvas", enumValues(VideoPlacement), "clears any free (dragged) card position", (s) => {
    s.videoCustomX = undefined;
    s.videoCustomY = undefined;
  }),
  en("frameShape", "canvas", enumValues(FrameShape)),
  num("cornerRadius", "canvas", 0, 20),
  num("windowCornerRadius", "canvas", 0, 20),
  num("shadowRadius", "canvas", 0, 60),
  num("shadowOpacity", "canvas", 0, 1),
  bool("showDeviceFrame", "canvas", "iPhone/iPad takes: draw the device bezel"),

  // Background.
  en("backgroundType", "background", enumValues(BackgroundType), '"Image"/"Wallpaper" use the image or wallpaper already picked in the editor'),
  color("gradientStartColor", "background"),
  color("gradientEndColor", "background"),
  num("gradientAngle", "background", 0, 360, "degrees, 90 = left→right; null = legacy corner-to-corner diagonal", true),
  color("solidColor", "background"),
  num("backgroundBlur", "background", 0, 1),
  num("backgroundBrightness", "background", -1, 1),
  num("backgroundSaturation", "background", 0, 2),
  num("backgroundContrast", "background", 0.5, 1.5),
  num("backgroundHue", "background", 0, 360),
  color("backgroundTintColor", "background"),
  num("backgroundTintOpacity", "background", 0, 1),
  num("backgroundVignette", "background", 0, 1),
  num("backgroundPixelate", "background", 0, 1),
  num("backgroundHalftone", "background", 0, 1),
  num("backgroundNoise", "background", 0, 1),

  // Cursor.
  bool("showCursor", "cursor"),
  en("cursorStyle", "cursor", enumValues(CursorStyle)),
  num("cursorScale", "cursor", 0.5, 3),
  bool("cursorFluidEnabled", "cursor", "spring-smoothed movement; clicks stay pinned"),
  num("cursorTension", "cursor", 20, 600),
  num("cursorFriction", "cursor", 2, 80),
  num("cursorMass", "cursor", 0.2, 6),
  num("cursorTilt", "cursor", 0, 1),
  num("cursorStretch", "cursor", 0, 1),
  num("cursorDrag", "cursor", 0, 1),
  num("cursorWeight", "cursor", 0.5, 3),
  bool("smoothCursor", "cursor"),
  num("smoothingFactor", "cursor", 0.05, 0.5),
  bool("autoHideCursor", "cursor"),
  num("autoHideDelay", "cursor", 1, 10),
  bool("cursorLoopToStart", "cursor", "true turns cursorStopAtEnd off", (s) => {
    if (s.cursorLoopToStart) s.cursorStopAtEnd = false;
  }),
  bool("cursorStopAtEnd", "cursor", "true turns cursorLoopToStart off", (s) => {
    if (s.cursorStopAtEnd) s.cursorLoopToStart = false;
  }),

  // Click ripple, click/key sounds, shortcut overlay.
  bool("showClickRipple", "clicksAndKeys"),
  color("clickRippleColor", "clicksAndKeys"),
  num("clickRippleSize", "clicksAndKeys", 20, 100),
  bool("clickSoundEnabled", "clicksAndKeys"),
  num("clickSoundVolume", "clicksAndKeys", 0.1, 1),
  en("clickSoundStyle", "clicksAndKeys", enumValues(ClickSoundStyle)),
  bool("keySoundEnabled", "clicksAndKeys"),
  num("keySoundVolume", "clicksAndKeys", 0.1, 1),
  en("keySoundStyle", "clicksAndKeys", enumValues(KeySoundStyle)),
  bool("showKeystrokes", "clicksAndKeys", "shortcut pill (⌘⇧S); only renders shortcuts captured at record time"),
  bool("keystrokeOverlayScopeToRecordedApp", "clicksAndKeys", "window recordings: only shortcuts sent to the recorded app"),

  // Camera bubble.
  bool("showCamera", "camera", "no effect without a camera recording"),
  en("cameraPosition", "camera", enumValues(CameraPosition)),
  en("cameraShape", "camera", enumValues(CameraShape)),
  en("cameraOrientation", "camera", enumValues(CameraOrientation)),
  num("cameraSize", "camera", 60, 240),
  bool("cameraMirrored", "camera"),
  num("cameraBrightness", "camera", -1, 1),
  num("cameraContrast", "camera", 0.5, 1.5),
  num("cameraSaturation", "camera", 0, 2),
  num("cameraHue", "camera", -180, 180),
  en("cameraFilter", "camera", enumValues(CameraFilterStyle)),
  num("cameraRingLight", "camera", 0, 1),
  num("cameraCornerRadius", "camera", 0, 60),
  num("cameraBorderWidth", "camera", 0, 8),
  color("cameraBorderColor", "camera", undefined, true),
  num("cameraOpacity", "camera", 0.2, 1),
  num("cameraTiltPitch", "camera", -25, 25),
  num("cameraTiltYaw", "camera", -25, 25),
  text("cameraTagText", "camera", 60, "name tag; empty hides it"),
  text("cameraTagSubtext", "camera", 60),
  text("cameraTagFontName", "camera", 80, undefined, true),
  color("cameraTagTextColor", "camera"),
  color("cameraTagBackgroundColor", "camera"),
  en("cameraTagPosition", "camera", enumValues(CameraTagPosition)),

  // Menu bar replacement (display recordings).
  en("menuBarReplacement", "menuBar", enumValues(MenuBarReplacement)),
  text("menuBarTitle", "menuBar", 60),
  en("menuBarTitleAlignment", "menuBar", enumValues(MenuBarTitleAlignment)),
  bool("menuBarShowStatusIcons", "menuBar"),
  text("menuBarClock", "menuBar", 12),
  num("menuBarHeight", "menuBar", 2, 6, "% of video height"),

  // Motion feel + global screen tilt.
  en("animationSpeed", "motion", enumValues(AnimationSpeed), "default zoom/tilt transition pace for blocks without an animationStyle"),
  num("autoZoomLevel", "motion", 1.5, 4, "auto_zoom's base depth"),
  num("cameraFollowSpeed", "motion", 0, 1, "how tightly a zoomed camera chases the cursor"),
  bool("motionBlur", "motion"),
  num("motionBlurStrength", "motion", 0, 1),
  num("parallaxStrength", "motion", 0, 1),
  en("screenTiltMode", "motion", enumValues(ScreenTiltMode), "global 3D tilt while zoomed out (timeline tilt blocks are add_effect type tilt)"),
  num("screenTiltAngle", "motion", -60, 60),
  num("screenTiltYaw", "motion", -60, 60),
  num("screenTiltRoll", "motion", -30, 30),

  // Intro slide + curtain unveil (OUTPUT-time placement).
  en("introSlideStyle", "intro", enumValues(IntroSlideStyle)),
  num("introSlideDuration", "intro", 0.3, 3600),
  num("introSlideStart", "intro", 0, 3600, "OUTPUT seconds"),
  num("introSlideBounce", "intro", 0, 1),
  num("introSlideSpeed", "intro", 1, 4),
  en("curtainUnveilCorner", "intro", enumValues(CurtainUnveilCorner)),
  num("curtainUnveilDuration", "intro", 0.1, 3600),
  num("curtainUnveilStart", "intro", 0, 3600, "OUTPUT seconds"),
  num("curtainLogoOpacity", "intro", 0, 1),
  num("curtainLogoScale", "intro", 0.05, 0.8),
  color("curtainColor", "intro", undefined, true),
  color("curtainLogoTint", "intro", undefined, true),

  // Audio mix.
  num("systemAudioVolume", "audio", 0, 1),
  num("microphoneVolume", "audio", 0, 1),
  num("voiceOverVolume", "audio", 0, 1.5),
  bool("muteRecordedAudio", "audio"),

  // Subtitles (burned in when showSubtitles and the project has any).
  bool("showSubtitles", "subtitles", "burns the project's subtitles (from transcribe) into render/export"),
  num("subtitleFontSize", "subtitles", 16, 64),
  en("subtitlePosition", "subtitles", enumValues(SubtitlePosition)),
  en("subtitleStyle", "subtitles", enumValues(SubtitleStyle)),
  en("subtitleWeight", "subtitles", enumValues(SubtitleWeight)),
  bool("subtitleUppercase", "subtitles"),

  // Watermark (image picked in the editor).
  bool("showWatermark", "watermark", "needs a watermark image picked in the editor"),
  num("watermarkOpacity", "watermark", 0.1, 1),
  num("watermarkSize", "watermark", 40, 400),
  num("watermarkX", "watermark", 0, 1),
  num("watermarkY", "watermark", 0, 1),
];

const STYLE_KEY_INDEX: ReadonlyMap<string, StyleKey> = (() => {
  const map = new Map<string, StyleKey>();
  for (const entry of STYLE_KEYS) if (!map.has(entry.key)) map.set(entry.key, entry);
  return map;
})();

// ── Validation (the Swift write closures) ─────────────────────────────────

function validatedNumber(key: string, value: unknown, min: number, max: number): number {
  const d = isJSONBool(value) ? null : doubleValue(value);
  if (d === null || !Number.isFinite(d) || !(d >= min && d <= max)) {
    throw new ToolError(
      `invalid value for ${key}: ${describeValue(value)} (allowed: a number in ${formatNumber(min)}...${formatNumber(max)})`,
    );
  }
  return d;
}

function validatedText(key: string, value: unknown, maxLength: number): string {
  const s = stringValue(value);
  if (s === null || charCount(s) > maxLength) {
    throw new ToolError(`${key} must be a string of at most ${maxLength} characters`);
  }
  return s;
}

function validatedColor(key: string, value: unknown): CodableColor {
  const hex = stringValue(value);
  const parsed = hex === null ? null : parseHexColor(hex);
  if (parsed === null) {
    throw new ToolError(`${key} must be a hex color string, e.g. "#FF3B30" or "#FF3B30CC" (RRGGBB or RRGGBBAA)`);
  }
  return parsed;
}

function write(entry: StyleKey, settings: ProjectSettings, value: unknown): void {
  const s = settings as Settings;
  const { key, kind } = entry;
  switch (kind.type) {
    case "enum": {
      const raw = stringValue(value);
      if (raw === null || !kind.values.includes(raw)) {
        throw new ToolError(
          `invalid value for ${key}: ${describeValue(value)} (allowed: ` +
            kind.values.map((v) => `"${v}"`).join(", ") +
            " — exact, case-sensitive)",
        );
      }
      s[key] = raw;
      break;
    }
    case "number":
      s[key] = validatedNumber(key, value, kind.min, kind.max);
      break;
    case "boolean": {
      const b = boolValue(value);
      if (b === null) throw new ToolError(`${key} must be a boolean (true/false), got ${describeValue(value)}`);
      s[key] = b;
      break;
    }
    case "string":
      s[key] = validatedText(key, value, kind.maxLength);
      break;
    case "color":
      s[key] = validatedColor(key, value);
      break;
  }
  entry.then?.(settings);
}

function read(entry: StyleKey, settings: ProjectSettings): unknown {
  const v = (settings as Settings)[entry.key];
  if (entry.optional && (v === undefined || v === null)) return null;
  switch (entry.kind.type) {
    case "number":
      return round3(v as number);
    case "color":
      return hexString(v as CodableColor);
    default:
      return v;
  }
}

function schemaFragment(entry: StyleKey): JSONObject {
  const out: JSONObject = { group: entry.group };
  const kind = entry.kind;
  switch (kind.type) {
    case "enum":
      out.type = "enum";
      out.values = [...kind.values];
      break;
    case "number":
      out.type = "number";
      out.min = kind.min;
      out.max = kind.max;
      break;
    case "boolean":
      out.type = "boolean";
      break;
    case "string":
      out.type = "string";
      out.maxLength = kind.maxLength;
      break;
    case "color":
      out.type = "color";
      out.format = "#RRGGBB or #RRGGBBAA";
      break;
  }
  if (entry.note !== undefined) out.note = entry.note;
  return out;
}

// ── Apply / describe ──────────────────────────────────────────────────────

/** `MCPServer.applyStyle(key:value:to:)` — validates and writes one key. */
export function applyStyle(key: string, value: unknown, settings: ProjectSettings): void {
  const entry = STYLE_KEY_INDEX.get(key);
  if (!entry) {
    let message = `key not whitelisted: ${key}`;
    const suggestions = closestStyleKeys(key);
    if (suggestions.length > 0) {
      message += " — did you mean " + suggestions.map((s) => `'${s}'`).join(" or ") + "?";
    }
    message += " Call style_options for every settable key with its type, range and current value.";
    throw new ToolError(message);
  }
  write(entry, settings, value);
}

/** `MCPServer.styleKeySummary` — one line per group (set_style's description). */
export function styleKeySummary(): string {
  return STYLE_GROUPS.map((group) => {
    const keys = STYLE_KEYS.filter((k) => k.group === group).map((k) => k.key);
    const shown = keys.slice(0, 5).join(", ");
    return keys.length > 5 ? `${group}: ${shown}… (+${keys.length - 5})` : `${group}: ${shown}`;
  }).join("; ");
}

/** `MCPServer.styleOptions(for:group:)` — the style_options payload. `group`
 * is `arguments["group"] as? String` (a non-string means "all groups"). */
export function styleOptions(project: Project | null, group?: unknown): JSONObject {
  const wanted = typeof group === "string" ? group : null;
  if (wanted !== null && !STYLE_GROUPS.includes(wanted)) {
    throw new ToolError(`unknown group '${wanted}' (groups: ${STYLE_GROUPS.join(", ")})`);
  }
  const groups: JSONObject = {};
  for (const name of STYLE_GROUPS) {
    if (wanted !== null && wanted !== name) continue;
    const keys: JSONObject = {};
    for (const entry of STYLE_KEYS) {
      if (entry.group !== name) continue;
      const fragment = schemaFragment(entry);
      delete fragment.group;
      if (project) fragment.current = read(entry, project.settings);
      keys[entry.key] = fragment;
    }
    groups[name] = keys;
  }
  return {
    groups,
    keyCount: STYLE_KEYS.length,
    note:
      "Patch any of these with set_style {id, patch: {key: value}} (or an apply_edits " +
      "set_style op). Enum values are exact, case-sensitive raw values. Colors are hex strings.",
  };
}

// ── Suggestions ───────────────────────────────────────────────────────────

/** Foundation `String.contains(_:)` — an EMPTY needle is never contained. */
function containsText(haystack: string, needle: string): boolean {
  return needle.length > 0 && haystack.includes(needle);
}

function closestStyleKeys(query: string): string[] {
  const q = query.toLowerCase();
  const scored = STYLE_KEYS.map((entry): [string, number] => {
    const k = entry.key.toLowerCase();
    if (containsText(k, q) || containsText(q, k)) return [entry.key, 0];
    return [entry.key, levenshtein(q, k)];
  });
  const limit = Math.max(2, Math.trunc(charCount(q) / 4));
  return scored
    .filter(([, score]) => score <= limit)
    .sort((a, b) => a[1] - b[1])
    .slice(0, 2)
    .map(([key]) => key);
}

/** Edit distance over Characters (grapheme clusters). */
export function levenshtein(aText: string, bText: string): number {
  const a = graphemes(aText);
  const b = graphemes(bText);
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const current = [i, ...new Array<number>(b.length).fill(0)];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return previous[b.length];
}
