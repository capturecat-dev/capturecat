/**
 * Integrity of the render-parity fixtures written by
 * `CaptureCat --web-parity-fixtures <dir>` (synced into the gitignored
 * apps/web/.fixtures/parity/ by scripts/sync-parity-fixtures.sh).
 *
 * The web RENDERER's pixel gate consumes these later; here we assert what the
 * core can already prove: every fixture project parses and re-serializes to
 * exactly the Swift JSON, the frame list agrees with the exporter's frame
 * clock / speed map / clip visibility ports, and every listed PNG exists.
 * Missing fixtures FAIL (with the generation command) — never skip.
 */
import { describe, expect, it } from "vitest";
import { parseProject, serializeProject } from "../model";
import { exportFrameTimes } from "../math/exportLayout";
import { SpeedTimeMap } from "../time/speedTimeMap";
import { exportedOutputDuration, exportSourceWindow, hasVisibleVideo } from "../time/clips";
import { numbersMatch } from "./harness";

const manifests = import.meta.glob("/.fixtures/parity/manifest.json", { eager: true, query: "?raw", import: "default" }) as Record<string, string>;
const projects = import.meta.glob("/.fixtures/parity/*/project.json", { eager: true, query: "?raw", import: "default" }) as Record<string, string>;
const pngs = import.meta.glob("/.fixtures/parity/*/frames/*.png", { query: "?url", import: "default" });

const HELP =
  "Generate them: `<BUILT_PRODUCTS_DIR>/CaptureCat.app/Contents/MacOS/CaptureCat --web-parity-fixtures parity` " +
  "(prints the container dir), then `apps/web/scripts/sync-parity-fixtures.sh <printed dir>`.";

interface FixtureFrame {
  index: number;
  outputTime: number;
  sourceTime: number;
  hasVisibleVideo: boolean;
  png: string;
}
interface FixtureSummary {
  name: string;
  dir: string;
  sourceDuration: number;
  outputFPS: number;
  totalSeconds: number;
  frameCount: number;
  frames: FixtureFrame[];
}

function sortKeysDeep(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeysDeep);
  if (v && typeof v === "object") {
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeysDeep((v as Record<string, unknown>)[k])]));
  }
  return v;
}

describe("render-parity fixtures", () => {
  it("manifest, projects and frame clock agree with the core ports", () => {
    const manifestText = Object.values(manifests)[0];
    if (!manifestText) throw new Error(`Render-parity fixtures are missing from apps/web/.fixtures/parity/. ${HELP}`);
    const manifest = JSON.parse(manifestText) as { fixtures: FixtureSummary[] };
    expect(manifest.fixtures.length).toBeGreaterThanOrEqual(8);

    for (const f of manifest.fixtures) {
      const key = Object.keys(projects).find((k) => k.endsWith(`/${f.dir}/project.json`));
      expect(key, `${f.name}: project.json`).toBeDefined();
      const swiftJSON = JSON.parse(projects[key!]);
      const project = parseProject(swiftJSON);
      // Lossless: the web's serialization IS Swift's.
      expect(JSON.stringify(sortKeysDeep(serializeProject(project))), `${f.name}: serialize`).toBe(
        JSON.stringify(sortKeysDeep(swiftJSON)),
      );

      // Frame clock: exporter source window (the synthetic asset is exactly
      // sourceDuration long) → speed map → last-visible-clip cap → frame times.
      const win = exportSourceWindow(project, f.sourceDuration);
      const map = new SpeedTimeMap(win.start, win.end, project.speedRegions);
      const total = exportedOutputDuration(project, map);
      expect(numbersMatch(total, f.totalSeconds), `${f.name}: totalSeconds ${total} vs ${f.totalSeconds}`).toBe(true);
      const times = exportFrameTimes(total, f.outputFPS);
      expect(times.length, `${f.name}: frameCount`).toBe(f.frameCount);
      for (const fr of f.frames) {
        expect(numbersMatch(times[fr.index], fr.outputTime), `${f.name}#${fr.index}: outputTime`).toBe(true);
        const source = map.sourceTime(times[fr.index]);
        expect(numbersMatch(source, fr.sourceTime), `${f.name}#${fr.index}: sourceTime`).toBe(true);
        expect(hasVisibleVideo(project, source), `${f.name}#${fr.index}: visibility`).toBe(fr.hasVisibleVideo);
        const png = Object.keys(pngs).some((p) => p.endsWith(`/${f.dir}/${fr.png}`));
        expect(png, `${f.name}: ${fr.png} exists`).toBe(true);
      }
    }
  });
});
