/**
 * The contextual annotation pill's pure halves — placement
 * (EditorShellViewController.repositionAnnotationPill) and writes
 * (TimelineViewController.applyToolbar* / toggleToolbarBackground).
 * The React view is AnnotationPill.tsx.
 */
import type { Annotation, AnnotationType, CodableColor, Project, SubtitleWeight } from "../../core/model";
import type { Pt } from "./stageMapping";

export interface PillRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** Gap between the annotation and the pill, and the card-edge margin. */
export const PILL_GAP = 10;
export const PILL_MARGIN = 8;

/**
 * iOS-edit-menu placement, in the stage card's top-down coordinates: the
 * pill floats `PILL_GAP` above the annotation when that leaves ≥ 8pt of
 * headroom, else just below it (its bottom never past card − 8); its centre
 * is clamped 8pt inside the card. Returns the pill's top-left.
 */
export function annotationPillOrigin(annotation: PillRect, pill: { width: number; height: number }, card: { width: number; height: number }): Pt {
  const top = annotation.y;
  const bottom = annotation.y + annotation.height;
  const bottomEdge = top - PILL_GAP - pill.height >= PILL_MARGIN ? top - PILL_GAP : Math.min(card.height - PILL_MARGIN, bottom + PILL_GAP + pill.height);
  const half = pill.width / 2;
  const cx = Math.min(Math.max(annotation.x + annotation.width / 2, half + PILL_MARGIN), Math.max(half + PILL_MARGIN, card.width - half - PILL_MARGIN));
  return { x: cx - half, y: bottomEdge - pill.height };
}

/** The pill's per-type control row (AnnotationToolbarPill.rebuildControls). */
export type PillControl = "font" | "weight" | "divider" | "backgroundToggle" | "backgroundColor" | "color" | "size";

export function pillControls(type: AnnotationType): PillControl[] {
  switch (type) {
    case "text":
    case "callout":
      return ["font", "weight", "divider", "backgroundToggle", "backgroundColor", "divider", "color"];
    case "rectangle":
    case "ellipse":
      return ["size", "color", "divider", "backgroundToggle", "backgroundColor"];
    case "arrow":
    case "drawing":
    case "tap":
      return ["size", "color"];
  }
}

/** Size slider: ripple size for taps (20…140), border / line width otherwise (1…14). */
export function pillSizeSlider(a: Pick<Annotation, "type" | "fontSize" | "lineWidth">): { value: number; min: number; max: number; tip: string } {
  return a.type === "tap"
    ? { value: a.fontSize, min: 20, max: 140, tip: "Ripple size" }
    : { value: a.lineWidth, min: 1, max: 14, tip: "Line width" };
}

/** A pill write — mutates the selected annotation in a draft (no-op when it is gone). */
export type PillEdit = (a: Annotation) => void;

export const PillEdits = {
  color: (c: CodableColor): PillEdit => (a) => {
    a.color = c;
  },
  font: (name: string | undefined): PillEdit => (a) => {
    // FontCatalog.storedName: nil (omitted) for System.
    if (name === undefined) delete a.fontName;
    else a.fontName = name;
  },
  weight: (w: SubtitleWeight): PillEdit => (a) => {
    a.fontWeight = w;
  },
  toggleBackground: (): PillEdit => (a) => {
    a.showBackground = !a.showBackground;
  },
  /** Picking a background colour IS turning the background on. */
  backgroundColor: (c: CodableColor): PillEdit => (a) => {
    a.backgroundColor = c;
    a.showBackground = true;
  },
  size: (value: number): PillEdit => (a) => {
    if (a.type === "tap") a.fontSize = value;
    else a.lineWidth = value;
  },
};

/** Applies `edit` to annotation `id` in a project draft. */
export function applyPillEdit(draft: Project, id: string, edit: PillEdit): void {
  const a = draft.annotations.find((x) => x.id === id);
  if (a) edit(a);
}
