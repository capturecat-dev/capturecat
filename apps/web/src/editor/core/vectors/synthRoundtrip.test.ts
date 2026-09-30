/**
 * Exports the web-serialized form of every decodable SYNTHETIC project in the
 * `projectDecode` vectors (plus the original the web parsed) so the Mac can
 * verify them with the real Codable:
 *
 *   CC_SYNTH_ROUNDTRIP_OUT=<dir> npx vitest run src/editor/core/vectors/synthRoundtrip.test.ts
 *   CaptureCat --web-roundtrip-check <dir>/web --against <dir>/originals
 *
 * Layout: `<dir>/web/<id>.json`, `<dir>/originals/<ID>/project.json`.
 * Opt-in (writes files); the in-process equivalence is already asserted by
 * model.test.ts.
 */
import { describe, expect, it } from "vitest";
import { loadVectors } from "./harness";
import { parseProject, serializeProjectText } from "../model";
import { stringifyJSON } from "../model/serialize";

type Env = Record<string, string | undefined>;
const env: Env = ((globalThis as { process?: { env?: Env } }).process?.env ?? {}) as Env;
const out = env.CC_SYNTH_ROUNDTRIP_OUT;

describe("synthetic round-trip export", () => {
  it.runIf(Boolean(out))("writes web-serialized synthetic projects for --web-roundtrip-check", async () => {
    const FS = "node:fs";
    const fs = (await import(/* @vite-ignore */ FS)) as {
      writeFileSync(p: string, data: string): void;
      mkdirSync(p: string, o: { recursive: boolean }): void;
    };
    const file = loadVectors<{ json: unknown }, Record<string, unknown>>("projectDecode");
    let written = 0;
    for (const c of file.cases) {
      if (c.output.error === true) continue;
      const project = parseProject(c.input.json);
      // Skip projects whose camera layout regions lack ids (Swift assigns a
      // random UUID on each decode, so no two decodes can match).
      const raw = c.input.json as { cameraLayoutRegions?: Array<{ id?: unknown }> };
      if (raw.cameraLayoutRegions?.some((r) => r.id === undefined || r.id === null)) continue;
      fs.mkdirSync(`${out}/web`, { recursive: true });
      fs.mkdirSync(`${out}/originals/${project.id}`, { recursive: true });
      fs.writeFileSync(`${out}/web/${project.id}.json`, serializeProjectText(project));
      fs.writeFileSync(`${out}/originals/${project.id}/project.json`, stringifyJSON(c.input.json));
      written++;
    }
    console.log(`SYNTH-ROUNDTRIP wrote=${written} dir=${out}`);
    expect(written).toBeGreaterThan(0);
  });

  it.skipIf(Boolean(out))("synthetic export is opt-in — set CC_SYNTH_ROUNDTRIP_OUT=<dir>", () => {});
});
