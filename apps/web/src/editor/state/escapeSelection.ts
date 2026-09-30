/**
 * Esc — the Mac's two Esc handlers folded into one (the web has one key
 * window, not a responder chain):
 *
 *   TimelineViewController.handleKeyDown(53): a selected VIDEO clip clears;
 *   PreviewInteractionView.cancelOperation → deselectAll: every canvas-
 *   selectable object clears — blur, highlight, depth focus, annotation
 *   ("total exclusivity", the same path as a click on empty canvas).
 *
 * (An armed blur-draw disarms first and consumes the key — StageInteraction.)
 * Returns the new selection, or null when there was nothing to clear.
 */
import type { Selection } from "./selection";

export function escapeSelection(sel: Selection): Selection | null {
  if (sel.clipId == null && sel.blurId == null && sel.highlightId == null && sel.depthFocusId == null && sel.annotationId == null) {
    return null;
  }
  return { ...sel, clipId: null, blurId: null, highlightId: null, depthFocusId: null, annotationId: null };
}
