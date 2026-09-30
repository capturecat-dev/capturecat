/**
 * When a selection re-shows a collapsed inspector — the Mac's
 * `selection.showInspector = true` sites:
 *
 *   EditorShellViewController.selectionObservation — a highlight / depth
 *     focus / blur / tilt / zoom / annotation id that CHANGES to non-nil
 *     (also switches the tab: `inspectorTabForChange`);
 *   TimelineViewController enableIntroSlide / enableCurtainUnveil /
 *     openIntro / openCurtain — the intro or curtain chip gets selected.
 */
import { inspectorTabForChange, type Selection } from "./selection";

export function revealsInspector(prev: Selection, next: Selection): boolean {
  if (inspectorTabForChange(prev, next) != null) return true;
  if (next.introSelected && !prev.introSelected) return true;
  if (next.curtainSelected && !prev.curtainSelected) return true;
  return false;
}
