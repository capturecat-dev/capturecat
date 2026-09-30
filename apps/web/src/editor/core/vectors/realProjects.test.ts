/**
 * LOCAL-ONLY, READ-ONLY check of the web model against the user's REAL
 * projects (opt-in: `CC_REAL_PROJECTS=1 npx vitest run src/editor/core/vectors/realProjects.test.ts`).
 *
 * Reads every `~/Library/Containers/so.capturecat.CaptureCat/Data/Library/
 * Application Support/CaptureCat/Projects/<id>/project.json` (or
 * `CC_REAL_PROJECTS_DIR`), parses + serializes it, and asserts nothing was
 * dropped or changed except Swift's own documented decode normalisations.
 * It NEVER writes the originals and prints COUNTS ONLY (never contents).
 *
 * With `CC_REAL_PROJECTS_OUT=<dir>` it also writes each web-serialized
 * project to `<dir>/<id>.json` so the Mac can prove the round trip with the
 * real Codable:
 *   CaptureCat --web-roundtrip-check <dir> --against <Projects root>
 * (use a dir inside the app container's tmp so the sandboxed app can read
 * it, and delete it afterwards).
 */
import { describe, expect, it } from "vitest";
import { parseProject, ProjectDecodeError, serializeProject, serializeProjectText } from "../model";

type Env = Record<string, string | undefined>;
const env: Env = ((globalThis as { process?: { env?: Env } }).process?.env ?? {}) as Env;
const enabled = env.CC_REAL_PROJECTS === "1";

/** Paths Swift's decoder deliberately rewrites (see parse.ts). */
const NORMALISED = [
  /^\.settings\.smoothCursor$/,
  /^\.settings\.autoHideCursor$/,
  /^\.settings\.showCamera$/,
  /^\.voiceOverClips\[\d+\]\.(sourceStartTime|sourceDuration)$/,
];

function diffPaths(original: unknown, web: unknown, path: string, out: string[]): void {
  if (Array.isArray(original)) {
    if (!Array.isArray(web) || web.length !== original.length) {
      out.push(`${path} (array)`);
      return;
    }
    original.forEach((v, i) => diffPaths(v, web[i], `${path}[${i}]`, out));
    return;
  }
  if (original && typeof original === "object") {
    if (!web || typeof web !== "object") {
      out.push(path);
      return;
    }
    for (const [k, v] of Object.entries(original)) {
      const w = (web as Record<string, unknown>)[k];
      // Swift writes nil Optionals via encodeIfPresent/omission or null; the
      // web may omit an original `null` for an encodeIfPresent key.
      if (v === null && w === undefined) continue;
      if (!(k in (web as object))) {
        out.push(`${path}.${k} (dropped)`);
        continue;
      }
      diffPaths(v, w, `${path}.${k}`, out);
    }
    return;
  }
  if (typeof original === "string" && typeof web === "string") {
    // UUIDs are re-encoded uppercase by Swift.
    if (original.toUpperCase() === web && /^[0-9a-f-]{36}$/i.test(original)) return;
  }
  if (original !== web && !(typeof original === "number" && typeof web === "number" && original === web)) {
    out.push(path);
  }
}

describe("real projects (LOCAL ONLY, read-only)", () => {
  it.runIf(enabled)("every real project parses and serializes losslessly", async () => {
    const FS = "node:fs";
    const fs = (await import(/* @vite-ignore */ FS)) as {
      readdirSync(p: string): string[];
      existsSync(p: string): boolean;
      readFileSync(p: string, enc: "utf8"): string;
      writeFileSync(p: string, data: string): void;
      mkdirSync(p: string, o: { recursive: boolean }): void;
    };
    const root =
      env.CC_REAL_PROJECTS_DIR ??
      `${env.HOME}/Library/Containers/so.capturecat.CaptureCat/Data/Library/Application Support/CaptureCat/Projects`;
    const out = env.CC_REAL_PROJECTS_OUT;
    if (out) fs.mkdirSync(out, { recursive: true });

    let found = 0;
    let parsed = 0;
    let decodeErrors = 0;
    let clean = 0;
    let normalisedOnly = 0;
    let unexpected = 0;
    let withUnknownKeys = 0;
    const unexpectedPaths = new Map<string, number>();

    for (const dir of fs.readdirSync(root).sort()) {
      const file = `${root}/${dir}/project.json`;
      if (!fs.existsSync(file)) continue;
      found++;
      const original = JSON.parse(fs.readFileSync(file, "utf8"));
      let project;
      try {
        project = parseProject(original);
      } catch (e) {
        if (e instanceof ProjectDecodeError) {
          decodeErrors++;
          continue;
        }
        throw e;
      }
      parsed++;
      const web = serializeProject(project);
      const paths: string[] = [];
      diffPaths(original, web, "", paths);
      const bad = paths.filter((p) => !NORMALISED.some((re) => re.test(p)));
      if (paths.length === 0) clean++;
      else if (bad.length === 0) normalisedOnly++;
      else {
        unexpected++;
        // Key paths only (index-free) — never values.
        for (const p of bad) {
          const key = p.replace(/\[\d+\]/g, "[]");
          unexpectedPaths.set(key, (unexpectedPaths.get(key) ?? 0) + 1);
        }
      }
      if (JSON.stringify(web).length !== JSON.stringify(serializeProject(project, { includeExtra: false })).length) {
        withUnknownKeys++;
      }
      if (out) fs.writeFileSync(`${out}/${project.id}.json`, serializeProjectText(project));
    }

    console.log(
      `REAL-PROJECTS found=${found} parsed=${parsed} decodeErrors=${decodeErrors} identical=${clean} ` +
        `swiftNormalisedOnly=${normalisedOnly} unexpected=${unexpected} withUnknownKeys=${withUnknownKeys}` +
        (unexpectedPaths.size ? ` unexpectedPaths=${JSON.stringify([...unexpectedPaths])}` : ""),
    );
    expect(found).toBeGreaterThan(0);
    expect(unexpected).toBe(0);
  });

  it.skipIf(enabled)("real-project round-trip is LOCAL ONLY — set CC_REAL_PROJECTS=1 to run it", () => {});
});
