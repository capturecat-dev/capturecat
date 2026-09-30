/**
 * Editor selection — the Mac's `EditorShellSelection` plus the
 * TimelineViewController-local ids (camera layout, voice-over, speed, clip),
 * with `applySelectionExclusivity` ported rule-for-rule:
 *
 *   ONE selected object at a time — except zoom/tilt, which never clear each
 *   other (a linked EFFECTS block selects both halves), and blur/voice-over,
 *   which keep `speed`. Annotations are fully exclusive both ways.
 *
 * Selecting a highlight / depth focus / blur / tilt / zoom opens the Effects
 * inspector tab; an annotation opens Annotate (EditorShellViewController's
 * selection observation).
 */
import type { InspectorTabId } from "../ui/shell/types";

export interface Selection {
  zoomId: string | null;
  tiltId: string | null;
  highlightId: string | null;
  depthFocusId: string | null;
  blurId: string | null;
  annotationId: string | null;
  cameraLayoutId: string | null;
  voiceOverId: string | null;
  speedId: string | null;
  clipId: string | null;
  introSelected: boolean;
  curtainSelected: boolean;
}

export const EMPTY_SELECTION: Selection = Object.freeze({
  zoomId: null,
  tiltId: null,
  highlightId: null,
  depthFocusId: null,
  blurId: null,
  annotationId: null,
  cameraLayoutId: null,
  voiceOverId: null,
  speedId: null,
  clipId: null,
  introSelected: false,
  curtainSelected: false,
}) as Selection;

type Lane = "zoom" | "tilt" | "blur" | "voiceOver" | "highlight" | "depthFocus" | "cameraLayout" | "speed" | "clip" | "annotation";

const FIELD: Record<Lane, keyof Selection> = {
  zoom: "zoomId",
  tilt: "tiltId",
  blur: "blurId",
  voiceOver: "voiceOverId",
  highlight: "highlightId",
  depthFocus: "depthFocusId",
  cameraLayout: "cameraLayoutId",
  speed: "speedId",
  clip: "clipId",
  annotation: "annotationId",
};

/** Which fields `applySelectionExclusivity(lane, non-nil)` clears. */
const CLEARS: Record<Lane, Lane[]> = {
  zoom: ["annotation", "highlight", "blur", "voiceOver", "speed", "clip", "depthFocus", "cameraLayout"],
  tilt: ["annotation", "highlight", "blur", "voiceOver", "speed", "clip", "depthFocus", "cameraLayout"],
  blur: ["annotation", "zoom", "tilt", "highlight", "depthFocus", "cameraLayout", "voiceOver", "clip"],
  voiceOver: ["annotation", "zoom", "tilt", "highlight", "blur", "clip", "depthFocus", "cameraLayout"],
  highlight: ["annotation", "zoom", "tilt", "depthFocus", "cameraLayout", "blur", "voiceOver", "speed", "clip"],
  depthFocus: ["annotation", "zoom", "tilt", "highlight", "cameraLayout", "blur", "voiceOver", "speed", "clip"],
  cameraLayout: ["annotation", "zoom", "tilt", "highlight", "depthFocus", "blur", "voiceOver", "speed", "clip"],
  speed: ["annotation", "zoom", "tilt", "highlight", "blur", "voiceOver", "clip", "depthFocus", "cameraLayout"],
  clip: ["annotation", "zoom", "tilt", "highlight", "blur", "voiceOver", "speed", "depthFocus", "cameraLayout"],
  annotation: ["zoom", "tilt", "highlight", "blur", "voiceOver", "speed", "clip", "depthFocus", "cameraLayout"],
};

/**
 * Assign one selection field the way the Mac's property setters do: write it,
 * then (non-nil only) run the exclusivity pass. Returns a new Selection.
 */
export function assign(sel: Selection, lane: Lane, id: string | null): Selection {
  const next: Selection = { ...sel, [FIELD[lane]]: id };
  if (id == null) return next;
  for (const other of CLEARS[lane]) (next as unknown as Record<string, unknown>)[FIELD[other]] = null;
  return next;
}

/** Sequential assignments (the Mac sets several fields in a row). */
export function assignAll(sel: Selection, ...steps: Array<[Lane, string | null]>): Selection {
  let s = sel;
  for (const [lane, id] of steps) s = assign(s, lane, id);
  return s;
}

/**
 * The inspector tab the Mac switches to when a selection field BECOMES
 * non-nil (EditorShellViewController selectionObservation), or null.
 */
export function inspectorTabForChange(prev: Selection, next: Selection): InspectorTabId | null {
  let tab: InspectorTabId | null = null;
  const became = (k: keyof Selection) => next[k] != null && next[k] !== prev[k];
  // Observation order: highlight, depthFocus, blur, tilt, zoom, annotation — last write wins.
  if (became("highlightId")) tab = "effects";
  if (became("depthFocusId")) tab = "effects";
  if (became("blurId")) tab = "effects";
  if (became("tiltId")) tab = "effects";
  if (became("zoomId")) tab = "effects";
  if (became("annotationId")) tab = "annotations";
  return tab;
}

/** Anything the trash button / Delete key can act on (`hasDeletableSelection`),
 *  given whether the selected clip may be lifted (`canDeleteSelectedClip`). */
export function hasDeletableSelection(sel: Selection, canDeleteSelectedClip: boolean): boolean {
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
    canDeleteSelectedClip
  );
}

/** Drop ids that no longer exist in the project (after undo/redo/external edits). */
export function pruneSelection(
  sel: Selection,
  exists: { zoom(id: string): boolean; tilt(id: string): boolean; highlight(id: string): boolean; depthFocus(id: string): boolean; blur(id: string): boolean; annotation(id: string): boolean; cameraLayout(id: string): boolean; voiceOver(id: string): boolean; speed(id: string): boolean; clip(id: string): boolean; intro: boolean; curtain: boolean },
): Selection {
  const next: Selection = { ...sel };
  let changed = false;
  const check = (field: keyof Selection, ok: (id: string) => boolean) => {
    const id = next[field];
    if (typeof id === "string" && !ok(id)) {
      (next as unknown as Record<string, unknown>)[field] = null;
      changed = true;
    }
  };
  check("zoomId", exists.zoom);
  check("tiltId", exists.tilt);
  check("highlightId", exists.highlight);
  check("depthFocusId", exists.depthFocus);
  check("blurId", exists.blur);
  check("annotationId", exists.annotation);
  check("cameraLayoutId", exists.cameraLayout);
  check("voiceOverId", exists.voiceOver);
  check("speedId", exists.speed);
  check("clipId", exists.clip);
  if (next.introSelected && !exists.intro) {
    next.introSelected = false;
    changed = true;
  }
  if (next.curtainSelected && !exists.curtain) {
    next.curtainSelected = false;
    changed = true;
  }
  return changed ? next : sel;
}
