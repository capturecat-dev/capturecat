/**
 * Raw-JSON primitives for the project merge (docs/project-history.md).
 *
 * The merge runs on the RAW project.json values, never on decoded models:
 * decoding drops unknown keys and, for id-less CameraLayoutRegions, invents a
 * fresh random id on every decode — neither is acceptable in a three-way
 * merge. Twinned EXACTLY in Swift (Services/ProjectHistory/JSONValue.swift);
 * the `projectMerge` golden vectors lock the two together.
 *
 * Canonical JSON (what every comparison and golden string uses):
 *   - object keys sorted by UTF-16 code units, no whitespace;
 *   - numbers in ECMAScript Number::toString form (`String(n)`), with -0
 *     written as `0` (numbers compare with IEEE `==`, so -0 == 0);
 *   - strings escape only `"`, `\`, and U+0000–U+001F (\b \f \n \r \t, else
 *     \u00xx lowercase); everything else is written literally.
 */

export type Json = null | boolean | number | string | Json[] | JsonObject;
export interface JsonObject {
  [key: string]: Json;
}

export type Side = "mine" | "theirs";

// ── Basic accessors ──────────────────────────────────────────────────────

export function isJsonObject(v: Json | undefined): v is JsonObject {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Own-property read (never an inherited `constructor`/`toString`). */
export function getKey(o: Json | undefined, key: string): Json | undefined {
  return isJsonObject(o) && Object.hasOwn(o, key) ? o[key] : undefined;
}

/** Own-property write that is safe for any key (including `__proto__`). */
export function setKey(o: JsonObject, key: string, value: Json): void {
  Object.defineProperty(o, key, { value, enumerable: true, writable: true, configurable: true });
}

/** Keys sorted by UTF-16 code units (the default `Array.prototype.sort`). */
export function sortedKeys(o: JsonObject): string[] {
  return Object.keys(o).sort();
}

/** Sorted union of the own keys of every object argument (others ignored). */
export function sortedUnionKeys(...objects: (Json | undefined)[]): string[] {
  const set = new Set<string>();
  for (const o of objects) if (isJsonObject(o)) for (const k of Object.keys(o)) set.add(k);
  return [...set].sort();
}

/** Sorted, de-duplicated union of string lists. */
export function sortedUnion(...lists: readonly (readonly string[])[]): string[] {
  const set = new Set<string>();
  for (const l of lists) for (const s of l) set.add(s);
  return [...set].sort();
}

export function sameSequence(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// ── Equality ────────────────────────────────────────────────────────────

/**
 * Structural equality. `undefined` stands for an ABSENT key and only equals
 * another absent key (absent ≠ null). Objects compare as key→value maps
 * (order-insensitive); numbers with `===` (so -0 equals 0).
 */
export function jsonEqual(a: Json | undefined, b: Json | undefined): boolean {
  if (a === b) return true;
  if (a === undefined || b === undefined || a === null || b === null) return false;
  if (typeof a !== "object" || typeof b !== "object") return false;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!jsonEqual(a[i], b[i])) return false;
    return true;
  }
  if (Array.isArray(b)) return false;
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length) return false;
  for (const k of ka) {
    if (!Object.hasOwn(b, k)) return false;
    if (!jsonEqual(a[k], b[k])) return false;
  }
  return true;
}

// ── Canonical JSON ──────────────────────────────────────────────────────

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
  return "{" + sortedKeys(obj).map((k) => canonicalString(k) + ":" + canonicalJSON(obj[k])).join(",") + "}";
}

// ── Hashing ─────────────────────────────────────────────────────────────

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

// ── Merge bookkeeping ───────────────────────────────────────────────────

/** A same-field (or same-group) clash settled by the last writer. */
export interface AutoResolved {
  path: string;
  kind: "field" | "group" | "order";
  winner: Side;
}

export type ConflictKind = "deleteVsModify" | "clipStructure" | "subtitlesRegenerated" | "laneOverlap";

/**
 * A structural clash the user reviews. The merged document already applies
 * `resolution` (the caller's choice for `id`, else the last writer); passing
 * `choices[id]` to `merge` re-merges with the other side.
 */
export interface MergeConflict {
  /** `${kind}:${path}` — stable across re-merges with different choices. */
  id: string;
  kind: ConflictKind;
  path: string;
  resolution: Side;
  defaultResolution: Side;
  /** deleteVsModify: the side that deleted the element. */
  deletedBy?: Side;
  /** subtitlesRegenerated: the side(s) whose captions were regenerated. */
  regeneratedBy?: Side | "both";
  /** laneOverlap: the exclusive lane and the two overlapping element paths. */
  lane?: string;
  elements?: string[];
}

export interface MergeContext {
  readonly mineWins: boolean;
  readonly choices: Readonly<Record<string, Side>>;
  readonly conflicts: MergeConflict[];
  readonly autoResolved: AutoResolved[];
}

export function lastWriter(ctx: MergeContext): Side {
  return ctx.mineWins ? "mine" : "theirs";
}

/** The caller's choice for a conflict id, else the last writer. */
export function decide(ctx: MergeContext, id: string): Side {
  if (Object.hasOwn(ctx.choices, id)) {
    const c = ctx.choices[id];
    if (c === "mine" || c === "theirs") return c;
  }
  return lastWriter(ctx);
}

// ── Paths ───────────────────────────────────────────────────────────────

export function joinPath(base: string, key: string): string {
  return base === "" ? key : `${base}.${key}`;
}

export function elementPath(collectionPath: string, id: string): string {
  return `${collectionPath}[${id}]`;
}

export function groupPath(base: string, keys: readonly string[]): string {
  return joinPath(base, `{${keys.join(",")}}`);
}

// ── Generic three-way ───────────────────────────────────────────────────

/**
 * Three-way merge of one value (absent = undefined). One side changed → that
 * side; both changed identically → it; both changed differently → the last
 * writer, logged in autoResolved.
 */
export function threeWay(
  b: Json | undefined,
  m: Json | undefined,
  t: Json | undefined,
  path: string,
  ctx: MergeContext,
): Json | undefined {
  if (jsonEqual(m, t)) return m;
  if (jsonEqual(m, b)) return t;
  if (jsonEqual(t, b)) return m;
  const w = lastWriter(ctx);
  ctx.autoResolved.push({ path, kind: "field", winner: w });
  return w === "mine" ? m : t;
}

export interface GroupSpec {
  readonly name: string;
  readonly keys: readonly string[];
  /** Both sides changed → a MergeConflict (kind = name) instead of autoResolved. */
  readonly prompt: boolean;
}

export type ChildMerger = (
  b: Json | undefined,
  m: Json | undefined,
  t: Json | undefined,
  path: string,
  ctx: MergeContext,
) => Json | undefined;

export interface ObjectSpec {
  readonly groups: readonly GroupSpec[];
  /** Special handling for a key (settings, id collections); default = threeWay. */
  readonly child: (key: string) => ChildMerger | undefined;
}

function groupEqual(a: Json | undefined, b: Json | undefined, keys: readonly string[]): boolean {
  for (const k of keys) if (!jsonEqual(getKey(a, k), getKey(b, k))) return false;
  return true;
}

/** Which side supplies an atomic group's keys (all of them, presence included). */
function mergeGroup(
  b: JsonObject | undefined,
  m: JsonObject,
  t: JsonObject,
  path: string,
  g: GroupSpec,
  ctx: MergeContext,
): Side {
  const changedMine = !groupEqual(b, m, g.keys);
  const changedTheirs = !groupEqual(b, t, g.keys);
  if (!changedTheirs) return "mine";
  if (!changedMine) return "theirs";
  if (groupEqual(m, t, g.keys)) return "mine";
  const gp = groupPath(path, g.keys);
  const def = lastWriter(ctx);
  if (g.prompt) {
    const kind = g.name as ConflictKind;
    const id = `${kind}:${gp}`;
    const resolution = decide(ctx, id);
    ctx.conflicts.push({ id, kind, path: gp, resolution, defaultResolution: def });
    return resolution;
  }
  ctx.autoResolved.push({ path: gp, kind: "group", winner: def });
  return def;
}

/**
 * Per-key merge of an object the policy says to open (root, settings, an
 * id-collection element). Atomic groups first (policy order), then every
 * other key in sorted order — that order is the log order. Output key order
 * is mine's, then keys only theirs has (theirs' order); absent results drop.
 */
export function mergeObject(
  b: JsonObject | undefined,
  m: JsonObject,
  t: JsonObject,
  path: string,
  spec: ObjectSpec,
  ctx: MergeContext,
): JsonObject {
  const taken = new Map<string, Json | undefined>();
  const handled = new Set<string>();
  for (const g of spec.groups) {
    for (const k of g.keys) handled.add(k);
    const src = mergeGroup(b, m, t, path, g, ctx) === "theirs" ? t : m;
    for (const k of g.keys) taken.set(k, getKey(src, k));
  }
  for (const k of sortedUnionKeys(b, m, t)) {
    if (handled.has(k)) continue;
    const kp = joinPath(path, k);
    const child = spec.child(k);
    const bv = getKey(b, k);
    const mv = getKey(m, k);
    const tv = getKey(t, k);
    taken.set(k, child ? child(bv, mv, tv, kp, ctx) : threeWay(bv, mv, tv, kp, ctx));
  }
  const out: JsonObject = {};
  for (const k of Object.keys(m)) {
    const v = taken.get(k);
    if (v !== undefined) setKey(out, k, v);
  }
  for (const k of Object.keys(t)) {
    if (Object.hasOwn(m, k)) continue;
    const v = taken.get(k);
    if (v !== undefined) setKey(out, k, v);
  }
  return out;
}

// ── Id collections ──────────────────────────────────────────────────────

export interface IdEntry {
  id: string;
  value: JsonObject;
}

/**
 * The elements of an id collection, or null when it cannot merge by id: not
 * an array, an element that is not an object, an element without a non-empty
 * string `id` (legacy), or a duplicate id. Absent = [] (older documents).
 */
export function idEntries(v: Json | undefined): IdEntry[] | null {
  if (v === undefined) return [];
  if (!Array.isArray(v)) return null;
  const seen = new Set<string>();
  const out: IdEntry[] = [];
  for (const e of v) {
    if (!isJsonObject(e)) return null;
    const id = getKey(e, "id");
    if (typeof id !== "string" || id === "" || seen.has(id)) return null;
    seen.add(id);
    out.push({ id, value: e });
  }
  return out;
}
