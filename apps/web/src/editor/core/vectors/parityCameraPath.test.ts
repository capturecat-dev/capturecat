/**
 * The TS camera path (exportCameraPath.ts, fed by the TS cursor chain) against
 * the REAL VideoExporter: every parity fixture stores the exporter's own
 * CAPTURECAT_DUMP_CAMERA dump (printed with %.4f/%.5f/%.3f), so this proves the
 * web's per-frame zoom / focal / card offset / tilt equal the Mac exporter for
 * real exports end to end, within print precision.
 */
import { describe, expect, it } from "vitest";
import { parseProject } from "../model";
import type { CursorRecording } from "../model";
import { computeCameraPath } from "../math/exportCameraPath";
import { processCursorEvents, recordingCoordinateSize } from "../math/cursorChain";
import { resolveCoordinateSize } from "../math/cursorOverlayLayout";
import { exportFrameTimes } from "../math/exportLayout";
import { SpeedTimeMap } from "../time/speedTimeMap";
import { effectiveTrimEnd, exportedOutputDuration, exportSourceWindow } from "../time/clips";

const manifests = import.meta.glob("/.fixtures/parity/manifest.json", { eager: true, query: "?raw", import: "default" }) as Record<string, string>;
const projects = import.meta.glob("/.fixtures/parity/*/project.json", { eager: true, query: "?raw", import: "default" }) as Record<string, string>;
const cursors = import.meta.glob("/.fixtures/parity/*/cursor.json", { eager: true, query: "?raw", import: "default" }) as Record<string, string>;

interface DumpRow {
  t: number;
  zoom: number;
  focalX: number;
  focalY: number;
  offsetX: number;
  offsetY: number;
  tiltPitch: number;
  tiltYaw: number;
  tiltRoll: number;
}

describe("render-parity fixtures: camera path", () => {
  it("TS computeCameraPath equals the real exporter camera dump (print precision)", () => {
    const text = Object.values(manifests)[0];
    if (!text) throw new Error("Render-parity fixtures are missing — run CaptureCat --web-parity-fixtures and scripts/sync-parity-fixtures.sh.");
    const manifest = JSON.parse(text) as {
      fixtures: Array<{ name: string; dir: string; sourceSize: { width: number; height: number }; sourceDuration: number; outputFPS: number; exporterCameraPath: DumpRow[] }>;
    };
    let compared = 0;
    for (const f of manifest.fixtures) {
      const project = parseProject(JSON.parse(projects[Object.keys(projects).find((k) => k.endsWith("/" + f.dir + "/project.json"))!]));
      const cursorKey = Object.keys(cursors).find((k) => k.endsWith("/" + f.dir + "/cursor.json"));
      const recording: CursorRecording | null = cursorKey ? JSON.parse(cursors[cursorKey]) : null;
      const events = recording ? processCursorEvents(recording.events, project.settings, effectiveTrimEnd(project)) : [];
      const display = resolveCoordinateSize(recordingCoordinateSize(recording), f.sourceSize);

      const win = exportSourceWindow(project, f.sourceDuration);
      const map = new SpeedTimeMap(win.start, win.end, project.speedRegions);
      const outputTimes = exportFrameTimes(exportedOutputDuration(project, map), f.outputFPS);
      const keys = computeCameraPath({
        zoomRegions: project.zoomRegions,
        tiltRegions: project.tiltRegions,
        settings: project.settings,
        outputFrameTimes: outputTimes,
        timelineSourceTimes: outputTimes.map((t) => map.sourceTime(t)),
        cursorEvents: events,
        displayWidth: display.width,
        displayHeight: display.height,
        scrollTimes: [],
      });
      expect(keys.length, f.name + ": frame count").toBe(f.exporterCameraPath.length);
      // Half a printed unit (+ float slack): %.5f zoom, %.4f focal/offset, %.3f tilt.
      const tol = { zoom: 5e-6, focal: 5e-5, tilt: 5e-4 };
      const slack = 1e-9;
      f.exporterCameraPath.forEach((row, i) => {
        const k = keys[i];
        const checks: Array<[string, number, number, number]> = [
          ["t", outputTimes[i], row.t, 5e-5],
          ["zoom", k.zoom, row.zoom, tol.zoom],
          ["focalX", k.focalX, row.focalX, tol.focal],
          ["focalY", k.focalY, row.focalY, tol.focal],
          ["offsetX", k.offsetX, row.offsetX, tol.focal],
          ["offsetY", k.offsetY, row.offsetY, tol.focal],
          ["tiltPitch", k.tiltPitch, row.tiltPitch, tol.tilt],
          ["tiltYaw", k.tiltYaw, row.tiltYaw, tol.tilt],
          ["tiltRoll", k.tiltRoll, row.tiltRoll, tol.tilt],
        ];
        for (const [name, ours, theirs, t] of checks) {
          expect(Math.abs(ours - theirs) <= t + slack, f.name + " frame " + i + " " + name + ": web " + ours + " vs exporter " + theirs).toBe(true);
        }
        compared++;
      });
    }
    expect(compared).toBeGreaterThan(1000);
  });
});
