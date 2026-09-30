/**
 * The editor's top bar (EditorToolbarController + HeaderChromeView):
 *   [⌗ Captures] [title] …[Image|Video │ 16:9]… [sync] [Share] [Export…] [◧]
 * The centre cluster is centred on the bar; flat CCKit chrome only (the Mac
 * bar deliberately avoids system glass — so does the web).
 */
import { useState, type ReactNode } from "react";

import { Button, Segmented, Select, SFIcon, TextField } from "../kit";
import { ASPECT_RATIOS, type EditorShellCallbacks, type ShellProjectInfo, type SyncState } from "./types";

const SYNC_COPY: Record<SyncState, { icon: string; label: string }> = {
  saved: { icon: "checkmark.icloud", label: "Saved" },
  saving: { icon: "arrow.triangle.2.circlepath", label: "Saving…" },
  offline: { icon: "icloud.slash", label: "Offline" },
  conflict: { icon: "exclamationmark.icloud", label: "Changed elsewhere" },
  local: { icon: "icloud", label: "Not synced" },
};

export function TopBar({
  project,
  callbacks,
  inspectorVisible,
  onToggleInspector,
  accessory,
  share,
}: {
  project: ShellProjectInfo;
  callbacks: EditorShellCallbacks;
  inspectorVisible: boolean;
  onToggleInspector: () => void;
  accessory?: ReactNode;
  /** The Share slot's live key (ui/export/SharePanel ShareButton). */
  share?: ReactNode;
}) {
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState(project.name);
  const aspectIndex = ASPECT_RATIOS.findIndex((a) => a.id === project.aspectRatio);
  const sync = project.syncState ? SYNC_COPY[project.syncState] : null;

  return (
    <header className="cc-topbar">
      <Button variant="ghost" size="regular" symbol="square.grid.2x2" onClick={callbacks.onShowProjects} title="Browse Captures">
        Captures
      </Button>
      {renaming ? (
        <TextField
          className="cc-topbar__title-input"
          size="sm"
          autoFocus
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={() => {
            setRenaming(false);
            if (draft.trim() && draft !== project.name) callbacks.onRename?.(draft.trim());
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.target as HTMLInputElement).blur();
            if (e.key === "Escape") {
              setDraft(project.name);
              setRenaming(false);
            }
          }}
        />
      ) : (
        <span
          className="cc-topbar__title"
          title={callbacks.onRename ? "Double-click to rename" : project.name}
          onDoubleClick={() => {
            if (!callbacks.onRename) return;
            setDraft(project.name);
            setRenaming(true);
          }}
        >
          {project.name}
        </span>
      )}

      <div className="cc-topbar__cluster">
        {project.isImageCapture && (
          <>
            <Segmented
              segments={["Image", "Video"]}
              selectedIndex={project.stillTreatment === "video" ? 1 : 0}
              size="sm"
              chrome="plain"
              onChange={(i) => callbacks.onStillTreatmentChange?.(i === 0 ? "image" : "video")}
              ariaLabel="Treatment"
            />
            <span className="cc-topbar__divider" />
          </>
        )}
        <Select
          options={ASPECT_RATIOS.map((a) => ({ title: a.title, subtitle: a.hint }))}
          selectedIndex={aspectIndex >= 0 ? aspectIndex : null}
          onSelect={(i) => callbacks.onAspectChange?.(ASPECT_RATIOS[i].id)}
          placeholder="Aspect"
          size="sm"
          chrome="plain"
          minTriggerWidth={84}
          ariaLabel="Aspect ratio"
        />
      </div>

      <span className="cc-topbar__spacer" />
      {accessory}
      {sync && (
        <button
          type="button"
          className="cc-sync"
          data-state={project.syncState}
          title={project.syncState === "conflict" || project.syncState === "offline" ? "Retry sync" : "Cloud sync"}
          onClick={() => (project.syncState === "conflict" || project.syncState === "offline") && callbacks.onSyncRetry?.()}
        >
          <SFIcon name={sync.icon} size={11} weight="medium" className="cc-icon" />
          {sync.label}
        </button>
      )}
      {callbacks.onShare &&
        (share ?? (
          <Button variant="ghost" size="sm" symbol="square.and.arrow.up" onClick={callbacks.onShare}>
            Share
          </Button>
        ))}
      <Button variant="primary" size="sm" onClick={callbacks.onExport}>
        Export…
      </Button>
      <Button
        variant="ghost"
        size="regular"
        symbol="sidebar.right"
        onClick={onToggleInspector}
        aria-pressed={inspectorVisible}
        title="Toggle Inspector (⌥⌘I)"
      />
    </header>
  );
}
