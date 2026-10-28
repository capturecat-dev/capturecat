/**
 * CCKit for the web editor — the Mac-accurate control kit.
 *
 * Tokens: tokens.css (capDark/capLight), materials: materials.css
 * (CCMaterial), motion: motion.ts (CCMotion), icons: ccIcon.tsx (the
 * CaptureCat icon kit, generated from apps/macos/IconKit/icons.json) with icons.tsx's
 * SF → lucide table as the fallback. The marketing pages never import this;
 * the dashboard imports ccIcon.tsx alone (no lucide table) for the kit icons.
 */
export { ThemeRoot, useCCTheme, readCanvasTokens, parseColor, rgbaString, blend } from "./theme";
export type { ThemeMode, ResolvedTheme, CanvasTokens, RGBA } from "./theme";
export * from "./motion";
export { SFIcon, SF_SYMBOLS, canvasGlyph } from "./icons";
export { CCIcon, ccKitName } from "./ccIcon";
export type { CCIconWeight } from "./ccIcon";
export { Button, IconKey, QuietButton, InspectorButton, ToolbarSeparator } from "./Button";
export type { ButtonProps, ButtonVariant, ButtonSize } from "./Button";
export { Chips, Toggle, ToggleRow, Segmented } from "./Controls";
export { PillSlider, RailSlider, defaultPercent } from "./Sliders";
export { Floating, GlideWash, useGlide, rectOf, markPicked } from "./Floating";
export type { AnchorRect, Edge, GlideController } from "./Floating";
export { MenuList, MenuIcon, Select, ContextMenu, Popover } from "./Menu";
export { AlertHost, AlertPresenter } from "./Alert";
export type { AlertButton, AlertButtonRole, AlertSpec } from "./Alert";
export { Callout } from "./Callout";
export type { CalloutVariant } from "./Callout";
export type { MenuEntry, MenuItem, MenuSection, SelectOption } from "./Menu";
export {
  ColorPicker,
  ColorSwatch,
  TextField,
  InspectorField,
  Reveal,
  Pane,
  Section,
  Attached,
  Row,
  Caption,
  Divider,
  PreviewPad,
  colorCss,
  colorToHex,
  hexToColor,
} from "./Fields";
export type { RGBAColor } from "./Fields";
