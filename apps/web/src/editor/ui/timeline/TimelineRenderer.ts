/**
 * The timeline, on <canvas> — the web twin of TimelineCanvasView +
 * TimelinePlayheadOverlayView + the native VIDEO/VOICE rows.
 *
 * Imperative and React-free: the React wrapper feeds it snapshots; the
 * playhead channel feeds it per-frame time. Two canvases:
 *   base    — ruler, separators, lanes, blocks (redraws on data/scroll/zoom/hover)
 *   overlay — snap guide, playhead, scrub bubble, overlay scrollers
 *             (the only thing that redraws per frame during playback)
 * Both are DPR-correct and repaint in ONE rAF callback, only when dirty.
 *
 * Coordinates: "document" space is the full-width, full-height track area
 * (x ∈ [0, trackWidth], y ∈ [0, docHeight], Y-down) exactly like the Mac's
 * flipped canvas document view; the viewport scrolls over it.
 */
import { canvasGlyph, readCanvasTokens, rgbaString, type CanvasTokens, type RGBA } from "../kit";
import { BlockSpriteCache } from "./blockSurface";
import type { VoiceOverClip } from "../../core/model";
import { isSliceable, resolvedSliceTarget } from "../../core/time/videoSliceMath";
import { VideoTrackEditMath } from "../../core/time/videoTrackEditMath";
import { VoiceTrackEditMath } from "../../core/time/voiceTrackEditMath";
import { canvasAreaHeight, M } from "./metrics";
import {
  annotateRowCount,
  annotateRowLayout,
  effectsRowAssignment,
  effectsSpans,
  orderedAnnotations,
  type Span,
} from "./rows";
import { formatRulerTime, formatScrub, majorInterval, resolveBlockDrag, snappedEdge, type DragMode } from "./snap";
import type {
  AnnotateBlock,
  EffectBlock,
  FocusBlock,
  LaneId,
  TimelineIntents,
  TimelineSnapshot,
  TimelineTarget,
  VideoBoundary,
  VideoClip,
  VoiceClip,
} from "./types";

export interface ContextMenuRequest {
  clientX: number;
  clientY: number;
  /** Output time under the pointer. */
  time: number;
  lane: LaneId | "ruler" | null;
  target: TimelineTarget | null;
  /** Effect block under the pointer (for the zoom-level/tilt entries). */
  effect?: EffectBlock;
  /** VIDEO segment under the pointer (speed entries). */
  segment?: { sourceStart: number; sourceEnd: number; outputStart: number; regionId?: string; startsAtSplit: boolean };
}

export interface TimelineRendererHooks {
  intents: TimelineIntents;
  onContextMenu?(req: ContextMenuRequest): void;
  /** EFFECTS sub-rows changed (panel height) or ANNOTATE rows grew (scroll). */
  onLayout?(info: { effectsRows: number; docHeight: number }): void;
  /** Vertical scroll moved — the DOM label column follows. */
  onScrollY?(scrollY: number): void;
  /** Horizontal zoom changed from inside (pinch / wheel). */
  onScale?(scale: number): void;
}

type BlockTarget =
  | { kind: "effect"; item: EffectBlock }
  | { kind: "focus"; item: FocusBlock }
  | { kind: "annotate"; item: AnnotateBlock }
  | { kind: "voice"; item: VoiceClip };

interface BlockDrag {
  target: BlockTarget;
  mode: DragMode;
  initialStart: number;
  initialEnd: number;
  startX: number;
  startY: number;
  translationX: number;
  didDrag: boolean;
  snapCandidates: number[];
  otherSpans: Array<[number, number]>;
  usesLegacyGrace: boolean;
  minDuration: number;
}

type MouseState =
  | { kind: "idle" }
  | { kind: "scrubbing"; playhead: boolean }
  | { kind: "block"; drag: BlockDrag }
  | { kind: "chipEdge"; chip: "intro" | "curtain" }
  | { kind: "chipMove"; chip: "intro" | "curtain"; downX: number; initialStart: number; didDrag: boolean }
  | { kind: "video"; drag: VideoDrag }
  | { kind: "videoDeselect" }
  | { kind: "slicing" };

/** VideoRowDrag (VideoTrackRowNative.swift) — the VIDEO lane's own machine. */
type VideoDragKind =
  | { type: "whole"; mode: DragMode }
  | { type: "clipMove"; clip: VideoClip }
  | { type: "clipEdge"; clip: VideoClip; side: "left" | "right" }
  | { type: "boundary"; boundary: VideoBoundary };

interface VideoDrag {
  kind: VideoDragKind;
  startX: number;
  translationX: number;
  didDrag: boolean;
  /** Boundary: the side picked by the first meaningful horizontal movement. */
  resolved?: { clip: VideoClip; side: "left" | "right" };
}

/** Per-gesture activation distance (VideoRowDrag.threshold). */
function videoThreshold(kind: VideoDragKind): number {
  switch (kind.type) {
    case "whole":
    case "clipMove":
      return 3;
    case "clipEdge":
      return 1;
    case "boundary":
      return 0.25;
  }
}

/** VideoTrackRowNative hit sizes. */
const VIDEO_CLIP_HANDLE_WIDTH = 23;
const VIDEO_CLIP_HANDLE_HEIGHT = 32;
const VIDEO_BOUNDARY_HIT_WIDTH = 30;

const EN_SPACE = " ";

export class TimelineRenderer {
  private host: HTMLElement;
  private base: HTMLCanvasElement;
  private overlay: HTMLCanvasElement;
  private bctx: CanvasRenderingContext2D;
  private octx: CanvasRenderingContext2D;
  private hooks: TimelineRendererHooks;

  private snap: TimelineSnapshot = {
    outputDuration: 0,
    trimStartOutput: 0,
    trimEndOutput: 0,
    effects: [],
    focus: [],
    annotate: [],
  };
  private tokens: CanvasTokens | null = null;
  private dpr = 1;
  private viewW = 0;
  private viewH = 0;
  private scale = 1;
  private scrollX = 0;
  private scrollY = 0;
  private playhead = 0;
  private playheadOverride: number | null = null;
  private playing = false;

  // Derived layout (recomputed on snapshot change / during effect drags)
  private effectsRowsCommitted = 1;
  private effectsRowMap = new Map<string, number>();
  private orderedAnno: AnnotateBlock[] = [];
  private annoLayout = new Map<string, { row: number; rows: number }>();
  private annoRows = 1;

  // Interaction
  private mouse: MouseState = { kind: "idle" };
  private snapGuide: number | null = null;
  private hoverLane: "effects" | "focus" | "annotate" | null = null;
  private hoverKey: string | null = null;
  private hoverVideo = false;
  private hoverVoice: string | null = null;
  private sliceHoverX: number | null = null;
  private sliceSnapped = false;
  private cursor = "default";
  private scrollerShownAt = -Infinity;

  // Paint scheduling
  private dirtyBase = true;
  private dirtyOverlay = true;
  private raf = 0;
  private destroyed = false;
  private sprites = new BlockSpriteCache();
  private textWidths = new Map<string, number>();
  private rulerAscent = 7;
  private labelAscent = 9;
  private lastLayoutKey = "";

  /** Frame-time instrumentation (perf harness reads it). */
  readonly stats = { frames: 0, lastBaseMs: 0, lastOverlayMs: 0, maxBaseMs: 0, totalBaseMs: 0, baseFrames: 0 };

  constructor(host: HTMLElement, base: HTMLCanvasElement, overlay: HTMLCanvasElement, hooks: TimelineRendererHooks) {
    this.host = host;
    this.base = base;
    this.overlay = overlay;
    this.bctx = base.getContext("2d", { alpha: true })!;
    this.octx = overlay.getContext("2d", { alpha: true })!;
    this.hooks = hooks;

    host.addEventListener("pointerdown", this.onPointerDown);
    host.addEventListener("pointermove", this.onPointerMove);
    host.addEventListener("pointerup", this.onPointerUp);
    host.addEventListener("pointercancel", this.onPointerUp);
    host.addEventListener("pointerleave", this.onPointerLeave);
    host.addEventListener("wheel", this.onWheel, { passive: false });
    host.addEventListener("contextmenu", this.onContextMenu);
    host.addEventListener("gesturestart", this.onGestureStart as EventListener);
    host.addEventListener("gesturechange", this.onGestureChange as EventListener);
  }

  destroy() {
    this.destroyed = true;
    cancelAnimationFrame(this.raf);
    const h = this.host;
    h.removeEventListener("pointerdown", this.onPointerDown);
    h.removeEventListener("pointermove", this.onPointerMove);
    h.removeEventListener("pointerup", this.onPointerUp);
    h.removeEventListener("pointercancel", this.onPointerUp);
    h.removeEventListener("pointerleave", this.onPointerLeave);
    h.removeEventListener("wheel", this.onWheel);
    h.removeEventListener("contextmenu", this.onContextMenu);
    h.removeEventListener("gesturestart", this.onGestureStart as EventListener);
    h.removeEventListener("gesturechange", this.onGestureChange as EventListener);
  }

  setHooks(hooks: TimelineRendererHooks) {
    this.hooks = hooks;
  }

  // ── Inputs ────────────────────────────────────────────────────────────

  setSnapshot(snapshot: TimelineSnapshot) {
    this.snap = snapshot;
    this.recomputeLayout();
    this.clampScroll();
    this.invalidate();
  }

  /** Re-read theme tokens (theme switch). */
  refreshTheme() {
    this.tokens = readCanvasTokens(this.host);
    this.sprites.clear();
    this.textWidths.clear();
    this.measureFonts();
    this.invalidate();
  }

  resize(viewW: number, viewH: number, dpr: number) {
    if (viewW === this.viewW && viewH === this.viewH && dpr === this.dpr) return;
    if (dpr !== this.dpr) this.sprites.clear();
    this.viewW = viewW;
    this.viewH = viewH;
    this.dpr = dpr;
    for (const c of [this.base, this.overlay]) {
      c.width = Math.max(1, Math.round(viewW * dpr));
      c.height = Math.max(1, Math.round(viewH * dpr));
      c.style.width = `${viewW}px`;
      c.style.height = `${viewH}px`;
    }
    this.clampScroll();
    this.invalidate();
  }

  /** Per-frame playhead (output seconds). Only the overlay repaints. */
  setPlayhead(t: number) {
    if (t === this.playhead) return;
    this.playhead = t;
    if (this.playing) this.followPlayhead();
    this.dirtyOverlay = true;
    this.schedule();
  }

  setPlaying(playing: boolean) {
    this.playing = playing;
  }

  getScale() {
    return this.scale;
  }

  /**
   * Horizontal zoom, anchored so the PLAYHEAD keeps its on-screen position
   * (TimelineViewController.setTimelineScale) — or at `anchorClientX` for
   * pointer-anchored zooms.
   */
  setScale(next: number, anchorClientX?: number) {
    const clamped = this.snap.timeless ? M.minScale : Math.min(M.maxScale, Math.max(M.minScale, next));
    if (Math.abs(clamped - this.scale) < 0.0001) return;
    const oldWidth = this.trackWidth;
    const duration = this.snap.outputDuration;
    let fraction: number;
    let anchorScreenX: number;
    if (anchorClientX != null) {
      anchorScreenX = anchorClientX - this.host.getBoundingClientRect().left;
      fraction = oldWidth > 0 ? (anchorScreenX + this.scrollX) / oldWidth : 0;
    } else {
      fraction = duration > 0 ? this.currentPlayhead / duration : 0;
      anchorScreenX = Math.min(Math.max(oldWidth * fraction - this.scrollX, 0), Math.max(0, this.viewW));
    }
    this.scale = clamped;
    const newWidth = this.trackWidth;
    this.scrollX = Math.max(0, Math.min(newWidth - this.viewW, newWidth * fraction - anchorScreenX));
    this.showScrollers();
    this.invalidate();
  }

  // ── Geometry ─────────────────────────────────────────────────────────

  get trackWidth() {
    return Math.max(this.viewW, this.viewW * this.scale);
  }

  private get currentPlayhead() {
    return this.playheadOverride ?? this.playhead;
  }

  private xFor(t: number) {
    const d = this.snap.outputDuration;
    return d > 0 ? (this.trackWidth * t) / d : 0;
  }

  private timeAt(x: number) {
    const w = this.trackWidth;
    const d = this.snap.outputDuration;
    if (!(w > 0) || !(d > 0)) return 0;
    return Math.max(0, Math.min(1, x / w)) * d;
  }

  private get effectsExtra() {
    return (this.effectsRowsCommitted - 1) * M.subRowPitch;
  }
  private get focusLaneY() {
    return M.focusLaneY + this.effectsExtra;
  }
  private get annotateLaneY() {
    return M.annotateLaneY + this.effectsExtra;
  }
  private get annotateExtra() {
    return (this.annoRows - 1) * M.subRowPitch;
  }
  private get tracksBottom() {
    return M.tracksBottom + this.effectsExtra + this.annotateExtra;
  }
  get docHeight() {
    return canvasAreaHeight(this.effectsRowsCommitted) + this.annotateExtra;
  }

  private effectsRowY(row: number) {
    return M.effectsLaneY + Math.max(0, Math.min(row, this.effectsRowsCommitted - 1)) * M.subRowPitch;
  }

  private blockRect(start: number, end: number, laneY: number) {
    const d = this.snap.outputDuration;
    const w = d > 0 ? Math.max(M.minBlockWidth, (this.trackWidth * (end - start)) / d) : M.minBlockWidth;
    return { x: this.xFor(start), y: laneY + M.blockInset, w, h: M.trackHeight - M.blockInset * 2 };
  }

  private recomputeLayout() {
    const committed = effectsRowAssignment(effectsSpans(this.snap));
    this.effectsRowsCommitted = committed.rowCount;
    this.effectsRowMap = committed.rows;
    this.orderedAnno = orderedAnnotations(this.snap.annotate);
    this.annoLayout = annotateRowLayout(this.orderedAnno);
    this.annoRows = annotateRowCount(this.annoLayout);
    const key = `${this.effectsRowsCommitted}|${this.docHeight}`;
    if (key !== this.lastLayoutKey) {
      this.lastLayoutKey = key;
      this.hooks.onLayout?.({ effectsRows: this.effectsRowsCommitted, docHeight: this.docHeight });
    }
  }

  /** Live row map: a dragged effect glides to its sub-row mid-drag. */
  private liveEffectsRows(): Map<string, number> {
    if (this.mouse.kind !== "block" || this.mouse.drag.target.kind !== "effect" || !this.mouse.drag.didDrag) {
      return this.effectsRowMap;
    }
    const drag = this.mouse.drag;
    const key = (drag.target as { item: EffectBlock }).item.key;
    const resolved = this.resolve(drag);
    const spans: Span[] = effectsSpans(this.snap).map((s) => (s.key === key ? { key, ...resolved } : s));
    return effectsRowAssignment(spans).rows;
  }

  private annotateRect(item: AnnotateBlock) {
    const slot = this.annoLayout.get(item.id);
    const row = slot && slot.rows > 1 ? slot.row : 0;
    return this.blockRect(item.start, item.end, this.annotateLaneY + row * M.subRowPitch);
  }

  // ── Scheduling ───────────────────────────────────────────────────────

  invalidate() {
    this.dirtyBase = true;
    this.dirtyOverlay = true;
    this.schedule();
  }

  private schedule() {
    if (this.raf || this.destroyed) return;
    this.raf = requestAnimationFrame(this.frame);
  }

  /** Pinch/wheel zoom reports at most once per frame — wheel events outpace
   *  frames, and each report re-renders the toolbar's slider. */
  private scaleReportPending = false;
  private reportScale() {
    this.scaleReportPending = true;
    this.schedule();
  }

  private frame = () => {
    this.raf = 0;
    if (this.destroyed) return;
    if (this.scaleReportPending) {
      this.scaleReportPending = false;
      this.hooks.onScale?.(this.scale);
    }
    if (!this.tokens) this.refreshThemeSilently();
    this.stats.frames++;
    if (this.dirtyBase) {
      const t0 = performance.now();
      this.dirtyBase = false;
      this.paintBase();
      const dt = performance.now() - t0;
      this.stats.lastBaseMs = dt;
      this.stats.maxBaseMs = Math.max(this.stats.maxBaseMs, dt);
      this.stats.totalBaseMs += dt;
      this.stats.baseFrames++;
    }
    if (this.dirtyOverlay) {
      const t0 = performance.now();
      this.dirtyOverlay = false;
      const animating = this.paintOverlay();
      this.stats.lastOverlayMs = performance.now() - t0;
      if (animating) {
        this.dirtyOverlay = true;
        this.schedule();
      }
    }
  };

  private refreshThemeSilently() {
    this.tokens = readCanvasTokens(this.host);
    this.measureFonts();
  }

  private measureFonts() {
    const ctx = this.bctx;
    const t = this.tokens;
    if (!t) return;
    ctx.font = `600 9px ${t.mono}`;
    this.rulerAscent = ctx.measureText("0").fontBoundingBoxAscent || 7;
    ctx.font = `600 10px ${t.font}`;
    this.labelAscent = ctx.measureText("0").fontBoundingBoxAscent || 9;
  }

  private measure(ctx: CanvasRenderingContext2D, text: string, font: string) {
    const key = `${font}|${text}`;
    let w = this.textWidths.get(key);
    if (w == null) {
      ctx.font = font;
      w = ctx.measureText(text).width;
      if (this.textWidths.size > 4000) this.textWidths.clear();
      this.textWidths.set(key, w);
    }
    return w;
  }

  // ── Painting: base ───────────────────────────────────────────────────

  private paintBase() {
    const ctx = this.bctx;
    const t = this.tokens!;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.clearRect(0, 0, this.viewW, this.viewH);
    if (!(this.snap.outputDuration > 0) || this.viewW <= 0) return;
    ctx.save();
    ctx.translate(-this.scrollX, -this.scrollY);

    this.drawRuler(ctx, t);
    this.drawSeparators(ctx, t);
    if (this.snap.video) this.drawVideoLane(ctx, t);
    if (this.snap.voice) this.drawVoiceLane(ctx, t);
    this.drawEffectsLane(ctx, t);
    this.drawFocusLane(ctx, t);
    this.drawAnnotateLane(ctx, t);
    this.drawEmptyLaneHints(ctx, t);
    this.drawSliceIndicator(ctx, t);
    ctx.restore();
  }

  private visibleRange(): [number, number] {
    return [this.scrollX - 40, this.scrollX + this.viewW + 40];
  }

  private drawRuler(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    const duration = this.snap.outputDuration;
    const width = this.trackWidth;
    const height = M.rulerHeight;
    const baseline = height - 1;
    const ink = t.ink;
    if (this.snap.timeless) {
      ctx.fillStyle = rgbaString(ink, 0.06);
      ctx.fillRect(this.scrollX, baseline - 0.5, this.viewW, 1);
      return;
    }
    const pps = width / duration;
    const major = majorInterval(pps);
    const minor = major / 5;
    const dim = this.snap.dimmedRuler ? 0.65 : 1;
    const [vx0, vx1] = this.visibleRange();

    ctx.fillStyle = rgbaString(ink, 0.12 * dim);
    ctx.fillRect(Math.max(0, vx0), baseline - 0.5, Math.min(width, vx1) - Math.max(0, vx0), 1);

    // Minor ticks (0.5px), skipping majors.
    const minorH = height * 0.22;
    const majorH = height * 0.46;
    ctx.strokeStyle = rgbaString(ink, 0.22 * dim);
    ctx.lineWidth = 0.5;
    ctx.beginPath();
    const i0 = Math.max(0, Math.floor(((vx0 / width) * duration) / minor));
    const i1 = Math.ceil(((vx1 / width) * duration) / minor);
    for (let i = i0; i <= i1; i++) {
      const tt = i * minor;
      if (tt > duration + 1e-9) break;
      if (i % 5 === 0) continue;
      const x = (tt / duration) * width;
      ctx.moveTo(x, baseline);
      ctx.lineTo(x, baseline - minorH);
    }
    ctx.stroke();

    // Majors + labels.
    ctx.lineWidth = 1;
    ctx.beginPath();
    const font = `600 9px ${t.mono}`;
    const labels: Array<[string, number]> = [];
    const j0 = Math.max(0, Math.floor(((vx0 / width) * duration) / major) - 1);
    const j1 = Math.ceil(((vx1 / width) * duration) / major) + 1;
    for (let j = j0; j <= j1; j++) {
      const tt = j * major;
      if (tt > duration + 1e-9) break;
      const x = (tt / duration) * width;
      ctx.moveTo(x, baseline);
      ctx.lineTo(x, baseline - majorH);
      labels.push([formatRulerTime(tt, major < 1), x]);
    }
    ctx.stroke();
    ctx.font = font;
    ctx.fillStyle = rgbaString(t.muted);
    ctx.textBaseline = "alphabetic";
    for (const [label, x] of labels) {
      const w = this.measure(ctx, label, font);
      const cx = Math.min(Math.max(w / 2 + 2, x), width - w / 2 - 2);
      ctx.fillText(label, cx - w / 2, 6 + this.rulerAscent);
    }
  }

  private drawSeparators(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    ctx.fillStyle = rgbaString(t.border);
    const x0 = Math.max(0, this.scrollX);
    const w = Math.min(this.trackWidth, this.scrollX + this.viewW) - x0;
    for (const y of [
      M.voiceLaneY - M.trackSpacing,
      M.effectsLaneY - M.trackSpacing,
      this.focusLaneY - M.trackSpacing,
      this.annotateLaneY - M.trackSpacing,
    ]) {
      ctx.fillRect(x0, y, w, 1);
    }
  }

  // VIDEO ───────────────────────────────────────────────────────────────

  private videoBlockGeometry(preview = true): { x: number; w: number } {
    const v = this.snap.video!;
    const d = this.snap.outputDuration;
    const width = this.trackWidth;
    if (!(d > 0) || !(width > 0)) return { x: 0, w: Math.max(40, width) };
    let start = v.regionStart;
    let end = v.regionEnd;
    let originTime = start;
    const drag = this.mouse.kind === "video" ? this.mouse.drag : null;
    if (preview && drag && drag.kind.type === "whole") {
      const delta = (drag.translationX * d) / Math.max(1, width);
      if (drag.kind.mode === "resizeLeft") {
        start = Math.max(0, Math.min(v.regionEnd - M.minDuration, v.regionStart + delta));
        originTime = start;
      } else if (drag.kind.mode === "resizeRight") {
        end = Math.max(v.regionStart + M.minDuration, Math.min(d, v.regionEnd + delta));
        originTime = v.regionStart;
      } else {
        const len = v.regionEnd - v.regionStart;
        start = Math.min(Math.max(0, v.regionStart + delta), Math.max(0, d - len));
        end = Math.min(d, start + len);
        originTime = start;
      }
    }
    return { x: (width * originTime) / d, w: Math.max(M.videoMinBlockWidth, (width * (end - start)) / d) };
  }

  private videoClipRect(clip: VideoClip, block: { x: number; w: number }) {
    const v = this.snap.video!;
    const span = Math.max(0.0001, v.regionEnd - v.regionStart);
    const x = block.x + Math.max(0, ((clip.outputStart - v.regionStart) / span) * block.w);
    const w = Math.max(0, ((clip.outputEnd - clip.outputStart) / span) * block.w);
    return { x, y: M.videoLaneY, w, h: M.trackHeight };
  }

  /** The math struct for the current row (TimelineCanvasView.videoEditMath);
   *  the live playhead is a snap target like the Mac's `currentTime`. */
  private videoEditMath(): VideoTrackEditMath {
    const v = this.snap.video!;
    return new VideoTrackEditMath({
      duration: this.snap.outputDuration,
      trackWidth: this.trackWidth,
      snapCandidates: [...(v.snapCandidates ?? []), this.currentPlayhead],
      regionStart: v.regionStart,
      regionEnd: v.regionEnd,
      minDuration: M.minDuration,
    });
  }

  private videoDragDelta(translationX: number): number {
    return (translationX * this.snap.outputDuration) / Math.max(1, this.trackWidth);
  }

  private clipSpans() {
    return this.snap.video!.clips.map((c) => ({ id: c.id, outputStart: c.outputStart, outputEnd: c.outputEnd }));
  }

  /** Live clip span during a per-clip drag (videoDisplayClip — unsnapped preview). */
  private videoDisplayClip(clip: VideoClip): VideoClip {
    const drag = this.mouse.kind === "video" ? this.mouse.drag : null;
    if (!drag || !drag.didDrag || !(this.snap.outputDuration > 0)) return clip;
    const math = this.videoEditMath();
    const spans = this.clipSpans();
    const delta = this.videoDragDelta(drag.translationX);
    const span = { id: clip.id, outputStart: clip.outputStart, outputEnd: clip.outputEnd };
    const edge = (side: "left" | "right"): VideoClip => {
      const original = side === "left" ? clip.outputStart : clip.outputEnd;
      const resolved = math.resolvedClipEdgeOutput(span, spans, side, original + delta, false);
      return side === "left" ? { ...clip, outputStart: resolved } : { ...clip, outputEnd: resolved };
    };
    const k = drag.kind;
    if (k.type === "clipMove" && k.clip.id === clip.id) {
      const start = math.resolvedClipMoveOutputStart(span, spans, clip.outputStart + delta, false);
      return { ...clip, outputStart: start, outputEnd: start + (clip.outputEnd - clip.outputStart) };
    }
    if (k.type === "clipEdge" && k.clip.id === clip.id) return edge(k.side);
    if (k.type === "boundary" && drag.resolved && drag.resolved.clip.id === clip.id) return edge(drag.resolved.side);
    return clip;
  }

  /** videoDragKind — boundary hotspots → per-clip edge handles → clip body →
   *  the whole-track block gesture (the SwiftUI hit order). */
  private videoDragKind(p: { x: number; y: number }): VideoDragKind | null {
    const v = this.snap.video;
    if (!v || !this.inRect(p, this.laneRect(M.videoLaneY))) return null;
    const block = this.videoBlockGeometry(false);
    if (v.usesWholeTrackDrag) {
      if (!(p.x >= block.x && p.x <= block.x + block.w)) return null;
      const local = Math.min(Math.max(p.x - block.x, 0), block.w);
      if (local < M.videoHandleWidth) return { type: "whole", mode: "resizeLeft" };
      if (local > block.w - M.videoHandleWidth) return { type: "whole", mode: "resizeRight" };
      return { type: "whole", mode: "move" };
    }
    const span = Math.max(0.0001, v.regionEnd - v.regionStart);
    for (const boundary of v.boundaries ?? []) {
      const bx = block.x + Math.max(0, ((boundary.outputTime - v.regionStart) / span) * block.w);
      if (Math.abs(p.x - bx) <= VIDEO_BOUNDARY_HIT_WIDTH / 2) return { type: "boundary", boundary };
    }
    const handleTop = M.videoLaneY + (M.trackHeight - VIDEO_CLIP_HANDLE_HEIGHT) / 2;
    const handleBottom = handleTop + VIDEO_CLIP_HANDLE_HEIGHT;
    for (const clip of v.clips) {
      const r = this.videoClipRect(clip, block);
      if (!(p.x >= r.x && p.x <= r.x + r.w)) continue;
      if (p.y >= handleTop && p.y <= handleBottom) {
        if (p.x - r.x <= VIDEO_CLIP_HANDLE_WIDTH) return { type: "clipEdge", clip, side: "left" };
        if (r.x + r.w - p.x <= VIDEO_CLIP_HANDLE_WIDTH) return { type: "clipEdge", clip, side: "right" };
      }
      return { type: "clipMove", clip };
    }
    return null;
  }

  private videoClipAt(p: { x: number; y: number }): VideoClip | null {
    const v = this.snap.video;
    if (!v) return null;
    const block = this.videoBlockGeometry(false);
    return v.clips.find((c) => this.inRect(p, this.videoClipRect(c, block))) ?? null;
  }

  /** videoMouseUp — resolve with the core VideoTrackEditMath and commit. */
  private finishVideoDrag(drag: VideoDrag, p: { x: number; y: number }) {
    const intents = this.hooks.intents;
    const v = this.snap.video!;
    drag.translationX = p.x - drag.startX;
    if (Math.abs(drag.translationX) > videoThreshold(drag.kind)) drag.didDrag = true;
    const delta = this.videoDragDelta(drag.translationX);
    const math = this.videoEditMath();
    const spans = this.clipSpans();
    const k = drag.kind;
    switch (k.type) {
      case "whole": {
        if (!drag.didDrag) {
          const clip = this.videoClipAt(p);
          intents.select(clip ? { lane: "video", clipId: clip.id } : null, "video");
          return;
        }
        const r = math.resolvedTimes(k.mode, delta, v.regionStart, v.regionEnd);
        if (intents.videoCommitWhole) intents.videoCommitWhole(k.mode, delta, r.start, r.end);
        else if (k.mode === "resizeLeft") intents.trimVideo?.("start", r.start);
        else if (k.mode === "resizeRight") intents.trimVideo?.("end", r.end);
        return;
      }
      case "clipMove": {
        if (!drag.didDrag) {
          intents.select({ lane: "video", clipId: k.clip.id });
          return;
        }
        const span = { id: k.clip.id, outputStart: k.clip.outputStart, outputEnd: k.clip.outputEnd };
        intents.videoCommitClipMove?.(k.clip.id, math.resolvedClipMoveOutputStart(span, spans, k.clip.outputStart + delta));
        return;
      }
      case "clipEdge": {
        if (!drag.didDrag) {
          intents.select({ lane: "video", clipId: k.clip.id });
          return;
        }
        const span = { id: k.clip.id, outputStart: k.clip.outputStart, outputEnd: k.clip.outputEnd };
        const original = k.side === "left" ? k.clip.outputStart : k.clip.outputEnd;
        intents.videoCommitClipEdge?.(k.clip.id, k.side, math.resolvedClipEdgeOutput(span, spans, k.side, original + delta));
        return;
      }
      case "boundary": {
        const target = drag.resolved;
        if (!drag.didDrag || !target) return;
        const span = { id: target.clip.id, outputStart: target.clip.outputStart, outputEnd: target.clip.outputEnd };
        const original = target.side === "left" ? target.clip.outputStart : target.clip.outputEnd;
        intents.videoCommitClipEdge?.(target.clip.id, target.side, math.resolvedClipEdgeOutput(span, spans, target.side, original + delta));
        return;
      }
    }
  }

  private drawVideoLane(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    const v = this.snap.video!;
    const block = this.videoBlockGeometry();
    ctx.save();
    if (this.mouse.kind === "video" && this.mouse.drag.didDrag && this.mouse.drag.kind.type === "whole") ctx.globalAlpha = 0.8;
    const [vx0, vx1] = this.visibleRange();
    const assets = this.snap.assets;
    const hasFilm = !!assets?.thumbnailAt;
    const hover = this.hoverVideo;
    const yellow = t.yellow;
    const orange = t.orange;

    for (const committed of v.clips) {
      const clip = this.videoDisplayClip(committed);
      const r = this.videoClipRect(clip, block);
      if (r.w <= 0.5 || r.x > vx1 || r.x + r.w < vx0) continue;
      ctx.save();
      if (clip !== committed) ctx.globalAlpha = 0.85;
      ctx.beginPath();
      ctx.roundRect(r.x, r.y, r.w, r.h, M.videoCorner);
      ctx.clip();
      ctx.fillStyle = hasFilm ? "rgba(0,0,0,0.4)" : rgbaString(yellow, hover ? 0.45 : 0.35);
      ctx.fillRect(r.x, r.y, r.w, r.h);
      if (hasFilm) this.drawFilmstrip(ctx, r, clip.sourceStart, clip.sourceEnd);

      // Segments (speed fills, dividers, labels)
      const segs = clip.fillSpeed != null
        ? [{
            outputStart: committed.outputStart,
            outputEnd: committed.outputEnd,
            speed: clip.fillSpeed,
            label: segmentLabel(clip.outputEnd - clip.outputStart, clip.fillSpeed),
            showsLeadingDivider: false,
          }]
        : v.segments.filter((s) => s.clipId === clip.id);
      // Segment fractions are of the COMMITTED clip (the drag preview stretches the slab).
      const clipSpan = Math.max(0.0001, committed.outputEnd - committed.outputStart);
      for (const s of segs) {
        const f0 = Math.min(Math.max((s.outputStart - committed.outputStart) / clipSpan, 0), 1);
        const f1 = Math.min(Math.max((s.outputEnd - committed.outputStart) / clipSpan, 0), 1);
        const sx = r.x + r.w * f0;
        const sw = r.w * Math.max(0, f1 - f0);
        if (sw <= 0.5) continue;
        const isSpeed = s.speed !== 1;
        if (isSpeed) {
          ctx.fillStyle = rgbaString(yellow, hover ? 0.65 : 0.55);
          ctx.fillRect(sx, r.y, sw, r.h);
        } else if (!hasFilm) {
          ctx.fillStyle = rgbaString(yellow, hover ? 0.45 : 0.35);
          ctx.fillRect(sx, r.y, sw, r.h);
        }
        if (s.showsLeadingDivider) {
          ctx.fillStyle = rgbaString(orange, 0.6);
          ctx.fillRect(sx, r.y, 1, r.h);
        }
        if (isSpeed) this.drawSpeedLabel(ctx, t, s.label, sx, r.y, sw, r.h);
      }
      if (v.hasAudio) this.drawVideoWaveform(ctx, r, clip, v.muted, hasFilm);
      if (r.w > 80) this.drawInfoPill(ctx, t, clip, r);
      ctx.restore();

      // Hairline + selection border (inside the shape; theme ink).
      this.strokeInside(ctx, r, M.videoCorner, rgbaString(t.ink, 0.1), 1);
      if (clip.selected) this.strokeInside(ctx, r, M.videoCorner, rgbaString(t.ink, 0.85), 2);
      this.drawVideoGrips(ctx, r, yellow, hover);
    }
    if (v.hasAudio) this.drawMuteGlyph(ctx, t, v.muted, block);
    ctx.restore();
  }

  private drawFilmstrip(ctx: CanvasRenderingContext2D, r: { x: number; y: number; w: number; h: number }, s0: number, s1: number) {
    const assets = this.snap.assets!;
    const aspect = assets.thumbnailAspect ?? 16 / 9;
    const tileW = Math.max(10, r.h * aspect);
    const probeW = Math.max(12, r.h * aspect);
    const span = Math.max(0.0001, s1 - s0);
    const [vx0, vx1] = this.visibleRange();
    let x = r.x;
    if (vx0 > r.x) x = r.x + Math.floor((vx0 - r.x) / tileW) * tileW;
    const end = Math.min(r.x + r.w, vx1);
    const dpr = this.dpr;
    while (x < end) {
      const fraction = (x - r.x + probeW / 2) / r.w;
      const img = assets.thumbnailAt!(s0 + fraction * span);
      // Snap tile edges to device pixels: fractional edges antialias into
      // visible seams between neighbouring frames.
      const x0 = Math.round(x * dpr) / dpr;
      const x1 = Math.round((x + tileW) * dpr) / dpr;
      if (img) {
        // Sample half a texel inside the source: bilinear filtering at the
        // image edge blends with transparency and shows as dark seams.
        const iw = (img as { width: number }).width;
        const ih = (img as { height: number }).height;
        if (iw > 1 && ih > 1) ctx.drawImage(img, 0.5, 0.5, iw - 1, ih - 1, x0, r.y, x1 - x0, r.h);
        else ctx.drawImage(img, x0, r.y, x1 - x0, r.h);
      }
      x += tileW;
    }
  }

  private drawSpeedLabel(ctx: CanvasRenderingContext2D, t: CanvasTokens, label: string, x: number, y: number, w: number, h: number) {
    const font = `700 12px ${t.font}`;
    ctx.font = font;
    const textW = this.measure(ctx, label, font);
    const glyphSize = 12;
    const total = glyphSize + 4 + textW;
    if (total > w - 12) return;
    const color = "rgba(0,0,0,0.85)";
    const left = x + w / 2 - total / 2;
    const glyph = canvasGlyph("gauge.with.needle", glyphSize, color, this.dpr, () => this.invalidate(), "bold");
    if (glyph) ctx.drawImage(glyph, left, y + h / 2 - glyphSize / 2, glyphSize, glyphSize);
    ctx.fillStyle = color;
    ctx.textBaseline = "middle";
    ctx.fillText(label, left + glyphSize + 4, y + h / 2 + 0.5);
    ctx.textBaseline = "alphabetic";
  }

  private drawVideoWaveform(
    ctx: CanvasRenderingContext2D,
    r: { x: number; y: number; w: number; h: number },
    clip: VideoClip,
    muted: boolean,
    hasFilm: boolean,
  ) {
    const a = this.snap.assets;
    const samples = a?.audioSamples;
    if (!samples || !samples.length) return;
    const t0 = a!.trimSourceStart ?? 0;
    const t1 = a!.trimSourceEnd ?? 0;
    const trimDur = t1 - t0;
    if (!(trimDur > 0)) return;
    const f0 = Math.max(0, Math.min(1, (clip.sourceStart - t0) / trimDur));
    const f1 = Math.max(0, Math.min(1, (clip.sourceEnd - t0) / trimDur));
    if (!(f1 > f0)) return;
    const count = samples.length;
    const i0 = Math.max(0, Math.min(count - 1, Math.floor(f0 * count)));
    const i1 = Math.max(i0 + 1, Math.min(count, Math.ceil(f1 * count)));
    const waveH = hasFilm ? 14 : 40;
    const hPad = hasFilm ? 4 : Math.min(18, Math.max(4, r.w * 0.12));
    const bPad = hasFilm ? 2 : 4;
    const wx = r.x + hPad;
    const ww = r.w - hPad * 2;
    if (ww <= 1) return;
    const wy = r.y + r.h - bPad - waveH;
    const cy = wy + waveH / 2;
    const maxBar = waveH - 8;
    const n = i1 - i0;
    const barW = Math.max(1, ww / n);
    const [vx0, vx1] = this.visibleRange();
    ctx.fillStyle = `rgba(255,255,255,${muted ? 0.12 : 0.42})`;
    ctx.beginPath();
    const k0 = Math.max(0, Math.floor((vx0 - wx) / barW));
    const k1 = Math.min(n, Math.ceil((vx1 - wx) / barW));
    for (let k = k0; k < k1; k++) {
      const amp = Math.max(0, Math.min(1, samples[i0 + k] ?? 0));
      const bh = amp * maxBar;
      if (bh < 1) continue;
      const bw = Math.max(1, barW - 1);
      ctx.roundRect(wx + k * barW, cy - bh / 2, bw, bh, Math.min(2, bw / 2));
    }
    ctx.fill();
    if (muted) {
      ctx.strokeStyle = "rgba(255,255,255,0.4)";
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(wx, cy);
      ctx.lineTo(wx + ww, cy);
      ctx.stroke();
    }
  }

  private drawInfoPill(ctx: CanvasRenderingContext2D, t: CanvasTokens, clip: VideoClip, r: { x: number; y: number; w: number; h: number }) {
    const font = `400 10px ${t.font}`;
    const main = `${Math.max(0, clip.outputEnd - clip.outputStart).toFixed(1)}s`;
    const extra = clip.pillSpeedLabel ? `  ×${clip.pillSpeedLabel}` : "";
    ctx.font = font;
    const w1 = this.measure(ctx, main, font);
    const w2 = extra ? this.measure(ctx, extra, font) : 0;
    const textH = 12;
    const pw = w1 + w2 + 12;
    const ph = textH + 4;
    const px = r.x + r.w / 2 - pw / 2;
    const py = r.y + r.h / 2 - ph / 2;
    ctx.fillStyle = "rgba(0,0,0,0.38)";
    ctx.beginPath();
    ctx.roundRect(px, py, pw, ph, ph / 2);
    ctx.fill();
    ctx.textBaseline = "middle";
    ctx.fillStyle = "rgba(255,255,255,0.85)";
    ctx.fillText(main, px + 6, py + ph / 2 + 0.5);
    if (extra) {
      ctx.fillStyle = "rgba(255,255,255,0.7)";
      ctx.fillText(extra, px + 6 + w1, py + ph / 2 + 0.5);
    }
    ctx.textBaseline = "alphabetic";
  }

  private drawVideoGrips(ctx: CanvasRenderingContext2D, r: { x: number; y: number; w: number; h: number }, yellow: RGBA, hover: boolean) {
    const base = hover ? 0.95 : 0.7;
    const alphas = [0.78, 0.64];
    for (const bx of [r.x + 5, r.x + r.w - 5 - 6]) {
      for (let i = 0; i < 2; i++) {
        ctx.fillStyle = rgbaString(yellow, base * alphas[i]);
        ctx.beginPath();
        ctx.roundRect(bx + i * 4, r.y + r.h / 2 - 6.5, 2, 13, 1);
        ctx.fill();
      }
    }
  }

  private muteRect(block: { x: number; w: number }) {
    const size = { w: 14, h: 11 };
    const w = size.w + 10;
    const h = size.h + 10;
    return { x: block.x + block.w - M.videoMuteTrailingInset - w, y: M.videoLaneY, w, h };
  }

  private drawMuteGlyph(ctx: CanvasRenderingContext2D, _t: CanvasTokens, muted: boolean, block: { x: number; w: number }) {
    const r = this.muteRect(block);
    const color = `rgba(255,255,255,${muted ? 0.4 : 0.75})`;
    const g = canvasGlyph(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", 11, color, this.dpr, () => this.invalidate());
    if (g) ctx.drawImage(g, r.x + r.w / 2 - 5.5, r.y + r.h / 2 - 5.5, 11, 11);
  }

  private strokeInside(ctx: CanvasRenderingContext2D, r: { x: number; y: number; w: number; h: number }, radius: number, color: string, width: number) {
    const x = r.x + width / 2;
    const y = r.y + width / 2;
    const w = r.w - width;
    const h = r.h - width;
    if (w <= 0 || h <= 0) return;
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, Math.max(0, radius - width / 2));
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.stroke();
  }

  // VOICE ───────────────────────────────────────────────────────────────

  private voiceClipRect(clip: { start: number; end: number; id?: string }) {
    const d = this.snap.outputDuration;
    let start = clip.start;
    let end = clip.end;
    if (this.mouse.kind === "block" && this.mouse.drag.target.kind === "voice" && this.mouse.drag.didDrag &&
      "id" in clip && this.mouse.drag.target.item.id === clip.id) {
      const r = this.resolve(this.mouse.drag);
      start = r.start;
      end = r.end;
    }
    const x = this.xFor(start);
    const w = Math.max(M.voiceMinBlockWidth, d > 0 ? (this.trackWidth * (end - start)) / d : 0);
    const rowH = 14;
    const h = rowH + 4 + M.voiceWaveHeight + M.voiceVerticalPadding * 2;
    return { x, y: M.voiceLaneY + (M.trackHeight - h) / 2, w, h, rowH };
  }

  private drawVoiceLane(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    const voice = this.snap.voice!;
    ctx.save();
    ctx.beginPath();
    ctx.rect(this.scrollX, M.voiceLaneY, this.viewW, M.trackHeight);
    ctx.clip();
    const [vx0, vx1] = this.visibleRange();
    const ink = t.ink;
    const orange = t.orange;
    if (voice.live) {
      const r = this.voiceClipRect(voice.live);
      ctx.beginPath();
      ctx.roundRect(r.x, r.y, r.w, r.h, Math.min(M.voiceCorner, r.w / 2));
      ctx.fillStyle = rgbaString(orange, 0.24);
      ctx.fill();
      this.strokeInside(ctx, r, M.voiceCorner, rgbaString(orange, 0.95), 1.75);
      this.drawVoiceContent(ctx, t, r, null, "Recording Voice Over", rgbaString(ink, 0.95), true, voice.live.samples, 0.56, 0.04);
      // drawVoiceLiveBlock's edge grips (voiceOrange 0.92).
      ctx.fillStyle = rgbaString(orange, 0.92);
      for (const hx of [r.x + 5, r.x + r.w - 5 - 3]) {
        ctx.beginPath();
        ctx.roundRect(hx, r.y + r.h / 2 - 9, 3, 18, 1);
        ctx.fill();
      }
    }
    for (const clip of voice.clips) {
      const r = this.voiceClipRect(clip);
      if (r.x > vx1 || r.x + r.w < vx0) continue;
      const hovering = this.hoverVoice === clip.id && this.mouse.kind === "idle";
      ctx.save();
      if (this.mouse.kind === "block" && this.mouse.drag.didDrag && this.mouse.drag.target.kind === "voice" &&
        (this.mouse.drag.target.item as VoiceClip).id === clip.id) ctx.globalAlpha = 0.84;
      if (clip.selected) {
        ctx.shadowColor = rgbaString(orange, 0.45);
        ctx.shadowBlur = 12 * this.dpr;
      }
      ctx.beginPath();
      ctx.roundRect(r.x, r.y, r.w, r.h, Math.min(M.voiceCorner, r.w / 2));
      ctx.fillStyle = rgbaString(orange, clip.selected ? 0.38 : hovering ? 0.3 : 0.24);
      ctx.fill();
      ctx.shadowColor = "transparent";
      ctx.shadowBlur = 0;
      this.strokeInside(ctx, r, M.voiceCorner, rgbaString(orange, clip.selected ? 1 : 0.8), clip.selected ? 2 : 1.5);
      this.drawVoiceContent(ctx, t, r, "waveform.and.mic", clip.label, rgbaString(ink, 0.92), false, clip.waveform, 0.52, 0);
      const handle = rgbaString(orange, clip.selected || hovering ? 0.96 : 0.72);
      ctx.fillStyle = handle;
      for (const hx of [r.x + 5, r.x + r.w - 5 - 3]) {
        ctx.beginPath();
        ctx.roundRect(hx, r.y + r.h / 2 - 9, 3, 18, 1);
        ctx.fill();
      }
      ctx.restore();
    }
    ctx.restore();
  }

  private drawVoiceContent(
    ctx: CanvasRenderingContext2D,
    t: CanvasTokens,
    r: { x: number; y: number; w: number; h: number; rowH: number },
    glyphName: string | null,
    title: string,
    titleColor: string,
    dot: boolean,
    samples: ArrayLike<number> | undefined,
    barAlpha: number,
    minAmp: number,
  ) {
    const cx = r.x + M.voiceHorizontalPadding;
    const cw = r.w - M.voiceHorizontalPadding * 2;
    if (cw <= 1) return;
    const top = r.y + M.voiceVerticalPadding;
    let x = cx;
    if (dot) {
      ctx.fillStyle = rgbaString(t.red);
      ctx.beginPath();
      ctx.arc(x + 4, top + r.rowH / 2, 4, 0, Math.PI * 2);
      ctx.fill();
      x += 8 + 6;
    }
    if (glyphName) {
      const g = canvasGlyph(glyphName, 12, titleColor, this.dpr, () => this.invalidate());
      if (g) ctx.drawImage(g, x, top + r.rowH / 2 - 6, 12, 12);
      x += 12 + 5;
    }
    const available = cx + cw - x;
    if (available > 1) {
      const font = `700 11px ${t.font}`;
      ctx.font = font;
      ctx.fillStyle = titleColor;
      ctx.textBaseline = "middle";
      ctx.fillText(truncate(ctx, title, available, (s) => this.measure(ctx, s, font)), x, top + r.rowH / 2 + 0.5);
      ctx.textBaseline = "alphabetic";
    }
    const wy = top + r.rowH + 4;
    const wh = M.voiceWaveHeight;
    const inkRgb = t.ink;
    if (!samples || !samples.length) {
      if (dot) return;
      ctx.fillStyle = rgbaString(inkRgb, 0.14);
      ctx.beginPath();
      ctx.roundRect(cx, wy + wh / 2 - 5, cw, 10, 3);
      ctx.fill();
      return;
    }
    const n = samples.length;
    const barW = Math.max(1, cw / n);
    const maxBar = dot ? Math.max(6, wh - 4) : wh;
    ctx.fillStyle = rgbaString(inkRgb, barAlpha);
    ctx.beginPath();
    const [vx0, vx1] = this.visibleRange();
    const k0 = Math.max(0, Math.floor((vx0 - cx) / barW));
    const k1 = Math.min(n, Math.ceil((vx1 - cx) / barW));
    for (let k = k0; k < k1; k++) {
      const amp = Math.max(minAmp, Math.min(1, samples[k] ?? 0));
      const bh = Math.max(2, amp * maxBar);
      const bw = Math.max(1, barW - 1);
      ctx.roundRect(cx + k * barW, wy + wh / 2 - bh / 2, bw, bh, Math.min(2, bw / 2));
    }
    ctx.fill();
  }

  // EFFECTS / FOCUS / ANNOTATE ──────────────────────────────────────────

  private dragDisplay(key: string, laneY: number): { rect: { x: number; y: number; w: number; h: number }; dimmed: boolean } | null {
    if (this.mouse.kind !== "block") return null;
    const drag = this.mouse.drag;
    if (blockKey(drag.target) !== key) return null;
    if (drag.mode === "move") {
      const committed = this.blockRect(drag.initialStart, drag.initialEnd, laneY);
      const maxX = Math.max(0, this.trackWidth - committed.w);
      const clampedX = Math.min(Math.max(committed.x + drag.translationX, 0), maxX);
      return { rect: { ...committed, x: clampedX }, dimmed: drag.didDrag };
    }
    const r = this.resolve(drag);
    return { rect: this.blockRect(r.start, r.end, laneY), dimmed: drag.didDrag };
  }

  private chipRect(chip: "intro" | "curtain") {
    const c = chip === "intro" ? this.snap.intro : this.snap.curtain;
    if (!c || !(c.end > c.start)) return null;
    return this.blockRect(c.start, c.end, this.effectsRowY(this.effectsRowMap.get(`${chip}-chip`) ?? 0));
  }

  private drawEffectsLane(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    const [vx0, vx1] = this.visibleRange();
    for (const chip of ["intro", "curtain"] as const) {
      const c = chip === "intro" ? this.snap.intro : this.snap.curtain;
      const r = this.chipRect(chip);
      if (!c || !r || r.x > vx1 || r.x + r.w < vx0) continue;
      const hovered = this.hoverKey === `${chip}-chip`;
      this.sprites.draw(ctx, r.x, r.y, r.w, r.h, t.laneEffectTop, t.laneEffectBottom, c.selected, hovered, this.dpr);
      this.drawIconLabel(ctx, t, r, [c.icon], r.w > 52 ? `  ${c.label}` : "", "none");
      if (c.selected || hovered) this.drawGrips(ctx, r);
    }
    const rows = this.liveEffectsRows();
    for (const item of this.snap.effects) {
      const laneY = this.effectsRowY(rows.get(item.key) ?? 0);
      const display = this.dragDisplay(item.key, laneY);
      const r = display?.rect ?? this.blockRect(item.start, item.end, laneY);
      if (r.x > vx1 || r.x + r.w < vx0) continue;
      const hovered = this.hoverKey === item.key;
      ctx.save();
      if (display?.dimmed) ctx.globalAlpha = 0.8;
      this.sprites.draw(ctx, r.x, r.y, r.w, r.h, t.laneEffectTop, t.laneEffectBottom, item.selected, hovered, this.dpr);
      const icons: string[] = [];
      if (item.zoomId) icons.push("plus.magnifyingglass");
      if (item.tiltId) icons.push("rotate.3d");
      if (item.hasSlide) icons.push("arrow.up.to.line");
      let value = "";
      if (r.w > 58) {
        const zoom = `${(item.zoomLevel ?? 1).toFixed(1)}x`;
        const dominant = [item.pitch, item.yaw, item.roll].reduce((a, b) => (Math.abs(b) > Math.abs(a) ? b : a), 0);
        const tilt = `${Math.round(dominant)}°`;
        value = item.zoomId && item.tiltId ? `${zoom} · ${tilt}` : item.zoomId ? zoom : item.tiltId ? tilt : "";
      }
      this.drawIconLabel(ctx, t, r, icons, value, "en");
      if (item.selected || hovered) this.drawGrips(ctx, r);
      ctx.restore();
    }
  }

  private drawFocusLane(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    const [vx0, vx1] = this.visibleRange();
    const laneY = this.focusLaneY;
    // Blurs first, highlights above.
    const ordered = [...this.snap.focus.filter((f) => !f.isHighlight), ...this.snap.focus.filter((f) => f.isHighlight)];
    const font = `600 10px ${t.font}`;
    for (const item of ordered) {
      const key = `f:${item.id}`;
      const display = this.dragDisplay(key, laneY);
      const r = display?.rect ?? this.blockRect(item.start, item.end, laneY);
      if (r.x > vx1 || r.x + r.w < vx0) continue;
      const hovered = this.hoverKey === key;
      ctx.save();
      if (display?.dimmed) ctx.globalAlpha = 0.8;
      const top = item.isHighlight ? t.laneHighlightTop : t.laneBlurTop;
      const bottom = item.isHighlight ? t.laneHighlightBottom : t.laneBlurBottom;
      this.sprites.draw(ctx, r.x, r.y, r.w, r.h, top, bottom, item.selected, hovered, this.dpr);
      const inner = r.w - 16;
      if (inner > 4) {
        ctx.font = font;
        const text = truncate(ctx, item.label, inner, (s) => this.measure(ctx, s, font));
        const tw = this.measure(ctx, text, font);
        ctx.fillStyle = "rgba(255,255,255,0.9)";
        ctx.textBaseline = "middle";
        ctx.fillText(text, r.x + 8 + (inner - tw) / 2, r.y + r.h / 2 + 0.5);
        ctx.textBaseline = "alphabetic";
      }
      if (item.selected || hovered) this.drawGrips(ctx, r);
      ctx.restore();
    }
  }

  private drawAnnotateLane(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    const [vx0, vx1] = this.visibleRange();
    for (const item of this.orderedAnno) {
      const key = `a:${item.id}`;
      const committed = this.annotateRect(item);
      const display = this.dragDisplay(key, committed.y - M.blockInset);
      const r = display?.rect ?? committed;
      if (r.x > vx1 || r.x + r.w < vx0) continue;
      if (r.y + r.h < this.scrollY || r.y > this.scrollY + this.viewH) continue;
      const hovered = this.hoverKey === key;
      ctx.save();
      if (display?.dimmed) ctx.globalAlpha = 0.8;
      this.sprites.draw(ctx, r.x, r.y, r.w, r.h, t.laneAnnotateTop, t.laneAnnotateBottom, item.selected, hovered, this.dpr);
      if (r.h >= 14) this.drawIconLabel(ctx, t, r, [item.icon], r.w > 58 ? item.label : "", "en");
      if (r.h >= 16 && (item.selected || hovered)) this.drawGrips(ctx, r);
      ctx.restore();
    }
  }

  /** Icon(s) + label centred in a block (effect / chip / annotate captions).
   *  `joiner` "en" separates pieces with an en space (effect + annotate
   *  blocks); "none" butts them (settings chips carry "  label"). */
  private drawIconLabel(
    ctx: CanvasRenderingContext2D,
    t: CanvasTokens,
    r: { x: number; y: number; w: number; h: number },
    icons: string[],
    label: string,
    joiner: "en" | "none",
  ) {
    const content = "rgba(255,255,255,0.9)";
    const font = `600 10px ${t.font}`;
    ctx.font = font;
    const glyph = 11; // 9pt SF symbol box
    const gap = joiner === "en" ? this.measure(ctx, EN_SPACE, font) : 0;
    const labelW = label ? this.measure(ctx, label, font) : 0;
    const pieces = icons.length + (label ? 1 : 0);
    if (!pieces) return;
    const total = icons.length * glyph + labelW + (pieces - 1) * gap;
    let x = r.x + r.w / 2 - total / 2;
    const cy = r.y + r.h / 2;
    for (const name of icons) {
      const g = canvasGlyph(name, glyph, content, this.dpr, () => this.invalidate());
      if (g) ctx.drawImage(g, x, cy - glyph / 2, glyph, glyph);
      x += glyph + gap;
    }
    if (label) {
      ctx.fillStyle = content;
      ctx.textBaseline = "middle";
      ctx.fillText(label, x, cy + 0.5);
      ctx.textBaseline = "alphabetic";
    }
  }

  private drawGrips(ctx: CanvasRenderingContext2D, r: { x: number; y: number; w: number; h: number }) {
    ctx.fillStyle = "rgba(255,255,255,0.7)";
    ctx.beginPath();
    const y = r.y + r.h / 2 - 6.5;
    for (const ex of [r.x + 5, r.x + r.w - 5 - 6]) {
      for (let i = 0; i < 2; i++) ctx.roundRect(ex + i * 4, y, 2, 13, 1);
    }
    ctx.fill();
  }

  private drawEmptyLaneHints(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    const lanes: Array<["effects" | "focus" | "annotate", number, boolean]> = [
      ["effects", M.effectsLaneY, this.snap.effects.length === 0],
      ["focus", this.focusLaneY, this.snap.focus.length === 0],
      ["annotate", this.annotateLaneY, this.snap.annotate.length === 0],
    ];
    for (const [lane, y, empty] of lanes) {
      if (this.hoverLane !== lane || !empty) continue;
      const g = canvasGlyph("plus", 17, rgbaString(t.ink, 0.25), this.dpr, () => this.invalidate());
      if (g) ctx.drawImage(g, this.trackWidth / 2 - 8.5, y + M.trackHeight / 2 - 8.5, 17, 17);
    }
  }

  private drawSliceIndicator(ctx: CanvasRenderingContext2D, t: CanvasTokens) {
    if (!this.snap.sliceArmed || this.sliceHoverX == null) return;
    const x = this.sliceHoverX;
    ctx.fillStyle = rgbaString(t.red, 0.9);
    ctx.fillRect(x - 0.75, M.videoLaneY, 1.5, M.trackHeight);
    const g = canvasGlyph("scissors", 18, rgbaString(t.red), this.dpr, () => this.invalidate());
    if (g) ctx.drawImage(g, x - 9, M.videoLaneY + 2, 18, 18);
  }

  // ── Painting: overlay ────────────────────────────────────────────────

  /** Returns true while something is animating (scroller fade). */
  private paintOverlay(): boolean {
    const ctx = this.octx;
    const t = this.tokens!;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.clearRect(0, 0, this.viewW, this.viewH);
    const d = this.snap.outputDuration;
    if (!(d > 0)) return false;
    ctx.save();
    ctx.translate(-this.scrollX, -this.scrollY);
    const bottom = this.tracksBottom;

    if (this.snapGuide != null) {
      const x = this.xFor(Math.min(Math.max(this.snapGuide, 0), d));
      ctx.fillStyle = rgbaString(t.snapGuide);
      ctx.fillRect(x - 0.75, 0, 1.5, bottom);
      ctx.beginPath();
      ctx.moveTo(x - 4.5, 0);
      ctx.lineTo(x + 4.5, 0);
      ctx.lineTo(x, 6);
      ctx.closePath();
      ctx.fill();
    }

    const interacting = this.mouse.kind === "scrubbing";
    if (!(this.snap.timeless && !interacting)) {
      const x = this.xFor(this.currentPlayhead);
      const color = this.sliceSnapped ? t.red : t.cyan;
      ctx.fillStyle = rgbaString(color);
      ctx.fillRect(x - 1, 0, 2, bottom);
      const cy = M.rulerHeight;
      ctx.beginPath();
      ctx.moveTo(x, cy - 8);
      ctx.lineTo(x + 8, cy);
      ctx.lineTo(x, cy + 8);
      ctx.lineTo(x - 8, cy);
      ctx.closePath();
      ctx.fill();
      ctx.strokeStyle = "rgba(255,255,255,0.9)";
      ctx.lineWidth = 1;
      ctx.stroke();
      if (this.mouse.kind === "scrubbing" && this.mouse.playhead) this.drawScrubBubble(ctx, t, x);
    }
    ctx.restore();
    return this.drawScrollers(ctx, t);
  }

  private drawScrubBubble(ctx: CanvasRenderingContext2D, t: CanvasTokens, x: number) {
    const text = formatScrub(this.currentPlayhead);
    const font = `500 10.5px ${t.mono}`;
    ctx.font = font;
    const tw = this.measure(ctx, text, font);
    const th = 13;
    const cap = { x: x + 8, y: -1 + this.scrollY, w: tw + 14, h: th + 6 };
    ctx.beginPath();
    ctx.roundRect(cap.x, cap.y, cap.w, cap.h, cap.h / 2);
    ctx.fillStyle = rgbaString(t.elevated);
    ctx.fill();
    ctx.strokeStyle = rgbaString(t.border);
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.fillStyle = rgbaString(t.foreground);
    ctx.textBaseline = "middle";
    ctx.fillText(text, cap.x + 7, cap.y + cap.h / 2 + 0.5);
    ctx.textBaseline = "alphabetic";
  }

  private showScrollers() {
    this.scrollerShownAt = performance.now();
    this.dirtyOverlay = true;
    this.schedule();
  }

  /** macOS overlay scrollers: appear while scrolling, fade after ~0.8s. */
  private drawScrollers(ctx: CanvasRenderingContext2D, t: CanvasTokens): boolean {
    const age = performance.now() - this.scrollerShownAt;
    const hold = 800;
    const fade = 250;
    if (age > hold + fade) return false;
    const alpha = age < hold ? 1 : 1 - (age - hold) / fade;
    const ink = t.dark ? { r: 255, g: 255, b: 255, a: 1 } : { r: 0, g: 0, b: 0, a: 1 };
    ctx.fillStyle = rgbaString(ink, 0.35 * alpha);
    const tw = this.trackWidth;
    if (tw > this.viewW + 1) {
      const len = Math.max(24, (this.viewW / tw) * (this.viewW - 8));
      const x = 4 + (this.scrollX / (tw - this.viewW)) * (this.viewW - 8 - len);
      ctx.beginPath();
      ctx.roundRect(x, this.viewH - 8, len, 5, 2.5);
      ctx.fill();
    }
    const dh = this.docHeight;
    if (dh > this.viewH + 1) {
      const len = Math.max(24, (this.viewH / dh) * (this.viewH - 8));
      const y = 4 + (this.scrollY / (dh - this.viewH)) * (this.viewH - 8 - len);
      ctx.beginPath();
      ctx.roundRect(this.viewW - 8, y, 5, len, 2.5);
      ctx.fill();
    }
    return true;
  }

  // ── Scrolling ─────────────────────────────────────────────────────────

  private clampScroll() {
    const maxX = Math.max(0, this.trackWidth - this.viewW);
    const maxY = Math.max(0, this.docHeight - this.viewH);
    const nx = Math.min(Math.max(0, this.scrollX), maxX);
    const ny = Math.min(Math.max(0, this.scrollY), maxY);
    if (ny !== this.scrollY) this.hooks.onScrollY?.(ny);
    this.scrollX = nx;
    this.scrollY = ny;
  }

  scrollBy(dx: number, dy: number) {
    const ox = this.scrollX;
    const oy = this.scrollY;
    this.scrollX += dx;
    this.scrollY += dy;
    this.clampScroll();
    if (ox !== this.scrollX || oy !== this.scrollY) {
      if (oy !== this.scrollY) this.hooks.onScrollY?.(this.scrollY);
      this.showScrollers();
      this.invalidate();
    }
  }

  /** Page-jump to keep the playhead in view while playing (CapCut/FCP feel). */
  private followPlayhead() {
    const width = this.trackWidth;
    if (!(width > this.viewW + 1)) return;
    const x = this.xFor(this.playhead);
    const margin = 24;
    if (x > this.scrollX + this.viewW - margin || x < this.scrollX) {
      this.scrollX = Math.max(0, Math.min(width - this.viewW, x - margin));
      this.invalidate();
    }
  }

  // ── Hit testing ──────────────────────────────────────────────────────

  private docPoint(e: { clientX: number; clientY: number }) {
    const r = this.host.getBoundingClientRect();
    return { x: e.clientX - r.left + this.scrollX, y: e.clientY - r.top + this.scrollY };
  }

  private laneRect(y: number) {
    return { x: 0, y, w: this.trackWidth, h: M.trackHeight };
  }

  private inRect(p: { x: number; y: number }, r: { x: number; y: number; w: number; h: number }, dx = 0, dy = 0) {
    return p.x >= r.x - dx && p.x <= r.x + r.w + dx && p.y >= r.y - dy && p.y <= r.y + r.h + dy;
  }

  private effectsLaneRect() {
    return { x: 0, y: M.effectsLaneY, w: this.trackWidth, h: M.trackHeight + this.effectsExtra };
  }

  private annotateLaneRect() {
    return { x: 0, y: this.annotateLaneY, w: this.trackWidth, h: M.trackHeight + this.annotateExtra };
  }

  private effectAt(p: { x: number; y: number }): EffectBlock | null {
    if (!this.inRect(p, this.effectsLaneRect())) return null;
    const items = this.snap.effects;
    for (let i = items.length - 1; i >= 0; i--) {
      const item = items[i];
      const r = this.blockRect(item.start, item.end, this.effectsRowY(this.effectsRowMap.get(item.key) ?? 0));
      if (this.inRect(p, r, 0, M.blockInset)) return item;
    }
    return null;
  }

  private focusAt(p: { x: number; y: number }): FocusBlock | null {
    if (!this.inRect(p, this.laneRect(this.focusLaneY))) return null;
    const ordered = [...this.snap.focus.filter((f) => f.isHighlight), ...this.snap.focus.filter((f) => !f.isHighlight)];
    for (const item of ordered) {
      if (this.inRect(p, this.blockRect(item.start, item.end, this.focusLaneY), 0, M.blockInset)) return item;
    }
    return null;
  }

  private annotateAt(p: { x: number; y: number }): AnnotateBlock | null {
    if (!this.inRect(p, this.annotateLaneRect())) return null;
    for (let i = this.orderedAnno.length - 1; i >= 0; i--) {
      const item = this.orderedAnno[i];
      if (this.inRect(p, this.annotateRect(item), 0, 1)) return item;
    }
    return null;
  }

  private voiceAt(p: { x: number; y: number }): VoiceClip | null {
    const voice = this.snap.voice;
    if (!voice || !this.inRect(p, this.laneRect(M.voiceLaneY))) return null;
    for (let i = voice.clips.length - 1; i >= 0; i--) {
      const r = this.voiceClipRect(voice.clips[i]);
      if (p.x >= r.x && p.x <= r.x + r.w) return voice.clips[i];
    }
    return null;
  }

  private dragModeFor(p: { x: number }, start: number, end: number, handle = M.handleWidth): DragMode {
    const ox = this.xFor(start);
    const d = this.snap.outputDuration;
    const w = Math.max(M.minBlockWidth, d > 0 ? (this.trackWidth * (end - start)) / d : 0);
    const local = Math.min(Math.max(p.x - ox, 0), w);
    if (local < handle) return "resizeLeft";
    if (local > w - handle) return "resizeRight";
    return "move";
  }

  /** VOICE drags resolve through the core VoiceTrackEditMath (head-trim
   *  aware), exactly like VoiceTrackRowNative — not the generic block math. */
  private resolveVoice(drag: BlockDrag): VoiceOverClip | null {
    if (drag.target.kind !== "voice") return null;
    const value = drag.target.item.value;
    if (!value) return null;
    const math = new VoiceTrackEditMath({
      totalDuration: this.snap.outputDuration,
      trackWidth: this.trackWidth,
      snapCandidates: [...(this.snap.voice?.snapCandidates ?? []), this.currentPlayhead],
      minDuration: M.voiceMinDuration,
    });
    return math.resolvedClip(value, drag.mode, math.delta(drag.translationX));
  }

  private resolve(drag: BlockDrag) {
    const voice = this.resolveVoice(drag);
    if (voice) return { start: voice.startTime, end: voice.startTime + voice.duration };
    return resolveBlockDrag({
      mode: drag.mode,
      initialStart: drag.initialStart,
      initialEnd: drag.initialEnd,
      translationX: drag.translationX,
      trackWidth: this.trackWidth,
      duration: this.snap.outputDuration,
      snapCandidates: drag.snapCandidates,
      otherSpans: drag.otherSpans,
      usesLegacyGrace: drag.usesLegacyGrace,
      minDuration: drag.minDuration,
    });
  }

  private baseCandidates(): number[] {
    return [this.snap.trimStartOutput, this.snap.trimEndOutput, this.currentPlayhead];
  }

  private beginBlockDrag(target: BlockTarget, p: { x: number; y: number }, start: number, end: number) {
    const snap = this.snap;
    const cands = this.baseCandidates();
    let spans: Array<[number, number]> = [];
    let legacy = false;
    let minDuration: number = M.minDuration;
    if (target.kind === "effect") {
      for (const f of snap.focus) cands.push(f.start, f.end);
      for (const o of snap.effects) if (o.key !== target.item.key) cands.push(o.start, o.end);
      spans = snap.effects.filter((o) => o.key !== target.item.key).map((o) => [o.start, o.end]);
      if (snap.intro && snap.intro.end > snap.intro.start) spans.push([snap.intro.start, snap.intro.end]);
      if (snap.curtain && snap.curtain.end > snap.curtain.start) spans.push([snap.curtain.start, snap.curtain.end]);
      legacy = true;
    } else if (target.kind === "focus") {
      for (const e of snap.effects) if (e.zoomId) cands.push(e.start, e.end);
      for (const o of snap.focus) if (o.id !== target.item.id) cands.push(o.start, o.end);
      spans = snap.focus.filter((o) => o.id !== target.item.id).map((o) => [o.start, o.end]);
    } else if (target.kind === "annotate") {
      for (const e of snap.effects) cands.push(e.start, e.end);
      for (const f of snap.focus) cands.push(f.start, f.end);
      for (const o of snap.annotate) if (o.id !== target.item.id) cands.push(o.start, o.end);
    } else {
      for (const o of snap.voice?.clips ?? []) if (o.id !== target.item.id) cands.push(o.start, o.end);
      spans = (snap.voice?.clips ?? []).filter((o) => o.id !== target.item.id).map((o) => [o.start, o.end]);
      minDuration = M.voiceMinDuration;
    }
    this.mouse = {
      kind: "block",
      drag: {
        target,
        mode: this.dragModeFor(p, start, end, target.kind === "voice" ? M.voiceHandleWidth : M.handleWidth),
        initialStart: start,
        initialEnd: end,
        startX: p.x,
        startY: p.y,
        translationX: 0,
        didDrag: false,
        snapCandidates: cands,
        otherSpans: spans,
        usesLegacyGrace: legacy,
        minDuration,
      },
    };
  }

  // ── Pointer events ───────────────────────────────────────────────────

  private setCursor(cursor: string) {
    if (cursor === this.cursor) return;
    this.cursor = cursor;
    this.host.style.cursor = cursor;
  }

  private playheadHit(p: { x: number; y: number }) {
    return (
      !this.snap.timeless &&
      this.snap.outputDuration > 0 &&
      Math.abs(p.x - this.xFor(this.currentPlayhead)) <= M.playheadStripHalfWidth &&
      p.y <= this.tracksBottom + 10
    );
  }

  private onPointerDown = (e: PointerEvent) => {
    if (e.button !== 0) return;
    const p = this.docPoint(e);
    if (!(this.snap.outputDuration > 0)) return;
    this.host.setPointerCapture(e.pointerId);
    const intents = this.hooks.intents;

    // Playhead grab strip wins (TimelinePlayheadOverlayView.hitTest).
    if (!this.snap.sliceArmed && this.playheadHit(p)) {
      this.mouse = { kind: "scrubbing", playhead: true };
      this.scrubTo(p.x);
      return;
    }

    const video = this.snap.video;
    if (video && this.inRect(p, this.laneRect(M.videoLaneY))) {
      if (this.snap.sliceArmed) {
        this.mouse = { kind: "slicing" };
        return;
      }
      const block = this.videoBlockGeometry(false);
      if (video.hasAudio && this.inRect(p, this.muteRect(block))) {
        intents.action?.({ type: "toggleMute" });
        return;
      }
      // videoMouseDown: the lane owns the gesture; an empty click deselects on release.
      const kind = this.videoDragKind(p);
      this.mouse = kind ? { kind: "video", drag: { kind, startX: p.x, translationX: 0, didDrag: false } } : { kind: "videoDeselect" };
      return;
    }

    if (this.snap.voice && this.inRect(p, this.laneRect(M.voiceLaneY))) {
      const clip = this.voiceAt(p);
      if (clip) {
        if (!clip.selected) intents.select({ lane: "voice", clipId: clip.id });
        this.beginBlockDrag({ kind: "voice", item: clip }, p, clip.start, clip.end);
      } else {
        intents.select(null, "voice");
        this.mouse = { kind: "scrubbing", playhead: false };
        this.scrubTo(p.x);
      }
      return;
    }

    const effect = this.effectAt(p);
    for (const chip of ["intro", "curtain"] as const) {
      const r = this.chipRect(chip);
      if (!r || effect || !this.inRect(p, r, 4, 0)) continue;
      if (Math.abs(p.x - (r.x + r.w)) <= 6) {
        this.mouse = { kind: "chipEdge", chip };
        return;
      }
      if (this.inRect(p, r)) {
        const c = chip === "intro" ? this.snap.intro! : this.snap.curtain!;
        this.mouse = { kind: "chipMove", chip, downX: p.x, initialStart: c.start, didDrag: false };
        return;
      }
    }

    if (effect) {
      if (!effect.selected) intents.select({ lane: "effects", key: effect.key, zoomId: effect.zoomId, tiltId: effect.tiltId });
      this.beginBlockDrag({ kind: "effect", item: effect }, p, effect.start, effect.end);
      this.setCursor("default");
      return;
    }
    const focus = this.focusAt(p);
    if (focus) {
      if (!focus.selected) intents.select({ lane: "focus", id: focus.id, isHighlight: focus.isHighlight });
      this.beginBlockDrag({ kind: "focus", item: focus }, p, focus.start, focus.end);
      this.setCursor("default");
      return;
    }
    const anno = this.annotateAt(p);
    if (anno) {
      if (!anno.selected) intents.select({ lane: "annotate", id: anno.id });
      this.beginBlockDrag({ kind: "annotate", item: anno }, p, anno.start, anno.end);
      this.setCursor("default");
      return;
    }

    if (this.inRect(p, this.effectsLaneRect())) intents.select(null, "effects");
    else if (this.inRect(p, this.laneRect(this.focusLaneY))) intents.select(null, "focus");
    else if (this.inRect(p, this.annotateLaneRect())) intents.select(null, "annotate");
    else if (p.y >= M.videoLaneY) return;
    this.mouse = { kind: "scrubbing", playhead: false };
    this.scrubTo(p.x);
  };

  private scrubTo(x: number) {
    const t = this.timeAt(x);
    this.playheadOverride = t;
    this.hooks.intents.scrub(t);
    this.dirtyOverlay = true;
    this.schedule();
  }

  private onPointerMove = (e: PointerEvent) => {
    const p = this.docPoint(e);
    const m = this.mouse;
    if (m.kind === "idle") {
      this.updateHover(p);
      return;
    }
    // Auto-scroll when dragging past the viewport edges.
    const local = p.x - this.scrollX;
    if ((m.kind === "block" || m.kind === "scrubbing" || m.kind === "video") && (local < 0 || local > this.viewW)) {
      const dx = local < 0 ? Math.max(-24, local / 2) : Math.min(24, (local - this.viewW) / 2);
      this.scrollBy(dx, 0);
    }
    switch (m.kind) {
      case "scrubbing":
        this.scrubTo(p.x);
        break;
      case "slicing":
        this.updateSliceHover(p);
        break;
      case "chipEdge": {
        const c = m.chip === "intro" ? this.snap.intro : this.snap.curtain;
        if (!c) break;
        let end = this.timeAt(p.x);
        for (const b of this.chipBlockers(m.chip, c.start, c.end)) if (b[1] > c.start && b[0] < end) end = Math.min(end, b[0]);
        this.hooks.intents.resizeChip?.(m.chip, end);
        break;
      }
      case "chipMove": {
        const dx = p.x - m.downX;
        if (!m.didDrag && Math.abs(dx) >= M.dragThreshold) m.didDrag = true;
        if (!m.didDrag) break;
        const c = m.chip === "intro" ? this.snap.intro : this.snap.curtain;
        if (!c) break;
        const d = this.snap.outputDuration;
        const dt = (dx / Math.max(1, this.trackWidth)) * d;
        const len = c.end - c.start;
        const proposed = m.initialStart + dt;
        let start = Math.max(0, Math.min(d - len, proposed));
        for (const b of this.chipBlockers(m.chip, c.start, c.end)) {
          if (start < b[1] && start + len > b[0]) {
            const leftPos = b[0] - len;
            const rightPos = b[1];
            start = Math.abs(proposed - leftPos) <= Math.abs(proposed - rightPos) ? Math.max(0, leftPos) : Math.min(d - len, rightPos);
          }
        }
        this.hooks.intents.moveChip?.(m.chip, start);
        break;
      }
      case "video": {
        // videoMouseDragged
        const drag = m.drag;
        drag.translationX = p.x - drag.startX;
        if (Math.abs(drag.translationX) > videoThreshold(drag.kind)) drag.didDrag = true;
        if (drag.kind.type === "boundary" && !drag.resolved && Math.abs(drag.translationX) > 0.25) {
          const b = drag.kind.boundary;
          const clips = this.snap.video?.clips ?? [];
          const clip = clips.find((c) => c.id === (drag.translationX < 0 ? b.leftClipId : b.rightClipId));
          if (clip) drag.resolved = { clip, side: drag.translationX < 0 ? "right" : "left" };
        }
        this.dirtyBase = true;
        this.schedule();
        break;
      }
      case "block": {
        const drag = m.drag;
        drag.translationX = p.x - drag.startX;
        const dy = p.y - drag.startY;
        if (!drag.didDrag && Math.hypot(drag.translationX, dy) >= M.dragThreshold) drag.didDrag = true;
        const resolved = this.resolve(drag);
        this.snapGuide = snappedEdge(resolved.start, resolved.end, drag.snapCandidates, drag.mode !== "resizeRight", drag.mode !== "resizeLeft");
        if (drag.didDrag) this.hooks.intents.previewTimes?.(targetOf(drag.target), resolved.start, resolved.end);
        this.invalidate();
        break;
      }
      default:
        break;
    }
  };

  private chipBlockers(chip: "intro" | "curtain", start: number, end: number): Array<[number, number]> {
    const blockers: Array<[number, number]> = this.snap.effects
      .filter((e) => !(e.start < end - 0.0001 && e.end > start + 0.0001))
      .map((e) => [e.start, e.end]);
    const other = chip === "intro" ? this.snap.curtain : this.snap.intro;
    if (other && other.end > other.start) blockers.push([other.start, other.end]);
    return blockers;
  }

  private onPointerUp = (e: PointerEvent) => {
    const p = this.docPoint(e);
    const m = this.mouse;
    const intents = this.hooks.intents;
    this.mouse = { kind: "idle" };
    if (this.host.hasPointerCapture(e.pointerId)) this.host.releasePointerCapture(e.pointerId);
    switch (m.kind) {
      case "scrubbing": {
        const t = this.timeAt(p.x);
        intents.seek(t);
        // Hold the local playhead until the channel reports the seek.
        this.playhead = t;
        this.playheadOverride = null;
        break;
      }
      case "slicing": {
        const target = this.sliceTarget(p);
        if (target != null) intents.sliceAt?.(target.time);
        this.sliceHoverX = null;
        this.sliceSnapped = false;
        break;
      }
      case "chipMove":
        if (!m.didDrag) intents.openChip?.(m.chip);
        break;
      case "video":
        if (this.snap.video) this.finishVideoDrag(m.drag, p);
        break;
      case "videoDeselect":
        intents.select(null, "video");
        break;
      case "block": {
        const drag = m.drag;
        drag.translationX = p.x - drag.startX;
        const voice = drag.didDrag && intents.voiceCommit ? this.resolveVoice(drag) : null;
        if (voice && drag.target.kind === "voice") {
          intents.voiceCommit!(drag.target.item.id, voice);
        } else if (drag.didDrag) {
          const r = this.resolve(drag);
          intents.commitTimes(targetOf(drag.target), r.start, r.end);
        } else {
          intents.select(targetOf(drag.target));
        }
        this.snapGuide = null;
        break;
      }
      default:
        break;
    }
    this.invalidate();
  };

  private onPointerLeave = () => {
    if (this.mouse.kind !== "idle") return;
    this.hoverLane = null;
    this.hoverKey = null;
    this.hoverVideo = false;
    this.hoverVoice = null;
    this.sliceHoverX = null;
    this.sliceSnapped = false;
    this.setCursor("default");
    this.invalidate();
  };

  private updateHover(p: { x: number; y: number }) {
    const before = `${this.hoverLane}|${this.hoverKey}|${this.hoverVideo}|${this.hoverVoice}|${this.sliceHoverX}`;
    let cursor = "default";
    const video = this.snap.video;

    if (this.snap.sliceArmed && video && this.inRect(p, this.laneRect(M.videoLaneY))) {
      this.hoverLane = null;
      this.hoverKey = null;
      this.hoverVideo = false;
      this.updateSliceHover(p);
      this.setCursor(this.sliceHoverX != null ? "crosshair" : "default");
      return;
    }
    if (this.sliceHoverX != null) {
      this.sliceHoverX = null;
      this.sliceSnapped = false;
    }

    this.hoverLane = this.inRect(p, this.effectsLaneRect())
      ? "effects"
      : this.inRect(p, this.laneRect(this.focusLaneY))
        ? "focus"
        : this.inRect(p, this.annotateLaneRect())
          ? "annotate"
          : null;

    let key: string | null = null;
    if (this.playheadHit(p)) {
      cursor = "ew-resize";
    } else {
      const effect = this.effectAt(p);
      const focus = effect ? null : this.focusAt(p);
      const anno = effect || focus ? null : this.annotateAt(p);
      const hit = effect ?? focus ?? anno;
      if (hit) {
        key = effect ? effect.key : focus ? `f:${focus.id}` : `a:${anno!.id}`;
        const mode = this.dragModeFor(p, hit.start, hit.end);
        cursor = mode === "move" ? "grab" : "ew-resize";
      } else {
        for (const chip of ["intro", "curtain"] as const) {
          const r = this.chipRect(chip);
          if (r && this.inRect(p, r)) {
            key = `${chip}-chip`;
            cursor = Math.abs(p.x - (r.x + r.w)) <= 6 ? "ew-resize" : "grab";
          }
        }
      }
    }
    this.hoverKey = key;

    this.hoverVideo = !!video && this.inRect(p, this.laneRect(M.videoLaneY));
    if (this.hoverVideo && video && !key && cursor === "default") {
      // videoHoverCursor
      const block = this.videoBlockGeometry(false);
      const onMute = video.hasAudio && this.inRect(p, this.muteRect(block));
      const kind = onMute ? null : this.videoDragKind(p);
      if (kind && (kind.type === "clipEdge" || kind.type === "boundary" || (kind.type === "whole" && kind.mode !== "move"))) cursor = "ew-resize";
    }
    const voice = this.snap.voice && this.inRect(p, this.laneRect(M.voiceLaneY)) ? this.voiceAt(p) : null;
    this.hoverVoice = voice?.id ?? null;
    if (voice && cursor === "default") {
      cursor = this.dragModeFor(p, voice.start, voice.end, M.voiceHandleWidth) === "move" ? "grab" : "ew-resize";
    }
    this.setCursor(cursor);
    const after = `${this.hoverLane}|${this.hoverKey}|${this.hoverVideo}|${this.hoverVoice}|${this.sliceHoverX}`;
    if (after !== before) {
      this.dirtyBase = true;
      this.schedule();
    }
  }

  /** Slice target — core VideoSliceMath (resolvedTarget + isSliceable), the
   *  same rule the ⌘B edit uses, so hover, click and split agree. */
  private sliceTarget(p: { x: number }): { x: number; time: number; snapped: boolean } | null {
    const video = this.snap.video;
    if (!this.snap.sliceArmed || !video) return null;
    const target = resolvedSliceTarget(p.x, this.trackWidth, this.snap.outputDuration, this.currentPlayhead);
    const spans = video.clips.map((c) => ({ id: c.id, outputStart: c.outputStart, outputEnd: c.outputEnd }));
    if (!isSliceable(target.outputTime, this.snap.trimStartOutput, this.snap.trimEndOutput, spans)) return null;
    return { x: target.x, time: target.outputTime, snapped: target.snappedToPlayhead };
  }

  private updateSliceHover(p: { x: number }) {
    const target = this.sliceTarget(p);
    const x = target?.x ?? null;
    const snapped = target?.snapped ?? false;
    if (x !== this.sliceHoverX || snapped !== this.sliceSnapped) {
      this.sliceHoverX = x;
      this.sliceSnapped = snapped;
      this.invalidate();
    }
  }

  private onWheel = (e: WheelEvent) => {
    e.preventDefault();
    if (e.ctrlKey) {
      // Trackpad pinch arrives as ctrl+wheel in Chromium/Firefox.
      // Anchored on the playhead like every Mac zoom path (setTimelineScale).
      const next = this.scale * Math.exp(-e.deltaY * 0.01);
      this.setScale(next);
      this.reportScale();
      return;
    }
    let dx = e.deltaX;
    let dy = e.deltaY;
    if (e.deltaMode === 1) {
      dx *= 16;
      dy *= 16;
    }
    if (e.shiftKey && dx === 0) {
      dx = dy;
      dy = 0;
    }
    // No vertical overflow: a plain wheel pans the time axis.
    if (this.docHeight <= this.viewH + 1 && Math.abs(dy) > Math.abs(dx)) {
      dx = dy;
      dy = 0;
    }
    this.scrollBy(dx, dy);
  };

  private gestureBase = 1;
  private onGestureStart = (e: Event & { scale?: number }) => {
    e.preventDefault();
    this.gestureBase = this.scale;
  };
  private onGestureChange = (e: Event & { scale?: number }) => {
    e.preventDefault();
    this.setScale(this.gestureBase * (e.scale ?? 1));
    this.reportScale();
  };

  private onContextMenu = (e: MouseEvent) => {
    e.preventDefault();
    const p = this.docPoint(e);
    const time = this.timeAt(p.x);
    const base = { clientX: e.clientX, clientY: e.clientY, time };
    const video = this.snap.video;
    let req: ContextMenuRequest = { ...base, lane: p.y < M.videoLaneY ? "ruler" : null, target: null };
    if (video && this.inRect(p, this.laneRect(M.videoLaneY))) {
      const block = this.videoBlockGeometry(false);
      let segment: ContextMenuRequest["segment"];
      for (const clip of video.clips) {
        const r = this.videoClipRect(clip, block);
        if (p.x < r.x || p.x > r.x + r.w) continue;
        const f = (p.x - r.x) / Math.max(1, r.w);
        const t = clip.outputStart + f * (clip.outputEnd - clip.outputStart);
        if (clip.fillSpeed != null) {
          segment = { sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd, outputStart: clip.outputStart, regionId: clip.fillRegionId, startsAtSplit: false };
        } else {
          const s = video.segments.find((s) => s.clipId === clip.id && t >= s.outputStart && t <= s.outputEnd);
          if (s) segment = { sourceStart: s.sourceStart, sourceEnd: s.sourceEnd, outputStart: s.outputStart, regionId: s.regionId, startsAtSplit: s.startsAtSplit };
        }
      }
      req = { ...base, lane: "video", target: null, segment };
    } else if (this.snap.voice && this.inRect(p, this.laneRect(M.voiceLaneY))) {
      const clip = this.voiceAt(p);
      req = { ...base, lane: "voice", target: clip ? { lane: "voice", clipId: clip.id } : null };
    } else {
      const effect = this.effectAt(p);
      const chip = !effect
        ? (["intro", "curtain"] as const).find((c) => {
            const r = this.chipRect(c);
            return r && this.inRect(p, r);
          })
        : undefined;
      if (chip) req = { ...base, lane: "effects", target: { lane: chip } };
      else if (effect) req = { ...base, lane: "effects", target: { lane: "effects", key: effect.key, zoomId: effect.zoomId, tiltId: effect.tiltId }, effect };
      else {
        const focus = this.focusAt(p);
        const anno = focus ? null : this.annotateAt(p);
        if (focus) req = { ...base, lane: "focus", target: { lane: "focus", id: focus.id, isHighlight: focus.isHighlight } };
        else if (anno) req = { ...base, lane: "annotate", target: { lane: "annotate", id: anno.id } };
        else if (this.inRect(p, this.annotateLaneRect())) req = { ...base, lane: "annotate", target: null };
        else if (this.inRect(p, this.effectsLaneRect())) req = { ...base, lane: "effects", target: null };
        else if (this.inRect(p, this.laneRect(this.focusLaneY))) req = { ...base, lane: "focus", target: null };
      }
    }
    this.hooks.onContextMenu?.(req);
  };
}

// ── helpers ─────────────────────────────────────────────────────────────

function blockKey(t: BlockTarget): string {
  switch (t.kind) {
    case "effect":
      return t.item.key;
    case "focus":
      return `f:${t.item.id}`;
    case "annotate":
      return `a:${t.item.id}`;
    case "voice":
      return `v:${t.item.id}`;
  }
}

function targetOf(t: BlockTarget): TimelineTarget {
  switch (t.kind) {
    case "effect":
      return { lane: "effects", key: t.item.key, zoomId: t.item.zoomId, tiltId: t.item.tiltId };
    case "focus":
      return { lane: "focus", id: t.item.id, isHighlight: t.item.isHighlight };
    case "annotate":
      return { lane: "annotate", id: t.item.id };
    case "voice":
      return { lane: "voice", clipId: t.item.id };
  }
}

export function segmentLabel(outputSpan: number, speed: number): string {
  const src = outputSpan * speed;
  const d = src < 1 ? `${src.toFixed(1)}s` : `${Math.round(src)}s`;
  return `${d} · ${formatSpeed(speed)}`;
}

export function formatSpeed(s: number): string {
  return Math.abs(s - Math.round(s)) < 0.01 ? `${s.toFixed(0)}x` : `${s.toFixed(1)}x`;
}

function truncate(_ctx: CanvasRenderingContext2D, text: string, max: number, measure: (s: string) => number): string {
  if (measure(text) <= max) return text;
  let lo = 0;
  let hi = text.length;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (measure(`${text.slice(0, mid)}…`) <= max) lo = mid;
    else hi = mid - 1;
  }
  return lo > 0 ? `${text.slice(0, lo)}…` : "";
}

