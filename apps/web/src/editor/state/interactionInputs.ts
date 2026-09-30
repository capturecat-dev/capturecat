/**
 * The recorded interaction data Auto Zoom and describe_project read —
 * cursor.json + keys.json fetched through the project's media URLs, and the
 * video's AVAssetTrack.naturalSize (engine LoadedInfo.naturalSize). Same
 * decode rules as AutoZoomApplier: an unreadable cursor file = no cursor data;
 * keys only when the project references a keystroke file.
 */
import { tryParseCursorFile, tryParseKeystrokeFile, type AutoZoomInputs } from "../core/edit/autoZoom";
import type { Project } from "../core/model";

export interface InteractionSources {
  mediaUrl(ref: string | null | undefined): string | undefined;
  naturalSize: { width: number; height: number } | null;
}

async function fetchJSON(url: string | undefined): Promise<unknown | null> {
  if (!url) return null;
  try {
    const res = await fetch(url, { cache: "force-cache" });
    return res.ok ? ((await res.json()) as unknown) : null;
  } catch {
    return null;
  }
}

export interface InteractionInputs extends AutoZoomInputs {
  /** cursor.json `coordinateWidth/Height` (describe_project screen size); null for the legacy bare array. */
  cursorCoordinateSize: { width: number; height: number } | null;
}

function coordinateSize(json: unknown): { width: number; height: number } | null {
  if (!json || typeof json !== "object" || Array.isArray(json)) return null;
  const o = json as { coordinateWidth?: unknown; coordinateHeight?: unknown };
  return typeof o.coordinateWidth === "number" && typeof o.coordinateHeight === "number" ? { width: o.coordinateWidth, height: o.coordinateHeight } : null;
}

const cache = new Map<string, Promise<InteractionInputs>>();

/** Cached per (cursor ref, keys ref, natural size) — sidecars never change. */
export function loadInteractionInputs(project: Project, sources: InteractionSources): Promise<InteractionInputs> {
  const key = `${project.cursorDataURL}|${project.keystrokeDataURL ?? ""}|${sources.naturalSize?.width}x${sources.naturalSize?.height}`;
  let hit = cache.get(key);
  if (!hit) {
    hit = (async () => {
      const cursorJSON = project.cursorDataURL ? await fetchJSON(sources.mediaUrl(project.cursorDataURL)) : null;
      const keysJSON = project.keystrokeDataURL ? await fetchJSON(sources.mediaUrl(project.keystrokeDataURL)) : null;
      return {
        cursor: cursorJSON == null ? null : tryParseCursorFile(cursorJSON),
        keystrokes: keysJSON == null ? [] : tryParseKeystrokeFile(keysJSON),
        videoNaturalSize: sources.naturalSize,
        cursorCoordinateSize: coordinateSize(cursorJSON),
      };
    })();
    cache.set(key, hit);
  }
  return hit;
}
