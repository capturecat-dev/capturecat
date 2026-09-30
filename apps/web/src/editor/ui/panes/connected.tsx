/**
 * Store-connected inspector panes. The panes themselves stay pure (settings
 * in, patches out); this binds all nine to the editor store in one call:
 *
 *   const panes = useInspectorPanes(store, { onAction: (a) => controller.timelineAction(a) });
 *   <EditorShell … panes={panes} />
 *
 * `PaneStore` is the slice of `state/store.ts` EditorStore the panes use,
 * typed structurally so this module does not depend on the store's file:
 * reads go through getState/subscribe (useSyncExternalStore — the same as
 * `useEditorStore`), writes through updateSettings / updateRegion /
 * updateProject, and slider/drag release calls endCoalescing (one undo step
 * per gesture).
 */
import { useCallback, useMemo, useSyncExternalStore, type ReactNode } from "react";

import type { Project, ProjectSettings } from "../../core/model";
import type { InspectorTabId } from "../shell/types";
import type { TimelineAction } from "../timeline/types";
import { inspectorPanes } from "./inspectorPanes";
import type { PaneActions, PaneFacts, PaneProps, PaneSelection, ProjectPatch, RegionKind } from "./types";

export interface PaneStore {
  getState(): { project: Project | null; selection: PaneSelection };
  subscribe(listener: () => void): () => void;
  updateSettings(patch: Partial<ProjectSettings>, label?: string): void;
  updateRegion(kind: RegionKind, id: string, patch: object): void;
  updateProject(patch: ProjectPatch, label?: string): void;
  endCoalescing(): void;
  /** The playhead in SOURCE seconds (EditorStore.playheadSource). */
  playheadSource?(): number;
}

export interface InspectorPaneOptions {
  /** EditorController.timelineAction — add/remove zoom & tilt, delete regions. */
  onAction?(action: TimelineAction): void;
  /** Extra side effects (logo/image pickers, transcription, test sounds…). */
  actions?: Partial<PaneActions>;
  /** Recording facts the project alone can't tell (e.g. keys.json shortcuts). */
  facts?: Partial<PaneFacts>;
}

export function useInspectorPanes(store: PaneStore, opts: InspectorPaneOptions = {}): Partial<Record<InspectorTabId, ReactNode>> {
  const project = useSyncExternalStore(store.subscribe, () => store.getState().project, () => store.getState().project);
  const selection = useSyncExternalStore(store.subscribe, () => store.getState().selection, () => store.getState().selection);
  const onSettingsChange = useCallback((patch: Partial<ProjectSettings>) => store.updateSettings(patch), [store]);
  const onRegionChange = useCallback<NonNullable<PaneProps["onRegionChange"]>>((kind, id, patch) => store.updateRegion(kind, id, patch), [store]);
  const onProjectChange = useCallback((patch: ProjectPatch) => store.updateProject(patch), [store]);
  const onCommit = useCallback(() => store.endCoalescing(), [store]);
  const { onAction, actions, facts } = opts;
  return useMemo(() => {
    if (!project) return {};
    return inspectorPanes({
      settings: project.settings,
      onSettingsChange,
      onCommit,
      selection,
      project,
      onRegionChange,
      onProjectChange,
      facts,
      actions: {
        onAction,
        playheadTime: store.playheadSource ? () => store.playheadSource!() : undefined,
        ...actions,
      },
    });
  }, [project, selection, store, onSettingsChange, onRegionChange, onProjectChange, onCommit, onAction, actions, facts]);
}
