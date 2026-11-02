/**
 * The Camera tab, 1:1 with CameraSettingsPaneAppKit: Camera Overlay (toggle,
 * drag-to-place pad, position/shape menus, orientation chips for the
 * aspect-following shapes, mirror, size as % of canvas width + Shrink during
 * zoom, the vertical stack's switch + camera height (§12.12) — and, first
 * under the pad, Background: the whole-video camera look,
 * then the camera styles of docs/camera-cutout.md §12.8: edge softness /
 * inset for either look; pop-out amount, card fill (gradient colours /
 * background blur / colour / image grid) and border for the pop-out card),
 * Adjust (colour sliders, look chips, ring light), Style (corner radius for
 * rounded rect, border + colour with reset, opacity, ±25° skew pad) and
 * Name Tag.
 */
import type { CodableColor, ProjectSettings } from "../../core/model";
import {
  CameraCardBorder,
  CameraCardFill,
  CameraFilterStyle,
  CameraOrientation,
  CameraPosition,
  CameraShape,
  CameraTagPosition,
  enumValues,
  type CameraLook,
} from "../../core/model/enums";
import { cameraCardStyle, type CardRGB } from "../../core/math/cameraCardStyle";
import { stackRatio, stackRatioRange, stackGap, stackGapRange } from "../../core/math/cameraLayoutMath";
import { borderColor } from "../../core/math/cameraStyleMath";
import { formatFixed, sInt, srounded } from "../../core/math/swift";
import { Button, Chips, ColorSwatch, InspectorButton, InspectorField, PillSlider, Row, ToggleRow, type MenuEntry } from "../kit";
import { Box, PaneStack } from "./layout";
import { CameraPreviewPad, TiltPad } from "./livePads";
import { WallpaperGrid, type WallpaperItem } from "./pads";
import { hasPickerStatus, PickerStatusLine } from "./pickerStatus";
import { Cap, MenuRow, pctTrunc, toCodable, toRGBA } from "./shared";
import { resolveFacts, type PaneProps } from "./types";

const POSITIONS = enumValues(CameraPosition);
const SHAPES = enumValues(CameraShape);
const ORIENTATIONS = enumValues(CameraOrientation);
const TAG_POSITIONS = enumValues(CameraTagPosition);
const FILTERS = enumValues(CameraFilterStyle);
/** Background: settings.cameraLook for the whole video (absent = None) — not a
 *  timeline block; camera-layout blocks still override it for their span. */
const BACKGROUNDS: readonly (CameraLook | undefined)[] = [undefined, "cutout", "popOut"];
const BACKGROUND_LABELS = ["None", "Cutout", "Pop-out card"];
/** Size is shown as % of a 1456pt nominal canvas width (persisted in points). */
const NOMINAL = 1456;
/** Card fill chips (absent = Gradient, written as absent). */
const CARD_FILLS = enumValues(CameraCardFill);
const CARD_FILL_LABELS = ["Gradient", "Camera", "Color", "Image"];
/** Border chips: None (absent), then the presets. */
const CARD_BORDERS: readonly (CameraCardBorder | undefined)[] = [undefined, ...enumValues(CameraCardBorder)];
const CARD_BORDER_LABELS = ["None", "Solid", "Aurora", "Gold"];

const codable = (c: CardRGB): CodableColor => ({ red: c.r, green: c.g, blue: c.b, opacity: 1 });

export function CameraPane({ settings: s, onSettingsChange, onCommit, project, actions, facts: overrides }: PaneProps) {
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
  // §12.8 camera styles: shown while the project draws a look — the
  // whole-video Background or a Bubble block's look.
  const regionLooks = project?.cameraLayoutRegions.filter((r) => r.mode === "bubble").map((r) => r.look) ?? [];
  const usesLook = details && (s.cameraLook !== undefined || regionLooks.some((l) => l !== undefined));
  const usesPopOut = details && (s.cameraLook === "popOut" || regionLooks.includes("popOut"));
  const card = cameraCardStyle(s);
  // Card images: the image library + the card's own image when it is not one of them.
  const cardImages = actions?.cameraCardImages;
  const cardLibrary: readonly WallpaperItem[] = cardImages?.library ?? [];
  const cardCurrent = cardImages?.current ?? null;
  const cardTiles = cardCurrent && !cardLibrary.some((t) => t.path === cardCurrent.path) ? [cardCurrent, ...cardLibrary] : cardLibrary;
  const cardStatus = actions?.pickerStatus?.cameraCard;
  const selectCardTile = (path: string) => {
    const tile = cardTiles.find((t) => t.path === path);
    if (cardImages && tile) cardImages.onSelect(tile);
    else pick({ cameraCardImagePath: path });
  };
  const cardTileMenu = (tile: WallpaperItem): MenuEntry[] | null => {
    if (!cardImages) return null;
    const entries: MenuEntry[] = [];
    if (cardImages.onRemoveFromLibrary && cardLibrary.some((t) => t.path === tile.path)) {
      entries.push({ title: "Remove from Library", icon: "trash", destructive: true, onSelect: () => cardImages.onRemoveFromLibrary?.(tile) });
    }
    return entries;
  };

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
                  key: "backgroundLabel",
                  show: details,
                  node: <Row label="Background">{null}</Row>,
                },
                {
                  key: "background",
                  show: details,
                  attached: true,
                  node: (
                    <Chips
                      items={BACKGROUND_LABELS}
                      selectedIndex={Math.max(0, BACKGROUNDS.indexOf(s.cameraLook))}
                      onSelect={(i) => pick({ cameraLook: BACKGROUNDS[i] })}
                      ariaLabel="Background"
                    />
                  ),
                },
                {
                  key: "edgeSoftness",
                  show: usesLook,
                  node: (
                    <PillSlider
                      title="Edge softness"
                      value={card.edgeSoftness}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctTrunc}
                      onChange={(v) => set({ cameraEdgeSoftness: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "edgeInset",
                  show: usesLook,
                  node: (
                    <PillSlider
                      title="Edge inset"
                      value={card.edgeInset}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctTrunc}
                      onChange={(v) => set({ cameraEdgeInset: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "popOutAmount",
                  show: usesPopOut,
                  node: (
                    <PillSlider
                      title="Pop-out"
                      value={card.popOutAmount ?? 0.5}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctTrunc}
                      onChange={(v) => set({ cameraPopOutAmount: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "cardLabel",
                  show: usesPopOut,
                  node: <Row label="Card">{null}</Row>,
                },
                {
                  key: "cardFill",
                  show: usesPopOut,
                  attached: true,
                  node: (
                    <Chips
                      items={CARD_FILL_LABELS}
                      selectedIndex={Math.max(0, CARD_FILLS.indexOf(card.fill))}
                      // Gradient is the default: written as absent, like Background None.
                      onSelect={(i) => pick({ cameraCardFill: i === 0 ? undefined : CARD_FILLS[i] })}
                      ariaLabel="Card"
                    />
                  ),
                },
                {
                  key: "cardGradientStart",
                  show: usesPopOut && card.fill === "gradient",
                  node: (
                    <Row label="Start Color">
                      <ColorSwatch
                        color={toRGBA(s.cameraCardGradientStart ?? codable(card.gradientTop))}
                        onChange={(c) => set({ cameraCardGradientStart: toCodable(c, s.cameraCardGradientStart) })}
                        ariaLabel="Start Color"
                      />
                    </Row>
                  ),
                },
                {
                  key: "cardGradientEnd",
                  show: usesPopOut && card.fill === "gradient",
                  node: (
                    <Row label="End Color">
                      <ColorSwatch
                        color={toRGBA(s.cameraCardGradientEnd ?? codable(card.gradientBottom))}
                        onChange={(c) => set({ cameraCardGradientEnd: toCodable(c, s.cameraCardGradientEnd) })}
                        ariaLabel="End Color"
                      />
                    </Row>
                  ),
                },
                {
                  key: "cardBlur",
                  show: usesPopOut && card.fill === "camera",
                  node: (
                    <PillSlider
                      title="Background blur"
                      value={Math.min(1, Math.max(0, s.cameraBackgroundBlur ?? 0))}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctTrunc}
                      onChange={(v) => set({ cameraBackgroundBlur: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "cardColor",
                  show: usesPopOut && card.fill === "color",
                  node: (
                    <Row label="Color">
                      <ColorSwatch
                        color={toRGBA(s.cameraCardColor ?? codable(card.color))}
                        onChange={(c) => set({ cameraCardColor: toCodable(c, s.cameraCardColor) })}
                        ariaLabel="Card Color"
                      />
                    </Row>
                  ),
                },
                {
                  key: "cardChoose",
                  show: usesPopOut && card.fill === "image",
                  node: (
                    <Button variant="secondary" symbol="photo" onClick={actions?.onChooseCameraCardImage} style={{ alignSelf: "flex-start" }}>
                      Choose Image…
                    </Button>
                  ),
                },
                {
                  key: "cardChooseStatus",
                  show: usesPopOut && card.fill === "image" && hasPickerStatus(cardStatus),
                  attached: true,
                  node: <PickerStatusLine status={cardStatus} />,
                },
                {
                  key: "cardImages",
                  show: usesPopOut && card.fill === "image",
                  attached: true,
                  node: <WallpaperGrid mode="images" items={cardTiles} selected={s.cameraCardImagePath ?? null} onSelect={selectCardTile} menuFor={cardTileMenu} />,
                },
                {
                  key: "cardBorderLabel",
                  show: usesPopOut,
                  node: <Row label="Border">{null}</Row>,
                },
                {
                  key: "cardBorder",
                  show: usesPopOut,
                  attached: true,
                  node: (
                    <Chips
                      items={CARD_BORDER_LABELS}
                      selectedIndex={Math.max(0, CARD_BORDERS.indexOf(s.cameraCardBorder))}
                      onSelect={(i) => pick({ cameraCardBorder: CARD_BORDERS[i] })}
                      ariaLabel="Border"
                    />
                  ),
                },
                {
                  key: "cardBorderWidth",
                  show: usesPopOut && card.border !== null,
                  node: (
                    <PillSlider
                      title="Thickness"
                      value={card.borderThickness}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctTrunc}
                      onChange={(v) => set({ cameraCardBorderWidth: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "cardBorderColor",
                  show: usesPopOut && card.border === "solid",
                  node: (
                    <Row label="Color">
                      <ColorSwatch
                        color={toRGBA(s.cameraCardBorderColor ?? codable(card.borderColor))}
                        onChange={(c) => set({ cameraCardBorderColor: toCodable(c, s.cameraCardBorderColor) })}
                        ariaLabel="Card Border Color"
                      />
                    </Row>
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
                {
                  key: "shrink",
                  show: details,
                  // §12.5: off keeps the bubble at its base size while the screen is zoomed.
                  node: <ToggleRow label="Shrink during zoom" checked={card.shrinkOnZoom} onChange={(v) => pick({ cameraShrinkOnZoom: v ? undefined : false })} />,
                },
                {
                  key: "stack",
                  show: details,
                  // §12.12: camera row on top, screen below — portrait outputs only.
                  node: (
                    <ToggleRow
                      label="Stack on top in vertical videos"
                      checked={s.cameraPortraitStack ?? false}
                      onChange={(v) => pick({ cameraPortraitStack: v ? true : undefined })}
                    />
                  ),
                },
                {
                  key: "stackRatio",
                  show: details && (s.cameraPortraitStack ?? false),
                  node: (
                    <PillSlider
                      title="Camera height"
                      value={stackRatio(s.cameraStackRatio)}
                      min={stackRatioRange.lowerBound}
                      max={stackRatioRange.upperBound}
                      step={0.01}
                      format={(v) => `${sInt(srounded(v * 100))}%`}
                      onChange={(v) => set({ cameraStackRatio: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "stackGap",
                  show: details && (s.cameraPortraitStack ?? false),
                  // §12.14: the gap between the rows; None joins them into one card.
                  node: (
                    <PillSlider
                      title="Gap"
                      value={stackGap(s.cameraStackGap)}
                      min={stackGapRange.lowerBound}
                      max={stackGapRange.upperBound}
                      step={0.01}
                      format={(v) => (v <= 0 ? "None" : `${sInt(srounded(v * 100))}%`)}
                      onChange={(v) => set({ cameraStackGap: v })}
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
