/**
 * The exporter's sound-cue inputs (VideoExporter.export, "Audio mix" block):
 *
 *   clickTimes = clickSoundEnabled
 *       ? ClickRippleOverlay.discreteClickTimes(from: <processed cursor chain>,
 *                                               coordinateSize: <recording size or .zero>)
 *       : []
 *   keystrokes = keySoundEnabled ? KeystrokeTracker.loadRecording(keys.json).events : []
 *
 * Decoding mirrors Swift's `JSONDecoder` strictness: cursor.json is a
 * `CursorRecording` (or the legacy bare `[CursorEvent]` array, with a zero
 * coordinate space); keys.json must decode as a whole — one bad event (e.g.
 * an unknown category) makes `try?` yield nil, i.e. no key sounds at all.
 * The click detection itself is the shared core math (processCursorEvents +
 * discreteClickTimes, both locked to Swift).
 */
import type { CursorEvent, KeystrokeEvent, Project } from "../model/types";
import { KeystrokeCategory } from "../model/enums";
import { discreteClickTimes } from "../math/clickRippleOverlay";
import { processCursorEvents } from "../math/cursorChain";
import { effectiveTrimEnd } from "../time/clips";
import type { SoundCueInput } from "./mixPlan";

type Json = Record<string, unknown>;
const isObj = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);
const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

function decodeCursorEvent(v: unknown): CursorEvent | null {
  if (!isObj(v) || !isNum(v.timestamp) || !isNum(v.x) || !isNum(v.y) || typeof v.isClick !== "boolean") return null;
  return { timestamp: v.timestamp, x: v.x, y: v.y, isClick: v.isClick };
}

function decodeCursorEvents(v: unknown): CursorEvent[] | null {
  if (!Array.isArray(v)) return null;
  const out: CursorEvent[] = [];
  for (const e of v) {
    const d = decodeCursorEvent(e);
    if (!d) return null;
    out.push(d);
  }
  return out;
}

/** `CursorTracker.loadRecording(from:)` → (events, hasValidCoordinateSpace ? size : .zero), or null. */
export function decodeCursorRecording(raw: unknown): { events: CursorEvent[]; coordinateSize: { width: number; height: number } } | null {
  if (isObj(raw) && isNum(raw.version) && isNum(raw.coordinateWidth) && isNum(raw.coordinateHeight)) {
    const events = decodeCursorEvents(raw.events);
    if (events) {
      const valid = raw.coordinateWidth > 0 && raw.coordinateHeight > 0;
      return {
        events,
        coordinateSize: valid ? { width: raw.coordinateWidth, height: raw.coordinateHeight } : { width: 0, height: 0 },
      };
    }
  }
  const legacy = decodeCursorEvents(raw);
  return legacy ? { events: legacy, coordinateSize: { width: 0, height: 0 } } : null;
}

const CATEGORIES = new Set<string>(Object.values(KeystrokeCategory));

/** `KeystrokeTracker.loadRecording(from:).events`, or null when the file does not decode. */
export function decodeKeystrokeEvents(raw: unknown): KeystrokeEvent[] | null {
  if (!isObj(raw) || !isNum(raw.version) || !Array.isArray(raw.events)) return null;
  const out: KeystrokeEvent[] = [];
  for (const e of raw.events) {
    if (!isObj(e) || !isNum(e.timestamp) || typeof e.category !== "string" || !CATEGORIES.has(e.category)) return null;
    out.push({ timestamp: e.timestamp, category: e.category as KeystrokeEvent["category"] });
  }
  return out;
}

/** The exporter's click/key inputs for `buildAudioMixPlan`. */
export function exportSoundCues(project: Project, cursorJson: unknown, keysJson: unknown): SoundCueInput {
  const s = project.settings;
  let clickTimes: number[] = [];
  if (s.clickSoundEnabled && project.cursorDataURL) {
    const recording = decodeCursorRecording(cursorJson);
    const events = processCursorEvents(recording?.events ?? [], s, effectiveTrimEnd(project));
    clickTimes = discreteClickTimes(events, recording?.coordinateSize ?? { width: 0, height: 0 });
  }
  const keystrokes = s.keySoundEnabled && project.keystrokeDataURL ? (decodeKeystrokeEvents(keysJson) ?? []) : [];
  return { clickTimes, keystrokes };
}
