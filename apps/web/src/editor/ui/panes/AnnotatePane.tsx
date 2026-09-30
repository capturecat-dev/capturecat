/**
 * The Annotate tab, 1:1 with AnnotationSettingsPaneAppKit — a flat 24pt
 * stack (no section boxes): the empty-state explainer, or the selected
 * annotation's type header + Delete, then Text / Tap / Style / Effects /
 * Strokes / Timing groups separated by hairline dividers, each row shown per
 * annotation type exactly like the Mac.
 */
import { useEffect, useRef, useState, type InputHTMLAttributes } from "react";

import type { Annotation, AnnotationType } from "../../core/model";
import { AnnotationEffect, SubtitleWeight, enumValues } from "../../core/model/enums";
import { formatFixed } from "../../core/math/swift";
import { Chips, ColorSwatch, Divider, InspectorButton, InspectorField, PillSlider, Row, SFIcon, Toggle, ToggleRow } from "../kit";
import { RowStack } from "./layout";
import { Cap, MenuRow, pctRounded, toCodable, toRGBA } from "./shared";
import { FONT_MENU, fontMenuIndex, fontStoredName } from "./SubtitlesPane";
import { selectedRegions, type PaneProps } from "./types";

const WEIGHTS = enumValues(SubtitleWeight);
const EFFECTS = enumValues(AnnotationEffect);

const NAMES: Record<AnnotationType, string> = {
  text: "Text",
  arrow: "Arrow",
  callout: "Callout",
  drawing: "Drawing",
  rectangle: "Rectangle",
  ellipse: "Ellipse",
  tap: "Tap Indicator",
};
const ICONS: Record<AnnotationType, string> = {
  text: "textformat",
  arrow: "arrow.up.right",
  callout: "bubble.left",
  drawing: "scribble",
  rectangle: "rectangle",
  ellipse: "circle",
  tap: "hand.tap",
};

/** A field that commits on end-editing (blur / Return), like the Mac's
 *  controlTextDidEndEditing; model changes flow in while it isn't focused. */
function CommitField({
  value,
  onCommitValue,
  ...rest
}: Omit<InputHTMLAttributes<HTMLInputElement>, "value" | "onChange"> & { value: string; onCommitValue: (v: string) => void; width?: number }) {
  const [draft, setDraft] = useState(value);
  const focused = useRef(false);
  useEffect(() => {
    if (!focused.current) setDraft(value);
  }, [value]);
  return (
    <InspectorField
      {...rest}
      value={draft}
      onFocus={() => {
        focused.current = true;
      }}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => {
        focused.current = false;
        onCommitValue(draft);
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter") (e.target as HTMLInputElement).blur();
      }}
    />
  );
}

export function AnnotatePane({ selection, project, onRegionChange, onCommit, actions }: PaneProps) {
  const { annotation: a } = selectedRegions(selection, project);
  const commit = () => onCommit?.();
  const mutate = (patch: Partial<Annotation>) => {
    if (!a) return;
    onRegionChange?.("annotation", a.id, patch);
  };
  const mutateCommit = (patch: Partial<Annotation>) => {
    mutate(patch);
    commit();
  };

  if (!a) {
    return (
      <div className="cc-flatstack">
        <div className="cc-pane-header" style={{ minHeight: 0 }}>
          Annotate
        </div>
        <Cap>
          Add a text label, arrow, shape, or tap indicator from the toolbar — it lands on the ANNOTATE lane at the playhead. Select one (on the preview or the timeline) to edit its properties here. Double-click a text label on the preview to edit it in place.
        </Cap>
      </div>
    );
  }

  const type = a.type;
  const isText = type === "text" || type === "callout";
  const isTap = type === "tap";
  const isShape = type === "rectangle" || type === "ellipse";
  const hasFill = isText || isShape;
  const hasBorder = type === "arrow" || type === "drawing" || isShape;
  const isDrawing = type === "drawing";
  const strokes = a.drawingStrokes.length;
  const duration = project?.duration ?? a.endTime;

  return (
    <div className="cc-annotate">
      <RowStack
        gap={24}
        rows={[
          {
            key: "header",
            node: (
              <div className="cc-pane-header">
                <span className="cc-pane-header__icon">
                  <SFIcon name={ICONS[type]} size={13} weight="semibold" />
                </span>
                <span>{NAMES[type]}</span>
                <span className="cc-spacer" />
                <InspectorButton destructive onClick={() => actions?.onAction?.({ type: "delete", target: { lane: "annotate", id: a.id } })}>
                  Delete
                </InspectorButton>
              </div>
            ),
          },
          { key: "d1", node: <Divider /> },
          { key: "textCap", show: isText, node: <div className="cc-fieldcap">Text</div> },
          {
            key: "text",
            show: isText,
            node: <CommitField key={a.id} placeholder="Label" value={a.text} onCommitValue={(v) => v !== a.text && mutateCommit({ text: v })} />,
          },
          { key: "textTip", show: isText, node: <Cap>Tip: double-click the label on the preview to edit it in place.</Cap> },
          {
            key: "size",
            show: isText,
            node: <PillSlider title="Size" value={a.fontSize} min={10} max={72} step={1} onChange={(v) => mutate({ fontSize: v })} onCommit={commit} />,
          },
          {
            key: "font",
            show: isText,
            node: <MenuRow label="Font" options={FONT_MENU} selectedIndex={fontMenuIndex(a.fontName)} onSelect={(i) => mutateCommit({ fontName: fontStoredName(i) })} />,
          },
          {
            key: "weight",
            show: isText,
            node: <Chips items={WEIGHTS} selectedIndex={Math.max(0, WEIGHTS.indexOf(a.fontWeight))} onSelect={(i) => mutateCommit({ fontWeight: WEIGHTS[i] })} ariaLabel="Weight" />,
          },
          { key: "upper", show: isText, node: <ToggleRow label="Uppercase" checked={a.uppercase} onChange={(v) => mutateCommit({ uppercase: v })} /> },
          { key: "tapCap", show: isTap, node: <div className="cc-fieldcap">Tap Ripple</div> },
          {
            key: "tapSize",
            show: isTap,
            node: <PillSlider title="Size" value={a.fontSize} min={20} max={120} step={5} onChange={(v) => mutate({ fontSize: v })} onCommit={commit} />,
          },
          { key: "tapTip", show: isTap, node: <Cap>Drag the ripple on the preview over the tapped spot. It pulses for the block's whole duration.</Cap> },
          { key: "d2", node: <Divider /> },
          { key: "styleCap", node: <div className="cc-fieldcap">Style</div> },
          {
            key: "color",
            node: (
              <Row label="Color">
                <ColorSwatch color={toRGBA(a.color)} onChange={(c) => mutate({ color: toCodable(c, a.color) })} ariaLabel="Colour" />
              </Row>
            ),
          },
          {
            key: "fill",
            show: hasFill,
            node: (
              <Row label={isShape ? "Fill" : "Background"}>
                <span className="cc-pane-pair" style={{ gap: 10 }}>
                  {a.showBackground && (
                    <ColorSwatch color={toRGBA(a.backgroundColor)} onChange={(c) => mutate({ backgroundColor: toCodable(c, a.backgroundColor) })} ariaLabel="Fill colour" />
                  )}
                  <Toggle size="sm" checked={a.showBackground} onChange={(v) => mutateCommit({ showBackground: v })} ariaLabel={isShape ? "Fill" : "Background"} />
                </span>
              </Row>
            ),
          },
          {
            key: "corners",
            show: isText || type === "rectangle",
            node: <PillSlider title="Corners" value={a.cornerRadius} min={0} max={24} step={1} onChange={(v) => mutate({ cornerRadius: v })} onCommit={commit} />,
          },
          {
            key: "border",
            show: hasBorder,
            node: (
              <PillSlider
                title="Border"
                value={a.lineWidth}
                min={isDrawing ? 1 : 0}
                max={isDrawing ? 30 : 12}
                step={0.5}
                onChange={(v) => mutate({ lineWidth: v })}
                onCommit={commit}
              />
            ),
          },
          { key: "d3", node: <Divider /> },
          { key: "effectsCap", node: <div className="cc-fieldcap">Effects</div> },
          {
            key: "opacity",
            node: <PillSlider title="Opacity" value={a.opacity} min={0.2} max={1} step={0.05} format={pctRounded} onChange={(v) => mutate({ opacity: v })} onCommit={commit} />,
          },
          {
            key: "blackout",
            node: (
              <PillSlider
                title="Blackout"
                value={a.backdropOpacity}
                min={0}
                max={0.9}
                step={0.05}
                format={(v) => (v < 0.026 ? "Off" : pctRounded(v))}
                onChange={(v) => mutate({ backdropOpacity: v < 0.026 ? 0 : v })}
                onCommit={commit}
              />
            ),
          },
          {
            key: "buildIn",
            node: <MenuRow label="Build In" options={EFFECTS} selectedIndex={EFFECTS.indexOf(a.enterEffect)} onSelect={(i) => mutateCommit({ enterEffect: EFFECTS[i] })} />,
          },
          {
            key: "buildOut",
            node: <MenuRow label="Build Out" options={EFFECTS} selectedIndex={EFFECTS.indexOf(a.exitEffect)} onSelect={(i) => mutateCommit({ exitEffect: EFFECTS[i] })} />,
          },
          { key: "shadow", show: !isTap, node: <ToggleRow label="Shadow" checked={a.showShadow} onChange={(v) => mutateCommit({ showShadow: v })} /> },
          { key: "strokesCap", show: isDrawing, node: <div className="cc-fieldcap">Strokes</div> },
          {
            key: "strokes",
            show: isDrawing,
            node: (
              <div className="cc-pane-hstack">
                <span className="cc-annotate__strokes">
                  {strokes} stroke{strokes === 1 ? "" : "s"}
                </span>
                <span className="cc-spacer" />
                {strokes > 0 && <InspectorButton onClick={() => mutateCommit({ drawingStrokes: a.drawingStrokes.slice(0, -1) })}>Undo Last</InspectorButton>}
                {strokes > 0 && (
                  <InspectorButton destructive onClick={() => mutateCommit({ drawingStrokes: [] })}>
                    Clear
                  </InspectorButton>
                )}
              </div>
            ),
          },
          { key: "drawTip", show: isDrawing, node: <Cap>Draw directly on the preview canvas.</Cap> },
          { key: "d4", node: <Divider /> },
          { key: "timingCap", node: <div className="cc-fieldcap">Timing</div> },
          {
            key: "timing",
            node: (
              <div className="cc-pane-hstack cc-annotate__timing">
                <label className="cc-annotate__labeled">
                  <span className="cc-fieldcap cc-fieldcap--sm">Start</span>
                  <CommitField
                    key={`s-${a.id}`}
                    width={56}
                    placeholder="0.00"
                    value={formatFixed(a.startTime, 2)}
                    onCommitValue={(v) => {
                      const n = Number.parseFloat(v);
                      if (Number.isFinite(n)) mutateCommit({ startTime: Math.max(0, n) });
                    }}
                  />
                </label>
                <label className="cc-annotate__labeled">
                  <span className="cc-fieldcap cc-fieldcap--sm">End</span>
                  <CommitField
                    key={`e-${a.id}`}
                    width={56}
                    placeholder="0.00"
                    value={formatFixed(a.endTime, 2)}
                    onCommitValue={(v) => {
                      const n = Number.parseFloat(v);
                      if (Number.isFinite(n)) mutateCommit({ endTime: Math.max(a.startTime + 0.5, n) });
                    }}
                  />
                </label>
                <span className="cc-spacer" />
                <InspectorButton
                  onClick={() => {
                    const t = actions?.playheadTime?.() ?? 0;
                    mutateCommit({ startTime: Math.max(0, t), endTime: Math.min(duration, t + 3) });
                  }}
                >
                  At Playhead
                </InspectorButton>
              </div>
            ),
          },
          { key: "timingTip", node: <Cap>Drag the block's edges on the ANNOTATE lane to retime it.</Cap> },
        ]}
      />
    </div>
  );
}
