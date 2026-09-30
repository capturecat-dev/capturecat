/**
 * render_frames' pure parts from MCPServer.swift `renderFrames`: argument
 * validation (same order + messages), the OUTPUT times it samples, the
 * per-frame caption / contact-sheet label text, the text header, and
 * `contactSheetLayout` (grid choice + tile/caption metrics). The pixels come
 * from the web export engine; everything an agent reads is identical.
 */
import { formatFixed, smax, smin, srounded } from "../../core/math/swift";
import { ToolError } from "./errors";
import { arrayValue, doubleValue, fmt, has, objectValue, round3, stringValue } from "./json";
import type { JSONObject } from "./types";

export type RenderLayout = "individual" | "contact_sheet";

export interface RenderFramesRequest {
  layout: RenderLayout;
  sheet: boolean;
  /** 16 for a contact sheet, 8 otherwise. */
  maxFrames: number;
  /** false = png. */
  jpeg: boolean;
  /** JPEG quality 0.1…1 (default 0.8). */
  quality: number;
  /** Longest edge of each image (individual) / of the sheet. */
  maxEdge: number;
  /** Explicit OUTPUT times, or null when sampling a span. */
  times: number[] | null;
  /** Evenly sampled OUTPUT span (end null = the video's end). */
  span: { start: number; end: number | null; count: number } | null;
}

/** Validates render_frames' arguments exactly like the Mac (before any
 * rendering happens). */
export function parseRenderFramesArgs(args: JSONObject): RenderFramesRequest {
  const layoutRaw = stringValue(args.layout) ?? "individual";
  if (layoutRaw !== "individual" && layoutRaw !== "contact_sheet") {
    throw new ToolError(
      'layout must be "individual" (one image per time) or "contact_sheet" ' +
        "(all frames tiled into ONE labelled image — far fewer image tokens)",
    );
  }
  const layout: RenderLayout = layoutRaw;
  const sheet = layout === "contact_sheet";
  const maxFrames = sheet ? 16 : 8;

  const formatRaw = (stringValue(args.format) ?? "png").toLowerCase();
  if (!["png", "jpeg", "jpg"].includes(formatRaw)) throw new ToolError('format must be "png" or "jpeg"');
  const jpeg = formatRaw !== "png";
  let quality = 0.8;
  if (has(args, "quality")) {
    const q = doubleValue(args.quality);
    if (q === null || !(q >= 0.1 && q <= 1)) throw new ToolError("quality must be a number in 0.1...1 (jpeg only)");
    quality = q;
  }
  const [lo, hi] = sheet ? [400, 2400] : [100, 1600];
  const maxEdge = smin(hi, smax(lo, doubleValue(args.maxWidth) ?? (sheet ? 1568 : 800)));

  // times (explicit) or span (evenly sampled) — both OUTPUT seconds.
  const rawTimes = arrayValue(args.times);
  const span = objectValue(args.span);
  if (rawTimes !== null && span !== null) throw new ToolError("pass either times or span, not both");
  if (rawTimes !== null) {
    const times = rawTimes.map(doubleValue).filter((t): t is number => t !== null);
    if (times.length === 0 || times.length !== rawTimes.length) {
      throw new ToolError("times must be a non-empty array of numbers (OUTPUT seconds)");
    }
    if (times.length > maxFrames) {
      throw new ToolError(
        `max ${maxFrames} times per call for layout ${layout}` +
          (sheet ? "" : ' — use layout "contact_sheet" for up to 16 in one image'),
      );
    }
    return { layout, sheet, maxFrames, jpeg, quality, maxEdge, times, span: null };
  }
  if (span !== null) {
    const countRaw = doubleValue(span.count);
    const count = countRaw !== null ? Math.trunc(countRaw) : sheet ? 12 : 4;
    if (!(count >= 1 && count <= maxFrames)) {
      throw new ToolError(`span.count must be 1...${maxFrames} for layout ${layout}`);
    }
    const start = doubleValue(span.start) ?? 0;
    const end = doubleValue(span.end);
    if (!(start >= 0) || !(end === null || end > start)) {
      throw new ToolError("span needs 0 <= start < end (OUTPUT seconds; end defaults to the video's end)");
    }
    return { layout, sheet, maxFrames, jpeg, quality, maxEdge, times: null, span: { start, end, count } };
  }
  throw new ToolError("pass times: [OUTPUT seconds…] or span: {start?, end?, count?} to sample evenly");
}

/** The OUTPUT times to grab once the render's `duration` is known. */
export function renderFrameTimes(request: RenderFramesRequest, duration: number): number[] {
  if (request.times) return request.times;
  const spec = request.span!;
  const end = smin(spec.end ?? duration, duration);
  if (!(end > spec.start)) {
    throw new ToolError(`span start ${fmt(spec.start)}s is past the end of the output (${fmt(duration)}s)`);
  }
  if (spec.count === 1) return [spec.start];
  return Array.from({ length: spec.count }, (_, i) => spec.start + ((end - spec.start) * i) / (spec.count - 1));
}

/** The time actually requested from the decoder for `t`. */
export function clampFrameTime(t: number, duration: number): number {
  return smax(0, smin(t, smax(0, duration - 0.001)));
}

/** Individual layout: the text item before each image. */
export function frameCaption(index: number, output: number, source: number | null): string {
  let caption = `frame #${index + 1} at t=${formatFixed(output, 2)}s`;
  if (source !== null) caption += ` (source ${formatFixed(source, 2)}s)`;
  return caption + ":";
}

/** Contact sheet: the label burned under each tile. */
export function contactSheetLabel(index: number, output: number, source: number | null): string {
  let label = `#${index + 1}  ${formatFixed(output, 2)}s`;
  if (source !== null) label += `  src ${formatFixed(source, 2)}`;
  return label;
}

export interface RenderedFrame {
  output: number;
  source: number | null;
}

/** The JSON text item that opens render_frames' content. */
export function renderFramesHeader(options: {
  freshlyRendered: boolean;
  duration: number;
  layout: RenderLayout;
  frames: readonly RenderedFrame[];
  sheetLayout?: ContactSheetLayout | null;
}): JSONObject {
  const header: JSONObject = {
    render: options.freshlyRendered ? "fresh export" : "cached export",
    durationSeconds: srounded(options.duration * 100) / 100,
    frames: options.frames.length,
    layout: options.layout,
  };
  if (options.sheetLayout) {
    header.grid = `${options.sheetLayout.columns}x${options.sheetLayout.rows}`;
    header.tiles = options.frames.map((frame, index) => {
      const tile: JSONObject = { tile: index + 1, output: round3(frame.output) };
      if (frame.source !== null) tile.source = round3(frame.source);
      return tile;
    });
    header.note =
      "One image, tiles left→right then top→bottom. The caption under each tile " +
      "reads '#n <OUTPUT>s  src <SOURCE>' — use the src (SOURCE) time for edit tools.";
  }
  return header;
}

/** `MCPServer.ContactSheetLayout` */
export interface ContactSheetLayout {
  columns: number;
  rows: number;
  /** The frame area of one cell (the caption strip sits below it). */
  tile: { width: number; height: number };
  captionHeight: number;
  fontSize: number;
  gap: number;
  size: { width: number; height: number };
}

/** `MCPServer.contactSheetLayout(count:aspect:maxEdge:)` — grid closest to
 * 3:2, preferring few empty cells; longest edge <= maxEdge. */
export function contactSheetLayout(count: number, aspect: number, maxEdge: number): ContactSheetLayout {
  const tileAspect = smax(0.1, aspect);
  let best = { columns: 1, score: Infinity };
  for (let columns = 1; columns <= Math.max(1, count); columns++) {
    const rows = Math.ceil(count / columns);
    // ~12% of a cell's height is caption.
    const sheetAspect = (columns * aspect * 0.88) / rows;
    const empty = columns * rows - count;
    const score = Math.abs(Math.log(sheetAspect / 1.5)) + empty * 0.12;
    if (score < best.score) best = { columns, score };
  }
  const columns = best.columns;
  const rows = Math.ceil(count / columns);
  const gap = 6;
  const caption = (tileWidth: number) => {
    const font = srounded(smax(12, smin(26, tileWidth * 0.05)));
    return { font, height: Math.ceil(font * 1.6) };
  };
  const sheetSize = (tileWidth: number) => {
    const tileHeight = Math.floor(tileWidth / tileAspect);
    return {
      width: columns * tileWidth + (columns + 1) * gap,
      height: rows * (tileHeight + caption(tileWidth).height) + (rows + 1) * gap,
    };
  };
  const edge = maxEdge;
  let tileWidth = Math.floor((edge - (columns + 1) * gap) / columns);
  for (let i = 0; i < 12; i++) {
    const size = sheetSize(tileWidth);
    const longest = smax(size.width, size.height);
    if (!(longest > edge)) break;
    tileWidth = Math.floor((tileWidth * edge) / longest) - 1;
  }
  tileWidth = smax(40, tileWidth);
  const metrics = caption(tileWidth);
  return {
    columns,
    rows,
    tile: { width: tileWidth, height: Math.floor(tileWidth / tileAspect) },
    captionHeight: metrics.height,
    fontSize: metrics.font,
    gap,
    size: sheetSize(tileWidth),
  };
}
