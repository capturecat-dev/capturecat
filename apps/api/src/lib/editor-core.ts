/**
 * The web editor's pure edit layer, IMPORTED — never copied — into the
 * Worker. This file is the one seam: the remote MCP editing tools
 * (src/mcp/project-tools.ts, via lib/project-edits.ts) reach the editor's
 * model, edit ops, Auto Zoom, media-reference resolution, change-set diff
 * and the editing playbook only through these re-exports.
 *
 * Why it is safe to import: everything below is the editor's pure TypeScript
 * (apps/web/src/editor/core + webmcp/ops + the pure state/mediaRef.ts) — no DOM,
 * no fetch, no path aliases, no npm packages — so esbuild (wrangler) bundles
 * it into the Worker as-is and the API's tsc checks it under the Worker's lib.
 * The ops are the Mac MCP server's tool cores, parity-checked against the
 * real Swift server by apps/web/scripts/mcp-parity; running the SAME module
 * here means a cloud edit is the edit the Mac and the browser would make
 * (CLAUDE.md rule 2: never fork edit math).
 *
 * Keep the import closure pure: anything added here must not pull in
 * engine/, ui/, React or `@/` imports. `npx wrangler deploy --dry-run` and
 * `npx tsc --noEmit -p .` in apps/api catch a violation.
 */

export * as ops from "../../../web/src/editor/webmcp/ops";
export {
  ProjectDecodeError,
  newUUID,
  parseProjectText,
  serializeProjectText,
  type Project,
} from "../../../web/src/editor/core/model";
export { applyAutoZoom, applyStillMotion } from "../../../web/src/editor/core/edit/autoZoom";
export { interactionInputsFrom, type InteractionInputs } from "../../../web/src/editor/core/edit/interactionInputs";
export { mediaRefIndex, resolveMediaRef, type MediaRefIndex } from "../../../web/src/editor/state/mediaRef";
export { diff as projectDiff, encodeChangeHeader } from "../../../web/src/editor/core/merge/projectDiff";

import catalog from "../../../web/src/editor/webmcp/catalog.generated.json";

/** The Mac MCP server's `instructions` — what the web's WebMCP
 *  `get_editing_playbook` tool returns (webmcp/register.ts). */
export const EDITING_PLAYBOOK: string = catalog.instructions;

/** One desktop tool as the catalog (generated from the Mac server) describes it. */
export interface CatalogTool {
  name: string;
  title?: string;
  description: string;
  inputSchema: { type: "object"; properties?: Record<string, unknown>; required?: string[] };
}

/** The desktop catalog entry for a tool name, or undefined. */
export function catalogTool(name: string): CatalogTool | undefined {
  return (catalog.tools as CatalogTool[]).find((t) => t.name === name);
}
