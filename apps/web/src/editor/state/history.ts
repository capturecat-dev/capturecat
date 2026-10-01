/**
 * Project history on the web (docs/project-history.md §1 Web, phase 3A).
 *
 *   HistoryController   the History pane's state: the version list (day
 *                       sections, retention, pinned media), preview /
 *                       back to current, restore, name, delete, compare,
 *                       "Free up" — and Merge Review's auto-open. All server
 *                       calls go through a `HistoryApi` (cloud.ts by
 *                       default; mocked in tests and the lab harness).
 *   pure helpers        version titles + client badges, day sections, the
 *                       Compare rows (a client-side diff grouped by
 *                       inspector tab plus Timeline and Subtitles), and the
 *                       Merge Review conflict copy.
 *
 * The store owns the document (preview overlay, merge, restore as one undo
 * step); this owns everything about versions. No React here — the UI reads
 * it through `useHistory(controller, selector)`.
 */
import { useSyncExternalStore } from "react";

import { changeSetFromJSON, diff, formatChangeSummary, type ChangeSet, type Json, type JsonObject, type MergeConflict } from "../core/merge";
import { INSPECTOR_TABS, type InspectorTabId } from "../ui/shell/types";
import {
  CloudApiError,
  deleteProjectVersion,
  getProjectVersion,
  listProjectVersions,
  nameProjectVersion,
  restoreProjectVersion,
  type HistoryRetention,
  type ProjectVersion,
  type RestoreResult,
  type VersionDetail,
  type VersionList,
} from "./cloud";
import type { EditorStore } from "./store";

// ── API seam ──────────────────────────────────────────────────────────────

export interface HistoryApi {
  list(opts: { before?: string | null; limit?: number }): Promise<VersionList>;
  get(versionId: string): Promise<VersionDetail>;
  name(versionId: string, label: string | null): Promise<ProjectVersion | null>;
  restore(versionId: string, baseRevision: number): Promise<RestoreResult>;
  remove(versionId: string): Promise<void>;
}

/** The real routes (state/cloud.ts) for one project. */
export function cloudHistoryApi(projectId: string): HistoryApi {
  return {
    list: (opts) => listProjectVersions(projectId, opts),
    get: (vid) => getProjectVersion(projectId, vid),
    name: (vid, label) => nameProjectVersion(projectId, vid, label),
    restore: (vid, rev) => restoreProjectVersion(projectId, vid, rev),
    remove: (vid) => deleteProjectVersion(projectId, vid),
  };
}

// ── Presentation helpers (pure) ─────────────────────────────────────────

const DATE_TIME = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
const TIME = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit" });
const DAY = new Intl.DateTimeFormat("en-US", { weekday: "short", month: "short", day: "numeric" });
const DAY_YEAR = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" });

const when = (iso: string): Date | null => {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? new Date(t) : null;
};

/** "Sep 28, 3:42 PM". */
export function formatDateTime(iso: string): string {
  const d = when(iso);
  return d ? DATE_TIME.format(d) : "";
}

/** "3:42 PM". */
export function formatTime(iso: string): string {
  const d = when(iso);
  return d ? TIME.format(d) : "";
}

/** The device the version was saved from: "Mac" / "Web" (null = unknown client). */
export function clientName(v: Pick<ProjectVersion, "clientKind">): string | null {
  return v.clientKind === "mac" ? "Mac" : v.clientKind === "web" ? "Web" : null;
}

/** The row badges: client, then "Agent" when an agent made (some of) it. */
export function versionBadges(v: Pick<ProjectVersion, "clientKind" | "source">): Array<{ text: string; tone: "client" | "agent"; title: string }> {
  const out: Array<{ text: string; tone: "client" | "agent"; title: string }> = [];
  const client = clientName(v);
  if (client) out.push({ text: client, tone: "client", title: `Saved from ${client === "Mac" ? "the Mac app" : "the web editor"}` });
  if (v.source === "agent") out.push({ text: "Agent", tone: "agent", title: `Made by an AI agent${client ? ` via ${client}` : ""}` });
  if (v.source === "mixed") out.push({ text: "Agent", tone: "agent", title: `Edited by a person and an AI agent${client ? ` on ${client}` : ""}` });
  return out;
}

/** "Ana on Web", "Agent via Mac (Ana)", "Ana". */
export function versionAuthor(v: Pick<ProjectVersion, "actorName" | "clientKind" | "source">): string {
  const who = v.actorName ?? "Someone";
  const client = clientName(v);
  if (v.source === "agent") return client ? `Agent via ${client} (${who})` : `Agent (${who})`;
  return client ? `${who} on ${client}` : who;
}

/** "Sep 28, 3:42 PM — Ana on Web" (the preview callout). */
export function versionTitle(v: ProjectVersion): string {
  return `${formatDateTime(v.updatedAt)} — ${versionAuthor(v)}`;
}

/** The author initial for the avatar. */
export function authorInitial(v: Pick<ProjectVersion, "actorName" | "source">): string {
  if (v.source === "agent") return "✦";
  const name = (v.actorName ?? "").trim();
  return name ? [...name][0].toUpperCase() : "?";
}

/** The row caption: the change summary, or what kind of version it is. */
export function versionCaption(v: ProjectVersion, maxParts = 3): string {
  const cs = v.change != null ? changeSetFromJSON(v.change as Json) : null;
  const summary = cs ? formatChangeSummary(cs, maxParts) : null;
  if (v.kind === "upload") return summary && summary !== "No changes" ? `Uploaded · ${summary}` : "Uploaded";
  if (v.kind === "restore") return "Restored an earlier version";
  if (v.kind === "merge") return summary && summary !== "No changes" ? `Merged · ${summary}` : "Merged changes";
  return summary ?? "Changes";
}

export interface DaySection {
  key: string;
  title: string;
  versions: ProjectVersion[];
}

const dayKey = (d: Date) => `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;

/** Newest-first versions → "Today" / "Yesterday" / "Mon, Sep 28" sections. */
export function daySections(versions: readonly ProjectVersion[], now: Date = new Date()): DaySection[] {
  const today = dayKey(now);
  const y = new Date(now);
  y.setDate(now.getDate() - 1);
  const yesterday = dayKey(y);
  const out: DaySection[] = [];
  for (const v of versions) {
    const d = when(v.updatedAt);
    const key = d ? dayKey(d) : "unknown";
    let section = out[out.length - 1];
    if (!section || section.key !== key) {
      const title = !d
        ? "Earlier"
        : key === today
          ? "Today"
          : key === yesterday
            ? "Yesterday"
            : d.getFullYear() === now.getFullYear()
              ? DAY.format(d)
              : DAY_YEAR.format(d);
      section = { key, title, versions: [] };
      out.push(section);
    }
    section.versions.push(v);
  }
  return out;
}

/** 1.2 GB / 340 MB / 12 KB. */
export function formatBytes(bytes: number): string {
  if (!(bytes > 0)) return "0 KB";
  const units = ["KB", "MB", "GB", "TB"];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

/** m:ss of SOURCE seconds. */
export function formatClock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds + 1e-6));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

// ── Elements (Compare rows, Merge Review copy) ──────────────────────────

/** [project.json key, noun] in timeline lane order, captions last. */
const ELEMENT_NOUNS: ReadonlyArray<readonly [string, string]> = [
  ["zoomRegions", "Zoom"],
  ["tiltRegions", "Tilt"],
  ["speedRegions", "Speed region"],
  ["blurRegions", "Blur"],
  ["highlightRegions", "Highlight"],
  ["focusRegions", "Depth focus"],
  ["cameraLayoutRegions", "Camera layout"],
  ["annotations", "Annotation"],
  ["voiceOverClips", "Voice-over"],
  ["subtitles", "Caption"],
];
const NOUN = new Map(ELEMENT_NOUNS);

const isObj = (v: unknown): v is JsonObject => v != null && typeof v === "object" && !Array.isArray(v);
const numOf = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

function findElement(doc: Json | undefined, collection: string, id: string): JsonObject | null {
  if (!isObj(doc)) return null;
  const list = doc[collection];
  if (!Array.isArray(list)) return null;
  for (const e of list) if (isObj(e) && e.id === id) return e;
  return null;
}

/** An element's [start, end] SOURCE seconds (voice-overs: start + duration). */
export function elementSpan(e: JsonObject | null): [number, number] | null {
  if (!e) return null;
  const start = numOf(e.startTime);
  if (start == null) return null;
  const end = numOf(e.endTime) ?? (numOf(e.duration) != null ? start + (numOf(e.duration) as number) : null);
  return [start, end ?? start];
}

function excerpt(text: unknown, max = 28): string | null {
  if (typeof text !== "string") return null;
  const t = text.replace(/\s+/g, " ").trim();
  if (!t) return null;
  return t.length > max ? `“${t.slice(0, max - 1)}…”` : `“${t}”`;
}

/** "Zoom 0:12–0:15", "Caption “Hello there” 0:03–0:05". */
export function describeElement(collection: string, e: JsonObject | null): string {
  const noun = NOUN.get(collection) ?? "Item";
  const quote = e ? excerpt(e.text) : null;
  const span = elementSpan(e);
  const range = span ? (span[1] > span[0] ? `${formatClock(span[0])}–${formatClock(span[1])}` : formatClock(span[0])) : null;
  return [noun, quote, range].filter(Boolean).join(" ");
}

// ── Compare (a client-side diff, grouped like the inspector) ─────────────

export interface CompareRow {
  id: string;
  text: string;
  /** Timeline rows: where to seek (SOURCE seconds). */
  sourceTime?: number;
  /** Settings rows: the inspector tab that edits it. */
  tab?: InspectorTabId;
}

export interface CompareGroup {
  id: string;
  title: string;
  rows: CompareRow[];
}

const humanize = (key: string) => {
  const words = key.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/_/g, " ").toLowerCase();
  return words.charAt(0).toUpperCase() + words.slice(1);
};

/** A few settings read better by their product name. */
const SETTING_NAMES: Record<string, string> = {
  backgroundType: "Background",
  aspectRatio: "Aspect ratio",
  exportSettings: "Export settings",
};

function formatValue(v: unknown): string | null {
  if (v === undefined || v === null) return "None";
  if (typeof v === "boolean") return v ? "On" : "Off";
  if (typeof v === "number") return Number.isInteger(v) ? String(v) : String(Math.round(v * 100) / 100);
  if (typeof v === "string") return v.length > 24 ? `${v.slice(0, 23)}…` : v || "None";
  return null; // objects/arrays: "changed"
}

function settingRow(key: string, a: unknown, b: unknown): string {
  const name = SETTING_NAMES[key] ?? humanize(key);
  const from = formatValue(a);
  const to = formatValue(b);
  return from != null && to != null ? `${name}: ${from} → ${to}` : `${name} changed`;
}

/** policy settings tab → [group id, title, inspector tab]. */
function tabGroup(tab: string): { id: string; title: string; tab?: InspectorTabId } {
  const inspector = INSPECTOR_TABS.find((t) => t.id === tab);
  if (inspector) return { id: inspector.id, title: inspector.title, tab: inspector.id };
  if (tab === "canvas") return { id: "canvas", title: "Canvas" };
  if (tab === "export") return { id: "export", title: "Export" };
  return { id: "other", title: "Other settings" };
}

const FIELD_ROWS: Record<string, string> = {
  videoClipSegments: "Clips edited",
  splitPoints: "Clips edited",
  sourceSegments: "Recording replaced",
  videoURL: "Recording replaced",
  duration: "Recording replaced",
  cursorDataURL: "Recording replaced",
  keystrokeDataURL: "Recording replaced",
  cameraVideoURL: "Recording replaced",
  cameraTimeOffset: "Camera offset changed",
  recordingSourceKind: "Recording replaced",
  stillTreatment: "Image/video mode changed",
  reminderDate: "Reminder changed",
};

/**
 * `a` → `b` as rows a person reads: "Zoom 0:12–0:15 added", "Background:
 * Gradient → Image". Groups: Timeline (clips, trim, lane items), each
 * inspector tab that changed (InspectorTab order, then Canvas / Export /
 * Other settings), Subtitles (caption style + captions), Project (name…).
 */
export function compareDocuments(a: Json, b: Json, cs: ChangeSet = diff(a, b)): CompareGroup[] {
  const groups = new Map<string, CompareGroup>();
  const group = (id: string, title: string) => {
    let g = groups.get(id);
    if (!g) {
      g = { id, title, rows: [] };
      groups.set(id, g);
    }
    return g;
  };
  const aObj = isObj(a) ? a : {};
  const bObj = isObj(b) ? b : {};

  // Timeline: clip structure / trim / recording fields first.
  const seenField = new Set<string>();
  for (const f of cs.fields) {
    if (f === "trimStart" || f === "trimEnd") {
      const from = numOf(aObj[f]);
      const to = numOf(bObj[f]);
      group("timeline", "Timeline").rows.push({
        id: `field:${f}`,
        text: `${f === "trimStart" ? "Trim start" : "Trim end"}: ${from != null ? formatClock(from) : "None"} → ${to != null ? formatClock(to) : "None"}`,
        sourceTime: to ?? from ?? undefined,
      });
      continue;
    }
    const text = FIELD_ROWS[f];
    if (!text || seenField.has(text)) continue;
    seenField.add(text);
    if (text === "Image/video mode changed" || text === "Reminder changed") continue; // Project group below
    group("timeline", "Timeline").rows.push({ id: `field:${f}`, text });
  }

  // Timeline lane items (captions go to Subtitles).
  for (const [key] of ELEMENT_NOUNS) {
    const c = cs.items[key];
    if (!c) continue;
    const g = key === "subtitles" ? group("subtitles", "Subtitles") : group("timeline", "Timeline");
    const noun = NOUN.get(key)!;
    if (c.replaced) {
      g.rows.push({ id: `${key}:replaced`, text: `${noun}s changed` });
      continue;
    }
    if (c.counts) {
      const n = c.counts;
      if (n.added) g.rows.push({ id: `${key}:added`, text: `${n.added} ${noun.toLowerCase()}${n.added === 1 ? "" : "s"} added` });
      if (n.removed) g.rows.push({ id: `${key}:removed`, text: `${n.removed} ${noun.toLowerCase()}${n.removed === 1 ? "" : "s"} removed` });
      if (n.changed) g.rows.push({ id: `${key}:changed`, text: `${n.changed} ${noun.toLowerCase()}${n.changed === 1 ? "" : "s"} edited` });
    }
    const row = (id: string, el: JsonObject | null, verb: string) => {
      const span = elementSpan(el);
      g.rows.push({ id: `${key}:${id}`, text: `${describeElement(key, el)} ${verb}`, sourceTime: span?.[0] });
    };
    for (const id of c.added ?? []) row(id, findElement(bObj, key, id), "added");
    for (const id of c.removed ?? []) row(id, findElement(aObj, key, id), "removed");
    for (const [id, fields] of Object.entries(c.changed ?? {})) {
      const el = findElement(bObj, key, id) ?? findElement(aObj, key, id);
      const what = fields.length ? ` — ${fields.slice(0, 3).map((f) => humanize(f).toLowerCase()).join(", ")}${fields.length > 3 ? "…" : ""}` : "";
      row(id, el, `edited${what}`);
    }
    if (c.reordered) g.rows.push({ id: `${key}:reordered`, text: `${noun}s reordered` });
  }

  // Settings, by the inspector tab that edits them.
  const aSettings = isObj(aObj.settings) ? aObj.settings : {};
  const bSettings = isObj(bObj.settings) ? bObj.settings : {};
  const tabOrder = [...INSPECTOR_TABS.map((t) => t.id as string), "canvas", "export", "other"];
  const tabs = Object.keys(cs.settings).sort((x, y) => (tabOrder.indexOf(x) === -1 ? 99 : tabOrder.indexOf(x)) - (tabOrder.indexOf(y) === -1 ? 99 : tabOrder.indexOf(y)));
  for (const tab of tabs) {
    const keys = cs.settings[tab];
    if (!keys?.length) continue;
    const t = tabGroup(tab);
    const g = group(t.id, t.title);
    for (const key of keys) {
      g.rows.push({
        id: `settings:${key}`,
        text: key === "*" ? "Settings changed" : settingRow(key, aSettings[key], bSettings[key]),
        tab: t.tab,
      });
    }
  }

  // Project fields.
  for (const f of cs.fields) {
    if (f === "name") {
      group("project", "Project").rows.push({ id: "field:name", text: `Renamed: ${formatValue(aObj.name) ?? "Untitled"} → ${formatValue(bObj.name) ?? "Untitled"}` });
    } else if (FIELD_ROWS[f] === "Image/video mode changed" || FIELD_ROWS[f] === "Reminder changed") {
      group("project", "Project").rows.push({ id: `field:${f}`, text: FIELD_ROWS[f] });
    } else if (!FIELD_ROWS[f] && f !== "trimStart" && f !== "trimEnd") {
      group("project", "Project").rows.push({ id: `field:${f}`, text: f === "*" ? "Document changed" : `${humanize(f)} changed` });
    }
  }
  for (const key of Object.keys(cs.items)) {
    if (NOUN.has(key)) continue;
    group("project", "Project").rows.push({ id: `${key}:other`, text: `${humanize(key)} changed` });
  }

  // Fixed group order: Timeline, inspector tabs, Canvas/Export/Other, Subtitles last among tabs, Project.
  const order = ["timeline", ...INSPECTOR_TABS.map((t) => t.id as string), "canvas", "export", "other", "project"];
  const rank = (id: string) => (id === "subtitles" ? order.indexOf("subtitles") : order.indexOf(id) === -1 ? 98 : order.indexOf(id));
  return [...groups.values()].filter((g) => g.rows.length).sort((x, y) => rank(x.id) - rank(y.id));
}

// ── Merge Review copy ───────────────────────────────────────────────────

const PATH_RE = /^([A-Za-z]+)\[([^\]]+)\](?:\.([A-Za-z]+)\[([^\]]+)\])?$/;

/** An element path from a conflict ("annotations[<id>]", "subtitles[<id>].words[<id>]") → its label. */
export function describePath(path: string, docs: ReadonlyArray<Json | undefined>): string {
  const m = PATH_RE.exec(path);
  if (!m) return humanize(path.replace(/[{}]/g, "").split(",")[0] ?? path);
  const [, collection, id, nested, nestedId] = m;
  const el = docs.map((d) => findElement(d, collection, id)).find(Boolean) ?? null;
  if (nested === "words" && nestedId) return `A word in ${describeElement(collection, el)}`;
  return describeElement(collection, el);
}

const LANE_NAMES: Record<string, string> = { effects: "effects", focus: "focus", speed: "speed" };

/** What one conflict is about, and what each side means — Merge Review's row copy. */
export function describeConflict(
  c: MergeConflict,
  docs: { base: Json | undefined; mine: Json | undefined; theirs: Json | undefined },
  theirName = "the other editor",
): { title: string; detail: string; mine: string; theirs: string } {
  const all = [docs.mine, docs.theirs, docs.base];
  switch (c.kind) {
    case "clipStructure":
      return {
        title: "Clips and trim",
        detail: `You and ${theirName} both split, trimmed or removed clips.`,
        mine: "Keep your clips",
        theirs: "Use their clips",
      };
    case "deleteVsModify": {
      const what = describePath(c.path, all);
      return c.deletedBy === "mine"
        ? { title: what, detail: `You deleted it; ${theirName} edited it.`, mine: "Delete it", theirs: "Keep their edit" }
        : { title: what, detail: `${capitalize(theirName)} deleted it; you edited it.`, mine: "Keep your edit", theirs: "Delete it" };
    }
    case "subtitlesRegenerated": {
      const by = c.regeneratedBy === "mine" ? "You regenerated" : c.regeneratedBy === "theirs" ? `${capitalize(theirName)} regenerated` : "Both of you regenerated";
      return { title: "Captions", detail: `${by} the captions while the other side edited them.`, mine: "Keep your captions", theirs: "Use their captions" };
    }
    case "laneOverlap": {
      const [x, y] = c.elements ?? [];
      const lane = LANE_NAMES[c.lane ?? ""] ?? c.lane ?? "timeline";
      return {
        title: `${x ? describePath(x, all) : "A block"} and ${y ? describePath(y, all) : "another"}`,
        detail: `Together they would overlap on the ${lane} lane.`,
        mine: "Your timing",
        theirs: "Their timing",
      };
    }
  }
}

function capitalize(s: string): string {
  return s ? s[0].toUpperCase() + s.slice(1) : s;
}

/** "zoomRegions[<id>].{startTime,endTime}" → "Zoom 0:12–0:15 timing" (auto-resolved list). */
export function describeAutoResolved(path: string, docs: ReadonlyArray<Json | undefined>): string {
  const m = /^([A-Za-z]+\[[^\]]+\])(?:\.(.+))?$/.exec(path);
  if (m) {
    const el = describePath(m[1], docs);
    const rest = m[2] ? m[2].replace(/[{}]/g, "").split(",").map((k) => (k === "startTime" || k === "endTime" ? "timing" : humanize(k).toLowerCase())) : [];
    const uniq = [...new Set(rest)];
    return uniq.length ? `${el}: ${uniq.join(", ")}` : el;
  }
  const parts = path.split(".");
  const last = parts[parts.length - 1].replace(/[{}]/g, "").split(",")[0];
  return parts[0] === "settings" ? SETTING_NAMES[last] ?? humanize(last) : humanize(last || path);
}

// ── Controller ──────────────────────────────────────────────────────────

export type HistoryMode = "list" | "compare" | "review";
/** gated: the plan has no cloud history (upsell); unavailable: no history API for this project. */
export type HistoryStatus = "idle" | "loading" | "ready" | "gated" | "unavailable" | "error";

export interface CompareState {
  fromLabel: string;
  toLabel: string;
  groups: CompareGroup[];
  loading: boolean;
  error: string | null;
}

export interface HistoryState {
  open: boolean;
  mode: HistoryMode;
  status: HistoryStatus;
  error: string | null;
  versions: ProjectVersion[];
  headVersionId: string | null;
  retention: HistoryRetention | null;
  pinnedMediaBytes: number;
  nextBefore: string | null;
  loadingMore: boolean;
  /** "Compare with…" armed on this version: the next row picked is compared with it. */
  comparePick: string | null;
  compare: CompareState | null;
  /** Row whose inline name field is open. */
  naming: string | null;
  /** Row with a request in flight (preview / restore / name / delete). */
  busy: string | null;
  /** A failed action, said in the pane (dismissed by the next action). */
  message: string | null;
  /** The author of the last clean merge ("Ana (Web)"), for the callout. */
  mergedFrom: { noticeId: number; who: string } | null;
  /** Who made the server version under Merge Review ("Ana"), when known. */
  reviewAuthor: string | null;
}

export interface HistoryControllerOptions {
  store: EditorStore;
  api: HistoryApi;
  /** Owner-only actions (Delete, Free up). */
  isOwner: boolean;
  /** The project's media (preview resolves through the version's manifest). */
  media?: { setOverride(urls: { media: VersionDetail["media"]; sources: VersionDetail["sources"] } | null): void; readonly hasOverride: boolean } | null;
  /** AlertPresenter.present-shaped confirm (index 0 = the default button). */
  confirm?: (spec: { title: string; message?: string; buttons?: Array<{ title: string; role?: "primary" | "secondary" | "destructive" }> }) => Promise<number>;
  /** Compare row → the timeline (SOURCE seconds). */
  seekSource?: (t: number) => void;
  revealTab?: (tab: InspectorTabId) => void;
  /** Refresh debounce after a save lands (ms). */
  refreshDelayMs?: number;
}

const INITIAL: HistoryState = {
  open: false,
  mode: "list",
  status: "idle",
  error: null,
  versions: [],
  headVersionId: null,
  retention: null,
  pinnedMediaBytes: 0,
  nextBefore: null,
  loadingMore: false,
  comparePick: null,
  compare: null,
  naming: null,
  busy: null,
  message: null,
  mergedFrom: null,
  reviewAuthor: null,
};

const PAGE = 50;

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** A 403 that is about the plan (requireEntitlement's "This feature requires a … plan"). */
function isPlanGate(e: unknown): boolean {
  if (!(e instanceof CloudApiError) || (e.status !== 403 && e.status !== 402)) return false;
  return /plan|upgrade|pro\b/i.test(e.message) || /plan|upgrade|entitlement/i.test(e.code ?? "");
}

export class HistoryController {
  private state: HistoryState = INITIAL;
  private listeners = new Set<() => void>();
  private readonly opts: HistoryControllerOptions;
  private details = new Map<string, Promise<VersionDetail>>();
  private refreshTimer: ReturnType<typeof setTimeout> | null = null;
  private listSeq = 0;
  private unsubscribe: () => void;

  constructor(opts: HistoryControllerOptions) {
    this.opts = opts;
    let lastRevision = opts.store.getState().revision;
    let lastNotice = opts.store.getState().mergeNotice?.id ?? 0;
    let lastSync = opts.store.getState().sync;
    this.unsubscribe = opts.store.subscribe(() => {
      const s = opts.store.getState();
      // Preview ended elsewhere (a merge, a restore) → drop the version's media map.
      if (!s.preview && opts.media?.hasOverride) opts.media.setOverride(null);
      // Merge Review opens itself; it closes back to the list once resolved.
      if (s.sync === "review" && lastSync !== "review") {
        this.set({ open: true, mode: "review", comparePick: null, reviewAuthor: null });
        const rev = s.review?.serverRevision;
        if (rev != null) {
          void this.authorOf(rev).then((v) => {
            if (v && opts.store.getState().review?.serverRevision === rev) this.set({ reviewAuthor: v.actorName ?? null });
          });
        }
      }
      else if (s.sync !== "review" && lastSync === "review" && this.state.mode === "review") this.set({ mode: "list" });
      lastSync = s.sync;
      if (s.mergeNotice && s.mergeNotice.id !== lastNotice) {
        lastNotice = s.mergeNotice.id;
        void this.resolveMergeAuthor(s.mergeNotice.id, s.mergeNotice.serverRevision);
      }
      if (s.revision !== lastRevision) {
        lastRevision = s.revision;
        if (this.state.open && this.state.status === "ready") this.scheduleRefresh();
      }
    });
  }

  dispose(): void {
    this.unsubscribe();
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    this.listeners.clear();
  }

  getState = (): HistoryState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private set(patch: Partial<HistoryState>) {
    this.state = { ...this.state, ...patch };
    for (const l of [...this.listeners]) l();
  }

  get isOwner(): boolean {
    return this.opts.isOwner;
  }

  // ── Pane ──────────────────────────────────────────────────────────────

  open(): void {
    const review = this.opts.store.getState().sync === "review";
    this.set({ open: true, mode: review ? "review" : this.state.mode === "review" ? "list" : this.state.mode, message: null });
    if (this.state.status === "idle" || this.state.status === "error") void this.refresh();
    else if (this.state.status === "ready") this.scheduleRefresh(0);
  }

  close(): void {
    this.set({ open: false, comparePick: null, naming: null, message: null });
  }

  toggle(): void {
    if (this.state.open) this.close();
    else this.open();
  }

  showList(): void {
    this.set({ mode: "list", compare: null, comparePick: null });
  }

  dismissMessage(): void {
    if (this.state.message) this.set({ message: null });
  }

  private scheduleRefresh(delay = this.opts.refreshDelayMs ?? 1200): void {
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      void this.refresh();
    }, delay);
  }

  /** (Re)load the first page. The list stays on screen while it refreshes. */
  async refresh(): Promise<void> {
    const seq = ++this.listSeq;
    if (this.state.status !== "ready") this.set({ status: "loading", error: null });
    try {
      const page = await this.opts.api.list({ limit: PAGE });
      if (seq !== this.listSeq) return;
      const gated = page.retention != null && page.retention.days <= 0 && page.retention.maxNamed <= 0;
      this.set({
        status: gated ? "gated" : "ready",
        error: null,
        versions: page.versions,
        headVersionId: page.headVersionId ?? page.versions[0]?.id ?? null,
        retention: page.retention,
        pinnedMediaBytes: page.pinnedMediaBytes,
        nextBefore: page.nextBefore ?? (page.versions.length >= PAGE ? String(page.versions[page.versions.length - 1].seq) : null),
      });
    } catch (e) {
      if (seq !== this.listSeq) return;
      if (isPlanGate(e)) this.set({ status: "gated", error: null });
      else if (e instanceof CloudApiError && e.status === 404) this.set({ status: "unavailable", error: null });
      else this.set({ status: this.state.status === "ready" ? "ready" : "error", error: errorText(e) });
    }
  }

  async loadMore(): Promise<void> {
    const before = this.state.nextBefore;
    if (!before || this.state.loadingMore) return;
    this.set({ loadingMore: true });
    try {
      const page = await this.opts.api.list({ before, limit: PAGE });
      const known = new Set(this.state.versions.map((v) => v.id));
      this.set({
        versions: [...this.state.versions, ...page.versions.filter((v) => !known.has(v.id))],
        nextBefore: page.nextBefore ?? (page.versions.length >= PAGE ? String(page.versions[page.versions.length - 1].seq) : null),
        loadingMore: false,
      });
    } catch (e) {
      this.set({ loadingMore: false, message: errorText(e) });
    }
  }

  private detail(versionId: string): Promise<VersionDetail> {
    let d = this.details.get(versionId);
    if (!d) {
      d = this.opts.api.get(versionId);
      d.catch(() => this.details.delete(versionId));
      this.details.set(versionId, d);
    }
    return d;
  }

  version(id: string): ProjectVersion | undefined {
    return this.state.versions.find((v) => v.id === id);
  }

  // ── Preview ───────────────────────────────────────────────────────────

  /** Show a version read-only; its media resolves through its own manifest. */
  async preview(versionId: string): Promise<void> {
    const store = this.opts.store;
    this.set({ busy: versionId, message: null });
    try {
      // Unsaved edits reach the server first — the live project is what "Back to current" returns to.
      if (!store.getState().preview) await store.flush();
      const d = await this.detail(versionId);
      this.opts.media?.setOverride({ media: d.media, sources: d.sources });
      store.previewVersion({ versionId, title: versionTitle(this.version(versionId) ?? d.version), text: d.document });
    } catch (e) {
      if (!store.getState().preview) this.opts.media?.setOverride(null);
      this.set({ message: `Couldn’t open that version: ${errorText(e)}` });
    } finally {
      this.set({ busy: null });
    }
  }

  backToCurrent(): void {
    this.opts.store.exitPreview();
    this.opts.media?.setOverride(null);
  }

  // ── Restore ───────────────────────────────────────────────────────────

  /**
   * Confirm, then POST restore against the current revision. Lands as one
   * undo step ("Restore Version"); the current version stays in History.
   * Returns true when restored.
   */
  async restore(versionId: string): Promise<boolean> {
    const store = this.opts.store;
    const s = store.getState();
    if (s.sync === "review" || s.sync === "conflict") {
      this.set({ message: "Finish reviewing the merge before restoring a version." });
      return false;
    }
    const v = this.version(versionId);
    const choice = await this.ask({
      title: "Restore this version?",
      message: `${v ? versionTitle(v) : "This version"} becomes the current project. Your current version stays in History.`,
      buttons: [{ title: "Restore", role: "primary" }, { title: "Cancel" }],
    });
    if (choice !== 0) return false;
    this.set({ busy: versionId, message: null });
    try {
      await store.flush();
      const now = store.getState();
      if (now.conflict || now.revision == null) {
        this.set({ message: "This project changed elsewhere — review the merge, then restore again." });
        return false;
      }
      const result = await this.opts.api.restore(versionId, now.revision);
      if (!result.ok) {
        // Someone saved first: merge their version in; the user restores again if still wanted.
        store.handleConflict({ serverRevision: result.revision, serverDocument: result.document, updatedAt: result.updatedAt });
        this.set({ message: "Someone saved while you were restoring. Their changes were merged — restore again if you still want this version." });
        return false;
      }
      const text = result.document ?? (await this.detail(versionId)).document;
      store.applyRestore({ text, revision: result.revision });
      this.opts.media?.setOverride(null);
      void this.refresh();
      return true;
    } catch (e) {
      this.set({ message: `Couldn’t restore: ${errorText(e)}` });
      return false;
    } finally {
      this.set({ busy: null });
    }
  }

  // ── Name ──────────────────────────────────────────────────────────────

  startNaming(versionId: string): void {
    this.set({ naming: versionId, message: null });
  }

  cancelNaming(): void {
    if (this.state.naming) this.set({ naming: null });
  }

  /** Enter in the row's field: PATCH the label (empty = unname). */
  async commitName(versionId: string, label: string): Promise<boolean> {
    const trimmed = label.trim().slice(0, 120);
    const v = this.version(versionId);
    this.set({ naming: null });
    if (v && (v.label ?? "") === trimmed) return true;
    this.set({ busy: versionId, message: null });
    try {
      const updated = await this.opts.api.name(versionId, trimmed || null);
      this.set({
        versions: this.state.versions.map((x) => (x.id === versionId ? (updated ?? { ...x, label: trimmed || null }) : x)),
      });
      return true;
    } catch (e) {
      this.set({ message: `Couldn’t name it: ${errorText(e)}` });
      return false;
    } finally {
      this.set({ busy: null });
    }
  }

  // ── Delete / Free up (owner) ──────────────────────────────────────────

  async remove(versionId: string): Promise<boolean> {
    if (!this.isOwner || versionId === this.state.headVersionId) return false;
    const v = this.version(versionId);
    const choice = await this.ask({
      title: "Delete this version?",
      message: `${v ? versionTitle(v) : "This version"} is removed from History for everyone. This can’t be undone.`,
      buttons: [{ title: "Delete", role: "destructive" }, { title: "Cancel" }],
    });
    if (choice !== 0) return false;
    this.set({ busy: versionId, message: null });
    try {
      await this.opts.api.remove(versionId);
      this.details.delete(versionId);
      this.set({ versions: this.state.versions.filter((x) => x.id !== versionId) });
      void this.refresh();
      return true;
    } catch (e) {
      this.set({ message: `Couldn’t delete: ${errorText(e)}` });
      return false;
    } finally {
      this.set({ busy: null });
    }
  }

  /**
   * "History keeps X of removed media [Free up]": delete the unnamed
   * versions (never the current one) so the media only they keep is
   * released. Named versions stay.
   */
  async freeUp(): Promise<number> {
    if (!this.isOwner) return 0;
    const victims = this.state.versions.filter((v) => !v.label && v.id !== this.state.headVersionId);
    if (!victims.length) return 0;
    const choice = await this.ask({
      title: `Free up ${formatBytes(this.state.pinnedMediaBytes)}?`,
      message: `Deletes ${victims.length} unnamed version${victims.length === 1 ? "" : "s"} and the removed media only they keep. Named versions and the current version stay.`,
      buttons: [{ title: "Free Up", role: "destructive" }, { title: "Cancel" }],
    });
    if (choice !== 0) return 0;
    this.set({ busy: "free-up", message: null });
    let done = 0;
    try {
      for (const v of victims) {
        await this.opts.api.remove(v.id);
        this.details.delete(v.id);
        done++;
      }
    } catch (e) {
      this.set({ message: `Freed ${done} of ${victims.length}: ${errorText(e)}` });
    } finally {
      this.set({ busy: null });
      await this.refresh();
    }
    return done;
  }

  // ── Compare ───────────────────────────────────────────────────────────

  /** Compare a version with the current (live) document. */
  async compareWithCurrent(versionId: string): Promise<void> {
    const v = this.version(versionId);
    this.set({
      mode: "compare",
      comparePick: null,
      compare: { fromLabel: v ? versionTitle(v) : "Version", toLabel: "Current", groups: [], loading: true, error: null },
    });
    try {
      const d = await this.detail(versionId);
      // The live document, even while another version is previewed.
      const live = this.opts.store.liveDocumentJSON() as Json;
      this.set({ compare: { ...this.state.compare!, groups: compareDocuments(JSON.parse(d.document) as Json, live), loading: false } });
    } catch (e) {
      this.set({ compare: { ...this.state.compare!, loading: false, error: errorText(e) } });
    }
  }

  /** "Compare with…": arm this row; the next row picked is compared with it. */
  armCompare(versionId: string): void {
    this.set({ comparePick: versionId, message: null });
  }

  cancelCompare(): void {
    this.set({ comparePick: null });
  }

  /** The second pick: older → newer. */
  async compareVersions(aId: string, bId: string): Promise<void> {
    const a = this.version(aId);
    const b = this.version(bId);
    const [older, newer] = (a?.seq ?? 0) <= (b?.seq ?? 0) ? [aId, bId] : [bId, aId];
    const vo = this.version(older);
    const vn = this.version(newer);
    this.set({
      mode: "compare",
      comparePick: null,
      compare: { fromLabel: vo ? versionTitle(vo) : "Version", toLabel: vn ? versionTitle(vn) : "Version", groups: [], loading: true, error: null },
    });
    try {
      const [x, y] = await Promise.all([this.detail(older), this.detail(newer)]);
      this.set({ compare: { ...this.state.compare!, groups: compareDocuments(JSON.parse(x.document) as Json, JSON.parse(y.document) as Json), loading: false } });
    } catch (e) {
      this.set({ compare: { ...this.state.compare!, loading: false, error: errorText(e) } });
    }
  }

  /** A row was picked: complete an armed "Compare with…", else nothing. */
  pick(versionId: string): boolean {
    const armed = this.state.comparePick;
    if (!armed || armed === versionId) return false;
    void this.compareVersions(armed, versionId);
    return true;
  }

  /** Compare row clicked: seek there / reveal its tab. */
  goTo(row: CompareRow): void {
    if (row.sourceTime != null) this.opts.seekSource?.(row.sourceTime);
    if (row.tab) this.opts.revealTab?.(row.tab);
  }

  // ── Merge callout ─────────────────────────────────────────────────────

  /** The version holding a server revision (its head, or within its range). */
  private async authorOf(revision: number): Promise<ProjectVersion | null> {
    try {
      const page = await this.opts.api.list({ limit: 10 });
      return (
        page.versions.find((x) => x.revision === revision) ??
        page.versions.find((x) => x.firstRevision <= revision && revision <= x.revision) ??
        null
      );
    } catch {
      return null;
    }
  }

  private async resolveMergeAuthor(noticeId: number, revision: number): Promise<void> {
    try {
      const v = await this.authorOf(revision);
      if (!v) return;
      const client = clientName(v);
      const who = v.source === "agent" ? `an agent${client ? ` (${client})` : ""}` : `${v.actorName ?? "a teammate"}${client ? ` (${client})` : ""}`;
      if (this.opts.store.getState().mergeNotice?.id === noticeId) this.set({ mergedFrom: { noticeId, who } });
    } catch {
      // The callout says "Merged N changes" without a name.
    }
  }

  private async ask(spec: Parameters<NonNullable<HistoryControllerOptions["confirm"]>>[0]): Promise<number> {
    return this.opts.confirm ? this.opts.confirm(spec) : 0;
  }
}

/** The pane text for the merge callout: "Merged 2 changes from Ana (Web)". */
export function mergedCalloutTitle(count: number, who: string | null): string {
  const from = who ? ` from ${who}` : "";
  if (count <= 0) return `Merged${from ? ` with changes${from}` : " changes"}`;
  return `Merged ${count} change${count === 1 ? "" : "s"}${from}`;
}

// ── React binding ─────────────────────────────────────────────────────────

export function useHistory<T>(controller: HistoryController, selector: (s: HistoryState) => T): T {
  return useSyncExternalStore(
    controller.subscribe,
    () => selector(controller.getState()),
    () => selector(controller.getState()),
  );
}
