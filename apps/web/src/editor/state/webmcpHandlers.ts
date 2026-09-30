/**
 * WebMCP handlers for the open project — the browser twin of the Mac MCP
 * server (MCPServer*.swift), bound to the editor store.
 *
 * The tool CORES are the Mac's, ported in webmcp/ops and proved against the
 * real server (scripts/mcp-parity: 419 calls, 0 diffs). This module is the
 * host the Mac's `runSingleEdit` / `applyEdits` / `undo` / `commitEdit` are:
 *   - every call runs on the project as the Mac would LOAD it
 *     (parse(serialize(current)) — decode normalisations included), on a
 *     deep draft; a throw discards the draft (all-or-nothing);
 *   - a successful write is ONE store undo step tagged as MCP history
 *     ({tool, summary, at}); results carry `undoSteps` like commitEdit;
 *   - `undo` walks the MCP entries of the store history with the Mac's rules
 *     ("changed outside MCP" = the user edited after the last MCP write);
 *   - render_frames grabs the engine's frames (preview == export passes).
 * `id` is optional on the web and must name the project open in this tab.
 */
import { applyAutoZoom, applyStillMotion } from "../core/edit/autoZoom";
import { newUUID, parseProject, serializeProject, type Project } from "../core/model";
import { SpeedTimeMap } from "../core/time/speedTimeMap";
import { registerEditorTools, type ToolArgs, type ToolHandlers } from "../webmcp/register";
import * as ops from "../webmcp/ops";
import type { EditorController } from "./controller";
import { loadInteractionInputs, type InteractionInputs } from "./interactionInputs";
import { listEditorProjects, type LoadedEditorProject } from "./projectSource";
import { recordingSilence } from "./silence";
import type { EditorStore, UndoEntry } from "./store";
import { renderFrames } from "./webmcpRender";

export interface WebMCPContext {
  store: EditorStore;
  controller: EditorController;
  loaded: LoadedEditorProject;
  projectId: string;
}

/** The project as the Mac's `loadProject` would decode it from disk. */
function asLoaded(p: Project): Project {
  return parseProject(serializeProject(p));
}

export function buildEditorToolHandlers(ctx: WebMCPContext): ToolHandlers {
  const { store, controller, loaded } = ctx;

  const openProject = (args: ToolArgs): Project => {
    const project = store.getState().project;
    if (!project) throw new ops.ToolError("the project is still loading — retry in a moment");
    const id = args.id;
    if (typeof id === "string" && id !== "" && id.toUpperCase() !== project.id.toUpperCase() && id.toUpperCase() !== ctx.projectId.toUpperCase()) {
      throw new ops.ToolError(
        `the web editor works on the project open in this tab (${project.id}) — open ${id} in the editor to work on it, or omit id`,
      );
    }
    return project;
  };

  const inputsFor = async (project: Project): Promise<InteractionInputs> => {
    const info = controller.client?.info;
    if (project.videoURL !== null && !info) throw new ops.ToolError("the editor is still loading the recording — retry in a moment");
    return loadInteractionInputs(project, { mediaUrl: loaded.mediaUrl, naturalSize: info?.naturalSize ?? null });
  };

  const opContext = async (project: Project, needsInputs: boolean): Promise<ops.OpContext> => {
    const inputs = needsInputs ? await inputsFor(project) : null;
    return {
      newId: newUUID,
      autoZoom: (p, zoomLevel) => (inputs ? applyAutoZoom(p, inputs, zoomLevel, newUUID) : 0),
      stillMotion: (p) => applyStillMotion(p, newUUID),
    };
  };

  /** Newest-first MCP history (capped like the Mac's `.mcp-history`). */
  const mcpHistory = (): UndoEntry[] =>
    store
      .history()
      .filter((e) => e.source === "mcp" && e.mcp)
      .reverse()
      .slice(0, ops.HISTORY_LIMIT);

  /** runSingleEdit / applyEdits → commitEdit. */
  const mutate = async (tool: string, args: ToolArgs, run: (draft: Project, c: ops.OpContext) => ops.JSONObject): Promise<string> => {
    const project = openProject(args);
    const usesAutoZoom =
      tool === "auto_zoom" || (tool === "apply_edits" && Array.isArray(args.ops) && args.ops.some((o) => (o as { op?: unknown })?.op === "auto_zoom"));
    const c = await opContext(project, usesAutoZoom);
    let result: ops.JSONObject = {};
    store.transact(
      `Agent: ${tool}`,
      (draft) => {
        const loadedDraft = asLoaded(draft) as unknown as Record<string, unknown>;
        const d = draft as unknown as Record<string, unknown>;
        for (const key of Object.keys(d)) if (!(key in loadedDraft)) delete d[key];
        Object.assign(d, loadedDraft);
        result = run(draft, c);
      },
      {
        source: "mcp",
        forceEntry: true,
        mcp: () => ({ tool, summary: ops.historySummary(ops.editSummary(tool, result)), at: ops.isoTimestamp() }),
      },
    );
    // `result.merge(extras) { current, _ in current }` — the op's keys win.
    return ops.resultJSON({ ...ops.commitExtras(mcpHistory().length), ...result });
  };

  const handlers: ToolHandlers = {
    list_projects: async () => {
      const projects = await listEditorProjects();
      return ops.resultJSON({
        projects: projects.map((p) => ({ id: p.id.toUpperCase(), name: p.name, duration: ops.round3(p.duration), updatedAt: p.updatedAt, origin: p.origin })),
      });
    },

    describe_project: async (args) => {
      const project = asLoaded(openProject(args));
      const inputs = await inputsFor(project);
      const videoUrl = loaded.mediaUrl(project.videoURL);
      const silence = videoUrl ? await recordingSilence(videoUrl) : null;
      return ops.resultJSON(
        ops.describeProject(project, { cursor: inputs.cursor, screenSize: inputs.cursorCoordinateSize, keystrokes: inputs.keystrokes, silence }),
      );
    },

    get_transcript: async (args) => ops.resultJSON(ops.getTranscript(asLoaded(openProject(args)))),

    style_options: async (args) => ops.resultJSON(ops.styleOptions(asLoaded(openProject(args)), args.group)),

    render_frames: async (args) => {
      const request = ops.parseRenderFramesArgs(args);
      const project = asLoaded(openProject(args));
      const client = controller.client;
      if (!client?.info) throw new ops.ToolError("the editor is still loading the recording — retry in a moment");
      const duration = client.transport?.duration ?? client.info.outputDuration;
      const map = SpeedTimeMap.trimmedOutputOf(project);
      return renderFrames(client, request, duration, (t) => map.sourceTime(t));
    },

    apply_edits: (args) => mutate("apply_edits", args, (d, c) => ops.applyEditsBatch(d, args.ops, c)),

    undo: async (args) => {
      const project = openProject(args);
      const history = mcpHistory();
      const all = store.history();
      const top = all[all.length - 1];
      // The Mac compares the file with the hash recorded at the last MCP write.
      const changedOutside = history.length > 0 && (top !== history[0] || store.getState().project !== history[0].after);
      const steps = ops.planUndo(args, history.map((e) => e.mcp!), changedOutside);
      const target = history[steps - 1];
      for (;;) {
        const undone = store.undo();
        if (!undone || undone === target) break;
      }
      const restored = asLoaded(store.getState().project!);
      return ops.resultJSON(ops.undoResult(history.slice(0, steps).map((e) => e.mcp!), history.length - steps, restored, asLoaded(project)));
    },

    export_project: async (args) => {
      const project = openProject(args);
      const client = controller.client;
      if (!client?.info) throw new ops.ToolError("the editor is still loading the recording — retry in a moment");
      // HeadlessRunner exports with the project's own settings — fast export included.
      const result = await client.export({ collapseStaticSpans: project.settings.exportSettings.collapseStaticSpans });
      const filename = `${(project.name || "CaptureCat").replace(/[\\/:*?"<>|]+/g, "-")}.mp4`;
      const url = URL.createObjectURL(new Blob([result.buffer], { type: result.mimeType }));
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
      return ops.resultJSON({
        path: filename,
        downloaded: true,
        bytes: result.buffer.byteLength,
        width: result.width,
        height: result.height,
        fps: result.fps,
        frames: result.frames,
        codec: result.codec,
        note: "The browser saved the mp4 to the user's Downloads (same renderer as the preview).",
      });
    },
  };

  for (const name of ops.EDIT_OP_NAMES) {
    const core = ops.editCore(name);
    if (!core) continue;
    (handlers as Record<string, (args: ToolArgs) => Promise<string>>)[name] = (args) => mutate(name, args, (d, c) => core(d, args, c));
  }
  return handlers;
}

/** Registers the editor's tools; returns the unregister function. */
export function registerEditorWebMCP(ctx: WebMCPContext): () => void {
  return registerEditorTools(buildEditorToolHandlers(ctx));
}
