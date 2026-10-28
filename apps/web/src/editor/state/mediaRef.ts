/**
 * project.json media reference → the cloud file that holds it. Pure (no
 * fetch, no DOM, no path aliases): the web editor (state/cloud.ts) and the
 * API's remote MCP editing tools (apps/api/src/lib/editor-core.ts) resolve
 * cursor.json, keys.json and the recording with this one function.
 */

export interface MediaRefIndex<F> {
  /** Keyed by logical path (relative to the Mac project folder). */
  media: Record<string, F>;
  /** `source` reference → logical path. */
  sources: Record<string, string>;
}

/** Files (logical `path` + optional Mac `source` reference) → the lookup maps. */
export function mediaRefIndex<F extends { path: string; source: string | null }>(files: readonly F[]): MediaRefIndex<F> {
  const media: Record<string, F> = {};
  const sources: Record<string, string> = {};
  for (const f of files) {
    media[f.path] = f;
    if (f.source) sources[f.source] = f.path;
  }
  return { media, sources };
}

/**
 * Resolve a reference as project.json spells it — a `file://` URL
 * (videoURL/cursorDataURL/keystrokeDataURL/cameraVideoURL), an absolute path
 * (backgroundImagePath), or a bare file name relative to the project folder
 * (voice-over `fileName`, watermark/curtain logo names) — to its media file.
 *
 * Order: the exact `source` the Mac recorded → the logical path itself → the
 * project-relative tail of a Mac path (`…/Projects/<id>/<name>`) → the last
 * path component. Never guesses beyond that; undefined means not uploaded.
 */
export function resolveMediaRef<F>(urls: MediaRefIndex<F>, ref: string | null | undefined): F | undefined {
  if (!ref) return undefined;
  const bySource = urls.sources[ref];
  if (bySource) return urls.media[bySource];
  if (urls.media[ref]) return urls.media[ref];

  let path = ref;
  if (path.startsWith("file://")) {
    try {
      path = decodeURIComponent(new URL(path).pathname);
    } catch {
      return undefined;
    }
  }
  const decodedSource = urls.sources[path];
  if (decodedSource) return urls.media[decodedSource];

  const marker = "/CaptureCat/Projects/";
  const at = path.indexOf(marker);
  if (at >= 0) {
    // …/Projects/<UUID>/<relative path>
    const rest = path.slice(at + marker.length).split("/").slice(1).join("/");
    // `sources` first: an image the Mac CONVERTED for browsers (HEIC → PNG)
    // uploads as `<name>.png` and records its original relative path there.
    const restViaSource = rest ? urls.sources[rest] : undefined;
    if (restViaSource) return urls.media[restViaSource];
    if (rest && urls.media[rest]) return urls.media[rest];
  }
  const last = path.split("/").pop();
  if (!last) return undefined;
  const lastViaSource = urls.sources[last];
  return lastViaSource ? urls.media[lastViaSource] : urls.media[last];
}
