/**
 * The contextual annotation toolbar — the web twin of
 * Views/Editor/AnnotationToolbarPill.swift, placed like
 * EditorShellViewController.repositionAnnotationPill:
 *
 *  • shown only while an annotation is SELECTED (contextual only — adding
 *    annotations lives in the timeline toolbar's picker);
 *  • hidden during playback and while a canvas drag is in flight (Keynote;
 *    also what keeps drags at frame rate — no per-move toolbar layout);
 *  • floats 10pt above the annotation's on-screen rect
 *    (StageInteraction.selectedAnnotationViewRect — the hit rect through the
 *    camera), below it when there is no headroom, clamped 8pt inside the
 *    stage card, as a sibling of the card so its corner mask never clips it.
 *
 * Controls per type (AnnotationToolbarPill.rebuildControls): text/callout
 * font ▾ · weight ▾ | background on/off + colour | colour; rect/ellipse
 * line width · colour | fill on/off + colour; arrow/drawing line width ·
 * colour; tap ripple size · colour. Built from the kit (Select, QuietButton,
 * ColorSwatch, RailSlider) in the elevated capsule the Mac draws
 * (panelElevated fill, hairline border).
 *
 * Position is written imperatively on each stage notification; React
 * re-renders only when the selected annotation changes.
 */
import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react";
import { createPortal } from "react-dom";

import type { Annotation } from "../../core/model";
import { SubtitleWeight, enumValues } from "../../core/model/enums";
import type { EditorController } from "../../state/controller";
import { useEditorStore, type EditorState, type EditorStore } from "../../state/store";
import { ColorSwatch, QuietButton, RailSlider, Select } from "../kit";
import { toCodable, toRGBA } from "../panes/shared";
import { FONT_MENU, fontMenuIndex, fontStoredName } from "../panes/SubtitlesPane";
import { annotationPillOrigin, applyPillEdit, PillEdits, pillControls, pillSizeSlider, type PillEdit } from "./annotationPillModel";
import { onStageInteractionMount, type StageInteraction } from "./StageInteraction";

const WEIGHTS = enumValues(SubtitleWeight);
const FONT_OPTIONS = FONT_MENU.map((title) => ({ title }));
const WEIGHT_OPTIONS = WEIGHTS.map((title) => ({ title }));

const selectedAnnotation = (s: EditorState): Annotation | null => {
  const id = s.selection.annotationId;
  return id ? (s.project?.annotations.find((a) => a.id === id) ?? null) : null;
};

export function AnnotationPill({
  store,
  controller,
  stageRef,
}: {
  store: EditorStore;
  controller: EditorController;
  stageRef: RefObject<StageInteraction | null>;
}) {
  const [stage, setStage] = useState<StageInteraction | null>(null);
  useEffect(() => {
    const pick = () => {
      const s = stageRef.current;
      setStage(s && !s.isDisposed ? s : null);
    };
    pick();
    return onStageInteractionMount(pick);
  }, [stageRef]);

  const annotation = useEditorStore(store, selectedAnnotation);
  const wrap = (stage?.host.closest(".cc-stagewrap") as HTMLElement | null) ?? null;
  const pillRef = useRef<HTMLDivElement>(null);

  // Placement: every stage notification (frame, selection, drag start/end,
  // playhead, transport), the stage scroller (zoomed preview) and resizes.
  useLayoutEffect(() => {
    const el = pillRef.current;
    if (!stage || !wrap || !el) return;
    const scroller = stage.host.closest(".cc-stagescroll");
    const place = () => {
      const playing = controller.client?.transport?.playing ?? false;
      const rect = playing || stage.isDraggingOnCanvas ? null : stage.selectedAnnotationViewRect();
      if (!rect) {
        el.dataset.visible = "false";
        return;
      }
      const host = stage.host.getBoundingClientRect();
      const card = wrap.getBoundingClientRect();
      const r = { x: rect.x + host.left - card.left, y: rect.y + host.top - card.top, width: rect.width, height: rect.height };
      const o = annotationPillOrigin(r, { width: el.offsetWidth, height: el.offsetHeight }, { width: card.width, height: card.height });
      el.style.transform = `translate(${Math.round(o.x)}px, ${Math.round(o.y)}px)`;
      el.dataset.visible = "true";
      // The anchor it was placed against (card px) — for the stage-interaction harness.
      el.dataset.anchor = `${r.x.toFixed(1)},${r.y.toFixed(1)},${r.width.toFixed(1)},${r.height.toFixed(1)}`;
    };
    place();
    const unsubscribe = stage.subscribe(place);
    const offTransport = controller.client?.onTransport(() => place());
    scroller?.addEventListener("scroll", place, { passive: true });
    window.addEventListener("resize", place);
    return () => {
      unsubscribe();
      offTransport?.();
      scroller?.removeEventListener("scroll", place);
      window.removeEventListener("resize", place);
    };
  }, [stage, wrap, controller, annotation]);

  if (!stage || !wrap || !annotation) return null;

  const id = annotation.id;
  const edit = (label: string, e: PillEdit, key: string) =>
    store.transact(label, (d) => applyPillEdit(d, id, e), { coalesceKey: `annotation-pill:${key}:${id}` });
  const commit = (label: string, e: PillEdit) => {
    store.transact(label, (d) => applyPillEdit(d, id, e));
    store.endCoalescing();
  };
  const size = pillSizeSlider(annotation);
  const isShape = annotation.type === "rectangle" || annotation.type === "ellipse";

  const controls = pillControls(annotation.type).map((c, i) => {
    switch (c) {
      case "font":
        return (
          <Select
            key="font"
            chrome="plain"
            size="sm"
            searchable
            ariaLabel="Font"
            options={FONT_OPTIONS}
            selectedIndex={fontMenuIndex(annotation.fontName)}
            onSelect={(idx) => commit("Edit Annotation", PillEdits.font(fontStoredName(idx)))}
          />
        );
      case "weight":
        return (
          <Select
            key="weight"
            chrome="plain"
            size="sm"
            ariaLabel="Weight"
            options={WEIGHT_OPTIONS}
            selectedIndex={Math.max(0, WEIGHTS.indexOf(annotation.fontWeight))}
            onSelect={(idx) => commit("Edit Annotation", PillEdits.weight(WEIGHTS[idx]))}
          />
        );
      case "divider":
        return <span key={`d${i}`} className="cc-annpill__divider" aria-hidden />;
      case "backgroundToggle":
        return (
          <QuietButton
            key="bg"
            symbol="square.fill.on.square"
            height={26}
            paddingX={4}
            selected={annotation.showBackground}
            title={isShape ? "Fill on/off" : "Background pill on/off"}
            aria-label={isShape ? "Fill on/off" : "Background pill on/off"}
            aria-pressed={annotation.showBackground}
            onClick={() => commit("Edit Annotation", PillEdits.toggleBackground())}
          />
        );
      case "backgroundColor":
        return (
          <span key="bgwell" className="cc-annpill__well" title="Background color">
            <ColorSwatch
              color={toRGBA(annotation.backgroundColor)}
              ariaLabel="Background color"
              onChange={(c) => edit("Edit Annotation", PillEdits.backgroundColor(toCodable(c, annotation.backgroundColor)), "bg")}
            />
          </span>
        );
      case "color":
        return (
          <span key="well" className="cc-annpill__well" title="Color">
            <ColorSwatch
              color={toRGBA(annotation.color)}
              ariaLabel="Color"
              onChange={(c) => {
                const codable = toCodable(c, annotation.color);
                // applyToolbarColor also makes it the next annotation's default.
                controller.toolbarAnnotationColor = { red: codable.red, green: codable.green, blue: codable.blue, opacity: codable.opacity };
                edit("Recolor Annotation", PillEdits.color(codable), "color");
              }}
            />
          </span>
        );
      case "size":
        return (
          <span key="size" title={size.tip}>
            <RailSlider
              width={72}
              min={size.min}
              max={size.max}
              value={size.value}
              ariaLabel={size.tip}
              onChange={(v) => edit("Edit Annotation", PillEdits.size(v), "size")}
            />
          </span>
        );
    }
  });

  return createPortal(
    <div ref={pillRef} className="cc-annpill" data-annotation-pill={annotation.type} role="toolbar" aria-label="Annotation">
      {controls}
    </div>,
    wrap,
  );
}
