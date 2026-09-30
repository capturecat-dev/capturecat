#!/usr/bin/env node
/**
 * Timeline media harness (DEV ONLY): the VIDEO row's filmstrip, the
 * recording waveform and the voice-clip waveforms on the REAL editor page
 * (/editor-lab/open), plus frame pacing while the media worker decodes.
 *
 *   node scripts/editor-lab/timeline-media.mjs --url http://localhost:3213 \
 *        [--project <UUID>] [--out <dir>] [--seconds 4]
 *
 * 1. SYNTHETIC project (deterministic, no user data): the parity fixture
 *    12-speed-trim-clips (trim, two clips, 2× and 0.5× speed) whose
 *    recording is served from .fixtures/h264-1080p.mp4 (video + AAC audio),
 *    plus a synthetic speech-like WAV voice-over; all served through
 *    Playwright routes under a fake project id. Screenshots: the strip +
 *    waveforms, voice clips added while the editor is open, and a zoomed
 *    timeline. Structural checks read the timeline canvas pixels (the VIDEO
 *    lane must carry varying filmstrip tiles and waveform bars).
 * 2. A LOCAL Mac project (--project, or the first 20–400 s one with an
 *    audio track): cold decode vs. warm IndexedDB reopen, and playback frame
 *    pacing alone vs. while the worker regenerates thumbnails + envelopes.
 *
 * Writes screenshots + report.json to --out. Exit 1 on any failed check.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const BASE = opt("url", "http://localhost:3207");
const OUT = opt("out", "/tmp/timeline-media-harness");
const SECONDS = Number(opt("seconds", "4"));
let PROJECT = opt("project", null);
mkdirSync(OUT, { recursive: true });

const FIXTURES = new URL("../../.fixtures/", import.meta.url).pathname;
const FAKE_ID = "00000000-0000-4000-8000-0000000F11E5";
const report = { base: BASE, startedAt: new Date().toISOString(), results: {} };
const failures = [];
const log = (...a) => console.log(...a);

/** 8 s mono 44.1 kHz s16 WAV: noise "syllables" under sin² envelopes, with pauses (xorshift32). */
function speechWav() {
  const rate = 44100;
  const n = rate * 8;
  const pcm = new Int16Array(n);
  let s = 0x2545f491;
  const rnd = () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
    return s / 4294967296;
  };
  let t = 0.2;
  while (t < 7.6) {
    const len = 0.12 + rnd() * 0.35;
    const amp = 0.15 + rnd() * 0.8;
    const a = Math.floor(t * rate);
    const b = Math.min(n, Math.floor((t + len) * rate));
    for (let i = a; i < b; i++) {
      const e = Math.sin((Math.PI * (i - a)) / (b - a)) ** 2;
      pcm[i] = Math.round((rnd() * 2 - 1) * amp * e * 30000);
    }
    t += len + (rnd() < 0.25 ? 0.5 + rnd() * 0.6 : 0.04 + rnd() * 0.1);
  }
  const buf = Buffer.alloc(44 + n * 2);
  buf.write("RIFF", 0);
  buf.writeUInt32LE(36 + n * 2, 4);
  buf.write("WAVEfmt ", 8);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write("data", 36);
  buf.writeUInt32LE(n * 2, 40);
  Buffer.from(pcm.buffer).copy(buf, 44);
  return buf;
}

/** Fulfil with Range support (mediabunny reads ranges). */
async function fulfilBytes(route, bytes, contentType) {
  const range = route.request().headers()["range"];
  const m = range && /bytes=(\d+)-(\d*)/.exec(range);
  if (!m) return route.fulfill({ status: 200, body: bytes, headers: { "content-type": contentType, "accept-ranges": "bytes" } });
  const start = Number(m[1]);
  const end = Math.min(bytes.length - 1, m[2] ? Number(m[2]) : bytes.length - 1);
  return route.fulfill({
    status: 206,
    body: bytes.subarray(start, end + 1),
    headers: { "content-type": contentType, "accept-ranges": "bytes", "content-range": `bytes ${start}-${end}/${bytes.length}` },
  });
}

const browser = await chromium.launch({
  channel: "chrome",
  headless: true,
  args: ["--autoplay-policy=no-user-gesture-required", "--enable-gpu", "--ignore-gpu-blocklist"],
});
const context = await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 });
const page = await context.newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(e.message));

// ── synthetic project routes ─────────────────────────────────────────────
const syntheticDoc = (() => {
  const doc = JSON.parse(readFileSync(join(FIXTURES, "parity/12-speed-trim-clips/project.json"), "utf8"));
  doc.id = FAKE_ID;
  doc.name = "Timeline media fixture";
  doc.videoURL = "recording.mp4";
  doc.duration = 10;
  doc.trimStart = 0.5;
  doc.trimEnd = 9.4;
  doc.speedRegions = [
    { id: "00000000-0000-4000-8000-000000001201", startTime: 2, endTime: 4, speed: 2 },
    { id: "00000000-0000-4000-8000-000000001202", startTime: 6.5, endTime: 7.5, speed: 0.5 },
  ];
  doc.videoClipSegments = [
    { id: "00000000-0000-4000-8000-000000001203", startTime: 0.5, endTime: 5.2 },
    { id: "00000000-0000-4000-8000-000000001204", startTime: 5.6, endTime: 9.4 },
  ];
  doc.voiceOverClips = [];
  doc.cursorDataURL = null;
  delete doc.keystrokeDataURL;
  doc.cameraVideoURL = null;
  return doc;
})();
const voiceWav = speechWav();
await page.route(`**/__dev/local-projects/${FAKE_ID}/**`, async (route) => {
  const url = new URL(route.request().url());
  if (url.pathname.endsWith("/project.json")) {
    return route.fulfill({ status: 200, body: JSON.stringify(syntheticDoc), headers: { "content-type": "application/json" } });
  }
  const ref = url.searchParams.get("ref") ?? "";
  if (ref === "recording.mp4") return route.continue({ url: `${BASE}/.fixtures/h264-1080p.mp4` });
  if (ref === "voice-synthetic.wav") return fulfilBytes(route, voiceWav, "audio/wav");
  return route.fulfill({ status: 404, body: "" });
});

async function clearCache() {
  await page.evaluate(
    () =>
      new Promise((resolve) => {
        const r = indexedDB.deleteDatabase("capturecat-timeline-media");
        r.onsuccess = r.onerror = r.onblocked = () => resolve(null);
      }),
  );
}

async function open(id) {
  const t0 = Date.now();
  await page.goto(`${BASE}/editor-lab/open?id=${id}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(
    () => window.__timelineMedia?.stats?.filmstrip && window.__timelineMedia.getSnapshot().recording !== null,
    null,
    { timeout: 120_000 },
  );
  const wall = Date.now() - t0;
  const state = await page.evaluate(() => {
    const m = window.__timelineMedia;
    const s = m.getSnapshot();
    return {
      stats: m.stats,
      thumbnails: s.thumbnails.length,
      thumbSize: s.thumbnails[0] ? [s.thumbnails[0].width, s.thumbnails[0].height] : null,
      tracks: (s.recording ?? []).map((e) => e && { rate: e.sampleRate, channels: e.channels, frames: e.frameCount, peak: e.peaks.reduce((a, b) => (b > a ? b : a), 0) }),
    };
  });
  return { wall, ...state };
}

const timelineShot = async (name) => {
  await page.waitForTimeout(300);
  const el = await page.$(".cc-tl-area");
  if (el) await el.screenshot({ path: join(OUT, `${name}.png`) });
};

/**
 * Structural read of the timeline's base canvas: the VIDEO lane (y 28…76 css px)
 * and each voice clip's waveform strip. Returns luminance statistics.
 */
const laneStats = () =>
  page.evaluate(() => {
    const canvas = document.querySelector(".cc-tl-canvas");
    const dpr = canvas.width / canvas.clientWidth;
    const ctx = canvas.getContext("2d");
    const row = (yCss, x0Css, x1Css) => {
      const y = Math.round(yCss * dpr);
      const x0 = Math.round(x0Css * dpr);
      const w = Math.max(1, Math.round((x1Css - x0Css) * dpr));
      const d = ctx.getImageData(x0, y, w, 1).data;
      const lum = [];
      for (let i = 0; i < d.length; i += 4) lum.push(0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]);
      return lum;
    };
    const stats = (lum) => {
      const mean = lum.reduce((a, b) => a + b, 0) / lum.length;
      const sd = Math.sqrt(lum.reduce((a, b) => a + (b - mean) ** 2, 0) / lum.length);
      let changes = 0;
      for (let i = 1; i < lum.length; i++) if (Math.abs(lum[i] - lum[i - 1]) > 24) changes++;
      return { mean, sd, changes };
    };
    const w = canvas.clientWidth;
    // Filmstrip body (mid-lane) and the waveform strip (bottom 14 px of the clip, centre row).
    const film = stats(row(28 + 20, 20, w - 20));
    const wave = stats(row(28 + 48 - 2 - 7, 20, w - 20));
    // Voice lane: the 16 px bar strip sits 8 + 14 + 4 below the block top (lane y 80, block 50 tall → y 79).
    const voiceRows = [];
    for (let y = 79 + 8 + 14 + 4 + 1; y < 79 + 8 + 14 + 4 + 16; y += 2) voiceRows.push(stats(row(y, 0, w)).changes);
    return { film, wave, voiceChangesMax: Math.max(...voiceRows) };
  });

try {
  await page.goto(`${BASE}/editor-lab/open`, { waitUntil: "domcontentloaded" });
  await clearCache();

  // ── 1. synthetic project ─────────────────────────────────────────────────
  const synth = await open(FAKE_ID);
  log("synthetic:", JSON.stringify(synth));
  report.results.synthetic = synth;
  if (synth.thumbnails !== 40) failures.push(`synthetic filmstrip: ${synth.thumbnails}/40 thumbnails`);
  if (!synth.tracks[0] || !(synth.tracks[0].peak > 1000)) failures.push("synthetic recording envelope missing or silent");
  if (!synth.thumbSize || synth.thumbSize[1] !== 96) failures.push(`thumbnail height ${synth.thumbSize?.[1]} ≠ 96 px at 2×`);
  await page.waitForTimeout(400);
  const lanes0 = await laneStats();
  report.results.lanes = lanes0;
  log("lanes:", JSON.stringify(lanes0));
  // Colour-bar thumbnails: many hard luma edges across the lane (the bare yellow slab has ~40, from its segments/pill).
  if (!(lanes0.film.changes >= 90)) failures.push(`VIDEO lane shows no filmstrip (${lanes0.film.changes} edges)`);
  if (!(lanes0.wave.changes >= 20)) failures.push(`VIDEO lane shows no waveform bars (${lanes0.wave.changes} edges)`);
  await timelineShot("01-filmstrip-waveform");

  // Voice clips added while the editor is open (what a voice-over recording does).
  const voice = await page.evaluate(async () => {
    const { store } = window.__editor;
    const clip = (i, start, src, dur, label) => ({
      id: `00000000-0000-4000-8000-00000000000${i}`,
      fileName: "voice-synthetic.wav",
      startTime: start,
      sourceStartTime: src,
      duration: dur,
      sourceDuration: 8,
      gain: 1,
      label,
    });
    const before = window.__timelineMedia.getSnapshot().voice.size;
    store.transact("Add Voice Over", (d) => {
      d.voiceOverClips.push(clip(1, 0.8, 0, 3.2, "Voice Over"));
      d.voiceOverClips.push(clip(2, 5.8, 3.5, 2.4, "Take 2"));
    });
    const t0 = performance.now();
    while (performance.now() - t0 < 30_000) {
      const env = window.__timelineMedia.getSnapshot().voice.get("voice-synthetic.wav");
      if (env !== undefined) return { before, ms: performance.now() - t0, decoded: env !== null, rate: env?.sampleRate, frames: env?.frameCount };
      await new Promise((r) => setTimeout(r, 30));
    }
    return { before, ms: -1, decoded: false };
  });
  log("voice:", JSON.stringify(voice));
  report.results.voice = voice;
  if (!voice.decoded) failures.push("voice-over waveform never arrived");
  await page.waitForTimeout(400);
  const lanes1 = await laneStats();
  report.results.lanesWithVoice = lanes1;
  log("lanes with voice:", JSON.stringify(lanes1));
  if (!(lanes1.voiceChangesMax >= 30)) failures.push(`voice clips show no waveform bars (${lanes1.voiceChangesMax} edges)`);
  await timelineShot("02-voice-waveforms");

  // Timeline zoom: the strip re-tiles (more tiles probing nearer thumbnails).
  await page.evaluate(() => {
    const host = document.querySelector(".cc-tl-viewport");
    for (let i = 0; i < 6; i++) host.dispatchEvent(new WheelEvent("wheel", { deltaY: -40, ctrlKey: true, bubbles: true, cancelable: true }));
  });
  await timelineShot("03-zoomed");
  await page.evaluate(() => {
    const host = document.querySelector(".cc-tl-viewport");
    for (let i = 0; i < 6; i++) host.dispatchEvent(new WheelEvent("wheel", { deltaY: 40, ctrlKey: true, bubbles: true, cancelable: true }));
  });

  // Negative control: without the media the same checks must fail.
  const control = await page.evaluate(async () => {
    window.__timelineMedia.dispose();
    await new Promise((r) => setTimeout(r, 300));
    return true;
  });
  if (control) {
    const lanesOff = await laneStats();
    report.results.negativeControl = lanesOff;
    log("negative control (media disposed):", JSON.stringify(lanesOff));
    if (lanesOff.film.changes >= 90) failures.push("negative control: filmstrip check passed without thumbnails — the gate is blind");
    if (lanesOff.wave.changes >= 20) failures.push("negative control: waveform check passed without samples — the gate is blind");
    if (lanesOff.voiceChangesMax >= 30) failures.push("negative control: voice check passed without waveforms — the gate is blind");
  }

  // ── 2. a local Mac project: cache + frame pacing ─────────────────────────
  await page.goto(`${BASE}/editor-lab/open`, { waitUntil: "domcontentloaded" });
  if (!PROJECT) {
    const list = await page.evaluate(async () => (await (await fetch("/__dev/local-projects")).json()).projects);
    for (const p of list.filter((p) => p.hasVideo && p.duration >= 20 && p.duration <= 400)) {
      const r = await open(p.id);
      if (r.tracks.some((t) => t)) {
        PROJECT = p.id;
        break;
      }
    }
  }
  if (PROJECT) {
    report.project = PROJECT;
    await clearCache();
    const cold = await open(PROJECT);
    log("local cold:", JSON.stringify(cold));
    const warm = await open(PROJECT);
    log("local warm:", JSON.stringify(warm));
    report.results.cold = cold;
    report.results.warm = warm;
    if (cold.thumbnails !== 40) failures.push(`local filmstrip: ${cold.thumbnails}/40 thumbnails`);
    if (!warm.stats.filmstrip?.fromCache || !warm.stats.recording?.fromCache) failures.push("warm reopen was not served from the cache");
    await timelineShot("04-local-project");

    const pacing = async (generate, playingFlag) =>
      page.evaluate(
        async ({ seconds, generate, playingFlag, projectId }) => {
          const { controller, store } = window.__editor;
          const client = controller.client;
          await client.seek(0);
          await new Promise((r) => setTimeout(r, 300));
          client.resetStats();
          const deltas = [];
          let last = 0;
          let running = true;
          const tick = (t) => {
            if (last) deltas.push(t - last);
            last = t;
            if (running) requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
          client.play();
          const jobs = [];
          let thumbsDelivered = 0;
          let gen = null;
          if (generate) {
            const { TimelineMediaClient } = await import("/src/editor/ui/timeline/media/timelineMediaClient.ts");
            gen = new TimelineMediaClient();
            gen.setPlaying(playingFlag);
            const p = store.getState().project;
            const url = new URL(`/__dev/local-projects/${projectId}/media?ref=${encodeURIComponent(p.videoURL)}`, location.href).href;
            const until = performance.now() + seconds * 1000;
            void (async () => {
              while (performance.now() < until) {
                const t0 = performance.now();
                const r = await gen.filmstrip({ url, cacheKey: null, duration: p.duration, count: 40, heightPx: 96 }, (_i, b) => {
                  thumbsDelivered++;
                  b.close();
                }).done;
                if (r) jobs.push({ kind: "filmstrip", ms: Math.round(performance.now() - t0), decoded: r.decoded });
                const t1 = performance.now();
                const e = await gen.envelope({ url, cacheKey: null, tracks: "all", gapless: false }).done;
                if (e) jobs.push({ kind: "envelope", ms: Math.round(performance.now() - t1) });
              }
            })();
          }
          await new Promise((r) => setTimeout(r, seconds * 1000));
          running = false;
          const stats = client.lastStats;
          client.pause();
          gen?.dispose();
          const sorted = deltas.slice(1).sort((a, b) => a - b);
          const q = (f) => +sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * f))].toFixed(2);
          return {
            rafFrames: sorted.length,
            rafMs: { median: q(0.5), p95: q(0.95), p99: q(0.99), max: +sorted[sorted.length - 1].toFixed(2) },
            rafOver25ms: sorted.filter((d) => d > 25).length,
            thumbsDelivered,
            engine: stats && { fps: stats.fps, intervalMs: stats.intervalMs, lateFrames: stats.lateFrames, skippedFrames: stats.skippedFrames },
            jobs,
          };
        },
        { seconds: SECONDS, generate, playingFlag, projectId: PROJECT },
      );
    const baselineA = await pacing(false, true);
    log("pacing baseline A:", JSON.stringify(baselineA));
    const paced = await pacing(true, true);
    log("pacing while generating (paced, as while playing):", JSON.stringify(paced));
    const unpaced = await pacing(true, false);
    log("pacing while generating (unpaced):", JSON.stringify(unpaced));
    const baselineB = await pacing(false, true);
    log("pacing baseline B:", JSON.stringify(baselineB));
    report.results.pacing = { baselineA, baselineB, paced, unpaced };
    // lateFrames (a tick whose frame was not decoded in time) is the stall signal.
    // skippedFrames jitters 0–9 per window even with nothing else running (headless
    // vsync vs. the source's frame phase), so it is bounded by the NOISIER baseline.
    const lateOf = (r) => r.engine?.lateFrames ?? 0;
    const skipOf = (r) => r.engine?.skippedFrames ?? 0;
    const hitchOf = (r) => r.rafOver25ms;
    const lateBase = Math.min(lateOf(baselineA), lateOf(baselineB));
    const skipBase = Math.max(skipOf(baselineA), skipOf(baselineB));
    const hitchBase = Math.max(hitchOf(baselineA), hitchOf(baselineB));
    if (!(paced.thumbsDelivered > 0) || !(unpaced.thumbsDelivered > 0)) failures.push("no generation ran during the pacing windows");
    for (const [name, r] of [["paced", paced], ["unpaced", unpaced]]) {
      if (lateOf(r) > lateBase + 2) failures.push(`playback had ${lateOf(r)} late frames while generating (${name}; baseline ${lateBase})`);
      if (skipOf(r) > skipBase + 3) failures.push(`playback skipped ${skipOf(r)} frames while generating (${name}; noisiest baseline ${skipBase})`);
      if (hitchOf(r) > hitchBase + 2) failures.push(`main-thread rAF hitched ${hitchOf(r)}× while generating (${name}; baseline ${hitchBase})`);
    }
  } else {
    log("no local project with recorded audio — skipped the cache/pacing phase");
  }
} catch (error) {
  failures.push(`harness error: ${error instanceof Error ? error.message : String(error)}`);
}

report.pageErrors = pageErrors.slice(0, 10);
report.failures = failures;
writeFileSync(join(OUT, "report.json"), JSON.stringify(report, null, 2));
await browser.close();
if (pageErrors.length) log("page errors:", pageErrors.slice(0, 5));
log(failures.length ? `TIMELINE MEDIA FAIL\n  ${failures.join("\n  ")}` : "TIMELINE MEDIA PASS");
process.exit(failures.length ? 1 : 0);
