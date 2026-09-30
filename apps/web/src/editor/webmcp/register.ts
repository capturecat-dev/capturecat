/**
 * WebMCP for the web editor — browser agents get the SAME tools as desktop
 * agents.
 *
 * The catalog (names, titles, JSON schemas, annotations, playbook) is not
 * written here: it is generated from the Mac app's MCP server
 * (`CaptureCat --mcp-catalog-json`, see scripts/sync-mcp-catalog.sh), so a
 * tool can never mean one thing on the desktop and another in the browser.
 * This module only adapts it to the browser:
 *
 *  - registers through `document.modelContext.registerTool` (the July-2026
 *    spec location; `navigator.modelContext` is the deprecated spelling and
 *    is used only as a fallback);
 *  - keeps the tools that make sense in a page (recording, on-device
 *    transcription and local-library tools stay desktop-only);
 *  - makes `id` optional — in the editor it defaults to the open project;
 *  - maps MCP annotations onto WebMCP's (`readOnlyHint`, and
 *    `consequentialHint` for anything destructive);
 *  - exposes the desktop server's `instructions` playbook as a read-only
 *    `get_editing_playbook` tool (WebMCP has no instructions channel).
 *
 * Handlers are injected by the editor store; a tool whose handler is missing
 * is not registered (never a stub that silently does nothing).
 */
import catalog from "./catalog.generated.json";

export type ToolArgs = Record<string, unknown>;
export type ToolHandler = (args: ToolArgs, signal: AbortSignal) => Promise<unknown>;
export type ToolHandlers = Partial<Record<WebToolName, ToolHandler>>;

interface CatalogTool {
  name: string;
  title?: string;
  description: string;
  inputSchema: { type: "object"; properties?: Record<string, unknown>; required?: string[] };
  annotations?: {
    readOnlyHint?: boolean;
    destructiveHint?: boolean;
    idempotentHint?: boolean;
    openWorldHint?: boolean;
  };
}

/** Tools the browser editor serves. Everything else stays desktop-only. */
export const WEB_TOOLS = [
  "list_projects",
  "describe_project",
  "get_transcript",
  "render_frames",
  "style_options",
  "apply_edits",
  "add_effect",
  "update_effect",
  "remove_effect",
  "auto_zoom",
  "add_annotation",
  "update_annotation",
  "remove_annotation",
  "add_blur",
  "remove_blur",
  "set_speed",
  "remove_speed",
  "set_trim",
  "cut_video",
  "set_style",
  "undo",
  "export_project",
] as const;
export type WebToolName = (typeof WEB_TOOLS)[number] | "get_editing_playbook";

/** Desktop-only: need the Mac (screen capture, on-device Whisper, the local
 *  library/notes index). Listed so the split is explicit and testable. */
export const DESKTOP_ONLY_TOOLS = [
  "list_capture_targets",
  "start_recording",
  "stop_recording",
  "transcribe",
  "search_captures",
  "list_notes",
] as const;

/** Minimal WebMCP surface we rely on (spec: WebMCP CG draft, Chrome 149+). */
export interface ModelContextToolDescriptor {
  name: string;
  title?: string;
  description: string;
  inputSchema: object;
  execute: (input: ToolArgs, options: { signal: AbortSignal }) => Promise<string>;
  annotations?: { readOnlyHint?: boolean; consequentialHint?: boolean };
}

export interface ModelContextLike {
  registerTool(tool: ModelContextToolDescriptor, options?: { signal?: AbortSignal }): Promise<void> | void;
}

export function findModelContext(scope: {
  document?: unknown;
  navigator?: unknown;
} = globalThis as never): ModelContextLike | null {
  const fromDocument = (scope.document as { modelContext?: ModelContextLike } | undefined)?.modelContext;
  if (fromDocument && typeof fromDocument.registerTool === "function") return fromDocument;
  const legacy = (scope.navigator as { modelContext?: ModelContextLike } | undefined)?.modelContext;
  if (legacy && typeof legacy.registerTool === "function") return legacy;
  return null;
}

const PLAYBOOK_TOOL: CatalogTool = {
  name: "get_editing_playbook",
  title: "Editing playbook",
  description:
    "READ THIS FIRST. How CaptureCat edits work: the two clocks (SOURCE vs OUTPUT seconds), the lanes " +
    "that never overlap, normalized Y-down coordinates, the describe → apply_edits → render_frames loop, " +
    "and good-taste defaults for screen recordings. Identical to the desktop MCP server's instructions.",
  inputSchema: { type: "object", properties: {}, required: [] },
  annotations: { readOnlyHint: true },
};

/** Adapt one catalog tool to the browser: `id` optional (defaults to the
 *  open project); export writes a download instead of a filesystem path. */
export function adaptTool(tool: CatalogTool): CatalogTool {
  const schema = structuredClone(tool.inputSchema);
  const properties = { ...(schema.properties ?? {}) } as Record<string, Record<string, unknown>>;
  let required = [...(schema.required ?? [])];
  if (properties.id) {
    properties.id = {
      ...properties.id,
      description: "Project id. Optional in the web editor — defaults to the project open in this tab.",
    };
    required = required.filter((key) => key !== "id");
  }
  let description = tool.description;
  if (tool.name === "export_project") {
    delete properties.output;
    required = required.filter((key) => key !== "output");
    description =
      "Export the open project to an mp4 in the browser (same renderer as the preview) and hand it to the " +
      "user as a download. Blocks until finished.";
  }
  return { ...tool, description, inputSchema: { type: "object", properties, required } };
}

export function webCatalog(): CatalogTool[] {
  const byName = new Map((catalog.tools as CatalogTool[]).map((tool) => [tool.name, tool]));
  const tools = WEB_TOOLS.map((name) => byName.get(name)).filter((t): t is CatalogTool => Boolean(t));
  return [PLAYBOOK_TOOL, ...tools.map(adaptTool)];
}

/** Everything the result string needs: JSON for data, raw text for text. */
function toResultString(value: unknown): string {
  if (typeof value === "string") return value;
  return JSON.stringify(value ?? null);
}

/**
 * Register the editor's tools. Returns an unregister function (aborts the
 * shared signal — in-flight executions are not cancelled by the spec).
 * No-op (returns a no-op) when the browser has no WebMCP.
 */
export function registerEditorTools(
  handlers: ToolHandlers,
  context: ModelContextLike | null = findModelContext(),
): () => void {
  if (!context) return () => {};
  const controller = new AbortController();
  const all: ToolHandlers = {
    get_editing_playbook: async () => catalog.instructions,
    ...handlers,
  };
  for (const tool of webCatalog()) {
    const handler = all[tool.name as WebToolName];
    if (!handler) continue;
    const annotations = tool.annotations ?? {};
    void context.registerTool(
      {
        name: tool.name,
        title: tool.title,
        description: tool.description,
        inputSchema: tool.inputSchema,
        annotations: {
          readOnlyHint: annotations.readOnlyHint === true,
          consequentialHint: annotations.readOnlyHint !== true && annotations.destructiveHint === true,
        },
        execute: async (input, { signal }) => {
          try {
            return toResultString(await handler(input ?? {}, signal));
          } catch (error) {
            // Same contract as the desktop server: an actionable ERROR line.
            return `ERROR: ${error instanceof Error ? error.message : String(error)}`;
          }
        },
      },
      { signal: controller.signal },
    );
  }
  return () => controller.abort();
}
