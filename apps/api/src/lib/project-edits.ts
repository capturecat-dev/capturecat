/**
 * The headless host for the editor's edit ops — what the Mac MCP server's
 * `runSingleEdit` / `applyEdits` and the web editor's WebMCP handlers
 * (apps/web/src/editor/state/webmcpHandlers.ts) are, minus a window:
 *
 *   load      decode the stored project.json like the Mac does on every tool
 *             call (`parseProjectText` — decode-time normalisations included);
 *   run       the shared op core on that draft; a throw writes nothing;
 *   encode    `serializeProjectText`, the bytes the web editor would save;
 *   change    `encodeChangeHeader(diff(before, after))` — the X-CC-Change the
 *             web editor sends, so History says what the agent changed.
 *
 * Every rule (validation, clamps, lanes, error texts, results) is the shared
 * op layer's (lib/editor-core.ts); this file only does the I/O a server has
 * instead of a browser: sidecars and the recording's natural size from R2.
 */

import type { Env } from "../types";
import type { CloudFileRow } from "./cloud-projects-db";
import { readNaturalSize, type NaturalSize } from "./mp4-natural-size";
import {
  applyAutoZoom,
  applyStillMotion,
  encodeChangeHeader,
  interactionInputsFrom,
  mediaRefIndex,
  newUUID,
  ops,
  parseProjectText,
  projectDiff,
  resolveMediaRef,
  serializeProjectText,
  type InteractionInputs,
  type MediaRefIndex,
  type Project,
} from "./editor-core";

export type JSONObject = ops.JSONObject;

/** The project as the Mac's `loadProject` decodes it from disk. Throws on a
 *  document the Mac could not decode either. */
export function loadProject(text: string): Project {
  return parseProjectText(text);
}

/** Whether running `tool` with `args` calls Auto Zoom (the only op that reads
 *  the recording's sidecars) — the web host's `usesAutoZoom`. */
export function usesAutoZoom(tool: string, args: JSONObject): boolean {
  if (tool === "auto_zoom") return true;
  return tool === "apply_edits" && Array.isArray(args.ops) && args.ops.some((o) => (o as { op?: unknown } | null)?.op === "auto_zoom");
}

/** The OpContext every host builds: ids, Auto Zoom over the loaded inputs
 *  (none = 0 regions, as with no cursor data), and the still-image Motion. */
export function opContextFor(inputs: InteractionInputs | null, newId: () => string = newUUID): ops.OpContext {
  return {
    newId,
    autoZoom: (project, zoomLevel) => (inputs ? applyAutoZoom(project, inputs, zoomLevel, newId) : 0),
    stillMotion: (project) => applyStillMotion(project, newId),
  };
}

export interface EditRun {
  /** The edited project (as encoded). */
  project: Project;
  /** The op core's result payload (the Mac's, key for key). */
  result: JSONObject;
  /** project.json to store, exactly as the web editor would save it. */
  text: string;
  bytes: Uint8Array;
  /** X-CC-Change for this save (null = over the header budget, like the web). */
  change: string | null;
}

/**
 * Run one edit tool on a stored document: `apply_edits` (args.ops, one
 * all-or-nothing batch) or a single batchable op by name (`set_style`, …).
 * Throws the op layer's ToolError (the Mac's exact message) when the edit is
 * refused; nothing is written in that case.
 */
export function runEditOnDocument(documentText: string, tool: string, args: JSONObject, ctx: ops.OpContext): EditRun {
  const project = loadProject(documentText);
  let result: JSONObject;
  if (tool === "apply_edits") {
    result = ops.applyEditsBatch(project, args.ops, ctx);
  } else {
    const core = ops.editCore(tool);
    if (!core) throw new ops.ToolError(`unknown edit op: ${tool}`);
    result = core(project, args, ctx);
  }
  const text = serializeProjectText(project);
  const change = encodeChangeHeader(projectDiff(JSON.parse(documentText), JSON.parse(text)));
  return { project, result, text, bytes: new TextEncoder().encode(text), change };
}

// ---------------------------------------------------------------------------
// Sidecars from R2
// ---------------------------------------------------------------------------

/** The recording exists in the cloud copy but its size could not be read. */
export class NaturalSizeUnavailableError extends Error {
  constructor(readonly path: string) {
    super(`could not read the video size of ${path}`);
    this.name = "NaturalSizeUnavailableError";
  }
}

async function readRange(r2: R2Bucket, key: string, offset: number, length: number): Promise<Uint8Array> {
  const object = await r2.get(key, { range: { offset, length } });
  if (!object) throw new Error(`R2 object ${key} is missing`);
  return new Uint8Array(await object.arrayBuffer());
}

/** A JSON sidecar by its project.json reference: null when it is not in the
 *  cloud copy or does not parse (the web's fetchJSON → null). */
async function readJSONRef(env: Env, files: MediaRefIndex<CloudFileRow>, ref: string | null | undefined): Promise<unknown | null> {
  const file = resolveMediaRef(files, ref);
  if (!file) return null;
  try {
    const object = await env.R2.get(file.r2Key);
    return object ? ((await object.json()) as unknown) : null;
  } catch {
    return null;
  }
}

/**
 * The Auto Zoom / describe inputs for `project`, read from its cloud files:
 * cursor.json and keys.json (only when project.json references them), and —
 * when `withNaturalSize` — the recording's natural size. A recording that is
 * not in the cloud copy reads as no size (AutoZoomApplier's fallback, as when
 * the Mac cannot open the file); one that IS there but cannot be parsed
 * throws NaturalSizeUnavailableError rather than silently zooming against
 * the wrong screen size.
 */
export async function loadInteractionInputs(
  env: Env,
  project: Project,
  files: readonly CloudFileRow[],
  withNaturalSize: boolean,
): Promise<InteractionInputs> {
  const index = mediaRefIndex(files);
  const cursorJSON = project.cursorDataURL ? await readJSONRef(env, index, project.cursorDataURL) : null;
  const keysJSON = project.keystrokeDataURL ? await readJSONRef(env, index, project.keystrokeDataURL) : null;
  let natural: NaturalSize | null = null;
  // Only Auto Zoom over a recording with cursor data reads the size.
  if (withNaturalSize && project.videoURL && cursorJSON !== null) {
    const recording = resolveMediaRef(index, project.videoURL);
    if (recording) {
      natural = await readNaturalSize((offset, length) => readRange(env.R2, recording.r2Key, offset, length), recording.bytes);
      if (!natural) throw new NaturalSizeUnavailableError(recording.path);
    }
  }
  return interactionInputsFrom(cursorJSON, keysJSON, natural);
}
