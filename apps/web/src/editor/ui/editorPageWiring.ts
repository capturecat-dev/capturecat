/**
 * EditorPage glue that is not the page's own layout — each piece is the web
 * twin of one EditorShellViewController / InspectorColumnAppKit duty, kept
 * here so the page itself only makes the calls:
 *
 *   editorPaneActions      — the Motion/Cursor pane context closures
 *                            (add block at playhead + beep, join slide,
 *                            click/key sound previews);
 *   useRecordingFacts      — `hasShortcutData` from keys.json;
 *   useInspectorRevealKey  — a selection re-shows a collapsed inspector;
 *   usePendingSeek         — `?t=` consumed once the project is loaded;
 *   REPLACE_ZOOM_BLOCKS    — the Motion regenerate confirm (CCAlert copy).
 */
import { useEffect, useMemo, useRef, useState } from "react";

import type { Project } from "../core/model";
import type { EditorController } from "../state/controller";
import { addTiltBlockAtPlayhead, addZoomBlockAtPlayhead, joinSlideToSelectedBlock } from "../state/inspectorEdits";
import { revealsInspector } from "../state/inspectorReveal";
import { pendingSeekOutputTime } from "../state/pendingSeek";
import { loadHasShortcutData } from "../state/recordingFacts";
import type { EditorStore } from "../state/store";
import type { AlertSpec } from "./kit/Alert";
import { systemBeep } from "./kit/uiAudio";
import { soundPreview } from "./panes/soundPreview";
import type { PaneActions, PaneFacts } from "./panes/types";

/** The Motion + Cursor pane closures the Mac builds in InspectorPaneContexts / CursorSettingsPaneAppKit. */
export function editorPaneActions(controller: EditorController, beep: () => void = systemBeep): Partial<PaneActions> {
  return {
    onAddZoomBlockAtPlayhead: () => {
      if (!controller.apply(addZoomBlockAtPlayhead)) beep();
    },
    onAddTiltBlockAtPlayhead: () => {
      if (!controller.apply(addTiltBlockAtPlayhead)) beep();
    },
    onJoinSlideToSelectedBlock: () => controller.apply(joinSlideToSelectedBlock) != null,
    onPlayClickSound: (style, volume, opts) => (opts?.preview ? soundPreview.clickPreview(style, volume) : soundPreview.click(style, volume)),
    onPlayKeySound: (style, volume) => soundPreview.keyBurst(style, volume),
  };
}

/** Recording facts only the sidecars know (InspectorColumnAppKit's keys.json read). */
export function useRecordingFacts(
  project: Pick<Project, "keystrokeDataURL"> | null | undefined,
  media: { mediaUrl(ref: string | null | undefined): string | undefined } | null | undefined,
): Partial<PaneFacts> {
  const ref = project?.keystrokeDataURL ?? null;
  const [known, setKnown] = useState<{ ref: string | null; has: boolean }>({ ref: null, has: false });
  useEffect(() => {
    if (!ref || !media) return;
    let alive = true;
    void loadHasShortcutData({ keystrokeDataURL: ref }, (r) => media.mediaUrl(r)).then((has) => {
      if (alive) setKnown({ ref, has });
    });
    return () => {
      alive = false;
    };
  }, [ref, media]);
  const hasShortcutData = ref != null && known.ref === ref && known.has;
  return useMemo(() => ({ hasShortcutData }), [hasShortcutData]);
}

/** Bumps whenever a selection should re-show the inspector (`showInspector = true`). */
export function useInspectorRevealKey(store: EditorStore): number {
  const [key, setKey] = useState(0);
  useEffect(() => {
    let prev = store.getState().selection;
    return store.subscribe(() => {
      const next = store.getState().selection;
      if (next === prev) return;
      const reveal = revealsInspector(prev, next);
      prev = next;
      if (reveal) setKey((k) => k + 1);
    });
  }, [store]);
  return key;
}

/**
 * `?t=` (output seconds), consumed ONCE per value: when the engine has
 * loaded (the Mac hands it to `setupPlayer(initialTime:)` — a seek racing
 * the load gets re-anchored to the start), or later, when the link changes
 * under an already-open editor (`consumeLatePendingSeek`).
 */
export function usePendingSeek(
  store: EditorStore,
  controller: EditorController,
  engineReady: boolean,
  t: number | null | undefined,
  key = "",
): void {
  const consumed = useRef<string | null>(null);
  useEffect(() => {
    if (t == null) {
      consumed.current = null;
      return;
    }
    const id = `${key}|${t}`;
    if (!engineReady || consumed.current === id) return;
    const project = store.getState().project;
    if (!project) return;
    consumed.current = id;
    controller.seek(pendingSeekOutputTime(project, t));
  }, [engineReady, t, key, store, controller]);
}

/** TimelineViewController.stillMotion's confirm (CCAlert), verbatim. */
export const REPLACE_ZOOM_BLOCKS: AlertSpec = {
  title: "Replace Zoom Blocks?",
  message: "Motion generates a new camera journey. Previously generated blocks will be replaced.",
  buttons: [{ title: "Generate", role: "primary" }, { title: "Cancel" }],
};
