/**
 * lib/project-history.ts — the pure history rules, and the parity gate that
 * pins the API's COPY of the web merge core's change-set code to the golden
 * vectors the REAL Swift twin wrote (apps/web/src/editor/core/merge/golden/
 * mergePolicy.json). If the web core or Swift changes compose / the header
 * codec / canonical JSON and regenerates its golden, this fails until the
 * copy here is updated too — the three cannot drift apart silently.
 */

import { describe, expect, it } from "vitest";
import golden from "../../../web/src/editor/core/merge/golden/mergePolicy.json";
import {
  CHANGE_HEADER_MAX_BYTES,
  COALESCE_MAX_IDLE_MS,
  COALESCE_MAX_OPEN_MS,
  MAX_CHANGE_JSON_BYTES,
  MAX_HISTORY_BYTES_PER_PROJECT,
  MAX_VERSIONS_PER_PROJECT,
  canonicalJSON,
  canonicalNumber,
  canonicalString,
  changeJSONWithinCap,
  changeSetFromJSON,
  changeSetJSON,
  checkpointHonoured,
  composeChangeSets,
  decodeChangeHeader,
  encodeChangeHeader,
  fnv1a64Hex,
  gunzipBytes,
  gzipBytes,
  manifestText,
  newVersionKind,
  normalizeLabel,
  parseSaveHeaders,
  restoredFileSet,
  selectPrunable,
  shouldExtend,
  versionChangeJSON,
  type ChangeSet,
  type HeadVersion,
  type Json,
  type RetainedVersion,
} from "./project-history";

type Case = { input: Record<string, Json>; output: Record<string, Json> };
const cases = (golden as unknown as { cases: Case[] }).cases;
const byCase = (name: string) => cases.filter((c) => c.input.case === name);

function changeSet(text: Json): ChangeSet {
  const cs = changeSetFromJSON(JSON.parse(text as string) as Json);
  if (!cs) throw new Error(`golden change-set does not parse: ${String(text)}`);
  return cs;
}
const cs = (c: ChangeSet) => canonicalJSON(changeSetJSON(c));

// ---------------------------------------------------------------------------
// Parity with the web merge core (Swift-written golden vectors)
// ---------------------------------------------------------------------------

describe("change-set parity with the web merge core (golden/mergePolicy.json)", () => {
  it("the golden file is the one the web core tests against", () => {
    expect((golden as { unit: string }).unit).toBe("mergePolicy");
    // Fails — never skips — when the vectors this copy is pinned to vanish.
    for (const name of ["number", "string", "json", "compose", "header", "decodeHeader"]) {
      expect(byCase(name).length, name).toBeGreaterThan(0);
    }
  });

  it("canonical numbers, strings and JSON texts (+ FNV-1a hash) match", () => {
    const numbers = byCase("number");
    expect(numbers.length).toBeGreaterThan(100);
    for (const c of numbers) expect(canonicalNumber(c.input.value as number), `value ${String(c.input.value)}`).toBe(c.output.canonical);
    for (const c of byCase("string")) expect(canonicalString(c.input.value as string)).toBe(c.output.canonical);
    for (const c of byCase("json")) {
      const canonical = canonicalJSON(JSON.parse(c.input.text as string) as Json);
      expect(canonical, `text ${String(c.input.text)}`).toBe(c.output.canonical);
      expect(fnv1a64Hex(canonical)).toBe(c.output.hash);
    }
  });

  it("composeChangeSets matches", () => {
    const compose = byCase("compose");
    expect(compose.length).toBeGreaterThan(0);
    for (const c of compose) {
      const composed = composeChangeSets(changeSet(c.input.x), changeSet(c.input.y));
      expect(cs(composed), `compose ${String(c.input.x)} + ${String(c.input.y)}`).toBe(c.output.composed);
    }
  });

  it("X-CC-Change encode (with budget degradation) and decode match", () => {
    const encode = byCase("header");
    expect(encode.some((c) => c.output.header === null)).toBe(true);
    for (const c of encode) {
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

// ---------------------------------------------------------------------------
// Save headers
// ---------------------------------------------------------------------------

const zoomAdded: ChangeSet = { v: 1, items: { zoomRegions: { added: ["Z1"] } }, settings: {}, fields: [] };
const zoomEdited: ChangeSet = {
  v: 1,
  items: { zoomRegions: { changed: { Z1: ["zoomLevel"], Z2: ["startTime"] } } },
  settings: { background: ["backgroundPadding"] },
  fields: ["name"],
};

function headersOf(h: Record<string, string>) {
  return parseSaveHeaders((name) => h[name]);
}

describe("parseSaveHeaders", () => {
  it("old clients send nothing and get neutral values", () => {
    expect(headersOf({})).toEqual({
      clientKind: "unknown",
      clientId: null,
      source: "human",
      change: null,
      checkpoint: null,
      mergedFrom: null,
    });
  });

  it("reads every header", () => {
    const header = encodeChangeHeader(zoomAdded)!;
    expect(
      headersOf({
        "X-CC-Client": "web",
        "X-CC-Client-Id": "br_0123-abc",
        "X-CC-Source": "agent",
        "X-CC-Change": header,
        "X-CC-Checkpoint": "merge",
        "X-CC-Merged-From": "41",
      }),
    ).toEqual({
      clientKind: "web",
      clientId: "br_0123-abc",
      source: "agent",
      change: zoomAdded,
      checkpoint: "merge",
      mergedFrom: 41,
    });
  });

  it("junk degrades to neutral and never throws", () => {
    const h = headersOf({
      "X-CC-Client": "ios",
      "X-CC-Client-Id": "has space",
      "X-CC-Source": "robot",
      "X-CC-Change": "!!!not-base64",
      "X-CC-Checkpoint": "everything",
      "X-CC-Merged-From": "-3",
    });
    expect(h).toEqual({ clientKind: "unknown", clientId: null, source: "human", change: null, checkpoint: null, mergedFrom: null });
    expect(headersOf({ "X-CC-Client-Id": "x".repeat(65) }).clientId).toBeNull();
    expect(headersOf({ "X-CC-Change": "A".repeat(CHANGE_HEADER_MAX_BYTES + 1) }).change).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Coalescing
// ---------------------------------------------------------------------------

const T0 = Date.parse("2026-10-01T12:00:00.000Z");
const iso = (ms: number) => new Date(ms).toISOString();

function head(over: Partial<HeadVersion> = {}): HeadVersion {
  return {
    kind: "edit",
    label: null,
    actorUid: "ana",
    clientId: "web-1",
    source: "human",
    openedAt: iso(T0),
    updatedAt: iso(T0),
    ...over,
  };
}
const ana = { actorUid: "ana", clientId: "web-1", source: "human" as const };

describe("shouldExtend (coalescing)", () => {
  it("extends: same actor + client + source, unnamed edit, fresh", () => {
    expect(shouldExtend(head(), ana, T0 + 30_000, false)).toBe(true);
  });

  it("opens a new version when any condition fails", () => {
    expect(shouldExtend(null, ana, T0, false)).toBe(false);
    expect(shouldExtend(head(), ana, T0 + 1000, true)).toBe(false); // honoured checkpoint
    expect(shouldExtend(head({ kind: "upload" }), ana, T0 + 1000, false)).toBe(false);
    expect(shouldExtend(head({ kind: "merge" }), ana, T0 + 1000, false)).toBe(false);
    expect(shouldExtend(head({ kind: "restore" }), ana, T0 + 1000, false)).toBe(false);
    expect(shouldExtend(head({ label: "Draft" }), ana, T0 + 1000, false)).toBe(false);
    expect(shouldExtend(head({ actorUid: "bo" }), ana, T0 + 1000, false)).toBe(false);
    expect(shouldExtend(head({ clientId: "mac-1" }), ana, T0 + 1000, false)).toBe(false);
    expect(shouldExtend(head({ source: "agent" }), ana, T0 + 1000, false)).toBe(false);
  });

  it("time windows: opened < 10 min AND updated < 3 min", () => {
    const opened = head({ openedAt: iso(T0), updatedAt: iso(T0 + COALESCE_MAX_OPEN_MS - 60_000) });
    expect(shouldExtend(opened, ana, T0 + COALESCE_MAX_OPEN_MS - 1, false)).toBe(true);
    expect(shouldExtend(opened, ana, T0 + COALESCE_MAX_OPEN_MS, false)).toBe(false);
    const idle = head({ updatedAt: iso(T0) });
    expect(shouldExtend(idle, ana, T0 + COALESCE_MAX_IDLE_MS - 1, false)).toBe(true);
    expect(shouldExtend(idle, ana, T0 + COALESCE_MAX_IDLE_MS, false)).toBe(false);
  });

  it("an old client (no client id) coalesces with itself per actor", () => {
    expect(shouldExtend(head({ clientId: null }), { ...ana, clientId: null }, T0 + 1000, false)).toBe(true);
    expect(shouldExtend(head({ clientId: null }), ana, T0 + 1000, false)).toBe(false);
  });

  it("checkpoints are honoured at most once a minute per project", () => {
    const cp = headersOf({ "X-CC-Checkpoint": "push" });
    expect(checkpointHonoured(headersOf({}), null, T0)).toBe(false);
    expect(checkpointHonoured(cp, null, T0)).toBe(true);
    expect(checkpointHonoured(cp, iso(T0 - 59_000), T0)).toBe(false);
    expect(checkpointHonoured(cp, iso(T0 - 60_000), T0)).toBe(true);
    expect(checkpointHonoured(headersOf({ "X-CC-Merged-From": "3" }), iso(T0 - 1000), T0)).toBe(false);
  });

  it("new-version kinds", () => {
    expect(newVersionKind(0, headersOf({}))).toBe("upload");
    expect(newVersionKind(0, headersOf({ "X-CC-Merged-From": "1" }))).toBe("upload");
    expect(newVersionKind(4, headersOf({}))).toBe("edit");
    expect(newVersionKind(4, headersOf({ "X-CC-Checkpoint": "push" }))).toBe("edit");
    expect(newVersionKind(4, headersOf({ "X-CC-Checkpoint": "named" }))).toBe("edit");
    expect(newVersionKind(4, headersOf({ "X-CC-Checkpoint": "merge" }))).toBe("merge");
    expect(newVersionKind(4, headersOf({ "X-CC-Merged-From": "3" }))).toBe("merge");
    expect(newVersionKind(4, headersOf({ "X-CC-Checkpoint": "restore" }))).toBe("restore");
    expect(newVersionKind(4, headersOf({ "X-CC-Checkpoint": "upload" }))).toBe("upload");
  });
});

describe("version change_json", () => {
  it("new version = the save's own change-set; extended = head ∘ save; unknown is contagious", () => {
    expect(versionChangeJSON(null, zoomAdded, false)).toBe(cs(zoomAdded));
    expect(versionChangeJSON(null, null, false)).toBeNull();
    const composed = versionChangeJSON(cs(zoomAdded), zoomEdited, true);
    // add + change = add (docs/project-history.md §4)
    expect(JSON.parse(composed!)).toEqual({
      v: 1,
      items: { zoomRegions: { added: ["Z1"], changed: { Z2: ["startTime"] } } },
      settings: { background: ["backgroundPadding"] },
      fields: ["name"],
    });
    expect(versionChangeJSON(null, zoomEdited, true)).toBeNull(); // head unknown
    expect(versionChangeJSON(cs(zoomAdded), null, true)).toBeNull(); // save unknown
    expect(versionChangeJSON("{garbage", zoomEdited, true)).toBeNull();
  });

  it("caps change_json at 32 KB by degrading the largest id list to counts", () => {
    const ids = Array.from({ length: 2000 }, (_, i) => `id-${String(i).padStart(6, "0")}-${"x".repeat(20)}`);
    const big: ChangeSet = { v: 1, items: { subtitles: { added: ids }, zoomRegions: { added: ["Z"] } }, settings: {}, fields: [] };
    expect(cs(big).length).toBeGreaterThan(MAX_CHANGE_JSON_BYTES);
    const capped = changeJSONWithinCap(big)!;
    expect(new TextEncoder().encode(capped).byteLength).toBeLessThanOrEqual(MAX_CHANGE_JSON_BYTES);
    expect(JSON.parse(capped).items).toEqual({
      subtitles: { counts: { added: 2000, changed: 0, removed: 0 } },
      zoomRegions: { added: ["Z"] },
    });
  });
});

// ---------------------------------------------------------------------------
// Retention
// ---------------------------------------------------------------------------

const DAY = 86_400_000;
const NOW = Date.parse("2026-10-01T00:00:00.000Z");

function v(seq: number, ageDays: number, label: string | null = null, storedBytes = 100): RetainedVersion {
  return { id: `v${seq}`, seq, label, updatedAt: iso(NOW - ageDays * DAY), storedBytes };
}

describe("selectPrunable", () => {
  const history = [v(1, 400), v(2, 200, "Launch cut"), v(3, 40), v(4, 29), v(5, 2, "Review"), v(6, 0)];
  const headId = "v6";

  it("Pro (30 days + 25 named): unnamed beyond 30 days go; named are exempt from the window", () => {
    expect(selectPrunable(history, headId, { maxHistoryDays: 30, maxNamedVersions: 25 }, NOW)).toEqual(["v1", "v3"]);
  });

  it("Business (365 days + 500 named) keeps more", () => {
    expect(selectPrunable(history, headId, { maxHistoryDays: 365, maxNamedVersions: 500 }, NOW)).toEqual(["v1"]);
  });

  it("Free / a downgrade to no history: everything but the head goes — named too", () => {
    expect(selectPrunable(history, headId, { maxHistoryDays: 0, maxNamedVersions: 0 }, NOW)).toEqual([
      "v1",
      "v2",
      "v3",
      "v4",
      "v5",
    ]);
  });

  it("a downgrade below the named count un-exempts the OLDEST named first", () => {
    // 1 named slot: "Review" (newer) stays exempt; "Launch cut" falls under the 30-day window.
    expect(selectPrunable(history, headId, { maxHistoryDays: 30, maxNamedVersions: 1 }, NOW)).toEqual(["v1", "v2", "v3"]);
  });

  it("never the head, however old", () => {
    expect(selectPrunable([v(1, 900)], "v1", { maxHistoryDays: 0, maxNamedVersions: 0 }, NOW)).toEqual([]);
  });

  it("the 1000-version cap evicts the oldest unnamed first", () => {
    const many = Array.from({ length: MAX_VERSIONS_PER_PROJECT + 5 }, (_, i) =>
      v(i + 1, 0, i === 0 ? "first" : null),
    );
    const doomed = selectPrunable(many, `v${many.length}`, { maxHistoryDays: 30, maxNamedVersions: 25 }, NOW);
    // The named v1 survives; v2…v6 (oldest unnamed) go.
    expect(doomed).toEqual(["v2", "v3", "v4", "v5", "v6"]);
  });

  it("the 256 MB history cap evicts the oldest unnamed first", () => {
    const mb = 1024 * 1024;
    const big = [v(1, 1, null, 100 * mb), v(2, 1, "keep", 100 * mb), v(3, 1, null, 50 * mb), v(4, 0, null, 50 * mb)];
    expect(big.reduce((s, x) => s + x.storedBytes, 0)).toBeGreaterThan(MAX_HISTORY_BYTES_PER_PROJECT);
    expect(selectPrunable(big, "v4", { maxHistoryDays: 30, maxNamedVersions: 25 }, NOW)).toEqual(["v1"]);
  });

  it("maxDeletes bounds one pass (oldest first)", () => {
    expect(selectPrunable(history, headId, { maxHistoryDays: 0, maxNamedVersions: 0 }, NOW, { maxDeletes: 2 })).toEqual([
      "v1",
      "v2",
    ]);
  });
});

// ---------------------------------------------------------------------------
// Manifests, labels, gzip
// ---------------------------------------------------------------------------

describe("manifests and labels", () => {
  const a = { path: "recording.mov", sha256: "a".repeat(64), bytes: 10, contentType: "video/quicktime", source: null };
  const b = { path: "cursor.json", sha256: "b".repeat(64), bytes: 2, contentType: "application/json", source: null };
  const a2 = { ...a, sha256: "c".repeat(64) };

  it("the manifest text is order-independent (content-addressed)", () => {
    expect(manifestText([a, b])).toBe(manifestText([b, a]));
    expect(manifestText([a, b])).not.toBe(manifestText([a2, b]));
  });

  it("restore's file set: the version's paths win, the current ones stay", () => {
    const extra = { ...b, path: "voiceover.m4a", contentType: "audio/mp4" };
    expect(restoredFileSet([a2, extra], [a, b]).map((f) => [f.path, f.sha256[0]])).toEqual([
      ["cursor.json", "b"],
      ["recording.mov", "a"],
      ["voiceover.m4a", "b"],
    ]);
  });

  it("labels", () => {
    expect(normalizeLabel("  Final cut ")).toEqual({ ok: true, label: "Final cut" });
    expect(normalizeLabel("")).toEqual({ ok: true, label: null });
    expect(normalizeLabel(null)).toEqual({ ok: true, label: null });
    expect(normalizeLabel("x".repeat(101)).ok).toBe(false);
    expect(normalizeLabel("bad\nlabel").ok).toBe(false);
    expect(normalizeLabel(5).ok).toBe(false);
  });
});

describe("gzip snapshots", () => {
  it("round-trips byte-exact (odd whitespace, a BOM, astral characters, number spellings)", async () => {
    const text = '﻿{\n  "name" : "Démo 🎬",\n  "x" : 1.50, "y": -0.0, "z" : 1e21\n}\r\n';
    const bytes = new TextEncoder().encode(text);
    const gz = await gzipBytes(bytes);
    expect(gz[0]).toBe(0x1f);
    expect(gz[1]).toBe(0x8b);
    expect([...(await gunzipBytes(gz))]).toEqual([...bytes]);
    const big = new TextEncoder().encode(JSON.stringify({ subtitles: Array.from({ length: 2000 }, (_, i) => ({ i, t: "word" })) }));
    const bigGz = await gzipBytes(big);
    expect(bigGz.byteLength).toBeLessThan(big.byteLength / 5);
    expect([...(await gunzipBytes(bigGz))]).toEqual([...big]);
  });
});
