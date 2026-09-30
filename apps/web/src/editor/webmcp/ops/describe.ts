/**
 * Ports of the read-only MCP payloads:
 *
 * - `describeProject` — MCPServer+Analysis.swift `describeProject` with its
 *   evidence digests (click clusters + idle spans from the cursor stream,
 *   silence spans, and their intersection: quiet spans).
 * - `analyzeSilence` — the RMS silence scan (`computeSilence`) over mono
 *   8 kHz float samples. The Mac decodes the audio with AVAssetReader; the
 *   browser decodes/resamples itself and hands the samples here.
 * - `getTranscript` / `transcriptPayload` — MCPServer.getTranscript over
 *   ShareIntelligence.transcriptPayload(includeSourceTimes: true).
 * - `timelineCounts` — the undo tool's before/after summary.
 *
 * Every span is SOURCE seconds unless a key says OUTPUT.
 */
import type {
  Annotation,
  CursorEvent,
  KeystrokeEvent,
  Project,
  Rect,
  Size,
} from "../../core/model/types";
import { isImageCapture } from "../../core/model/helpers";
import { chypot, smax, smin } from "../../core/math/swift";
import { effectiveTrimEnd, effectiveTrimStart, effectiveVideoClipSegments } from "../../core/time/clips";
import { transcriptPayload as corePayload } from "../../core/transcript";
import { outputDuration } from "./edits";
import { round3 } from "./json";
import { hexString } from "./style";
import type { JSONObject } from "./types";

// ── Inputs the Mac reads from disk ────────────────────────────────────────

export interface TimeSpan {
  start: number;
  end: number;
}

/** `MCPServer.SilenceAnalysis` */
export interface SilenceAnalysis {
  spans: TimeSpan[];
  thresholdDb: number;
  noiseFloorDb: number;
  trackCount: number;
}

/** `MCPServer.SilenceOutcome` */
export type SilenceOutcome =
  | { kind: "analyzed"; analysis: SilenceAnalysis }
  | { kind: "noAudio" }
  | { kind: "failed"; reason: string };

export interface DescribeInputs {
  /** cursor.json events; null (or empty) when the project has no readable
   * cursor recording — then there is no interactionDigest and no quietSpans. */
  cursor: readonly CursorEvent[] | null;
  /** cursor.json `coordinateWidth/Height`; null or 0×0 for the legacy
   * bare-array format (Swift then uses 1×1). */
  screenSize: Size | null;
  /** keys.json events (keystrokes + scroll ticks); [] when there is none. */
  keystrokes: readonly KeystrokeEvent[];
  /**
   * The recording's silence analysis. null/undefined = the recording file is
   * unavailable (Swift: `videoURL` missing on disk) — describe then carries
   * no `audio` / `silenceSpans` / `quietSpans` at all.
   */
  silence?: SilenceOutcome | null;
}

// ── describe_project ──────────────────────────────────────────────────────

const byStart = <T extends { startTime: number }>(xs: readonly T[]): T[] =>
  [...xs].sort((a, b) => (a.startTime < b.startTime ? -1 : b.startTime < a.startTime ? 1 : 0));

/** `MCPServer.rectPayload` (CGRect.width/height are standardized → abs). */
export function rectPayload(rect: Rect): JSONObject {
  return {
    x: round3(rect.x),
    y: round3(rect.y),
    width: round3(Math.abs(rect.width)),
    height: round3(Math.abs(rect.height)),
  };
}

/** `MCPServer.annotationPayload` */
export function annotationPayload(a: Annotation): JSONObject {
  const entry: JSONObject = {
    id: a.id.toUpperCase(),
    type: a.type,
    start: round3(a.startTime),
    end: round3(a.endTime),
    x: round3(a.x),
    y: round3(a.y),
    color: hexString(a.color),
  };
  if (a.type === "arrow" || a.type === "rectangle" || a.type === "ellipse" || a.type === "callout") {
    entry.arrowEndX = round3(a.arrowEndX);
    entry.arrowEndY = round3(a.arrowEndY);
  }
  if (a.type === "text" || a.type === "callout") entry.text = a.text;
  if (a.type === "drawing") entry.strokes = a.drawingStrokes.length;
  if (a.backdropOpacity > 0) entry.backdropOpacity = round3(a.backdropOpacity);
  return entry;
}

/** `MCPServer.describeProject` minus the load: the describe_project payload. */
export function describeProject(project: Project, inputs: DescribeInputs): JSONObject {
  const s = project.settings;
  const id = (value: string) => value.toUpperCase();
  const result: JSONObject = {
    id: id(project.id),
    name: project.name,
    clock:
      "Every start/end/at here is SOURCE seconds (original recording) — the clock all edit " +
      "tools take. render_frames and get_transcript start/end use OUTPUT seconds (after trim + speed).",
    duration: round3(project.duration),
    trimStart: round3(project.trimStart),
    trimEnd: round3(project.trimEnd),
    trim: { start: round3(effectiveTrimStart(project)), end: round3(effectiveTrimEnd(project)) },
    recordingSourceKind: project.recordingSourceKind,
    isImageCapture: isImageCapture(project),
    clips: effectiveVideoClipSegments(project).map((c) => ({
      id: id(c.id),
      start: round3(c.startTime),
      end: round3(c.endTime),
    })),
    splitPoints: project.splitPoints.map(round3),
    effects: {
      zoomRegions: byStart(project.zoomRegions).map((zoom) => {
        const entry: JSONObject = {
          id: id(zoom.id),
          start: round3(zoom.startTime),
          end: round3(zoom.endTime),
          zoomLevel: round3(zoom.zoomLevel),
          focalPoint: { x: round3(zoom.focalPoint.x), y: round3(zoom.focalPoint.y) },
        };
        if (zoom.animationStyle !== undefined) entry.animationStyle = zoom.animationStyle;
        if (zoom.followsCursor === false) entry.followsCursor = false;
        if (zoom.cardOffsetX !== undefined) entry.offsetX = round3(zoom.cardOffsetX);
        if (zoom.cardOffsetY !== undefined) entry.offsetY = round3(zoom.cardOffsetY);
        if (zoom.isAuto === true) entry.auto = true;
        return entry;
      }),
      tiltRegions: byStart(project.tiltRegions).map((tilt) => {
        const entry: JSONObject = {
          id: id(tilt.id),
          start: round3(tilt.startTime),
          end: round3(tilt.endTime),
          pitch: round3(tilt.pitch),
          yaw: round3(tilt.yaw),
          roll: round3(tilt.roll),
        };
        if (tilt.animationStyle !== undefined) entry.animationStyle = tilt.animationStyle;
        return entry;
      }),
    },
    annotations: byStart(project.annotations).map(annotationPayload),
    blurRegions: byStart(project.blurRegions).map((blur) => {
      const entry: JSONObject = {
        id: id(blur.id),
        start: round3(blur.startTime),
        end: round3(blur.endTime),
        rect: rectPayload(blur.rect),
        style: blur.style,
        intensity: round3(blur.intensity),
      };
      if (blur.animated) entry.animated = true;
      return entry;
    }),
    highlightRegions: byStart(project.highlightRegions).map((highlight) => ({
      id: id(highlight.id),
      start: round3(highlight.startTime),
      end: round3(highlight.endTime),
      rect: rectPayload(highlight.rect),
      opacity: round3(highlight.opacity),
      label: highlight.label,
    })),
    speedRegions: byStart(project.speedRegions).map((r) => ({
      id: id(r.id),
      start: round3(r.startTime),
      end: round3(r.endTime),
      speed: r.speed,
    })),
    subtitles: { count: project.subtitles.length, showSubtitles: s.showSubtitles },
    settings: {
      aspectRatio: s.aspectRatio,
      backgroundType: s.backgroundType,
      backgroundPadding: s.backgroundPadding,
      backgroundBlur: s.backgroundBlur,
      videoPlacement: s.videoPlacement,
      cornerRadius: s.cornerRadius,
      shadowRadius: s.shadowRadius,
      cursorStyle: s.cursorStyle,
      cursorScale: s.cursorScale,
      showCursor: s.showCursor,
      showClickRipple: s.showClickRipple,
      animationSpeed: s.animationSpeed,
      autoZoomLevel: s.autoZoomLevel,
      menuBarReplacement: s.menuBarReplacement,
      showDeviceFrame: s.showDeviceFrame,
      showCamera: s.showCamera,
      muteRecordedAudio: s.muteRecordedAudio,
    },
    settingsNote: "Key settings only — style_options lists every set_style key with its current value.",
  };
  const output = outputDuration(project);
  if (output !== null) result.outputDuration = round3(output);
  // FOCUS-lane occupants the agent can't edit but must route around.
  const otherFocus: JSONObject[] = [
    ...project.focusRegions.map((r) => ({
      kind: "depth-focus",
      id: id(r.id),
      start: round3(r.startTime),
      end: round3(r.endTime),
    })),
    ...project.cameraLayoutRegions.map((r) => ({
      kind: `camera-layout:${r.mode}`,
      id: id(r.id),
      start: round3(r.startTime),
      end: round3(r.endTime),
    })),
  ];
  if (otherFocus.length > 0) result.otherFocusLaneRegions = otherFocus;
  if (project.voiceOverClips.length > 0) result.voiceOverClips = project.voiceOverClips.length;

  const activity = cursorActivity(inputs.cursor, inputs.screenSize);
  if (activity) result.interactionDigest = interactionDigest(activity);
  result.pacing = pacingDigest(project, activity, inputs.silence ?? null, inputs.keystrokes);
  return result;
}

// ── Cursor activity ───────────────────────────────────────────────────────

/** `MCPServer.CursorActivity` */
export interface CursorActivity {
  events: readonly CursorEvent[];
  coordinateSize: Size;
  clicks: CursorEvent[];
  /** >3s without meaningful movement (5pt) or clicks. */
  idleSpans: TimeSpan[];
}

/** `MCPServer.cursorActivity` — the discrete-click collapse (mouse-down runs →
 * one click; drags dropped) plus the idle-span scan. */
export function cursorActivity(events: readonly CursorEvent[] | null, screenSize: Size | null): CursorActivity | null {
  if (!events || events.length === 0) return null;
  const coordW = smax(1, screenSize?.width ?? 0);
  const coordH = smax(1, screenSize?.height ?? 0);

  const shortSide = smin(coordW, coordH);
  const dragThreshold = smax(10, smin(24, shortSide * 0.006));
  const clicks: CursorEvent[] = [];
  let runStart: CursorEvent | null = null;
  let maxDist = 0;
  const finishRun = () => {
    if (runStart !== null && maxDist <= dragThreshold) clicks.push(runStart);
    runStart = null;
    maxDist = 0;
  };
  for (const event of events) {
    if (event.isClick) {
      if (runStart !== null) {
        maxDist = smax(maxDist, chypot(event.x - runStart.x, event.y - runStart.y));
      } else {
        runStart = event;
        maxDist = 0;
      }
    } else {
      finishRun();
    }
  }
  finishRun();

  const idleSpans: TimeSpan[] = [];
  let idleStart = events[0].timestamp;
  let lastPos = events[0];
  for (const event of events) {
    if (chypot(event.x - lastPos.x, event.y - lastPos.y) > 5 || event.isClick) {
      if (event.timestamp - idleStart > 3.0) idleSpans.push({ start: idleStart, end: event.timestamp });
      idleStart = event.timestamp;
      lastPos = event;
    }
  }
  const last = events[events.length - 1];
  if (last.timestamp - idleStart > 3.0) idleSpans.push({ start: idleStart, end: last.timestamp });
  return { events, coordinateSize: { width: coordW, height: coordH }, clicks, idleSpans };
}

/** `MCPServer.interactionDigest` — click clusters (2s gaps) + idle spans. */
export function interactionDigest(activity: CursorActivity): JSONObject {
  const clusters: { start: number; end: number; count: number; sumX: number; sumY: number }[] = [];
  for (const click of activity.clicks) {
    const last = clusters[clusters.length - 1];
    if (last && click.timestamp - last.end <= 2.0) {
      last.end = click.timestamp;
      last.count += 1;
      last.sumX += click.x;
      last.sumY += click.y;
    } else {
      clusters.push({ start: click.timestamp, end: click.timestamp, count: 1, sumX: click.x, sumY: click.y });
    }
  }
  const coordW = activity.coordinateSize.width;
  const coordH = activity.coordinateSize.height;
  return {
    totalEvents: activity.events.length,
    coordinateSize: { width: coordW, height: coordH },
    clickClusters: clusters.map((c) => ({
      start: round3(c.start),
      end: round3(c.end),
      clickCount: c.count,
      meanPosition: { x: round3(c.sumX / c.count / coordW), y: round3(c.sumY / c.count / coordH) },
    })),
    idleSpans: activity.idleSpans.map((s) => ({ start: round3(s.start), end: round3(s.end) })),
  };
}

// ── Pacing ────────────────────────────────────────────────────────────────

const PACING_HINT =
  "quietSpans = no cursor movement, no clicks/keys/scrolls AND no sound — the safest " +
  "set_speed candidates (2–4×); still glance at them (a page may be loading). " +
  "interactionDigest.idleSpans are cursor-only and may contain speech. All SOURCE seconds, " +
  "clipped to the trim window.";

/** Splits `span` around keystroke/scroll moments (± pad). */
function subtractActivity(span: TimeSpan, keyTimes: readonly number[], pad: number): TimeSpan[] {
  const pieces: TimeSpan[] = [];
  let cursor = span.start;
  for (const t of keyTimes) {
    if (!(t + pad > span.start && t - pad < span.end)) continue;
    if (t - pad > cursor) pieces.push({ start: cursor, end: t - pad });
    cursor = smax(cursor, t + pad);
  }
  if (span.end > cursor) pieces.push({ start: cursor, end: span.end });
  return pieces;
}

/** `MCPServer.pacingDigest` — silence alongside idle cursor spans, clipped to
 * the trim window, plus their intersection minus typing/scrolling. */
export function pacingDigest(
  project: Project,
  activity: CursorActivity | null,
  silenceOutcome: SilenceOutcome | null,
  keystrokes: readonly KeystrokeEvent[],
): JSONObject {
  const trimStart = effectiveTrimStart(project);
  const trimEnd = project.duration > 0 ? effectiveTrimEnd(project) : Infinity;
  const clipped = (spans: readonly TimeSpan[], minLength: number): TimeSpan[] => {
    const out: TimeSpan[] = [];
    for (const span of spans) {
      const start = smax(span.start, trimStart);
      const end = smin(span.end, trimEnd);
      if (end - start >= minLength) out.push({ start, end });
    }
    return out;
  };
  const payload = (spans: readonly TimeSpan[], seconds = false, limit = 40): JSONObject[] =>
    spans.slice(0, limit).map((s) => {
      const entry: JSONObject = { start: round3(s.start), end: round3(s.end) };
      if (seconds) entry.seconds = round3(s.end - s.start);
      return entry;
    });

  const result: JSONObject = {};
  let silence: TimeSpan[] | null = null;
  if (silenceOutcome) {
    switch (silenceOutcome.kind) {
      case "noAudio":
        // No audio track at all: nothing is ever said.
        result.audio = { tracks: 0, note: "no audio track — the whole recording is silent" };
        if (Number.isFinite(trimEnd)) silence = [{ start: trimStart, end: trimEnd }];
        break;
      case "failed":
        result.audio = { note: `audio analysis failed: ${silenceOutcome.reason}` };
        break;
      case "analyzed": {
        const analysis = silenceOutcome.analysis;
        const spans = clipped(analysis.spans, 1.0);
        silence = spans;
        result.audio = {
          tracks: analysis.trackCount,
          silenceThresholdDb: round3(analysis.thresholdDb),
          noiseFloorDb: round3(analysis.noiseFloorDb),
        };
        result.silenceSpans = payload(spans);
        if (spans.length > 40) result.silenceSpansTruncated = spans.length - 40;
        break;
      }
    }
  }

  if (activity) {
    const idle = clipped(activity.idleSpans, 1.0);
    if (silence) {
      // Keystrokes and scroll ticks are activity even when the mouse is
      // parked (typing into a field, scrolling a page).
      const keyTimes = keystrokes.map((k) => k.timestamp).sort((a, b) => (a < b ? -1 : b < a ? 1 : 0));
      let quiet: TimeSpan[] = [];
      for (const a of idle) {
        for (const b of silence) {
          const start = smax(a.start, b.start);
          const end = smin(a.end, b.end);
          if (!(end - start >= 2.0)) continue;
          quiet.push(...subtractActivity({ start, end }, keyTimes, 0.5));
        }
      }
      quiet = quiet
        .filter((q) => q.end - q.start >= 2.0)
        .sort((a, b) => (a.start < b.start ? -1 : b.start < a.start ? 1 : 0));
      result.quietSpans = payload(quiet, true);
      result.quietSeconds = round3(quiet.reduce((sum, q) => sum + (q.end - q.start), 0));
    }
  }
  result.hint = PACING_HINT;
  return result;
}

// ── Audio silence (RMS) ───────────────────────────────────────────────────

/**
 * `MCPServer.computeSilence` after the decode: all audio tracks mixed to MONO
 * at 8 kHz float (what AVAssetReaderAudioMixOutput delivers), RMS per 50 ms
 * window. The threshold adapts to the recording: 12 dB above its noise floor
 * (10th percentile), clamped to −55…−40 dBFS. Spans ≥ 1 s; a single loud
 * 50 ms blip doesn't break silence. `trackCount` = the asset's audio tracks
 * (0 → noAudio, like Swift).
 */
export function analyzeSilence(
  samples: ArrayLike<number>,
  trackCount: number,
  sampleRate = 8000,
): SilenceOutcome {
  if (trackCount <= 0) return { kind: "noAudio" };
  const window = Math.trunc(sampleRate * 0.05);
  const windowDb: number[] = [];
  let sumSquares = 0;
  let count = 0;
  for (let i = 0; i < samples.length; i++) {
    const v = samples[i];
    sumSquares += v * v;
    count += 1;
    if (count === window) {
      const rms = Math.sqrt(sumSquares / count);
      windowDb.push(20 * Math.log10(smax(rms, 1e-9)));
      sumSquares = 0;
      count = 0;
    }
  }
  if (windowDb.length === 0) return { kind: "noAudio" };

  const sorted = [...windowDb].sort((a, b) => (a < b ? -1 : b < a ? 1 : 0));
  const noiseFloor = sorted[Math.min(sorted.length - 1, Math.trunc(sorted.length / 10))];
  const threshold = smin(-40, smax(-55, noiseFloor + 12));
  const windowSeconds = window / sampleRate;

  const spans: TimeSpan[] = [];
  let runStart: number | null = null;
  for (let index = 0; index < windowDb.length; index++) {
    const loud =
      windowDb[index] > threshold && (index + 1 < windowDb.length ? windowDb[index + 1] > threshold : true);
    if (!loud) {
      if (runStart === null) runStart = index;
    } else if (runStart !== null) {
      const span = { start: runStart * windowSeconds, end: index * windowSeconds };
      if (span.end - span.start >= 1.0) spans.push(span);
      runStart = null;
    }
  }
  if (runStart !== null) {
    const span = { start: runStart * windowSeconds, end: windowDb.length * windowSeconds };
    if (span.end - span.start >= 1.0) spans.push(span);
  }
  return { kind: "analyzed", analysis: { spans, thresholdDb: threshold, noiseFloorDb: noiseFloor, trackCount } };
}

// ── get_transcript ────────────────────────────────────────────────────────

/** `ShareIntelligence.transcriptPayload(for:includeSourceTimes:)` — subtitle
 * segments retimed to OUTPUT seconds on the exporter's trim+speed map. One
 * implementation (core/transcript.ts), shared with the share upload. */
export function transcriptPayload(project: Project, includeSourceTimes = false): JSONObject[] {
  return corePayload(project, includeSourceTimes) as unknown as JSONObject[];
}

/** `MCPServer.getTranscript` minus the load. */
export function getTranscript(project: Project): JSONObject {
  const segments = transcriptPayload(project, true);
  return {
    segments,
    count: segments.length,
    note:
      segments.length === 0
        ? project.subtitles.length === 0
          ? "No transcript — the project has no subtitles yet. Run transcribe {id} to generate them " +
            "on-device (Whisper)."
          : "No transcript inside the trim window."
        : "start/end (and words[].start/end) are OUTPUT seconds — the clock render_frames uses. " +
          "sourceStart/sourceEnd (per segment and per word) are SOURCE seconds — the clock every " +
          "edit tool uses (cut_video, set_speed, add_effect, add_annotation…).",
  };
}

// ── undo's summary ────────────────────────────────────────────────────────

/** `MCPServer.timelineCounts` */
export function timelineCounts(p: Project): JSONObject {
  const counts: JSONObject = {
    trim: { start: round3(effectiveTrimStart(p)), end: round3(effectiveTrimEnd(p)) },
    clips: effectiveVideoClipSegments(p).length,
    zoomRegions: p.zoomRegions.length,
    tiltRegions: p.tiltRegions.length,
    annotations: p.annotations.length,
    blurRegions: p.blurRegions.length,
    speedRegions: p.speedRegions.length,
    subtitles: p.subtitles.length,
  };
  const output = outputDuration(p);
  if (output !== null) counts.outputDuration = round3(output);
  return counts;
}
