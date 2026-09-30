/**
 * Recording facts the inspector gates on that project.json alone can't tell
 * — read from the take's sidecars, exactly like `InspectorColumnAppKit`:
 *
 *   cursorPane.hasShortcutData = project.keystrokeDataURL
 *       .flatMap { try? KeystrokeTracker.loadRecording(from: $0).events }?
 *       .contains { $0.shortcut != nil } ?? false
 *
 * (strict decode: an unreadable or malformed keys.json = no shortcut data).
 */
import { tryParseKeystrokeFile } from "../core/edit/autoZoom";
import type { Project } from "../core/model";

/** `events.contains { $0.shortcut != nil }` */
export function hasShortcutEvents(events: ReadonlyArray<{ shortcut?: string | null }>): boolean {
  return events.some((e) => e.shortcut != null);
}

/** keys.json (already parsed JSON) → does the take carry recorded shortcuts? */
export function keystrokeFileHasShortcuts(json: unknown): boolean {
  return json != null && hasShortcutEvents(tryParseKeystrokeFile(json));
}

const cache = new Map<string, Promise<boolean>>();

/**
 * `hasShortcutData` for the project's keystroke sidecar, fetched through the
 * project's media URLs. Cached per sidecar URL (recordings never change);
 * false when the project has no keystroke file or it can't be read.
 */
export function loadHasShortcutData(
  project: Pick<Project, "keystrokeDataURL">,
  mediaUrl: (ref: string | null | undefined) => string | undefined,
): Promise<boolean> {
  const ref = project.keystrokeDataURL;
  const url = ref ? mediaUrl(ref) : undefined;
  if (!url) return Promise.resolve(false);
  let hit = cache.get(url);
  if (!hit) {
    hit = fetch(url, { cache: "force-cache" })
      .then((res) => (res.ok ? (res.json() as Promise<unknown>) : null))
      .then(keystrokeFileHasShortcuts, () => false);
    cache.set(url, hit);
  }
  return hit;
}
