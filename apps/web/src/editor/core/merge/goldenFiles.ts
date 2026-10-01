/**
 * Test-only loaders for the project-merge golden files and fixtures (never
 * import from runtime code). Node's fs is reached through
 * process.getBuiltinModule, like core/vectors/harness.ts.
 *
 * golden/{mergePolicy,projectMerge}.json are written by the REAL Swift
 * (Services/ProjectHistory via `CaptureCat --web-vectors`) — regenerate them
 * with `apps/web/scripts/merge-vectors.sh`, never by hand.
 */
import { canonicalJSON, fnv1a64Hex, type Json } from "./jsonMerge";

type NodeFS = {
  readFileSync(path: string, encoding: "utf8"): string;
  existsSync(path: string): boolean;
  readdirSync(path: string): string[];
  writeFileSync(path: string, data: string): void;
  mkdirSync(path: string, options: { recursive: boolean }): void;
};
type NodeURL = { fileURLToPath(url: string | URL): string };
type ProcessLike = { getBuiltinModule?: (id: string) => unknown; env?: Record<string, string | undefined> };

function proc(): ProcessLike {
  const p = (globalThis as { process?: ProcessLike }).process;
  if (!p?.getBuiltinModule) throw new Error("Merge goldens need Node >= 22.3 (process.getBuiltinModule).");
  return p;
}

export function nodeFS(): NodeFS {
  return proc().getBuiltinModule!("node:fs") as NodeFS;
}

export function env(name: string): string | undefined {
  return proc().env?.[name];
}

function here(relative: string): string {
  const url = proc().getBuiltinModule!("node:url") as NodeURL;
  return url.fileURLToPath(new URL(relative, import.meta.url));
}

export const GOLDEN_HELP =
  "Regenerate it from the REAL Swift: build apps/macos (Debug), then run `apps/web/scripts/merge-vectors.sh` " +
  "(stages the fixtures into the app's sandbox, runs `CaptureCat --web-vectors … --only mergePolicy,projectMerge`, " +
  "copies the output into src/editor/core/merge/golden/). Never hand-edit expectations.";

export interface GoldenCase<I = Record<string, Json>, O = Record<string, Json>> {
  input: I;
  output: O;
}

export interface GoldenFile<I = Record<string, Json>, O = Record<string, Json>> {
  unit: string;
  notes: string;
  count: number;
  cases: GoldenCase<I, O>[];
}

export function loadGolden<I = Record<string, Json>, O = Record<string, Json>>(unit: string): GoldenFile<I, O> {
  const fs = nodeFS();
  const path = here(`./golden/${unit}.json`);
  if (!fs.existsSync(path)) {
    throw new Error(`Golden file src/editor/core/merge/golden/${unit}.json is missing. ${GOLDEN_HELP}`);
  }
  const file = JSON.parse(fs.readFileSync(path, "utf8")) as GoldenFile<I, O>;
  if (!Array.isArray(file.cases) || file.cases.length === 0) {
    throw new Error(`Golden file ${unit}.json has no cases. ${GOLDEN_HELP}`);
  }
  return file;
}

export interface MergeFixture {
  name: string;
  description: string;
  covers: string[];
  mineWins: boolean;
  base: Json;
  mine: Json;
  theirs: Json;
}

export function loadFixtures(): MergeFixture[] {
  const fs = nodeFS();
  const dir = here("./fixtures/");
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => JSON.parse(fs.readFileSync(`${dir}${f}`, "utf8")) as MergeFixture);
}

/** FNV-1a 64 of the fixture's canonical inputs — the golden records Swift's. */
export function fixtureHash(f: MergeFixture): string {
  return fnv1a64Hex(canonicalJSON({ mineWins: f.mineWins, base: f.base, mine: f.mine, theirs: f.theirs }));
}
