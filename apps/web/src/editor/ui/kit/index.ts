/**
 * CCKit for the web editor — the Mac-accurate control kit.
 *
 * Tokens: tokens.css (capDark/capLight), materials: materials.css
 * (CCMaterial), motion: motion.ts (CCMotion), icons: icons.tsx (the SF
 * Symbol → lucide table). The marketing/dashboard pages never import this;
 * the editor never imports theirs.
 */
export { ThemeRoot, useCCTheme, readCanvasTokens, parseColor, rgbaString, blend } from "./theme";
export type { ThemeMode, ResolvedTheme, CanvasTokens, RGBA } from "./theme";
export * from "./motion";
export { SFIcon, SF_SYMBOLS, canvasGlyph } from "./icons";
export { Button, IconKey, QuietButton, InspectorButton, ToolbarSeparator } from "./Button";
export type { ButtonProps, ButtonVariant, ButtonSize } from "./Button";
export { Chips, Toggle, ToggleRow, Segmented } from "./Controls";
export { PillSlider, RailSlider, defaultPercent } from "./Sliders";
export { Floating, GlideWash, useGlide, rectOf } from "./Floating";
export type { AnchorRect, Edge, GlideController } from "./Floating";
export { MenuList, Select, ContextMenu, Popover } from "./Menu";
export type { MenuEntry, MenuItem, SelectOption } from "./Menu";
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
