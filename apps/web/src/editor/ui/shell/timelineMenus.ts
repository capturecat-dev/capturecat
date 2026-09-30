/**
 * The timeline lanes' right-click menus, 1:1 with TimelineCanvasView.
 * rightMouseDown / effectBlockMenu / focusBlockMenu / videoContextMenu /
 * voiceContextMenu. Submenus (Zoom Level, Set/Change Speed) are flattened
 * into checked rows under a separator — the kit menu has no cascades.
 */
import type { MenuEntry } from "../kit";
import { formatSpeed, type ContextMenuRequest } from "../timeline/TimelineRenderer";
import type { TimelineAction } from "../timeline/types";

const SPEED_PRESETS = [0.5, 0.75, 1.2, 1.4, 1.6, 1.8, 2.0, 3.0, 4.0];
const ZOOM_LEVELS = [1.5, 2.0, 2.5, 3.0, 4.0, 5.0];

export function timelineMenu(req: ContextMenuRequest, act: (a: TimelineAction) => void): MenuEntry[] | null {
  const { lane, target, time } = req;

  if (lane === "video") {
    const s = req.segment;
    if (!s) return null;
    const entries: MenuEntry[] = [];
    if (s.regionId) {
      const regionId = s.regionId;
      entries.push({ title: "Change Speed", disabled: true });
      for (const level of SPEED_PRESETS) entries.push({ title: `   ${formatSpeed(level)}`, onSelect: () => act({ type: "changeSpeed", regionId, speed: level }) });
      entries.push("separator");
      entries.push({ title: "Remove Speed", destructive: true, onSelect: () => act({ type: "removeSpeed", regionId }) });
    } else {
      entries.push({ title: "Set Speed", disabled: true });
      for (const level of SPEED_PRESETS) {
        entries.push({
          title: `   ${formatSpeed(level)}`,
          onSelect: () => act({ type: "setSpeed", sourceStart: s.sourceStart, sourceEnd: s.sourceEnd, speed: level }),
        });
      }
    }
    if (s.startsAtSplit) {
      entries.push("separator");
      entries.push({ title: "Remove Split at Start", destructive: true, onSelect: () => act({ type: "removeSplit", outputTime: s.outputStart }) });
    }
    return entries;
  }

  if (lane === "voice") {
    if (!target) return null;
    return [{ title: "Delete Voice Over", destructive: true, onSelect: () => act({ type: "delete", target }) }];
  }

  if (target?.lane === "intro" || target?.lane === "curtain") {
    return [{ title: "Delete", onSelect: () => act({ type: "delete", target }) }];
  }

  if (lane === "effects" && target?.lane === "effects") {
    const e = req.effect;
    const entries: MenuEntry[] = [];
    if (target.zoomId) {
      const zoomId = target.zoomId;
      entries.push({ title: "Zoom Level", disabled: true });
      for (const level of ZOOM_LEVELS) {
        entries.push({
          title: `   ${level.toFixed(1)}x`,
          checked: Math.abs((e?.zoomLevel ?? 0) - level) < 0.01,
          onSelect: () => act({ type: "setZoomLevel", zoomId, level }),
        });
      }
      entries.push("separator");
    }
    if (target.tiltId) {
      const tiltId = target.tiltId;
      entries.push({ title: "Remove Tilt", onSelect: () => act({ type: "removeTilt", tiltId }) });
    } else if (target.zoomId) {
      const zoomId = target.zoomId;
      entries.push({ title: "Add Tilt to Block", onSelect: () => act({ type: "addTiltToBlock", zoomId }) });
    }
    if (target.zoomId) {
      const zoomId = target.zoomId;
      entries.push({ title: "Remove Zoom", onSelect: () => act({ type: "removeZoom", zoomId }) });
    } else if (target.tiltId) {
      const tiltId = target.tiltId;
      entries.push({ title: "Add Zoom to Block", onSelect: () => act({ type: "addZoomToBlock", tiltId }) });
    }
    entries.push("separator");
    entries.push({ title: "Delete", onSelect: () => act({ type: "delete", target }) });
    return entries;
  }

  if (lane === "focus" && target?.lane === "focus") {
    const entries: MenuEntry[] = [];
    if (!target.isHighlight) {
      entries.push({ title: "Rename...", disabled: true });
      entries.push("separator");
    }
    entries.push({ title: "Delete", onSelect: () => act({ type: "delete", target }) });
    return entries;
  }

  if (lane === "annotate" && target?.lane === "annotate") {
    return [{ title: "Delete", onSelect: () => act({ type: "delete", target }) }];
  }

  if (lane === "annotate") {
    const add = (title: string, annotation: Extract<TimelineAction, { type: "addAnnotationAt" }>["annotation"]): MenuEntry => ({
      title,
      onSelect: () => act({ type: "addAnnotationAt", time, annotation }),
    });
    return [
      add("Add Text Label", "text"),
      add("Add Arrow", "arrow"),
      add("Add Callout", "callout"),
      add("Add Drawing", "drawing"),
      add("Add Rectangle", "rectangle"),
      add("Add Ellipse", "ellipse"),
      add("Add Tap Indicator", "tap"),
    ];
  }
  if (lane === "effects") {
    return [
      { title: "Add Zoom Region", onSelect: () => act({ type: "addZoomAt", time }) },
      { title: "Add Tilt Region", onSelect: () => act({ type: "addTiltAt", time }) },
    ];
  }
  if (lane === "focus") {
    return [
      { title: "Add Highlight", onSelect: () => act({ type: "addHighlightAt", time }) },
      { title: "Add Blur", onSelect: () => act({ type: "addBlurAt", time }) },
    ];
  }
  return null;
}
