/**
 * Auto Zoom + Motion parity gate — the TS port (core/math/autoZoomGenerator,
 * core/math/stillMotion, core/edit/autoZoom) against the REAL Swift.
 *
 * `golden/autoZoom.json` was recorded by driving the Mac binary's MCP
 * `auto_zoom` tool (`CaptureCat --mcp`, single-edit path → MCPServer.opAutoZoom
 * → AutoZoomApplier.apply(to:zoomLevel:) / StillMotionApplier.apply(to:)) over
 * synthetic projects (cursor.json / keys.json / tiny ffmpeg videos built in a
 * throwaway folder in the app's container tmp, deleted afterwards), and reading
 * back the project.json it wrote. Synthetic data only.
 *
 * Each case replays the same inputs through `runAutoZoomOp` on a project
 * parsed with the real `parseProject`, serializes it with `serializeProject`,
 * and requires: same ok/error (+ message, + project untouched on error), same
 * mode and created count, and zoom/tilt regions equal key-for-key — numbers
 * within 1e-9, strings/bools exact, ids "kept:<input id>" vs "new".
 *
 * Cursor events are not stored (size): the golden stores the generator spec,
 * `buildCursorEvents` below rebuilds them (a verbatim copy of the recorder's
 * builder), and a count + cyrb53 digest proves they are the bytes the Swift
 * read. The suite FAILS — never skips — when the golden file is missing.
 */
import { describe, expect, it } from "vitest";
import { parseProject, serializeProject } from "../model";
import type { CursorEvent, KeystrokeEvent, Project } from "../model/types";
import {
  applyAutoZoom,
  applyStillMotion,
  parseCursorFile,
  parseKeystrokeFile,
  runAutoZoomOp,
  tryParseCursorFile,
  tryParseKeystrokeFile,
} from "../edit/autoZoom";
import { generateZoomRegions, stableSortByStart } from "../math/autoZoomGenerator";
import { smooth } from "../math/cursorSmoother";

// ── golden loading (node:fs lazily, like harness.ts) ─────────────────────────

type ProcessLike = { getBuiltinModule?: (id: string) => unknown };
type NodeFS = { readFileSync(path: string, encoding: "utf8"): string; existsSync(path: string): boolean };
type NodeURL = { fileURLToPath(url: string | URL): string };

const GOLDEN_HELP =
  "Golden file src/editor/core/vectors/golden/autoZoom.json is missing. It is recorded from the REAL " +
  "Swift by driving `CaptureCat --mcp` `auto_zoom` over synthetic projects (see this file's header); " +
  "restore it from git or re-record it — never hand-edit expectations.";

interface CursorSpec {
  fps: number;
  duration: number;
  tOffset?: number;
  path: [number, number, number][];
  presses?: [number, number][];
  jitter?: number;
  seed?: number;
  drop?: number;
}

interface GoldenRegion {
  idKind: string;
  [key: string]: unknown;
}

type Expected =
  | { ok: false; error: string; unchanged: boolean }
  | { ok: true; mode: "auto-zoom" | "still-motion"; created: number; zoomRegions: GoldenRegion[]; tiltRegions: GoldenRegion[] };

interface GoldenCase {
  name: string;
  projectPatch: Record<string, unknown>;
  settingsPatch: Record<string, unknown>;
  videoNaturalSize: [number, number] | null;
  cursor: {
    format: "recording" | "bare" | "invalid" | "empty" | "missing" | "none";
    coord?: [number, number];
    spec?: CursorSpec;
    count?: number;
    digest?: number;
  };
  keys?: { file: unknown; referenced: boolean };
  zoomLevelArg?: number;
  expected: Expected;
}

interface GoldenFile {
  unit: string;
  notes: string;
  baseProject: Record<string, unknown>;
  count: number;
  cases: GoldenCase[];
}

function loadGolden(): GoldenFile {
  const proc = (globalThis as { process?: ProcessLike }).process;
  if (!proc?.getBuiltinModule) throw new Error("autoZoom golden needs Node >= 22.3 (process.getBuiltinModule).");
  const fs = proc.getBuiltinModule("node:fs") as NodeFS;
  const url = proc.getBuiltinModule("node:url") as NodeURL;
  const path = url.fileURLToPath(new URL("./golden/autoZoom.json", import.meta.url));
  if (!fs.existsSync(path)) throw new Error(GOLDEN_HELP);
  const file = JSON.parse(fs.readFileSync(path, "utf8")) as GoldenFile;
  if (!Array.isArray(file.cases) || file.cases.length === 0) throw new Error(`autoZoom golden has no cases. ${GOLDEN_HELP}`);
  return file;
}

// ── the recorder's cursor builder (VERBATIM copy — the digest proves it) ─────

function mulberry32(seed: number): () => number {
  let a = seed | 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function buildCursorEvents(spec: CursorSpec): CursorEvent[] {
  const fps = spec.fps;
  const tOffset = spec.tOffset ?? 0;
  const frames = Math.floor(spec.duration * fps);
  const pts = spec.path;
  const presses = spec.presses ?? [];
  const jitter = spec.jitter ?? 0;
  const drop = spec.drop ?? 0;
  const rnd = mulberry32(spec.seed ?? 1);
  const first = pts[0];
  const last = pts[pts.length - 1];
  const out: CursorEvent[] = [];
  for (let i = 0; i <= frames; i++) {
    const t = tOffset + i / fps;
    let x: number;
    let y: number;
    if (t <= first[0]) {
      x = first[1];
      y = first[2];
    } else if (t >= last[0]) {
      x = last[1];
      y = last[2];
    } else {
      x = last[1];
      y = last[2];
      for (let j = 1; j < pts.length; j++) {
        if (t <= pts[j][0]) {
          const [t0, x0, y0] = pts[j - 1];
          const [t1, x1, y1] = pts[j];
          const f = t1 > t0 ? (t - t0) / (t1 - t0) : 0;
          x = x0 + (x1 - x0) * f;
          y = y0 + (y1 - y0) * f;
          break;
        }
      }
    }
    const pressed = presses.some(([s, e]) => t >= s && t < e);
    let jx = 0;
    let jy = 0;
    if (jitter > 0) {
      jx = (rnd() - 0.5) * 2 * jitter;
      jy = (rnd() - 0.5) * 2 * jitter;
    }
    if (drop > 0 && rnd() < drop && i > 0) continue;
    out.push({ timestamp: t, x: x + jx, y: y + jy, isClick: pressed });
  }
  return out;
}

function cyrb53(str: string, seed = 0): number {
  let h1 = 0xdeadbeef ^ seed;
  let h2 = 0x41c6ce57 ^ seed;
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
  h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
  h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return 4294967296 * (2097151 & h2) + (h1 >>> 0);
}

// ── comparison ───────────────────────────────────────────────────────────────

const ABS_TOL = 1e-9;
let maxAbsDiff = 0;
let numbersCompared = 0;

/** Exact structural compare: same key sets, numbers within 1e-9, rest exact. */
function mismatch(actual: unknown, expected: unknown, path: string): string | null {
  if (typeof expected === "number") {
    if (typeof actual !== "number") return `${path}: expected ${expected}, got ${JSON.stringify(actual)}`;
    const d = Math.abs(actual - expected);
    numbersCompared++;
    if (d > maxAbsDiff) maxAbsDiff = d;
    return d <= ABS_TOL ? null : `${path}: expected ${expected}, got ${actual} (Δ=${d})`;
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) return `${path}: expected array, got ${JSON.stringify(actual)}`;
    if (actual.length !== expected.length) return `${path}: expected length ${expected.length}, got ${actual.length}`;
    for (let i = 0; i < expected.length; i++) {
      const m = mismatch(actual[i], expected[i], `${path}[${i}]`);
      if (m) return m;
    }
    return null;
  }
  if (expected !== null && typeof expected === "object") {
    if (actual === null || typeof actual !== "object" || Array.isArray(actual)) {
      return `${path}: expected object, got ${JSON.stringify(actual)}`;
    }
    const ek = Object.keys(expected).sort();
    const ak = Object.keys(actual).sort();
    if (ek.join(",") !== ak.join(",")) return `${path}: keys [${ak}] ≠ Swift [${ek}]`;
    for (const k of ek) {
      const m = mismatch((actual as Record<string, unknown>)[k], (expected as Record<string, unknown>)[k], `${path}.${k}`);
      if (m) return m;
    }
    return null;
  }
  return actual === expected ? null : `${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
}

function withIdKinds(regions: unknown, inputIds: Set<string>): GoldenRegion[] {
  return (regions as Record<string, unknown>[]).map((r) => {
    const { id, ...rest } = r;
    return { idKind: inputIds.has(id as string) ? `kept:${id as string}` : "new", ...rest };
  });
}

// ── replay ───────────────────────────────────────────────────────────────────

function cursorFileFor(c: GoldenCase, events: CursorEvent[] | null): unknown | undefined {
  const coord = c.cursor.coord ?? [0, 0];
  switch (c.cursor.format) {
    case "recording":
      return { version: 1, coordinateWidth: coord[0], coordinateHeight: coord[1], events };
    case "bare":
      return events;
    case "invalid": {
      const bad: Record<string, unknown>[] = (events ?? []).map((e) => ({ ...e }));
      bad[Math.floor(bad.length / 2)].isClick = 1;
      return { version: 1, coordinateWidth: 0, coordinateHeight: 0, events: bad };
    }
    case "empty":
      return { version: 1, coordinateWidth: 0, coordinateHeight: 0, events: [] };
    case "missing":
    case "none":
      return undefined;
  }
}

function projectFor(golden: GoldenFile, c: GoldenCase): Project {
  const base = golden.baseProject;
  const doc = {
    ...base,
    ...c.projectPatch,
    settings: { ...(base.settings as Record<string, unknown>), ...c.settingsPatch },
  };
  return parseProject(JSON.parse(JSON.stringify(doc)));
}

let golden: GoldenFile | null = null;
let loadError: unknown = null;
try {
  golden = loadGolden();
} catch (error) {
  loadError = error;
}

describe("autoZoom golden (real Swift via MCP auto_zoom)", () => {
  it("golden file is present and well-formed", () => {
    if (loadError) throw loadError;
    expect(golden).not.toBeNull();
    expect(golden!.unit).toBe("autoZoom");
    expect(golden!.cases.length).toBe(golden!.count);
    expect(golden!.cases.length).toBeGreaterThanOrEqual(40);
  });

  for (const c of golden?.cases ?? []) {
    it(c.name, () => {
      const g = golden!;
      // 1. Rebuild the exact cursor samples the Swift read.
      let events: CursorEvent[] | null = null;
      if (c.cursor.spec) {
        events = buildCursorEvents(c.cursor.spec);
        expect(events.length, "cursor sample count").toBe(c.cursor.count);
        expect(cyrb53(JSON.stringify(events)), "cursor digest (builder drifted from the recorder)").toBe(
          c.cursor.digest,
        );
      }
      const file = cursorFileFor(c, events);
      const cursor = file === undefined ? null : tryParseCursorFile(file);
      const keystrokes: KeystrokeEvent[] = c.keys ? tryParseKeystrokeFile(c.keys.file) : [];

      // 2. Same project the Swift decoded, same op.
      const project = projectFor(g, c);
      const before = JSON.stringify(serializeProject(project));
      const inputIds = new Set<string>([...project.zoomRegions, ...project.tiltRegions].map((r) => r.id));
      let n = 0;
      const makeId = () => `FFFFFFFF-0000-4000-8000-${String(++n).padStart(12, "0")}`;
      const result = runAutoZoomOp(
        project,
        { cursor, keystrokes, videoNaturalSize: c.videoNaturalSize ? { width: c.videoNaturalSize[0], height: c.videoNaturalSize[1] } : null },
        c.zoomLevelArg,
        makeId,
      );

      // 3. Compare with what the Swift wrote.
      const exp = c.expected;
      if (!exp.ok) {
        expect(result.ok, "Swift threw").toBe(false);
        if (!result.ok) expect(`ERROR: ${result.error}`).toBe(exp.error);
        expect(exp.unchanged).toBe(true);
        expect(JSON.stringify(serializeProject(project)), "project untouched on error").toBe(before);
        return;
      }
      expect(result.ok, result.ok ? "" : result.error).toBe(true);
      if (!result.ok) return;
      expect(result.mode).toBe(exp.mode);
      expect(result.created).toBe(exp.created);
      const out = serializeProject(project);
      const zooms = withIdKinds(out.zoomRegions, inputIds);
      const tilts = withIdKinds(out.tiltRegions, inputIds);
      const m = mismatch(zooms, exp.zoomRegions, "zoomRegions") ?? mismatch(tilts, exp.tiltRegions, "tiltRegions");
      expect(m, m ?? "").toBeNull();
      expect(zooms.filter((z) => z.idKind === "new").length, "new zoom regions == created").toBe(exp.created);
    });
  }

  it("every number matched within 1e-9", () => {
    // Runs after the cases (vitest runs a file's tests in order).
    expect(numbersCompared).toBeGreaterThan(200);
    expect(maxAbsDiff).toBeLessThanOrEqual(ABS_TOL);
    console.info(`autoZoom golden: ${numbersCompared} numbers compared, max |Δ| = ${maxAbsDiff}`);
  });
});

// ── unit checks the MCP path cannot reach ────────────────────────────────────

describe("autoZoom applier (non-golden branches)", () => {
  const base = () => {
    const g = golden;
    if (!g) throw loadError ?? new Error(GOLDEN_HELP);
    return g;
  };

  it("smoothCursor=true (forced false on decode) smooths from the current settings", () => {
    const g = base();
    const c = g.cases.find((k) => k.name === "harness-two-nearby-clusters-pan")!;
    const events = buildCursorEvents(c.cursor.spec!).map((e, i) => ({ ...e, x: e.x + ((i * 7) % 13) - 6 }));
    const project = projectFor(g, c);
    project.settings.smoothCursor = true;
    project.settings.smoothingFactor = 0.1;
    let n = 0;
    const created = applyAutoZoom(project, { cursor: events, keystrokes: [], videoNaturalSize: { width: 3840, height: 2160 } }, null, () => `S-${++n}`);
    n = 0;
    const direct = generateZoomRegions(smooth(events, 0.1), project.duration, { width: 1920, height: 1080 }, 2.0, [], [], () => `S-${++n}`);
    expect(created).toBe(direct.length);
    expect(project.zoomRegions).toEqual(direct);
  });

  it("no cursor data / empty events → 0 and the project untouched", () => {
    const g = base();
    const c = g.cases.find((k) => k.name === "harness-typing-burst")!;
    const project = projectFor(g, c);
    const before = JSON.stringify(serializeProject(project));
    expect(applyAutoZoom(project, { cursor: null, keystrokes: [], videoNaturalSize: null })).toBe(0);
    expect(applyAutoZoom(project, { cursor: [], keystrokes: [], videoNaturalSize: null })).toBe(0);
    project.cursorDataURL = null;
    const events = buildCursorEvents(c.cursor.spec!);
    expect(applyAutoZoom(project, { cursor: events, keystrokes: [], videoNaturalSize: null })).toBe(0);
    project.cursorDataURL = (g.baseProject.cursorDataURL as string) ?? "file:///golden/cursor.json";
    expect(JSON.stringify(serializeProject(project))).toBe(before);
  });

  it("applyStillMotion is the MCP still path", () => {
    const g = base();
    const c = g.cases.find((k) => k.name === "still-motion-8s")!;
    const a = projectFor(g, c);
    const b = projectFor(g, c);
    expect(applyStillMotion(a, () => "X")).toBe(4);
    const r = runAutoZoomOp(b, { cursor: null, keystrokes: [], videoNaturalSize: null }, null, () => "X");
    expect(r).toEqual({ ok: true, mode: "still-motion", created: 4 });
    expect(serializeProject(a)).toEqual(serializeProject(b));
  });

  it("stableSortByStart keeps insertion order on ties", () => {
    const rows = [
      { startTime: 2, k: "a" },
      { startTime: 1, k: "b" },
      { startTime: 2, k: "c" },
      { startTime: 1, k: "d" },
    ];
    expect(stableSortByStart(rows).map((r) => r.k).join("")).toBe("bdac");
  });

  it("cursor.json decoding mirrors CursorTracker.load (JSONDecoder strictness)", () => {
    const e = { timestamp: 0.5, x: 10, y: 20, isClick: false };
    expect(parseCursorFile({ version: 1, coordinateWidth: 0, coordinateHeight: 0, events: [e] })).toEqual([e]);
    expect(parseCursorFile([e])).toEqual([e]); // legacy bare array
    expect(parseCursorFile({ version: 2, coordinateWidth: 1, coordinateHeight: 1, events: [e], extra: 1 })).toEqual([e]);
    expect(() => parseCursorFile({ version: 1.5, coordinateWidth: 0, coordinateHeight: 0, events: [e] })).toThrow();
    expect(() => parseCursorFile({ version: 1, coordinateWidth: 0, events: [e] })).toThrow();
    expect(() => parseCursorFile({ version: 1, coordinateWidth: 0, coordinateHeight: 0, events: [{ ...e, isClick: 1 }] })).toThrow();
    expect(() => parseCursorFile([{ ...e, x: "10" }])).toThrow();
    expect(() => parseCursorFile({ events: [e] })).toThrow();
    expect(tryParseCursorFile("nope")).toBeNull();
  });

  it("keys.json decoding mirrors KeystrokeTracker.loadRecording", () => {
    const k = { timestamp: 1, category: "key" };
    expect(parseKeystrokeFile({ version: 1, events: [k, { timestamp: 2, category: "modifier", shortcut: "⌘S", frontmostBundleID: null }] })).toEqual([
      k,
      { timestamp: 2, category: "modifier", shortcut: "⌘S" },
    ]);
    expect(() => parseKeystrokeFile({ version: 1, events: [{ timestamp: 1, category: "tab" }] })).toThrow();
    expect(() => parseKeystrokeFile({ version: 1, events: [{ timestamp: 1, category: "key", shortcut: 3 }] })).toThrow();
    expect(() => parseKeystrokeFile([k])).toThrow();
    expect(tryParseKeystrokeFile({ version: 1, events: [{ timestamp: 1, category: "tab" }, k] })).toEqual([]);
  });
});
