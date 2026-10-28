/**
 * The timeline lanes' right-click menus, 1:1 with TimelineCanvasView.
 * rightMouseDown / effectBlockMenu / focusBlockMenu / videoContextMenu /
 * voiceContextMenu. The Mac's submenus (Zoom Level, Set/Change Speed) are
 * flattened into a SECTION of checked rows — the kit menu has no cascades.
 * Kit icons lead each row; Delete shows its key (⌫ — EditorShell's keydown).
 */
import type { MenuEntry } from "../kit";
import { formatSpeed, type ContextMenuRequest } from "../timeline/TimelineRenderer";
import type { TimelineAction } from "../timeline/types";

const SPEED_PRESETS = [0.5, 0.75, 1.2, 1.4, 1.6, 1.8, 2.0, 3.0, 4.0];
const ZOOM_LEVELS = [1.5, 2.0, 2.5, 3.0, 4.0, 5.0];

const DELETE_KEY = "⌫";

export function timelineMenu(req: ContextMenuRequest, act: (a: TimelineAction) => void): MenuEntry[] | null {
  const { lane, target, time } = req;

  if (lane === "video") {
    const s = req.segment;
    if (!s) return null;
    const entries: MenuEntry[] = [];
    if (s.regionId) {
      const regionId = s.regionId;
      entries.push({ section: "Change speed" });
      for (const level of SPEED_PRESETS) entries.push({ title: formatSpeed(level), onSelect: () => act({ type: "changeSpeed", regionId, speed: level }) });
      entries.push("separator");
      entries.push({ title: "Remove Speed", icon: "gauge", destructive: true, onSelect: () => act({ type: "removeSpeed", regionId }) });
    } else {
      entries.push({ section: "Set speed" });
      for (const level of SPEED_PRESETS) {
        entries.push({
          title: formatSpeed(level),
          onSelect: () => act({ type: "setSpeed", sourceStart: s.sourceStart, sourceEnd: s.sourceEnd, speed: level }),
        });
      }
    }
    if (s.startsAtSplit) {
      entries.push("separator");
      entries.push({ title: "Remove Split at Start", icon: "merge", destructive: true, onSelect: () => act({ type: "removeSplit", outputTime: s.outputStart }) });
    }
    return entries;
  }

  if (lane === "voice") {
    if (!target) return null;
    return [{ title: "Delete Voice Over", icon: "trash", shortcut: DELETE_KEY, destructive: true, onSelect: () => act({ type: "delete", target }) }];
  }

  if (target?.lane === "intro" || target?.lane === "curtain") {
    return [{ title: "Delete", icon: "trash", shortcut: DELETE_KEY, onSelect: () => act({ type: "delete", target }) }];
  }

  if (lane === "effects" && target?.lane === "effects") {
    const e = req.effect;
    const entries: MenuEntry[] = [];
    if (target.zoomId) {
      const zoomId = target.zoomId;
      entries.push({ section: "Zoom level" });
      for (const level of ZOOM_LEVELS) {
        entries.push({
          title: `${level.toFixed(1)}x`,
          checked: Math.abs((e?.zoomLevel ?? 0) - level) < 0.01,
          onSelect: () => act({ type: "setZoomLevel", zoomId, level }),
        });
      }
      entries.push("separator");
    }
    if (target.tiltId) {
      const tiltId = target.tiltId;
      entries.push({ title: "Remove Tilt", icon: "tilt", onSelect: () => act({ type: "removeTilt", tiltId }) });
    } else if (target.zoomId) {
      const zoomId = target.zoomId;
      entries.push({ title: "Add Tilt to Block", icon: "tilt", onSelect: () => act({ type: "addTiltToBlock", zoomId }) });
    }
    if (target.zoomId) {
      const zoomId = target.zoomId;
      entries.push({ title: "Remove Zoom", icon: "zoom-out", onSelect: () => act({ type: "removeZoom", zoomId }) });
    } else if (target.tiltId) {
      const tiltId = target.tiltId;
      entries.push({ title: "Add Zoom to Block", icon: "zoom-in", onSelect: () => act({ type: "addZoomToBlock", tiltId }) });
    }
    entries.push("separator");
    entries.push({ title: "Delete", icon: "trash", shortcut: DELETE_KEY, onSelect: () => act({ type: "delete", target }) });
    return entries;
  }

  if (lane === "focus" && target?.lane === "focus") {
    const entries: MenuEntry[] = [];
    if (!target.isHighlight) {
      entries.push({ title: "Rename…", icon: "pencil", disabled: true });
      entries.push("separator");
    }
    entries.push({ title: "Delete", icon: "trash", shortcut: DELETE_KEY, onSelect: () => act({ type: "delete", target }) });
    return entries;
  }

  if (lane === "annotate" && target?.lane === "annotate") {
    return [{ title: "Delete", icon: "trash", shortcut: DELETE_KEY, onSelect: () => act({ type: "delete", target }) }];
  }

  if (lane === "annotate") {
    const add = (title: string, icon: string, annotation: Extract<TimelineAction, { type: "addAnnotationAt" }>["annotation"]): MenuEntry => ({
      title,
      icon,
      onSelect: () => act({ type: "addAnnotationAt", time, annotation }),
    });
    return [
      add("Add Text Label", "text-bubble", "text"),
      add("Add Arrow", "arrow-up-right", "arrow"),
      add("Add Callout", "pencil", "callout"),
      add("Add Drawing", "draw", "drawing"),
      add("Add Rectangle", "rectangle", "rectangle"),
      add("Add Ellipse", "ellipse", "ellipse"),
      add("Add Tap Indicator", "tap", "tap"),
    ];
  }
  if (lane === "effects") {
    return [
      { title: "Add Zoom Region", icon: "zoom-in", onSelect: () => act({ type: "addZoomAt", time }) },
      { title: "Add Tilt Region", icon: "tilt", onSelect: () => act({ type: "addTiltAt", time }) },
    ];
  }
  if (lane === "focus") {
    return [
      { title: "Add Highlight", icon: "highlighter", onSelect: () => act({ type: "addHighlightAt", time }) },
      { title: "Add Blur", icon: "eye-off", onSelect: () => act({ type: "addBlurAt", time }) },
    ];
  }
  return null;
}
