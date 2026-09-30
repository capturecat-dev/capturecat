/**
 * The Effects tab, 1:1 with MotionSettingsPaneAppKit (which embeds
 * EffectsSettingsPaneAppKit): ONE flat list —
 *   Slide · Curtain Unveil · Parallax · Motion Blur   (project-wide switches)
 *   Zoom · Tilt                                       (the selected EFFECTS
 *                                                      block; the switches add
 *                                                      / remove a block)
 *   Highlight Mask · Depth Focus · Blur               (the selected FOCUS
 *                                                      region only)
 * Every range, step, unit, caption and conditional row follows the Mac pane.
 * A selected camera-layout block or intro/curtain chip has no section of its
 * own on the Mac (the chips open this tab; Slide / Curtain are always here).
 */
import { useEffect, useRef, useState } from "react";

import type { ProjectSettings } from "../../core/model";
import {
  BlurStyle,
  CurtainUnveilCorner,
  FocusRegionStyle,
  IntroSlideStyle,
  ZoomAnimationStyle,
  enumValues,
  zoomStyleDamping,
  zoomStyleOmegaMultiplier,
} from "../../core/model/enums";
import { coverColorTop } from "../../core/math/curtainUnveilMath";
import { cardOffsetLimit } from "../../core/math/zoomFocalMath";
import { Chips, ColorSwatch, InspectorButton, PillSlider, Row, ToggleRow } from "../kit";
import { Box, PaneStack } from "./layout";
import { EffectPreviewPad, PropertyPreviewPad, TiltPad, ZoomFocusPad } from "./livePads";
import { hasPickerStatus, PickerStatusLine } from "./pickerStatus";
import { Cap, MenuRow, RowButton, WHITE, degRounded, fixed, pctRounded, pctTrunc, sig2, toCodable, toRGBA } from "./shared";
import { selectedRegions, type PaneProps } from "./types";

const SLIDE_STYLES = enumValues(IntroSlideStyle).slice(1);
const CURTAIN_CORNERS = enumValues(CurtainUnveilCorner).slice(1);
const ZOOM_STYLES = enumValues(ZoomAnimationStyle);
const STYLE_MENU = ["Default", ...ZOOM_STYLES];
const FOCUS_STYLES = enumValues(FocusRegionStyle);
const BLUR_STYLES = enumValues(BlurStyle);
const TILT_PRESETS = ["Flat", "Showcase", "Lean L", "Lean R", "Top Down"];
/** (pitch, yaw, roll) — depth from PITCH, drama from yaw, life from a whisper of roll. */
const TILT_PRESET_VALUES: [number, number, number][] = [
  [0, 0, 0],
  [12, 0, -3],
  [8, -25, -2],
  [8, 25, 2],
  [28, 0, 0],
];

export function EffectsPane({ settings: s, onSettingsChange, onCommit, selection, project, onRegionChange, actions }: PaneProps) {
  const set = (patch: Partial<ProjectSettings>) => onSettingsChange(patch);
  const pick = (patch: Partial<ProjectSettings>) => {
    onSettingsChange(patch);
    onCommit?.();
  };
  const commit = () => onCommit?.();
  const { zoom, tilt, highlight, focus: depth, blur } = selectedRegions(selection, project);
  const act = actions?.onAction;
  const [presetIndex, setPresetIndex] = useState(0);

  // "Cinematic" adds the missing half of the block first; the new region
  // only exists once the store answers, so the preset lands on the next
  // render that carries both.
  const cinematicPending = useRef(false);
  const applyCinematic = () => {
    if (zoom) onRegionChange?.("zoom", zoom.id, { zoomLevel: 2.4 });
    if (tilt) onRegionChange?.("tilt", tilt.id, { pitch: 12, yaw: 0, roll: -3 });
  };
  useEffect(() => {
    if (cinematicPending.current && zoom && tilt) {
      cinematicPending.current = false;
      applyCinematic();
      commit();
    }
  });

  const slideOn = s.introSlideStyle !== "Off";
  const curtainOn = s.curtainUnveilCorner !== "Off";
  const hasLogo = s.curtainLogoFileName != null;
  const parallaxOn = s.parallaxStrength > 0.001;
  const zoomStyle = zoom?.animationStyle;
  const curtainColor = s.curtainColor ?? { red: coverColorTop.r, green: coverColorTop.g, blue: coverColorTop.b, opacity: coverColorTop.a };

  return (
    <PaneStack
      items={[
        {
          key: "slide",
          render: (first) => (
            <Box
              title="Slide"
              first={first}
              rows={[
                {
                  key: "toggle",
                  node: (
                    <ToggleRow
                      label="Slide"
                      checked={slideOn}
                      onChange={(on) => {
                        if (on) {
                          const joined = actions?.onJoinSlideToSelectedBlock?.() === true;
                          if (!joined && s.introSlideStyle === "Off") pick({ introSlideStyle: "Bottom" });
                        } else {
                          pick({ introSlideStyle: "Off" });
                        }
                      }}
                    />
                  ),
                },
                {
                  key: "chips",
                  show: slideOn,
                  node: (
                    <Chips
                      items={SLIDE_STYLES}
                      selectedIndex={Math.max(0, SLIDE_STYLES.indexOf(s.introSlideStyle))}
                      onSelect={(i) => pick({ introSlideStyle: SLIDE_STYLES[i] })}
                      ariaLabel="Slide direction"
                    />
                  ),
                },
                {
                  key: "pad",
                  show: slideOn,
                  attached: true,
                  node: (
                    <EffectPreviewPad
                      mode={{
                        kind: "slide",
                        style: slideOn ? s.introSlideStyle : "Bottom",
                        duration: s.introSlideDuration,
                        bounce: s.introSlideBounce,
                        depth: s.introSlideDepth,
                      }}
                    />
                  ),
                },
                {
                  key: "bounce",
                  show: slideOn,
                  node: (
                    <PillSlider
                      title="Bounce"
                      value={s.introSlideBounce}
                      min={0}
                      max={1}
                      step={0.05}
                      format={(v) => (v < 0.026 ? "None" : pctRounded(v))}
                      onChange={(v) => set({ introSlideBounce: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "speed",
                  show: slideOn,
                  node: (
                    <PillSlider
                      title="Speed"
                      value={s.introSlideSpeed}
                      min={1}
                      max={4}
                      step={0.25}
                      format={(v) => (v <= 1.01 ? "1x" : `${sig2(v)}x`)}
                      onChange={(v) => set({ introSlideSpeed: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "depth",
                  show: slideOn,
                  node: <ToggleRow label="Pull Toward Viewer" checked={s.introSlideDepth} onChange={(v) => pick({ introSlideDepth: v })} />,
                },
                {
                  key: "caption",
                  attached: true,
                  node: (
                    <Cap
                      line
                      full="The screen slides from an edge with a punchy settle. Pull Toward Viewer adds a 3D depth pull — the card starts small and deep, then dollies to the front as it lands. Drag the yellow Slide block on the EFFECTS lane to place it anywhere — at 0:00 it plays as the intro."
                    >
                      Slides in from an edge — drag the Slide block on the EFFECTS lane to place it.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "curtain",
          render: (first) => (
            <Box
              title="Curtain Unveil"
              first={first}
              rows={[
                {
                  key: "toggle",
                  node: <ToggleRow label="Curtain Unveil" checked={curtainOn} onChange={(on) => pick({ curtainUnveilCorner: on ? "Top Left" : "Off" })} />,
                },
                {
                  key: "chips",
                  show: curtainOn,
                  node: (
                    <Chips
                      items={CURTAIN_CORNERS}
                      selectedIndex={Math.max(0, CURTAIN_CORNERS.indexOf(s.curtainUnveilCorner))}
                      onSelect={(i) => pick({ curtainUnveilCorner: CURTAIN_CORNERS[i] })}
                      ariaLabel="Curtain corner"
                    />
                  ),
                },
                {
                  key: "length",
                  show: curtainOn,
                  node: (
                    <PillSlider
                      title="Length"
                      value={s.curtainUnveilDuration}
                      min={0.4}
                      max={3}
                      step={0.1}
                      format={fixed(1, "s")}
                      onChange={(v) => set({ curtainUnveilDuration: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "color",
                  show: curtainOn,
                  node: (
                    <Row label="Curtain">
                      <ColorSwatch color={toRGBA(curtainColor)} onChange={(c) => set({ curtainColor: toCodable(c, s.curtainColor) })} ariaLabel="Curtain colour" />
                    </Row>
                  ),
                },
                {
                  key: "resetColor",
                  show: curtainOn && s.curtainColor != null,
                  attached: true,
                  node: <RowButton onClick={() => pick({ curtainColor: undefined })}>Reset Color</RowButton>,
                },
                {
                  key: "logoButtons",
                  show: curtainOn,
                  node: (
                    <div className="cc-pane-hstack">
                      <InspectorButton onClick={actions?.onChooseCurtainLogo}>{hasLogo ? "Replace Logo…" : "Choose Logo…"}</InspectorButton>
                      {hasLogo && (
                        <InspectorButton
                          destructive
                          onClick={() => {
                            // EffectsSettingsPaneAppKit.removeCurtainLogo: the setting clears.
                            if (actions?.onRemoveCurtainLogo) actions.onRemoveCurtainLogo();
                            else pick({ curtainLogoFileName: undefined });
                          }}
                        >
                          Remove Logo
                        </InspectorButton>
                      )}
                    </div>
                  ),
                },
                {
                  key: "logoStatus",
                  show: curtainOn && hasPickerStatus(actions?.pickerStatus?.curtainLogo),
                  attached: true,
                  node: <PickerStatusLine status={actions?.pickerStatus?.curtainLogo} />,
                },
                {
                  key: "logoOpacity",
                  show: curtainOn && hasLogo,
                  node: (
                    <PillSlider title="Logo Opacity" value={s.curtainLogoOpacity} min={0} max={1} step={0.05} format={pctRounded} onChange={(v) => set({ curtainLogoOpacity: v })} onCommit={commit} />
                  ),
                },
                {
                  key: "logoSize",
                  show: curtainOn && hasLogo,
                  node: (
                    <PillSlider title="Logo Size" value={s.curtainLogoScale} min={0.05} max={0.8} step={0.05} format={pctRounded} onChange={(v) => set({ curtainLogoScale: v })} onCommit={commit} />
                  ),
                },
                {
                  key: "tintToggle",
                  show: curtainOn && hasLogo,
                  node: <ToggleRow label="Tint Logo" checked={s.curtainLogoTint != null} onChange={(on) => pick({ curtainLogoTint: on ? { ...WHITE } : undefined })} />,
                },
                {
                  key: "tint",
                  show: curtainOn && hasLogo && s.curtainLogoTint != null,
                  node: (
                    <Row label="Tint">
                      <ColorSwatch
                        color={toRGBA(s.curtainLogoTint ?? WHITE)}
                        onChange={(c) => set({ curtainLogoTint: toCodable(c, s.curtainLogoTint) })}
                        ariaLabel="Logo tint"
                      />
                    </Row>
                  ),
                },
                {
                  key: "caption",
                  attached: true,
                  node: (
                    <Cap
                      line
                      full="A curtain covers the screen and peels away from the chosen corner like a page turn, revealing the video underneath. Add a logo and it rides the curtain, peeling away with it. Drag the Curtain block on the EFFECTS lane to place it."
                    >
                      A curtain peels away from the chosen corner to reveal the video.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "parallax",
          render: (first) => (
            <Box
              title="Parallax"
              first={first}
              rows={[
                { key: "toggle", node: <ToggleRow label="Parallax" checked={parallaxOn} onChange={(on) => pick({ parallaxStrength: on ? 0.4 : 0 })} /> },
                {
                  key: "strength",
                  show: parallaxOn,
                  node: (
                    <PillSlider title="Strength" value={s.parallaxStrength} min={0.05} max={1} step={0.05} format={pctRounded} onChange={(v) => set({ parallaxStrength: v })} onCommit={commit} />
                  ),
                },
                { key: "pad", show: parallaxOn, attached: true, node: <PropertyPreviewPad mode={{ kind: "parallax", strength: s.parallaxStrength }} /> },
                { key: "caption", attached: true, node: <Cap line>The background drifts gently with zooms for a sense of depth.</Cap> },
              ]}
            />
          ),
        },
        {
          key: "motionBlur",
          render: (first) => (
            <Box
              title="Motion Blur"
              first={first}
              rows={[
                { key: "toggle", node: <ToggleRow label="Motion Blur" checked={s.motionBlur} onChange={(on) => pick({ motionBlur: on })} /> },
                {
                  key: "strength",
                  show: s.motionBlur,
                  node: (
                    <PillSlider title="Strength" value={s.motionBlurStrength} min={0} max={1} step={0.05} format={pctRounded} onChange={(v) => set({ motionBlurStrength: v })} onCommit={commit} />
                  ),
                },
                {
                  key: "pad",
                  show: s.motionBlur,
                  attached: true,
                  node: <PropertyPreviewPad mode={{ kind: "motionBlur", on: s.motionBlur, strength: s.motionBlurStrength }} />,
                },
                {
                  key: "caption",
                  attached: true,
                  node: (
                    <Cap line full="Adds subtle blur during fast camera movements for a more natural look.">
                      Subtle blur during fast camera movement, for a more natural look.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "zoom",
          render: (first) => (
            <Box
              title="Zoom"
              first={first}
              rows={[
                {
                  key: "toggle",
                  node: (
                    <ToggleRow
                      label="Zoom"
                      checked={zoom != null}
                      onChange={(on) => {
                        if (on) {
                          if (tilt) act?.({ type: "addZoomToBlock", tiltId: tilt.id });
                          else actions?.onAddZoomBlockAtPlayhead?.();
                        } else if (zoom) {
                          act?.({ type: "removeZoom", zoomId: zoom.id });
                        }
                      }}
                    />
                  ),
                },
                {
                  key: "level",
                  show: zoom != null,
                  node: (
                    <PillSlider
                      title="Zoom / Scale"
                      value={zoom?.zoomLevel ?? 2}
                      min={0.3}
                      max={6}
                      step={0.1}
                      format={fixed(1, "x")}
                      onChange={(v) => zoom && onRegionChange?.("zoom", zoom.id, { zoomLevel: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "speed",
                  show: zoom != null,
                  node: (
                    <MenuRow
                      label="Speed"
                      options={STYLE_MENU}
                      selectedIndex={zoomStyle ? ZOOM_STYLES.indexOf(zoomStyle) + 1 : 0}
                      onSelect={(i) => {
                        if (!zoom) return;
                        onRegionChange?.("zoom", zoom.id, { animationStyle: i === 0 ? undefined : ZOOM_STYLES[i - 1] });
                        commit();
                      }}
                    />
                  ),
                },
                {
                  key: "pad",
                  show: zoom != null,
                  attached: true,
                  node: (
                    <EffectPreviewPad
                      mode={{
                        kind: "zoom",
                        level: zoom?.zoomLevel ?? 2,
                        omegaMultiplier: zoomStyle ? zoomStyleOmegaMultiplier(zoomStyle) : 1,
                        damping: zoomStyle ? zoomStyleDamping(zoomStyle) : 0.88,
                      }}
                    />
                  ),
                },
                {
                  key: "follow",
                  show: zoom != null,
                  node: (
                    <ToggleRow
                      label="Follow Cursor"
                      checked={zoom?.followsCursor ?? true}
                      onChange={(on) => {
                        if (!zoom) return;
                        onRegionChange?.("zoom", zoom.id, { followsCursor: on ? undefined : false });
                        commit();
                      }}
                    />
                  ),
                },
                {
                  key: "focus",
                  show: zoom != null,
                  node: (
                    <ZoomFocusPad
                      focal={zoom?.focalPoint ?? { x: 0.5, y: 0.5 }}
                      onChange={(p) => zoom && onRegionChange?.("zoom", zoom.id, { focalPoint: p })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "offset",
                  show: zoom != null,
                  node: (
                    <ZoomFocusPad
                      title="Offset"
                      focal={{
                        x: (zoom?.cardOffsetX ?? 0) / (2 * cardOffsetLimit) + 0.5,
                        y: (zoom?.cardOffsetY ?? 0) / (2 * cardOffsetLimit) + 0.5,
                      }}
                      onChange={(p) => {
                        if (!zoom) return;
                        // Pad 0…1 maps to the full ±cardOffsetLimit excursion;
                        // dead-centre means none.
                        const dx = (p.x - 0.5) * 2 * cardOffsetLimit;
                        const dy = (p.y - 0.5) * 2 * cardOffsetLimit;
                        const none = Math.abs(dx) < 0.02 && Math.abs(dy) < 0.02;
                        onRegionChange?.("zoom", zoom.id, { cardOffsetX: none ? undefined : dx, cardOffsetY: none ? undefined : dy });
                      }}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "caption",
                  show: zoom != null,
                  attached: true,
                  node: (
                    <Cap line full="How far this block pushes in. The block on the EFFECTS lane shows the level.">
                      How far this block pushes in — the EFFECTS block shows the level.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "tilt",
          render: (first) => (
            <Box
              title="Tilt"
              first={first}
              rows={[
                {
                  key: "toggle",
                  node: (
                    <ToggleRow
                      label="Tilt"
                      checked={tilt != null}
                      onChange={(on) => {
                        if (on) {
                          if (zoom) act?.({ type: "addTiltToBlock", zoomId: zoom.id });
                          else actions?.onAddTiltBlockAtPlayhead?.();
                        } else if (tilt) {
                          act?.({ type: "removeTilt", tiltId: tilt.id });
                        }
                      }}
                    />
                  ),
                },
                {
                  key: "pad",
                  show: tilt != null,
                  node: (
                    <TiltPad
                      pitch={tilt?.pitch ?? 0}
                      yaw={tilt?.yaw ?? 0}
                      roll={tilt?.roll ?? 0}
                      onChange={(pitch, yaw) => tilt && onRegionChange?.("tilt", tilt.id, { pitch, yaw })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "presets",
                  show: tilt != null,
                  attached: true,
                  node: (
                    <Chips
                      items={TILT_PRESETS}
                      selectedIndex={presetIndex}
                      onSelect={(i) => {
                        setPresetIndex(i);
                        if (!tilt) return;
                        const [pitch, yaw, roll] = TILT_PRESET_VALUES[i];
                        onRegionChange?.("tilt", tilt.id, { pitch, yaw, roll });
                        commit();
                      }}
                      ariaLabel="Tilt presets"
                    />
                  ),
                },
                {
                  key: "rotation",
                  show: tilt != null,
                  node: (
                    <PillSlider
                      title="Rotation"
                      value={tilt?.roll ?? 0}
                      min={-30}
                      max={30}
                      step={1}
                      format={fixed(0, "°")}
                      onChange={(v) => tilt && onRegionChange?.("tilt", tilt.id, { roll: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "speed",
                  show: tilt != null,
                  node: (
                    <MenuRow
                      label="Speed"
                      options={STYLE_MENU}
                      selectedIndex={tilt?.animationStyle ? ZOOM_STYLES.indexOf(tilt.animationStyle) + 1 : 0}
                      onSelect={(i) => {
                        if (!tilt) return;
                        onRegionChange?.("tilt", tilt.id, { animationStyle: i === 0 ? undefined : ZOOM_STYLES[i - 1] });
                        commit();
                      }}
                    />
                  ),
                },
                {
                  key: "buttons",
                  show: tilt != null,
                  node: (
                    <div className="cc-pane-hstack">
                      <InspectorButton
                        onClick={() => {
                          // One-click reference look: deep push-in, gentle
                          // pitch-back, a whisper of roll.
                          if (!zoom && tilt) act?.({ type: "addZoomToBlock", tiltId: tilt.id });
                          if (!tilt && zoom) act?.({ type: "addTiltToBlock", zoomId: zoom.id });
                          if (zoom && tilt) {
                            applyCinematic();
                            commit();
                          } else {
                            cinematicPending.current = true;
                          }
                        }}
                      >
                        Cinematic
                      </InspectorButton>
                    </div>
                  ),
                },
                {
                  key: "caption",
                  show: tilt != null,
                  attached: true,
                  node: (
                    <Cap
                      line
                      full="Drag the pad to skew the screen — left/right tips a side back, up/down tips the top or bottom back. The preview updates live."
                    >
                      Drag the pad to skew the screen — the preview updates live.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "highlight",
          show: highlight != null,
          render: (first) => (
            <Box
              title="Highlight Mask"
              first={first}
              rows={[
                {
                  key: "opacity",
                  node: (
                    <PillSlider
                      title="Opacity"
                      value={highlight?.opacity ?? 0.55}
                      min={0.1}
                      max={0.9}
                      format={pctTrunc}
                      onChange={(v) => highlight && onRegionChange?.("highlight", highlight.id, { opacity: v })}
                      onCommit={commit}
                    />
                  ),
                },
                { key: "pad", attached: true, node: <PropertyPreviewPad mode={{ kind: "highlightMask", opacity: highlight?.opacity ?? 0.55 }} /> },
                {
                  key: "caption",
                  attached: true,
                  node: (
                    <Cap line full="Highlights softly dim everything outside the selected region so attention stays on the important area.">
                      Softly dims everything outside the selected region.
                    </Cap>
                  ),
                },
                {
                  key: "remove",
                  node: (
                    <RowButton destructive onClick={() => highlight && act?.({ type: "delete", target: { lane: "focus", id: highlight.id, isHighlight: true } })}>
                      Remove Highlight
                    </RowButton>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "depthFocus",
          show: depth != null,
          render: (first) => (
            <Box
              title="Depth Focus"
              first={first}
              rows={[
                {
                  key: "style",
                  node: (
                    <Chips
                      items={FOCUS_STYLES}
                      selectedIndex={Math.max(0, FOCUS_STYLES.indexOf(depth?.style ?? "Area"))}
                      onSelect={(i) => {
                        if (!depth) return;
                        onRegionChange?.("focus", depth.id, { style: FOCUS_STYLES[i] });
                        commit();
                      }}
                      ariaLabel="Depth focus style"
                    />
                  ),
                },
                {
                  key: "strength",
                  node: (
                    <PillSlider
                      title="Blur Strength"
                      value={depth?.intensity ?? 0.7}
                      min={0.1}
                      max={1}
                      step={0.05}
                      format={pctRounded}
                      onChange={(v) => depth && onRegionChange?.("focus", depth.id, { intensity: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "falloff",
                  node: (
                    <PillSlider
                      title="Focus Falloff"
                      value={depth?.falloff ?? 0.45}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctRounded}
                      onChange={(v) => depth && onRegionChange?.("focus", depth.id, { falloff: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "corner",
                  // Corner radius is Area-only; angle is Tilt-Shift-only.
                  show: depth?.style === "Area",
                  node: (
                    <PillSlider
                      title="Corner Radius"
                      value={depth?.cornerRadius ?? 0.24}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctRounded}
                      onChange={(v) => depth && onRegionChange?.("focus", depth.id, { cornerRadius: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "angle",
                  show: depth?.style === "Tilt Shift",
                  node: (
                    <PillSlider
                      title="Angle"
                      value={depth?.angle ?? 0}
                      min={-90}
                      max={90}
                      step={1}
                      format={degRounded}
                      onChange={(v) => depth && onRegionChange?.("focus", depth.id, { angle: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "caption",
                  attached: true,
                  node: (
                    <Cap
                      line
                      full="The focused area stays sharp while everything outside melts into a graduated blur. Area follows the rect; Tilt Shift blurs with distance from an angled band through its centre. Drag and resize the region on the preview."
                    >
                      Sharp inside the region, graduated blur outside — drag it on the preview.
                    </Cap>
                  ),
                },
                {
                  key: "remove",
                  node: (
                    <RowButton destructive onClick={() => depth && act?.({ type: "delete", target: { lane: "focus", id: depth.id, isHighlight: false } })}>
                      Remove Depth Focus
                    </RowButton>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "blur",
          show: blur != null,
          render: (first) => (
            <Box
              title="Blur"
              first={first}
              rows={[
                {
                  key: "style",
                  node: (
                    <Chips
                      items={BLUR_STYLES}
                      selectedIndex={Math.max(0, BLUR_STYLES.indexOf(blur?.style ?? "Blur"))}
                      onSelect={(i) => {
                        if (!blur) return;
                        onRegionChange?.("blur", blur.id, { style: BLUR_STYLES[i] });
                        commit();
                      }}
                      ariaLabel="Blur style"
                    />
                  ),
                },
                {
                  key: "strength",
                  node: (
                    <PillSlider
                      title="Strength"
                      value={blur?.intensity ?? 0.6}
                      min={0.1}
                      max={1}
                      step={0.05}
                      format={pctRounded}
                      onChange={(v) => blur && onRegionChange?.("blur", blur.id, { intensity: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "animated",
                  // Animation only means something for the mosaic.
                  show: blur?.style === "Pixelate",
                  node: (
                    <ToggleRow
                      label="Animated"
                      checked={blur?.animated ?? false}
                      onChange={(on) => {
                        if (!blur) return;
                        onRegionChange?.("blur", blur.id, { animated: on });
                        commit();
                      }}
                    />
                  ),
                },
                {
                  key: "caption",
                  attached: true,
                  node: (
                    <Cap line full="Blur softens the region; Pixelate covers it with a mosaic. Animated jitters the mosaic grid over time — the classic censor look.">
                      Blur softens the region; Pixelate covers it with a mosaic.
                    </Cap>
                  ),
                },
                {
                  key: "remove",
                  node: (
                    <RowButton destructive onClick={() => blur && act?.({ type: "delete", target: { lane: "focus", id: blur.id, isHighlight: false } })}>
                      Remove Blur
                    </RowButton>
                  ),
                },
              ]}
            />
          ),
        },
      ]}
    />
  );
}
