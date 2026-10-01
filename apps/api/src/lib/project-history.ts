/**
 * Cloud-project history (docs/project-history.md §6) — the rules, as pure
 * functions. No D1, no R2, no Hono: the data layer is
 * lib/project-history-db.ts and the routes are routes/cloud-project-history.ts
 * plus the save handler in routes/cloud-projects.ts.
 *
 *   REVISION  the CAS counter (If-Match), one per save — unchanged.
 *   VERSION   a retained checkpoint: a D1 row + a full gzipped snapshot of
 *             project.json in R2 + the media manifest it was saved against.
 *             A save EXTENDS the head version (coalescing, `shouldExtend`) or
 *             opens a new one.
 *
 * The first half of this file is a COPY of the web merge core's change-set
 * code (apps/web/src/editor/core/merge/{jsonMerge,projectDiff}.ts): the API
 * cannot import web code, and only these pure functions are needed here —
 * canonical JSON, `composeChangeSets`, `changeSetJSON`, the `X-CC-Change`
 * header codec. `project-history.test.ts` pins this copy to the web core's
 * golden vectors (golden/mergePolicy.json, written by the Swift twin), so the
 * three implementations cannot drift apart silently. Edit the web core first,
 * regenerate its golden, then copy the change here.
 */

// ═══════════════════════════════════════════════════════════════════════════
// COPY of apps/web/src/editor/core/merge/jsonMerge.ts (the parts compose and
// the header codec use). Keep byte-for-byte equivalent behaviour.
// ═══════════════════════════════════════════════════════════════════════════

export type Json = null | boolean | number | string | Json[] | JsonObject;
export interface JsonObject {
  [key: string]: Json;
}

export function isJsonObject(v: Json | undefined): v is JsonObject {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Own-property read (never an inherited `constructor`/`toString`). */
export function getKey(o: Json | undefined, key: string): Json | undefined {
  return isJsonObject(o) && Object.hasOwn(o, key) ? o[key] : undefined;
}

/** Sorted, de-duplicated union of string lists (UTF-16 code-unit order). */
export function sortedUnion(...lists: readonly (readonly string[])[]): string[] {
  const set = new Set<string>();
  for (const l of lists) for (const s of l) set.add(s);
  return [...set].sort();
}

/** ECMAScript Number::toString; -0 → "0". Non-finite numbers are not JSON. */
export function canonicalNumber(n: number): string {
  if (!Number.isFinite(n)) throw new Error(`canonicalJSON: non-finite number ${String(n)}`);
  if (n === 0) return "0";
  return String(n);
}

export function canonicalString(s: string): string {
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 0x22) out += '\\"';
    else if (c === 0x5c) out += "\\\\";
    else if (c < 0x20) {
      switch (c) {
        case 0x08:
          out += "\\b";
          break;
        case 0x0c:
          out += "\\f";
          break;
        case 0x0a:
          out += "\\n";
          break;
        case 0x0d:
          out += "\\r";
          break;
        case 0x09:
          out += "\\t";
          break;
        default:
          out += "\\u" + c.toString(16).padStart(4, "0");
      }
    } else out += s[i];
  }
  return out + '"';
}

/** Keys sorted by UTF-16 code units, no whitespace (docs/project-history.md §3). */
export function canonicalJSON(v: Json): string {
  if (v === null) return "null";
  switch (typeof v) {
    case "boolean":
      return v ? "true" : "false";
    case "number":
      return canonicalNumber(v);
    case "string":
      return canonicalString(v);
  }
  if (Array.isArray(v)) return "[" + v.map(canonicalJSON).join(",") + "]";
  const obj = v as JsonObject;
  return (
    "{" +
    Object.keys(obj)
      .sort()
      .map((k) => canonicalString(k) + ":" + canonicalJSON(obj[k]))
      .join(",") +
    "}"
  );
}

const FNV_OFFSET = 0xcbf29ce484222325n;
const FNV_PRIME = 0x100000001b3n;
const U64 = 0xffffffffffffffffn;

/** FNV-1a 64 over the UTF-8 bytes of `text`, as 16 lowercase hex digits. */
export function fnv1a64Hex(text: string): string {
  let h = FNV_OFFSET;
  for (const byte of new TextEncoder().encode(text)) {
    h ^= BigInt(byte);
    h = (h * FNV_PRIME) & U64;
  }
  return h.toString(16).padStart(16, "0");
}

// ═══════════════════════════════════════════════════════════════════════════
// COPY of apps/web/src/editor/core/merge/projectDiff.ts (everything but
// `diff`, which needs the policy table — the API never diffs documents; the
// client sends the change-set in `X-CC-Change`).
// ═══════════════════════════════════════════════════════════════════════════

export interface ChangeCounts {
  added: number;
  removed: number;
  changed: number;
}

/** One id collection's changes: exact, truncated (`counts`) or `replaced`. */
export interface CollectionChange {
  added?: string[];
  removed?: string[];
  changed?: Record<string, string[]>;
  counts?: ChangeCounts;
  reordered?: boolean;
  replaced?: boolean;
}

export interface ChangeSet {
  v: 1;
  items: Record<string, CollectionChange>;
  settings: Record<string, string[]>;
  fields: string[];
}

export const CHANGE_SET_VERSION = 1;
export const CHANGE_HEADER_MAX_BYTES = 8192;

export function emptyChangeSet(): ChangeSet {
  return { v: 1, items: {}, settings: {}, fields: [] };
}

export function isEmptyChangeSet(cs: ChangeSet): boolean {
  return Object.keys(cs.items).length === 0 && Object.keys(cs.settings).length === 0 && cs.fields.length === 0;
}

export function countsOf(c: CollectionChange): ChangeCounts {
  if (c.replaced) return { added: 0, removed: 0, changed: 0 };
  if (c.counts) return { ...c.counts };
  return {
    added: c.added?.length ?? 0,
    removed: c.removed?.length ?? 0,
    changed: c.changed ? Object.keys(c.changed).length : 0,
  };
}

/** Canonical shape; null when the entry carries no change. */
export function normalizeCollectionChange(c: CollectionChange): CollectionChange | null {
  if (c.replaced) return { replaced: true };
  const reordered = c.reordered === true;
  if (c.counts) {
    const counts = { added: c.counts.added, removed: c.counts.removed, changed: c.counts.changed };
    if (counts.added === 0 && counts.removed === 0 && counts.changed === 0 && !reordered) return null;
    return reordered ? { counts, reordered: true } : { counts };
  }
  const out: CollectionChange = {};
  const added = sortedUnion(c.added ?? []);
  const removed = sortedUnion(c.removed ?? []);
  if (added.length) out.added = added;
  if (removed.length) out.removed = removed;
  const ids = Object.keys(c.changed ?? {}).sort();
  if (ids.length) {
    const changed: Record<string, string[]> = {};
    for (const id of ids) changed[id] = sortedUnion(c.changed![id]);
    out.changed = changed;
  }
  if (reordered) out.reordered = true;
  return Object.keys(out).length ? out : null;
}

type Status = { kind: "added" } | { kind: "removed" } | { kind: "changed"; fields: string[] };

function composeCollection(x: CollectionChange, y: CollectionChange): CollectionChange {
  if (x.replaced || y.replaced) return { replaced: true };
  const reordered = x.reordered === true || y.reordered === true;
  if (x.counts || y.counts) {
    const a = countsOf(x);
    const b = countsOf(y);
    return {
      counts: { added: a.added + b.added, removed: a.removed + b.removed, changed: a.changed + b.changed },
      reordered,
    };
  }
  const status = new Map<string, Status>();
  for (const id of x.added ?? []) status.set(id, { kind: "added" });
  for (const id of x.removed ?? []) status.set(id, { kind: "removed" });
  for (const [id, fields] of Object.entries(x.changed ?? {})) status.set(id, { kind: "changed", fields: [...fields] });
  for (const id of y.added ?? []) {
    const s = status.get(id);
    if (s?.kind === "removed") status.set(id, { kind: "changed", fields: [] });
    else if (!s) status.set(id, { kind: "added" });
  }
  for (const id of y.removed ?? []) {
    if (status.get(id)?.kind === "added") status.delete(id);
    else status.set(id, { kind: "removed" });
  }
  for (const [id, fields] of Object.entries(y.changed ?? {})) {
    const s = status.get(id);
    if (s?.kind === "added") continue;
    if (s?.kind === "changed") status.set(id, { kind: "changed", fields: sortedUnion(s.fields, fields) });
    else status.set(id, { kind: "changed", fields: [...fields] });
  }
  const added: string[] = [];
  const removed: string[] = [];
  const changed: Record<string, string[]> = {};
  for (const [id, s] of status) {
    if (s.kind === "added") added.push(id);
    else if (s.kind === "removed") removed.push(id);
    else changed[id] = s.fields;
  }
  return { added, removed, changed, reordered };
}

/** `x` (a → b) then `y` (b → c) as one change-set a → c. */
export function composeChangeSets(x: ChangeSet, y: ChangeSet): ChangeSet {
  const out = emptyChangeSet();
  for (const key of sortedUnion(Object.keys(x.items), Object.keys(y.items))) {
    const cx = Object.hasOwn(x.items, key) ? x.items[key] : undefined;
    const cy = Object.hasOwn(y.items, key) ? y.items[key] : undefined;
    const composed = cx && cy ? composeCollection(cx, cy) : (cx ?? cy)!;
    const entry = normalizeCollectionChange(composed);
    if (entry) out.items[key] = entry;
  }
  for (const tab of sortedUnion(Object.keys(x.settings), Object.keys(y.settings))) {
    const keys = sortedUnion(
      Object.hasOwn(x.settings, tab) ? x.settings[tab] : [],
      Object.hasOwn(y.settings, tab) ? y.settings[tab] : [],
    );
    if (keys.length) out.settings[tab] = keys;
  }
  out.fields = sortedUnion(x.fields, y.fields);
  return out;
}

function collectionChangeJSON(c: CollectionChange): Json {
  const n = normalizeCollectionChange(c);
  if (!n) return {};
  const out: JsonObject = {};
  if (n.replaced) out.replaced = true;
  if (n.counts) out.counts = { added: n.counts.added, removed: n.counts.removed, changed: n.counts.changed };
  if (n.added) out.added = [...n.added];
  if (n.removed) out.removed = [...n.removed];
  if (n.changed) {
    const changed: JsonObject = {};
    for (const [id, fields] of Object.entries(n.changed)) changed[id] = [...fields];
    out.changed = changed;
  }
  if (n.reordered) out.reordered = true;
  return out;
}

export function changeSetJSON(cs: ChangeSet): Json {
  const items: JsonObject = {};
  for (const key of Object.keys(cs.items).sort()) {
    if (normalizeCollectionChange(cs.items[key])) items[key] = collectionChangeJSON(cs.items[key]);
  }
  const settings: JsonObject = {};
  for (const tab of Object.keys(cs.settings).sort()) {
    const keys = sortedUnion(cs.settings[tab]);
    if (keys.length) settings[tab] = keys;
  }
  return { v: CHANGE_SET_VERSION, items, settings, fields: sortedUnion(cs.fields) };
}

function stringList(v: Json | undefined): string[] | null {
  if (v === undefined) return [];
  if (!Array.isArray(v)) return null;
  for (const s of v) if (typeof s !== "string") return null;
  return v as string[];
}

function count(v: Json | undefined): number | null {
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null;
}

function collectionChangeFromJSON(v: Json): CollectionChange | null {
  if (!isJsonObject(v)) return null;
  if (getKey(v, "replaced") === true) return { replaced: true };
  const reordered = getKey(v, "reordered") === true;
  const counts = getKey(v, "counts");
  if (counts !== undefined) {
    if (!isJsonObject(counts)) return null;
    const added = count(getKey(counts, "added"));
    const removed = count(getKey(counts, "removed"));
    const changed = count(getKey(counts, "changed"));
    if (added === null || removed === null || changed === null) return null;
    return { counts: { added, removed, changed }, reordered };
  }
  const added = stringList(getKey(v, "added"));
  const removed = stringList(getKey(v, "removed"));
  if (!added || !removed) return null;
  const changedJSON = getKey(v, "changed");
  const changed: Record<string, string[]> = {};
  if (changedJSON !== undefined) {
    if (!isJsonObject(changedJSON)) return null;
    for (const id of Object.keys(changedJSON)) {
      const fields = stringList(changedJSON[id]);
      if (!fields) return null;
      changed[id] = fields;
    }
  }
  return { added, removed, changed, reordered };
}

/** Parses + validates a change-set JSON value; null when malformed. */
export function changeSetFromJSON(v: Json): ChangeSet | null {
  if (!isJsonObject(v) || getKey(v, "v") !== CHANGE_SET_VERSION) return null;
  const out = emptyChangeSet();
  const items = getKey(v, "items") ?? {};
  const settings = getKey(v, "settings") ?? {};
  if (!isJsonObject(items) || !isJsonObject(settings)) return null;
  for (const key of Object.keys(items).sort()) {
    const c = collectionChangeFromJSON(items[key]);
    if (!c) return null;
    const n = normalizeCollectionChange(c);
    if (n) out.items[key] = n;
  }
  for (const tab of Object.keys(settings).sort()) {
    const keys = stringList(settings[tab]);
    if (!keys) return null;
    if (keys.length) out.settings[tab] = sortedUnion(keys);
  }
  const fields = stringList(getKey(v, "fields"));
  if (!fields) return null;
  out.fields = sortedUnion(fields);
  return out;
}

function base64url(text: string): string {
  let binary = "";
  for (const byte of new TextEncoder().encode(text)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text: string): string | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  try {
    const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    // ignoreBOM: false is the web default (the Workers types want it spelled out).
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
  } catch {
    return null;
  }
}

function idPayload(c: CollectionChange): number {
  return (c.added?.length ?? 0) + (c.removed?.length ?? 0) + (c.changed ? Object.keys(c.changed).length : 0);
}

/**
 * Shrink a change-set until its canonical JSON `fits`: the exact collection
 * with the most ids (ties → first key in sorted order) degrades to counts,
 * repeatedly; then every settings tab collapses to ["*"]; null when it still
 * does not fit. This is `encodeChangeHeader`'s degradation order, shared so
 * the stored `change_json` cap degrades exactly the way the header does.
 */
function fitChangeSet(cs: ChangeSet, fits: (canonical: string) => boolean): string | null {
  const current: ChangeSet = {
    v: 1,
    items: { ...cs.items },
    settings: { ...cs.settings },
    fields: [...cs.fields],
  };
  for (;;) {
    const canonical = canonicalJSON(changeSetJSON(current));
    if (fits(canonical)) return canonical;
    let best: string | null = null;
    let bestSize = -1;
    for (const key of Object.keys(current.items).sort()) {
      const c = current.items[key];
      if (c.replaced || c.counts) continue;
      const size = idPayload(c);
      if (size > bestSize) {
        best = key;
        bestSize = size;
      }
    }
    if (best !== null) {
      const c = current.items[best];
      current.items[best] = c.reordered ? { counts: countsOf(c), reordered: true } : { counts: countsOf(c) };
      continue;
    }
    const tabs = Object.keys(current.settings);
    if (tabs.some((t) => current.settings[t].length !== 1 || current.settings[t][0] !== "*")) {
      const collapsed: Record<string, string[]> = {};
      for (const t of tabs) collapsed[t] = ["*"];
      current.settings = collapsed;
      continue;
    }
    return null;
  }
}

/**
 * `X-CC-Change` value: base64url (no padding) of the change-set's canonical
 * JSON, at most `maxBytes` characters (degrading per `fitChangeSet`); null =
 * send no header.
 */
export function encodeChangeHeader(cs: ChangeSet, maxBytes = CHANGE_HEADER_MAX_BYTES): string | null {
  const canonical = fitChangeSet(cs, (c) => base64url(c).length <= maxBytes);
  return canonical === null ? null : base64url(canonical);
}

export function decodeChangeHeader(text: string): ChangeSet | null {
  const json = fromBase64url(text.trim());
  if (json === null) return null;
  try {
    return changeSetFromJSON(JSON.parse(json) as Json);
  } catch {
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// History rules (server-only)
// ═══════════════════════════════════════════════════════════════════════════

/** A head version opened at least this long ago is never extended. */
export const COALESCE_MAX_OPEN_MS = 10 * 60 * 1000;
/** …nor one whose last save is at least this old. */
export const COALESCE_MAX_IDLE_MS = 3 * 60 * 1000;
/** `X-CC-Checkpoint` / `X-CC-Merged-From` force a new version at most this often per project. */
export const CHECKPOINT_MIN_INTERVAL_MS = 60 * 1000;
/** Hard bound on retained versions per project (oldest unnamed evicted first). */
export const MAX_VERSIONS_PER_PROJECT = 1000;
/** Hard bound on the gzipped snapshot bytes one project's history may hold. */
export const MAX_HISTORY_BYTES_PER_PROJECT = 256 * 1024 * 1024;
/** Stored `change_json` cap (canonical JSON, UTF-8 bytes). */
export const MAX_CHANGE_JSON_BYTES = 32 * 1024;
/** Versions a save may prune inline; the hourly sweep does the rest. */
export const PRUNE_PER_SAVE = 5;
/** Version-label length cap (characters). */
export const MAX_LABEL_LENGTH = 100;
/** Versions per page in GET …/versions. */
export const VERSIONS_PAGE_DEFAULT = 50;
export const VERSIONS_PAGE_MAX = 200;

export type VersionKind = "upload" | "edit" | "merge" | "restore";
export type ClientKind = "mac" | "web" | "unknown";
export type SaveSource = "human" | "agent" | "mixed";
export type Checkpoint = "merge" | "restore" | "push" | "upload" | "named";

const CHECKPOINTS: readonly Checkpoint[] = ["merge", "restore", "push", "upload", "named"];
const CLIENT_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const VERSION_ID_RE = /^[a-z0-9]{8,32}$/;

/** The optional `X-CC-*` request headers of a save, validated. Every field
 *  degrades to its neutral value on junk — a malformed header never fails a
 *  save (old and buggy clients keep working). */
export interface SaveHeaders {
  clientKind: ClientKind;
  clientId: string | null;
  source: SaveSource;
  change: ChangeSet | null;
  checkpoint: Checkpoint | null;
  mergedFrom: number | null;
}

export function parseSaveHeaders(get: (name: string) => string | undefined | null): SaveHeaders {
  const client = get("X-CC-Client")?.trim().toLowerCase();
  const clientId = get("X-CC-Client-Id")?.trim() ?? "";
  const source = get("X-CC-Source")?.trim().toLowerCase();
  const changeText = get("X-CC-Change") ?? "";
  const checkpoint = get("X-CC-Checkpoint")?.trim().toLowerCase();
  const merged = get("X-CC-Merged-From")?.trim() ?? "";
  const mergedFrom = /^\d{1,12}$/.test(merged) ? Number(merged) : null;
  return {
    clientKind: client === "mac" || client === "web" ? client : "unknown",
    clientId: CLIENT_ID_RE.test(clientId) ? clientId : null,
    source: source === "agent" || source === "mixed" ? source : "human",
    change:
      changeText.length > 0 && changeText.length <= CHANGE_HEADER_MAX_BYTES ? decodeChangeHeader(changeText) : null,
    checkpoint: CHECKPOINTS.includes(checkpoint as Checkpoint) ? (checkpoint as Checkpoint) : null,
    mergedFrom: mergedFrom !== null && Number.isSafeInteger(mergedFrom) ? mergedFrom : null,
  };
}

export function isVersionId(raw: string | undefined | null): raw is string {
  return typeof raw === "string" && VERSION_ID_RE.test(raw);
}

/** Whether a save's checkpoint request (X-CC-Checkpoint or X-CC-Merged-From)
 *  is honoured: at most once per CHECKPOINT_MIN_INTERVAL_MS per project. */
export function checkpointHonoured(headers: SaveHeaders, lastCheckpointAt: string | null, nowMs: number): boolean {
  if (headers.checkpoint === null && headers.mergedFrom === null) return false;
  if (!lastCheckpointAt) return true;
  const last = Date.parse(lastCheckpointAt);
  return !Number.isFinite(last) || nowMs - last >= CHECKPOINT_MIN_INTERVAL_MS;
}

/** The head version, as far as coalescing cares. */
export interface HeadVersion {
  kind: string;
  label: string | null;
  actorUid: string | null;
  clientId: string | null;
  source: string;
  openedAt: string;
  updatedAt: string;
}

/**
 * Coalescing (docs/project-history.md §6): a save EXTENDS the head version
 * when all hold — same actor + client id + source; the head is unnamed and
 * of kind `edit`; it opened < 10 min ago and was updated < 3 min ago; no
 * honoured checkpoint. A missing client id (an old client) matches another
 * missing one, so an old web autosave still coalesces per actor.
 */
export function shouldExtend(
  head: HeadVersion | null,
  save: { actorUid: string; clientId: string | null; source: SaveSource },
  nowMs: number,
  forceNew: boolean,
): boolean {
  if (!head || forceNew) return false;
  if (head.kind !== "edit" || head.label !== null) return false;
  if (head.actorUid !== save.actorUid || head.clientId !== save.clientId || head.source !== save.source) return false;
  const opened = Date.parse(head.openedAt);
  const updated = Date.parse(head.updatedAt);
  if (!Number.isFinite(opened) || !Number.isFinite(updated)) return false;
  return nowMs - opened < COALESCE_MAX_OPEN_MS && nowMs - updated < COALESCE_MAX_IDLE_MS && nowMs >= updated;
}

/** The kind of a NEW version opened by a save. The first save of a project
 *  is its upload; merge / restore / upload checkpoints name themselves; a
 *  merged-from revision makes a merge; everything else (incl. `push`,
 *  `named`) is an edit. */
export function newVersionKind(previousRevision: number, headers: SaveHeaders): VersionKind {
  if (previousRevision === 0) return "upload";
  if (headers.mergedFrom !== null || headers.checkpoint === "merge") return "merge";
  if (headers.checkpoint === "restore") return "restore";
  if (headers.checkpoint === "upload") return "upload";
  return "edit";
}

/** Canonical JSON of a change-set within MAX_CHANGE_JSON_BYTES (degrading
 *  like the header budget), or null when even the collapsed form is over. */
export function changeJSONWithinCap(cs: ChangeSet, maxBytes = MAX_CHANGE_JSON_BYTES): string | null {
  return fitChangeSet(cs, (c) => new TextEncoder().encode(c).byteLength <= maxBytes);
}

/**
 * The `change_json` a save leaves on its version (canonical JSON or null =
 * unknown). A new version records the save's own change-set (base → new).
 * An extended version composes the head's with the save's — and becomes
 * unknown when either side is unknown: a gap cannot be composed honestly.
 */
export function versionChangeJSON(headChangeJSON: string | null, save: ChangeSet | null, extend: boolean): string | null {
  if (!save) return null;
  if (!extend) return changeJSONWithinCap(save);
  if (headChangeJSON === null) return null;
  let head: ChangeSet | null = null;
  try {
    head = changeSetFromJSON(JSON.parse(headChangeJSON) as Json);
  } catch {
    head = null;
  }
  return head ? changeJSONWithinCap(composeChangeSets(head, save)) : null;
}

// ── Retention ────────────────────────────────────────────────────────────

export interface RetentionLimits {
  /** Unnamed versions older than this many days are pruned; 0 = only the head is kept. */
  maxHistoryDays: number;
  /** The newest this-many named versions are exempt from the day window; 0 = none. */
  maxNamedVersions: number;
}

export interface RetainedVersion {
  id: string;
  seq: number;
  label: string | null;
  updatedAt: string;
  storedBytes: number;
}

/**
 * Which versions to delete, oldest first. Never the head. Named versions are
 * exempt from the day window — but only the newest `maxNamedVersions` of
 * them, so a downgrade (or a plan with no history) trims the rest on the next
 * sweep. Then the hard caps: at most MAX_VERSIONS_PER_PROJECT rows and
 * MAX_HISTORY_BYTES_PER_PROJECT snapshot bytes, evicting the oldest unnamed
 * first, then the oldest non-exempt named. Exempt named versions and the head
 * are never evicted by the caps (they are bounded by the plan's named cap).
 */
export function selectPrunable(
  versions: readonly RetainedVersion[],
  headId: string | null,
  limits: RetentionLimits,
  nowMs: number,
  opts: { maxVersions?: number; maxBytes?: number; maxDeletes?: number } = {},
): string[] {
  const maxVersions = opts.maxVersions ?? MAX_VERSIONS_PER_PROJECT;
  const maxBytes = opts.maxBytes ?? MAX_HISTORY_BYTES_PER_PROJECT;
  const maxDeletes = opts.maxDeletes ?? Number.POSITIVE_INFINITY;
  const days = Math.max(0, Math.floor(limits.maxHistoryDays));
  const namedCap = Math.max(0, Math.floor(limits.maxNamedVersions));
  const cutoff = nowMs - days * 86_400_000;

  const bySeqDesc = [...versions].sort((a, b) => b.seq - a.seq);
  const exempt = new Set<string>();
  for (const v of bySeqDesc) {
    if (v.label !== null && exempt.size < namedCap) exempt.add(v.id);
  }
  const doomed = new Set<string>();
  for (const v of versions) {
    if (v.id === headId || exempt.has(v.id)) continue;
    const t = Date.parse(v.updatedAt);
    if (days === 0 || !Number.isFinite(t) || t < cutoff) doomed.add(v.id);
  }

  // Eviction order for the caps: unnamed oldest first, then non-exempt named.
  const evictable = [...versions]
    .filter((v) => v.id !== headId && !exempt.has(v.id) && !doomed.has(v.id))
    .sort((a, b) => (a.label === null ? 0 : 1) - (b.label === null ? 0 : 1) || a.seq - b.seq);
  let count = versions.length - doomed.size;
  let bytes = versions.filter((v) => !doomed.has(v.id)).reduce((s, v) => s + v.storedBytes, 0);
  for (const v of evictable) {
    if (count <= maxVersions && bytes <= maxBytes) break;
    doomed.add(v.id);
    count -= 1;
    bytes -= v.storedBytes;
  }

  return versions
    .filter((v) => doomed.has(v.id))
    .sort((a, b) => a.seq - b.seq)
    .slice(0, maxDeletes === Number.POSITIVE_INFINITY ? undefined : maxDeletes)
    .map((v) => v.id);
}

// ── Manifests ────────────────────────────────────────────────────────────

export interface ManifestEntry {
  path: string;
  sha256: string;
  bytes: number;
  contentType: string;
  source: string | null;
}

/** The canonical manifest text (files sorted by path, fixed key order) —
 *  what `files_json` stores and what `manifest_sha` hashes, so the same file
 *  set always has the same sha. */
export function manifestText(files: readonly ManifestEntry[]): string {
  const sorted = [...files].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return JSON.stringify(
    sorted.map((f) => ({
      path: f.path,
      sha256: f.sha256,
      bytes: f.bytes,
      contentType: f.contentType,
      source: f.source ?? null,
    })),
  );
}

export function parseManifestText(text: string | null): ManifestEntry[] {
  if (!text) return [];
  try {
    const parsed = JSON.parse(text) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (f): f is ManifestEntry =>
        typeof f === "object" &&
        f !== null &&
        typeof (f as ManifestEntry).path === "string" &&
        typeof (f as ManifestEntry).sha256 === "string" &&
        typeof (f as ManifestEntry).bytes === "number" &&
        typeof (f as ManifestEntry).contentType === "string",
    );
  } catch {
    return [];
  }
}

/** Restore's file set: the version's paths win, unioned with the current ones. */
export function restoredFileSet(current: readonly ManifestEntry[], version: readonly ManifestEntry[]): ManifestEntry[] {
  const byPath = new Map<string, ManifestEntry>();
  for (const f of current) byPath.set(f.path, f);
  for (const f of version) byPath.set(f.path, f);
  return [...byPath.values()].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

// ── Labels ───────────────────────────────────────────────────────────────

/** A version label: trimmed, ≤ MAX_LABEL_LENGTH, no control characters.
 *  Empty / null = un-name. */
export function normalizeLabel(raw: unknown): { ok: true; label: string | null } | { ok: false; error: string } {
  if (raw === null || raw === undefined) return { ok: true, label: null };
  if (typeof raw !== "string") return { ok: false, error: "label must be a string or null" };
  const label = raw.trim();
  if (label.length === 0) return { ok: true, label: null };
  if ([...label].length > MAX_LABEL_LENGTH) return { ok: false, error: `label must be at most ${MAX_LABEL_LENGTH} characters` };
  if (/[\u0000-\u001f\u007f]/.test(label)) return { ok: false, error: "label must not contain control characters" };
  return { ok: true, label };
}

// ── gzip ─────────────────────────────────────────────────────────────────

/** Version snapshots are stored gzipped (`customMetadata.enc = "gzip"`);
 *  gzip is lossless, so the byte-exact document contract still holds. */
export const GZIP_ENCODING = "gzip";

async function pipeBytes(bytes: Uint8Array, transform: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const stream = new Response(bytes).body!.pipeThrough(transform as unknown as ReadableWritablePair<Uint8Array, Uint8Array>);
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export function gzipBytes(bytes: Uint8Array): Promise<Uint8Array> {
  return pipeBytes(bytes, new CompressionStream("gzip"));
}

export function gunzipBytes(bytes: Uint8Array): Promise<Uint8Array> {
  return pipeBytes(bytes, new DecompressionStream("gzip"));
}
