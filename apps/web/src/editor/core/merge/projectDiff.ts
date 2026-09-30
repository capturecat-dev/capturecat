/**
 * Change-sets (docs/project-history.md §Change-set): what changed between
 * two project.json documents, in a form small enough for the `X-CC-Change`
 * header and composable by the API without the web model.
 *
 *   diff(a, b)                 → ChangeSet (a → b)
 *   composeChangeSets(x, y)    → x then y (add+change=add, add+remove=nothing,
 *                                change+remove=remove, remove+add=change)
 *   encodeChangeHeader(cs)     → base64url(canonical JSON) ≤ 8 KB, degrading
 *                                the largest id lists to counts when needed
 *   decodeChangeHeader(text)   → ChangeSet | null (validated, normalized)
 *
 * Twinned EXACTLY in Swift (Services/ProjectHistory/ProjectDiff.swift).
 * This module has no dependency on the web project model, so the API may
 * import it (or copy it verbatim — the golden vectors lock both).
 */
import {
  canonicalJSON,
  getKey,
  idEntries,
  isJsonObject,
  jsonEqual,
  sameSequence,
  sortedUnion,
  sortedUnionKeys,
  type Json,
  type JsonObject,
} from "./jsonMerge";
import { MERGE_POLICY, settingsTabFor, type MergePolicy } from "./policy";

export interface ChangeCounts {
  added: number;
  removed: number;
  changed: number;
}

/**
 * One id collection's changes. Exactly one form:
 *   - exact:     added / removed ids, changed id → element keys (sorted);
 *   - truncated: `counts` only (id lists dropped to fit the header budget);
 *   - replaced:  a legacy id-less (or malformed) collection that changed.
 * `reordered`: the ids both documents hold changed relative order (z-order).
 */
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
  /** Id collections by project.json key. */
  items: Record<string, CollectionChange>;
  /** Changed settings keys grouped by inspector tab (policy.settingsTabs; else "other"). */
  settings: Record<string, string[]>;
  /** Other changed root keys, sorted ("*" = the documents are not objects). */
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

// ── diff ────────────────────────────────────────────────────────────────

function changedKeys(a: JsonObject, b: JsonObject): string[] {
  return sortedUnionKeys(a, b).filter((k) => !jsonEqual(getKey(a, k), getKey(b, k)));
}

export function diff(a: Json, b: Json, policy: MergePolicy = MERGE_POLICY): ChangeSet {
  const cs = emptyChangeSet();
  if (!isJsonObject(a) || !isJsonObject(b)) {
    if (!jsonEqual(a, b)) cs.fields = ["*"];
    return cs;
  }
  const special = new Set<string>([policy.settingsKey, ...policy.collections.map((c) => c.key)]);

  for (const c of policy.collections) {
    const va = getKey(a, c.key);
    const vb = getKey(b, c.key);
    if (jsonEqual(va, vb)) continue;
    const A = idEntries(va);
    const B = idEntries(vb);
    if (!A || !B) {
      cs.items[c.key] = { replaced: true };
      continue;
    }
    const aMap = new Map(A.map((e) => [e.id, e.value]));
    const bMap = new Map(B.map((e) => [e.id, e.value]));
    const changed: Record<string, string[]> = {};
    for (const id of [...aMap.keys()].filter((id) => bMap.has(id)).sort()) {
      const keys = changedKeys(aMap.get(id)!, bMap.get(id)!);
      if (keys.length) changed[id] = keys;
    }
    const entry = normalizeCollectionChange({
      added: B.filter((e) => !aMap.has(e.id)).map((e) => e.id),
      removed: A.filter((e) => !bMap.has(e.id)).map((e) => e.id),
      changed,
      reordered: !sameSequence(
        A.filter((e) => bMap.has(e.id)).map((e) => e.id),
        B.filter((e) => aMap.has(e.id)).map((e) => e.id),
      ),
    });
    if (entry) cs.items[c.key] = entry;
  }

  const fields: string[] = [];
  const sa = getKey(a, policy.settingsKey);
  const sb = getKey(b, policy.settingsKey);
  if (!jsonEqual(sa, sb)) {
    if (isJsonObject(sa) && isJsonObject(sb)) {
      for (const k of changedKeys(sa, sb)) {
        const tab = settingsTabFor(k, policy);
        (cs.settings[tab] ??= []).push(k);
      }
    } else fields.push(policy.settingsKey);
  }
  for (const k of sortedUnionKeys(a, b)) {
    if (special.has(k)) continue;
    if (!jsonEqual(getKey(a, k), getKey(b, k))) fields.push(k);
  }
  cs.fields = sortedUnion(fields);
  return cs;
}

// ── compose ─────────────────────────────────────────────────────────────

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

// ── JSON form ───────────────────────────────────────────────────────────

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

// ── X-CC-Change header ──────────────────────────────────────────────────

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
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

function idPayload(c: CollectionChange): number {
  return (c.added?.length ?? 0) + (c.removed?.length ?? 0) + (c.changed ? Object.keys(c.changed).length : 0);
}

/**
 * `X-CC-Change` value: base64url (no padding) of the change-set's canonical
 * JSON. Over `maxBytes`, the exact collection with the most ids (ties → first
 * key in sorted order) degrades to counts, repeatedly; then every settings
 * tab collapses to ["*"]; if it still does not fit, null (send no header).
 */
export function encodeChangeHeader(cs: ChangeSet, maxBytes = CHANGE_HEADER_MAX_BYTES): string | null {
  let current: ChangeSet = {
    v: 1,
    items: { ...cs.items },
    settings: { ...cs.settings },
    fields: [...cs.fields],
  };
  for (;;) {
    const encoded = base64url(canonicalJSON(changeSetJSON(current)));
    if (encoded.length <= maxBytes) return encoded;
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

export function decodeChangeHeader(text: string): ChangeSet | null {
  const json = fromBase64url(text.trim());
  if (json === null) return null;
  try {
    return changeSetFromJSON(JSON.parse(json) as Json);
  } catch {
    return null;
  }
}
