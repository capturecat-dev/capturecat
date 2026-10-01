/**
 * The stage's edit-gesture surface — the web twin of
 * Views/Editor/PreviewCompositor/PreviewInteractionView.swift (+ the
 * SelectionChromeKit / AnnotationRenderer.Chrome / focal-reticle chrome the
 * compositor draws for it).
 *
 * CONTRACT (EditorPage mounts it):
 *   mountStageInteraction(host, viewport, deps) → StageInteraction
 * `host` is the letterboxed output-canvas element the engine renders into
 * (position: relative); this layer adds ONE overlay <canvas> on top (chrome
 * + pointer handling) and, while a label is being edited, the in-place
 * editor's two elements. Frame geometry comes from `deps.client.onFrame`
 * (engine FrameInfo: the card → canvas camera homography + card rects of the
 * frame just presented), so hit-testing and chrome follow the SAME camera as
 * the pixels. Writes go through the store (one undo step per gesture) /
 * controller only.
 *
 * One pointer state machine, ported mode for mode from the Mac's DragMode:
 * blurDraw (armed marquee), zoomFocal (on-canvas focal target), draw
 * (freehand pen on the selected drawing), annotation (body move),
 * annotationHandle (arrow endpoint / shape corner), regionMove,
 * regionResize, regionSlider (the value pill), blockOffset (card drag
 * inside a zoom block), placement (card drag) and overlay — the Mac's
 * `.camera` / `.subtitle` / `.watermark` drags, hit-tested against the rects
 * the engine reports it DREW (FrameInfo.hits, engine/stageHits.ts) with the
 * fraction math + magnetism in ./overlayDrag.ts.
 */
import type { BlurStyle, Project, Rect } from "../../core/model";
import { highlightCornerRadiusFor, highlightRegionRectInViewSpace, focusRegionRectInViewSpace } from "../../core/math/regionGeometry";
import { clampCardOffset } from "../../core/math/zoomFocalMath";
import * as Placement from "../../core/math/placementMath";
import type { EngineClient } from "../../engine/client";
import { IDENTITY, invert, type Mat3 } from "../../engine/mat3";
import type { FrameInfo } from "../../engine/protocol";
import type { EditorController } from "../../state/controller";
import { assignAll } from "../../state/selection";
import type { EditorStore } from "../../state/store";
import type { StageViewport } from "../shell/types";
import { annotationCssFont, annotationLabelRect, measureLine } from "./annotationLabel";
import { drawAnnotationChrome, drawFocalReticle, drawMarquee, drawRegionChrome, readChromeTheme, type ChromeFrame } from "./stageChrome";
import {
  CARD_DRAG_THRESHOLD,
  adjustRegionRect,
  annotationHandleHit,
  annotationHitRect,
  appendStrokePoint,
  blurDrawRect,
  focalHit,
  handleDragPatch,
  insetRect,
  isActiveAt,
  movedAnnotation,
  normalizedVideoPoint,
  rectContains,
  regionHit,
  sliderFraction,
  sliderValue,
  videoPoint,
  type AnnotationHandleHit,
  type HitGeometry,
  type RegionHit,
} from "./stageGeometry";
import { boundsOf, canvasFromClient, canvasToCard, cardToCanvas, localScale, projectRect, type Pt } from "./stageMapping";
import {
  OVERLAY_LABEL,
  applySettingsPatch,
  overlayDragFraction,
  overlayDragPatch,
  overlayHitTest,
  overlayInitialFraction,
  overlayReleasePatch,
  type OverlayKind,
} from "./overlayDrag";

export interface StageInteractionDeps {
  store: EditorStore;
  controller: EditorController;
  client: EngineClient;
}

export interface StageInteraction {
  /** Arm one drag-to-draw pass (PreviewInteractionView.armBlurDraw). */
  armBlurDraw(style: BlurStyle): void;
  cancelBlurDraw(): void;
  /** Open the in-place label editor on a text/callout annotation. */
  beginInlineEdit(annotationId: string): void;
  /** The host was resized / re-zoomed. */
  resize(viewport: StageViewport): void;
  dispose(): void;
  /**
   * `selectedAnnotationViewRect()` — the selected annotation's hit rect
   * through the camera, host-relative CSS px (for a contextual annotation
   * toolbar). Null when nothing is selected.
   */
  selectedAnnotationViewRect(): Rect | null;
  /** True while a canvas drag is mutating geometry (the Mac hides the
   * contextual toolbar meanwhile — `isDraggingOnCanvas`). */
  readonly isDraggingOnCanvas: boolean;
  /** The host element the engine canvas + this layer live in. */
  readonly host: HTMLElement;
  readonly isDisposed: boolean;
  /**
   * Fires whenever the chrome re-lays out (a presented frame, a store /
   * playhead / transport change, a resize) or a drag starts / ends — what the
   * contextual annotation pill re-positions on (ESVC.repositionAnnotationPill).
   */
  subscribe(listener: () => void): () => void;
}

/** Stage interactions mounted/unmounted — lets the pill (re)bind to the live surface. */
const stageMountListeners = new Set<() => void>();
export function onStageInteractionMount(listener: () => void): () => void {
  stageMountListeners.add(listener);
  return () => stageMountListeners.delete(listener);
}
function announceStageMount(): void {
  // After the caller stored the instance (EditorPage assigns stageRef on return).
  queueMicrotask(() => {
    for (const l of [...stageMountListeners]) l();
  });
}

export function mountStageInteraction(host: HTMLElement, viewport: StageViewport, deps: StageInteractionDeps): StageInteraction {
  return new StageInteractionSurface(host, viewport, deps);
}

// ── Modes ──────────────────────────────────────────────────────────────────

type RegionKind = "blur" | "highlight" | "focus";
interface RegionRef {
  kind: RegionKind;
  id: string;
}

type DragMode =
  | { kind: "idle" }
  | { kind: "blurDraw"; style: BlurStyle }
  | { kind: "zoomFocal"; id: string }
  | { kind: "draw"; id: string }
  | { kind: "annotation"; id: string; initial: Pt; initialEnd: Pt }
  | { kind: "annotationHandle"; id: string; handle: AnnotationHandleHit }
  | { kind: "regionMove"; ref: RegionRef; initial: Rect }
  | { kind: "regionResize"; ref: RegionRef; initial: Rect; edges: { left: boolean; right: boolean; top: boolean; bottom: boolean } }
  | { kind: "regionSlider"; ref: RegionRef; track: { minX: number; width: number } }
  | { kind: "placement"; moved: boolean; grab: Pt }
  | { kind: "blockOffset"; id: string; initial: Pt; moved: boolean }
  /** `.camera` / `.watermark` / `.subtitle`: `initial` = the fraction at mousedown. */
  | { kind: "overlay"; overlay: OverlayKind; initial: Pt };

type SelectionStep = Parameters<typeof assignAll>[1];

const REGION_LABEL: Record<RegionKind, string> = { blur: "Edit Blur", highlight: "Edit Highlight", focus: "Edit Depth Focus" };
const REGION_ARRAY = { blur: "blurRegions", highlight: "highlightRegions", focus: "focusRegions" } as const;
const REGION_ICONS: Record<RegionKind, { leading: string; trailing: string }> = {
  blur: { leading: "eye", trailing: "eye.slash.fill" },
  focus: { leading: "circle.dashed", trailing: "camera.aperture" },
  highlight: { leading: "circle.lefthalf.filled", trailing: "circle.fill" },
};

/** Double-click window (NSEvent.doubleClickInterval default) and slop. */
const DOUBLE_CLICK_MS = 500;
const DOUBLE_CLICK_SLOP_PX = 5;

interface InlineEditor {
  id: string;
  input: HTMLInputElement;
  backing: HTMLDivElement;
  /** Until the user types, the box is the renderer's own label rect. */
  typed: boolean;
  closed: boolean;
}

class StageInteractionSurface implements StageInteraction {
  private readonly overlay: HTMLCanvasElement;
  private readonly ctx: CanvasRenderingContext2D | null;
  private frame: FrameInfo | null = null;
  private inverse: Mat3 = IDENTITY;
  private mode: DragMode = { kind: "idle" };
  private downCanvas: Pt = { x: 0, y: 0 };
  private currentCanvas: Pt = { x: 0, y: 0 };
  private armedStyle: BlurStyle | null = null;
  private gestureKey: string | null = null;
  private gestureSeq = 0;
  private gestureWrote = false;
  private lastDown = { t: -Infinity, x: 0, y: 0, count: 0 };
  private editor: InlineEditor | null = null;
  private raf = 0;
  private drewChrome = false;
  private disposed = false;
  private readonly cleanups: Array<() => void> = [];
  private readonly listeners = new Set<() => void>();
  /** The pointer is over a draggable overlay while idle (hover cursor). */
  private hoverOverlay = false;

  constructor(
    readonly host: HTMLElement,
    private viewport: StageViewport,
    private readonly deps: StageInteractionDeps,
  ) {
    const overlay = document.createElement("canvas");
    overlay.dataset.stageInteraction = "";
    overlay.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;touch-action:none;z-index:1;";
    host.appendChild(overlay);
    this.overlay = overlay;
    this.ctx = overlay.getContext("2d");

    const on = <K extends keyof HTMLElementEventMap>(el: HTMLElement, type: K, fn: (e: HTMLElementEventMap[K]) => void) => {
      el.addEventListener(type, fn as EventListener);
      this.cleanups.push(() => el.removeEventListener(type, fn as EventListener));
    };
    on(overlay, "pointerdown", this.onPointerDown);
    on(overlay, "pointermove", this.onPointerMove);
    on(overlay, "pointerup", this.onPointerUp);
    on(overlay, "pointercancel", this.onPointerCancel);
    on(overlay, "pointerleave", () => this.setHover(false));
    // Capture lost without a pointerup (window blur, OS gesture): end the drag.
    on(overlay, "lostpointercapture", (e) => {
      if (this.mode.kind !== "idle") this.finish(e, true);
    });
    const onKey = (e: KeyboardEvent) => this.onKeyDown(e);
    window.addEventListener("keydown", onKey, true);
    this.cleanups.push(() => window.removeEventListener("keydown", onKey, true));

    const { client, store, controller } = deps;
    this.cleanups.push(client.onFrame((f) => this.setFrame(f)));
    this.cleanups.push(client.onTransport(() => this.schedule()));
    this.cleanups.push(store.subscribe(() => this.schedule()));
    this.cleanups.push(controller.playhead.subscribe(() => this.schedule()));
    if (client.lastFrame) this.setFrame(client.lastFrame);
    announceStageMount();
  }

  // ── Public contract ──────────────────────────────────────────────────────

  armBlurDraw(style: BlurStyle): void {
    this.armedStyle = style;
    this.updateCursor();
  }

  cancelBlurDraw(): void {
    if (this.armedStyle == null) return;
    this.armedStyle = null;
    if (this.mode.kind === "blurDraw") this.mode = { kind: "idle" };
    this.updateCursor();
    this.schedule();
  }

  beginInlineEdit(annotationId: string): void {
    const a = this.project()?.annotations.find((x) => x.id === annotationId);
    if (!a || !(a.type === "text" || a.type === "callout")) return;
    this.openEditor(annotationId);
  }

  resize(viewport: StageViewport): void {
    this.viewport = viewport;
    this.schedule();
  }

  get isDraggingOnCanvas(): boolean {
    return this.mode.kind !== "idle";
  }

  selectedAnnotationViewRect(): Rect | null {
    const g = this.geometry();
    const f = this.frame;
    const id = this.deps.store.getState().selection.annotationId;
    const a = id ? this.project()?.annotations.find((x) => x.id === id) : undefined;
    if (!g || !f || !a) return null;
    const r = annotationHitRect(a, g, this.labelRectFn(g));
    const host = this.overlay.getBoundingClientRect();
    const k = host.width > 0 ? f.target.width / host.width : 1;
    const b = boundsOf(projectRect(r, g.camera));
    return { x: b.x / k, y: b.y / k, width: b.width / k, height: b.height / k };
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private notify(): void {
    for (const l of [...this.listeners]) l();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.endInlineEdit(true);
    cancelAnimationFrame(this.raf);
    for (const c of this.cleanups.splice(0)) c();
    this.overlay.remove();
    this.notify();
    this.listeners.clear();
    announceStageMount();
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  // ── Frame / state ────────────────────────────────────────────────────────

  private setFrame(f: FrameInfo): void {
    this.frame = f;
    this.inverse = invert(f.camera as Mat3);
    this.schedule();
  }

  private project(): Project | null {
    return this.deps.store.getState().project;
  }

  private isPlaying(): boolean {
    return this.deps.client.transport?.playing ?? this.frame?.playing ?? false;
  }

  /** The Mac's `currentTime` (SOURCE s): the playhead while parked, the
   * presented frame's time while playing. */
  private time(): number {
    if (this.isPlaying() && this.frame) return this.frame.sourceTime;
    return this.deps.store.playheadSource();
  }

  private geometry(): (HitGeometry & { camera: Mat3 }) | null {
    const f = this.frame;
    if (!f) return null;
    return { videoRect: f.videoRect, u: f.canvasScale > 0 ? f.canvasScale : 1, camera: f.camera as Mat3 };
  }

  private canvasPoint(e: { clientX: number; clientY: number }): Pt {
    const f = this.frame!;
    return canvasFromClient(e.clientX, e.clientY, this.overlay.getBoundingClientRect(), f.target);
  }

  /** `contentPoint(_:_:)` — through the CURRENT frame's inverse camera. */
  private cardPoint(p: Pt): Pt {
    return canvasToCard(this.inverse, p);
  }

  private labelRectFn(g: HitGeometry) {
    return (a: Parameters<typeof annotationLabelRect>[0]) => annotationLabelRect(a, g.videoRect, g.u);
  }

  // ── Writes ───────────────────────────────────────────────────────────────

  private beginGesture(): void {
    this.gestureKey = `stage-gesture:${++this.gestureSeq}`;
    this.gestureWrote = false;
  }

  /** One undo step per gesture: every write of the drag shares a coalesce key. */
  private write(label: string, recipe: (draft: Project) => void): void {
    // An old version on screen (History preview) is read-only.
    if (!this.project() || this.deps.store.getState().preview) return;
    this.gestureWrote = true;
    this.deps.store.transact(label, recipe, { coalesceKey: this.gestureKey ?? undefined });
  }

  private endGesture(): void {
    if (this.gestureKey && this.gestureWrote) this.deps.store.endCoalescing();
    this.gestureKey = null;
    this.gestureWrote = false;
  }

  private select(...steps: SelectionStep[]): void {
    const store = this.deps.store;
    const current = store.getState().selection;
    const next = assignAll(current, ...steps);
    const changed = (Object.keys(next) as Array<keyof typeof next>).some((k) => next[k] !== current[k]);
    if (changed) store.select(next);
  }

  private regionItem(draft: Project, ref: RegionRef) {
    return (draft[REGION_ARRAY[ref.kind]] as Array<{ id: string; rect: Rect }>).find((r) => r.id === ref.id);
  }

  // ── Pointer ──────────────────────────────────────────────────────────────

  private clickCount(e: PointerEvent): number {
    const last = this.lastDown;
    const near = Math.hypot(e.clientX - last.x, e.clientY - last.y) <= DOUBLE_CLICK_SLOP_PX;
    const count = e.timeStamp - last.t <= DOUBLE_CLICK_MS && near ? last.count + 1 : 1;
    this.lastDown = { t: e.timeStamp, x: e.clientX, y: e.clientY, count };
    return count;
  }

  private onPointerDown = (e: PointerEvent): void => {
    // One gesture at a time (a second finger / button never restarts a drag).
    if (e.button !== 0 || this.mode.kind !== "idle") return;
    const project = this.project();
    const g = this.geometry();
    if (!project || !g) return;
    e.preventDefault();
    const clicks = this.clickCount(e);

    // Click-away COMMITS the in-place edit; the click is consumed.
    if (this.editor) {
      this.endInlineEdit(true);
      return;
    }

    const p = this.canvasPoint(e);
    this.downCanvas = p;
    this.currentCanvas = p;
    try {
      this.overlay.setPointerCapture(e.pointerId);
    } catch {
      /* synthetic events have no active pointer */
    }
    this.beginGesture();

    // Armed blur draw wins over everything.
    if (this.armedStyle != null) {
      this.mode = { kind: "blurDraw", style: this.armedStyle };
      this.schedule();
      return;
    }

    const playing = this.isPlaying();
    const time = this.time();
    const sel = this.deps.store.getState().selection;
    const cp = this.cardPoint(p);
    const labelRect = this.labelRectFn(g);
    const annotations = project.annotations;
    // Drags begin here; the pill hides for their duration (isDraggingOnCanvas).
    queueMicrotask(() => this.notify());

    // Double-click a text/callout → edit the label in place.
    if (clicks === 2 && !playing) {
      for (let i = annotations.length - 1; i >= 0; i--) {
        const a = annotations[i];
        if (!isActiveAt(a, time) || !(a.type === "text" || a.type === "callout")) continue;
        if (rectContains(annotationHitRect(a, g, labelRect), cp)) {
          this.select(["annotation", a.id], ["blur", null], ["highlight", null], ["depthFocus", null]);
          this.mode = { kind: "idle" };
          this.openEditor(a.id);
          return;
        }
      }
    }

    // 0 — the focal target of the selected zoom block (topmost chrome).
    if (sel.zoomId) {
      const z = project.zoomRegions.find((r) => r.id === sel.zoomId);
      if (z) {
        const zoom = localScale(g.camera, videoPoint(z.focalPoint.x, z.focalPoint.y, g.videoRect));
        if (focalHit(cp, z.focalPoint, g, zoom)) {
          this.mode = { kind: "zoomFocal", id: z.id };
          return;
        }
      }
    }

    // 1 — canvas-level chrome, topmost first (watermark > camera > subtitle),
    // against the rects the engine drew this frame.
    const overlay = overlayHitTest(this.frame?.hits, p, cp, g.u);
    if (overlay) {
      this.mode = { kind: "overlay", overlay: overlay.kind, initial: overlayInitialFraction(overlay.kind, project.settings) };
      this.updateCursor();
      return;
    }

    // 2-pre — pen-down on the SELECTED drawing annotation starts a stroke.
    if (!playing && sel.annotationId) {
      const a = annotations.find((x) => x.id === sel.annotationId);
      if (a && a.type === "drawing" && rectContains(insetRect(g.videoRect, -20 * g.u, -20 * g.u), cp) && isActiveAt(a, time)) {
        const n = normalizedVideoPoint(cp, g);
        const id = a.id;
        this.write("Draw", (d) => {
          const t = d.annotations.find((x) => x.id === id);
          if (t) t.drawingStrokes = [...t.drawingStrokes, [{ x: n.x, y: n.y }]];
        });
        this.mode = { kind: "draw", id };
        return;
      }
    }

    // 2 — annotations (paused editing): handles first, then bodies.
    if (!playing) {
      for (let i = annotations.length - 1; i >= 0; i--) {
        const a = annotations[i];
        if (!isActiveAt(a, time)) continue;
        const handle = annotationHandleHit(a, cp, g);
        if (handle) {
          this.select(["annotation", a.id], ["blur", null], ["highlight", null], ["depthFocus", null]);
          this.mode = { kind: "annotationHandle", id: a.id, handle };
          return;
        }
      }
      for (let i = annotations.length - 1; i >= 0; i--) {
        const a = annotations[i];
        if (!isActiveAt(a, time)) continue;
        if (rectContains(annotationHitRect(a, g, labelRect), cp)) {
          this.select(["annotation", a.id], ["blur", null], ["highlight", null], ["depthFocus", null]);
          this.mode = { kind: "annotation", id: a.id, initial: { x: a.x, y: a.y }, initialEnd: { x: a.arrowEndX, y: a.arrowEndY } };
          return;
        }
      }
    }

    // Clicking anything that is NOT an annotation deselects the current one.
    if (!playing && sel.annotationId != null) this.select(["annotation", null]);

    // 3 — highlight above depth focus above blur (compositor z-order).
    const hit = this.hitRegion(cp, g, time);
    if (hit) {
      this.mode = hit;
      return;
    }

    // Not region chrome → every region type deselects.
    const after = this.deps.store.getState().selection;
    const clear: SelectionStep[] = [];
    if (after.blurId != null) clear.push(["blur", null]);
    if (after.highlightId != null) clear.push(["highlight", null]);
    if (after.depthFocusId != null) clear.push(["depthFocus", null]);
    if (clear.length) this.select(...clear);

    // 4 — card body: a zoom block's excursion, else the base placement.
    if (rectContains(g.videoRect, cp)) {
      const zoom = project.zoomRegions.find((r) => isActiveAt(r, time));
      if (zoom) {
        this.mode = { kind: "blockOffset", id: zoom.id, initial: { x: zoom.cardOffsetX ?? 0, y: zoom.cardOffsetY ?? 0 }, moved: false };
        return;
      }
      const vr = g.videoRect;
      const centre = { x: vr.x + vr.width / 2, y: vr.y + vr.height / 2 };
      this.mode = { kind: "placement", moved: false, grab: { x: cp.x - centre.x, y: cp.y - centre.y } };
      return;
    }
    this.mode = { kind: "idle" };
  };

  /** `hitRegion(_:_:)` — selects on hit (the Mac's select closures). */
  private hitRegion(cp: Pt, g: HitGeometry, time: number): DragMode | null {
    const project = this.project()!;
    const sel = this.deps.store.getState().selection;
    const toMode = (ref: RegionRef, rect: Rect, h: RegionHit): DragMode => {
      switch (h.kind) {
        case "slider":
          return { kind: "regionSlider", ref, track: h.track };
        case "resize":
          return { kind: "regionResize", ref, initial: { ...rect }, edges: { left: h.left, right: h.right, top: h.top, bottom: h.bottom } };
        default:
          return { kind: "regionMove", ref, initial: { ...rect } };
      }
    };
    for (let i = project.highlightRegions.length - 1; i >= 0; i--) {
      const r = project.highlightRegions[i];
      if (!isActiveAt(r, time)) continue;
      const h = regionHit(cp, r.rect, sel.highlightId === r.id, g, REGION_ICONS.highlight);
      if (h) {
        this.select(["highlight", r.id], ["blur", null]);
        return toMode({ kind: "highlight", id: r.id }, r.rect, h);
      }
    }
    for (let i = project.focusRegions.length - 1; i >= 0; i--) {
      const r = project.focusRegions[i];
      if (!isActiveAt(r, time)) continue;
      const h = regionHit(cp, r.rect, sel.depthFocusId === r.id, g, REGION_ICONS.focus);
      if (h) {
        this.select(["depthFocus", r.id], ["highlight", null], ["blur", null]);
        return toMode({ kind: "focus", id: r.id }, r.rect, h);
      }
    }
    for (let i = project.blurRegions.length - 1; i >= 0; i--) {
      const r = project.blurRegions[i];
      if (!isActiveAt(r, time)) continue;
      const h = regionHit(cp, r.rect, sel.blurId === r.id, g, REGION_ICONS.blur);
      if (h) {
        this.select(["blur", r.id], ["highlight", null], ["depthFocus", null]);
        return toMode({ kind: "blur", id: r.id }, r.rect, h);
      }
    }
    return null;
  }

  private onPointerMove = (e: PointerEvent): void => {
    if (!this.frame) return;
    if (this.mode.kind === "idle") {
      this.updateHover(e);
      return;
    }
    const g = this.geometry();
    if (!g) return;
    const p = this.canvasPoint(e);
    this.currentCanvas = p;
    const vr = g.videoRect;
    const mode = this.mode;
    switch (mode.kind) {
      case "blurDraw":
        this.schedule();
        return;
      case "overlay": {
        // The live rect (the Mac reads ctx.<x>Rect per drag event; none → no write).
        const hit = this.frame.hits?.[mode.overlay];
        if (!hit) return;
        // Delta in the space the overlay is drawn in: canvas px for the bubble
        // and watermark, card px (through the camera) for subtitles / the tile.
        const a = hit.space === "canvas" ? this.downCanvas : this.cardPoint(this.downCanvas);
        const b = hit.space === "canvas" ? p : this.cardPoint(p);
        const f = overlayDragFraction(mode.overlay, mode.initial, { x: b.x - a.x, y: b.y - a.y }, hit.usable);
        if (!f) return;
        const patch = overlayDragPatch(mode.overlay, f);
        this.write(OVERLAY_LABEL[mode.overlay], (d) => applySettingsPatch(d.settings, patch));
        return;
      }
      case "zoomFocal": {
        const n = normalizedVideoPoint(this.cardPoint(p), g);
        this.write("Edit Zoom", (d) => {
          const z = d.zoomRegions.find((r) => r.id === mode.id);
          if (!z) return;
          z.focalPoint = { x: Math.max(0, Math.min(1, n.x)), y: Math.max(0, Math.min(1, n.y)) };
          // Aiming the shot by hand means the aim must hold: fixed focus.
          z.followsCursor = false;
        });
        return;
      }
      case "draw": {
        const n = normalizedVideoPoint(this.cardPoint(p), g);
        this.write("Draw", (d) => {
          const a = d.annotations.find((x) => x.id === mode.id);
          if (!a || a.drawingStrokes.length === 0) return;
          a.drawingStrokes = appendStrokePoint(a.drawingStrokes, n);
        });
        return;
      }
      case "annotation": {
        const cp = this.cardPoint(p);
        const cpDown = this.cardPoint(this.downCanvas);
        const dx = (cp.x - cpDown.x) / Math.max(1, vr.width);
        const dy = (cp.y - cpDown.y) / Math.max(1, vr.height);
        this.write("Edit Annotation", (d) => {
          const a = d.annotations.find((x) => x.id === mode.id);
          if (a) Object.assign(a, movedAnnotation(a.type, mode.initial, mode.initialEnd, dx, dy));
        });
        return;
      }
      case "annotationHandle": {
        const patch = handleDragPatch(this.cardPoint(p), g, mode.handle);
        this.write("Edit Annotation", (d) => {
          const a = d.annotations.find((x) => x.id === mode.id);
          if (a) Object.assign(a, patch);
        });
        return;
      }
      case "regionMove":
      case "regionResize": {
        const cp = this.cardPoint(p);
        const cpDown = this.cardPoint(this.downCanvas);
        const dx = (cp.x - cpDown.x) / Math.max(1, vr.width);
        const dy = (cp.y - cpDown.y) / Math.max(1, vr.height);
        const rect =
          mode.kind === "regionMove"
            ? adjustRegionRect(mode.initial, dx, dy, { left: false, right: false, top: false, bottom: false }, true)
            : adjustRegionRect(mode.initial, dx, dy, mode.edges, false);
        this.write(REGION_LABEL[mode.ref.kind], (d) => {
          const r = this.regionItem(d, mode.ref);
          if (r) r.rect = rect;
        });
        return;
      }
      case "regionSlider": {
        // Card-space X (the pill is drawn in card space; the Mac mixes view
        // X with the content-space pill here, off by the padding under zoom).
        const f = sliderFraction(this.cardPoint(p).x, mode.track);
        const value = sliderValue(mode.ref.kind, f);
        this.write(REGION_LABEL[mode.ref.kind], (d) => {
          const r = this.regionItem(d, mode.ref) as unknown as Record<string, number> | undefined;
          if (!r) return;
          if (mode.ref.kind === "highlight") r.opacity = value;
          else r.intensity = value;
        });
        return;
      }
      case "blockOffset": {
        const t = this.frame.target;
        const distance = Math.hypot(p.x - this.downCanvas.x, p.y - this.downCanvas.y);
        if (!(mode.moved || distance >= CARD_DRAG_THRESHOLD * g.u)) return;
        mode.moved = true;
        this.updateCursor();
        if (!(t.width > 0 && t.height > 0)) return;
        // Applied OUTSIDE the zoom scale — raw canvas deltas track 1:1.
        const ox = clampCardOffset(mode.initial.x + (p.x - this.downCanvas.x) / t.width);
        const oy = clampCardOffset(mode.initial.y + (p.y - this.downCanvas.y) / t.height);
        this.write("Edit Zoom", (d) => {
          const z = d.zoomRegions.find((r) => r.id === mode.id);
          if (!z) return;
          z.cardOffsetX = ox;
          z.cardOffsetY = oy;
        });
        return;
      }
      case "placement": {
        const t = this.frame.target;
        const distance = Math.hypot(p.x - this.downCanvas.x, p.y - this.downCanvas.y);
        if (!(mode.moved || distance >= CARD_DRAG_THRESHOLD * g.u)) return;
        mode.moved = true;
        this.updateCursor();
        if (!(t.width > 0 && t.height > 0)) return;
        // The card CENTRE tracks (pointer − grab offset) 1:1, past the edges;
        // magnetism happens once, on release.
        const cp = this.cardPoint(p);
        const range = Placement.customFractionRange;
        const fx = Math.min(range.upperBound, Math.max(range.lowerBound, (cp.x - mode.grab.x) / t.width));
        const fy = Math.min(range.upperBound, Math.max(range.lowerBound, (cp.y - mode.grab.y) / t.height));
        this.write("Move Video", (d) => {
          d.settings.videoCustomX = fx;
          d.settings.videoCustomY = fy;
        });
        return;
      }
    }
  };

  private onPointerUp = (e: PointerEvent): void => {
    this.finish(e, false);
  };

  private onPointerCancel = (e: PointerEvent): void => {
    this.finish(e, true);
  };

  private finish(e: PointerEvent, cancelled: boolean): void {
    const mode = this.mode;
    if (mode.kind === "idle") {
      this.endGesture();
      return;
    }
    const g = this.geometry();
    // Idle BEFORE releasing capture: the release fires lostpointercapture.
    this.mode = { kind: "idle" };
    try {
      if (this.overlay.hasPointerCapture(e.pointerId)) this.overlay.releasePointerCapture(e.pointerId);
    } catch {
      /* ignore */
    }
    switch (mode.kind) {
      case "blurDraw": {
        const style = mode.style;
        let rect: Rect | null = null;
        if (g && !cancelled) {
          const a = normalizedVideoPoint(this.cardPoint(this.downCanvas), g);
          const b = normalizedVideoPoint(this.cardPoint(this.canvasPoint(e)), g);
          rect = blurDrawRect(a, b);
        }
        this.mode = { kind: "idle" };
        this.cancelBlurDraw();
        if (rect) this.deps.controller.createBlurRegion(rect, style);
        break;
      }
      case "blockOffset":
        // Rest magnetism: a near-zero excursion collapses to nil.
        if (mode.moved) {
          this.write("Edit Zoom", (d) => {
            const z = d.zoomRegions.find((r) => r.id === mode.id);
            if (!z) return;
            if (z.cardOffsetX != null && Math.abs(z.cardOffsetX) < 0.005) delete z.cardOffsetX;
            if (z.cardOffsetY != null && Math.abs(z.cardOffsetY) < 0.005) delete z.cardOffsetY;
          });
        }
        break;
      case "overlay": {
        // mouseUp magnetism — camera corners, watermark edges, subtitle
        // anchors collapse back to the clean enum. Same gesture = same undo step.
        const s = this.project()?.settings;
        const patch = s ? overlayReleasePatch(mode.overlay, s) : null;
        if (patch) this.write(OVERLAY_LABEL[mode.overlay], (d) => applySettingsPatch(d.settings, patch));
        break;
      }
      case "placement": {
        // Only the CENTRE anchor magnetizes (a centred custom position and
        // the centre enum render identically, so the collapse is invisible).
        const s = this.project()?.settings;
        if (mode.moved && s && s.videoCustomX != null && s.videoCustomY != null && Math.abs(s.videoCustomX - 0.5) < Placement.magnetism && Math.abs(s.videoCustomY - 0.5) < Placement.magnetism) {
          this.write("Move Video", (d) => {
            d.settings.videoPlacement = "Center";
            delete d.settings.videoCustomX;
            delete d.settings.videoCustomY;
          });
        }
        break;
      }
      default:
        break;
    }
    this.mode = { kind: "idle" };
    this.endGesture();
    this.updateCursor();
    this.schedule();
    // The shell re-shows the contextual pill (the Mac's onDragEnded).
    this.notify();
  }

  private onKeyDown(e: KeyboardEvent): void {
    if (e.key !== "Escape" || this.editor) return;
    // Esc disarms an armed draw (and drops an in-flight marquee) without creating anything.
    if (this.armedStyle != null) {
      this.cancelBlurDraw();
      this.mode = { kind: "idle" };
      e.preventDefault();
      e.stopPropagation();
    }
  }

  private updateCursor(): void {
    const m = this.mode;
    const grabbing = ((m.kind === "placement" || m.kind === "blockOffset") && m.moved) || m.kind === "overlay";
    const grab = m.kind === "idle" && this.hoverOverlay;
    this.overlay.style.cursor = this.armedStyle != null ? "crosshair" : grabbing ? "grabbing" : grab ? "grab" : "";
  }

  /** Idle pointer over the camera bubble / subtitle / watermark → an open hand (they drag). */
  private updateHover(e: PointerEvent): void {
    const f = this.frame;
    const g = this.geometry();
    if (!f || !g || !f.hits) return this.setHover(false);
    const p = this.canvasPoint(e);
    this.setHover(overlayHitTest(f.hits, p, this.cardPoint(p), g.u) !== null);
  }

  private setHover(on: boolean): void {
    if (this.hoverOverlay === on) return;
    this.hoverOverlay = on;
    this.updateCursor();
  }

  // ── Chrome ───────────────────────────────────────────────────────────────

  private schedule(): void {
    if (this.disposed || this.raf) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = 0;
      this.draw();
      this.notify();
    });
  }

  private draw(): void {
    const ctx = this.ctx;
    const f = this.frame;
    const project = this.project();
    if (!ctx || !f) return;
    const t = f.target;
    if (this.overlay.width !== t.width || this.overlay.height !== t.height) {
      this.overlay.width = t.width;
      this.overlay.height = t.height;
      this.drewChrome = true;
    }
    if (this.editor) this.layoutEditor();
    if (this.drewChrome) {
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, this.overlay.width, this.overlay.height);
      this.drewChrome = false;
    }
    if (!project) return;

    const g = this.geometry()!;
    const cf: ChromeFrame = { camera: g.camera, videoRect: g.videoRect, u: g.u };
    const sel = this.deps.store.getState().selection;
    const time = this.time();
    const playing = this.isPlaying();
    let drew = false;

    // Region selection chrome — SELECTED + shown at the playhead only.
    const blur = sel.blurId ? project.blurRegions.find((r) => r.id === sel.blurId && isActiveAt(r, time)) : undefined;
    const focus = sel.depthFocusId ? project.focusRegions.find((r) => r.id === sel.depthFocusId && isActiveAt(r, time)) : undefined;
    const highlight = sel.highlightId ? project.highlightRegions.find((r) => r.id === sel.highlightId && isActiveAt(r, time)) : undefined;
    if (blur || focus || highlight) {
      const theme = readChromeTheme(this.host);
      if (blur) {
        drawRegionChrome(ctx, cf, theme, {
          rect: blur.rect,
          cornerRadius: 10 * g.u,
          sliderValue: blur.intensity,
          sliderRange: [0.1, 1],
          ...leadingTrailing("blur"),
        });
      }
      if (focus) {
        // SAME radius rule as FocusMath's SDF: the outline traces the blur boundary.
        const rendered = focusRegionRectInViewSpace(focus, g.videoRect);
        const corner = focus.style === "Area" ? Math.max(0, Math.min(1, focus.cornerRadius)) * Math.min(rendered.width, rendered.height) / 2 : 0;
        drawRegionChrome(ctx, cf, theme, {
          rect: focus.rect,
          cornerRadius: corner,
          sliderValue: focus.intensity,
          sliderRange: [0.1, 1],
          ...leadingTrailing("focus"),
        });
      }
      if (highlight) {
        // HighlightRegion.cornerRadius(for: rendered, in: videoRect) in POINTS.
        const vrPt = scaleRect(g.videoRect, 1 / g.u);
        const renderedPt = highlightRegionRectInViewSpace(highlight, vrPt);
        drawRegionChrome(ctx, cf, theme, {
          rect: highlight.rect,
          cornerRadius: highlightCornerRadiusFor(renderedPt, vrPt) * g.u,
          sliderValue: highlight.opacity,
          sliderRange: [0.1, 0.9],
          ...leadingTrailing("highlight"),
        });
      }
      drew = true;
    }

    // Zoom focal reticle (selected zoom block, regardless of the playhead).
    if (sel.zoomId) {
      const z = project.zoomRegions.find((r) => r.id === sel.zoomId);
      if (z) {
        drawFocalReticle(ctx, cf, z.focalPoint);
        drew = true;
      }
    }

    // Annotation handles / rings (paused editor only).
    if (!playing && project.annotations.length) {
      drawAnnotationChrome(ctx, cf, {
        annotations: project.annotations,
        time,
        selectedId: sel.annotationId,
        editingId: this.editor?.id ?? null,
        labelRect: this.labelRectFn(g),
      });
      drew = true;
    }

    if (this.mode.kind === "blurDraw") {
      drawMarquee(ctx, this.downCanvas, this.currentCanvas, g.u);
      drew = true;
    }
    this.drewChrome = drew;
  }

  // ── In-place label editor ────────────────────────────────────────────────

  private openEditor(id: string): void {
    this.endInlineEdit(true);
    const backing = document.createElement("div");
    backing.style.cssText = "position:absolute;box-sizing:border-box;pointer-events:none;z-index:2;border:1.5px solid rgb(0 122 255);";
    const input = document.createElement("input");
    input.type = "text";
    input.spellcheck = false;
    input.autocomplete = "off";
    input.style.cssText =
      "position:absolute;z-index:3;margin:0;padding:0;border:0;outline:none;background:transparent;text-align:center;box-sizing:border-box;white-space:pre;";
    const a = this.project()?.annotations.find((x) => x.id === id);
    input.value = a?.text ?? "";
    const editor: InlineEditor = { id, input, backing, typed: false, closed: false };
    input.addEventListener("input", () => {
      editor.typed = true;
      this.layoutEditor();
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        e.stopPropagation();
        this.endInlineEdit(true);
      } else if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        this.endInlineEdit(false);
      }
    });
    input.addEventListener("blur", () => {
      if (this.editor === editor) this.endInlineEdit(true);
    });
    input.addEventListener("pointerdown", (e) => e.stopPropagation());
    this.host.appendChild(backing);
    this.host.appendChild(input);
    this.editor = editor;
    // The engine omits this annotation from the preview raster NOW (Mac:
    // Chrome.editingID + requestRender) — the field replaces it, no twin.
    this.syncEditingAnnotation();
    this.layoutEditor();
    input.focus({ preventScroll: true });
    input.select();
    this.schedule();
  }

  /**
   * Geometry: the renderer's own labelRect through the camera (centre mapped
   * exactly, size by the camera's local zoom — the Mac also approximates the
   * tilt away here). Once the user types, the pill grows symmetrically about
   * its centre from the measured text, Keynote-style.
   */
  private layoutEditor(): void {
    const ed = this.editor;
    const f = this.frame;
    const g = this.geometry();
    if (!ed || !f || !g) return;
    const a = this.project()?.annotations.find((x) => x.id === ed.id);
    if (!a) {
      this.endInlineEdit(false);
      return;
    }
    const host = this.overlay.getBoundingClientRect();
    const pxPerCss = host.width > 0 ? f.target.width / host.width : 1;
    const label = annotationLabelRect(a, g.videoRect, g.u) ?? annotationHitRect(a, g, this.labelRectFn(g));
    const centerCard = { x: label.x + label.width / 2, y: label.y + label.height / 2 };
    const c = cardToCanvas(g.camera, centerCard);
    const center = { x: c.x / pxPerCss, y: c.y / pxPerCss };
    const z = (localScale(g.camera, centerCard) * g.u) / pxPerCss; // CSS px per Mac point on screen
    const pads = { w: (a.type === "text" ? 10 : 12) * z, h: (a.type === "text" ? 6 : 8) * z };
    const fontSize = Math.max(10, a.fontSize) * z;
    const font = annotationCssFont(a, fontSize);
    let fieldW: number;
    let fieldH: number;
    if (ed.typed) {
      const m = measureLine(ed.input.value || " ", font, fontSize);
      fieldW = Math.max(16, m.width) + 8;
      fieldH = Math.max(12, m.height) + 2;
    } else {
      const s = (localScale(g.camera, centerCard)) / pxPerCss;
      fieldW = label.width * s - 2 * pads.w + 8;
      fieldH = label.height * s - 2 * pads.h + 2;
    }
    const field = { x: center.x - fieldW / 2, y: center.y - fieldH / 2, width: fieldW, height: fieldH };
    const back = { x: field.x + 4 - pads.w, y: field.y + 1 - pads.h, width: fieldW - 8 + 2 * pads.w, height: fieldH - 2 + 2 * pads.h };

    const bg = a.backgroundColor;
    const showsBG = a.type === "callout" || a.showBackground;
    const bs = ed.backing.style;
    bs.left = `${back.x}px`;
    bs.top = `${back.y}px`;
    bs.width = `${back.width}px`;
    bs.height = `${back.height}px`;
    bs.background = showsBG ? `rgba(${bg.red * 255}, ${bg.green * 255}, ${bg.blue * 255}, ${bg.opacity})` : "transparent";
    bs.borderRadius = `${Math.max(0, a.cornerRadius) * z}px`;

    const is = ed.input.style;
    is.left = `${field.x}px`;
    is.top = `${field.y}px`;
    is.width = `${field.width}px`;
    is.height = `${field.height}px`;
    is.lineHeight = `${field.height}px`;
    is.font = font;
    const col = a.color;
    is.color = `rgb(${col.red * 255}, ${col.green * 255}, ${col.blue * 255})`;
  }

  /** Commit (or discard) and remove the field. Safe to call repeatedly. */
  private endInlineEdit(commit: boolean): void {
    const ed = this.editor;
    if (!ed || ed.closed) return;
    ed.closed = true;
    this.editor = null;
    const text = ed.input.value;
    ed.backing.remove();
    ed.input.remove();
    if (commit) {
      const a = this.project()?.annotations.find((x) => x.id === ed.id);
      if (a && a.text !== text) {
        this.deps.store.updateRegion("annotation", ed.id, { text });
        this.deps.store.endCoalescing();
      }
    }
    // Un-hide it in the raster only AFTER the committed text reaches the
    // engine: the controller pushes the project on the next animation frame,
    // and rAF callbacks (then worker messages) run in order — un-hiding now
    // would flash the OLD label for a frame.
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => this.syncEditingAnnotation());
    else this.syncEditingAnnotation();
    this.schedule();
  }

  /** Tells the engine which label the editor replaces (null: none). */
  private syncEditingAnnotation(): void {
    try {
      this.deps.client.setEditingAnnotation(this.disposed ? null : (this.editor?.id ?? null));
    } catch {
      /* the engine is gone (page teardown) */
    }
  }
}

function leadingTrailing(kind: RegionKind): { leadingIcon: string; trailingIcon: string } {
  return { leadingIcon: REGION_ICONS[kind].leading, trailingIcon: REGION_ICONS[kind].trailing };
}

function scaleRect(r: Rect, s: number): Rect {
  return { x: r.x * s, y: r.y * s, width: r.width * s, height: r.height * s };
}
