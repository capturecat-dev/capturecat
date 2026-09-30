/**
 * Property tests for the project merge (docs/project-history.md §Merge):
 *
 *   merge(b, x, b) = x,   merge(b, b, y) = y,   merge(b, x, x) = x
 *
 * (canonical JSON, no conflicts, nothing auto-resolved, either last writer)
 * over deterministic pseudo-random project-shaped documents, plus: unknown
 * keys are never dropped, keys only one side touched keep that side's value,
 * and diff / compose / the X-CC-Change header behave. Swift parity is the
 * golden suite's job (merge.golden.test.ts); these hold for the TS alone.
 */
import { describe, expect, it } from "vitest";

import { PROJECT_SETTINGS_KEYS } from "../model/keys";
import { canonicalJSON, getKey, isJsonObject, jsonEqual, type Json, type JsonObject } from "./jsonMerge";
import { MERGE_POLICY, settingsTabFor } from "./policy";
import { merge } from "./projectMerge";
import {
  changeSetJSON,
  composeChangeSets,
  decodeChangeHeader,
  diff,
  emptyChangeSet,
  encodeChangeHeader,
  isEmptyChangeSet,
} from "./projectDiff";
import { formatChangeSummary } from "./changeSummary";
import { loadFixtures } from "./goldenFiles";

// ── deterministic generator ──────────────────────────────────────────────

class Rng {
  private s: number;
  constructor(seed: number) {
    this.s = seed >>> 0;
  }
  next(): number {
    // mulberry32
    this.s = (this.s + 0x6d2b79f5) >>> 0;
    let t = this.s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  int(lo: number, hi: number): number {
    return lo + Math.floor(this.next() * (hi - lo + 1));
  }
  bool(p = 0.5): boolean {
    return this.next() < p;
  }
  pick<T>(items: readonly T[]): T {
    return items[this.int(0, items.length - 1)];
  }
}

let idCounter = 0;
const newId = () => `A0000000-0000-4000-8000-${String(++idCounter).padStart(12, "0")}`;

const SETTINGS_SAMPLE = [
  "backgroundType",
  "backgroundPadding",
  "videoPlacement",
  "videoCustomX",
  "videoCustomY",
  "cursorScale",
  "cameraPosition",
  "cameraCustomX",
  "introSlideStyle",
  "introSlideStart",
  "subtitleFontSize",
  "gradientStartColor",
  "exportSettings",
  "aspectRatio",
  "futureSettingA",
  "futureSettingB",
];

function scalar(rng: Rng): Json {
  switch (rng.int(0, 5)) {
    case 0:
      return rng.int(-50, 50) / 4;
    case 1:
      return rng.bool();
    case 2:
      return rng.pick(["Gradient", "Solid Color", "Left", "Top", "é🎬", ""]);
    case 3:
      return null;
    case 4:
      return { red: rng.next(), green: 0.5, blue: 1, opacity: 1 };
    default:
      return [rng.int(0, 3), rng.int(0, 3)];
  }
}

function element(rng: Rng, collection: string): JsonObject {
  const start = rng.int(0, 40) / 2;
  const e: JsonObject = { id: newId(), startTime: start, endTime: start + rng.int(1, 8) / 2 };
  if (rng.bool()) e.label = rng.pick(["a", "b", "c"]);
  if (rng.bool(0.3)) e.futureElementKey = scalar(rng);
  if (collection === "subtitles") {
    e.text = "caption";
    e.words = Array.from({ length: rng.int(0, 3) }, () => element(rng, "words"));
  }
  if (collection === "voiceOverClips") e.duration = rng.int(1, 6);
  return e;
}

function randomDoc(rng: Rng): JsonObject {
  const settings: JsonObject = {};
  for (const k of SETTINGS_SAMPLE) if (rng.bool(0.7)) settings[k] = scalar(rng);
  const doc: JsonObject = { id: "F0000000-0000-4000-8000-000000000000", name: "doc", settings, duration: 30 };
  for (const c of MERGE_POLICY.collections) {
    if (rng.bool(0.15)) continue; // absent (older document)
    doc[c.key] = Array.from({ length: rng.int(0, 4) }, () => element(rng, c.key));
  }
  if (rng.bool(0.2)) doc.cameraLayoutRegions = [{ startTime: 0, endTime: 2, mode: "cameraOnly" }]; // legacy id-less
  if (rng.bool(0.4)) doc.futureRoot = { nested: scalar(rng) };
  doc.trimEnd = rng.pick([0, 20, 25]);
  doc.videoClipSegments = [{ id: newId(), startTime: 0, endTime: 30 }];
  return doc;
}

function clone<T extends Json>(v: T): T {
  return JSON.parse(JSON.stringify(v)) as T;
}

/** A random edit session on a copy of `doc`. */
function mutate(doc: JsonObject, rng: Rng): JsonObject {
  const out = clone(doc);
  const edits = rng.int(1, 6);
  for (let i = 0; i < edits; i++) {
    const kind = rng.int(0, 11);
    const settings = out.settings as JsonObject;
    const coll = rng.pick(MERGE_POLICY.collections).key;
    const arr = Array.isArray(out[coll]) ? (out[coll] as Json[]) : null;
    switch (kind) {
      case 0:
        settings[rng.pick(SETTINGS_SAMPLE)] = scalar(rng);
        break;
      case 1:
        delete settings[rng.pick(SETTINGS_SAMPLE)];
        break;
      case 2:
        if (arr) arr.push(element(rng, coll));
        else out[coll] = [element(rng, coll)];
        break;
      case 3:
        if (arr?.length) arr.splice(rng.int(0, arr.length - 1), 1);
        break;
      case 4:
        if (arr?.length) {
          const e = arr[rng.int(0, arr.length - 1)] as JsonObject;
          if (isJsonObject(e)) e[rng.pick(["startTime", "endTime", "label", "futureElementKey", "zoomLevel"])] = scalar(rng);
        }
        break;
      case 5:
        if (arr && arr.length > 1) arr.push(arr.shift()!); // reorder (z-order)
        break;
      case 6:
        out[`futureRoot${rng.int(0, 2)}`] = scalar(rng);
        break;
      case 7:
        out.name = `renamed ${rng.int(0, 9)}`;
        break;
      case 8:
        out.trimEnd = rng.int(10, 30);
        break;
      case 9:
        if (Array.isArray(out.subtitles) && out.subtitles.length) {
          const s = out.subtitles[0] as JsonObject;
          const words = s.words as Json[] | undefined;
          if (words?.length) (words[0] as JsonObject).text = `w${rng.int(0, 9)}`;
          else s.words = [element(rng, "words")];
        }
        break;
      case 10:
        if (Array.isArray(out.subtitles)) out.subtitles = [element(rng, "subtitles")]; // regenerate
        break;
      default:
        delete out[rng.pick(["futureRoot", "duration", coll])];
    }
  }
  return out;
}

// ── properties ───────────────────────────────────────────────────────────

const RUNS = 400;

function triples(): Array<{ b: JsonObject; x: JsonObject; y: JsonObject; label: string }> {
  const rng = new Rng(0xcafe);
  const out = [];
  for (let i = 0; i < RUNS; i++) {
    const b = randomDoc(rng);
    out.push({ b, x: mutate(b, rng), y: mutate(b, rng), label: `random #${i}` });
  }
  for (const f of loadFixtures()) {
    out.push({ b: f.base as JsonObject, x: f.mine as JsonObject, y: f.theirs as JsonObject, label: f.name });
  }
  return out;
}

const TRIPLES = triples();

function expectClean(r: ReturnType<typeof merge>, expected: Json, label: string) {
  expect(canonicalJSON(r.merged), label).toBe(canonicalJSON(expected));
  expect(r.conflicts, label).toEqual([]);
  expect(r.autoResolved, label).toEqual([]);
}

describe("merge identity properties", () => {
  it("merge(b, x, b) = x, merge(b, b, y) = y, merge(b, x, x) = x — either last writer", () => {
    for (const { b, x, y, label } of TRIPLES) {
      for (const mineWins of [true, false]) {
        expectClean(merge(b, x, b, mineWins), x, `${label} merge(b,x,b)`);
        expectClean(merge(b, b, y, mineWins), y, `${label} merge(b,b,y)`);
        expectClean(merge(b, x, x, mineWins), x, `${label} merge(b,x,x)`);
        expectClean(merge(b, y, y, mineWins), y, `${label} merge(b,y,y)`);
      }
    }
  });

  it("merge is deterministic and total (canonical JSON, no undefined values)", () => {
    for (const { b, x, y, label } of TRIPLES) {
      const r1 = merge(b, x, y, true);
      const r2 = merge(clone(b), clone(x), clone(y), true);
      expect(canonicalJSON(r1.merged), label).toBe(canonicalJSON(r2.merged));
      expect(JSON.stringify(r1.conflicts)).toBe(JSON.stringify(r2.conflicts));
      expect(JSON.stringify(r1.merged)).not.toContain("undefined");
    }
  });

  it("a conflict flipped by choices applies the other side and keeps its id", () => {
    let flippedAny = 0;
    for (const { b, x, y, label } of TRIPLES) {
      const r = merge(b, x, y, true);
      if (r.conflicts.length === 0) continue;
      const choices = Object.fromEntries(r.conflicts.map((c) => [c.id, "theirs" as const]));
      const f = merge(b, x, y, true, choices);
      for (const c of f.conflicts) if (c.id in choices) expect(c.resolution, label).toBe("theirs");
      flippedAny++;
    }
    expect(flippedAny).toBeGreaterThan(10);
  });
});

describe("unknown keys are never dropped", () => {
  it("a key only one side added (root, settings, element) survives with that side's value", () => {
    const rng = new Rng(0xbeef);
    for (let i = 0; i < RUNS; i++) {
      const b = randomDoc(rng);
      const x = mutate(b, rng);
      const y = mutate(b, rng);
      x[`mineOnly${i}`] = { v: i };
      (x.settings as JsonObject)[`mineSetting${i}`] = i;
      y[`theirsOnly${i}`] = [i];
      (y.settings as JsonObject)[`theirsSetting${i}`] = `t${i}`;
      const zooms = getKey(x, "zoomRegions");
      const target = Array.isArray(zooms) && zooms.length ? (zooms[0] as JsonObject) : null;
      if (target) target[`mineElementKey${i}`] = true;

      for (const mineWins of [true, false]) {
        const r = merge(b, x, y, mineWins);
        const m = r.merged as JsonObject;
        expect(m[`mineOnly${i}`]).toEqual({ v: i });
        expect(m[`theirsOnly${i}`]).toEqual([i]);
        // settings survive unless one side replaced settings wholesale (never in this generator)
        expect((m.settings as JsonObject)[`mineSetting${i}`]).toBe(i);
        expect((m.settings as JsonObject)[`theirsSetting${i}`]).toBe(`t${i}`);
        if (target) {
          const conflicted = r.conflicts.some((c) => c.path.includes(target.id as string));
          const merged = (getKey(m, "zoomRegions") as Json[] | undefined)?.find((e) => getKey(e, "id") === target.id);
          if (merged && !conflicted) expect(getKey(merged, `mineElementKey${i}`)).toBe(true);
        }
      }
    }
  });

  it("a root/settings key only one side changed keeps that side's value", () => {
    for (const { b, x, y, label } of TRIPLES) {
      const r = merge(b, x, y, false);
      const m = r.merged as JsonObject;
      for (const k of Object.keys(x)) {
        if (MERGE_POLICY.collections.some((c) => c.key === k) || k === "settings") continue;
        if (MERGE_POLICY.rootGroups.some((g) => g.keys.includes(k))) continue;
        if (jsonEqual(getKey(y, k), getKey(b, k)) && !jsonEqual(getKey(x, k), getKey(b, k))) {
          expect(getKey(m, k), `${label}: ${k}`).toEqual(getKey(x, k));
        }
      }
    }
  });
});

describe("diff / compose / header", () => {
  it("diff(a, a) is empty; diff(b, x) round-trips through the X-CC-Change header", () => {
    for (const { b, x, label } of TRIPLES) {
      expect(isEmptyChangeSet(diff(b, b)), label).toBe(true);
      expect(formatChangeSummary(diff(b, b))).toBe("No changes");
      const cs = diff(b, x);
      const header = encodeChangeHeader(cs);
      expect(header, label).not.toBeNull();
      expect(header!.length).toBeLessThanOrEqual(8192);
      expect(canonicalJSON(changeSetJSON(decodeChangeHeader(header!)!)), label).toBe(canonicalJSON(changeSetJSON(cs)));
    }
  });

  it("compose with the empty change-set is the identity; compose keeps exact ids", () => {
    for (const { b, x, y, label } of TRIPLES) {
      const cs = diff(b, x);
      const c = (v: ReturnType<typeof diff>) => canonicalJSON(changeSetJSON(v));
      expect(c(composeChangeSets(cs, emptyChangeSet())), label).toBe(c(cs));
      expect(c(composeChangeSets(emptyChangeSet(), cs)), label).toBe(c(cs));
      // a → x → y: an id added in the first step and removed in the second vanishes.
      const composed = composeChangeSets(diff(b, x), diff(x, y));
      for (const [key, change] of Object.entries(composed.items)) {
        if (!change.added) continue;
        const direct = diff(b, y).items[key];
        for (const id of change.added) expect(direct?.added ?? [], `${label}: ${key} ${id}`).toContain(id);
      }
    }
  });

  it("header budget degradation keeps it under maxBytes", () => {
    const big = diff({ subtitles: [] }, { subtitles: Array.from({ length: 400 }, (_, i) => ({ id: `2A000000-0000-4000-8000-${String(i).padStart(12, "0")}`, text: "x" })) });
    const header = encodeChangeHeader(big)!;
    expect(header.length).toBeLessThanOrEqual(8192);
    expect(decodeChangeHeader(header)!.items.subtitles.counts).toEqual({ added: 400, removed: 0, changed: 0 });
    expect(formatChangeSummary(decodeChangeHeader(header)!)).toBe("400 captions added");
  });
});

describe("policy table", () => {
  it("maps every ProjectSettings key to exactly one inspector tab", () => {
    const seen = new Map<string, string>();
    for (const t of MERGE_POLICY.settingsTabs) {
      for (const k of t.keys) {
        expect(seen.has(k), `${k} is in ${seen.get(k)} and ${t.tab}`).toBe(false);
        seen.set(k, t.tab);
      }
    }
    for (const k of PROJECT_SETTINGS_KEYS) expect(settingsTabFor(k), k).not.toBe("other");
    expect([...seen.keys()].sort()).toEqual([...PROJECT_SETTINGS_KEYS].sort());
  });

  it("group keys are real settings / root keys and never overlap", () => {
    const settingsGroupKeys = MERGE_POLICY.settingsGroups.flatMap((g) => g.keys);
    expect(new Set(settingsGroupKeys).size).toBe(settingsGroupKeys.length);
    for (const k of settingsGroupKeys) expect(PROJECT_SETTINGS_KEYS as readonly string[]).toContain(k);
    const rootGroupKeys = MERGE_POLICY.rootGroups.flatMap((g) => g.keys);
    expect(new Set(rootGroupKeys).size).toBe(rootGroupKeys.length);
  });
});
