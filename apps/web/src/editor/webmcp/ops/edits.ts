/**
 * Port of apps/macos/CaptureCat/Services/MCPServer+Edits.swift — the mutating
 * MCP tools as PURE cores `(project, args, ctx) -> result`. No load, no
 * write: a single tool is load → core → commit, and `apply_edits` runs any
 * number of cores against ONE draft and commits once (all-or-nothing).
 *
 * Same validation order, clamps, lane rules, error texts and result payloads
 * as the Swift server (proved by apps/web/scripts/mcp-parity). Every time is
 * SOURCE seconds.
 */
import {
  AnnotationEffect as AnnotationEffectValues,
  AnnotationType as AnnotationTypeValues,
  BlurStyle as BlurStyleValues,
  ZoomAnimationStyle as ZoomAnimationStyleValues,
  enumValues,
} from "../../core/model/enums";
import type {
  Annotation,
  AnnotationEffect,
  AnnotationType,
  BlurRegion,
  BlurStyle,
  Project,
  TiltRegion,
  VideoClipSegment,
  VideoSpeedRegion,
  ZoomAnimationStyle,
  ZoomRegion,
} from "../../core/model";
import { DEFAULT_COLORS, newAnnotation, newBlurRegion } from "../../core/model/defaults";
import { isImageCapture } from "../../core/model/helpers";
import { smax, smin } from "../../core/math/swift";
import { clampCardOffset } from "../../core/math/zoomFocalMath";
import {
  effectiveTrimEnd,
  effectiveTrimStart,
  effectiveVideoClipSegments,
  exportedOutputDuration,
} from "../../core/time/clips";
import { SpeedTimeMap } from "../../core/time/speedTimeMap";
import { ToolError, errorMessage } from "./errors";
import {
  arrayValue,
  boolValue,
  describeValue,
  doubleValue,
  fmt,
  formatNumber,
  has,
  objectArrayValue,
  objectValue,
  prefixChars,
  round3,
  stringValue,
  swiftDoubleDescription,
  uuidValue,
} from "./json";
import { applyStyle, parseHexColor } from "./style";
import type { EditCore, JSONObject, OpContext } from "./types";

// ── Output clock ──────────────────────────────────────────────────────────

/** `MCPServer.outputDuration(of:)` — exported length (OUTPUT seconds) on the
 * exporter's trim+speed map and last-visible-clip cap; null while the
 * project's duration is unprobed (0). */
export function outputDuration(project: Project): number | null {
  if (!(project.duration > 0)) return null;
  return exportedOutputDuration(project, SpeedTimeMap.trimmedOutputOf(project));
}

function outputDurationEntry(before: number | null, project: Project): JSONObject | null {
  const after = outputDuration(project);
  return before !== null && after !== null ? { before: round3(before), after: round3(after) } : null;
}

// ── Shared validation ─────────────────────────────────────────────────────

/** Some projects persist duration 0 (metadata written before probe) — treat
 * that as unbounded rather than rejecting every span. */
export function durationLimit(project: Project): number {
  return project.duration > 0 ? project.duration : Infinity;
}

function requiredSpan(args: JSONObject, project: Project, what: string): [number, number] {
  const start = doubleValue(args.start);
  const end = doubleValue(args.end);
  if (start === null || end === null) {
    throw new ToolError(`${what} needs start and end (SOURCE seconds, end > start)`);
  }
  validateSpan(start, end, project, what);
  return [start, end];
}

function validateSpan(start: number, end: number, project: Project, what: string): void {
  const duration = durationLimit(project);
  if (!(Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end > start)) {
    throw new ToolError(`${what}: invalid span ${fmt(start)}–${fmt(end)} — need 0 <= start < end (SOURCE seconds)`);
  }
  if (!(end <= duration + 0.001)) {
    throw new ToolError(
      `${what}: span ${fmt(start)}–${fmt(end)} runs past the recording's end ` +
        `(${fmt(duration)}s SOURCE). Times are SOURCE seconds — if you read them off render_frames ` +
        "or get_transcript start/end, those are OUTPUT seconds; convert first.",
    );
  }
}

function uuidArgument(args: JSONObject, key: string, hint: string): string {
  const id = uuidValue(args[key]);
  if (id === null) throw new ToolError(`${key} must be a UUID string (${hint})`);
  return id;
}

const clamp01 = (v: number) => smin(1, smax(0, v));
const sameId = (a: string, b: string) => a.toUpperCase() === b;
const sortNumbers = (xs: number[]) => xs.sort((a, b) => (a < b ? -1 : b < a ? 1 : 0));

interface LaneSpan {
  start: number;
  end: number;
  kind: string;
  id: string;
}

function firstConflict(spans: LaneSpan[], start: number, end: number, ignoring: ReadonlySet<string>): LaneSpan | null {
  const epsilon = 0.0001;
  for (const span of spans) {
    if (!ignoring.has(span.id) && start < span.end - epsilon && end > span.start + epsilon) return span;
  }
  return null;
}

/** The single no-overlap EFFECTS lane (zoom + tilt), SOURCE time. */
export function effectLaneConflict(
  project: Project,
  start: number,
  end: number,
  ignoring: ReadonlySet<string> = new Set(),
): string | null {
  const spans: LaneSpan[] = [
    ...project.zoomRegions.map((r) => ({ start: r.startTime, end: r.endTime, kind: "zoom", id: r.id })),
    ...project.tiltRegions.map((r) => ({ start: r.startTime, end: r.endTime, kind: "tilt", id: r.id })),
  ];
  const span = firstConflict(spans, start, end, ignoring);
  if (!span) return null;
  return (
    `span ${fmt(start)}–${fmt(end)} overlaps existing ${span.kind} region ${span.id.toUpperCase()} ` +
    `(${fmt(span.start)}–${fmt(span.end)}) — the EFFECTS lane never overlaps. ` +
    "Pick a free span, shorten this one, or remove/move that region first (same batch is fine)."
  );
}

/** The FOCUS lane: blur, highlight, depth-focus and camera-layout regions
 * share one no-overlap lane in the editor. */
export function focusLaneConflict(
  project: Project,
  start: number,
  end: number,
  ignoring: ReadonlySet<string> = new Set(),
): string | null {
  const spans: LaneSpan[] = [
    ...project.blurRegions.map((r) => ({ start: r.startTime, end: r.endTime, kind: "blur", id: r.id })),
    ...project.highlightRegions.map((r) => ({ start: r.startTime, end: r.endTime, kind: "highlight", id: r.id })),
    ...project.focusRegions.map((r) => ({ start: r.startTime, end: r.endTime, kind: "depth-focus", id: r.id })),
    ...project.cameraLayoutRegions.map((r) => ({
      start: r.startTime,
      end: r.endTime,
      kind: "camera-layout",
      id: r.id,
    })),
  ];
  const span = firstConflict(spans, start, end, ignoring);
  if (!span) return null;
  return (
    `span ${fmt(start)}–${fmt(end)} overlaps the ${span.kind} region ${span.id.toUpperCase()} ` +
    `(${fmt(span.start)}–${fmt(span.end)}) — blur, highlight, depth-focus and camera-layout ` +
    "regions share one FOCUS lane that never overlaps. Pick a free span or remove that region first."
  );
}

const ZOOM_STYLES = enumValues(ZoomAnimationStyleValues);

/** undefined = key absent (leave as is), null = explicit null (clear). */
function parseAnimationStyle(args: JSONObject): ZoomAnimationStyle | null | undefined {
  if (!has(args, "animationStyle")) return undefined;
  const raw = args.animationStyle;
  if (raw === null) return null;
  const style = stringValue(raw);
  if (style === null || !(ZOOM_STYLES as readonly string[]).includes(style)) {
    throw new ToolError(
      `invalid animationStyle: ${describeValue(raw)} (allowed: ` +
        ZOOM_STYLES.map((s) => `"${s}"`).join(", ") +
        ", or null/omit for the project's animationSpeed)",
    );
  }
  return style as ZoomAnimationStyle;
}

function setCardOffset(region: ZoomRegion, key: "cardOffsetX" | "cardOffsetY", value: number | null): void {
  if (value === null) return;
  if (Math.abs(value) < 0.005) delete region[key];
  else region[key] = clampCardOffset(value);
}

function setFollowsCursor(region: ZoomRegion, value: unknown): void {
  const follows = boolValue(value);
  if (follows === null) return;
  // false = fixed focus; true = default cursor blend (stored as nil).
  if (follows) delete region.followsCursor;
  else region.followsCursor = false;
}

// ── Effects (zoom / tilt) ─────────────────────────────────────────────────

const opAddEffect: EditCore = (project, args, ctx) => {
  const type = stringValue(args.type);
  if (type === null || !["zoom", "tilt", "zoomtilt"].includes(type)) {
    throw new ToolError('type must be "zoom", "tilt" or "zoomtilt" (a linked zoom+tilt pair on one span)');
  }
  const [start, end] = requiredSpan(args, project, "add_effect");
  const style = parseAnimationStyle(args) ?? null;
  const conflict = effectLaneConflict(project, start, end);
  if (conflict) throw new ToolError(conflict);

  const created: JSONObject[] = [];
  if (type === "zoom" || type === "zoomtilt") {
    const fx = doubleValue(args.focalX) ?? 0.5;
    const fy = doubleValue(args.focalY) ?? 0.5;
    const region: ZoomRegion = {
      id: ctx.newId(),
      startTime: start,
      endTime: end,
      zoomLevel: smin(6, smax(0.3, doubleValue(args.zoomLevel) ?? 2.0)),
      focalPoint: { x: clamp01(fx), y: clamp01(fy) },
    };
    if (style !== null) region.animationStyle = style;
    setCardOffset(region, "cardOffsetX", doubleValue(args.offsetX));
    setCardOffset(region, "cardOffsetY", doubleValue(args.offsetY));
    setFollowsCursor(region, args.followsCursor);
    project.zoomRegions.push(region);
    created.push({ type: "zoom", id: region.id, zoomLevel: round3(region.zoomLevel) });
  }
  if (type === "tilt" || type === "zoomtilt") {
    const region: TiltRegion = {
      id: ctx.newId(),
      startTime: start,
      endTime: end,
      pitch: smin(60, smax(-60, doubleValue(args.pitch) ?? 20)),
      yaw: smin(60, smax(-60, doubleValue(args.yaw) ?? 0)),
      roll: smin(30, smax(-30, doubleValue(args.roll) ?? 0)),
    };
    if (style !== null) region.animationStyle = style;
    project.tiltRegions.push(region);
    created.push({ type: "tilt", id: region.id });
  }
  return { created, span: { start: round3(start), end: round3(end) } };
};

/**
 * `MCPServer.effectBlock(at:in:)` — the EFFECTS-lane block at SOURCE time
 * `at`: a zoom, a tilt, or both halves of a linked zoomtilt (identical
 * spans). Blocks may TOUCH, so a boundary time can hit two different blocks —
 * then the one `at` is strictly inside wins (else the earlier-listed zoom),
 * never both.
 */
export function effectBlock(at: number, project: Project): { zoom: number | null; tilt: number | null } {
  const pick = (spans: { start: number; end: number }[]): number | null => {
    const hits: number[] = [];
    spans.forEach((s, i) => {
      if (at >= s.start && at <= s.end) hits.push(i);
    });
    const inside = hits.find((i) => at > spans[i].start && at < spans[i].end);
    return inside ?? hits[0] ?? null;
  };
  let zoom = pick(project.zoomRegions.map((r) => ({ start: r.startTime, end: r.endTime })));
  let tilt = pick(project.tiltRegions.map((r) => ({ start: r.startTime, end: r.endTime })));
  if (zoom !== null && tilt !== null) {
    const zr = project.zoomRegions[zoom];
    const tr = project.tiltRegions[tilt];
    const linked = Math.abs(zr.startTime - tr.startTime) < 0.0005 && Math.abs(zr.endTime - tr.endTime) < 0.0005;
    if (!linked) {
      const insideTilt = at > tr.startTime && at < tr.endTime;
      const insideZoom = at > zr.startTime && at < zr.endTime;
      // Both strictly inside = a legacy project whose tilt track overlapped
      // zooms: keep both, as before the single lane.
      if (insideTilt && !insideZoom) zoom = null;
      else if (!(insideZoom && insideTilt)) tilt = null;
    }
  }
  return { zoom, tilt };
}

/** Patches the zoom/tilt block containing SOURCE time `at` (both halves of a
 * linked zoomtilt pair). */
const opUpdateEffect: EditCore = (project, args) => {
  const at = doubleValue(args.at);
  if (at === null) throw new ToolError("'at' (a SOURCE time inside the block — e.g. its start) is required");
  const { zoom: zoomIndex, tilt: tiltIndex } = effectBlock(at, project);
  if (zoomIndex === null && tiltIndex === null) {
    throw new ToolError(
      `no zoom/tilt block spans SOURCE t=${fmt(at)} — describe_project lists ` +
        "effects.zoomRegions/tiltRegions with their start/end",
    );
  }
  const style = parseAnimationStyle(args);

  // New span (validated once, against every OTHER block on the lane).
  const current =
    zoomIndex !== null
      ? [project.zoomRegions[zoomIndex].startTime, project.zoomRegions[zoomIndex].endTime]
      : [project.tiltRegions[tiltIndex!].startTime, project.tiltRegions[tiltIndex!].endTime];
  const newStart = doubleValue(args.start) ?? current[0];
  const newEnd = doubleValue(args.end) ?? current[1];
  const spanChanged = has(args, "start") || has(args, "end");
  if (spanChanged) {
    validateSpan(newStart, newEnd, project, "update_effect");
    const mine = new Set<string>();
    if (zoomIndex !== null) mine.add(project.zoomRegions[zoomIndex].id);
    if (tiltIndex !== null) mine.add(project.tiltRegions[tiltIndex].id);
    const conflict = effectLaneConflict(project, newStart, newEnd, mine);
    if (conflict) throw new ToolError(conflict);
  }

  const touched: string[] = [];
  if (zoomIndex !== null) {
    const region = project.zoomRegions[zoomIndex];
    const level = doubleValue(args.zoomLevel);
    if (level !== null) region.zoomLevel = smin(6, smax(0.3, level));
    const fx = doubleValue(args.focalX);
    const fy = doubleValue(args.focalY);
    if (fx !== null || fy !== null) {
      const old = region.focalPoint;
      region.focalPoint = { x: clamp01(fx ?? old.x), y: clamp01(fy ?? old.y) };
    }
    if (spanChanged) {
      region.startTime = newStart;
      region.endTime = newEnd;
    }
    setCardOffset(region, "cardOffsetX", doubleValue(args.offsetX));
    setCardOffset(region, "cardOffsetY", doubleValue(args.offsetY));
    if (style !== undefined) {
      if (style === null) delete region.animationStyle;
      else region.animationStyle = style;
    }
    setFollowsCursor(region, args.followsCursor);
    touched.push(`zoom:${region.id.toUpperCase()}`);
  }
  if (tiltIndex !== null) {
    const region = project.tiltRegions[tiltIndex];
    const pitch = doubleValue(args.pitch);
    if (pitch !== null) region.pitch = smin(60, smax(-60, pitch));
    const yaw = doubleValue(args.yaw);
    if (yaw !== null) region.yaw = smin(60, smax(-60, yaw));
    const roll = doubleValue(args.roll);
    if (roll !== null) region.roll = smin(30, smax(-30, roll));
    if (spanChanged) {
      region.startTime = newStart;
      region.endTime = newEnd;
    }
    if (style !== undefined) {
      if (style === null) delete region.animationStyle;
      else region.animationStyle = style;
    }
    touched.push(`tilt:${region.id.toUpperCase()}`);
  }
  return { updated: touched, span: { start: round3(newStart), end: round3(newEnd) } };
};

const opRemoveEffect: EditCore = (project, args) => {
  const at = doubleValue(args.at);
  if (at === null) throw new ToolError("'at' (a SOURCE time inside the block) is required");
  const { zoom: zoomIndex, tilt: tiltIndex } = effectBlock(at, project);
  if (zoomIndex === null && tiltIndex === null) {
    throw new ToolError(`no zoom/tilt block spans SOURCE t=${fmt(at)} — describe_project lists them`);
  }
  const removed: string[] = [];
  if (zoomIndex !== null) removed.push(`zoom:${project.zoomRegions.splice(zoomIndex, 1)[0].id.toUpperCase()}`);
  if (tiltIndex !== null) removed.push(`tilt:${project.tiltRegions.splice(tiltIndex, 1)[0].id.toUpperCase()}`);
  return { removed: removed.length, blocks: removed };
};

/** Runs the SAME auto-zoom pipeline the app's ✨ menu uses (via the host's
 * `ctx.autoZoom` / `ctx.stillMotion`); only earlier auto-generated regions
 * are replaced — manual blocks stay put. */
const opAutoZoom: EditCore = (project, args, ctx) => {
  // Image captures have no cursor data — route to Motion: the four-corner
  // cinematic tour the editor's Motion entry generates.
  if (project.cursorDataURL === null && isImageCapture(project)) {
    const created = ctx.stillMotion(project);
    if (!(created > 0)) throw new ToolError("could not compose a motion tour for this image");
    return { created, mode: "still-motion" };
  }
  if (project.cursorDataURL === null) {
    throw new ToolError(
      "project has no recorded cursor data to generate zooms from — place zooms by hand with add_effect",
    );
  }
  const created = ctx.autoZoom(project, doubleValue(args.zoomLevel));
  if (!(created > 0)) {
    throw new ToolError(
      "no zoom-worthy activity found in the recorded cursor data " +
        "(auto_zoom needs 2+ clicks close together, a typing burst or a dwell)",
    );
  }
  const auto = project.zoomRegions.filter((r) => r.isAuto === true);
  return {
    created,
    zoomRegions: auto.map((r) => ({
      id: r.id.toUpperCase(),
      start: round3(r.startTime),
      end: round3(r.endTime),
      zoomLevel: round3(r.zoomLevel),
      focalPoint: { x: round3(r.focalPoint.x), y: round3(r.focalPoint.y) },
    })),
  };
};

// ── Annotations ───────────────────────────────────────────────────────────

const ANNOTATION_TYPES = enumValues(AnnotationTypeValues);
const ANNOTATION_EFFECTS = enumValues(AnnotationEffectValues);
export const SCRIPTABLE_ANNOTATION_TYPES: readonly AnnotationType[] = ANNOTATION_TYPES.filter((t) => t !== "drawing");

/**
 * `Annotation.applyNewAnnotationDefaults()` — per-type starting look for a
 * NEW annotation, shared by the editor's toolbar add and add_annotation.
 */
export function applyNewAnnotationDefaults(a: Annotation): void {
  switch (a.type) {
    case "text":
      a.text = "Label";
      break;
    case "arrow":
      a.x = 0.35;
      a.y = 0.45;
      a.arrowEndX = 0.55;
      a.arrowEndY = 0.55;
      break;
    case "rectangle":
    case "ellipse":
      a.x = 0.35;
      a.y = 0.375;
      a.arrowEndX = 0.65;
      a.arrowEndY = 0.625;
      a.color = { ...DEFAULT_COLORS.white };
      a.backgroundColor = { red: 1, green: 1, blue: 1, opacity: 0.25 };
      a.showBackground = false;
      a.lineWidth = 4;
      break;
    case "tap":
      a.x = 0.5;
      a.y = 0.5;
      a.fontSize = 60; // reused as ripple size for taps
      break;
    case "callout":
      a.x = 0.4;
      a.y = 0.3;
      a.arrowEndX = 0.55;
      a.arrowEndY = 0.5;
      a.text = "Look here";
      break;
    case "drawing":
      a.enterEffect = "Fade";
      a.exitEffect = "Fade";
      break;
  }
}

/** Field patch shared by add_annotation and update_annotation — one set of
 * ranges (the inspector's) for both. */
function applyAnnotationFields(args: JSONObject, annotation: Annotation): void {
  const x = doubleValue(args.x);
  if (x !== null) annotation.x = clamp01(x);
  const y = doubleValue(args.y);
  if (y !== null) annotation.y = clamp01(y);
  const ex = doubleValue(args.arrowEndX);
  if (ex !== null) annotation.arrowEndX = clamp01(ex);
  const ey = doubleValue(args.arrowEndY);
  if (ey !== null) annotation.arrowEndY = clamp01(ey);
  if (has(args, "text")) {
    const text = stringValue(args.text);
    if (text === null) throw new ToolError("text must be a string (max 200 chars)");
    annotation.text = prefixChars(text, 200);
  }
  if (has(args, "color")) {
    const hex = stringValue(args.color);
    const parsed = hex === null ? null : parseHexColor(hex);
    if (parsed === null) throw new ToolError('color must be a hex string, e.g. "#FF3B30" (RRGGBB or RRGGBBAA)');
    annotation.color = parsed;
  }
  if (has(args, "backgroundColor")) {
    const hex = stringValue(args.backgroundColor);
    const parsed = hex === null ? null : parseHexColor(hex);
    if (parsed === null) {
      throw new ToolError('backgroundColor must be a hex string, e.g. "#000000B3" (RRGGBB or RRGGBBAA)');
    }
    annotation.backgroundColor = parsed;
  }
  const show = boolValue(args.showBackground);
  if (show !== null) annotation.showBackground = show;
  const backdrop = doubleValue(args.backdropOpacity);
  if (backdrop !== null) annotation.backdropOpacity = smin(0.9, smax(0, backdrop));
  const size = doubleValue(args.fontSize);
  if (size !== null) {
    // Taps reuse fontSize as the ripple size (inspector: 20…120).
    annotation.fontSize = annotation.type === "tap" ? smin(120, smax(20, size)) : smin(72, smax(10, size));
  }
  const opacity = doubleValue(args.opacity);
  if (opacity !== null) annotation.opacity = smin(1, smax(0.2, opacity));
  const width = doubleValue(args.lineWidth);
  if (width !== null) annotation.lineWidth = smin(12, smax(0, width));
  for (const key of ["enterEffect", "exitEffect"] as const) {
    if (!has(args, key)) continue;
    const raw = args[key];
    const effect = stringValue(raw);
    if (effect === null || !(ANNOTATION_EFFECTS as readonly string[]).includes(effect)) {
      throw new ToolError(
        `invalid ${key}: ${describeValue(raw)} (allowed: ` + ANNOTATION_EFFECTS.map((e) => `"${e}"`).join(", ") + ")",
      );
    }
    annotation[key] = effect as AnnotationEffect;
  }
}

const opAddAnnotation: EditCore = (project, args, ctx) => {
  const typeRaw = stringValue(args.type);
  if (typeRaw === null || !(SCRIPTABLE_ANNOTATION_TYPES as readonly string[]).includes(typeRaw)) {
    throw new ToolError(
      "type must be one of: " +
        SCRIPTABLE_ANNOTATION_TYPES.join(", ") +
        " (drawing/freehand strokes are editor-only — not scriptable)",
    );
  }
  const type = typeRaw as AnnotationType;
  const [start, end] = requiredSpan(args, project, "add_annotation");
  const annotation = newAnnotation(type, start, end, ctx.newId());
  applyNewAnnotationDefaults(annotation);
  applyAnnotationFields(args, annotation);
  project.annotations.push(annotation);
  return { created: annotation.id.toUpperCase(), type };
};

const ANNOTATION_ID_HINT = "from add_annotation's 'created' or describe_project's annotations[].id";

const opUpdateAnnotation: EditCore = (project, args) => {
  const annID = uuidArgument(args, "annotationId", ANNOTATION_ID_HINT);
  const index = project.annotations.findIndex((a) => sameId(a.id, annID));
  if (index < 0) {
    throw new ToolError(`no annotation with id ${annID} — describe_project lists annotations with ids`);
  }
  // Swift edits a copy and writes it back (a throw leaves the original).
  const annotation: Annotation = { ...project.annotations[index] };
  const rawType = stringValue(args.type);
  if (rawType !== null && rawType !== annotation.type) {
    throw new ToolError(
      `an annotation's type can't change (it is ${annotation.type}) — ` + "remove_annotation and add_annotation instead",
    );
  }
  const start = doubleValue(args.start) ?? annotation.startTime;
  const end = doubleValue(args.end) ?? annotation.endTime;
  if (has(args, "start") || has(args, "end")) validateSpan(start, end, project, "update_annotation");
  annotation.startTime = start;
  annotation.endTime = end;
  applyAnnotationFields(args, annotation);
  project.annotations[index] = annotation;
  return { updated: annID, span: { start: round3(start), end: round3(end) } };
};

const opRemoveAnnotation: EditCore = (project, args) => {
  const annID = uuidArgument(args, "annotationId", ANNOTATION_ID_HINT);
  const before = project.annotations.length;
  project.annotations = project.annotations.filter((a) => !sameId(a.id, annID));
  if (!(project.annotations.length < before)) {
    throw new ToolError(`no annotation with id ${annID} — describe_project lists annotations with ids`);
  }
  return { removed: 1 };
};

// ── Privacy blur (FOCUS lane) ─────────────────────────────────────────────

const BLUR_STYLES = enumValues(BlurStyleValues);

/** Mirrors the editor: BlurRegion's model defaults (rect, intensity 0.6,
 * style Blur), the style-derived label, the inspector's strength range
 * (0.1…1), the canvas' minimum rect side (0.04) and the FOCUS lane's
 * no-overlap + 0.8s slot minimum. */
const opAddBlur: EditCore = (project, args, ctx) => {
  const [start, end] = requiredSpan(args, project, "add_blur");
  if (!(end - start >= 0.8 - 0.0001)) {
    throw new ToolError(
      `add_blur: span ${fmt(start)}–${fmt(end)} is shorter than 0.8s, the editor's minimum ` +
        "region length — extend it (a blur should cover the whole time the secret is visible)",
    );
  }
  let style: BlurStyle = "Blur";
  if (has(args, "style")) {
    const parsed = stringValue(args.style);
    if (parsed === null || !(BLUR_STYLES as readonly string[]).includes(parsed)) {
      throw new ToolError(
        `invalid style: ${describeValue(args.style)} (allowed: ` + BLUR_STYLES.map((s) => `"${s}"`).join(", ") + ")",
      );
    }
    style = parsed as BlurStyle;
  }
  const defaults = newBlurRegion(start, end, "00000000-0000-0000-0000-000000000000");
  const x = doubleValue(args.x) ?? defaults.rect.x;
  const y = doubleValue(args.y) ?? defaults.rect.y;
  const width = doubleValue(args.width) ?? Math.abs(defaults.rect.width);
  const height = doubleValue(args.height) ?? Math.abs(defaults.rect.height);
  const minSide = 0.04;
  if (!(x >= 0 && y >= 0 && width >= minSide && height >= minSide && x + width <= 1.0001 && y + height <= 1.0001)) {
    throw new ToolError(
      `add_blur: rect x=${fmt(x)} y=${fmt(y)} width=${fmt(width)} height=${fmt(height)} is ` +
        "invalid — x/y/width/height are normalized 0–1 fractions of the video frame (Y-down, not pixels), " +
        `width/height >= ${swiftDoubleDescription(minSide)}, and the rect must stay inside the frame ` +
        "(x+width <= 1, y+height <= 1)",
    );
  }
  let intensity = defaults.intensity;
  if (has(args, "intensity")) {
    const v = doubleValue(args.intensity);
    if (v === null || !(v >= 0.1 && v <= 1)) {
      throw new ToolError("intensity must be a number in 0.1...1 (the editor's Strength slider)");
    }
    intensity = v;
  }
  // Lane check last: argument mistakes (pixels, bad style) first.
  const conflict = focusLaneConflict(project, start, end);
  if (conflict) throw new ToolError(conflict);
  const label = stringValue(args.label);
  const region: BlurRegion = {
    id: ctx.newId(),
    startTime: start,
    endTime: end,
    label: label !== null ? prefixChars(label, 60) : style === "Pixelate" ? "Pixelate" : "Blur",
    rect: { x, y, width: smin(width, 1 - x), height: smin(height, 1 - y) },
    intensity,
    style,
    animated: boolValue(args.animated) ?? false,
  };
  project.blurRegions.push(region);
  return { created: region.id.toUpperCase(), style };
};

const opRemoveBlur: EditCore = (project, args) => {
  const blurID = uuidArgument(args, "blurId", "from add_blur's 'created' or describe_project's blurRegions[].id");
  const before = project.blurRegions.length;
  project.blurRegions = project.blurRegions.filter((r) => !sameId(r.id, blurID));
  if (!(project.blurRegions.length < before)) {
    throw new ToolError(`no blur region with id ${blurID} — describe_project lists blurRegions with ids`);
  }
  return { removed: 1 };
};

// ── Speed regions ─────────────────────────────────────────────────────────

/** `TimelineVideoRowModel.speedPresets` — the editor's speed menu. */
export const SPEED_PRESETS: readonly number[] = [0.5, 0.75, 1.2, 1.4, 1.6, 1.8, 2.0, 3.0, 4.0];
const SPEED_MIN = Math.min(...SPEED_PRESETS);
const SPEED_MAX = Math.max(...SPEED_PRESETS);

function speedResult(project: Project, region: VideoSpeedRegion, action: string, before: number | null): JSONObject {
  const result: JSONObject = {
    [action]: {
      id: region.id.toUpperCase(),
      start: round3(region.startTime),
      end: round3(region.endTime),
      speed: region.speed,
    },
  };
  const output = outputDurationEntry(before, project);
  if (output) result.outputDuration = output;
  return result;
}

/** Mirrors the editor's speed rules: regions live on SOURCE spans inside the
 * recording, never overlap each other, are at least 0.8s long, and a pick on
 * an existing region changes its speed in place. */
const opSetSpeed: EditCore = (project, args, ctx) => {
  const range = `${formatNumber(SPEED_MIN)}...${formatNumber(SPEED_MAX)}`;
  const speed = doubleValue(args.speed);
  if (speed === null || !Number.isFinite(speed)) {
    throw new ToolError(
      `speed is required: a multiplier in ${range} (editor presets: ` + SPEED_PRESETS.map(formatNumber).join(", ") + ")",
    );
  }
  if (!(speed >= SPEED_MIN && speed <= SPEED_MAX)) {
    throw new ToolError(`speed ${fmt(speed)} is outside ${range} (the editor's range)`);
  }
  if (!(Math.abs(speed - 1) > 0.01)) {
    throw new ToolError("speed 1.0 is normal playback — use remove_speed to clear a region instead");
  }
  const [start, end] = requiredSpan(args, project, "set_speed");
  const before = outputDuration(project);
  const tolerance = 0.01;

  const existing = project.speedRegions.find(
    (r) => Math.abs(r.startTime - start) < tolerance && Math.abs(r.endTime - end) < tolerance,
  );
  if (existing) {
    existing.speed = speed;
    return speedResult(project, existing, "changed", before);
  }
  if (!(end - start >= 0.8 - 0.0001)) {
    throw new ToolError(
      `set_speed: span ${fmt(start)}–${fmt(end)} is shorter than 0.8s, the editor's minimum ` +
        "speed-region length — widen it",
    );
  }
  const epsilon = 0.0001;
  const overlapping = project.speedRegions.filter((r) => start < r.endTime - epsilon && end > r.startTime + epsilon);
  if (overlapping.length > 0) {
    const list = overlapping
      .map((r) => `${r.id.toUpperCase()} (${fmt(r.startTime)}–${fmt(r.endTime)} at ${formatNumber(r.speed)}×)`)
      .join(", ");
    throw new ToolError(
      `set_speed: span ${fmt(start)}–${fmt(end)} overlaps speed region(s) ${list}. Speed regions ` +
        "never overlap: pass that region's exact start/end to change its speed, remove_speed it first, " +
        "or pick a span outside it.",
    );
  }
  const region: VideoSpeedRegion = { id: ctx.newId(), startTime: start, endTime: end, speed };
  project.speedRegions.push(region);
  const result = speedResult(project, region, "created", before);
  const trimStart = effectiveTrimStart(project);
  const trimEnd = effectiveTrimEnd(project);
  if (start < trimStart - 0.001 || end > trimEnd + 0.001) {
    result.note =
      "part of this span lies outside the trim window " +
      `(${fmt(trimStart)}–${fmt(trimEnd)}); only the part inside it plays`;
  }
  return result;
};

const opRemoveSpeed: EditCore = (project, args) => {
  const before = outputDuration(project);
  let removed: VideoSpeedRegion[];
  if (boolValue(args.all) === true) {
    removed = project.speedRegions;
    project.speedRegions = [];
  } else if (has(args, "speedId")) {
    const id = uuidValue(args.speedId);
    if (id === null) throw new ToolError("speedId must be a UUID string (describe_project's speedRegions[].id)");
    removed = project.speedRegions.filter((r) => sameId(r.id, id));
    project.speedRegions = project.speedRegions.filter((r) => !sameId(r.id, id));
  } else if (doubleValue(args.at) !== null) {
    const at = doubleValue(args.at)!;
    const hit = (r: VideoSpeedRegion) => at >= r.startTime && at <= r.endTime;
    removed = project.speedRegions.filter(hit);
    project.speedRegions = project.speedRegions.filter((r) => !hit(r));
  } else {
    throw new ToolError(
      "remove_speed needs one of: speedId (UUID), at (a SOURCE time inside the region), or all: true",
    );
  }
  if (removed.length === 0) {
    throw new ToolError("no matching speed region — describe_project lists speedRegions with ids and spans");
  }
  const result: JSONObject = { removed: removed.map((r) => r.id.toUpperCase()) };
  const output = outputDurationEntry(before, project);
  if (output) result.outputDuration = output;
  return result;
};

// ── Trim ──────────────────────────────────────────────────────────────────

/** Mirrors the editor's whole-track trim: 0 <= start, end <= duration and at
 * least 0.5s kept. Refuses a window that would hide every visible clip. */
const opSetTrim: EditCore = (project, args) => {
  if (!(project.duration > 0)) {
    throw new ToolError("this project has no probed duration yet — open it once in CaptureCat, then retry");
  }
  const before = outputDuration(project);
  const previous = [project.trimStart, project.trimEnd] as const;
  if (boolValue(args.reset) === true) {
    project.trimStart = 0;
    project.trimEnd = 0;
  } else {
    if (!has(args, "start") && !has(args, "end")) {
      throw new ToolError(
        "set_trim needs start and/or end (SOURCE seconds), or reset: true for the full recording",
      );
    }
    const start = doubleValue(args.start) ?? effectiveTrimStart(project);
    const end = doubleValue(args.end) ?? effectiveTrimEnd(project);
    if (!(start >= 0 && end <= project.duration + 0.001 && Number.isFinite(start) && Number.isFinite(end))) {
      throw new ToolError(
        `set_trim: ${fmt(start)}–${fmt(end)} must lie within 0–${fmt(project.duration)} ` +
          "(SOURCE seconds of the original recording)",
      );
    }
    if (!(end - start >= 0.5)) {
      throw new ToolError(`set_trim: keep at least 0.5s (the editor's minimum); got ${fmt(start)}–${fmt(end)}`);
    }
    project.trimStart = start;
    project.trimEnd = smin(end, project.duration);
  }
  const clips = effectiveVideoClipSegments(project);
  if (clips.length === 0) {
    const window = `${fmt(effectiveTrimStart(project))}–${fmt(effectiveTrimEnd(project))}`;
    project.trimStart = previous[0];
    project.trimEnd = previous[1];
    throw new ToolError(
      `set_trim: the window ${window} contains no visible video clip (cut_video removed that ` +
        "footage) — describe_project lists clips; pick a window that overlaps one",
    );
  }
  const result: JSONObject = {
    trim: { start: round3(effectiveTrimStart(project)), end: round3(effectiveTrimEnd(project)) },
    clips: clips.map((c) => ({ start: round3(c.startTime), end: round3(c.endTime) })),
    note:
      "Effects keep their SOURCE times; only the OUTPUT timeline shifts " +
      `(output 0 = source ${fmt(effectiveTrimStart(project))}).`,
  };
  const output = outputDurationEntry(before, project);
  if (output) result.outputDuration = output;
  return result;
};

// ── Cut ───────────────────────────────────────────────────────────────────

/** Removes SOURCE ranges from the video lane — the editor's delete-clip write
 * (materialise effectiveVideoClipSegments, subtract, re-derive splitPoints).
 * NOT a ripple delete: the span renders as background-only. */
const opCutVideo: EditCore = (project, args, ctx) => {
  const rawRanges = objectArrayValue(args.ranges);
  if (rawRanges === null || rawRanges.length === 0) {
    throw new ToolError(
      "ranges must be a non-empty array of {start, end} in SOURCE seconds " +
        "(get_transcript returns sourceStart/sourceEnd per segment and per word)",
    );
  }
  const ranges = rawRanges.map((entry): [number, number] => {
    const start = doubleValue(entry.start);
    const end = doubleValue(entry.end);
    if (start === null || end === null || !(end > start) || !(start >= 0)) {
      throw new ToolError("each range needs start >= 0 and end > start (SOURCE seconds)");
    }
    return [start, end];
  });

  // Mirror the editor's minimum-clip hygiene: ignore slivers < 0.05s.
  const minPiece = 0.05;
  let clips: VideoClipSegment[] = effectiveVideoClipSegments(project);
  for (const [rangeStart, rangeEnd] of ranges) {
    clips = clips.flatMap((clip) => {
      if (!(rangeEnd > clip.startTime + minPiece && rangeStart < clip.endTime - minPiece)) return [clip];
      const pieces: VideoClipSegment[] = [];
      if (rangeStart > clip.startTime + minPiece) {
        pieces.push({ id: ctx.newId(), startTime: clip.startTime, endTime: rangeStart });
      }
      if (rangeEnd < clip.endTime - minPiece) {
        pieces.push({ id: ctx.newId(), startTime: rangeEnd, endTime: clip.endTime });
      }
      return pieces;
    });
  }
  if (clips.length === 0) {
    throw new ToolError("removing these ranges would leave no video at all — remove fewer ranges");
  }

  const span = (xs: VideoClipSegment[]) => xs.reduce((sum, c) => sum + (c.endTime - c.startTime), 0);
  const removed = span(effectiveVideoClipSegments(project)) - span(clips);
  // A range that misses every clip must not report success.
  if (!(removed > 0.001)) {
    throw new ToolError(
      "ranges removed nothing — they fall in already-cut spans, outside the " +
        "video lane, or are shorter than 0.1s. Check clip bounds via describe_project.",
    );
  }
  project.videoClipSegments = clips;
  project.splitPoints = sortNumbers(clips.slice(1).map((c) => c.startTime));

  return {
    clips: clips.map((c) => ({ start: round3(c.startTime), end: round3(c.endTime) })),
    removedSeconds: round3(removed),
    note:
      "The removed spans show the background only — the video is NOT shorter (no ripple). " +
      "To shorten, use set_trim (head/tail) or set_speed (middle). Check with render_frames.",
  };
};

// ── Style ─────────────────────────────────────────────────────────────────

/** Swift `String <` — Unicode scalar order of the canonical (NFC) form. */
function swiftStringCompare(a: string, b: string): number {
  const x = Array.from(a.normalize("NFC"), (c) => c.codePointAt(0)!);
  const y = Array.from(b.normalize("NFC"), (c) => c.codePointAt(0)!);
  for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] - y[i];
  return x.length - y.length;
}

const opSetStyle: EditCore = (project, args) => {
  const patch = objectValue(args.patch);
  const keys = patch ? Object.keys(patch).filter((k) => patch[k] !== undefined) : [];
  if (!patch || keys.length === 0) {
    throw new ToolError(
      'patch must be a non-empty object of settings, e.g. {"backgroundPadding": 64} ' + "— style_options lists every key",
    );
  }
  const applied: JSONObject = {};
  for (const key of keys.sort(swiftStringCompare)) {
    applyStyle(key, patch[key], project.settings);
    applied[key] = patch[key];
  }
  return { applied };
};

// ── Registry + batch runner ───────────────────────────────────────────────

/** Batchable ops, in schema order. */
export const EDIT_OP_NAMES: readonly string[] = [
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
];

export const EDIT_OPS: Readonly<Record<string, EditCore>> = Object.freeze({
  add_effect: opAddEffect,
  update_effect: opUpdateEffect,
  remove_effect: opRemoveEffect,
  auto_zoom: opAutoZoom,
  add_annotation: opAddAnnotation,
  update_annotation: opUpdateAnnotation,
  remove_annotation: opRemoveAnnotation,
  add_blur: opAddBlur,
  remove_blur: opRemoveBlur,
  set_speed: opSetSpeed,
  remove_speed: opRemoveSpeed,
  set_trim: opSetTrim,
  cut_video: opCutVideo,
  set_style: opSetStyle,
});

/** The edit core for a tool name, or null (own keys only). */
export function editCore(name: string): EditCore | null {
  return Object.prototype.hasOwnProperty.call(EDIT_OPS, name) ? EDIT_OPS[name] : null;
}

/**
 * `MCPServer.applyEdits` minus the load/commit: ordered ops against ONE
 * draft. Throws a ToolError with the exact Swift message on the first
 * failure — the caller discards the draft (all-or-nothing). `rawOps` is the
 * tool's `ops` argument as received.
 */
export function applyEditsBatch(project: Project, rawOps: unknown, ctx: OpContext): JSONObject {
  const ops = arrayValue(rawOps);
  if (ops === null || ops.length === 0) {
    throw new ToolError(
      "ops must be a non-empty array of {op, args} — e.g. " +
        '[{"op": "add_effect", "args": {"type": "zoom", "start": 2, "end": 5}}]',
    );
  }
  if (ops.length > 200) {
    throw new ToolError(`at most 200 ops per apply_edits call (got ${ops.length}) — split the batch`);
  }
  const outputBefore = outputDuration(project);

  const results: JSONObject[] = [];
  ops.forEach((raw, index) => {
    const entry = objectValue(raw);
    const name = entry ? stringValue(entry.op) : null;
    if (entry === null || name === null) {
      throw new ToolError(
        `apply_edits: ops[${index}] must be an object {"op": <tool name>, ` + '"args": {...}}. Nothing was written.',
      );
    }
    const core = editCore(name);
    if (!core) {
      throw new ToolError(
        `apply_edits: ops[${index}] op '${name}' is not batchable (allowed: ` +
          EDIT_OP_NAMES.join(", ") +
          "). Nothing was written.",
      );
    }
    // `args` is the tool's own arguments minus `id`; a flat {op, ...fields}
    // entry is accepted too.
    const nested = objectValue(entry.args);
    const args: JSONObject = nested ? { ...nested } : { ...entry };
    if (!nested) delete args.op;
    delete args.id;
    let result: JSONObject;
    try {
      result = core(project, args, ctx);
    } catch (error) {
      throw new ToolError(
        `apply_edits: ops[${index}] (${name}) failed — ${errorMessage(error)} ` +
          "Nothing was written (the batch is all-or-nothing): fix that op and resend the whole batch.",
      );
    }
    results.push({ index, op: name, result });
  });

  const response: JSONObject = { applied: results.length, results };
  const output = outputDurationEntry(outputBefore, project);
  if (output) response.outputDuration = output;
  return response;
}

/** The undo-history summary the Mac records for a committed edit
 * (`commitEdit(… summary:)`): the tool name, or "apply_edits: a, b, …". */
export function editSummary(tool: string, result: JSONObject): string {
  if (tool !== "apply_edits") return tool;
  const names = Array.isArray(result.results) ? result.results.map((r) => (r as JSONObject).op as string) : [];
  return "apply_edits: " + names.join(", ");
}
