/**
 * Opt-in exporter: every merged output (default, flipped, reversed) of every
 * fixture, web-serialized, so the Mac can prove it opens and re-saves them:
 *
 *   CC_MERGE_ROUNDTRIP_OUT=<dir> npx vitest run src/editor/core/merge/mergeRoundtrip.test.ts
 *   CaptureCat --web-roundtrip-check <dir>/<variant>/web --against <dir>/<variant>/originals
 *
 * Layout per variant: `web/<id>.json` = serializeProjectText(parseProject(merged)),
 * `originals/<ID>/project.json` = the raw merged document. `--against` then
 * requires Swift's decode+encode of the raw merge to equal the web's
 * parse+serialize of it. apps/web/scripts/merge-vectors.sh runs both steps
 * (with <dir> inside the app's sandbox container).
 */
import { describe, expect, it } from "vitest";

import { parseProject, serializeProjectText } from "../model";
import { canonicalJSON, getKey, type Json, type Side } from "./jsonMerge";
import { merge } from "./projectMerge";
import { env, loadFixtures, nodeFS } from "./goldenFiles";

const out = env("CC_MERGE_ROUNDTRIP_OUT");

describe("merge round-trip export", () => {
  it.runIf(Boolean(out))("writes every merged output for --web-roundtrip-check", () => {
    const fs = nodeFS();
    let written = 0;
    for (const f of loadFixtures()) {
      const result = merge(f.base, f.mine, f.theirs, f.mineWins);
      const choices: Record<string, Side> = {};
      for (const c of result.conflicts) choices[c.id] = c.resolution === "mine" ? "theirs" : "mine";
      const variants: Record<string, Json> = {
        default: result.merged,
        flipped: merge(f.base, f.mine, f.theirs, f.mineWins, choices).merged,
        reversed: merge(f.base, f.mine, f.theirs, !f.mineWins).merged,
      };
      for (const [variant, merged] of Object.entries(variants)) {
        const project = parseProject(merged);
        fs.mkdirSync(`${out}/${variant}/web`, { recursive: true });
        fs.writeFileSync(`${out}/${variant}/web/${project.id}.json`, serializeProjectText(project));
        written++;
        // Id-less (legacy) camera layout regions get a FRESH random UUID on
        // every decode (Swift and web alike), so no two decodes can match:
        // those files get decode + fixpoint only (like synthRoundtrip.test.ts).
        const layouts = getKey(merged, "cameraLayoutRegions");
        if (Array.isArray(layouts) && layouts.some((r) => getKey(r, "id") === undefined)) continue;
        fs.mkdirSync(`${out}/${variant}/originals/${project.id}`, { recursive: true });
        fs.writeFileSync(`${out}/${variant}/originals/${project.id}/project.json`, canonicalJSON(merged));
      }
    }
    console.log(`MERGE-ROUNDTRIP wrote=${written} dir=${out}`);
    expect(written).toBeGreaterThan(0);
  });

  it.skipIf(Boolean(out))("merge round-trip export is opt-in — set CC_MERGE_ROUNDTRIP_OUT=<dir>", () => {});
});
