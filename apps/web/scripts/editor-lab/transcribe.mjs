#!/usr/bin/env node
/**
 * Headless check of Generate / Regenerate / Cancel Subtitles in the REAL
 * editor page (DEV ONLY): on-device Whisper in the browser, end to end.
 *
 *   1. make a speech project:  scripts/editor-lab/make-speech-project.sh <projects-root> [UUID]
 *   2. serve it:  CAPTURECAT_PROJECTS_ROOT=<projects-root> npx vite dev --port 3215
 *   3. node scripts/editor-lab/transcribe.mjs --url http://localhost:3215 --id <UUID>
 *        [--reference <projects-root>/<UUID>/script.txt …] [--device webgpu|wasm]
 *        [--profile <dir>] [--out <dir>] [--headed]
 *   (The first page load after a config change re-optimizes deps and reloads
 *   the page mid-run — run it again.)
 *
 * Drives the Subtitles pane by clicking its buttons, then reads the store
 * (window.__editor) and the generator (window.__editorSubtitles). Reports
 * timings per stage, the backend, word error rate against --reference, and
 * fails when: no cues, Cancel changed the project, Regenerate was not ONE
 * undo step, or undo did not restore the previous cues.
 *
 * --profile keeps a Chrome profile between runs, so the model downloads once
 * (Cache Storage) — run twice to time first use vs cached.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const all = (name) => args.flatMap((a, i) => (a === `--${name}` ? [args[i + 1]] : []));
const flag = (name) => args.includes(`--${name}`);
const BASE = opt("url", "http://localhost:3215");
const ID = opt("id", "5B1D0C1E-7A11-4C0A-9E57-5AB717E50001");
const OUT = opt("out", "/tmp/editor-lab-transcribe");
const PROFILE = opt("profile", null);
const DEVICE = opt("device", null);
const REFERENCE = all("reference").map((f) => readFileSync(f, "utf8")).join(" ");
mkdirSync(OUT, { recursive: true });

const log = (...a) => console.log(...a);
const failures = [];
const report = { base: BASE, id: ID, device: DEVICE ?? "auto" };

const launchArgs = ["--enable-gpu", "--ignore-gpu-blocklist", "--enable-unsafe-webgpu"];
const context = PROFILE
  ? await chromium.launchPersistentContext(PROFILE, {
      channel: "chrome",
      headless: !flag("headed"),
      args: launchArgs,
      viewport: { width: 1600, height: 1000 },
      deviceScaleFactor: 2,
    })
  : await (await chromium.launch({ channel: "chrome", headless: !flag("headed"), args: launchArgs })).newContext({
      viewport: { width: 1600, height: 1000 },
      deviceScaleFactor: 2,
    });
const page = context.pages()[0] ?? (await context.newPage());
const consoleErrors = [];
page.on("console", (m) => m.type() === "error" && consoleErrors.push(m.text()));
page.on("pageerror", (e) => consoleErrors.push(`pageerror: ${e.message}`));

const words = (s) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9' ]+/g, " ")
    .split(/\s+/)
    .filter(Boolean);
function wer(ref, hyp) {
  const r = words(ref);
  const h = words(hyp);
  const d = Array.from({ length: r.length + 1 }, (_, i) => [i, ...new Array(h.length).fill(0)]);
  for (let j = 0; j <= h.length; j++) d[0][j] = j;
  for (let i = 1; i <= r.length; i++)
    for (let j = 1; j <= h.length; j++)
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1));
  return { wer: d[r.length][h.length] / Math.max(1, r.length), refWords: r.length, hypWords: h.length };
}

const state = () =>
  page.evaluate(() => {
    const s = window.__editor.store.getState();
    return {
      ids: s.project.subtitles.map((c) => c.id),
      cues: s.project.subtitles.map((c) => ({ start: c.startTime, end: c.endTime, text: c.text, words: c.words.length })),
      undoLabel: s.undoLabel,
      status: window.__editorSubtitles.getStatus(),
      stats: window.__editorSubtitles.lastStats,
    };
  });

/** Poll the generator until idle; record every progress line and when it appeared. */
async function watch(tag, { cancelWhen } = {}) {
  const t0 = Date.now();
  const lines = [];
  const shots = new Set();
  let cancelledAt = null;
  for (;;) {
    const s = await page.evaluate(() => window.__editorSubtitles.getStatus());
    const last = lines[lines.length - 1];
    const stage = s.progress.replace(/\d+%.*$/, "");
    if (s.busy && (!last || last.text !== s.progress)) {
      lines.push({ t: Date.now() - t0, text: s.progress });
      if (!shots.has(stage)) {
        shots.add(stage);
        await page.screenshot({ path: join(OUT, `${tag}-${shots.size}-${stage.replace(/[^a-z]+/gi, "-").toLowerCase()}.png`) });
      }
    }
    if (cancelWhen && s.busy && cancelledAt === null && cancelWhen(s.progress)) {
      cancelledAt = Date.now();
      await page.getByRole("button", { name: "Cancel", exact: true }).click();
    }
    if (!s.busy) {
      const idleAt = Date.now();
      return { ms: idleAt - t0, lines, cancelLatencyMs: cancelledAt ? idleAt - cancelledAt : null, status: s };
    }
    await page.waitForTimeout(100);
  }
}

try {
  await page.goto(`${BASE}/editor-lab/open?id=${ID}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__editor?.store?.getState().project && window.__editorSubtitles, null, { timeout: 90_000 });
  await page.evaluate(() => window.__editor.store.setInspectorTab("subtitles"));
  await page.waitForTimeout(1500);
  await page.screenshot({ path: join(OUT, "0-before.png") });
  const before = await state();
  if (before.ids.length) failures.push("fixture already has subtitles");

  // ── Generate (the pane's button, or pinned to a runtime) ────────────────
  if (DEVICE) {
    void page.evaluate((d) => window.__editorSubtitles.generate("generate", { device: d }), DEVICE);
  } else {
    await page.getByRole("button", { name: "Generate Subtitles" }).click();
  }
  const gen = await watch("generate");
  const first = await state();
  report.generate = { wallMs: gen.ms, progress: gen.lines, stats: first.stats, cues: first.cues.length, undoLabel: first.undoLabel };
  report.cues = first.cues;
  log("generate:", JSON.stringify({ wallMs: gen.ms, stats: first.stats, cues: first.cues.length, error: gen.status.error }));
  for (const l of gen.lines) log(`  +${String(l.t).padStart(6)} ms  ${l.text}`);
  if (!first.cues.length) failures.push(`generate produced no cues (${gen.status.error})`);
  if (first.undoLabel !== "Generate Subtitles") failures.push(`undo label after generate: ${first.undoLabel}`);
  const text = first.cues.map((c) => c.text).join(" ");
  if (REFERENCE) {
    report.accuracy = wer(REFERENCE, text);
    log("accuracy:", JSON.stringify(report.accuracy));
  }
  log("first cues:", JSON.stringify(first.cues.slice(0, 4)));
  report.transcript = text;

  // Show a cue on the stage (source 2.3 s → output via the controller's own map).
  await page.evaluate(() => window.__editor.controller.seekToSource(2.3));
  await page.waitForTimeout(1200);
  await page.screenshot({ path: join(OUT, "1-generated.png") });

  // Share transcript (core/transcript.ts) — OUTPUT seconds after trim + speed.
  report.share = await page.evaluate(async () => {
    const { transcriptForShare } = await import("/src/editor/core/transcript.ts");
    const p = window.__editor.store.getState().project;
    const t = transcriptForShare(p);
    return { segments: t.length, first: t[0], trim: [p.trimStart, p.trimEnd], speed: p.speedRegions };
  });
  log("share transcript:", JSON.stringify(report.share));

  // ── Regenerate, cancelled mid-transcription: nothing changes ────────────
  await page.getByRole("button", { name: "Regenerate", exact: true }).click();
  const cancelled = await watch("cancel", { cancelWhen: (p) => p.startsWith("Transcribing") });
  const afterCancel = await state();
  report.cancel = { latencyMs: cancelled.cancelLatencyMs, status: cancelled.status };
  log("cancel:", JSON.stringify(report.cancel));
  if (JSON.stringify(afterCancel.ids) !== JSON.stringify(first.ids)) failures.push("cancel changed the cues");
  if (afterCancel.undoLabel !== "Generate Subtitles") failures.push(`cancel added an undo step (${afterCancel.undoLabel})`);
  if (cancelled.status.error) failures.push(`cancel left an error: ${cancelled.status.error}`);
  if (cancelled.cancelLatencyMs === null) failures.push("never saw Transcribing… to cancel");

  // ── Regenerate to completion: ONE undo step; undo restores ──────────────
  await page.getByRole("button", { name: "Regenerate", exact: true }).click();
  const regen = await watch("regenerate");
  const second = await state();
  report.regenerate = { wallMs: regen.ms, stats: second.stats, cues: second.cues.length, undoLabel: second.undoLabel };
  log("regenerate:", JSON.stringify(report.regenerate));
  if (second.undoLabel !== "Regenerate Subtitles") failures.push(`undo label after regenerate: ${second.undoLabel}`);
  if (second.ids.some((id) => first.ids.includes(id))) failures.push("regenerate did not replace the cues");
  if (second.cues.map((c) => c.text).join("|") !== first.cues.map((c) => c.text).join("|")) {
    report.regenerateDiffers = true; // same audio, same model: expected identical text
    failures.push("regenerate produced different text for the same audio");
  }
  await page.evaluate(() => window.__editor.store.undo());
  const undone = await state();
  if (JSON.stringify(undone.ids) !== JSON.stringify(first.ids)) failures.push("undo did not restore the first cues");
  await page.screenshot({ path: join(OUT, "2-after-undo.png") });
} catch (error) {
  failures.push(`harness: ${error instanceof Error ? error.stack : String(error)}`);
  await page.screenshot({ path: join(OUT, "error.png") }).catch(() => {});
}

report.consoleErrors = consoleErrors.slice(0, 20);
report.failures = failures;
writeFileSync(join(OUT, "report.json"), JSON.stringify(report, null, 2));
log(consoleErrors.length ? `console errors:\n  ${consoleErrors.slice(0, 10).join("\n  ")}` : "no console errors");
log(failures.length ? `FAIL\n  ${failures.join("\n  ")}` : "PASS");
await context.close();
process.exit(failures.length ? 1 : 0);
