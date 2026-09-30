/**
 * `merge(base, mine, theirs, mineWins, choices?)` — the three-way project
 * merge (docs/project-history.md §Merge). Pure and clock-free: `mineWins`
 * (last local edit vs the server's updated_at, ties → theirs) is decided by
 * the caller. Twinned EXACTLY in Swift (Services/ProjectHistory/
 * ProjectMerge.swift) and locked by the `projectMerge` golden vectors.
 *
 * Works on raw project.json values, so unknown keys merge per key and are
 * never dropped. The merged document always applies a resolution for every
 * conflict (the caller's `choices[id]`, else the last writer); Merge Review
 * flips a conflict by re-merging with a different choice for its id.
 */
import {
  decide,
  elementPath,
  getKey,
  idEntries,
  isJsonObject,
  jsonEqual,
  lastWriter,
  mergeObject,
  sameSequence,
  setKey,
  threeWay,
  type AutoResolved,
  type ChildMerger,
  type GroupSpec,
  type IdEntry,
  type Json,
  type JsonObject,
  type MergeConflict,
  type MergeContext,
  type ObjectSpec,
  type Side,
} from "./jsonMerge";
import { MERGE_POLICY, type CollectionPolicy, type LanePolicy, type MergePolicy } from "./policy";

export interface MergeResult {
  merged: Json;
  conflicts: MergeConflict[];
  autoResolved: AutoResolved[];
}

export type MergeChoices = Readonly<Record<string, Side>>;

export function merge(
  base: Json,
  mine: Json,
  theirs: Json,
  mineWins: boolean,
  choices: MergeChoices = {},
  policy: MergePolicy = MERGE_POLICY,
): MergeResult {
  const ctx: MergeContext = { mineWins, choices, conflicts: [], autoResolved: [] };
  let merged: Json | undefined;
  if (jsonEqual(mine, theirs)) merged = mine;
  else if (jsonEqual(mine, base)) merged = theirs;
  else if (jsonEqual(theirs, base)) merged = mine;
  else if (isJsonObject(mine) && isJsonObject(theirs)) {
    const root = mergeObject(isJsonObject(base) ? base : undefined, mine, theirs, "", rootSpec(policy), ctx);
    merged = resolveLaneOverlaps(root, mine, theirs, policy, ctx);
  } else {
    merged = threeWay(base, mine, theirs, "", ctx);
  }
  return { merged: merged ?? null, conflicts: ctx.conflicts, autoResolved: ctx.autoResolved };
}

// ── Specs ───────────────────────────────────────────────────────────────

function rootSpec(policy: MergePolicy): ObjectSpec {
  const settings: ObjectSpec = { groups: policy.settingsGroups, child: () => undefined };
  const mergeSettings: ChildMerger = (b, m, t, path, ctx) => mergeOpenObject(b, m, t, path, settings, ctx);
  return {
    groups: policy.rootGroups,
    child: (key) => {
      if (key === policy.settingsKey) return mergeSettings;
      const c = policy.collections.find((p) => p.key === key);
      return c ? (b, m, t, path, ctx) => mergeCollection(c, policy, b, m, t, path, ctx) : undefined;
    },
  };
}

function elementSpec(c: CollectionPolicy, policy: MergePolicy): ObjectSpec {
  const groups: GroupSpec[] = c.groups.map((keys) => ({ name: keys.join(","), keys, prompt: false }));
  return {
    groups,
    child: (key) => {
      const nested = c.nested.find((n) => n.key === key);
      return nested ? (b, m, t, path, ctx) => mergeCollection(nested, policy, b, m, t, path, ctx) : undefined;
    },
  };
}

/** An object the policy opens: per key when both sides hold objects, else one value. */
function mergeOpenObject(
  b: Json | undefined,
  m: Json | undefined,
  t: Json | undefined,
  path: string,
  spec: ObjectSpec,
  ctx: MergeContext,
): Json | undefined {
  if (jsonEqual(m, t)) return m;
  if (jsonEqual(m, b)) return t;
  if (jsonEqual(t, b)) return m;
  if (isJsonObject(m) && isJsonObject(t)) return mergeObject(isJsonObject(b) ? b : undefined, m, t, path, spec, ctx);
  return threeWay(b, m, t, path, ctx);
}

// ── Id collections ──────────────────────────────────────────────────────

function mergeCollection(
  c: CollectionPolicy,
  policy: MergePolicy,
  b: Json | undefined,
  m: Json | undefined,
  t: Json | undefined,
  path: string,
  ctx: MergeContext,
): Json | undefined {
  if (jsonEqual(m, t)) return m;
  if (jsonEqual(m, b)) return t;
  if (jsonEqual(t, b)) return m;
  const B = idEntries(b);
  const M = idEntries(m);
  const T = idEntries(t);
  // Legacy (an element without an id) or malformed → the whole collection is one value.
  if (!B || !M || !T) return threeWay(b, m, t, path, ctx);

  if (c.regenerationCheck) {
    // Both sides changed (the fast paths above returned otherwise), so a
    // regeneration on either side clashes with the other side's edits.
    const regenMine = regenerated(B, M, policy);
    const regenTheirs = regenerated(B, T, policy);
    if (regenMine || regenTheirs) {
      const id = `subtitlesRegenerated:${path}`;
      const resolution = decide(ctx, id);
      ctx.conflicts.push({
        id,
        kind: "subtitlesRegenerated",
        path,
        resolution,
        defaultResolution: lastWriter(ctx),
        regeneratedBy: regenMine && regenTheirs ? "both" : regenMine ? "mine" : "theirs",
      });
      return resolution === "mine" ? m : t;
    }
  }
  return mergeById(c, policy, B, M, T, path, ctx);
}

/** Fewer than `regenerationSurvival` of the base ids survive on that side. */
function regenerated(base: IdEntry[], side: IdEntry[], policy: MergePolicy): boolean {
  if (base.length === 0) return false;
  const ids = new Set(side.map((e) => e.id));
  let survivors = 0;
  for (const e of base) if (ids.has(e.id)) survivors++;
  return survivors < base.length * policy.regenerationSurvival;
}

function mergeById(
  c: CollectionPolicy,
  policy: MergePolicy,
  B: IdEntry[],
  M: IdEntry[],
  T: IdEntry[],
  path: string,
  ctx: MergeContext,
): Json[] {
  const bMap = new Map(B.map((e) => [e.id, e.value]));
  const mMap = new Map(M.map((e) => [e.id, e.value]));
  const tMap = new Map(T.map((e) => [e.id, e.value]));
  const spec = elementSpec(c, policy);
  const out: Json[] = [];
  for (const id of mergedOrder(B, M, T, path, ctx)) {
    const bv = bMap.get(id);
    const mv = mMap.get(id);
    const tv = tMap.get(id);
    const ep = elementPath(path, id);
    if (mv && tv) {
      out.push(mergeElement(bv, mv, tv, ep, spec, ctx));
    } else if (mv) {
      if (!bv) out.push(mv); // added by mine
      else if (!jsonEqual(mv, bv) && deleteVsModify(ep, "theirs", ctx) === "mine") out.push(mv);
    } else if (tv) {
      if (!bv) out.push(tv); // added by theirs
      else if (!jsonEqual(tv, bv) && deleteVsModify(ep, "mine", ctx) === "theirs") out.push(tv);
    }
  }
  return out;
}

function deleteVsModify(path: string, deletedBy: Side, ctx: MergeContext): Side {
  const id = `deleteVsModify:${path}`;
  const resolution = decide(ctx, id);
  ctx.conflicts.push({ id, kind: "deleteVsModify", path, resolution, defaultResolution: lastWriter(ctx), deletedBy });
  return resolution;
}

function mergeElement(
  b: JsonObject | undefined,
  m: JsonObject,
  t: JsonObject,
  path: string,
  spec: ObjectSpec,
  ctx: MergeContext,
): Json {
  if (jsonEqual(m, t)) return m;
  if (jsonEqual(m, b)) return t;
  if (jsonEqual(t, b)) return m;
  return mergeObject(b, m, t, path, spec, ctx);
}

/**
 * Output order: mine's, with theirs-only ids appended (annotation order is
 * z-order — never re-sorted). When ONLY theirs reordered the elements both
 * sides kept, theirs' order is the backbone instead (mine's additions are
 * appended); when both reordered differently the last writer's order wins.
 */
function mergedOrder(B: IdEntry[], M: IdEntry[], T: IdEntry[], path: string, ctx: MergeContext): string[] {
  const inB = new Set(B.map((e) => e.id));
  const inM = new Set(M.map((e) => e.id));
  const inT = new Set(T.map((e) => e.id));
  const projB = B.filter((e) => inM.has(e.id) && inT.has(e.id)).map((e) => e.id);
  const projM = M.filter((e) => inB.has(e.id) && inT.has(e.id)).map((e) => e.id);
  const projT = T.filter((e) => inB.has(e.id) && inM.has(e.id)).map((e) => e.id);
  const mineReordered = !sameSequence(projM, projB);
  const theirsReordered = !sameSequence(projT, projB);
  let backbone: Side = "mine";
  if (theirsReordered && !mineReordered) backbone = "theirs";
  else if (theirsReordered && mineReordered && !sameSequence(projM, projT)) {
    backbone = lastWriter(ctx);
    ctx.autoResolved.push({ path, kind: "order", winner: backbone });
  }
  const first = backbone === "mine" ? M : T;
  const second = backbone === "mine" ? T : M;
  const order = first.map((e) => e.id);
  const seen = new Set(order);
  for (const e of second) if (!seen.has(e.id)) order.push(e.id);
  return order;
}

// ── Exclusive lanes ─────────────────────────────────────────────────────

interface LaneItem {
  collection: string;
  id: string;
  start: number;
  end: number;
  /** `collection[id]` */
  key: string;
}

interface LanePair {
  key: string;
  a: LaneItem;
  b: LaneItem;
}

function laneItems(doc: JsonObject, collections: readonly string[]): LaneItem[] {
  const items: LaneItem[] = [];
  for (const collection of collections) {
    const entries = idEntries(getKey(doc, collection));
    if (!entries) continue;
    for (const { id, value } of entries) {
      const start = getKey(value, "startTime");
      const end = getKey(value, "endTime");
      if (typeof start !== "number" || typeof end !== "number") continue;
      items.push({ collection, id, start, end, key: elementPath(collection, id) });
    }
  }
  return items;
}

function pairKey(a: string, b: string): string {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

/** Linked zoom+tilt blocks (TimelineViewController.canvasEffectItems pairing). */
function linkedPairs(doc: JsonObject, lane: LanePolicy): Set<string> {
  const links = new Set<string>();
  if (!lane.link) return links;
  const eps = lane.link.epsilon;
  const primaries = laneItems(doc, [lane.link.primary]);
  const secondaries = laneItems(doc, [lane.link.secondary]);
  const claimed = new Set<string>();
  for (const p of primaries) {
    const match = secondaries.find(
      (s) => !claimed.has(s.id) && Math.abs(s.start - p.start) <= eps && Math.abs(s.end - p.end) <= eps,
    );
    if (match) {
      claimed.add(match.id);
      links.add(pairKey(p.key, match.key));
    }
  }
  return links;
}

function overlapPairs(doc: JsonObject, lane: LanePolicy, policy: MergePolicy): LanePair[] {
  const eps = policy.overlapEpsilon;
  const items = laneItems(doc, lane.collections);
  const links = linkedPairs(doc, lane);
  const pairs: LanePair[] = [];
  for (let i = 0; i < items.length; i++) {
    for (let j = i + 1; j < items.length; j++) {
      const x = items[i];
      const y = items[j];
      if (!(x.start < y.end - eps && y.start < x.end - eps)) continue;
      const key = pairKey(x.key, y.key);
      if (links.has(key)) continue;
      pairs.push(x.key < y.key ? { key, a: x, b: y } : { key, a: y, b: x });
    }
  }
  return pairs.sort((p, q) => (p.key < q.key ? -1 : p.key > q.key ? 1 : 0));
}

/**
 * An overlap on an exclusive lane that NEITHER input had is a conflict. Its
 * resolution puts BOTH elements back to the chosen side's version (removing
 * one the chosen side does not have) — that pair never overlapped there.
 * Detection runs once on the merged document; resolutions apply in order.
 */
function resolveLaneOverlaps(
  merged: JsonObject,
  mine: JsonObject,
  theirs: JsonObject,
  policy: MergePolicy,
  ctx: MergeContext,
): JsonObject {
  const resolutions: { items: LaneItem[]; side: Side }[] = [];
  for (const lane of policy.lanes) {
    const pairs = overlapPairs(merged, lane, policy);
    if (pairs.length === 0) continue;
    const before = new Set([
      ...overlapPairs(mine, lane, policy).map((p) => p.key),
      ...overlapPairs(theirs, lane, policy).map((p) => p.key),
    ]);
    for (const p of pairs) {
      if (before.has(p.key)) continue;
      const id = `laneOverlap:${p.key}`;
      const resolution = decide(ctx, id);
      ctx.conflicts.push({
        id,
        kind: "laneOverlap",
        path: p.key,
        resolution,
        defaultResolution: lastWriter(ctx),
        lane: lane.name,
        elements: [p.a.key, p.b.key],
      });
      resolutions.push({ items: [p.a, p.b], side: resolution });
    }
  }
  if (resolutions.length === 0) return merged;

  const out: JsonObject = {};
  for (const k of Object.keys(merged)) setKey(out, k, merged[k]);
  for (const r of resolutions) {
    const source = r.side === "mine" ? mine : theirs;
    for (const item of r.items) {
      const current = getKey(out, item.collection);
      if (!Array.isArray(current)) continue;
      const index = current.findIndex((e) => getKey(e, "id") === item.id);
      if (index < 0) continue; // already removed by an earlier resolution
      const replacement = idEntries(getKey(source, item.collection))?.find((e) => e.id === item.id)?.value;
      const next = current.slice();
      if (replacement === undefined) next.splice(index, 1);
      else next[index] = replacement;
      setKey(out, item.collection, next);
    }
  }
  return out;
}
