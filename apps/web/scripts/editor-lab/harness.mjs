#!/usr/bin/env node
/**
 * Headless perf + correctness harness for the web render engine (DEV ONLY).
 *
 * Drives the SYSTEM Chrome through playwright-core (channel "chrome" — no
 * browser download) against the /editor-lab page of a running dev server,
 * using the page's `window.__lab` API (src/editor/lab/labApi.ts).
 *
 *   node scripts/editor-lab/harness.mjs [--url http://localhost:3207] [--headed]
 *        [--only smoke,perf,seek,parity,export] [--seconds 10] [--seeks 50]
 *        [--out <dir>]    (screenshots + JSON report)
 *
 * Exit code 1 when any gate fails: seek mismatch, parity > 2/255, preview ≠
 * export pre-encode, dropped/late frames during 1080p playback.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const flag = (name) => args.includes(`--${name}`);
const BASE = opt("url", "http://localhost:3207");
const ONLY = new Set(opt("only", "smoke,seek,parity,camera,export,bench,perf,visual").split(","));
const SECONDS = Number(opt("seconds", "10"));
const SEEKS = Number(opt("seeks", "50"));
const OUT = opt("out", "/tmp/editor-lab-harness");
const DPR = Number(opt("dpr", "2"));
mkdirSync(OUT, { recursive: true });

const report = { startedAt: new Date().toISOString(), base: BASE, results: {} };
const failures = [];
const log = (...a) => console.log(...a);

const browser = await chromium.launch({
  channel: "chrome",
  headless: !flag("headed"),
  args: ["--autoplay-policy=no-user-gesture-required", "--enable-gpu", "--ignore-gpu-blocklist"],
});
report.chrome = browser.version();
const context = await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: DPR });
const page = await context.newPage();
const consoleErrors = [];
page.on("console", (m) => {
  if (m.type() === "error" || m.type() === "warning") {
    const loc = m.location();
    consoleErrors.push(`${m.type()}: ${m.text()}${loc?.url ? ` (${loc.url})` : ""}`);
  }
});
page.on("pageerror", (e) => consoleErrors.push(`pageerror: ${e.message}`));
context.on("response", (r) => {
  if (r.status() >= 400) consoleErrors.push(`http ${r.status()}: ${r.url()}`);
});

async function openLab(query = "") {
  await page.goto(`${BASE}/editor-lab${query}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__lab?.ready === true, null, { timeout: 60_000 });
}

async function loadClip(clip, preset = "angle-135") {
  return page.evaluate(([c, p]) => window.__lab.loadFixture(c, p), [clip, preset]);
}

const rnd = (() => {
  let s = 0x9e3779b9;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
})();

try {
  await openLab("?autoload=0");

  // ── smoke: load + render + screenshot ───────────────────────────────────
  if (ONLY.has("smoke")) {
    const info = await loadClip("h264-1080p");
    await page.evaluate(() => window.__lab.client().seek(1.0));
    await page.waitForTimeout(300);
    await page.screenshot({ path: join(OUT, "smoke-h264-1080p.png") });
    report.results.smoke = { info };
    log("smoke:", JSON.stringify(info));
  }

  // ── seek accuracy: random exact + mid-frame seeks, read the burned-in index ──
  if (ONLY.has("seek")) {
    const res = {};
    for (const clip of ["h264-1080p", "hevc-1080p", "h264-4k", "hevc-4k"]) {
      const info = await loadClip(clip);
      const probes = [];
      for (let i = 0; i < SEEKS; i++) {
        const frame = Math.floor(rnd() * info.frameCount);
        const mid = i % 2 === 1; // half the probes land mid-frame
        const t = (frame + (mid ? 0.5 : 0)) / info.fps;
        const t0 = Date.now();
        const p = await page.evaluate((tt) => window.__lab.seekProbe(tt), t);
        probes.push({ ...p, wallMs: Date.now() - t0 });
      }
      const bad = probes.filter((p) => !p.ok);
      const lat = probes.map((p) => p.wallMs).sort((a, b) => a - b);
      res[clip] = {
        seeks: probes.length,
        correct: probes.length - bad.length,
        mismatches: bad.slice(0, 5),
        latencyMs: { median: lat[lat.length >> 1], p95: lat[Math.floor(lat.length * 0.95)], max: lat[lat.length - 1] },
      };
      if (bad.length) failures.push(`seek ${clip}: ${bad.length}/${probes.length} wrong`);
      log(`seek ${clip}:`, JSON.stringify(res[clip]));
    }
    report.results.seek = res;
  }

  // ── parity: GPU vs CPU reference ────────────────────────────────────────
  if (ONLY.has("parity")) {
    const presets = await page.evaluate(async () => {
      const m = await import("/src/editor/lab/fixtures.ts");
      return Object.fromEntries(m.PROJECT_PRESETS.map((p) => [p.id, p.project]));
    });
    const cases = [
      { name: "srgb-angle135-lanczos-1080p", clipId: "h264-1080p", project: presets["angle-135"], pixelWidth: 1920, pixelHeight: 1080, reference: null },
      { name: "srgb-angle135-layerpath", clipId: "h264-1080p", project: presets["angle-135"], pixelWidth: 1920, pixelHeight: 1080, reference: null, forceLayer: true },
      { name: "p3-diagonal-squircle-720p", clipId: "hevc-1080p-p3", project: presets["squircle"], pixelWidth: 1280, pixelHeight: 960, reference: null },
      { name: "srgb-solid-rect-direct-1440p", clipId: "hevc-1080p", project: presets["solid-rect"], pixelWidth: 2560, pixelHeight: 1440, reference: { width: 1280, height: 720 } },
      { name: "srgb-default-diagonal-dpr2", clipId: "h264-1080p", project: presets["default"], pixelWidth: 1920, pixelHeight: 1080, reference: { width: 960, height: 540 } },
    ];
    const res = {};
    for (const c of cases) {
      const r = await page.evaluate((spec) => window.__lab.parity(spec), c);
      await page.screenshot({ path: join(OUT, `parity-${c.name}.png`) });
      res[c.name] = r;
      if (!r.pass) failures.push(`parity ${c.name}: max ${r.maxDiff}/255`);
      log(`parity ${c.name}: pass=${r.pass} max=${r.maxDiff} path=${r.videoPath} space=${r.workingSpace}`, JSON.stringify(r.categories));
      if (!r.pass) log("  worst:", JSON.stringify(r.worst.slice(0, 3)));
    }
    report.results.parity = res;
    // Back to the responsive stage for the sections that follow.
    await page.evaluate(() => window.__lab.resetViewport());
  }

  // ── camera: zoom through the card-layer path, structural strip decode ───
  if (ONLY.has("camera")) {
    const res = [];
    // Zoom/focal picked so every strip cell stays on the canvas after the zoom
    // (the probe reports offCanvas otherwise — it is a failure, not a pass).
    for (const [clip, z, fx, fy, t] of [["h264-1080p", 1.25, 0.5, 0.2, 1.0], ["hevc-4k", 1.2, 0.45, 0.1, 3.0], ["hevc-1080p", 1.15, 0.55, 0.3, 7.5]]) {
      await loadClip(clip, "angle-135");
      const r = await page.evaluate(([tt, zz, x, y]) => window.__lab.cameraProbe(tt, zz, x, y), [t, z, fx, fy]);
      res.push({ clip, zoom: z, ...r });
      if (!r.ok || r.unzoomedDecodeWouldPass) failures.push(`camera ${clip} zoom ${z}: ${JSON.stringify(r)}`);
      log(`camera ${clip} zoom ${z}:`, JSON.stringify(r));
    }
    report.results.camera = res;
  }

  // ── export: same passes → VideoEncoder → mp4; preview == export ──────────
  if (ONLY.has("export")) {
    await openLab("?autoload=0");
    await loadClip("h264-1080p", "angle-135");
    await page.evaluate(() => window.__lab.client().seek(0));
    const r = await page.evaluate(() => window.__lab.exportCheck({ seconds: 2 }));
    report.results.export = r;
    const identical = r.previewVsExport.every((f) => f.max === 0);
    const idxOk = r.decodedVsExport.every((f) => f.index === f.expectedIndex);
    if (!identical) failures.push("export: pre-encode frames differ from preview");
    if (!idxOk || !r.sourceIndicesMatchExporterRule) failures.push("export: frame timing mismatch");
    log("export:", JSON.stringify(r));
  }

  // ── bench: saturated GPU cost per frame (no vsync) ──────────────────────
  if (ONLY.has("bench")) {
    const res = {};
    for (const clip of opt("clips", "h264-1080p,hevc-1080p,h264-4k,hevc-4k").split(",")) {
      await openLab("?autoload=0");
      await loadClip(clip);
      await page.evaluate(() => window.__lab.client().seek(1.0));
      const newFrame = await page.evaluate(() => window.__lab.client().bench(240, true));
      const sameFrame = await page.evaluate(() => window.__lab.client().bench(240, false));
      res[clip] = { newFrame, sameFrame };
      log(`bench ${clip}: new-frame ${newFrame.msPerFrame.toFixed(3)} ms, same-frame ${sameFrame.msPerFrame.toFixed(3)} ms @ ${newFrame.target.width}x${newFrame.target.height} (videoScale ${newFrame.videoScale.toFixed(3)})`);
    }
    report.results.bench = res;
  }

  // ── perf: play each fixture for N seconds ───────────────────────────────
  if (ONLY.has("perf")) {
    const res = {};
    for (const clip of opt("clips", "h264-1080p,hevc-1080p,h264-4k,hevc-4k").split(",")) {
      await openLab("?autoload=0");
      const info = await loadClip(clip);
      const r = await page.evaluate((s) => window.__lab.perf(s), SECONDS);
      const s = r.stats;
      res[clip] = {
        canvas: await page.evaluate(() => {
          const c = document.querySelector("canvas");
          return c ? `${c.clientWidth}x${c.clientHeight}css@${devicePixelRatio}x` : "?";
        }),
        video: `${info.codec} ${info.width}x${info.height}@${info.fps} hw=${info.hardwareDecode}`,
        fps: s.fps,
        cpuFrameMs: s.frameMs,
        gpuFrameMs: s.gpuMs,
        vsyncIntervalMs: s.intervalMs,
        rendered: s.rendered,
        lateFrames: s.lateFrames,
        skippedFrames: s.skippedFrames,
        decode: s.stream,
        audioMasterClock: await page.evaluate(() => window.__lab.client().hasAudioClock),
        lastClockSyncErrorMs: s.clockSyncErrorMs,
        perSecond: r.perSecond,
      };
      if (clip.includes("1080p") && (s.lateFrames > 0 || s.skippedFrames > 0)) {
        failures.push(`perf ${clip}: late ${s.lateFrames} skipped ${s.skippedFrames}`);
      }
      await page.screenshot({ path: join(OUT, `perf-${clip}.png`) });
      log(`perf ${clip}:`, JSON.stringify(res[clip]));
    }
    // Rate changes: 2x makes the decoder run at 120 fps (every frame must still
    // be decoded — only the display skips); 0.5x shows each frame twice.
    for (const [clip, rate] of [["h264-1080p", 2], ["hevc-4k", 2], ["hevc-1080p", 0.5]]) {
      await openLab("?autoload=0");
      await loadClip(clip);
      const r = await page.evaluate(([s, rt]) => window.__lab.perf(s, { rate: rt }), [Math.min(5, SECONDS), rate]);
      const s = r.stats;
      res[`${clip}@${rate}x`] = { fps: s.fps, lateFrames: s.lateFrames, skippedFrames: s.skippedFrames, gpuFrameMs: s.gpuMs, decode: s.stream };
      log(`perf ${clip}@${rate}x: fps ${s.fps} late ${s.lateFrames} skipped ${s.skippedFrames} lateOutputs ${s.stream?.lateOutputs}`);
    }
    report.results.perf = res;
  }

  // ── visual: screenshots of presets + the camera (card-layer) path ───────
  if (ONLY.has("visual")) {
    await openLab("?autoload=0");
    for (const preset of ["default", "angle-135", "squircle", "solid-rect", "vertical"]) {
      await loadClip("h264-1080p", preset);
      await page.evaluate(() => window.__lab.client().seek(2.0));
      await page.waitForTimeout(250);
      await page.screenshot({ path: join(OUT, `visual-${preset}.png`) });
    }
    await loadClip("hevc-4k", "angle-135");
    await page.evaluate(async () => {
      const c = window.__lab.client();
      await c.seek(3.0);
      c.debug({ camera: { zoom: 1.6, focalX: 0.3, focalY: 0.35 } });
    });
    await page.waitForTimeout(300);
    await page.screenshot({ path: join(OUT, "visual-camera-zoom.png") });
    await page.evaluate(() => window.__lab.client().debug({ camera: null }));
    log(`visual: screenshots in ${OUT}`);
  }
} catch (e) {
  failures.push(`harness error: ${e?.stack ?? e}`);
  await page.screenshot({ path: join(OUT, "error.png") }).catch(() => {});
} finally {
  report.consoleErrors = consoleErrors.slice(0, 50);
  if (consoleErrors.some((e) => /WebGPU error|pageerror|VideoDecoder error/.test(e))) failures.push("console: WebGPU/decoder errors");
  report.failures = failures;
  writeFileSync(join(OUT, "report.json"), JSON.stringify(report, null, 2));
  await browser.close();
}

if (consoleErrors.length) log(`console (${consoleErrors.length}):\n  ${consoleErrors.slice(0, 15).join("\n  ")}`);
log(failures.length ? `FAIL:\n  ${failures.join("\n  ")}` : "PASS");
log(`report: ${join(OUT, "report.json")}`);
process.exit(failures.length ? 1 : 0);
