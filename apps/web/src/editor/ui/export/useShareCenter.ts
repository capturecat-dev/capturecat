/**
 * The editor page's share job (state/shareCenter.ts), wired to the open
 * project: the top-bar Share exports an MP4 with the project's own export
 * settings (the Mac's HeadlessRunner export behind a card's "Share…" — a
 * movie whatever the saved format) through the engine, then uploads it.
 */
import { useEffect, useRef, useState } from "react";

import type { EditorController } from "../../state/controller";
import { ShareCenter } from "../../state/shareCenter";
import type { EditorStore } from "../../state/store";
import { exportProject, sheetSettingsFromDoc } from "./exportProject";

export function useShareCenter(
  store: EditorStore,
  controller: EditorController,
  sourceSize: { width: number; height: number } | null,
): ShareCenter {
  const size = useRef(sourceSize);
  size.current = sourceSize;
  const [center] = useState(
    () =>
      new ShareCenter({
        project: () => store.getState().project,
        exportMovie: async (onProgress, signal) => {
          const client = controller.client;
          const source = size.current;
          if (!client || !source) throw new Error("The editor is still loading this project.");
          const doc = store.documentJSON() as Record<string, unknown>;
          const settings = doc.settings as Record<string, unknown> | undefined;
          const result = await exportProject(
            client,
            {
              settings: { ...sheetSettingsFromDoc(doc), format: "MP4" },
              aspectRatio: typeof settings?.aspectRatio === "string" ? settings.aspectRatio : "Auto",
              sourceSize: source,
              projectName: typeof doc.name === "string" ? doc.name : "Untitled",
              delivery: "none",
              signal,
            },
            onProgress,
          );
          return { blob: result.blob, fileName: result.fileName };
        },
      }),
  );
  // The top-bar Share (EditorShellCallbacks.onShare → ControllerHooks.share).
  useEffect(() => {
    controller.hooks.share = () => void center.shareProject();
    return () => {
      controller.hooks.share = undefined;
    };
  }, [controller, center]);
  return center;
}
