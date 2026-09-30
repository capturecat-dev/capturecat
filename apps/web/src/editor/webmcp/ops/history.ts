/**
 * The desktop server's undo contract (MCPServer.swift `commitEdit` / `undo`),
 * minus the file IO: every committed MCP edit snapshots the previous project
 * into a history (newest first, at most 30 kept), mutating results carry
 * `undoSteps`, and `undo {steps?, force?}` walks back with the same checks,
 * messages and result payload.
 *
 * The host owns the snapshots; these helpers own the rules and the words.
 */
import type { Project } from "../../core/model";
import { timelineCounts } from "./describe";
import { ToolError } from "./errors";
import { boolValue, doubleValue, has, prefixChars } from "./json";
import { srounded } from "../../core/math/swift";
import type { JSONObject } from "./types";

/** `MCPServer.historyLimit` */
export const HISTORY_LIMIT = 30;

/** One undo step's metadata (the Mac's `.meta.json`). */
export interface HistoryEntry {
  /** Tool that made the edit ("set_style", "apply_edits", …). */
  tool: string;
  /** `editSummary(tool, result)` — "apply_edits: add_effect, set_trim". */
  summary: string;
  /** ISO-8601 time of the edit (`isoTimestamp()`). */
  at: string;
}

/** `ISO8601DateFormatter().string(from:)` — UTC, whole seconds. */
export function isoTimestamp(date = new Date()): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** The extras every committed mutating result carries: `undoSteps` =
 * history depth after this edit's snapshot, capped at the limit. (The Mac
 * may add a `warning` when its GUI is running — not applicable on the web.) */
export function commitExtras(historyDepthAfterCommit: number): JSONObject {
  return { undoSteps: Math.min(historyDepthAfterCommit, HISTORY_LIMIT) };
}

/**
 * Validates an `undo` call against the available history (newest first) and
 * returns how many steps to undo. `changedOutside` = the project changed
 * outside MCP since the last MCP edit (the Mac compares the file's SHA-256
 * with the one recorded at that edit; the web store knows when the user
 * edited the project by hand) — refused unless `force: true`.
 */
export function planUndo(args: JSONObject, entries: readonly HistoryEntry[], changedOutside = false): number {
  let steps = 1;
  if (has(args, "steps")) {
    const value = doubleValue(args.steps);
    if (value === null || !(value >= 1) || value !== srounded(value)) {
      throw new ToolError("steps must be a whole number >= 1");
    }
    steps = value;
  }
  if (entries.length === 0) {
    throw new ToolError(
      "nothing to undo — no MCP edits are recorded for this project " +
        "(project.json.bak, if present, holds the state before the last write)",
    );
  }
  if (steps > entries.length) {
    throw new ToolError(`only ${entries.length} MCP edit(s) can be undone (asked for ${steps})`);
  }
  if (changedOutside && boolValue(args.force) !== true) {
    throw new ToolError(
      "project.json changed outside MCP after the last MCP edit " +
        `(${entries[0].summary} at ${entries[0].at}) — most likely saved from the CaptureCat app. ` +
        "Undoing now would also discard those changes. Pass force: true to undo anyway.",
    );
  }
  return steps;
}

/** The undo result: `undone` = the popped entries (newest first). */
export function undoResult(
  undone: readonly HistoryEntry[],
  remainingUndoSteps: number,
  restored: Project,
  replaced: Project | null,
): JSONObject {
  const result: JSONObject = {
    undone: undone.map((e) => ({ tool: e.tool, summary: e.summary, at: e.at })),
    remainingUndoSteps,
    restored: timelineCounts(restored),
    note: "project.json.bak holds the state just before this undo.",
  };
  if (replaced) result.replaced = timelineCounts(replaced);
  return result;
}

/** `String(summary.prefix(300))` as the Mac stores it. */
export function historySummary(summary: string): string {
  return prefixChars(summary, 300);
}
