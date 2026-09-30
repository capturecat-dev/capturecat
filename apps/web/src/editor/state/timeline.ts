/**
 * Project + selection → TimelineSnapshot (OUTPUT seconds): the web twin of
 * TimelineViewController.canvasSnapshot / canvasEffectItems,
 * TimelineVideoRowModel.make (VideoTrackRowNative.swift) and
 * TimelineVoiceRowModel.make (VoiceTrackRowNative.swift).
 *
 * Every lane is retimed through the SAME `fullTimeMap` the Mac builds
 * (core/time SpeedTimeMap — locked to Swift by golden vectors), so speed
 * regions stretch/squeeze the lanes exactly like the Mac timeline.
 */
import type { Project, VideoSpeedRegion } from "../core/model";
import { hidesTimelinePlayhead, hasTimedEffects, presentsTimelessTimeline } from "../core/model/helpers";
import { formatFixed, smax, smin, srounded } from "../core/math/swift";
import { effectiveTrimEnd, effectiveTrimStart, effectiveVideoClipSegments } from "../core/time/clips";
import type { SpeedTimeMap } from "../core/time/speedTimeMap";
import { voiceOutputClip } from "../core/time/voiceTrackEditMath";
import type {
  AnnotateBlock,
  EffectBlock,
  FocusBlock,
  SettingsChip,
  TimelineSnapshot,
  VideoBoundary,
  VideoClip,
  VideoRow,
  VideoSegment,
  VoiceRow,
} from "../ui/timeline/types";
import { annotationLaneLabel, fullTimeMap, timelineOutputDuration } from "./edits";
import type { Selection } from "./selection";

/** TimelineViewController.annotationLaneIcon(for:) */
export const ANNOTATION_ICONS: Record<string, string> = {
  text: "text.bubble",
  arrow: "arrow.up.right",
  callout: "pencil.tip",
  drawing: "pencil.and.scribble",
  rectangle: "rectangle",
  ellipse: "oval",
  tap: "hand.tap",
};

const CAMERA_LAYOUT_NAMES: Record<string, string> = {
  bubble: "Bubble",
  cameraOnly: "Camera Only",
  sideBySide: "Side by Side",
  screenOnly: "Screen Only",
};

/** EffectBlockItem.linkEpsilon */
const LINK_EPSILON = 0.02;

export const effectKey = (zoomId?: string | null, tiltId?: string | null) => `e:${zoomId ?? "-"}:${tiltId ?? "-"}`;

/** TimelineVideoRowModel.speedPresets */
export const SPEED_PRESETS = [0.5, 0.75, 1.2, 1.4, 1.6, 1.8, 2.0, 3.0, 4.0];

/** TimelineVideoRowModel.formatSpeedLabel */
export function formatSpeedLabel(s: number): string {
  if (Math.abs(s - srounded(s)) < 0.01) return `${formatFixed(s, 0)}x`;
  return `${formatFixed(s, 1)}x`;
}

/** TimelineVideoRowModel.segmentLabel */
export function segmentLabel(outputSpan: number, speed: number): string {
  const srcDur = outputSpan * speed;
  const d = srcDur < 1 ? `${formatFixed(srcDur, 1)}s` : `${Math.trunc(srounded(srcDur))}s`;
  return `${d} · ${formatSpeedLabel(speed)}`;
}

/** canvasEffectItems — each zoom claims the first unclaimed co-spanning
 *  tilt; unclaimed tilts append last; a matching Slide joins its block. */
function effectItems(p: Project, map: SpeedTimeMap, sel: Selection): EffectBlock[] {
  const claimed = new Set<string>();
  const out: EffectBlock[] = [];
  for (const z of p.zoomRegions) {
    const match = p.tiltRegions.find(
      (t) => !claimed.has(t.id) && Math.abs(t.startTime - z.startTime) <= LINK_EPSILON && Math.abs(t.endTime - z.endTime) <= LINK_EPSILON,
    );
    if (match) claimed.add(match.id);
    out.push({
      key: effectKey(z.id, match?.id),
      zoomId: z.id,
      tiltId: match?.id,
      start: map.outputTime(z.startTime),
      end: map.outputTime(z.endTime),
      zoomLevel: z.zoomLevel,
      pitch: match?.pitch ?? 0,
      yaw: match?.yaw ?? 0,
      roll: match?.roll ?? 0,
      selected: sel.zoomId === z.id || (match != null && sel.tiltId === match.id),
    });
  }
  for (const t of p.tiltRegions) {
    if (claimed.has(t.id)) continue;
    out.push({
      key: effectKey(null, t.id),
      tiltId: t.id,
      start: map.outputTime(t.startTime),
      end: map.outputTime(t.endTime),
      pitch: t.pitch,
      yaw: t.yaw,
      roll: t.roll,
      selected: sel.tiltId === t.id,
    });
  }
  if (p.settings.introSlideStyle !== "Off") {
    const s0 = p.settings.introSlideStart;
    const s1 = s0 + p.settings.introSlideDuration;
    const item = out.find((e) => Math.abs(e.start - s0) < 0.05 && Math.abs(e.end - s1) < 0.08);
    if (item) item.hasSlide = true;
  }
  return out;
}

/** slideJoinsABlock */
function slideJoinsABlock(p: Project, map: SpeedTimeMap): boolean {
  if (p.settings.introSlideStyle === "Off") return false;
  const s0 = p.settings.introSlideStart;
  const s1 = s0 + p.settings.introSlideDuration;
  const spans = [...p.zoomRegions, ...p.tiltRegions].map((r) => [r.startTime, r.endTime] as const);
  return spans.some((s) => Math.abs(map.outputTime(s[0]) - s0) < 0.05 && Math.abs(map.outputTime(s[1]) - s1) < 0.08);
}

const INTRO_ICONS: Record<string, string> = {
  Top: "arrow.down.to.line",
  Bottom: "arrow.up.to.line",
  Left: "arrow.right.to.line",
  Right: "arrow.left.to.line",
  Off: "arrow.up.to.line",
};

export interface TimelineInputs {
  project: Project;
  selection: Selection;
  sliceArmed: boolean;
  /** The recording has an audio track (the Mac: `!audioSamples.isEmpty`). */
  hasAudio: boolean;
}

/** TimelineVideoRowModel.make (snap candidates without the playhead). */
export function videoRow(p: Project, map: SpeedTimeMap, selectedClipId: string | null, hasAudio: boolean): VideoRow {
  const tolerance = 1.0 / 15.0;
  const regionStart = map.outputTime(effectiveTrimStart(p));
  const regionEnd = map.outputTime(effectiveTrimEnd(p));
  const outputSplits = p.splitPoints.map((s) => map.outputTime(s));

  const refs = effectiveVideoClipSegments(p)
    .map((c) => ({ id: c.id, sourceStart: c.startTime, sourceEnd: c.endTime, outputStart: map.outputTime(c.startTime), outputEnd: map.outputTime(c.endTime) }))
    .filter((c) => c.outputEnd > c.outputStart)
    .sort((a, b) => (a.outputStart < b.outputStart ? -1 : b.outputStart < a.outputStart ? 1 : 0));

  const overlapping = (c: (typeof refs)[number]): VideoSpeedRegion[] =>
    p.speedRegions.filter((r) => r.startTime < c.sourceEnd + tolerance && r.endTime > c.sourceStart - tolerance);

  const dominantSpeed = (c: (typeof refs)[number]): number | null => {
    const span = c.sourceEnd - c.sourceStart;
    if (!(span > 0.01)) return null;
    let best: [number, number] | null = null;
    for (const r of overlapping(c)) {
      const overlap = smin(r.endTime, c.sourceEnd) - smax(r.startTime, c.sourceStart);
      const entry: [number, number] = [r.speed, smax(0, overlap) / span];
      // `.max { $0.1 < $1.1 }` — Swift's max(by:) replaces only on strictly-greater (first maximum wins).
      if (best === null || best[1] < entry[1]) best = entry;
    }
    if (!best || !(best[1] >= 0.6) || !(Math.abs(best[0] - 1.0) > 0.01)) return null;
    return best[0];
  };

  const fillingRegion = (c: (typeof refs)[number]): VideoSpeedRegion | null => {
    const regions = overlapping(c);
    if (regions.length !== 1) return null;
    const r = regions[0];
    const startsAtClipStart = Math.abs(r.startTime - c.sourceStart) <= tolerance;
    const endsAtClipEnd = Math.abs(r.endTime - c.sourceEnd) <= tolerance;
    return startsAtClipStart || endsAtClipEnd ? r : null;
  };

  const clips: VideoClip[] = refs.map((c) => {
    const fill = fillingRegion(c);
    const dom = dominantSpeed(c);
    return {
      id: c.id,
      outputStart: c.outputStart,
      outputEnd: c.outputEnd,
      sourceStart: c.sourceStart,
      sourceEnd: c.sourceEnd,
      selected: selectedClipId === c.id,
      pillSpeedLabel: dom == null ? undefined : formatSpeedLabel(dom),
      fillSpeed: fill?.speed,
      fillRegionId: fill?.id,
    };
  });

  const segments: VideoSegment[] = [];
  for (const c of refs) {
    for (const seg of map.segments) {
      const outputStart = smax(seg.outputStart, c.outputStart);
      const outputEnd = smin(seg.outputEnd, c.outputEnd);
      if (!(outputEnd > outputStart + 0.001)) continue;
      const regionId =
        seg.speed === 1.0
          ? undefined
          : p.speedRegions.find((r) => Math.abs(r.startTime - seg.sourceStart) < 0.01 && Math.abs(r.endTime - seg.sourceEnd) < 0.01)?.id;
      segments.push({
        id: `${c.id}-${seg.sourceStart}-${seg.sourceEnd}-${outputStart}-${outputEnd}`,
        clipId: c.id,
        sourceStart: map.sourceTime(outputStart),
        sourceEnd: map.sourceTime(outputEnd),
        outputStart,
        outputEnd,
        speed: seg.speed,
        regionId,
        label: segmentLabel(outputEnd - outputStart, seg.speed),
        showsLeadingDivider: outputStart > c.outputStart + 0.01,
        startsAtSplit: outputSplits.some((s) => Math.abs(s - outputStart) < 0.05),
      });
    }
  }

  const boundaries: VideoBoundary[] = [];
  for (let i = 0; i + 1 < refs.length; i++) {
    const left = refs[i];
    const right = refs[i + 1];
    if (!(Math.abs(left.outputEnd - right.outputStart) <= 1.0 / 60.0)) continue;
    boundaries.push({ id: `${left.id}-${right.id}`, leftClipId: left.id, rightClipId: right.id, outputTime: (left.outputEnd + right.outputStart) / 2 });
  }

  // videoTrackSnapCandidates (minus the playhead — the renderer adds it live).
  const cands: number[] = [];
  for (const r of p.zoomRegions) cands.push(r.startTime, r.endTime);
  for (const r of p.blurRegions) cands.push(r.startTime, r.endTime);
  for (const r of p.highlightRegions) cands.push(r.startTime, r.endTime);
  for (const r of p.speedRegions) cands.push(r.startTime, r.endTime);

  return {
    regionStart,
    regionEnd,
    usesWholeTrackDrag: refs.length <= 1,
    clips,
    segments,
    boundaries,
    muted: p.settings.muteRecordedAudio,
    hasAudio,
    snapCandidates: cands.map((t) => map.outputTime(t)),
  };
}

/** TimelineVoiceRowModel.make (committed clips + snap candidates). */
export function voiceRow(p: Project, map: SpeedTimeMap, selectedVoiceId: string | null): VoiceRow {
  const clips = p.voiceOverClips.map((stored) => {
    const value = voiceOutputClip(stored, map);
    return {
      id: stored.id,
      start: value.startTime,
      end: value.startTime + value.duration,
      label: stored.label,
      selected: selectedVoiceId === stored.id,
      value,
    };
  });
  const sources: number[] = [effectiveTrimStart(p), effectiveTrimEnd(p)];
  for (const r of p.zoomRegions) sources.push(r.startTime, r.endTime);
  for (const r of p.blurRegions) sources.push(r.startTime, r.endTime);
  for (const r of p.highlightRegions) sources.push(r.startTime, r.endTime);
  for (const c of p.voiceOverClips) sources.push(c.startTime, c.startTime + c.duration);
  return { clips, snapCandidates: sources.map((t) => map.outputTime(t)) };
}

/** canvasSnapshot */
export function timelineSnapshot({ project: p, selection: sel, sliceArmed, hasAudio }: TimelineInputs): TimelineSnapshot {
  const map = fullTimeMap(p);
  const outputDuration = timelineOutputDuration(p);

  const focus: FocusBlock[] = [
    ...p.blurRegions.map((r) => ({ id: r.id, isHighlight: false, start: map.outputTime(r.startTime), end: map.outputTime(r.endTime), label: r.label, selected: sel.blurId === r.id })),
    ...p.focusRegions.map((r) => ({ id: r.id, isHighlight: false, start: map.outputTime(r.startTime), end: map.outputTime(r.endTime), label: r.label, selected: sel.depthFocusId === r.id })),
    ...p.cameraLayoutRegions.map((r) => ({
      id: r.id,
      isHighlight: false,
      start: map.outputTime(r.startTime),
      end: map.outputTime(r.endTime),
      label: `Camera: ${CAMERA_LAYOUT_NAMES[r.mode] ?? r.mode}`,
      selected: sel.cameraLayoutId === r.id,
    })),
    ...p.highlightRegions.map((r) => ({ id: r.id, isHighlight: true, start: map.outputTime(r.startTime), end: map.outputTime(r.endTime), label: r.label, selected: sel.highlightId === r.id })),
  ];

  const annotate: AnnotateBlock[] = p.annotations.map((a) => ({
    id: a.id,
    start: map.outputTime(a.startTime),
    end: map.outputTime(a.endTime),
    label: annotationLaneLabel(a),
    icon: ANNOTATION_ICONS[a.type] ?? "pencil.tip",
    selected: sel.annotationId === a.id,
  }));

  const s = p.settings;
  let intro: SettingsChip | undefined;
  if (s.introSlideStyle !== "Off" && !slideJoinsABlock(p, map)) {
    intro = {
      start: s.introSlideStart,
      end: smin(s.introSlideStart + s.introSlideDuration, outputDuration),
      label: s.introSlideStart <= 0.01 ? "Slide In" : "Slide",
      icon: INTRO_ICONS[s.introSlideStyle] ?? "arrow.up.to.line",
      selected: sel.introSelected,
    };
  }
  let curtain: SettingsChip | undefined;
  if (s.curtainUnveilCorner !== "Off") {
    curtain = {
      start: s.curtainUnveilStart,
      end: smin(s.curtainUnveilStart + s.curtainUnveilDuration, outputDuration),
      label: "Curtain",
      icon: "book.pages",
      selected: sel.curtainSelected,
    };
  }

  return {
    outputDuration,
    trimStartOutput: map.outputTime(effectiveTrimStart(p)),
    trimEndOutput: map.outputTime(effectiveTrimEnd(p)),
    effects: effectItems(p, map, sel),
    intro,
    curtain,
    focus,
    annotate,
    video: videoRow(p, map, sel.clipId, hasAudio),
    voice: voiceRow(p, map, sel.voiceOverId),
    sliceArmed,
    timeless: hidesTimelinePlayhead(p),
    dimmedRuler: presentsTimelessTimeline(p) && hasTimedEffects(p),
  };
}
