/**
 * The replacement menu bar — port of apps/macos/CaptureCat/Services/
 * MenuBarRenderer.swift `image(for:)` (19-116) as LAYOUT NUMBERS, plus the
 * exporter's use of it (VideoExporter.export 386-395 menu-bar crop, 987-1010
 * cached bar placement, 1722 hidden during device segments).
 *
 * Golden-vector units (verbatim oracles): `menuBarLayout`,
 * `menuBarTextMetrics`, `menuBarExportPlacement`; the hide-during-device-
 * segment rule is in `deviceSegmentExport` (`menuBarVisible`).
 *
 * ## Text is NOT ported — it is measured
 * Swift measures with AppKit (`NSAttributedString.size()` in the system font,
 * `.AppleSystemUIFont` = SF Pro; SF Symbols "battery.100" / "wifi" at
 * `pointSize: fontSize × 0.95, weight: .medium`). Positions depend on those
 * measurements, so `menuBarLayout` takes them as input (`MenuBarMeasured`).
 * The web must measure with the same faces: clock = system font weight 500
 * (medium) at `fontSize`; title = weight 700 (bold) at `fontSize`; logo =
 * "\u{F8FF}" (Apple logo, private-use glyph of SF — absent from non-Apple
 * fonts: substitute an SVG of the same measured box) at `fontSize × 1.05`
 * regular; icons = SF-Symbol-equivalent SVGs sized to the measured symbol
 * boxes. `menuBarTextMetrics` records AppKit's measurements (and font
 * metrics) per bar height as the calibration table for the browser.
 * Text is drawn with its box's origin at the returned rect (NSImage y-up
 * space, origin bottom-left; every element is vertically centred, so the
 * Y-down rect is `{x, y: height − y − h}` = the same centred value).
 *
 * ## Colours
 * The bar fill is `NSColor(calibratedRed:…)` — GENERIC (calibrated) RGB,
 * not sRGB. The sRGB values below are AppKit's own conversion
 * (`usingColorSpace(.sRGB)`), recorded by the vectors; draw with those.
 */
import type { MenuBarReplacement, MenuBarTitleAlignment, RecordingSourceKind } from "../model/enums";
import type { ProjectSettings, Rect, Size } from "../model/types";
import { maxY, minX, rectHeight, rectWidth } from "./geometry";
import type { SRGBA } from "./regionsSupport";
import { sInt, smax, smin, srounded } from "./swift";

/** `MenuBarRenderer.Spec`. */
export interface MenuBarSpec {
  style: MenuBarReplacement;
  title: string;
  titleAlignment: MenuBarTitleAlignment;
  showStatusIcons: boolean;
  clock: string;
  /** Swift `Int` (pixels/points of the raster). */
  width: number;
  /** Swift `Int`. */
  height: number;
}

/** `image(for:)` returns nil unless dark/light and both sides > 4. */
export function menuBarRenders(spec: MenuBarSpec): boolean {
  return (spec.style === "Clean Dark" || spec.style === "Clean Light") && spec.width > 4 && spec.height > 4;
}

/** Calibrated (Generic RGB) components as written in Swift. */
export const barColorCalibrated = {
  dark: { red: 0.11, green: 0.11, blue: 0.12, alpha: 1 },
  light: { red: 0.96, green: 0.96, blue: 0.97, alpha: 1 },
} as const;

/** AppKit's sRGB conversion of the calibrated bar colours (recorded by the
 * `menuBarLayout` vectors on macOS 26; locked by the suite). */
export const barColorSRGB: { dark: SRGBA; light: SRGBA } = {
  dark: { red: 0.14652875065803528, green: 0.1469733715057373, blue: 0.16014054417610168, alpha: 1 },
  light: { red: 0.9681995511054993, green: 0.9684506058692932, blue: 0.9761977791786194, alpha: 1 },
};

/** `NSColor.white` / `NSColor.black`. */
export function textColorSRGB(style: MenuBarReplacement): SRGBA {
  return style === "Clean Dark"
    ? { red: 1, green: 1, blue: 1, alpha: 1 }
    : { red: 0, green: 0, blue: 0, alpha: 1 };
}

/** The font requests for a bar of `height` (points of the raster). */
export function menuBarFonts(height: number): {
  fontSize: number;
  pad: number;
  clock: { size: number; weight: 500 };
  title: { size: number; weight: 700 };
  logo: { size: number; weight: 400 };
  symbolPointSize: number;
} {
  const fontSize = height * 0.52;
  return {
    fontSize,
    pad: height * 0.55,
    clock: { size: fontSize, weight: 500 },
    title: { size: fontSize, weight: 700 },
    logo: { size: fontSize * 1.05, weight: 400 },
    symbolPointSize: fontSize * 0.95,
  };
}

/** AppKit measurements the layout depends on (see module doc). */
export interface MenuBarMeasured {
  /** Clock string box (null when the clock is empty). */
  clock: Size | null;
  /** Status symbols actually available, in draw order (battery.100, wifi). */
  symbols: { name: string; size: Size }[];
  /** Apple-logo glyph box. */
  logo: Size;
  /** Title box (null when the title is empty). */
  title: Size | null;
}

export interface MenuBarLayout {
  fontSize: number;
  pad: number;
  clock: Rect | null;
  icons: { name: string; rect: Rect }[];
  logo: Rect;
  title: Rect | null;
  /** The right cursor after the clock + icons (where a right-aligned title ends). */
  finalRightX: number;
}

/**
 * Element boxes inside the `width × height` bar image (NSImage y-up space —
 * see module doc), exactly as `image(for:)` lays them out. Null when the
 * renderer would return nil.
 */
export function menuBarLayout(spec: MenuBarSpec, measured: MenuBarMeasured): MenuBarLayout | null {
  if (!menuBarRenders(spec)) return null;
  const rectW = spec.width;
  const rectH = spec.height;
  const h = spec.height;
  const fontSize = h * 0.52;
  const pad = h * 0.55;

  // Right side first (clock, then optional status glyphs).
  let rightX = rectW - pad;
  let clock: Rect | null = null;
  if (spec.clock.length > 0 && measured.clock) {
    const s = measured.clock;
    rightX -= s.width;
    clock = { x: rightX, y: (rectH - s.height) / 2, width: s.width, height: s.height };
    rightX -= fontSize * 0.9;
  }
  const icons: { name: string; rect: Rect }[] = [];
  if (spec.showStatusIcons) {
    for (const sym of measured.symbols) {
      rightX -= sym.size.width;
      icons.push({
        name: sym.name,
        rect: { x: rightX, y: (rectH - sym.size.height) / 2, width: sym.size.width, height: sym.size.height },
      });
      rightX -= fontSize * 0.7;
    }
  }

  //  logo anchored left; the title goes where the user says.
  let x = pad;
  const logo: Rect = {
    x,
    y: (rectH - measured.logo.height) / 2,
    width: measured.logo.width,
    height: measured.logo.height,
  };
  x += measured.logo.width + fontSize * 0.7;

  let title: Rect | null = null;
  if (spec.title.length > 0 && measured.title) {
    const s = measured.title;
    let titleX: number;
    switch (spec.titleAlignment) {
      case "Left":
        titleX = x;
        break;
      case "Center":
        titleX = (rectW - s.width) / 2;
        break;
      case "Right":
        titleX = rightX - s.width;
        break;
    }
    title = { x: titleX, y: (rectH - s.height) / 2, width: s.width, height: s.height };
  }
  return { fontSize, pad, clock, icons, logo, title, finalRightX: rightX };
}

// ── Exporter use (VideoExporter.export) ─────────────────────────────────────

type MenuBarSettings = Pick<
  ProjectSettings,
  | "menuBarReplacement"
  | "menuBarHeight"
  | "menuBarTitle"
  | "menuBarClock"
  | "menuBarShowStatusIcons"
  | "menuBarTitleAlignment"
  | "showDeviceFrame"
>;

/**
 * Hidden-menu-bar crop (386-391): the fraction of the SOURCE's top strip
 * removed for "Hidden" on non-device takes (layout then uses
 * `effectiveNaturalSize`, and cursor y shifts up by
 * `cursorCoordinateHeight × crop`).
 */
export function menuBarCrop(
  settings: Pick<ProjectSettings, "menuBarReplacement" | "menuBarHeight">,
  recordingSourceKind: RecordingSourceKind,
  sourceSegmentKinds: readonly RecordingSourceKind[],
): number {
  if (
    !(
      settings.menuBarReplacement === "Hidden" &&
      recordingSourceKind !== "device" &&
      !sourceSegmentKinds.some((k) => k === "device")
    )
  ) {
    return 0;
  }
  return smin(0.12, smax(0, settings.menuBarHeight / 100));
}

/** `effectiveNaturalSize` (392-395). */
export function effectiveNaturalSize(naturalSize: Size, crop: number): Size {
  return { width: naturalSize.width, height: naturalSize.height * (1 - crop) };
}

/** The exporter's bar: spec (raster size) + CI placement over the video's top strip. */
export interface MenuBarExportPlacement {
  barH: number;
  spec: MenuBarSpec;
  /** CI Y-UP origin of the scaled raster: (vr.minX, vr.maxY − barH). */
  origin: { x: number; y: number };
}

/**
 * `cachedMenuBar` (987-1010): null when not dark/light or the whole take is a
 * framed device recording. The raster (`spec.width × spec.height`, possibly
 * rasterized at a backing scale k) is scaled by (vr.width / max(1, rasterW),
 * barH / max(1, rasterH)) — i.e. stretched onto the exact rect
 * (vr.minX, vr.maxY − barH, vr.width, barH) in CI Y-UP (the video's top
 * strip). `exportMenuBarRasterScale` gives those factors.
 */
export function exportMenuBarPlacement(
  settings: MenuBarSettings,
  recordingSourceKind: RecordingSourceKind,
  videoRect: Rect,
): MenuBarExportPlacement | null {
  const deviceFrameActive = recordingSourceKind === "device" && settings.showDeviceFrame;
  if (!((settings.menuBarReplacement === "Clean Dark" || settings.menuBarReplacement === "Clean Light") && !deviceFrameActive)) {
    return null;
  }
  const vr = videoRect;
  const barH = smax(4, (rectHeight(vr) * settings.menuBarHeight) / 100);
  const spec: MenuBarSpec = {
    style: settings.menuBarReplacement,
    title: settings.menuBarTitle,
    titleAlignment: settings.menuBarTitleAlignment,
    showStatusIcons: settings.menuBarShowStatusIcons,
    clock: settings.menuBarClock,
    width: sInt(srounded(rectWidth(vr))),
    height: sInt(srounded(barH)),
  };
  return { barH, spec, origin: { x: minX(vr), y: maxY(vr) - barH } };
}

/** The CI scale applied to a `raster` of the bar image (1003-1005). */
export function exportMenuBarRasterScale(videoRect: Rect, barH: number, raster: Size): Size {
  return { width: rectWidth(videoRect) / smax(1, raster.width), height: barH / smax(1, raster.height) };
}
