/**
 * No fork: the remote MCP host (lib/project-edits.ts) produces EXACTLY what
 * the web editor's WebMCP host (apps/web/src/editor/state/webmcpHandlers.ts)
 * produces for the same document and the same calls — same results, same
 * project.json bytes, same change-set. The web side below is written the way
 * webmcpHandlers does it, importing the editor's modules by their own paths
 * (not through lib/editor-core.ts), including Auto Zoom with the natural size
 * the browser's demuxer would report and the sidecars it would fetch.
 */

import { describe, expect, it } from "vitest";
import { MemoryBucket } from "../test-support/memory-bucket";
import { mp4File } from "../test-support/mp4-boxes";
import type { Env } from "../types";
import type { CloudFileRow } from "./cloud-projects-db";
import { loadInteractionInputs, opContextFor, runEditOnDocument, usesAutoZoom } from "./project-edits";

// The web editor's modules, by their own paths.
import * as webOps from "../../../web/src/editor/webmcp/ops";
import { newProject, parseProject, serializeProject, serializeProjectText, type Project } from "../../../web/src/editor/core/model";
import { applyAutoZoom, applyStillMotion } from "../../../web/src/editor/core/edit/autoZoom";
import { interactionInputsFrom } from "../../../web/src/editor/core/edit/interactionInputs";
import { diff, encodeChangeHeader } from "../../../web/src/editor/core/merge/projectDiff";

const PID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const MAC_DIR = `file:///Users/test/Library/Containers/so.capturecat.CaptureCat/Data/Library/Application%20Support/CaptureCat/Projects/${PID}`;

/** Deterministic ids, one sequence per host run. */
function ids() {
  let n = 0;
  return () => `AAAAAAAA-0000-4000-8000-${String(++n).padStart(12, "0")}`;
}

function documentText(extra: Partial<Project> = {}): string {
  return serializeProjectText({
    ...newProject({
      id: PID,
      name: "Checkout demo",
      duration: 24,
      createdAt: 780000000.5,
      videoURL: `${MAC_DIR}/recording.mov`,
      cursorDataURL: `${MAC_DIR}/cursor.json`,
    }),
    ...extra,
  });
}

/** The web editor's `mutate` (webmcpHandlers.ts), minus the store. */
function webMutate(text: string, tool: string, args: webOps.JSONObject, ctx: webOps.OpContext) {
  const loaded = parseProject(JSON.parse(text)); // the store's project
  const draft = parseProject(serializeProject(loaded)); // asLoaded(draft)
  const result = tool === "apply_edits" ? webOps.applyEditsBatch(draft, args.ops, ctx) : webOps.editCore(tool)!(draft, args, ctx);
  const saved = serializeProjectText(draft); // store.documentText
  return { result, text: saved, change: encodeChangeHeader(diff(JSON.parse(text), JSON.parse(saved))) };
}

function webContext(newId: () => string, inputs: ReturnType<typeof interactionInputsFrom> | null): webOps.OpContext {
  return {
    newId,
    autoZoom: (p, zoomLevel) => (inputs ? applyAutoZoom(p, inputs, zoomLevel, newId) : 0),
    stillMotion: (p) => applyStillMotion(p, newId),
  };
}

const BATCH: webOps.JSONObject = {
  ops: [
    { op: "set_trim", args: { start: 1, end: 22 } },
    { op: "add_effect", args: { type: "zoomtilt", start: 2, end: 6, zoomLevel: 1.8, focalX: 0.3, focalY: 0.4, pitch: 8 } },
    { op: "add_effect", args: { type: "zoom", start: 9, end: 12.5, zoomLevel: 2.2, focalX: 0.95, focalY: 0.1 } },
    { op: "add_annotation", args: { type: "text", start: 3, end: 6, x: 0.5, y: 0.2, text: "Pick a plan" } },
    { op: "add_blur", args: { start: 0, end: 24, x: 0.7, y: 0.05, width: 0.25, height: 0.06, style: "Pixelate" } },
    { op: "set_speed", args: { start: 14, end: 18, speed: 3 } },
    { op: "cut_video", args: { ranges: [{ start: 19, end: 20 }] } },
    { op: "set_style", args: { patch: { backgroundPadding: 72, aspectRatio: "9:16", cursorScale: 1.4 } } },
    { op: "update_effect", args: { at: 10, zoomLevel: 1.9 } },
  ],
};

describe("remote host == web editor host", () => {
  it("apply_edits: same results, same project.json bytes, same change-set", () => {
    const text = documentText();
    const api = runEditOnDocument(text, "apply_edits", BATCH, opContextFor(null, ids()));
    const web = webMutate(text, "apply_edits", BATCH, webContext(ids(), null));
    expect(webOps.resultJSON(api.result)).toBe(webOps.resultJSON(web.result));
    expect(api.text).toBe(web.text);
    expect(api.change).toBe(web.change);
    expect(api.change).not.toBeNull();
    // And it did edit: the batch is visible in the describe payload.
    const described = webOps.describeProject(api.project, { cursor: null, screenSize: null, keystrokes: [], silence: null });
    expect((described.effects as { zoomRegions: unknown[] }).zoomRegions).toHaveLength(2);
    expect(described.speedRegions).toHaveLength(1);
  });

  it("every single op and set_style: same result or the same Mac error text", () => {
    const text = documentText();
    const calls: Array<[string, webOps.JSONObject]> = [
      ["set_style", { patch: { backgroundType: "Gradient", gradientStartColor: "#112233" } }],
      ["set_style", { patch: { backgroundPading: 10 } }], // typo → suggestion error
      ["add_effect", { type: "zoom", start: 5, end: 4 }], // inverted span
      ["remove_effect", { at: 3 }], // nothing there
      ["set_speed", { start: 1, end: 1.2, speed: 2 }], // too short
      ["add_annotation", { type: "arrow", start: 1, end: 3, x: 0.2, y: 0.2, arrowEndX: 0.6, arrowEndY: 0.5 }],
    ];
    for (const [tool, args] of calls) {
      const outcome = (fn: () => { result: webOps.JSONObject; text: string }) => {
        try {
          const r = fn();
          return { ok: webOps.resultJSON(r.result), text: r.text };
        } catch (error) {
          return { error: webOps.errorMessage(error) };
        }
      };
      const api = outcome(() => runEditOnDocument(text, tool, args, opContextFor(null, ids())));
      const web = outcome(() => webMutate(text, tool, args, webContext(ids(), null)));
      expect(api, `${tool} ${JSON.stringify(args)}`).toEqual(web);
    }
  });

  it("an apply_edits batch with a bad op throws the op layer's message and writes nothing", () => {
    const text = documentText();
    const bad = { ops: [{ op: "add_effect", args: { type: "zoom", start: 2, end: 4 } }, { op: "add_effect", args: { type: "zoom", start: 3, end: 5 } }] };
    expect(() => runEditOnDocument(text, "apply_edits", bad, opContextFor(null, ids()))).toThrow(/ops\[1\] \(add_effect\) failed/);
    let webError = "";
    try {
      webMutate(text, "apply_edits", bad, webContext(ids(), null));
    } catch (error) {
      webError = webOps.errorMessage(error);
    }
    expect(() => runEditOnDocument(text, "apply_edits", bad, opContextFor(null, ids()))).toThrow(webError);
  });

  it("auto_zoom: the sidecars and recording size read from R2 equal what the browser would load", async () => {
    // A cursor recording with three click bursts, a keys file, and a
    // recording whose natural size is Retina-odd (so the 3840×2160 fallback
    // would give different regions).
    const events: Array<{ timestamp: number; x: number; y: number; isClick: boolean }> = [];
    for (let i = 0; i <= 24 * 30; i++) {
      const t = i / 30;
      const target = t < 6 ? [300, 260] : t < 13 ? [1180, 640] : [420, 820];
      const presses = [[2, 2.06], [2.8, 2.86], [8, 8.06], [8.9, 8.96], [15, 15.06], [15.7, 15.76]];
      events.push({ timestamp: t, x: target[0] + Math.sin(t) * 3, y: target[1], isClick: presses.some(([a, b]) => t >= a && t < b) });
    }
    const cursorJSON = { version: 1, coordinateWidth: 1470, coordinateHeight: 956, events };
    const keysJSON = { version: 1, events: [{ timestamp: 9, category: "shortcut", display: "⌘S" }] };
    const natural = { width: 2940, height: 1912 };

    const bucket = new MemoryBucket();
    const env = { R2: bucket } as unknown as Env;
    const put = (path: string, bytes: Uint8Array): CloudFileRow => {
      const r2Key = `cloud-projects/u/${PID}/objects/${path}`;
      void bucket.put(r2Key, bytes);
      return { path, sha256: path, bytes: bytes.byteLength, contentType: "application/octet-stream", r2Key, source: null, uploadedAt: "" };
    };
    const files = [
      put("recording.mov", mp4File({ tracks: [{ kind: "audio" }, { kind: "video", ...natural }], mdatBytes: 4096 })),
      put("cursor.json", new TextEncoder().encode(JSON.stringify(cursorJSON))),
      put("keys.json", new TextEncoder().encode(JSON.stringify(keysJSON))),
    ];
    const text = documentText({ keystrokeDataURL: `${MAC_DIR}/keys.json` });
    const args = { ops: [{ op: "auto_zoom", args: { zoomLevel: 1.6 } }] };
    expect(usesAutoZoom("apply_edits", args)).toBe(true);

    const inputs = await loadInteractionInputs(env, parseProject(JSON.parse(text)), files, true);
    expect(inputs.videoNaturalSize).toEqual(natural);
    const api = runEditOnDocument(text, "apply_edits", args, opContextFor(inputs, ids()));
    const web = webMutate(text, "apply_edits", args, webContext(ids(), interactionInputsFrom(cursorJSON, keysJSON, natural)));
    expect(api.text).toBe(web.text);
    expect(webOps.resultJSON(api.result)).toBe(webOps.resultJSON(web.result));
    expect(api.project.zoomRegions.length).toBeGreaterThan(0);

    // The size matters: the fallback screen size produces a different edit.
    const fallback = webMutate(text, "apply_edits", args, webContext(ids(), interactionInputsFrom(cursorJSON, keysJSON, null)));
    expect(fallback.text).not.toBe(api.text);
  });
});
