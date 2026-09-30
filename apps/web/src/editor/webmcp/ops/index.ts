/**
 * The Mac MCP server's tool cores, ported to pure TypeScript for WebMCP.
 * Same validation, clamps, error texts and result payloads as
 * apps/macos/CaptureCat/Services/MCPServer*.swift — proved against the real
 * server by apps/web/scripts/mcp-parity.
 *
 * Host contract (the editor store):
 *  - mutating tool `name` (see EDIT_OP_NAMES): `editCore(name)!(draft, args, ctx)`
 *    on a deep-cloned draft; on throw discard the draft, else commit it and
 *    merge `commitExtras(historyDepth)` into the result.
 *  - apply_edits: `applyEditsBatch(draft, args.ops, ctx)` — same contract,
 *    one commit for the whole batch.
 *  - errors: `ERROR: ${error.message}` (register.ts already does this).
 *  - results: `resultJSON(result)` gives the desktop's exact text form.
 */
export { ToolError, errorMessage } from "./errors";
export type { EditCore, JSONObject, OpContext } from "./types";
export {
  EDIT_OPS,
  EDIT_OP_NAMES,
  SCRIPTABLE_ANNOTATION_TYPES,
  SPEED_PRESETS,
  applyEditsBatch,
  applyNewAnnotationDefaults,
  durationLimit,
  editCore,
  editSummary,
  effectBlock,
  effectLaneConflict,
  focusLaneConflict,
  outputDuration,
} from "./edits";
export {
  STYLE_GROUPS,
  STYLE_KEYS,
  applyStyle,
  hexString,
  levenshtein,
  parseHexColor,
  styleKeySummary,
  styleOptions,
  type StyleKey,
  type StyleKind,
} from "./style";
export {
  analyzeSilence,
  annotationPayload,
  cursorActivity,
  describeProject,
  getTranscript,
  interactionDigest,
  pacingDigest,
  rectPayload,
  timelineCounts,
  transcriptPayload,
  type CursorActivity,
  type DescribeInputs,
  type SilenceAnalysis,
  type SilenceOutcome,
  type TimeSpan,
} from "./describe";
export {
  HISTORY_LIMIT,
  commitExtras,
  historySummary,
  isoTimestamp,
  planUndo,
  undoResult,
  type HistoryEntry,
} from "./history";
export {
  clampFrameTime,
  contactSheetLabel,
  contactSheetLayout,
  frameCaption,
  parseRenderFramesArgs,
  renderFrameTimes,
  renderFramesHeader,
  type ContactSheetLayout,
  type RenderFramesRequest,
  type RenderLayout,
  type RenderedFrame,
} from "./render";
export {
  boolValue,
  describeValue,
  doubleValue,
  fmt,
  formatG,
  formatNumber,
  jsonSafe,
  resultJSON,
  round3,
  swiftDoubleDescription,
} from "./json";
