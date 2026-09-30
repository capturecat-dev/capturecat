/**
 * The nine inspector panes (1:1 with Views/Editor/InspectorKit/*PaneAppKit).
 *
 * Mount, store-connected (EditorPage):
 *   const panes = useInspectorPanes(store, { onAction: (a) => controller.timelineAction(a) });
 *   <EditorShell … panes={panes} />
 *
 * Or pure (any host): `inspectorPanes({ settings, onSettingsChange, … })`.
 */
export { AnnotatePane } from "./AnnotatePane";
export { AudioPane } from "./AudioPane";
export { BackgroundPane, isPlainLook } from "./BackgroundPane";
export { BrandPane } from "./BrandPane";
export { CameraPane } from "./CameraPane";
export { CursorPane } from "./CursorPane";
export { EffectsPane } from "./EffectsPane";
export { MotionPane } from "./MotionPane";
export { SubtitlesPane } from "./SubtitlesPane";
export { inspectorPanes } from "./inspectorPanes";
export { useInspectorPanes, type InspectorPaneOptions, type PaneStore } from "./connected";
export type { WallpaperItem } from "./pads";
export * from "./types";
