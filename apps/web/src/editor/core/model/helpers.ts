/**
 * Derived model properties — ports of the computed properties / helpers on
 * the Swift model types (Project.swift extensions, SubtitleSegment.groupWords,
 * SubtitlePreset, ProjectSourceSegment). Locked by the `modelHelpers`,
 * `subtitleGroupWords` and `subtitlePresets` golden vectors.
 */
import type { SubtitleStyle, SubtitleWeight } from "./enums";
import type {
  CodableColor,
  Project,
  ProjectSettings,
  ProjectSourceSegment,
  Rect,
  SubtitleSegment,
  WordTiming,
} from "./types";
import { DEFAULT_COLORS, newUUID, STILL_DEFAULT_DURATION } from "./defaults";

type ImageCaptureProject = Pick<Project, "isStillCapture" | "cursorDataURL" | "recordingSourceKind" | "duration">;

/** `Project.isImageCapture` — flagged stills, or legacy stills recognised by
 * their signature (StillMovieWriter default duration, no cursor track, not
 * a device take). */
export function isImageCapture(p: ImageCaptureProject): boolean {
  if (p.isStillCapture) return true;
  return (
    p.cursorDataURL === null &&
    p.recordingSourceKind !== "device" &&
    Math.abs(p.duration - STILL_DEFAULT_DURATION) < 0.01
  );
}

type TimedEffectsProject = Pick<
  Project,
  "zoomRegions" | "tiltRegions" | "speedRegions" | "cameraLayoutRegions" | "voiceOverClips" | "annotations"
> & { settings: Pick<ProjectSettings, "introSlideStyle" | "curtainUnveilCorner"> };

/** `Project.hasTimedEffects` — effects that only read as motion over time. */
export function hasTimedEffects(p: TimedEffectsProject): boolean {
  return (
    p.zoomRegions.length > 0 ||
    p.tiltRegions.length > 0 ||
    p.speedRegions.length > 0 ||
    p.cameraLayoutRegions.length > 0 ||
    p.voiceOverClips.length > 0 ||
    p.settings.introSlideStyle !== "Off" ||
    p.settings.curtainUnveilCorner !== "Off" ||
    p.annotations.some((a) => a.type === "tap")
  );
}

/** `Project.presentsTimelessTimeline` */
export function presentsTimelessTimeline(p: ImageCaptureProject & Pick<Project, "stillTreatment">): boolean {
  return isImageCapture(p) && p.stillTreatment === "image";
}

/** `Project.hidesTimelinePlayhead` */
export function hidesTimelinePlayhead(
  p: ImageCaptureProject & Pick<Project, "stillTreatment"> & TimedEffectsProject,
): boolean {
  return presentsTimelessTimeline(p) && !hasTimedEffects(p);
}

/** `ProjectSourceSegment.endTime` */
export function sourceSegmentEnd(s: Pick<ProjectSourceSegment, "startTime" | "duration">): number {
  return s.startTime + s.duration;
}

/** `ProjectSourceSegment.normalizedContentRect` (0 to 1, top-left origin). */
export function normalizedContentRect(s: ProjectSourceSegment): Rect {
  return { x: s.contentX, y: s.contentY, width: s.contentWidth, height: s.contentHeight };
}

/** `String.trimmingCharacters(in: .whitespaces)` — Unicode Zs + tab (not newlines). */
function trimWhitespaces(s: string): string {
  return s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");
}

/**
 * `SubtitleSegment.groupWords(_:maxDuration:maxWords:)` — word-level
 * segments grouped into display chunks (fresh ids, like Swift).
 */
export function groupWords(
  words: readonly Pick<SubtitleSegment, "startTime" | "endTime" | "text">[],
  maxDuration = 3.0,
  maxWords = 8,
): SubtitleSegment[] {
  if (words.length === 0) return [];
  const groups: SubtitleSegment[] = [];
  let currentWords: string[] = [];
  let currentTimings: WordTiming[] = [];
  let groupStart = words[0].startTime;
  let groupEnd = words[0].endTime;
  const flush = () =>
    groups.push({
      id: newUUID(),
      startTime: groupStart,
      endTime: groupEnd,
      text: currentWords.join(" "),
      words: currentTimings,
    });

  for (const word of words) {
    const wouldExceedDuration = word.endTime - groupStart > maxDuration;
    const wouldExceedWords = currentWords.length >= maxWords;
    const last = currentWords.length > 0 ? currentWords[currentWords.length - 1] : undefined;
    const isAfterPunctuation =
      last !== undefined && (last.endsWith(".") || last.endsWith("?") || last.endsWith("!"));
    if (currentWords.length > 0 && (wouldExceedDuration || wouldExceedWords || isAfterPunctuation)) {
      flush();
      currentWords = [];
      currentTimings = [];
      groupStart = word.startTime;
    }
    const trimmed = trimWhitespaces(word.text);
    currentWords.push(trimmed);
    currentTimings.push({ id: newUUID(), startTime: word.startTime, endTime: word.endTime, text: trimmed });
    groupEnd = word.endTime;
  }
  if (currentWords.length > 0) flush();
  return groups;
}

export interface SubtitlePreset {
  id: string;
  name: string;
  style: SubtitleStyle;
  weight: SubtitleWeight;
  uppercase: boolean;
  color: CodableColor;
  background: CodableColor | null;
  karaoke: boolean;
  highlight: CodableColor | null;
}

const W = DEFAULT_COLORS.white;
const neonBlue: CodableColor = { red: 0.55, green: 0.75, blue: 1.0, opacity: 1 };

/** `SubtitlePreset.all` (Models/SubtitlePreset.swift; card identity only). */
export const subtitlePresets: readonly SubtitlePreset[] = [
  { id: "clean", name: "Clean", style: "Outline", weight: "Bold", uppercase: false, color: W, background: null, karaoke: false, highlight: null },
  { id: "boxed", name: "Boxed", style: "Background", weight: "Semibold", uppercase: false, color: W, background: DEFAULT_COLORS.black, karaoke: false, highlight: null },
  { id: "neon", name: "Neon", style: "Glow", weight: "Heavy", uppercase: true, color: neonBlue, background: null, karaoke: false, highlight: null },
  { id: "karaoke", name: "Karaoke", style: "Outline", weight: "Bold", uppercase: false, color: W, background: null, karaoke: true, highlight: DEFAULT_COLORS.systemYellow },
  { id: "shout", name: "Shout", style: "Outline", weight: "Heavy", uppercase: true, color: DEFAULT_COLORS.systemYellow, background: null, karaoke: false, highlight: null },
  { id: "minimal", name: "Minimal", style: "Plain", weight: "Regular", uppercase: false, color: W, background: null, karaoke: false, highlight: null },
];

type PresetSettings = Pick<
  ProjectSettings,
  | "subtitleStyle"
  | "subtitleWeight"
  | "subtitleUppercase"
  | "subtitleColor"
  | "subtitleBackgroundColor"
  | "highlightWords"
  | "subtitleHighlightColor"
>;

/** `SubtitlePreset.apply(to:)` — returns updated settings (immutable). */
export function applySubtitlePreset<T extends PresetSettings>(preset: SubtitlePreset, settings: T): T {
  const next = { ...settings };
  next.subtitleStyle = preset.style;
  next.subtitleWeight = preset.weight;
  next.subtitleUppercase = preset.uppercase;
  next.subtitleColor = { ...preset.color };
  if (preset.background) next.subtitleBackgroundColor = { ...preset.background };
  next.highlightWords = preset.karaoke;
  if (preset.highlight) next.subtitleHighlightColor = { ...preset.highlight };
  return next;
}

/** `SubtitlePreset.matches(_:)` — colours excluded. */
export function subtitlePresetMatches(preset: SubtitlePreset, s: PresetSettings): boolean {
  return (
    s.subtitleStyle === preset.style &&
    s.subtitleWeight === preset.weight &&
    s.subtitleUppercase === preset.uppercase &&
    s.highlightWords === preset.karaoke
  );
}
