/**
 * Golden-vector loader + comparator (TEST-ONLY — never import from runtime code).
 *
 * Vectors are produced by the REAL Swift functions:
 *
 *   1. build the Mac app (apps/macos, Debug) and resolve its binary via
 *      `xcodebuild -showBuildSettings | grep ' BUILT_PRODUCTS_DIR'`
 *   2. `CaptureCat.app/Contents/MacOS/CaptureCat --web-vectors <dir>`
 *      (sandboxed: when <dir> is not writable it prints the container tmp path)
 *   3. `apps/web/scripts/sync-vectors.sh [<printed dir>]` → apps/web/.fixtures/vectors/
 *
 * A suite whose vectors are missing FAILS with those instructions — it never
 * skips silently (a skipped parity gate is indistinguishable from a passing one).
 */
import { expect } from "vitest";

export interface VectorCase<I = any, O = any> {
  input: I;
  output: O;
}

export interface VectorFile<I = any, O = any> {
  unit: string;
  notes: string;
  count: number;
  cases: VectorCase<I, O>[];
}

// Vectors are read LAZILY and synchronously from disk (node:fs via
// process.getBuiltinModule — no @types/node needed): each suite loads only its
// own units. (An eager import.meta.glob of ~200 MB of JSON in every worker ran
// the test pool out of heap.) Parsed with JSON.parse on the raw text so
// Swift's -0.0 keeps its sign (Vite's JSON transform would drop it).
type NodeFS = {
  readFileSync(path: string, encoding: "utf8"): string;
  existsSync(path: string): boolean;
};
type NodeURL = { fileURLToPath(url: string | URL): string };
type ProcessLike = { getBuiltinModule?: (id: string) => unknown };

function nodeModules(): { fs: NodeFS; url: NodeURL } {
  const proc = (globalThis as { process?: ProcessLike }).process;
  if (!proc?.getBuiltinModule) throw new Error("Golden vectors need Node >= 22.3 (process.getBuiltinModule).");
  return { fs: proc.getBuiltinModule("node:fs") as NodeFS, url: proc.getBuiltinModule("node:url") as NodeURL };
}

/** apps/web/.fixtures/vectors/ (this file lives in apps/web/src/editor/core/vectors/). */
export function vectorsDir(): string {
  const { url } = nodeModules();
  return url.fileURLToPath(new URL("../../../../.fixtures/vectors/", import.meta.url));
}

export const GENERATE_HELP =
  "Generate them: build apps/macos (Debug), run " +
  "`<BUILT_PRODUCTS_DIR>/CaptureCat.app/Contents/MacOS/CaptureCat --web-vectors /tmp/cc-vectors` " +
  "(note the printed dir — the sandbox may redirect it into the container tmp), then " +
  "`apps/web/scripts/sync-vectors.sh <printed dir>`.";

/** NaN / ±Infinity travel as strings (JSON has no literal for them). */
function revive(value: unknown): unknown {
  if (value === "NaN") return Number.NaN;
  if (value === "Infinity") return Number.POSITIVE_INFINITY;
  if (value === "-Infinity") return Number.NEGATIVE_INFINITY;
  if (Array.isArray(value)) return value.map(revive);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) out[k] = revive(v);
    return out;
  }
  return value;
}

const cache = new Map<string, VectorFile>();

/** Loads `<unit>.json`; throws (failing the suite) when it is missing. */
export function loadVectors<I = any, O = any>(unit: string): VectorFile<I, O> {
  const hit = cache.get(unit);
  if (hit) return hit as VectorFile<I, O>;
  const { fs } = nodeModules();
  const path = `${vectorsDir()}${unit}.json`;
  if (!fs.existsSync(path)) {
    throw new Error(
      `Golden vectors for unit "${unit}" are missing from apps/web/.fixtures/vectors/. ${GENERATE_HELP}`,
    );
  }
  const file = revive(JSON.parse(fs.readFileSync(path, "utf8"))) as VectorFile<I, O>;
  if (!Array.isArray(file.cases) || file.cases.length === 0) {
    throw new Error(`Golden vectors for unit "${unit}" contain no cases. ${GENERATE_HELP}`);
  }
  cache.set(unit, file);
  return file;
}

/** Absolute tolerance for doubles (the parity contract). */
export const ABS_TOL = 1e-9;
/** Relative tolerance, only consulted for magnitudes where 1e-9 absolute is
 * below one ulp-scale of libm differences (|x| > 1e3). */
export const REL_TOL = 1e-12;

export function numbersMatch(actual: number, expected: number, absTol = ABS_TOL): boolean {
  if (Number.isNaN(expected)) return Number.isNaN(actual);
  if (!Number.isFinite(expected)) return actual === expected;
  if (!Number.isFinite(actual)) return false;
  const diff = Math.abs(actual - expected);
  if (diff <= absTol) return true;
  const scale = Math.max(Math.abs(actual), Math.abs(expected));
  return scale > 1e3 && diff <= REL_TOL * scale;
}

/**
 * Structural deep compare. Numbers within tolerance; strings/bools exact;
 * arrays by length + element; objects by the EXPECTED keys (an `undefined`
 * actual matches an expected `null`, since Swift nil encodes as null).
 * Returns the first mismatch path, or null.
 */
export function firstMismatch(
  actual: unknown,
  expected: unknown,
  path = "output",
  absTol = ABS_TOL,
): string | null {
  if (typeof expected === "number") {
    if (typeof actual !== "number") return `${path}: expected number ${expected}, got ${fmt(actual)}`;
    return numbersMatch(actual, expected, absTol)
      ? null
      : `${path}: expected ${expected}, got ${actual} (Δ=${Math.abs(actual - expected)})`;
  }
  if (expected === null) {
    return actual === null || actual === undefined ? null : `${path}: expected null, got ${fmt(actual)}`;
  }
  if (typeof expected === "string" || typeof expected === "boolean") {
    return actual === expected ? null : `${path}: expected ${fmt(expected)}, got ${fmt(actual)}`;
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) return `${path}: expected array, got ${fmt(actual)}`;
    if (actual.length !== expected.length) {
      return `${path}: expected length ${expected.length}, got ${actual.length}`;
    }
    for (let i = 0; i < expected.length; i++) {
      const m = firstMismatch(actual[i], expected[i], `${path}[${i}]`, absTol);
      if (m) return m;
    }
    return null;
  }
  if (expected && typeof expected === "object") {
    if (!actual || typeof actual !== "object") return `${path}: expected object, got ${fmt(actual)}`;
    for (const [k, v] of Object.entries(expected)) {
      const m = firstMismatch((actual as Record<string, unknown>)[k], v, `${path}.${k}`, absTol);
      if (m) return m;
    }
    return null;
  }
  return actual === expected ? null : `${path}: expected ${fmt(expected)}, got ${fmt(actual)}`;
}

function fmt(v: unknown): string {
  try {
    const s = JSON.stringify(v);
    return s === undefined ? String(v) : s.length > 200 ? s.slice(0, 200) + "…" : s;
  } catch {
    return String(v);
  }
}

/**
 * Runs `port` over every case of `unit` and asserts each output matches.
 * Reports the number of failing cases and the first few mismatches with their
 * inputs, so a broken port points straight at the offending case.
 */
export function checkUnit<I = any, O = any>(
  unit: string,
  port: (input: I, index: number) => unknown,
  options: { absTol?: number } = {},
): number {
  const file = loadVectors<I, O>(unit);
  const failures: string[] = [];
  let failed = 0;
  file.cases.forEach((c, i) => {
    let actual: unknown;
    try {
      actual = port(c.input, i);
    } catch (e) {
      failed++;
      if (failures.length < 5) failures.push(`case ${i} threw ${(e as Error).message}\n  input=${fmt(c.input)}`);
      return;
    }
    const mismatch = firstMismatch(actual, c.output, "output", options.absTol ?? ABS_TOL);
    if (mismatch) {
      failed++;
      if (failures.length < 5) failures.push(`case ${i}: ${mismatch}\n  input=${fmt(c.input)}`);
    }
  });
  expect(
    failed,
    `${unit}: ${failed}/${file.cases.length} cases diverge from Swift\n${failures.join("\n")}`,
  ).toBe(0);
  return file.cases.length;
}
