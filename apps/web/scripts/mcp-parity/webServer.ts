/**
 * The WEB side of the MCP parity runner: the Mac server's tool dispatch
 * (MCPServer.callTool / runSingleEdit / applyEdits / undo) re-created over
 * the pure TS cores in src/editor/webmcp/ops, with the Mac's disk semantics
 * emulated in memory:
 *
 *  - every call LOADS the project by decoding the stored project.json
 *    (`parseProject`) — the Mac re-decodes the file on each tool call, so
 *    decode-time normalisations (autoHideCursor/smoothCursor forced false,
 *    showCamera ⇔ camera file) apply between calls exactly as on the Mac;
 *  - a successful mutating call ENCODES the draft (`serializeProject`) and
 *    pushes the previous JSON onto a 30-deep undo history.
 *
 * Bundled by run.mjs with esbuild; the OpContext (ids, auto-zoom) and the
 * describe inputs are injected by the driver.
 */
import { parseProject, serializeProject, type Project } from "../../src/editor/core/model";
import type { CursorEvent, KeystrokeEvent, Size } from "../../src/editor/core/model/types";
import {
  HISTORY_LIMIT,
  analyzeSilence,
  applyEditsBatch,
  commitExtras,
  describeProject,
  editCore,
  editSummary,
  errorMessage,
  getTranscript,
  historySummary,
  isoTimestamp,
  parseRenderFramesArgs,
  planUndo,
  resultJSON,
  styleOptions,
  undoResult,
  type HistoryEntry,
  type JSONObject,
  type OpContext,
  type SilenceOutcome,
} from "../../src/editor/webmcp/ops";

export { analyzeSilence, parseProject, serializeProject };

export interface WebHost {
  newId(): string;
  /** Auto Zoom for the CURRENT project (null = port unavailable → skip). */
  autoZoom: ((project: Project, zoomLevel: number | null, newId: () => string) => number) | null;
  stillMotion: ((project: Project, newId: () => string) => number) | null;
  /** cursor.json the Mac's describe would read (projectDir/cursor.json first). */
  readCursor(project: Project): { events: CursorEvent[]; size: Size | null } | null;
  /** keys.json events from `project.keystrokeDataURL` ([] when none). */
  readKeystrokes(project: Project): KeystrokeEvent[];
  /** Silence outcome for `project.videoURL` (null = file missing). */
  silence(project: Project): SilenceOutcome | null;
}

export class SkipError extends Error {}

interface Snapshot {
  entry: HistoryEntry;
  json: Record<string, unknown>;
}

export class WebServer {
  private json: Record<string, unknown>;
  private history: Snapshot[] = []; // newest first
  /** Set when an op needed a host port that is unavailable (the batch
   * runner wraps every throw, so the reason travels out of band). */
  private skipReason: string | null = null;

  constructor(
    initialJSON: Record<string, unknown>,
    private readonly host: WebHost,
  ) {
    this.json = structuredClone(initialJSON);
  }

  /** The current project.json object (as the web would write it). */
  projectJSON(): Record<string, unknown> {
    return structuredClone(this.json);
  }

  private load(): Project {
    return parseProject(structuredClone(this.json));
  }

  private ctx(): OpContext {
    const host = this.host;
    return {
      newId: () => host.newId(),
      autoZoom: (project, zoomLevel) => {
        if (!host.autoZoom) throw new SkipError((this.skipReason = "auto_zoom port unavailable"));
        return host.autoZoom(project, zoomLevel, () => host.newId());
      },
      stillMotion: (project) => {
        if (!host.stillMotion) throw new SkipError((this.skipReason = "still-motion port unavailable"));
        return host.stillMotion(project, () => host.newId());
      },
    };
  }

  private commit(project: Project, tool: string, summary: string): JSONObject {
    const next = serializeProject(project);
    this.history.unshift({
      entry: { tool, summary: historySummary(summary), at: isoTimestamp() },
      json: this.json,
    });
    const depth = this.history.length;
    this.history = this.history.slice(0, HISTORY_LIMIT);
    this.json = next;
    return commitExtras(depth);
  }

  private undo(args: JSONObject): JSONObject {
    const entries = this.history.map((h) => h.entry);
    const steps = planUndo(args, entries, false);
    const target = this.history[steps - 1].json;
    const restored = parseProject(structuredClone(target));
    let before: Project | null = null;
    try {
      before = this.load();
    } catch {
      before = null;
    }
    const undone = entries.slice(0, steps);
    this.json = structuredClone(target);
    this.history = this.history.slice(steps);
    return undoResult(undone, entries.length - steps, restored, before);
  }

  private dispatch(name: string, args: JSONObject): JSONObject {
    switch (name) {
      case "describe_project": {
        const project = this.load();
        const cursor = this.host.readCursor(project);
        return describeProject(project, {
          cursor: cursor?.events ?? null,
          screenSize: cursor?.size ?? null,
          keystrokes: this.host.readKeystrokes(project),
          silence: this.host.silence(project),
        });
      }
      case "get_transcript":
        return getTranscript(this.load());
      case "style_options": {
        const project = typeof args.id === "string" && args.id !== "" ? this.load() : null;
        return styleOptions(project, args.group);
      }
      case "apply_edits": {
        const project = this.load();
        const result = applyEditsBatch(project, args.ops, this.ctx());
        return { ...result, ...this.commit(project, "apply_edits", editSummary("apply_edits", result)) };
      }
      case "undo":
        return this.undo(args);
      case "render_frames":
        // Only the argument validation is comparable (it runs before any
        // rendering on the Mac); a valid request would render pixels.
        parseRenderFramesArgs(args);
        this.skipReason = "render_frames: valid request (pixels are not compared)";
        throw new SkipError(this.skipReason);
      default: {
        const core = editCore(name);
        if (!core) throw new Error(`unknown tool: ${name}`);
        const project = this.load();
        const result = core(project, args, this.ctx());
        return { ...result, ...this.commit(project, name, name) };
      }
    }
  }

  /** tools/call → { isError, text } (text = resultJSON or "ERROR: …"). */
  call(name: string, args: JSONObject): { isError: boolean; text: string; skipped?: string } {
    this.skipReason = null;
    const before = this.json;
    const beforeHistory = this.history;
    try {
      const text = resultJSON(this.dispatch(name, args));
      return { isError: false, text };
    } catch (error) {
      if (this.skipReason !== null) {
        this.json = before;
        this.history = beforeHistory;
        return { isError: true, text: "", skipped: this.skipReason };
      }
      return { isError: true, text: `ERROR: ${errorMessage(error)}` };
    }
  }
}
