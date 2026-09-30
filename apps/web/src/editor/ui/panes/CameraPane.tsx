/**
 * The Camera tab, 1:1 with CameraSettingsPaneAppKit: Camera Overlay (toggle,
 * drag-to-place pad, position/shape menus, orientation chips for the
 * aspect-following shapes, mirror, size as % of canvas width), Adjust
 * (colour sliders, look chips, ring light), Style (corner radius for rounded
 * rect, border + colour with reset, opacity, ±25° skew pad) and Name Tag.
 */
import type { ProjectSettings } from "../../core/model";
import { CameraFilterStyle, CameraOrientation, CameraPosition, CameraShape, CameraTagPosition, enumValues } from "../../core/model/enums";
import { borderColor } from "../../core/math/cameraStyleMath";
import { formatFixed, sInt } from "../../core/math/swift";
import { Chips, ColorSwatch, InspectorButton, InspectorField, PillSlider, Row, ToggleRow } from "../kit";
import { Box, PaneStack } from "./layout";
import { CameraPreviewPad, TiltPad } from "./livePads";
import { Cap, MenuRow, pctTrunc, toCodable, toRGBA } from "./shared";
import { resolveFacts, type PaneProps } from "./types";

const POSITIONS = enumValues(CameraPosition);
const SHAPES = enumValues(CameraShape);
const ORIENTATIONS = enumValues(CameraOrientation);
const TAG_POSITIONS = enumValues(CameraTagPosition);
const FILTERS = enumValues(CameraFilterStyle);
/** Size is shown as % of a 1456pt nominal canvas width (persisted in points). */
const NOMINAL = 1456;

export function CameraPane({ settings: s, onSettingsChange, onCommit, project, facts: overrides }: PaneProps) {
  const facts = resolveFacts(project, overrides);
  const set = (patch: Partial<ProjectSettings>) => onSettingsChange(patch);
  const pick = (patch: Partial<ProjectSettings>) => {
    onSettingsChange(patch);
    onCommit?.();
  };
  const commit = () => onCommit?.();
  const hasCamera = facts.hasRecordedCamera;
  const details = hasCamera && s.showCamera;
  const aspectShape = s.cameraShape === "Rounded Rectangle" || s.cameraShape === "Squircle";
  const effectiveSize = Math.max(120, s.cameraSize);
  const border = borderColor(s);

  return (
    <PaneStack
      items={[
        {
          key: "overlay",
          render: (first) => (
            <Box
              title="Camera Overlay"
              first={first}
              rows={[
                {
                  key: "show",
                  node: <ToggleRow label="Show Camera" checked={s.showCamera} disabled={!hasCamera} onChange={(v) => pick({ showCamera: v })} />,
                },
                !hasCamera && {
                  key: "noCamera",
                  attached: true,
                  node: <Cap>No recorded camera video is available for this project.</Cap>,
                },
                {
                  key: "pad",
                  node: (
                    <CameraPreviewPad
                      s={s}
                      dimmed={!details}
                      onPlace={(x, y) => set({ cameraCustomX: x, cameraCustomY: y })}
                      onSnap={(corner) => pick({ cameraPosition: corner, cameraCustomX: undefined, cameraCustomY: undefined })}
                    />
                  ),
                },
                {
                  key: "position",
                  show: details,
                  node: (
                    <MenuRow
                      label="Position"
                      options={POSITIONS}
                      selectedIndex={POSITIONS.indexOf(s.cameraPosition)}
                      // Picking a corner from the menu clears free placement.
                      onSelect={(i) => pick({ cameraPosition: POSITIONS[i], cameraCustomX: undefined, cameraCustomY: undefined })}
                    />
                  ),
                },
                {
                  key: "shape",
                  show: details,
                  node: <MenuRow label="Shape" options={SHAPES} selectedIndex={SHAPES.indexOf(s.cameraShape)} onSelect={(i) => pick({ cameraShape: SHAPES[i] })} />,
                },
                {
                  key: "orientation",
                  show: details && aspectShape,
                  attached: true,
                  node: (
                    <Chips
                      items={ORIENTATIONS}
                      selectedIndex={Math.max(0, ORIENTATIONS.indexOf(s.cameraOrientation))}
                      onSelect={(i) => pick({ cameraOrientation: ORIENTATIONS[i] })}
                      ariaLabel="Orientation"
                    />
                  ),
                },
                {
                  key: "mirror",
                  show: details,
                  node: <ToggleRow label="Mirror Camera" checked={s.cameraMirrored} onChange={(v) => pick({ cameraMirrored: v })} />,
                },
                {
                  key: "size",
                  show: details,
                  node: (
                    <PillSlider
                      title="Size"
                      value={(effectiveSize / NOMINAL) * 100}
                      min={8}
                      max={22}
                      step={0.5}
                      format={(v) => (v % 1 === 0 ? `${sInt(v)}%` : `${formatFixed(v, 1)}%`)}
                      onChange={(v) => set({ cameraSize: (v / 100) * NOMINAL })}
                      onCommit={commit}
                    />
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "adjust",
          show: details,
          render: (first) => (
            <Box
              title="Adjust"
              first={first}
              rows={[
                { key: "brightness", node: <PillSlider title="Brightness" value={s.cameraBrightness} min={-1} max={1} step={0.05} onChange={(v) => set({ cameraBrightness: v })} onCommit={commit} /> },
                { key: "contrast", node: <PillSlider title="Contrast" value={s.cameraContrast} min={0.5} max={1.5} step={0.05} onChange={(v) => set({ cameraContrast: v })} onCommit={commit} /> },
                { key: "saturation", node: <PillSlider title="Saturation" value={s.cameraSaturation} min={0} max={2} step={0.05} onChange={(v) => set({ cameraSaturation: v })} onCommit={commit} /> },
                {
                  key: "hue",
                  node: <PillSlider title="Hue" value={s.cameraHue} min={-180} max={180} step={5} format={(v) => `${sInt(v)}°`} onChange={(v) => set({ cameraHue: v })} onCommit={commit} />,
                },
                {
                  key: "filter",
                  node: <Chips items={FILTERS} selectedIndex={Math.max(0, FILTERS.indexOf(s.cameraFilter))} onSelect={(i) => pick({ cameraFilter: FILTERS[i] })} ariaLabel="Look" />,
                },
                {
                  key: "ring",
                  node: <PillSlider title="Ring Light" value={s.cameraRingLight} min={0} max={1} step={0.05} format={pctTrunc} onChange={(v) => set({ cameraRingLight: v })} onCommit={commit} />,
                },
              ]}
            />
          ),
        },
        {
          key: "style",
          show: details,
          render: (first) => (
            <Box
              title="Style"
              first={first}
              rows={[
                {
                  key: "corner",
                  // Corner radius only applies to the rounded-rect shape.
                  show: s.cameraShape === "Rounded Rectangle",
                  node: <PillSlider title="Corner Radius" value={s.cameraCornerRadius} min={0} max={60} step={1} onChange={(v) => set({ cameraCornerRadius: v })} onCommit={commit} />,
                },
                { key: "border", node: <PillSlider title="Border" value={s.cameraBorderWidth} min={0} max={8} step={0.5} onChange={(v) => set({ cameraBorderWidth: v })} onCommit={commit} /> },
                {
                  key: "borderColor",
                  node: (
                    <Row label="Border Color">
                      <span className="cc-pane-pair">
                        <ColorSwatch
                          color={{ r: border.red, g: border.green, b: border.blue, a: border.alpha }}
                          onChange={(c) => set({ cameraBorderColor: toCodable(c, s.cameraBorderColor) })}
                          ariaLabel="Border Color"
                        />
                        {/* Back to the default white 30% (nil). */}
                        <InspectorButton onClick={() => pick({ cameraBorderColor: undefined })}>Reset</InspectorButton>
                      </span>
                    </Row>
                  ),
                },
                {
                  key: "opacity",
                  node: <PillSlider title="Opacity" value={s.cameraOpacity} min={0.2} max={1} step={0.05} format={pctTrunc} onChange={(v) => set({ cameraOpacity: v })} onCommit={commit} />,
                },
                {
                  key: "tilt",
                  node: (
                    <TiltPad
                      pitch={s.cameraTiltPitch}
                      yaw={s.cameraTiltYaw}
                      roll={0}
                      maxAngle={25}
                      onChange={(pitch, yaw) => set({ cameraTiltPitch: pitch, cameraTiltYaw: yaw })}
                      onCommit={commit}
                    />
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "tag",
          show: details,
          render: (first) => (
            <Box
              title="Name Tag"
              first={first}
              rows={[
                {
                  key: "text",
                  node: <InspectorField placeholder="Name" value={s.cameraTagText} onChange={(e) => set({ cameraTagText: e.target.value })} onBlur={commit} />,
                },
                {
                  key: "subtext",
                  node: <InspectorField placeholder="Role / company" value={s.cameraTagSubtext} onChange={(e) => set({ cameraTagSubtext: e.target.value })} onBlur={commit} />,
                },
                {
                  key: "position",
                  node: (
                    <MenuRow label="Tag Position" options={TAG_POSITIONS} selectedIndex={TAG_POSITIONS.indexOf(s.cameraTagPosition)} onSelect={(i) => pick({ cameraTagPosition: TAG_POSITIONS[i] })} />
                  ),
                },
                {
                  key: "textColor",
                  node: (
                    <Row label="Text Color">
                      <ColorSwatch color={toRGBA(s.cameraTagTextColor)} onChange={(c) => set({ cameraTagTextColor: toCodable(c, s.cameraTagTextColor) })} ariaLabel="Text Color" />
                    </Row>
                  ),
                },
                {
                  key: "fill",
                  node: (
                    <Row label="Tag Fill">
                      <ColorSwatch
                        color={toRGBA(s.cameraTagBackgroundColor)}
                        onChange={(c) => set({ cameraTagBackgroundColor: toCodable(c, s.cameraTagBackgroundColor) })}
                        ariaLabel="Tag Fill"
                      />
                    </Row>
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
