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
 *   (state/cloud.ts). Every save carries its history metadata (SaveMeta:
 *   who — human / agent / mixed from the undo entries' `source` — and the
 *   base→new change-set). Local dev projects are read-only: edits live in
 *   the tab, nothing is written.
 * - A 409 THREE-WAY MERGES (docs/project-history.md §7): base = the snapshot
 *   the server last accepted (`savedProject`), mine = the current document,
 *   theirs = the server's. The most recent edit wins a same-field clash
 *   (`mineWins` = last local edit vs the server's updatedAt, ties → theirs).
 *   Clean → ONE undo entry, revision/savedProject = theirs, then a save with
 *   `X-CC-Checkpoint: merge`. Structural conflicts → `sync: "review"` and NO
 *   save until Merge Review resolves them. No server document → the old
 *   two-way `sync: "conflict"` (Keep mine / Load theirs).
 * - `previewVersion()` swaps in an old version READ-ONLY: edits, undo and
 *   autosave are off and the live project (with its undo stack and dirty
 *   flag) waits untouched until `exitPreview()`; `applyRestore()` lands a
 *   server-side restore as one undo step, "Restore Version".
 *
 * React reads it through `useEditorStore(store, selector)`; per-frame state
 * (the playhead) never lives here.
 */
import { useSyncExternalStore } from "react";

import {
  countChanges,
  diff,
  encodeChangeHeader,
  jsonEqual,
  merge,
  type AutoResolved,
  type Json,
  type MergeConflict,
  type MergeResult,
  type Side,
} from "../core/merge";
import {
  parseProject,
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
  /** The server's head version (the 409 names it) — who saved theirs. */
  headVersionId?: string | null;
}

/** A clean 409 merge just landed ("Merged 2 changes from Ana (Web)"). */
export interface MergeNotice {
  /** Bumps per merge (callout identity). */
  id: number;
  /** Changes the merge brought into this document (countChanges(mine → merged)). */
  count: number;
  /** Same-field clashes the most recent edit settled. */
  autoResolved: number;
  /** The server revision (theirs) that was merged — who made it is History's to say. */
  serverRevision: number;
  /** Theirs' version (from the 409), when the API named it. */
  headVersionId: string | null;
}

/** Structural conflicts waiting in Merge Review (`sync: "review"`). */
export interface MergeReviewState {
  conflicts: MergeConflict[];
  autoResolved: AutoResolved[];
  /** The user's picks so far (conflict id → side); unpicked = the last writer. */
  choices: Record<string, Side>;
  /** Mine edited last (else theirs) — every conflict's default. */
  mineWins: boolean;
  serverRevision: number;
  updatedAt: string;
}

/** The old version on screen (read-only). */
export interface PreviewInfo {
  versionId: string;
  /** "Sep 28, 3:42 PM — Ana on Web". */
  title: string;
  /** Media that version names which is no longer stored (it previews without them). */
  missingPaths?: string[];
}

/** Who made a save's changes (X-CC-Source). */
export type SaveSource = "human" | "agent" | "mixed";

/** History metadata for one save (state/cloud.ts turns it into X-CC-* headers). */
export interface SaveMeta {
  source: SaveSource;
  /** `encodeChangeHeader(diff(saved, new))`; null when over budget. */
  change: string | null;
  checkpoint?: "merge";
  /** The server revision this save merged (with checkpoint "merge"). */
  mergedFrom?: number;
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
  /** The server moved on: saves stop until a merge/review/choice clears it. */
  conflict: ConflictInfo | null;
  /** Set during Merge Review (`sync: "review"`). */
  review: MergeReviewState | null;
  mergeNotice: MergeNotice | null;
  /** Viewing an old version (read-only). */
  preview: PreviewInfo | null;
}

export type SaveResult =
  | { ok: true; revision: number }
  | { ok: false; conflict: true; revision: number; document: string | null; updatedAt: string; headVersionId?: string | null };

export interface Persistence {
  save(document: string, baseRevision: number, meta?: SaveMeta): Promise<SaveResult>;
}

export interface EditorStoreOptions {
  /** Wall clock (epoch ms) for `mineWins` — the last local edit vs the server's updatedAt. */
  clock?: () => number;
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
    review: null,
    mergeNotice: null,
    preview: null,
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
  /** `JSON.parse(documentText(savedProject))`, cached per snapshot (the merge/diff base). */
  private savedJSONCache: { project: Project; json: Json } | null = null;

  private persistence: Persistence | null = null;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;
  private saving: Promise<void> | null = null;
  private playheadOutput: () => number = () => 0;

  // History bookkeeping (docs/project-history.md).
  private readonly clock: () => number;
  /** Wall time of the last local edit / undo / redo (0 = none since load). */
  private lastEditAt = 0;
  /** Undo-entry sources since the last accepted save (→ X-CC-Source). */
  private pendingSources = new Set<UndoEntry["source"]>();
  /** The next save is a merge checkpoint (set by a clean merge, consumed by flush). */
  private nextCheckpoint: { checkpoint: "merge"; mergedFrom: number } | null = null;
  /** The 409 being merged: base + theirs, kept for Merge Review's re-merges. */
  private pendingMerge: { base: Json; theirsJSON: Json; theirsText: string; theirsProject: Project; info: ConflictInfo; mineWins: boolean } | null = null;
  private mergeSeq = 0;
  /** While previewing: the live editor state, restored by exitPreview(). */
  private live: { project: Project; selection: Selection; inspectorTab: InspectorTabId; sliceArmed: boolean } | null = null;
  private previewProject: Project | null = null;
  private previewText = "";
  private previewJSON: Record<string, unknown> | null = null;

  constructor(opts: EditorStoreOptions = {}) {
    this.clock = opts.clock ?? (() => Date.now());
  }

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
    this.savedJSONCache = null;
    this.undoStack = [];
    this.redoStack = [];
    this.persistence = opts.origin === "cloud" ? (opts.persistence ?? null) : null;
    this.lastEditAt = 0;
    this.pendingSources = new Set();
    this.nextCheckpoint = null;
    this.pendingMerge = null;
    this.live = null;
    this.previewProject = null;
    this.previewJSON = null;
    this.previewText = "";
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
      review: null,
      mergeNotice: null,
      preview: null,
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
    if (project === this.previewProject) return this.previewText;
    return serializeProjectText(project);
  }

  /** project.json as a JSON object (what the engine consumes). */
  documentJSON(project: Project | null = this.state.project): Record<string, unknown> {
    if (!project || project === this.loadedProject) {
      if (!this.rawJSON) this.rawJSON = JSON.parse(this.rawText || "{}") as Record<string, unknown>;
      return this.rawJSON;
    }
    if (project === this.previewProject && this.previewJSON) return this.previewJSON;
    return serializeProject(project);
  }

  /** The merge/diff base: the server's accepted snapshot as raw JSON (exact bytes, parsed). */
  private savedDocumentJSON(): Json {
    const saved = this.savedProject;
    if (!saved) return {};
    if (this.savedJSONCache?.project !== saved) this.savedJSONCache = { project: saved, json: JSON.parse(this.documentText(saved)) as Json };
    return this.savedJSONCache.json;
  }

  /** The project the user is editing — the live one even while an old version is previewed. */
  private liveProject(): Project | null {
    return this.live ? this.live.project : this.state.project;
  }

  /** The server's accepted snapshot as raw JSON (History's "Current — unsaved: …" line). */
  savedDocument(): Json {
    return this.savedDocumentJSON();
  }

  /** The live document (never the previewed version) — History's "Compare with current". */
  liveDocumentJSON(): Record<string, unknown> {
    return this.documentJSON(this.liveProject());
  }

  // ── Transactions ──────────────────────────────────────────────────────

  /**
   * Run an Edit against a draft. `null` from the edit (a Mac guard / beep)
   * discards the draft; an edit that only changes selection records no undo
   * step. Returns the outcome (or null).
   */
  apply(edit: Edit, opts: TransactOptions = {}): EditOutcome | null {
    const base = this.state.project;
    if (!base || this.state.preview) return null;
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
    if (this.state.preview) throw new Error("An old version is on screen (read-only) — go back to the current version to edit.");
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
    this.noteLocalEdit(opts.source ?? "user");
    this.setProject(next, { selection, inspectorTab, sliceArmed });
  }

  /** A local change the next save carries: its author kind + when (for mineWins). */
  private noteLocalEdit(source: UndoEntry["source"]) {
    this.pendingSources.add(source);
    this.lastEditAt = this.clock();
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

  /** `source`: who asked — the WebMCP `undo` tool passes "mcp" (an agent edit). */
  undo(opts: { source?: UndoEntry["source"] } = {}): UndoEntry | null {
    if (this.state.preview || !this.state.project) return null;
    const entry = this.undoStack.pop();
    if (!entry) return null;
    this.redoStack.push(entry);
    this.noteLocalEdit(opts.source ?? "user");
    this.setProject(entry.before, { selection: this.prune(entry.before, entry.selectionBefore) });
    return entry;
  }

  redo(opts: { source?: UndoEntry["source"] } = {}): UndoEntry | null {
    if (this.state.preview || !this.state.project) return null;
    const entry = this.redoStack.pop();
    if (!entry) return null;
    this.undoStack.push(entry);
    this.noteLocalEdit(opts.source ?? "user");
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
    if (keys.length === 0 || !this.state.project || this.state.preview) return;
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
    if (keys.length === 0 || !this.state.project || this.state.preview) return;
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
    if (keys.length === 0 || !this.state.project || this.state.preview) return;
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
    // Previewing an old version never saves (the live project waits untouched).
    if (!this.persistence || this.state.readOnly || this.state.conflict || this.state.preview) return;
    if (!this.state.dirty) {
      if (this.state.sync === "saving" && !this.saving) this.set({ sync: "saved" });
      return;
    }
    this.cancelSave();
    if (this.state.sync !== "offline") this.set({ sync: "saving" });
    this.saveTimer = setTimeout(() => void this.flush(), delay);
  }

  /** The save's X-CC-Source from the undo entries' sources since the last save. */
  private static sourceOf(sources: ReadonlySet<UndoEntry["source"]>): SaveSource {
    const agent = sources.has("mcp");
    const human = sources.has("user");
    return agent && human ? "mixed" : agent ? "agent" : "human";
  }

  /**
   * Save now (also used on page hide). Resolves when the server has it.
   * Always the LIVE project — an old version on screen is never saved.
   */
  async flush(): Promise<void> {
    this.cancelSave();
    if (this.saving) {
      await this.saving;
      if (this.state.dirty) return this.flush();
      return;
    }
    const persistence = this.persistence;
    const project = this.liveProject();
    if (!persistence || !project || !this.state.dirty || this.state.conflict || this.state.revision == null) return;
    const text = this.documentText(project);
    const baseRevision = this.state.revision;
    // History metadata: who (since the last accepted save) and what (saved → new).
    const sources = this.pendingSources;
    this.pendingSources = new Set();
    const checkpoint = this.nextCheckpoint;
    this.nextCheckpoint = null;
    const meta: SaveMeta = {
      source: EditorStore.sourceOf(sources),
      change: encodeChangeHeader(diff(this.savedDocumentJSON(), JSON.parse(text) as Json)),
      ...(checkpoint ? { checkpoint: checkpoint.checkpoint, mergedFrom: checkpoint.mergedFrom } : null),
    };
    const giveBack = () => {
      for (const s of sources) this.pendingSources.add(s);
      if (checkpoint && !this.nextCheckpoint) this.nextCheckpoint = checkpoint;
    };
    this.set({ sync: "saving" });
    this.saving = (async () => {
      try {
        const result = await persistence.save(text, baseRevision, meta);
        if (result.ok) {
          this.savedProject = project;
          const current = this.liveProject();
          this.set({ revision: result.revision, dirty: current !== project, sync: current !== project ? "saving" : "saved" });
        } else {
          giveBack();
          this.handleConflict({
            serverRevision: result.revision,
            serverDocument: result.document,
            updatedAt: result.updatedAt,
            headVersionId: result.headVersionId ?? null,
          });
        }
      } catch {
        giveBack();
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

  // ── Concurrent edits (docs/project-history.md §3, §7) ─────────────────

  /**
   * The server moved on (a 409, or a restore that lost its race): merge
   * three ways. base = the snapshot the server last accepted, mine = the
   * live document, theirs = the server's. Clean → applied as one undo step
   * and saved as a `merge` checkpoint; structural conflicts → Merge Review
   * (`sync: "review"`, no saves). No server document → the two-way fallback.
   */
  handleConflict(info: ConflictInfo): void {
    if (this.state.preview) this.exitPreview();
    const mine = this.state.project;
    let theirsJSON: Json;
    let theirsProject: Project;
    try {
      if (!info.serverDocument || !mine || !this.savedProject) throw new Error("no merge base");
      theirsJSON = JSON.parse(info.serverDocument) as Json;
      theirsProject = parseProject(theirsJSON);
    } catch {
      this.pendingMerge = null;
      this.set({ sync: "conflict", conflict: info, review: null });
      return;
    }
    // The most recent edit wins a same-field clash; ties go to theirs.
    const serverAt = Date.parse(info.updatedAt);
    const mineWins = Number.isFinite(serverAt) ? this.lastEditAt > serverAt : false;
    this.pendingMerge = { base: this.savedDocumentJSON(), theirsJSON, theirsText: info.serverDocument!, theirsProject, info, mineWins };
    const mineJSON = this.documentJSON(mine) as Json;
    const result = merge(this.pendingMerge.base, mineJSON, theirsJSON, mineWins);
    if (result.conflicts.length === 0) {
      this.applyMerge(result, mineJSON);
      return;
    }
    this.cancelSave();
    this.set({
      sync: "review",
      conflict: info,
      review: {
        conflicts: result.conflicts,
        autoResolved: result.autoResolved,
        choices: {},
        mineWins,
        serverRevision: info.serverRevision,
        updatedAt: info.updatedAt,
      },
    });
  }

  /** Merge Review's three inputs (to describe conflicts), while reviewing. */
  reviewDocuments(): { base: Json; mine: Json; theirs: Json } | null {
    const pending = this.pendingMerge;
    const mine = this.liveProject();
    if (!this.state.review || !pending || !mine) return null;
    return { base: pending.base, mine: this.documentJSON(mine) as Json, theirs: pending.theirsJSON };
  }

  /** Merge Review: pick a side for one conflict (re-merges; nothing is saved yet). */
  setReviewChoice(conflictId: string, side: Side): void {
    const review = this.state.review;
    const pending = this.pendingMerge;
    const mine = this.liveProject();
    if (!review || !pending || !mine) return;
    const choices = { ...review.choices, [conflictId]: side };
    const result = merge(pending.base, this.documentJSON(mine) as Json, pending.theirsJSON, pending.mineWins, choices);
    this.set({ review: { ...review, choices, conflicts: result.conflicts, autoResolved: result.autoResolved } });
  }

  /**
   * Merge Review → apply: re-merge the CURRENT document with the picks and
   * land it (one undo step, then the merge save). Returns false — and keeps
   * reviewing — when an edit made during review raised a conflict the user
   * has not seen yet.
   */
  applyReview(): boolean {
    if (this.state.preview) this.exitPreview();
    const review = this.state.review;
    const pending = this.pendingMerge;
    const mine = this.state.project;
    if (!review || !pending || !mine) return false;
    const mineJSON = this.documentJSON(mine) as Json;
    const result = merge(pending.base, mineJSON, pending.theirsJSON, pending.mineWins, review.choices);
    const seen = new Set(review.conflicts.map((c) => c.id));
    if (result.conflicts.some((c) => !seen.has(c.id))) {
      this.set({ review: { ...review, conflicts: result.conflicts, autoResolved: result.autoResolved } });
      return false;
    }
    this.applyMerge(result, mineJSON);
    return true;
  }

  /**
   * Land a merge: theirs becomes the server snapshot (exact bytes), the
   * merged document is ONE undo step ("Merge Changes"), and — when it
   * differs from theirs — the next save is a `merge` checkpoint.
   */
  private applyMerge(result: MergeResult, mineJSON: Json): void {
    const pending = this.pendingMerge;
    const before = this.state.project;
    if (!pending || !before) return;
    let merged: Project;
    try {
      merged = jsonEqual(result.merged, pending.theirsJSON)
        ? pending.theirsProject
        : jsonEqual(result.merged, mineJSON)
          ? before
          : parseProject(result.merged);
    } catch {
      // A merged document the model can't decode is not saved: fall back to the choice.
      this.pendingMerge = null;
      this.set({ sync: "conflict", conflict: pending.info, review: null });
      return;
    }
    this.pendingMerge = null;
    this.rawText = pending.theirsText;
    this.rawJSON = null;
    this.loadedProject = pending.theirsProject;
    this.savedProject = pending.theirsProject;
    this.savedJSONCache = { project: pending.theirsProject, json: pending.theirsJSON };
    if (merged !== before) {
      this.undoStack.push({
        label: "Merge Changes",
        before,
        after: merged,
        selectionBefore: this.state.selection,
        selectionAfter: this.prune(merged, this.state.selection),
        at: now(),
        source: "user",
      });
      if (this.undoStack.length > UNDO_LIMIT) this.undoStack.shift();
      this.redoStack = [];
    }
    const dirty = merged !== pending.theirsProject;
    this.nextCheckpoint = dirty ? { checkpoint: "merge", mergedFrom: pending.info.serverRevision } : null;
    this.set({
      conflict: null,
      review: null,
      revision: pending.info.serverRevision,
      sync: dirty ? "saving" : "saved",
      mergeNotice: {
        id: ++this.mergeSeq,
        count: countChanges(diff(mineJSON, result.merged)),
        autoResolved: result.autoResolved.length,
        serverRevision: pending.info.serverRevision,
        headVersionId: pending.info.headVersionId ?? null,
      },
    });
    this.setProject(merged, { selection: this.prune(merged, this.state.selection) });
    if (dirty) this.scheduleSave(0);
  }

  dismissMergeNotice(): void {
    if (this.state.mergeNotice) this.set({ mergeNotice: null });
  }

  /**
   * No-base fallback (the server sent no document, or it could not be
   * parsed): "keepMine" overwrites the server copy (saves against its
   * revision); "takeTheirs" loads the server's project (undo history kept —
   * an undo steps back into the local edits, which then save again).
   */
  resolveConflict(choice: "keepMine" | "takeTheirs"): void {
    const conflict = this.state.conflict;
    if (!conflict) return;
    if (this.state.preview) this.exitPreview();
    this.pendingMerge = null;
    if (choice === "keepMine") {
      this.set({ conflict: null, review: null, revision: conflict.serverRevision, dirty: true });
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
    this.savedJSONCache = null;
    this.set({ conflict: null, review: null, revision: conflict.serverRevision, sync: "saved" });
    this.setProject(project, { selection: this.prune(project, this.state.selection) });
  }

  // ── Version preview + restore (History) ───────────────────────────────

  /**
   * Show an old version READ-ONLY: edits, undo/redo and autosave are off;
   * the live project, its undo stack, selection and dirty flag wait until
   * `exitPreview()`. Media resolves through the version's manifest (the
   * caller sets ProjectMedia's override). Throws if the text doesn't parse.
   */
  previewVersion(opts: { versionId: string; title: string; text: string; missingPaths?: string[] }): void {
    const current = this.state.project;
    if (!current) throw new Error("No project is open.");
    const json = JSON.parse(opts.text) as Record<string, unknown>;
    const project = parseProject(json);
    this.cancelSave();
    if (!this.live) {
      this.live = { project: current, selection: this.state.selection, inspectorTab: this.state.inspectorTab, sliceArmed: this.state.sliceArmed };
    }
    this.previewProject = project;
    this.previewText = opts.text;
    this.previewJSON = json;
    this.set({
      project,
      version: this.state.version + 1,
      selection: EMPTY_SELECTION,
      sliceArmed: false,
      preview: { versionId: opts.versionId, title: opts.title, ...(opts.missingPaths?.length ? { missingPaths: opts.missingPaths } : null) },
      canUndo: false,
      canRedo: false,
      undoLabel: null,
      redoLabel: null,
    });
  }

  /** Back to the live project, exactly as it was. */
  exitPreview(): void {
    const live = this.live;
    if (!live) return;
    this.live = null;
    this.previewProject = null;
    this.previewText = "";
    this.previewJSON = null;
    this.set({
      project: live.project,
      version: this.state.version + 1,
      selection: this.prune(live.project, live.selection),
      inspectorTab: live.inspectorTab,
      sliceArmed: live.sliceArmed,
      preview: null,
      ...this.undoFlags(),
    });
    this.scheduleSave();
  }

  /**
   * A server-side restore landed (POST …/restore saved `text` as `revision`):
   * it becomes the server snapshot and ONE undo step, "Restore Version" —
   * undoing it puts the previous document back (and autosaves it).
   */
  applyRestore(opts: { text: string; revision: number }): void {
    const restored = parseProjectText(opts.text);
    if (this.state.preview) this.exitPreview();
    const before = this.state.project;
    if (!before) return;
    this.cancelSave();
    this.rawText = opts.text;
    this.rawJSON = null;
    this.loadedProject = restored;
    this.savedProject = restored;
    this.savedJSONCache = null;
    this.pendingSources = new Set();
    this.nextCheckpoint = null;
    this.undoStack.push({
      label: "Restore Version",
      before,
      after: restored,
      selectionBefore: this.state.selection,
      selectionAfter: this.prune(restored, this.state.selection),
      at: now(),
      source: "user",
    });
    if (this.undoStack.length > UNDO_LIMIT) this.undoStack.shift();
    this.redoStack = [];
    this.set({ revision: opts.revision, conflict: null, review: null, sync: "saved" });
    this.setProject(restored, { selection: this.prune(restored, this.state.selection) });
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
