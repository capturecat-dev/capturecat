/**
 * Copy-on-write for the project model.
 *
 * The ported Mac edit logic mutates the project in place (Swift's Project is
 * a reference type), so every edit runs against a DEEP draft of the current
 * snapshot. After the recipe, `reconcile` puts back the base's references for
 * every subtree the recipe did not change, so snapshots share structure:
 * undo entries stay cheap and `prev.subtitles === next.subtitles` tells a
 * consumer (engine, panes) that nothing there moved.
 *
 * Project data is plain JSON-shaped (objects, arrays, numbers, strings,
 * booleans, null — `$extra` included), so a hand-rolled clone is exact and
 * several times faster than structuredClone for this shape.
 */

export function deepClone<T>(value: T): T {
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) {
    const out = new Array(value.length);
    for (let i = 0; i < value.length; i++) out[i] = deepClone(value[i]);
    return out as T;
  }
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value as Record<string, unknown>)) {
    out[key] = deepClone((value as Record<string, unknown>)[key]);
  }
  return out as T;
}

/** Structural equality for JSON-shaped data (NaN never appears in a valid project). */
export function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") {
    // -0 vs 0 are the same persisted value for every field we store.
    return false;
  }
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false;
    return true;
  }
  if (Array.isArray(b)) return false;
  const ka = Object.keys(a as Record<string, unknown>);
  const kb = Object.keys(b as Record<string, unknown>);
  if (ka.length !== kb.length) return false;
  for (const key of ka) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!deepEqual((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key])) return false;
  }
  return true;
}

/**
 * Returns `base` itself when `next` is structurally equal to it; otherwise a
 * value equal to `next` whose unchanged children are `base`'s references
 * (recursively for objects, element-wise for equal-length arrays and for
 * array elements that kept their `id`).
 */
export function reconcile<T>(base: T, next: T): T {
  if (base === next) return base;
  if (base === null || next === null || typeof base !== "object" || typeof next !== "object") {
    return deepEqual(base, next) ? base : next;
  }
  if (Array.isArray(base) !== Array.isArray(next)) return next;
  if (Array.isArray(base)) {
    const b = base as unknown[];
    const n = next as unknown as unknown[];
    const byId = new Map<unknown, unknown>();
    for (const item of b) {
      const id = item && typeof item === "object" ? (item as { id?: unknown }).id : undefined;
      if (id !== undefined) byId.set(id, item);
    }
    let same = b.length === n.length;
    const out = new Array(n.length);
    for (let i = 0; i < n.length; i++) {
      const item = n[i];
      const id = item && typeof item === "object" ? (item as { id?: unknown }).id : undefined;
      const counterpart = id !== undefined && byId.has(id) ? byId.get(id) : i < b.length ? b[i] : undefined;
      out[i] = counterpart === undefined ? item : reconcile(counterpart, item);
      if (out[i] !== b[i]) same = false;
    }
    return (same ? base : out) as T;
  }
  const b = base as Record<string, unknown>;
  const n = next as Record<string, unknown>;
  const keys = Object.keys(n);
  let same = keys.length === Object.keys(b).length;
  const out: Record<string, unknown> = {};
  for (const key of keys) {
    const has = Object.prototype.hasOwnProperty.call(b, key);
    out[key] = has ? reconcile(b[key], n[key]) : n[key];
    if (!has || out[key] !== b[key]) same = false;
  }
  return (same ? base : out) as T;
}

/** Run `recipe` against a deep draft of `base`; returns the reconciled result
 *  (=== base when nothing changed) plus whatever the recipe returned. */
export function produce<T, R>(base: T, recipe: (draft: T) => R): { next: T; result: R } {
  const draft = deepClone(base);
  const result = recipe(draft);
  return { next: reconcile(base, draft), result };
}
