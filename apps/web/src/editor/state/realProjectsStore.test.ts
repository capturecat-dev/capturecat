/**
 * LOCAL-ONLY, READ-ONLY store round trip over the user's REAL projects
 * (opt-in: `CC_REAL_PROJECTS=1 npx vitest run src/editor/state/realProjectsStore.test.ts`).
 *
 * For every project.json: load into the store → the saved text is the
 * ORIGINAL bytes; run real edits (zoom add, settings patch, split, speed) →
 * the serialized document differs from the original ONLY at the edited keys
 * (unknown keys and every other value survive); undo everything → the
 * original bytes again. Never writes; prints COUNTS only.
 */
import { describe, expect, it } from "vitest";

import { serializeProjectText } from "../core/model";
import * as E from "./edits";
import { EditorStore } from "./store";

type Env = Record<string, string | undefined>;
const env: Env = ((globalThis as { process?: { env?: Env } }).process?.env ?? {}) as Env;
const enabled = env.CC_REAL_PROJECTS === "1";

function changedTopKeys(a: Record<string, unknown>, b: Record<string, unknown>): string[] {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  const out: string[] = [];
  for (const k of keys) {
    if (k === "settings") {
      const sa = a.settings as Record<string, unknown>;
      const sb = b.settings as Record<string, unknown>;
      for (const sk of new Set([...Object.keys(sa ?? {}), ...Object.keys(sb ?? {})])) {
        if (JSON.stringify(sa?.[sk]) !== JSON.stringify(sb?.[sk])) out.push(`settings.${sk}`);
      }
    } else if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) out.push(k);
  }
  return out.sort();
}

describe("store round trip on real projects (LOCAL ONLY, read-only)", () => {
  it.runIf(enabled)("load → edit → undo is byte-identical; edits touch only their keys", async () => {
    const FS = "node:fs";
    const fs = (await import(/* @vite-ignore */ FS)) as {
      readdirSync(p: string): string[];
      existsSync(p: string): boolean;
      readFileSync(p: string, enc: "utf8"): string;
    };
    const home = env.HOME ?? "";
    const root = env.CC_REAL_PROJECTS_DIR ?? `${home}/Library/Containers/so.capturecat.CaptureCat/Data/Library/Application Support/CaptureCat/Projects`;
    let checked = 0;
    let skipped = 0;
    let worstEditMs = 0;
    const failures: string[] = [];
    for (const id of fs.readdirSync(root)) {
      const file = `${root}/${id}/project.json`;
      if (!fs.existsSync(file)) continue;
      const text = fs.readFileSync(file, "utf8");
      const store = new EditorStore();
      store.load({ text, origin: "local", revision: null });
      const p = store.getState().project;
      if (!p || !(p.duration > 2)) {
        skipped++;
        continue;
      }
      checked++;
      if (store.documentText() !== text) failures.push(`${checked}: untouched text changed`);
      // Baseline = what the lossless serializer writes for the UNEDITED project (the
      // same keys Swift encode(decode(x)) writes — defaults filled, order canonical;
      // realProjects.test.ts proves that against the original file).
      const original = JSON.parse(serializeProjectText(p)) as Record<string, unknown>;
      store.setPlayheadProvider(() => 1);
      store.apply(E.addZoomRegion());
      store.updateSettings({ backgroundPadding: p.settings.backgroundPadding + 1 });
      const mid = E.fullTimeMap(p).outputDuration / 2;
      store.setPlayheadProvider(() => mid);
      store.apply(E.splitAtPlayhead);
      const edited = JSON.parse(store.documentText()) as Record<string, unknown>;
      const allowed = new Set(["zoomRegions", "settings.backgroundPadding", "videoClipSegments", "splitPoints"]);
      // Swift's documented decode normalisations also show up once re-encoded.
      const normalised = new Set(["settings.smoothCursor", "settings.autoHideCursor", "settings.showCamera", "voiceOverClips"]);
      const extra = changedTopKeys(original, edited).filter((k) => !allowed.has(k) && !normalised.has(k));
      if (extra.length) failures.push(`${checked}: unexpected changed keys ${extra.join(",")}`);
      while (store.getState().canUndo) store.undo();
      if (store.documentText() !== text) failures.push(`${checked}: undo did not restore the original bytes`);
      // Cost of one live edit (a slider tick): transaction + engine document.
      const t0 = performance.now();
      for (let i = 0; i < 20; i++) {
        store.updateSettings({ backgroundPadding: i });
        store.documentJSON();
      }
      worstEditMs = Math.max(worstEditMs, (performance.now() - t0) / 20);
    }
    console.log(`store round trip: ${checked} projects checked, ${skipped} skipped, ${failures.length} failures; worst live edit ${worstEditMs.toFixed(2)} ms`);
    expect(failures).toEqual([]);
    expect(checked).toBeGreaterThan(0);
  });
});
