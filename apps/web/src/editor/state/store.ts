/**
 * The editor store — one tiny in-house store (ARCHITECTURE.md §Stack: no
 * Zustand) over the LOSSLESS core model.
 *
 *   project.json text ─parseProjectText→ Project (immutable snapshots)
 *        ▲                                   │ edits run on a deep DRAFT
 *        │ serialize (raw text while         │ (state/draft.ts), reconciled
 *        │ untouched → byte-identical)       ▼ back into shared structure
 *   cloud autosave  ◀── dirty ── undo/redo stack of snapshots (+ selection)
 *
 * - Edits are the Mac's own (state/edits.ts); panes patch settings/regions
 *   through `updateSettings` / `updateRegion`; WebMCP batches go through
 *   `transact` (all-or-nothing, one undo step).
 * - Undo entries are whole-project snapshots with structural sharing, so an
 *   undo is a pointer swap and a redo can never drift.
 * - Consecutive edits with the same `coalesceKey` inside COALESCE_MS merge
 *   into one undo step (slider drags, nudges) — the Mac's run-loop grouping.
 * - Cloud projects autosave (debounced) with optimistic `If-Match` revisions
 *   (state/cloud.ts); a 409 surfaces as `sync: "conflict"` with the server's
 *   copy for the conflict UI. Local dev projects are read-only: edits live in
 *   the tab, nothing is written.
 *
 * React reads it through `useEditorStore(store, selector)`; per-frame state
 * (the playhead) never lives here.
 */
import { useSyncExternalStore } from "react";

import {
  parseProjectText,
  serializeProject,
  serializeProjectText,
  type Annotation,
  type BlurRegion,
  type CameraLayoutRegion,
  type FocusRegion,
  type HighlightRegion,
  type Project,
  type ProjectSettings,
  type SubtitleSegment,
  type TiltRegion,
  type VideoSpeedRegion,
  type VoiceOverClip,
  type ZoomRegion,
} from "../core/model";
import { effectiveVideoClipSegments } from "../core/time/clips";
import type { InspectorTabId, SyncState } from "../ui/shell/types";
import { produce } from "./draft";
import { fullTimeMap, type Edit, type EditEnv, type EditOutcome } from "./edits";
import { EMPTY_SELECTION, inspectorTabForChange, pruneSelection, type Selection } from "./selection";

// ── Region kinds (pane contract) ─────────────────────────────────────────

export type RegionKind =
  | "zoom"
  | "tilt"
  | "blur"
  | "highlight"
  | "focus"
  | "cameraLayout"
  | "annotation"
  | "voiceOver"
  | "subtitle"
  | "speed";

export interface RegionByKind {
  zoom: ZoomRegion;
  tilt: TiltRegion;
  blur: BlurRegion;
  highlight: HighlightRegion;
  focus: FocusRegion;
  cameraLayout: CameraLayoutRegion;
  annotation: Annotation;
  voiceOver: VoiceOverClip;
  subtitle: SubtitleSegment;
  speed: VideoSpeedRegion;
}

const REGION_ARRAY: { [K in RegionKind]: keyof Project } = {
  zoom: "zoomRegions",
  tilt: "tiltRegions",
  blur: "blurRegions",
  highlight: "highlightRegions",
  focus: "focusRegions",
  cameraLayout: "cameraLayoutRegions",
  annotation: "annotations",
  voiceOver: "voiceOverClips",
  subtitle: "subtitles",
  speed: "speedRegions",
};

const REGION_NAME: Record<RegionKind, string> = {
  zoom: "Zoom",
  tilt: "Tilt",
  blur: "Blur",
  highlight: "Highlight",
  focus: "Depth Focus",
  cameraLayout: "Camera Layout",
  annotation: "Annotation",
  voiceOver: "Voice Over",
  subtitle: "Subtitle",
  speed: "Speed",
};

export function regionsOf<K extends RegionKind>(project: Project, kind: K): RegionByKind[K][] {
  return project[REGION_ARRAY[kind]] as unknown as RegionByKind[K][];
}

// ── State ────────────────────────────────────────────────────────────────

export type ProjectOrigin = "cloud" | "local";

export interface ConflictInfo {
  /** The server's current revision (to overwrite against). */
  serverRevision: number;
  /** The server's project.json, when the API returned it. */
  serverDocument: string | null;
  updatedAt: string;
}

export interface EditorState {
  project: Project | null;
  /** Bumps on every project change (cheap memo key). */
  version: number;
  parseError: string | null;
  selection: Selection;
  inspectorTab: InspectorTabId;
  sliceArmed: boolean;
  canUndo: boolean;
  canRedo: boolean;
  undoLabel: string | null;
  redoLabel: string | null;
  /** Project differs from the last saved/loaded copy. */
  dirty: boolean;
  origin: ProjectOrigin | null;
  readOnly: boolean;
  sync: SyncState;
  revision: number | null;
  conflict: ConflictInfo | null;
}

export type SaveResult =
  | { ok: true; revision: number }
  | { ok: false; conflict: true; revision: number; document: string | null; updatedAt: string };

export interface Persistence {
  save(document: string, baseRevision: number): Promise<SaveResult>;
}

export interface UndoEntry {
  label: string;
  before: Project;
  after: Project;
  selectionBefore: Selection;
  selectionAfter: Selection;
  coalesceKey?: string;
  at: number;
  /** "mcp" for WebMCP batches (the `undo` tool walks these). */
  source: "user" | "mcp";
  /** MCP history metadata (the Mac's `.mcp-history/*.meta.json`). */
  mcp?: McpHistoryMeta;
}

export interface McpHistoryMeta {
  tool: string;
  summary: string;
  at: string;
}

export interface TransactOptions {
  coalesceKey?: string;
  source?: "user" | "mcp";
  /** Record an undo entry even when nothing changed (every MCP write snapshots). */
  forceEntry?: boolean;
  /** MCP metadata, evaluated AFTER the recipe (the summary needs its result). */
  mcp?: () => McpHistoryMeta;
}

const COALESCE_MS = 1200;
/** A per-gesture key ("…gesture:<n>", unique per pointer gesture) stays open
 *  until `endCoalescing()` — a drag that pauses mid-gesture is still ONE undo step. */
const isGestureKey = (key: string) => /(^|-)gesture:/.test(key);
const SAVE_DEBOUNCE_MS = 800;
const RETRY_MS = 4000;
const UNDO_LIMIT = 300;

const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now());

export class EditorStore {
  private state: EditorState = {
    project: null,
    version: 0,
    parseError: null,
    selection: EMPTY_SELECTION,
    inspectorTab: "background",
    sliceArmed: false,
    canUndo: false,
    canRedo: false,
    undoLabel: null,
    redoLabel: null,
    dirty: false,
    origin: null,
    readOnly: true,
    sync: "local",
    revision: null,
    conflict: null,
  };
  private listeners = new Set<() => void>();
  private undoStack: UndoEntry[] = [];
  private redoStack: UndoEntry[] = [];

  /** The snapshot parsed from `rawText` — serialized as `rawText` verbatim. */
  private loadedProject: Project | null = null;
  private rawText = "";
  private rawJSON: Record<string, unknown> | null = null;
  /** The snapshot the server holds (dirty = project !== savedProject). */
  private savedProject: Project | null = null;

  private persistence: Persistence | null = null;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;
  private saving: Promise<void> | null = null;
  private playheadOutput: () => number = () => 0;

  // ── Subscription ──────────────────────────────────────────────────────

  getState = (): EditorState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private set(patch: Partial<EditorState>) {
    this.state = { ...this.state, ...patch };
    for (const l of [...this.listeners]) l();
  }

  // ── Loading ───────────────────────────────────────────────────────────

  /**
   * Load project.json text. Local (dev) projects are read-only: edits apply
   * in the tab, nothing is saved.
   */
  load(opts: { text: string; origin: ProjectOrigin; revision: number | null; persistence?: Persistence | null }): void {
    this.cancelSave();
    let project: Project | null = null;
    let parseError: string | null = null;
    try {
      project = parseProjectText(opts.text);
    } catch (error) {
      parseError = error instanceof Error ? error.message : String(error);
    }
    this.rawText = opts.text;
    this.rawJSON = null;
    this.loadedProject = project;
    this.savedProject = project;
    this.undoStack = [];
    this.redoStack = [];
    this.persistence = opts.origin === "cloud" ? (opts.persistence ?? null) : null;
    this.set({
      project,
      version: this.state.version + 1,
      parseError,
      selection: EMPTY_SELECTION,
      sliceArmed: false,
      origin: opts.origin,
      readOnly: opts.origin !== "cloud",
      revision: opts.revision,
      sync: opts.origin === "cloud" ? "saved" : "local",
      conflict: null,
      dirty: false,
      ...this.undoFlags(),
    });
  }

  /** The playhead (OUTPUT seconds) — adds land at it like the Mac's currentTime. */
  setPlayheadProvider(fn: () => number): void {
    this.playheadOutput = fn;
  }

  /** The Mac's `currentTime` (SOURCE seconds) for the current playhead. */
  playheadSource(): number {
    const p = this.state.project;
    if (!p) return 0;
    return fullTimeMap(p).sourceTime(Math.max(0, this.playheadOutput()));
  }

  env(): EditEnv {
    return { playheadSource: this.playheadSource() };
  }

  // ── Serialization ─────────────────────────────────────────────────────

  /** project.json for saving: the ORIGINAL bytes while untouched (even after
   *  undoing back to it), else the lossless serializer's output. */
  documentText(project: Project | null = this.state.project): string {
    if (!project) return this.rawText;
    if (project === this.loadedProject) return this.rawText;
    return serializeProjectText(project);
  }

  /** project.json as a JSON object (what the engine consumes). */
  documentJSON(project: Project | null = this.state.project): Record<string, unknown> {
    if (!project || project === this.loadedProject) {
      if (!this.rawJSON) this.rawJSON = JSON.parse(this.rawText || "{}") as Record<string, unknown>;
      return this.rawJSON;
    }
    return serializeProject(project);
  }

  // ── Transactions ──────────────────────────────────────────────────────

  /**
   * Run an Edit against a draft. `null` from the edit (a Mac guard / beep)
   * discards the draft; an edit that only changes selection records no undo
   * step. Returns the outcome (or null).
   */
  apply(edit: Edit, opts: TransactOptions = {}): EditOutcome | null {
    const base = this.state.project;
    if (!base) return null;
    const env = this.env();
    const selection = this.state.selection;
    const { next, result } = produce(base, (draft) => edit(draft, selection, env));
    if (!result) return null;
    this.commit(base, next, result, opts);
    return result;
  }

  /**
   * Arbitrary all-or-nothing mutation (WebMCP batches, panes). A throw
   * discards the draft and propagates; the project is untouched.
   */
  transact<R>(label: string, recipe: (draft: Project) => R, opts: TransactOptions = {}): R {
    const base = this.state.project;
    if (!base) throw new Error("No project is open.");
    const { next, result } = produce(base, recipe);
    this.commit(base, next, { label }, opts);
    return result;
  }

  private commit(base: Project, next: Project, outcome: EditOutcome, opts: TransactOptions) {
    const prevSelection = this.state.selection;
    let selection = outcome.selection ?? prevSelection;
    if (next !== base) selection = this.prune(next, selection);
    const inspectorTab = outcome.inspectorTab ?? inspectorTabForChange(prevSelection, selection) ?? this.state.inspectorTab;
    const sliceArmed = outcome.disarmSlice ? false : this.state.sliceArmed;

    if (next === base && !opts.forceEntry) {
      // Selection-only (e.g. "Slide" when the slide is already on).
      this.set({ selection, inspectorTab, sliceArmed });
      return;
    }

    const t = now();
    const top = this.undoStack[this.undoStack.length - 1];
    if (opts.coalesceKey && top && top.coalesceKey === opts.coalesceKey && (t - top.at < COALESCE_MS || isGestureKey(opts.coalesceKey)) && top.after === base) {
      top.after = next;
      top.selectionAfter = selection;
      top.at = t;
    } else {
      this.undoStack.push({
        label: outcome.label,
        before: base,
        after: next,
        selectionBefore: prevSelection,
        selectionAfter: selection,
        coalesceKey: opts.coalesceKey,
        at: t,
        source: opts.source ?? "user",
        mcp: opts.mcp?.(),
      });
      if (this.undoStack.length > UNDO_LIMIT) this.undoStack.shift();
    }
    this.redoStack = [];
    this.setProject(next, { selection, inspectorTab, sliceArmed });
  }

  private setProject(project: Project, extra: Partial<EditorState> = {}) {
    this.set({
      project,
      version: this.state.version + 1,
      dirty: project !== this.savedProject,
      ...this.undoFlags(),
      ...extra,
    });
    this.scheduleSave();
  }

  private undoFlags() {
    const u = this.undoStack[this.undoStack.length - 1];
    const r = this.redoStack[this.redoStack.length - 1];
    return { canUndo: !!u, canRedo: !!r, undoLabel: u?.label ?? null, redoLabel: r?.label ?? null };
  }

  /** Close the current coalescing group (e.g. on slider release). */
  endCoalescing(): void {
    const top = this.undoStack[this.undoStack.length - 1];
    if (top) top.coalesceKey = undefined;
  }

  undo(): UndoEntry | null {
    const entry = this.undoStack.pop();
    if (!entry || !this.state.project) return null;
    this.redoStack.push(entry);
    this.setProject(entry.before, { selection: this.prune(entry.before, entry.selectionBefore) });
    return entry;
  }

  redo(): UndoEntry | null {
    const entry = this.redoStack.pop();
    if (!entry || !this.state.project) return null;
    this.undoStack.push(entry);
    this.setProject(entry.after, { selection: this.prune(entry.after, entry.selectionAfter) });
    return entry;
  }

  /** The undo stack, newest last (read-only; the WebMCP `undo` tool reads it). */
  history(): readonly UndoEntry[] {
    return this.undoStack;
  }

  private prune(p: Project, sel: Selection): Selection {
    const has = (list: Array<{ id: string }>) => (id: string) => list.some((r) => r.id === id);
    return pruneSelection(sel, {
      zoom: has(p.zoomRegions),
      tilt: has(p.tiltRegions),
      highlight: has(p.highlightRegions),
      depthFocus: has(p.focusRegions),
      blur: has(p.blurRegions),
      annotation: has(p.annotations),
      cameraLayout: has(p.cameraLayoutRegions),
      voiceOver: has(p.voiceOverClips),
      speed: has(p.speedRegions),
      clip: has(effectiveVideoClipSegments(p)),
      intro: p.settings.introSlideStyle !== "Off",
      curtain: p.settings.curtainUnveilCorner !== "Off",
    });
  }

  // ── Selection / chrome ────────────────────────────────────────────────

  select(selection: Selection, inspectorTab?: InspectorTabId | null): void {
    const prev = this.state.selection;
    const tab = inspectorTab ?? inspectorTabForChange(prev, selection) ?? this.state.inspectorTab;
    if (selection === prev && tab === this.state.inspectorTab) return;
    this.set({ selection, inspectorTab: tab });
  }

  setInspectorTab(tab: InspectorTabId): void {
    if (tab !== this.state.inspectorTab) this.set({ inspectorTab: tab });
  }

  setSliceArmed(armed: boolean): void {
    if (armed !== this.state.sliceArmed) this.set({ sliceArmed: armed });
  }

  // ── Pane actions (the panes' onSettingsChange / onRegionChange) ────────

  /** Patch ProjectSettings (core-model shapes; colours are CodableColor). */
  updateSettings = (patch: Partial<ProjectSettings>, label = "Edit Settings"): void => {
    const keys = Object.keys(patch).sort();
    if (keys.length === 0 || !this.state.project) return;
    this.transact(
      label,
      (draft) => {
        const s = draft.settings as unknown as Record<string, unknown>;
        for (const key of keys) {
          const value = (patch as Record<string, unknown>)[key];
          if (value === undefined) delete s[key];
          else if (key === "exportSettings" && value && typeof value === "object") s[key] = { ...(s[key] as object), ...(value as object) };
          else s[key] = value;
        }
      },
      { coalesceKey: `settings:${keys.join(",")}` },
    );
  };

  /** Patch one region/annotation/clip by id (fields in core-model shapes). */
  updateRegion = <K extends RegionKind>(kind: K, id: string, patch: Partial<RegionByKind[K]>): void => {
    const keys = Object.keys(patch).sort();
    if (keys.length === 0 || !this.state.project) return;
    if (!regionsOf(this.state.project, kind).some((r) => r.id === id)) return;
    this.transact(
      `Edit ${REGION_NAME[kind]}`,
      (draft) => {
        const region = regionsOf(draft, kind).find((r) => r.id === id) as unknown as Record<string, unknown> | undefined;
        if (!region) return;
        for (const key of keys) {
          const value = (patch as Record<string, unknown>)[key];
          if (value === undefined) delete region[key];
          else region[key] = value;
        }
      },
      { coalesceKey: `region:${kind}:${id}:${keys.join(",")}` },
    );
  };

  /** Top-level project fields (name, still treatment, camera offset, subtitles…). */
  updateProject = (patch: Partial<Pick<Project, "name" | "stillTreatment" | "cameraTimeOffset" | "subtitles" | "trimStart" | "trimEnd">>, label = "Edit Project"): void => {
    const keys = Object.keys(patch).sort();
    if (keys.length === 0 || !this.state.project) return;
    this.transact(
      label,
      (draft) => {
        Object.assign(draft, patch);
      },
      { coalesceKey: `project:${keys.join(",")}` },
    );
  };

  // ── Persistence ───────────────────────────────────────────────────────

  private cancelSave() {
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = null;
  }

  private scheduleSave(delay = SAVE_DEBOUNCE_MS) {
    if (!this.persistence || this.state.readOnly || this.state.conflict) return;
    if (!this.state.dirty) {
      if (this.state.sync === "saving" && !this.saving) this.set({ sync: "saved" });
      return;
    }
    this.cancelSave();
    if (this.state.sync !== "offline") this.set({ sync: "saving" });
    this.saveTimer = setTimeout(() => void this.flush(), delay);
  }

  /** Save now (also used on page hide). Resolves when the server has it. */
  async flush(): Promise<void> {
    this.cancelSave();
    if (this.saving) {
      await this.saving;
      if (this.state.dirty) return this.flush();
      return;
    }
    const persistence = this.persistence;
    const project = this.state.project;
    if (!persistence || !project || !this.state.dirty || this.state.conflict || this.state.revision == null) return;
    const text = this.documentText(project);
    const baseRevision = this.state.revision;
    this.set({ sync: "saving" });
    this.saving = (async () => {
      try {
        const result = await persistence.save(text, baseRevision);
        if (result.ok) {
          this.savedProject = project;
          this.set({ revision: result.revision, dirty: this.state.project !== project, sync: this.state.project !== project ? "saving" : "saved" });
        } else {
          this.set({
            sync: "conflict",
            conflict: { serverRevision: result.revision, serverDocument: result.document, updatedAt: result.updatedAt },
          });
        }
      } catch {
        this.set({ sync: "offline" });
        this.saveTimer = setTimeout(() => void this.flush(), RETRY_MS);
      } finally {
        this.saving = null;
      }
    })();
    await this.saving;
    if (this.state.dirty && !this.state.conflict && this.state.sync !== "offline") this.scheduleSave(0);
  }

  /** Retry after the browser comes back online / the user clicks retry. */
  retrySave(): void {
    if (this.state.sync === "offline") void this.flush();
  }

  /**
   * Conflict UI: "keepMine" overwrites the server copy (saves against its
   * revision); "takeTheirs" loads the server's project (undo history kept —
   * an undo steps back into the local edits, which then save again).
   */
  resolveConflict(choice: "keepMine" | "takeTheirs"): void {
    const conflict = this.state.conflict;
    if (!conflict) return;
    if (choice === "keepMine") {
      this.set({ conflict: null, revision: conflict.serverRevision, dirty: true });
      void this.flush();
      return;
    }
    if (!conflict.serverDocument) return;
    const text = conflict.serverDocument;
    let project: Project;
    try {
      project = parseProjectText(text);
    } catch (error) {
      this.set({ parseError: error instanceof Error ? error.message : String(error) });
      return;
    }
    this.rawText = text;
    this.rawJSON = null;
    this.loadedProject = project;
    this.savedProject = project;
    this.set({ conflict: null, revision: conflict.serverRevision, sync: "saved" });
    this.setProject(project, { selection: this.prune(project, this.state.selection) });
  }

  /** Unsaved cloud edits (for a beforeunload guard). */
  hasUnsavedChanges(): boolean {
    return !this.state.readOnly && this.state.dirty;
  }
}

// ── React binding ─────────────────────────────────────────────────────────

export function useEditorStore<T>(store: EditorStore, selector: (state: EditorState) => T): T {
  return useSyncExternalStore(
    store.subscribe,
    () => selector(store.getState()),
    () => selector(store.getState()),
  );
}
