/**
 * Auto Zoom + Motion as PURE edits on a mutable (draft) project — ports of
 *
 *   - Services/AutoZoomApplier.swift   `AutoZoomApplier.apply(to:zoomLevel:)`
 *   - Services/StillMotionComposer.swift `StillMotionApplier.install / apply`
 *   - Services/MCPServer+Edits.swift   `opAutoZoom` (the routing the MCP
 *     `auto_zoom` tool uses: image captures → Motion, else Auto Zoom)
 *   - Services/CursorTracker.swift     `CursorTracker.load(from:)` (cursor.json)
 *   - Services/KeystrokeTracker.swift  `KeystrokeTracker.loadRecording(from:)` (keys.json)
 *
 * The Swift appliers read files (cursor.json, keys.json, the recording's
 * video track). This module is I/O-free: the caller loads those and passes
 * `AutoZoomInputs`; every decision after that is the Swift's, byte for byte.
 *
 * Locked to the REAL Swift by `core/vectors/autoZoom.test.ts` — golden
 * cases recorded by driving the Mac binary's MCP `auto_zoom` tool over
 * synthetic projects and reading back the project.json it wrote.
 */
import { isImageCapture } from "../model/helpers";
import { newUUID } from "../model/defaults";
import type { CursorEvent, KeystrokeEvent, Project, Size, TiltRegion, ZoomRegion } from "../model/types";
import { KeystrokeCategory } from "../model/enums";
import { generateZoomRegions, stableSortByStart } from "../math/autoZoomGenerator";
import { smooth } from "../math/cursorSmoother";
import { composeStillMotion, type StillMotionPlan } from "../math/stillMotion";

/** What AutoZoomApplier loads from disk, loaded by the caller instead. */
export interface AutoZoomInputs {
  /** Events of the project's cursor.json (`parseCursorFile`), or null when the
   * file is missing / fails to decode (Swift `try? CursorTracker.load` → nil). */
  cursor: CursorEvent[] | null;
  /** Events of keys.json (`parseKeystrokeFile`); [] when missing / undecodable
   * (Swift `(try? loadRecording(from:).events) ?? []`). */
  keystrokes: KeystrokeEvent[];
  /** The recording's FIRST video track `naturalSize` (encoded pixel size,
   * NOT rotated by preferredTransform — AVAssetTrack.naturalSize), or null
   * when the file has no video track / cannot be opened. Ignored when
   * `project.videoURL` is null. */
  videoNaturalSize: { width: number; height: number } | null;
}

/** AutoZoomApplier's screen size: the video track's natural size halved
 * (3840×2160 when there is no track → 1920×1080), or 1920×1080 when the
 * project has no video URL at all. */
export function autoZoomScreenSize(project: Pick<Project, "videoURL">, videoNaturalSize: Size | null): Size {
  if (project.videoURL !== null && project.videoURL !== undefined) {
    const natural = videoNaturalSize ?? { width: 3840, height: 2160 };
    return { width: natural.width / 2, height: natural.height / 2 };
  }
  return { width: 1920, height: 1080 };
}

/**
 * `AutoZoomApplier.apply(to:zoomLevel:)` — generates and installs auto zoom
 * regions. MUTATES `project.zoomRegions` (earlier auto regions replaced,
 * manual blocks kept and routed around, the merged list stably sorted by
 * start) and returns how many regions were created. 0 = no cursor data or no
 * zoom-worthy activity; the project is untouched in that case.
 *
 * `zoomLevel` null/undefined = `project.settings.autoZoomLevel`.
 */
export function applyAutoZoom(
  project: Project,
  inputs: AutoZoomInputs,
  zoomLevel?: number | null,
  makeId: () => string = newUUID,
): number {
  if (project.cursorDataURL === null || project.cursorDataURL === undefined) return 0;
  let cursorEvents = inputs.cursor;
  if (cursorEvents === null || cursorEvents.length === 0) return 0;

  // Mirrors the preview: smoothing from the CURRENT settings, never baked in.
  // (ProjectSettings decode forces smoothCursor false today — kept faithful.)
  if (project.settings.smoothCursor) {
    cursorEvents = smooth(cursorEvents, project.settings.smoothingFactor);
  }

  const screenSize = autoZoomScreenSize(project, inputs.videoNaturalSize);

  const keystrokes =
    project.keystrokeDataURL !== null && project.keystrokeDataURL !== undefined ? inputs.keystrokes : [];

  const manualRegions = project.zoomRegions.filter((r) => r.isAuto !== true);
  const regions = generateZoomRegions(
    cursorEvents,
    project.duration,
    screenSize,
    zoomLevel ?? project.settings.autoZoomLevel,
    keystrokes,
    manualRegions,
    makeId,
  );
  if (regions.length === 0) return 0;

  project.zoomRegions = stableSortByStart([...manualRegions, ...regions]);
  return regions.length;
}

/**
 * `StillMotionApplier.install(_:into:)` — previously generated Motion/auto
 * zoom regions (isAuto == true) are replaced, along with the tilt spans that
 * exactly mirror them (±1 ms); the user's hand-placed blocks stay. MUTATES
 * `project.zoomRegions` / `project.tiltRegions`. Returns the number of zoom
 * regions created (0 = empty plan, project untouched).
 */
export function installStillMotion(plan: StillMotionPlan, project: Project): number {
  if (plan.zoomRegions.length === 0) return 0;
  const removedAuto = project.zoomRegions.filter((r) => r.isAuto === true);
  project.zoomRegions = project.zoomRegions.filter((r) => r.isAuto !== true);
  // Tilts have no isAuto flag: a tilt is ours iff its span exactly mirrors a
  // removed auto zoom — how Motion creates them.
  project.tiltRegions = project.tiltRegions.filter(
    (tilt: TiltRegion) =>
      !removedAuto.some(
        (z: ZoomRegion) =>
          Math.abs(z.startTime - tilt.startTime) < 0.001 && Math.abs(z.endTime - tilt.endTime) < 0.001,
      ),
  );
  project.zoomRegions = stableSortByStart([...project.zoomRegions, ...plan.zoomRegions]);
  project.tiltRegions = stableSortByStart([...project.tiltRegions, ...plan.tiltRegions]);
  return plan.zoomRegions.length;
}

/** `StillMotionApplier.apply(to:)` — compose the four-corner tour for
 * `project.duration` and install it (needs nothing but the project). */
export function applyStillMotion(project: Project, makeId: () => string = newUUID): number {
  return installStillMotion(composeStillMotion(project.duration, makeId), project);
}

export type AutoZoomOpResult =
  | { ok: true; mode: "auto-zoom" | "still-motion"; created: number }
  | { ok: false; error: string };

/**
 * `MCPServer.opAutoZoom` routing (the MCP `auto_zoom` tool / WebMCP twin):
 * image captures without cursor data get Motion; otherwise Auto Zoom. On
 * `ok: false` the project is untouched (the Swift throws before writing).
 */
export function runAutoZoomOp(
  project: Project,
  inputs: AutoZoomInputs,
  zoomLevel?: number | null,
  makeId: () => string = newUUID,
): AutoZoomOpResult {
  if ((project.cursorDataURL === null || project.cursorDataURL === undefined) && isImageCapture(project)) {
    const created = applyStillMotion(project, makeId);
    if (!(created > 0)) return { ok: false, error: "could not compose a motion tour for this image" };
    return { ok: true, mode: "still-motion", created };
  }
  if (project.cursorDataURL === null || project.cursorDataURL === undefined) {
    return {
      ok: false,
      error:
        "project has no recorded cursor data to generate zooms from — place zooms by hand with add_effect",
    };
  }
  const created = applyAutoZoom(project, inputs, zoomLevel, makeId);
  if (!(created > 0)) {
    return {
      ok: false,
      error:
        "no zoom-worthy activity found in the recorded cursor data " +
        "(auto_zoom needs 2+ clicks close together, a typing burst or a dwell)",
    };
  }
  return { ok: true, mode: "auto-zoom", created };
}

// MARK: - Sidecar decoding (Swift JSONDecoder semantics)

/** Thrown where Swift's `JSONDecoder` would throw a DecodingError. */
export class RecordingDecodeError extends Error {
  override name = "RecordingDecodeError";
}

type Obj = Record<string, unknown>;

function isObject(v: unknown): v is Obj {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Double / CGFloat: any JSON number (JSONDecoder rejects strings, null). */
function dDouble(v: unknown, path: string): number {
  if (typeof v !== "number") throw new RecordingDecodeError(`${path}: expected a number`);
  return v;
}

/** Int: a JSON number with an exact Int64 value. */
function dInt(v: unknown, path: string): number {
  if (typeof v !== "number" || !Number.isInteger(v) || Math.abs(v) > 2 ** 63) {
    throw new RecordingDecodeError(`${path}: expected an integer`);
  }
  return v;
}

/** Bool: JSON true/false only (JSONDecoder never coerces 0/1). */
function dBool(v: unknown, path: string): boolean {
  if (typeof v !== "boolean") throw new RecordingDecodeError(`${path}: expected a bool`);
  return v;
}

function dKey(o: Obj, key: string, path: string): unknown {
  if (!(key in o) || o[key] === null || o[key] === undefined) {
    throw new RecordingDecodeError(`${path}.${key}: missing`);
  }
  return o[key];
}

/** `CursorEvent` (synthesized Codable: timestamp, x, y, isClick — all required). */
function decodeCursorEvent(v: unknown, path: string): CursorEvent {
  if (!isObject(v)) throw new RecordingDecodeError(`${path}: expected an object`);
  return {
    timestamp: dDouble(dKey(v, "timestamp", path), `${path}.timestamp`),
    x: dDouble(dKey(v, "x", path), `${path}.x`),
    y: dDouble(dKey(v, "y", path), `${path}.y`),
    isClick: dBool(dKey(v, "isClick", path), `${path}.isClick`),
  };
}

function decodeCursorEvents(v: unknown, path: string): CursorEvent[] {
  if (!Array.isArray(v)) throw new RecordingDecodeError(`${path}: expected an array`);
  return v.map((e, i) => decodeCursorEvent(e, `${path}[${i}]`));
}

/**
 * `CursorTracker.load(from:)` on already-parsed cursor.json: a
 * `CursorRecording` {version, coordinateWidth, coordinateHeight, events}, or
 * — the legacy format — a bare `[CursorEvent]` array. Throws
 * `RecordingDecodeError` where Swift throws (use `tryParseCursorFile` for
 * the `try?` the applier uses).
 */
export function parseCursorFile(json: unknown): CursorEvent[] {
  try {
    if (!isObject(json)) throw new RecordingDecodeError("cursor.json: expected a CursorRecording object");
    dInt(dKey(json, "version", "cursor"), "cursor.version");
    dDouble(dKey(json, "coordinateWidth", "cursor"), "cursor.coordinateWidth");
    dDouble(dKey(json, "coordinateHeight", "cursor"), "cursor.coordinateHeight");
    return decodeCursorEvents(dKey(json, "events", "cursor"), "cursor.events");
  } catch (error) {
    // Legacy: a bare event array.
    if (Array.isArray(json)) {
      try {
        return decodeCursorEvents(json, "cursor");
      } catch {
        /* fall through to the original error, like the Swift */
      }
    }
    throw error;
  }
}

/** `try? CursorTracker.load(from:)` — null instead of throwing. */
export function tryParseCursorFile(json: unknown): CursorEvent[] | null {
  try {
    return parseCursorFile(json);
  } catch {
    return null;
  }
}

const KEYSTROKE_CATEGORIES = new Set<string>(Object.values(KeystrokeCategory));

/** Optional String (synthesized `decodeIfPresent`: absent or null → nil). */
function dOptString(o: Obj, key: string, path: string): string | undefined {
  const v = o[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") throw new RecordingDecodeError(`${path}.${key}: expected a string`);
  return v;
}

function decodeKeystrokeEvent(v: unknown, path: string): KeystrokeEvent {
  if (!isObject(v)) throw new RecordingDecodeError(`${path}: expected an object`);
  const timestamp = dDouble(dKey(v, "timestamp", path), `${path}.timestamp`);
  const category = dKey(v, "category", path);
  if (typeof category !== "string" || !KEYSTROKE_CATEGORIES.has(category)) {
    throw new RecordingDecodeError(`${path}.category: unknown keystroke category`);
  }
  const event: KeystrokeEvent = { timestamp, category: category as KeystrokeCategory };
  const shortcut = dOptString(v, "shortcut", path);
  if (shortcut !== undefined) event.shortcut = shortcut;
  const frontmostBundleID = dOptString(v, "frontmostBundleID", path);
  if (frontmostBundleID !== undefined) event.frontmostBundleID = frontmostBundleID;
  return event;
}

/**
 * `KeystrokeTracker.loadRecording(from:).events` on already-parsed keys.json
 * (`KeystrokeRecording` {version, events}). Strict like JSONDecoder: an
 * unknown category anywhere fails the WHOLE file. Throws
 * `RecordingDecodeError`; `tryParseKeystrokeFile` gives the applier's `?? []`.
 */
export function parseKeystrokeFile(json: unknown): KeystrokeEvent[] {
  if (!isObject(json)) throw new RecordingDecodeError("keys.json: expected a KeystrokeRecording object");
  dInt(dKey(json, "version", "keys"), "keys.version");
  const events = dKey(json, "events", "keys");
  if (!Array.isArray(events)) throw new RecordingDecodeError("keys.events: expected an array");
  return events.map((e, i) => decodeKeystrokeEvent(e, `keys.events[${i}]`));
}

/** `(try? KeystrokeTracker.loadRecording(from:).events) ?? []`. */
export function tryParseKeystrokeFile(json: unknown): KeystrokeEvent[] {
  try {
    return parseKeystrokeFile(json);
  } catch {
    return [];
  }
}
