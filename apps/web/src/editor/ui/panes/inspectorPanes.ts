/**
 * One call → the nine panes keyed by inspector tab. Tab → pane follows
 * InspectorColumnAppKit: the "Effects" tab hosts the Mac MotionSettingsPane
 * (effects list + selected block / region), the "Motion" tab MotionFeel.
 */
import { createElement, type ReactNode } from "react";

import type { InspectorTabId } from "../shell/types";
import { AnnotatePane } from "./AnnotatePane";
import { AudioPane } from "./AudioPane";
import { BackgroundPane } from "./BackgroundPane";
import { BrandPane } from "./BrandPane";
import { CameraPane } from "./CameraPane";
import { CursorPane } from "./CursorPane";
import { EffectsPane } from "./EffectsPane";
import { MotionPane } from "./MotionPane";
import { SubtitlesPane } from "./SubtitlesPane";
import type { PaneProps } from "./types";

export function inspectorPanes(props: PaneProps): Record<InspectorTabId, ReactNode> {
  return {
    background: createElement(BackgroundPane, props),
    cursor: createElement(CursorPane, props),
    camera: createElement(CameraPane, props),
    audio: createElement(AudioPane, props),
    effects: createElement(EffectsPane, props),
    motion: createElement(MotionPane, props),
    subtitles: createElement(SubtitlesPane, props),
    brand: createElement(BrandPane, props),
    annotations: createElement(AnnotatePane, props),
  };
}
