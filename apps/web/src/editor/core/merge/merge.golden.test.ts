/**
 * Project-history parity gate — the TS core (core/merge) against the REAL
 * Swift (apps/macos/CaptureCat/Services/ProjectHistory).
 *
 * golden/{mergePolicy,mergeRandom,projectMerge}.json are written by
 * `CaptureCat --web-vectors … --only mergePolicy,mergeRandom,projectMerge`
 * (apps/web/scripts/merge-vectors.sh): projectMerge over the committed
 * fixtures, mergeRandom over Swift-generated random triples (inputs recorded). Everything is
 * compared as EXACT strings: canonical JSON of merged documents, conflict
 * lists, auto-resolution logs, change-sets, headers, and summary captions.
 *
 * Fails — never skips — when a golden file is missing, when the policy
 * table's hash differs from Swift's, or when a fixture changed after the
 * golden was recorded (fixture hash mismatch).
 */
import { describe, expect, it } from "vitest";

import { parseProject } from "../model";
import { countChanges, formatChangeSummary } from "./changeSummary";
import { canonicalJSON, canonicalNumber, canonicalString, fnv1a64Hex, jsonEqual, type Json, type Side } from "./jsonMerge";
import { policyHash, policyJSON } from "./policy";
import { merge, type MergeResult } from "./projectMerge";
import {
  changeSetFromJSON,
  changeSetJSON,
  composeChangeSets,
  decodeChangeHeader,
  diff,
  encodeChangeHeader,
  type ChangeSet,
} from "./projectDiff";
import { fixtureHash, loadFixtures, loadGolden, type MergeFixture } from "./goldenFiles";

type Out = Record<string, Json>;

const policyGolden = loadGolden<Out, Out>("mergePolicy");
const randomGolden = loadGolden<Out, Out>("mergeRandom");
const mergeGolden = loadGolden<Out, Out>("projectMerge");
const fixtures = new Map(loadFixtures().map((f) => [f.name, f]));

function changeSet(text: Json): ChangeSet {
  const cs = changeSetFromJSON(JSON.parse(text as string) as Json);
  if (!cs) throw new Error(`golden change-set does not parse: ${String(text)}`);
  return cs;
}

const cs = (c: ChangeSet) => canonicalJSON(changeSetJSON(c));

/** A variant whose merge equals the default merge is stored as "=default". */
function resultStrings(r: MergeResult, defaultMerged?: Json): Out {
  return {
    merged: defaultMerged !== undefined && jsonEqual(defaultMerged, r.merged) ? "=default" : canonicalJSON(r.merged),
    conflicts: canonicalJSON(r.conflicts as unknown as Json),
    autoResolved: canonicalJSON(r.autoResolved as unknown as Json),
  };
}

/** Every output field of one fixture, computed by the TS core. */
function fixtureOutputs(f: MergeFixture): Out {
  const result = merge(f.base, f.mine, f.theirs, f.mineWins);
  const choices: Record<string, Side> = {};
  for (const c of result.conflicts) choices[c.id] = c.resolution === "mine" ? "theirs" : "mine";
  const flipped = merge(f.base, f.mine, f.theirs, f.mineWins, choices);
  const reversed = merge(f.base, f.mine, f.theirs, !f.mineWins);
  const diffMine = diff(f.base, f.mine);
  const diffTheirs = diff(f.base, f.theirs);
  const diffMerged = diff(f.base, result.merged);
  const composed = composeChangeSets(diffMine, diff(f.mine, result.merged));
  return {
    default: resultStrings(result),
    flippedChoices: canonicalJSON(choices),
    flipped: resultStrings(flipped, result.merged),
    reversed: resultStrings(reversed, result.merged),
    diffMine: cs(diffMine),
    diffTheirs: cs(diffTheirs),
    diffMerged: cs(diffMerged),
    composed: cs(composed),
    summaryMine: formatChangeSummary(diffMine),
    summaryTheirs: formatChangeSummary(diffTheirs),
    summaryMerged: formatChangeSummary(diffMerged),
    summaryMergedShort: formatChangeSummary(diffMerged, 1),
    summaryComposed: formatChangeSummary(composed),
    countMerged: countChanges(diffMerged),
    header: encodeChangeHeader(diffMerged),
    headerSmall: encodeChangeHeader(diffMerged, 96),
  };
}

/** First differing field path between two output trees (strings exact). */
function mismatch(actual: Json | undefined, expected: Json | undefined, path: string): string | null {
  if (expected !== null && typeof expected === "object" && !Array.isArray(expected)) {
    if (actual === null || typeof actual !== "object" || Array.isArray(actual)) return `${path}: not an object`;
    for (const k of Object.keys(expected)) {
      const m = mismatch((actual as Out)[k], expected[k], `${path}.${k}`);
      if (m) return m;
    }
    return null;
  }
  if (actual === expected) return null;
  const a = String(actual);
  const e = String(expected);
  let i = 0;
  while (i < a.length && i < e.length && a[i] === e[i]) i++;
  return `${path} differs at char ${i}\n  swift: …${e.slice(Math.max(0, i - 60), i + 120)}\n  ts:    …${a.slice(Math.max(0, i - 60), i + 120)}`;
}

describe("merge policy parity (mergePolicy golden)", () => {
  const byCase = (name: string) => policyGolden.cases.filter((c) => c.input.case === name);

  it("the policy table is the one Swift hashed", () => {
    const [policy] = byCase("policy");
    expect(canonicalJSON(policyJSON()), "policy table differs from MergePolicy.swift").toBe(policy.output.policyJSON);
    expect(policyHash()).toBe(policy.output.policyHash);
  });

  it("canonical numbers match Swift (ECMAScript Number::toString)", () => {
    const cases = byCase("number");
    expect(cases.length).toBeGreaterThan(100);
    for (const c of cases) expect(canonicalNumber(c.input.value as number), `value ${String(c.input.value)}`).toBe(c.output.canonical);
  });

  it("canonical strings and JSON texts match Swift", () => {
    for (const c of byCase("string")) expect(canonicalString(c.input.value as string)).toBe(c.output.canonical);
    for (const c of byCase("json")) {
      const canonical = canonicalJSON(JSON.parse(c.input.text as string) as Json);
      expect(canonical, `text ${String(c.input.text)}`).toBe(c.output.canonical);
      expect(fnv1a64Hex(canonical)).toBe(c.output.hash);
    }
  });

  it("composeChangeSets matches Swift", () => {
    const cases = byCase("compose");
    expect(cases.length).toBeGreaterThan(0);
    for (const c of cases) {
      const composed = composeChangeSets(changeSet(c.input.x), changeSet(c.input.y));
      expect(cs(composed), `compose ${String(c.input.x)} + ${String(c.input.y)}`).toBe(c.output.composed);
      expect(formatChangeSummary(composed)).toBe(c.output.summary);
      expect(countChanges(composed)).toBe(c.output.count);
    }
  });

  it("formatChangeSummary / countChanges match Swift", () => {
    const cases = byCase("summary");
    expect(cases.length).toBeGreaterThan(0);
    for (const c of cases) {
      const set = changeSet(c.input.changeSet);
      expect(formatChangeSummary(set, c.input.maxParts as number), String(c.input.changeSet)).toBe(c.output.summary);
      expect(countChanges(set)).toBe(c.output.count);
    }
  });

  it("X-CC-Change encode (with budget degradation) and decode match Swift", () => {
    const encodeCases = byCase("header");
    expect(encodeCases.some((c) => c.output.header === null)).toBe(true);
    for (const c of encodeCases) {
      const header = encodeChangeHeader(changeSet(c.input.changeSet), c.input.maxBytes as number);
      expect(header, `maxBytes ${String(c.input.maxBytes)}`).toBe(c.output.header);
      const decoded = header === null ? null : decodeChangeHeader(header);
      expect(decoded === null ? null : cs(decoded)).toBe(c.output.decoded);
    }
    for (const c of byCase("decodeHeader")) {
      const decoded = decodeChangeHeader(c.input.header as string);
      expect(decoded === null ? null : cs(decoded), `header ${String(c.input.header)}`).toBe(c.output.decoded);
    }
  });
});

describe("random-triple merge parity (mergeRandom golden)", () => {
  it("every Swift-generated random triple merges identically in TS", () => {
    expect(randomGolden.cases.length).toBeGreaterThan(20);
    let clashes = 0;
    randomGolden.cases.forEach((c, i) => {
      const [base, mine, theirs] = [c.input.base, c.input.mine, c.input.theirs];
      const mineWins = c.input.mineWins as boolean;
      const result = merge(base, mine, theirs, mineWins);
      const choices: Record<string, Side> = {};
      for (const k of result.conflicts) choices[k.id] = k.resolution === "mine" ? "theirs" : "mine";
      const diffMerged = diff(base, result.merged);
      const actual: Out = {
        default: resultStrings(result),
        flipped: resultStrings(merge(base, mine, theirs, mineWins, choices), result.merged),
        diffMerged: cs(diffMerged),
        summaryMerged: formatChangeSummary(diffMerged),
      };
      const m = mismatch(actual, c.output, `random #${i}`);
      expect(m, m ?? "").toBeNull();
      if (result.conflicts.length || result.autoResolved.length) clashes++;
    });
    // The generator is biased toward clashes; a good share must exercise them.
    expect(clashes).toBeGreaterThan(randomGolden.cases.length / 3);
  });
});

describe("project merge parity (projectMerge golden, every fixture)", () => {
  it("the golden covers exactly the committed fixtures, and none is stale", () => {
    const golden = new Map(mergeGolden.cases.map((c) => [c.input.fixture as string, c]));
    expect([...golden.keys()].sort(), "fixture set differs from the golden — regenerate it").toEqual([...fixtures.keys()].sort());
    for (const [name, f] of fixtures) {
      expect(fixtureHash(f), `fixture ${name} changed after the golden was recorded — regenerate it`).toBe(
        golden.get(name)!.input.fixtureHash,
      );
      expect(golden.get(name)!.input.mineWins).toBe(f.mineWins);
    }
  });

  it("Swift decoded every input and merged output with the real Project Codable", () => {
    for (const c of mergeGolden.cases) {
      for (const [label, ok] of Object.entries(c.output.decodes as Out)) {
        expect(ok, `${String(c.input.fixture)}: ${label} does not decode on the Mac`).toBe(true);
      }
    }
  });

  for (const c of mergeGolden.cases) {
    const name = c.input.fixture as string;
    it(name, () => {
      const f = fixtures.get(name);
      expect(f, `fixture ${name} is missing`).toBeDefined();
      const actual = fixtureOutputs(f!);
      const expected: Out = { ...c.output };
      delete expected.decodes;
      const m = mismatch(actual, expected, name);
      expect(m, m ?? "").toBeNull();
      // The web can open every merged output too.
      for (const variant of ["default", "flipped", "reversed"]) {
        const text = (actual[variant] as Out).merged as string;
        if (text === "=default") continue;
        const merged = JSON.parse(text) as Json;
        expect(() => parseProject(merged), `${name}: ${variant} merged does not parse`).not.toThrow();
      }
    });
  }
});
