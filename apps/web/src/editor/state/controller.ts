/**
 * EditorController — binds the store (state/store.ts), the engine client and
 * the shell: every timeline intent, toolbar pick, keyboard shortcut and
 * transport command lands here and is routed into the Mac's own edit logic
 * (state/edits.ts), converting OUTPUT ↔ SOURCE time at the boundary exactly
 * like TimelineViewController's canvas callbacks.
 *
 * React-free on purpose: the page builds one per project and hands its
 * callbacks to the shell; per-frame time flows through `playhead`.
 */
import type { AnnotationType, BlurStyle, Rect, VoiceOverClip } from "../core/model";
import { effectiveTrimEnd, effectiveTrimStart, effectiveVideoClipSegments } from "../core/time/clips";
import type { EngineClient } from "../engine/client";
import type { AnnotationPick, EditorShellCallbacks, EffectsPick, FocusPick, InspectorTabId } from "../ui/shell/types";
import { createPlayheadChannel } from "../ui/shell/types";
import type { LaneId, TimelineAction, TimelineIntents, TimelineTarget } from "../ui/timeline/types";
import * as E from "./edits";
import { escapeSelection } from "./escapeSelection";
import { assign, assignAll, type Selection } from "./selection";
import type { EditorStore } from "./store";

export interface ControllerHooks {
  /** Arms the stage's drag-to-draw blur (PreviewInteractionView.armBlurDraw). */
  armBlurDraw?(style: BlurStyle): void;
  /** Opens the stage's in-place label editor on a fresh text/callout. */
  beginInlineEdit?(annotationId: string): void;
  /** ✨ Auto Zoom (AutoZoomApplier) — returns regions created (0 = none). */
  autoZoom?(): Promise<number> | number;
  /** Motion (StillMotionApplier) for image captures. */
  stillMotion?(): Promise<number> | number;
  /** The mic key: start/stop voice-over recording (ui/voiceover/VoiceOver.tsx). */
  toggleVoiceOver?(): void;
  showProjects?(): void;
  exportVideo?(): void;
  /** Top-bar Share: export an MP4 + upload a share link (ui/export/useShareCenter). */
  share?(): void;
}

export class EditorController {
  readonly playhead = createPlayheadChannel(0);
  client: EngineClient | null = null;
  hooks: ControllerHooks = {};
  /** The pill's chosen colour (applyToolbarColor with nothing selected). */
  toolbarAnnotationColor: { red: number; green: number; blue: number; opacity: number } | null = null;

  constructor(readonly store: EditorStore) {
    store.setPlayheadProvider(() => this.playhead.get());
    // The Mac's playhead is SOURCE time (`playback.currentTime`): a trim or
    // speed edit keeps the same frame under the playhead and moves its
    // OUTPUT position. Ours is OUTPUT time, so remap it when the map changes.
    let last = store.getState().project;
    store.subscribe(() => {
      const next = store.getState().project;
      const prev = last;
      last = next;
      if (!prev || !next || prev === next) return;
      let remap: number | null = null;
      const mapChanged =
        prev.trimStart !== next.trimStart || prev.trimEnd !== next.trimEnd || prev.duration !== next.duration || prev.speedRegions !== next.speedRegions;
      if (mapChanged && !this.client?.transport?.playing) {
        const source = E.fullTimeMap(prev).sourceTime(this.playhead.get());
        remap = Math.max(0, Math.min(E.timelineOutputDuration(next), E.fullTimeMap(next).outputTime(source)));
        this.playhead.set(remap); // the timeline follows at once
      }
      this.scheduleEnginePush(remap);
    });
  }

  // ── Store → engine ─────────────────────────────────────────────────────

  private pushFrame = 0;
  private pendingSeek: number | null = null;

  /**
   * One engine update per animation frame: the new project FIRST, then any
   * playhead remap seek — a seek must never be resolved against the old
   * time map (it raced the scene rebuild and imported a released frame).
   */
  private scheduleEnginePush(seekTo: number | null): void {
    if (seekTo !== null) this.pendingSeek = seekTo;
    if (this.pushFrame) return;
    const run = () => {
      this.pushFrame = 0;
      const client = this.client;
      const project = this.store.getState().project;
      const seek = this.pendingSeek;
      this.pendingSeek = null;
      if (!client || !project) return;
      client.setProject(this.store.documentJSON(project));
      if (seek !== null) void client.seek(seek);
    };
    if (typeof requestAnimationFrame === "function") this.pushFrame = requestAnimationFrame(run);
    else run();
  }

  private get project() {
    return this.store.getState().project;
  }

  private get selection(): Selection {
    return this.store.getState().selection;
  }

  // ── Transport ──────────────────────────────────────────────────────────

  timelineDuration(): number {
    const p = this.project;
    return p ? E.timelineOutputDuration(p) : 0;
  }

  /** Committed (exact) seek, OUTPUT seconds. */
  seek(outputTime: number): void {
    const t = Math.max(0, Math.min(this.timelineDuration(), outputTime));
    this.playhead.set(t);
    void this.client?.seek(t);
  }

  /** seekToSource — the Mac's `seekToSource(_:)`. */
  seekToSource(sourceTime: number): void {
    const p = this.project;
    if (!p) return;
    this.seek(E.fullTimeMap(p).outputTime(sourceTime));
  }

  pause(): void {
    if (this.client?.transport?.playing) this.client.pause();
  }

  togglePlay(): void {
    const c = this.client;
    if (!c) return;
    if (c.transport?.playing) c.pause();
    else c.play();
  }

  /** stepPlayhead(byOutput:) — pauses, clamps to [0, trimEnd − 1 ms]. */
  step(delta: number): void {
    const p = this.project;
    if (!p) return;
    this.pause();
    const end = E.fullTimeMap(p).outputDuration;
    this.seek(Math.min(Math.max(this.playhead.get() + delta, 0), Math.max(0, end - 0.001)));
  }

  goToStart(): void {
    const p = this.project;
    if (p) this.seekToSource(effectiveTrimStart(p));
  }

  goToEnd(): void {
    const p = this.project;
    if (p) this.seekToSource(Math.max(effectiveTrimStart(p), effectiveTrimEnd(p) - 0.01));
  }

  // ── Edits ──────────────────────────────────────────────────────────────

  apply(edit: E.Edit, coalesceKey?: string) {
    return this.store.apply(edit, coalesceKey ? { coalesceKey } : {});
  }

  private sourceAt(outputTime: number): number {
    const p = this.project;
    return p ? E.fullTimeMap(p).sourceTime(outputTime) : outputTime;
  }

  addAnnotation(type: AnnotationType, atSource?: number): string | null {
    const outcome = this.apply(E.addAnnotation(type, atSource, this.toolbarAnnotationColor));
    const id = outcome?.selection?.annotationId ?? null;
    if (id && atSource === undefined && (type === "text" || type === "callout")) this.hooks.beginInlineEdit?.(id);
    return id;
  }

  createBlurRegion(rect: Rect, style: BlurStyle): void {
    this.apply(E.createBlurRegion(rect, style));
  }

  undo(): void {
    this.store.undo();
  }

  redo(): void {
    this.store.redo();
  }

  deleteSelection(): boolean {
    return this.apply(E.deleteSelectedRegion) != null;
  }

  canDelete(): boolean {
    const p = this.project;
    if (!p) return false;
    const sel = this.selection;
    return (
      sel.introSelected ||
      sel.curtainSelected ||
      sel.depthFocusId != null ||
      sel.zoomId != null ||
      sel.blurId != null ||
      sel.voiceOverId != null ||
      sel.highlightId != null ||
      sel.speedId != null ||
      sel.tiltId != null ||
      E.canDeleteClip(p, sel.clipId)
    );
  }

  // ── Selection (the canvas callbacks' select* bodies) ───────────────────

  selectEffect(zoomId: string | null, tiltId: string | null): void {
    const sel = assignAll({ ...this.selection, introSelected: false, curtainSelected: false }, ["zoom", zoomId], ["tilt", tiltId]);
    this.store.select(sel);
  }

  selectFocus(id: string | null, isHighlight: boolean): void {
    const p = this.project;
    let sel: Selection = { ...this.selection, introSelected: false, curtainSelected: false };
    if (id && p) {
      if (isHighlight) sel = assignAll(sel, ["highlight", id], ["blur", null], ["depthFocus", null]);
      else if (p.focusRegions.some((r) => r.id === id)) sel = assignAll(sel, ["depthFocus", id], ["blur", null], ["highlight", null], ["cameraLayout", null]);
      else if (p.cameraLayoutRegions.some((r) => r.id === id)) sel = assignAll(sel, ["cameraLayout", id], ["blur", null], ["highlight", null], ["depthFocus", null]);
      else sel = assignAll(sel, ["blur", id], ["highlight", null], ["depthFocus", null], ["cameraLayout", null]);
    } else {
      sel = assignAll(sel, ["blur", null], ["highlight", null], ["depthFocus", null], ["cameraLayout", null]);
    }
    this.store.select(sel);
  }

  /** selectAnnotation — seek-if-not-visible (the playhead jumps into the span). */
  selectAnnotation(id: string | null): void {
    const p = this.project;
    this.store.select(assign({ ...this.selection, introSelected: false, curtainSelected: false }, "annotation", id));
    if (!id || !p) return;
    const a = p.annotations.find((x) => x.id === id);
    const current = this.store.playheadSource();
    if (a && (current < a.startTime || current > a.endTime)) {
      this.pause();
      this.seekToSource(Math.min(a.startTime + 0.05, a.endTime));
    }
  }

  selectClip(id: string | null): void {
    this.store.select(assign(this.selection, "clip", id));
  }

  selectVoiceOver(id: string | null): void {
    this.store.select(assign(this.selection, "voiceOver", id));
  }

  openIntro(): void {
    this.store.select({ ...assignAll(this.selection, ["zoom", null], ["tilt", null]), curtainSelected: false, introSelected: true }, "effects");
  }

  openCurtain(): void {
    this.store.select({ ...assignAll(this.selection, ["zoom", null], ["tilt", null]), introSelected: false, curtainSelected: true }, "effects");
  }

  setInspectorTab(tab: InspectorTabId): void {
    this.store.setInspectorTab(tab);
  }

  // ── Toolbar picks (showZoomMenu / showFocusMenu / showAnnotationMenu) ──

  async effectsPick(pick: EffectsPick): Promise<void> {
    switch (pick) {
      case "motion":
        await this.hooks.stillMotion?.();
        return;
      case "autoZoom":
        await this.hooks.autoZoom?.();
        return;
      case "zoomIn":
        this.apply(E.addZoomRegion());
        return;
      case "showcase":
        this.apply(E.addShowcaseBlock);
        return;
      case "scaleDown":
        this.apply(E.addScaleDownBlock);
        return;
      case "tilt":
        this.apply(E.addTiltRegion());
        return;
      case "slide":
        this.apply(E.enableIntroSlide);
        return;
      case "curtain":
        this.apply(E.enableCurtainUnveil);
        return;
      case "cameraFull":
        this.apply(E.addCameraLayoutRegion("cameraOnly"));
        return;
      case "cameraSideBySide":
        this.apply(E.addCameraLayoutRegion("sideBySide"));
        return;
      case "cameraHide":
        this.apply(E.addCameraLayoutRegion("screenOnly"));
        return;
    }
  }

  focusPick(pick: FocusPick): void {
    switch (pick) {
      case "blur":
        if (this.hooks.armBlurDraw) this.hooks.armBlurDraw("Blur");
        else this.apply(E.addBlurRegion());
        return;
      case "pixelate":
        // The Mac's fallback (no preview to arm) adds a plain blur.
        if (this.hooks.armBlurDraw) this.hooks.armBlurDraw("Pixelate");
        else this.apply(E.addBlurRegion());
        return;
      case "highlight":
        this.apply(E.addHighlightRegion());
        return;
      case "depthFocus":
        this.apply(E.addDepthFocusRegion());
        return;
    }
  }

  annotationPick(pick: AnnotationPick): void {
    this.addAnnotation(pick);
  }

  // ── Shell callbacks ────────────────────────────────────────────────────

  shellCallbacks(): EditorShellCallbacks {
    return {
      onShowProjects: () => this.hooks.showProjects?.(),
      onExport: () => this.hooks.exportVideo?.(),
      onShare: () => this.hooks.share?.(),
      onSyncRetry: () => this.store.retrySave(),
      onRename: (name) => this.store.updateProject({ name }, "Rename"),
      onAspectChange: (id) => this.store.updateSettings({ aspectRatio: id as never }, "Aspect Ratio"),
      onStillTreatmentChange: (t) => this.store.updateProject({ stillTreatment: t }, "Treatment"),
      onGoToStart: () => this.goToStart(),
      onTogglePlay: () => this.togglePlay(),
      onGoToEnd: () => this.goToEnd(),
      onUndo: () => this.undo(),
      onRedo: () => this.redo(),
      onDelete: () => void this.deleteSelection(),
      onEffectsPick: (pick) => void this.effectsPick(pick),
      onFocusPick: (pick) => this.focusPick(pick),
      onToggleSlice: () => this.store.setSliceArmed(!this.store.getState().sliceArmed),
      onSplitAtPlayhead: () => void this.apply(E.splitAtPlayhead),
      onAnnotationPick: (pick) => this.annotationPick(pick),
      onToggleVoiceOver: () => this.hooks.toggleVoiceOver?.(),
      onStep: (delta) => this.step(delta),
      onDuplicate: () => void this.apply(E.duplicateSelectedRegion),
      onEscape: () => {
        const next = escapeSelection(this.selection);
        if (next) this.store.select(next);
      },
      onInspectorTabChange: (tab) => this.setInspectorTab(tab),
    };
  }

  // ── Timeline intents (TimelineCanvasCallbacks + video/voice rows) ──────

  timelineIntents(): TimelineIntents {
    return {
      scrub: (t) => {
        this.playhead.set(t);
        void this.client?.seek(t);
      },
      seek: (t) => this.seek(t),
      select: (target, lane) => this.selectTarget(target, lane),
      commitTimes: (target, start, end) => this.commitTimes(target, start, end),
      openChip: (chip) => (chip === "intro" ? this.openIntro() : this.openCurtain()),
      moveChip: (chip, start) => void this.apply(chip === "intro" ? E.moveIntro(start) : E.moveCurtain(start), `chip-move:${chip}`),
      resizeChip: (chip, end) => void this.apply(chip === "intro" ? E.resizeIntro(end) : E.resizeCurtain(end), `chip-resize:${chip}`),
      trimVideo: (edge, t) => {
        const v = this.videoRegion();
        if (!v) return;
        if (edge === "start") this.apply(E.commitWholeDrag("resizeLeft", t - v.start, t, v.end));
        else this.apply(E.commitWholeDrag("resizeRight", t - v.end, v.start, t));
      },
      videoCommitWhole: (mode, delta, start, end) => void this.apply(E.commitWholeDrag(mode, delta, start, end)),
      videoCommitClipMove: (clipId, resolved) => {
        const ref = this.clipRef(clipId);
        if (ref) this.apply(E.commitClipMove(ref, resolved));
      },
      videoCommitClipEdge: (clipId, side, resolved) => {
        const ref = this.clipRef(clipId);
        if (ref) this.apply(E.commitClipEdge(ref, side, resolved));
      },
      voiceCommit: (clipId, value: VoiceOverClip) => void this.apply(E.commitVoiceClip(clipId, value)),
      sliceAt: (t) => void this.apply(E.sliceAt(t)),
      action: (a) => this.timelineAction(a),
    };
  }

  private videoRegion(): { start: number; end: number } | null {
    const p = this.project;
    if (!p) return null;
    const map = E.fullTimeMap(p);
    return { start: map.outputTime(effectiveTrimStart(p)), end: map.outputTime(effectiveTrimEnd(p)) };
  }

  private clipRef(clipId: string): E.VideoClipRef | null {
    const p = this.project;
    if (!p) return null;
    const map = E.fullTimeMap(p);
    const c = effectiveVideoClipSegments(p).find((x) => x.id === clipId);
    if (!c) return null;
    return { id: c.id, sourceStart: c.startTime, sourceEnd: c.endTime, outputStart: map.outputTime(c.startTime), outputEnd: map.outputTime(c.endTime) };
  }

  selectTarget(target: TimelineTarget | null, lane?: LaneId): void {
    if (!target) {
      switch (lane) {
        case "effects":
          return this.selectEffect(null, null);
        case "focus":
          return this.selectFocus(null, false);
        case "annotate":
          return this.selectAnnotation(null);
        case "video":
          return this.selectClip(null);
        case "voice":
          return this.selectVoiceOver(null);
        default:
          return;
      }
    }
    switch (target.lane) {
      case "effects":
        return this.selectEffect(target.zoomId ?? null, target.tiltId ?? null);
      case "focus":
        return this.selectFocus(target.id, target.isHighlight);
      case "annotate":
        return this.selectAnnotation(target.id);
      case "video":
        return this.selectClip(target.clipId);
      case "voice":
        return this.selectVoiceOver(target.clipId);
      case "intro":
        return this.openIntro();
      case "curtain":
        return this.openCurtain();
    }
  }

  commitTimes(target: TimelineTarget, start: number, end: number): void {
    switch (target.lane) {
      case "effects":
        this.apply(E.commitEffectBlockTimes(target.zoomId, target.tiltId, start, end));
        return;
      case "focus":
        this.apply(E.commitFocusTimes(target.id, target.isHighlight, start, end));
        return;
      case "annotate":
        this.apply(E.commitAnnotationTimes(target.id, start, end));
        return;
      case "voice": {
        const p = this.project;
        const stored = p?.voiceOverClips.find((c) => c.id === target.clipId);
        if (!p || !stored) return;
        // Generic-block fallback: keep the head trim, move/resize in OUTPUT time.
        this.apply(E.commitVoiceClip(target.clipId, { ...stored, startTime: start, duration: Math.max(0.01, end - start) }));
        return;
      }
      case "video": {
        const ref = this.clipRef(target.clipId);
        if (ref) this.apply(E.commitClipMove(ref, start));
        return;
      }
      default:
        return;
    }
  }

  timelineAction(a: TimelineAction): void {
    switch (a.type) {
      case "addZoomAt":
        this.apply(E.addZoomRegion(this.sourceAt(a.time)));
        return;
      case "addTiltAt":
        this.apply(E.addTiltRegion(this.sourceAt(a.time)));
        return;
      case "addHighlightAt":
        this.apply(E.addHighlightRegion(this.sourceAt(a.time)));
        return;
      case "addBlurAt":
        this.apply(E.addBlurRegion(this.sourceAt(a.time)));
        return;
      case "addAnnotationAt":
        this.addAnnotation(a.annotation, this.sourceAt(a.time));
        return;
      case "setZoomLevel":
        this.apply(E.setZoomLevel(a.zoomId, a.level));
        return;
      case "addTiltToBlock":
        this.apply(E.addTiltToBlock(a.zoomId));
        return;
      case "addZoomToBlock":
        this.apply(E.addZoomToBlock(a.tiltId));
        return;
      case "removeZoom":
        this.apply(E.deleteZoomRegion(a.zoomId));
        return;
      case "removeTilt":
        this.apply(E.deleteTiltRegion(a.tiltId));
        return;
      case "delete":
        this.deleteTarget(a.target);
        return;
      case "setSpeed":
        this.apply(E.addSpeedRegion(a.sourceStart, a.sourceEnd, a.speed));
        return;
      case "changeSpeed":
        this.apply(E.changeSpeedRegion(a.regionId, a.speed));
        return;
      case "removeSpeed":
        this.apply(E.deleteSpeedRegion(a.regionId));
        return;
      case "removeSplit":
        this.apply(E.removeSplit(a.outputTime));
        return;
      case "toggleMute":
        this.apply(E.toggleMute);
        return;
    }
  }

  deleteTarget(target: TimelineTarget): void {
    switch (target.lane) {
      case "effects":
        this.apply(E.deleteEffectBlock(target.zoomId, target.tiltId));
        return;
      case "focus":
        this.apply(E.deleteFocusItem(target.id, target.isHighlight));
        return;
      case "annotate":
        this.apply(E.deleteAnnotation(target.id));
        return;
      case "voice":
        this.apply(E.deleteVoiceOverClip(target.clipId));
        return;
      case "video":
        this.apply(E.deleteVideoClip(target.clipId));
        return;
      case "intro":
        // deleteIntro: select the chip, then the shared delete path.
        this.store.select({ ...this.selection, introSelected: true });
        this.apply(E.deleteSelectedRegion);
        return;
      case "curtain":
        this.store.select({ ...this.selection, curtainSelected: true });
        this.apply(E.deleteSelectedRegion);
        return;
    }
  }
}
