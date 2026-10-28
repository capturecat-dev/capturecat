/**
 * The recorded interaction data Auto Zoom and describe_project read, built
 * from the sidecars' parsed JSON — cursor.json and keys.json — plus the
 * recording's AVAssetTrack.naturalSize. Same decode rules as
 * AutoZoomApplier: an unreadable cursor file = no cursor data; keys only
 * when the project references a keystroke file.
 *
 * Pure (no fetch): the web editor loads the files through the project's
 * media URLs (state/interactionInputs.ts); the API's remote MCP editing
 * tools read the same files from R2 (apps/api/src/lib/project-edits.ts).
 */
import { tryParseCursorFile, tryParseKeystrokeFile, type AutoZoomInputs } from "./autoZoom";

export interface InteractionInputs extends AutoZoomInputs {
  /** cursor.json `coordinateWidth/Height` (describe_project screen size); null for the legacy bare array. */
  cursorCoordinateSize: { width: number; height: number } | null;
}

function coordinateSize(json: unknown): { width: number; height: number } | null {
  if (!json || typeof json !== "object" || Array.isArray(json)) return null;
  const o = json as { coordinateWidth?: unknown; coordinateHeight?: unknown };
  return typeof o.coordinateWidth === "number" && typeof o.coordinateHeight === "number" ? { width: o.coordinateWidth, height: o.coordinateHeight } : null;
}

/** The inputs from the sidecars' parsed JSON (null = missing or unreadable). */
export function interactionInputsFrom(
  cursorJSON: unknown | null,
  keysJSON: unknown | null,
  naturalSize: { width: number; height: number } | null,
): InteractionInputs {
  return {
    cursor: cursorJSON == null ? null : tryParseCursorFile(cursorJSON),
    keystrokes: keysJSON == null ? [] : tryParseKeystrokeFile(keysJSON),
    videoNaturalSize: naturalSize,
    cursorCoordinateSize: coordinateSize(cursorJSON),
  };
}
