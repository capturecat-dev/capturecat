/**
 * The Background tab, 1:1 with BackgroundSettingsPaneAppKit: background type
 * chips, colour rows / image / wallpaper source, the LOOK stack, FRAME
 * (placement + pad, padding, shape, corners, shadows + frame pad) and MENU
 * BAR. Reads/writes core ProjectSettings verbatim.
 */
import type { ProjectSettings } from "../../core/model";
import { BackgroundType, FrameShape, MenuBarReplacement, MenuBarTitleAlignment, VideoPlacement, enumValues } from "../../core/model/enums";
import { Button, Chips, ColorSwatch, InspectorButton, InspectorField, PillSlider, Row, ToggleRow } from "../kit";
import { Box, PaneStack } from "./layout";
import { PropertyPreviewPad } from "./livePads";
import { PlacementPad, WallpaperGrid, type WallpaperItem } from "./pads";
import { sInt, srounded } from "../../core/math/swift";
import { Cap, MenuRow, RowButton, degRounded, fixed, pctTrunc, toCodable, toRGBA } from "./shared";
import { resolveFacts, type PaneProps } from "./types";

const TYPES = enumValues(BackgroundType);
const PLACEMENTS = enumValues(VideoPlacement);
const SHAPES = enumValues(FrameShape);
const MENU_BARS = enumValues(MenuBarReplacement);
const ALIGNMENTS = enumValues(MenuBarTitleAlignment);
/** The chips shorten "Clean Dark/Light" to "Dark/Light". */
const MENU_BAR_CHIPS = ["Original", "Hidden", "Dark", "Light"];

/** BackgroundLook.Spec.isPlainLook — every look slider at identity. */
export function isPlainLook(s: ProjectSettings): boolean {
  return (
    s.backgroundBlur === 0 &&
    s.backgroundPixelate === 0 &&
    s.backgroundHalftone === 0 &&
    s.backgroundNoise === 0 &&
    s.backgroundContrast === 1 &&
    s.backgroundHue === 0 &&
    s.backgroundBrightness === 0 &&
    s.backgroundSaturation === 1 &&
    s.backgroundTintOpacity <= 0 &&
    s.backgroundVignette === 0
  );
}

const RESET_LOOK: Partial<ProjectSettings> = {
  backgroundBlur: 0,
  backgroundBrightness: 0,
  backgroundSaturation: 1,
  backgroundTintOpacity: 0,
  backgroundVignette: 0,
  backgroundPixelate: 0,
  backgroundHalftone: 0,
  backgroundNoise: 0,
  backgroundContrast: 1,
  backgroundHue: 0,
};

export function BackgroundPane({
  settings: s,
  onSettingsChange,
  onCommit,
  project,
  actions,
  facts: factOverrides,
  wallpapers,
  libraryImages,
}: PaneProps & {
  /** Catalog tiles (the Mac scans macOS wallpapers; the web has none unless
   *  the store supplies them). */
  wallpapers?: readonly WallpaperItem[];
  /** The user's image library (Image tab grid). */
  libraryImages?: readonly WallpaperItem[];
}) {
  const facts = resolveFacts(project, factOverrides);
  const set = (patch: Partial<ProjectSettings>) => onSettingsChange(patch);
  const pick = (patch: Partial<ProjectSettings>) => {
    onSettingsChange(patch);
    onCommit?.();
  };
  const commit = () => onCommit?.();
  const type = s.backgroundType;
  const usesRamp = type === "Gradient" || type === "Mesh";
  // PlacementMath.isCustom
  const isCustom = s.videoCustomX != null || s.videoCustomY != null;
  const replacement = s.menuBarReplacement;
  const showsCustomBar = replacement === "Clean Dark" || replacement === "Clean Light";

  return (
    <PaneStack
      items={[
        {
          key: "background",
          render: (first) => (
            <Box
              title="Background"
              first={first}
              rows={[
                {
                  key: "type",
                  node: (
                    <Chips items={TYPES} selectedIndex={Math.max(0, TYPES.indexOf(type))} onSelect={(i) => pick({ backgroundType: TYPES[i] })} ariaLabel="Background type" />
                  ),
                },
                {
                  key: "start",
                  show: usesRamp,
                  node: (
                    <Row label="Start Color">
                      <ColorSwatch color={toRGBA(s.gradientStartColor)} onChange={(c) => set({ gradientStartColor: toCodable(c, s.gradientStartColor) })} ariaLabel="Start Color" />
                    </Row>
                  ),
                },
                {
                  key: "end",
                  show: usesRamp,
                  node: (
                    <Row label="End Color">
                      <ColorSwatch color={toRGBA(s.gradientEndColor)} onChange={(c) => set({ gradientEndColor: toCodable(c, s.gradientEndColor) })} ariaLabel="End Color" />
                    </Row>
                  ),
                },
                {
                  key: "solid",
                  show: type === "Solid Color",
                  node: (
                    <Row label="Color">
                      <ColorSwatch color={toRGBA(s.solidColor)} onChange={(c) => set({ solidColor: toCodable(c, s.solidColor) })} ariaLabel="Color" />
                    </Row>
                  ),
                },
                {
                  key: "angle",
                  show: type === "Gradient",
                  node: (
                    <PillSlider
                      title="Angle"
                      // nil = the legacy corner-to-corner diagonal, shown as 135°.
                      value={s.gradientAngle ?? 135}
                      min={0}
                      max={360}
                      step={5}
                      format={degRounded}
                      onChange={(v) => set({ gradientAngle: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "choose",
                  show: type === "Image",
                  node: (
                    <Button variant="secondary" symbol="photo" onClick={actions?.onChooseBackgroundImage} style={{ alignSelf: "flex-start" }}>
                      Choose Image…
                    </Button>
                  ),
                },
                {
                  key: "images",
                  show: type === "Image",
                  attached: true,
                  node: (
                    <WallpaperGrid mode="images" items={libraryImages} selected={s.backgroundImagePath} onSelect={(p) => pick({ backgroundImagePath: p })} />
                  ),
                },
                {
                  key: "wallpapers",
                  show: type === "Wallpaper",
                  node: <WallpaperGrid mode="catalog" items={wallpapers} selected={s.backgroundImagePath} onSelect={(p) => pick({ backgroundImagePath: p })} />,
                },
                { key: "transparent", show: type === "Transparent", node: <Cap>No additional settings</Cap> },
              ]}
            />
          ),
        },
        {
          key: "look",
          show: type !== "Transparent",
          render: (first) => (
            <Box
              title="Look"
              first={first}
              rows={[
                { key: "blur", node: <PillSlider title="Blur" value={s.backgroundBlur} step={0.02} onChange={(v) => set({ backgroundBlur: v })} onCommit={commit} /> },
                { key: "pixelate", node: <PillSlider title="Pixelate" value={s.backgroundPixelate} step={0.02} onChange={(v) => set({ backgroundPixelate: v })} onCommit={commit} /> },
                { key: "halftone", node: <PillSlider title="Halftone" value={s.backgroundHalftone} step={0.02} onChange={(v) => set({ backgroundHalftone: v })} onCommit={commit} /> },
                { key: "grain", node: <PillSlider title="Grain" value={s.backgroundNoise} step={0.02} onChange={(v) => set({ backgroundNoise: v })} onCommit={commit} /> },
                {
                  key: "brightness",
                  node: (
                    <PillSlider
                      title="Brightness"
                      value={s.backgroundBrightness}
                      min={-1}
                      max={1}
                      step={0.02}
                      format={(v) => (v >= 0 ? `+${sInt(srounded(v * 100))}` : `${sInt(srounded(v * 100))}`)}
                      onChange={(v) => set({ backgroundBrightness: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "contrast",
                  node: <PillSlider title="Contrast" value={s.backgroundContrast} min={0.5} max={1.5} step={0.02} format={fixed(2, "×")} onChange={(v) => set({ backgroundContrast: v })} onCommit={commit} />,
                },
                {
                  key: "saturation",
                  node: <PillSlider title="Saturation" value={s.backgroundSaturation} min={0} max={2} step={0.05} format={fixed(2, "×")} onChange={(v) => set({ backgroundSaturation: v })} onCommit={commit} />,
                },
                {
                  key: "hue",
                  node: <PillSlider title="Hue" value={s.backgroundHue} min={0} max={360} step={5} format={degRounded} onChange={(v) => set({ backgroundHue: v })} onCommit={commit} />,
                },
                {
                  key: "tint",
                  node: (
                    <Row label="Tint">
                      <ColorSwatch
                        color={toRGBA(s.backgroundTintColor)}
                        onChange={(c) =>
                          // Picking a tint at zero strength would look like
                          // nothing happened — give it a visible amount.
                          set(
                            s.backgroundTintOpacity <= 0
                              ? { backgroundTintColor: toCodable(c, s.backgroundTintColor), backgroundTintOpacity: 0.3 }
                              : { backgroundTintColor: toCodable(c, s.backgroundTintColor) },
                          )
                        }
                        ariaLabel="Tint"
                      />
                    </Row>
                  ),
                },
                {
                  key: "tintAmount",
                  attached: true,
                  node: <PillSlider title="Tint Amount" value={s.backgroundTintOpacity} step={0.02} onChange={(v) => set({ backgroundTintOpacity: v })} onCommit={commit} />,
                },
                { key: "vignette", node: <PillSlider title="Vignette" value={s.backgroundVignette} step={0.02} onChange={(v) => set({ backgroundVignette: v })} onCommit={commit} /> },
                {
                  key: "reset",
                  show: !isPlainLook(s),
                  attached: true,
                  node: <RowButton onClick={() => pick(RESET_LOOK)}>Reset Look</RowButton>,
                },
              ]}
            />
          ),
        },
        {
          key: "frame",
          render: (first) => (
            <Box
              title="Frame"
              first={first}
              rows={[
                facts.isDeviceRecording && {
                  key: "device",
                  node: <ToggleRow label="iPhone / iPad Frame" checked={s.showDeviceFrame} onChange={(v) => pick({ showDeviceFrame: v })} />,
                },
                {
                  key: "placement",
                  node: (
                    <MenuRow
                      label="Placement"
                      options={PLACEMENTS}
                      selectedIndex={PLACEMENTS.indexOf(s.videoPlacement)}
                      overrideTitle={isCustom ? "Custom" : undefined}
                      // Picking an anchor drops any freeform drag position.
                      onSelect={(i) => pick({ videoPlacement: PLACEMENTS[i], videoCustomX: undefined, videoCustomY: undefined })}
                    />
                  ),
                },
                {
                  key: "pad",
                  attached: true,
                  node: (
                    <PlacementPad
                      placement={s.videoPlacement}
                      custom={isCustom ? { x: s.videoCustomX ?? 0.5, y: s.videoCustomY ?? 0.5 } : null}
                      padding={s.backgroundPadding}
                      onSelect={(p) => pick({ videoPlacement: p, videoCustomX: undefined, videoCustomY: undefined })}
                    />
                  ),
                },
                {
                  key: "resetPlacement",
                  show: isCustom,
                  attached: true,
                  node: (
                    <RowButton onClick={() => pick({ videoCustomX: undefined, videoCustomY: undefined, videoPlacement: "Center" })}>Reset to Center</RowButton>
                  ),
                },
                {
                  key: "padding",
                  node: <PillSlider title="Padding" value={s.backgroundPadding} min={0} max={300} step={4} onChange={(v) => set({ backgroundPadding: v })} onCommit={commit} />,
                },
                {
                  key: "shape",
                  node: <MenuRow label="Shape" options={SHAPES} selectedIndex={SHAPES.indexOf(s.frameShape)} onSelect={(i) => pick({ frameShape: SHAPES[i] })} />,
                },
                {
                  key: "corners",
                  node: (
                    <PillSlider
                      title="Rounded Corners"
                      value={s.windowCornerRadius}
                      min={0}
                      max={20}
                      step={1}
                      // One slider writes both radii (the SwiftUI pane's rule).
                      onChange={(v) => set({ windowCornerRadius: v, cornerRadius: v })}
                      onCommit={commit}
                    />
                  ),
                },
                { key: "shadow", node: <PillSlider title="Shadow" value={s.shadowRadius} min={0} max={60} step={2} onChange={(v) => set({ shadowRadius: v })} onCommit={commit} /> },
                {
                  key: "shadowOpacity",
                  node: <PillSlider title="Shadow Opacity" value={s.shadowOpacity} step={0.05} format={pctTrunc} onChange={(v) => set({ shadowOpacity: v })} onCommit={commit} />,
                },
                {
                  key: "framePad",
                  attached: true,
                  node: (
                    <PropertyPreviewPad mode={{ kind: "frameStyle", cornerRadius: s.windowCornerRadius, shadowRadius: s.shadowRadius, shadowOpacity: s.shadowOpacity }} />
                  ),
                },
              ]}
            />
          ),
        },
        facts.supportsMenuBar && {
          key: "menubar",
          render: (first) => (
            <Box
              title="Menu Bar"
              first={first}
              rows={[
                {
                  key: "chips",
                  node: (
                    <Chips
                      items={MENU_BAR_CHIPS}
                      selectedIndex={Math.max(0, MENU_BARS.indexOf(replacement))}
                      onSelect={(i) => pick({ menuBarReplacement: MENU_BARS[i] })}
                      ariaLabel="Menu bar"
                    />
                  ),
                },
                {
                  key: "title",
                  show: showsCustomBar,
                  node: (
                    <Row label="Title">
                      <InspectorField width={140} placeholder="App name" value={s.menuBarTitle} onChange={(e) => set({ menuBarTitle: e.target.value })} onBlur={commit} />
                    </Row>
                  ),
                },
                { key: "alignLabel", show: showsCustomBar, node: <div className="cc-label">Align</div> },
                {
                  key: "align",
                  show: showsCustomBar,
                  attached: true,
                  node: (
                    <Chips
                      items={ALIGNMENTS}
                      selectedIndex={Math.max(0, ALIGNMENTS.indexOf(s.menuBarTitleAlignment))}
                      onSelect={(i) => pick({ menuBarTitleAlignment: ALIGNMENTS[i] })}
                      ariaLabel="Title alignment"
                    />
                  ),
                },
                {
                  key: "clock",
                  show: showsCustomBar,
                  node: (
                    <Row label="Clock">
                      <InspectorField width={70} placeholder="9:41" value={s.menuBarClock} onChange={(e) => set({ menuBarClock: e.target.value })} onBlur={commit} />
                    </Row>
                  ),
                },
                {
                  key: "icons",
                  show: showsCustomBar,
                  node: <ToggleRow label="Wi-Fi & Battery Icons" checked={s.menuBarShowStatusIcons} onChange={(v) => pick({ menuBarShowStatusIcons: v })} />,
                },
                {
                  key: "height",
                  show: replacement !== "Original",
                  node: (
                    <PillSlider title="Height" value={s.menuBarHeight} min={2} max={6} step={0.1} format={fixed(1, "%")} onChange={(v) => set({ menuBarHeight: v })} onCommit={commit} />
                  ),
                },
                {
                  key: "caption",
                  attached: true,
                  node: (
                    <Cap>
                      {replacement === "Hidden"
                        ? "Crops the menu bar strip off the recording entirely — adjust Height until the bar is exactly gone."
                        : "Covers the recorded macOS menu bar with a clean bar — your own title, a fixed clock, no personal clutter. Adjust Height until it exactly hides the real bar."}
                    </Cap>
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
