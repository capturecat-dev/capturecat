/**
 * cursor.json / keys.json → typed recordings, with the Mac loaders' decode
 * semantics (the exporter reads both with `try?`, so an undecodable file is
 * simply "no data"):
 *
 *   - `CursorTracker.loadRecording(from:)`: `CursorRecording` (synthesized
 *     Codable — `version`, `coordinateWidth`, `coordinateHeight`, `events`
 *     all required; every event needs `timestamp`, `x`, `y`, `isClick`),
 *     else a bare `[CursorEvent]` array (legacy files → coordinate space 0×0),
 *     else nil.
 *   - `KeystrokeTracker.loadRecording(from:)`: `KeystrokeRecording`
 *     (`version`, `events`; each event `timestamp` + a known `category` raw
 *     value, optional `shortcut` / `frontmostBundleID`), else nil.
 */
import type { CursorEvent, CursorRecording, KeystrokeEvent, KeystrokeRecording } from "../../../core/model/types";
import { KeystrokeCategory } from "../../../core/model/enums";

type Json = Record<string, unknown>;
const isObj = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);
const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const isInt = (v: unknown): v is number => isNum(v) && Number.isInteger(v);

function cursorEvent(v: unknown): CursorEvent | null {
  if (!isObj(v) || !isNum(v.timestamp) || !isNum(v.x) || !isNum(v.y) || typeof v.isClick !== "boolean") return null;
  return { timestamp: v.timestamp, x: v.x, y: v.y, isClick: v.isClick };
}

function cursorEvents(v: unknown): CursorEvent[] | null {
  if (!Array.isArray(v)) return null;
  const out: CursorEvent[] = new Array(v.length);
  for (let i = 0; i < v.length; i++) {
    const e = cursorEvent(v[i]);
    if (!e) return null;
    out[i] = e;
  }
  return out;
}

/** `CursorTracker.loadRecording` on already-parsed JSON; null = `try?` failed. */
export function decodeCursorRecording(json: unknown): CursorRecording | null {
  if (isObj(json)) {
    if (!isInt(json.version) || !isNum(json.coordinateWidth) || !isNum(json.coordinateHeight)) return null;
    const events = cursorEvents(json.events);
    if (!events) return null;
    return { version: json.version, coordinateWidth: json.coordinateWidth, coordinateHeight: json.coordinateHeight, events };
  }
  const legacy = cursorEvents(json);
  return legacy ? { version: 1, coordinateWidth: 0, coordinateHeight: 0, events: legacy } : null;
}

const CATEGORIES = new Set<string>(Object.values(KeystrokeCategory));

/** `KeystrokeTracker.loadRecording` on already-parsed JSON; null = `try?` failed. */
export function decodeKeystrokeRecording(json: unknown): KeystrokeRecording | null {
  if (!isObj(json) || !isInt(json.version) || !Array.isArray(json.events)) return null;
  const events: KeystrokeEvent[] = [];
  for (const raw of json.events) {
    if (!isObj(raw) || !isNum(raw.timestamp) || typeof raw.category !== "string" || !CATEGORIES.has(raw.category)) {
      return null;
    }
    const e: KeystrokeEvent = { timestamp: raw.timestamp, category: raw.category as KeystrokeEvent["category"] };
    if (raw.shortcut !== undefined && raw.shortcut !== null) {
      if (typeof raw.shortcut !== "string") return null;
      e.shortcut = raw.shortcut;
    }
    if (raw.frontmostBundleID !== undefined && raw.frontmostBundleID !== null) {
      if (typeof raw.frontmostBundleID !== "string") return null;
      e.frontmostBundleID = raw.frontmostBundleID;
    }
    events.push(e);
  }
  return { version: json.version, events };
}
