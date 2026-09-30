#!/usr/bin/env node
/**
 * Voice-over recording gate (DEV ONLY): the REAL editor page
 * (/editor-lab/open) over a synthetic CLOUD project whose API is mocked in
 * the browser (no sign-in, nothing leaves the machine), recording from
 * Chrome's fake microphone.
 *
 *   node scripts/editor-lab/voiceover.mjs [--url http://localhost:3212] [--out <dir>] [--headed]
 *        [--only record,wav,mickey,end,local,denied,missing]
 *
 * record   mic key at 1.0 s → the live VOICE block grows (pixel count rises
 *          between two captures mid-take) → space stops → a Mac-shaped
 *          VoiceOverClip is appended (undo/redo) → the take is staged with
 *          the FULL manifest, PUT, finalized, and only then project.json is
 *          saved with the clip → the file is AAC-LC / 48 kHz / mono (ffprobe +
 *          macOS `afinfo`, the AudioToolbox reader AVAudioFile uses) → the
 *          playback mixer renders sound in the clip window → the EXPORTED
 *          mp4's audio (decoded by ffmpeg) is non-silent inside the clip
 *          window and silent outside it (the fixture has no other audio).
 *   wav      the no-AAC fallback (forced): voiceover-<UUID>.wav, audio/wav,
 *          plays and exports.
 *   mickey   the mic key again mid-take: the take stops, playback keeps going.
 *   end      a take that reaches the end of the timeline stops there; the
 *          playhead returns to the start; the editor's looping is restored.
 *   local    a dev-server LOCAL project (read-only): the take plays from the
 *          tab; nothing is uploaded or written.
 *   denied   getUserMedia → NotAllowedError: the house "Voice Over" alert
 *          with the Mac's copy; nothing recorded.
 *   missing  getUserMedia → NotFoundError: "Unable to start voice-over recording."
 *
 * Exit 1 on any failed check. Screenshots + the recorded/exported files go to --out.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
};
const BASE = opt("url", "http://localhost:3212");
const OUT = opt("out", "/tmp/capturecat-voiceover");
const ONLY = new Set(opt("only", "record,wav,mickey,end,local,denied,missing").split(","));
const HEADED = args.includes("--headed");
const API = "http://localhost:8787"; // .env.development VITE_API_URL (mocked below)
mkdirSync(OUT, { recursive: true });

const FIXTURE = "01-baseline-gradient";
const FIX_DIR = new URL(`../../.fixtures/parity/${FIXTURE}/`, import.meta.url).pathname;
const DOC_TEXT = readFileSync(join(FIX_DIR, "project.json"), "utf8");
const DOC = JSON.parse(DOC_TEXT);
const ID = DOC.id;

const failures = [];
const log = (...a) => console.log(...a);
function check(ok, label, detail = "") {
  log(`${ok ? "  ok  " : "  FAIL"} ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures.push(label);
}
const sha = (buf) => createHash("sha256").update(buf).digest("hex");

// ── Mock cloud (API + R2), state per scenario ────────────────────────────

function fixtureFile(name, contentType, source) {
  const bytes = readFileSync(join(FIX_DIR, name));
  return { path: name, sha256: sha(bytes), bytes: bytes.length, contentType, source, url: `${BASE}/.fixtures/parity/${FIXTURE}/${name}` };
}

function makeCloud() {
  const state = {
    revision: 5,
    document: DOC_TEXT,
    files: [fixtureFile("recording.mp4", "video/mp4", DOC.videoURL), fixtureFile("cursor.json", "application/json", DOC.cursorDataURL)],
    objects: new Map(), // sha → Buffer (uploaded)
    staged: null,
    events: [], // ordered log: stage / put / finalize / save
    saves: [],
  };
  const urlFor = (f) => (state.objects.has(f.sha256) ? `${BASE}/__mock-r2/${f.sha256}` : f.url);
  const filesOut = () => state.files.map((f) => ({ ...f, url: urlFor(f) }));
  return { state, filesOut };
}

const CORS = {
  "Access-Control-Allow-Origin": BASE,
  "Access-Control-Allow-Credentials": "true",
  "Access-Control-Allow-Headers": "Content-Type, If-Match",
  "Access-Control-Allow-Methods": "GET, PUT, POST, DELETE, OPTIONS",
};
const json = (route, status, body) =>
  route.fulfill({ status, headers: { ...CORS, "Content-Type": "application/json" }, body: JSON.stringify(body) });

async function installMocks(context, cloud) {
  const { state, filesOut } = cloud;
  await context.route(`${API}/api/cloud-projects**`, async (route) => {
    const req = route.request();
    const method = req.method();
    const path = new URL(req.url()).pathname.replace(/^\/api\/cloud-projects/, "");
    if (method === "OPTIONS") return route.fulfill({ status: 204, headers: CORS });
    if (method === "GET" && path === "") return json(route, 200, { projects: [] });
    if (method === "GET" && path === `/${ID}`) {
      return json(route, 200, {
        projectId: ID,
        name: DOC.name,
        revision: state.revision,
        documentSha256: sha(state.document),
        access: "owner",
        isOwner: true,
        orgId: null,
        updatedAt: new Date().toISOString(),
        document: state.document,
        files: filesOut(),
        urlsExpireAt: new Date(Date.now() + 15 * 60_000).toISOString(),
      });
    }
    if (method === "GET" && path === `/${ID}/files`) {
      return json(route, 200, { revision: state.revision, files: filesOut(), urlsExpireAt: new Date(Date.now() + 15 * 60_000).toISOString() });
    }
    if (method === "PUT" && path === `/${ID}`) {
      const body = JSON.parse(req.postData() ?? "{}");
      state.staged = body;
      state.events.push({ kind: "stage", files: body.files.map((f) => f.path) });
      const have = new Set([...state.files.map((f) => f.sha256), ...state.objects.keys()]);
      const missing = body.files
        .filter((f) => !have.has(f.sha256))
        .map((f) => ({ sha256: f.sha256, bytes: f.bytes, contentType: f.contentType, paths: [f.path], method: "PUT", uploadUrl: `${BASE}/__mock-r2/put/${f.sha256}`, headers: { "Content-Type": f.contentType } }));
      return json(route, 200, { projectId: ID, revision: state.revision, documentSha256: sha(state.document), missing, presentCount: body.files.length - missing.length, expiresIn: 900 });
    }
    if (method === "POST" && path === `/${ID}/finalize`) {
      const staged = state.staged;
      if (!staged) return json(route, 200, { projectId: ID, committed: true, revision: state.revision, fileCount: state.files.length, totalBytes: 0 });
      const lost = staged.files.filter((f) => !state.objects.has(f.sha256) && !state.files.some((x) => x.sha256 === f.sha256));
      if (lost.length) return json(route, 409, { error: "missing", code: "objects_missing", missing: lost.map((f) => ({ sha256: f.sha256, paths: [f.path] })) });
      const bySha = new Map(state.files.map((f) => [f.sha256, f]));
      state.files = staged.files.map((f) => ({ ...f, source: f.source ?? null, url: bySha.get(f.sha256)?.url ?? "" }));
      state.staged = null;
      state.events.push({ kind: "finalize" });
      return json(route, 200, { projectId: ID, committed: true, revision: state.revision, fileCount: state.files.length, totalBytes: 0 });
    }
    if (method === "PUT" && path === `/${ID}/project`) {
      const base = Number(String(req.headers()["if-match"] ?? "").replaceAll('"', ""));
      if (base !== state.revision) return json(route, 409, { code: "revision_conflict", revision: state.revision, document: state.document, updatedAt: new Date().toISOString() });
      state.document = req.postData() ?? "";
      state.revision += 1;
      state.saves.push(state.document);
      state.events.push({ kind: "save", revision: state.revision });
      return json(route, 200, { revision: state.revision, documentSha256: sha(state.document), updatedAt: new Date().toISOString() });
    }
    return json(route, 404, { error: `mock: ${method} ${path}` });
  });
  // Presigned R2 (same origin as the page: no CORS in the way).
  await context.route(`${BASE}/__mock-r2/**`, async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const put = url.pathname.match(/^\/__mock-r2\/put\/([0-9a-f]{64})$/);
    if (put && req.method() === "PUT") {
      const body = req.postDataBuffer() ?? Buffer.alloc(0);
      if (sha(body) !== put[1]) return route.fulfill({ status: 400, body: "hash mismatch" });
      state.objects.set(put[1], body);
      state.events.push({ kind: "put", sha256: put[1], bytes: body.length, contentType: req.headers()["content-type"] });
      return route.fulfill({ status: 200, body: "" });
    }
    const get = url.pathname.match(/^\/__mock-r2\/([0-9a-f]{64})$/);
    return serveBytes(route, get ? state.objects.get(get[1]) : null);
  });
}

/** 200 / 206 (Range) / 404 for an in-memory file. */
function serveBytes(route, bytes) {
  if (!bytes) return route.fulfill({ status: 404, body: "" });
  const range = route.request().headers()["range"];
  const m = range && /bytes=(\d+)-(\d*)/.exec(range);
  if (m) {
    const start = Number(m[1]);
    const end = m[2] ? Math.min(Number(m[2]), bytes.length - 1) : bytes.length - 1;
    return route.fulfill({
      status: 206,
      headers: { "Content-Range": `bytes ${start}-${end}/${bytes.length}`, "Accept-Ranges": "bytes", "Content-Type": "application/octet-stream" },
      body: bytes.subarray(start, end + 1),
    });
  }
  return route.fulfill({ status: 200, headers: { "Accept-Ranges": "bytes" }, body: bytes });
}

/** The dev server's read-only LOCAL project (vite/localProjects.ts), served from the fixture; no cloud copy. */
async function installLocalMocks(context) {
  await context.route(`${API}/api/cloud-projects**`, (route) =>
    route.request().method() === "OPTIONS" ? route.fulfill({ status: 204, headers: CORS }) : json(route, 404, { error: "Project not found" }),
  );
  const writes = [];
  await context.route(`${BASE}/__dev/local-projects/${ID}/**`, (route) => {
    const req = route.request();
    if (req.method() !== "GET" && req.method() !== "HEAD") {
      writes.push(req.url());
      return route.fulfill({ status: 405, body: '{"error":"read-only"}' });
    }
    const url = new URL(req.url());
    if (url.pathname.endsWith("/project.json")) return route.fulfill({ status: 200, headers: { "Content-Type": "application/json" }, body: DOC_TEXT });
    const ref = url.searchParams.get("ref") ?? "";
    const name = decodeURIComponent(ref).split("/").pop();
    try {
      return serveBytes(route, readFileSync(join(FIX_DIR, name)));
    } catch {
      return serveBytes(route, null);
    }
  });
  return writes;
}

// ── Browser helpers ──────────────────────────────────────────────────────

async function openEditor(browser, { init, local = false } = {}) {
  const context = await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 });
  await context.grantPermissions(["microphone"], { origin: BASE });
  // Record every AudioEncoder configuration (the take's encoder settings).
  await context.addInitScript(() => {
    window.__voEncoderConfigs = [];
    if (typeof AudioEncoder === "undefined") return;
    const configure = AudioEncoder.prototype.configure;
    AudioEncoder.prototype.configure = function (c) {
      window.__voEncoderConfigs.push({ codec: c.codec, bitrate: c.bitrate, sampleRate: c.sampleRate, numberOfChannels: c.numberOfChannels });
      return configure.call(this, c);
    };
  });
  if (init) await context.addInitScript(init);
  const cloud = makeCloud();
  const localWrites = local ? await installLocalMocks(context) : null;
  if (!local) await installMocks(context, cloud);
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  // A LOCAL project is found after the cloud lookup 404s (projectSource's fallback) — expected.
  const expected404 = (url) => local && url.startsWith(`${API}/api/cloud-projects/${ID}`);
  page.on("console", (m) => {
    if (m.type() !== "error") return;
    const url = m.location()?.url ?? "";
    if (/status of 404/.test(m.text()) && expected404(url)) return;
    errors.push(`console: ${m.text()}${url ? ` (${url})` : ""}`);
  });
  await page.goto(`${BASE}/editor-lab/open?id=${ID}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__editor?.controller?.client?.info && window.__editor?.voiceOver, null, { timeout: 90_000 });
  await page.waitForTimeout(500);
  return { context, page, cloud, errors, localWrites };
}

/** Orange-ish pixels (the voice lane's systemOrange stroke/grips) in the timeline's base canvas. */
async function voiceLaneOrange(page) {
  return page.evaluate(() => {
    const canvas = document.querySelector(".cc-tl-canvas");
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return -1;
    const dpr = canvas.width / canvas.clientWidth;
    const y0 = Math.round(80 * dpr);
    const h = Math.round(48 * dpr);
    const { data } = ctx.getImageData(0, y0, canvas.width, h);
    let n = 0;
    for (let i = 0; i < data.length; i += 4) {
      const [r, g, b, a] = [data[i], data[i + 1], data[i + 2], data[i + 3]];
      if (a > 0 && r > 170 && g > 90 && g < 190 && b < 90) n++;
    }
    return n;
  });
}

async function clickMic(page) {
  await page.locator('[title="Record Voice Over"], [title="Stop Recording"]').first().click();
}

/** Channel 0 of `file` as 48 kHz float PCM (no downmix: ffmpeg's -ac 1 scales stereo by √2). */
function decodePcm(file) {
  const out = execFileSync("ffmpeg", ["-v", "error", "-i", file, "-af", "pan=mono|c0=c0", "-f", "f32le", "-ar", "48000", "pipe:1"], { maxBuffer: 1 << 28 });
  return new Float32Array(out.buffer, out.byteOffset, Math.floor(out.byteLength / 4));
}
function rms(pcm, t0, t1) {
  const a = Math.max(0, Math.floor(t0 * 48000));
  const b = Math.min(pcm.length, Math.floor(t1 * 48000));
  if (b <= a) return 0;
  let s = 0;
  for (let i = a; i < b; i++) s += pcm[i] * pcm[i];
  return Math.sqrt(s / (b - a));
}
function probe(file) {
  const o = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", file]).toString());
  return o;
}

/** Record one take through the UI; returns the clip + the cloud state. */
async function recordTake(page, cloud, label) {
  await page.evaluate(() => window.__editor.controller.seek(1.0));
  await page.waitForTimeout(400);
  const before = await voiceLaneOrange(page);
  await clickMic(page);
  await page.waitForFunction(() => window.__editor.voiceOver.isRecording, null, { timeout: 20_000 });
  await page.waitForTimeout(700);
  const a = await page.evaluate(() => ({ live: window.__editor.voiceOver.live(window.__editor.controller.playhead.get()), t: window.__editor.controller.playhead.get() }));
  const orangeA = await voiceLaneOrange(page);
  await page.screenshot({ path: join(OUT, `${label}-recording-a.png`) });
  await page.waitForTimeout(900);
  const b = await page.evaluate(() => ({ live: window.__editor.voiceOver.live(window.__editor.controller.playhead.get()), t: window.__editor.controller.playhead.get(), samples: window.__editor.voiceOver.liveSamples.length }));
  const orangeB = await voiceLaneOrange(page);
  await page.screenshot({ path: join(OUT, `${label}-recording-b.png`) });
  const micTitle = await page.locator('[title="Stop Recording"]').count();
  check(micTitle === 1, `${label}: mic key shows "Stop Recording" while recording`);
  check(a.live && b.live && b.live.end > a.live.end + 0.5, `${label}: live block grows with the playhead`, `end ${a.live?.end?.toFixed(3)} → ${b.live?.end?.toFixed(3)}`);
  check(Math.abs((a.live?.start ?? -1) - 1.0) < 0.02, `${label}: live block starts at the playhead (1.0 s)`, `start ${a.live?.start}`);
  check(before === 0 && orangeA > 0 && orangeB > orangeA, `${label}: live block drawn and growing in the VOICE lane`, `orange px ${before} → ${orangeA} → ${orangeB}`);
  check(b.samples > 10, `${label}: meter samples accumulate`, `${b.samples}`);
  // Space → pause → the take stops (the shell's own shortcut path).
  await page.locator(".cc-tl-viewport").hover();
  await page.keyboard.press("Space");
  await page.waitForFunction(() => !window.__editor.voiceOver.isRecording, null, { timeout: 10_000 });
  await page.waitForFunction(() => window.__editor.store.getState().project.voiceOverClips.length > 0, null, { timeout: 10_000 });
  const clip = await page.evaluate(() => window.__editor.store.getState().project.voiceOverClips.at(-1));
  const playing = await page.evaluate(() => window.__editor.controller.client.transport.playing);
  check(!playing, `${label}: space paused playback and stopped the take`);
  // Upload + save.
  await page.evaluate(() => window.__editor.voiceOver.lastPersist);
  await page.waitForFunction(() => window.__editor.store.getState().sync === "saved" && !window.__editor.store.getState().dirty, null, { timeout: 20_000 });
  await page.waitForTimeout(300);
  await page.screenshot({ path: join(OUT, `${label}-committed.png`) });
  return { clip, playheadAtStop: b.t };
}

async function exportAudio(page, file) {
  const b64 = await page.evaluate(async () => {
    const r = await window.__editor.controller.client.export({ width: 640, height: 360, fps: 30 });
    const bytes = new Uint8Array(r.buffer);
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return { data: btoa(s), audio: r.audio };
  });
  writeFileSync(file, Buffer.from(b64.data, "base64"));
  return b64.audio;
}

/** The PLAYBACK mixer (engine/audio.ts's renderer) over a window, as RMS. */
async function playbackRms(page, t0, t1) {
  return page.evaluate(
    async ([a, b]) => {
      const pa = window.__editor.controller.client.audio?.pa;
      const r = pa?.renderer;
      if (!r) return -1;
      const f0 = Math.round(a * 48000);
      const n = Math.max(1, Math.round((b - a) * 48000));
      const [l] = await r.render(f0, n);
      let s = 0;
      for (let i = 0; i < l.length; i++) s += l[i] * l[i];
      return Math.sqrt(s / l.length);
    },
    [t0, t1],
  );
}

// ── Scenarios ────────────────────────────────────────────────────────────

const browser = await chromium.launch({
  channel: "chrome",
  headless: !HEADED,
  args: [
    "--autoplay-policy=no-user-gesture-required",
    "--enable-gpu",
    "--ignore-gpu-blocklist",
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
  ],
});
log(`chrome ${browser.version()} → ${BASE}`);

async function scenarioRecord(label, init) {
  log(`\n[${label}]`);
  const { context, page, cloud, errors } = await openEditor(browser, { init });
  try {
    const { clip } = await recordTake(page, cloud, label);
    const wav = label === "wav";
    const ext = wav ? "wav" : "m4a";
    const type = wav ? "audio/wav" : "audio/mp4";
    check(new RegExp(`^voiceover-[0-9A-F-]{36}\\.${ext}$`).test(clip.fileName), `${label}: file name voiceover-<UUID>.${ext}`, clip.fileName);
    check(Math.abs(clip.startTime - 1.0) < 0.02, `${label}: clip starts at the playhead`, `${clip.startTime}`);
    check(clip.sourceStartTime === 0 && clip.gain === 1 && clip.label === "Voice Over" && clip.sourceDuration >= clip.duration, `${label}: Mac VoiceOverClip defaults`, JSON.stringify(clip));
    check(clip.duration > 1.2 && clip.duration < 3.5, `${label}: clip duration ≈ the take`, `${clip.duration.toFixed(3)} s`);
    check(Object.keys(clip).sort().join(",") === "duration,fileName,gain,id,label,sourceDuration,sourceStartTime,startTime", `${label}: exactly the Mac's keys (no waveform)`);

    // Cloud: stage (full manifest) → put → finalize → save, in that order.
    const ev = cloud.state.events;
    const stage = ev.find((e) => e.kind === "stage");
    const put = ev.find((e) => e.kind === "put");
    const iStage = ev.indexOf(stage);
    const iPut = ev.indexOf(put);
    const iFinal = ev.findIndex((e) => e.kind === "finalize");
    const iSaveWithClip = ev.findIndex((e, i) => e.kind === "save" && JSON.parse(cloud.state.saves[ev.slice(0, i + 1).filter((x) => x.kind === "save").length - 1]).voiceOverClips?.some((c) => c.id === clip.id));
    check(stage && stage.files.includes("recording.mp4") && stage.files.includes("cursor.json") && stage.files.includes(clip.fileName) && stage.files.length === 3, `${label}: stage carries the full manifest + the take`, JSON.stringify(stage?.files));
    check(put && put.contentType === type, `${label}: uploaded as ${type}`, `${put?.bytes} bytes`);
    check(iStage >= 0 && iStage < iPut && iPut < iFinal && iFinal < iSaveWithClip, `${label}: order stage → PUT → finalize → project save`, ev.map((e) => e.kind).join(" → "));
    const saved = JSON.parse(cloud.state.document);
    check(saved.voiceOverClips?.length === 1 && saved.voiceOverClips[0].fileName === clip.fileName, `${label}: saved project.json has the clip (syncs to the Mac)`);

    // The recorded file itself.
    const bytes = cloud.state.objects.get(put.sha256);
    const recFile = join(OUT, `${label}-${clip.fileName}`);
    writeFileSync(recFile, bytes);
    const pr = probe(recFile);
    const st = pr.streams[0];
    if (wav) {
      check(st.codec_name === "pcm_s16le" && st.channels === 1 && Number(st.sample_rate) === 48000, `${label}: file is PCM s16 / mono / 48 kHz`, `${st.codec_name} ${st.channels}ch ${st.sample_rate}`);
    } else {
      check(st.codec_name === "aac" && st.profile === "LC" && st.channels === 1 && Number(st.sample_rate) === 48000, `${label}: file is AAC-LC / mono / 48 kHz`, `${st.codec_name} ${st.profile} ${st.channels}ch ${st.sample_rate} ${st.bit_rate} bps`);
      // The encoder is configured at the Mac's rate; the file's average is lower
      // over the fake mic's mostly-silent beeps (AAC spends ~nothing on silence).
      const cfg = await page.evaluate(() => window.__voEncoderConfigs.find((c) => c.numberOfChannels === 1));
      check(cfg?.codec?.startsWith("mp4a.40.2") && cfg.bitrate === 192_000 && cfg.sampleRate === 48_000, `${label}: AudioEncoder configured AAC-LC 192 kbps / 48 kHz / mono`, JSON.stringify(cfg));
    }
    try {
      const af = execFileSync("afinfo", [recFile]).toString();
      const dur = Number(/estimated duration: ([\d.]+)/.exec(af)?.[1] ?? NaN);
      check(Math.abs(dur - clip.sourceDuration) < 0.05, `${label}: macOS AudioToolbox (afinfo) reads it; duration matches the clip`, `${dur} s vs ${clip.sourceDuration.toFixed(3)} s`);
      writeFileSync(join(OUT, `${label}-afinfo.txt`), af);
    } catch (e) {
      check(false, `${label}: afinfo`, String(e));
    }
    const pcm = decodePcm(recFile);
    check(rms(pcm, 0, pcm.length / 48000) > 0.003, `${label}: the take is not silent`, `rms ${rms(pcm, 0, pcm.length / 48000).toFixed(4)}`);

    // Undo / redo.
    await page.keyboard.press("Meta+z");
    let n = await page.evaluate(() => window.__editor.store.getState().project.voiceOverClips.length);
    const undoOk = n === 0;
    await page.keyboard.press("Meta+Shift+z");
    n = await page.evaluate(() => window.__editor.store.getState().project.voiceOverClips.length);
    check(undoOk && n === 1, `${label}: ⌘Z removes the clip, ⇧⌘Z restores it`);
    await page.waitForFunction(() => window.__editor.store.getState().sync === "saved" && !window.__editor.store.getState().dirty, null, { timeout: 20_000 });

    // Preview playback mix: the SAME renderer the speakers get.
    await page.waitForFunction((name) => window.__editor.controller.client.audioPlan?.voiceOvers?.some((v) => v.fileName === name), clip.fileName, { timeout: 10_000 });
    const s0 = clip.startTime;
    const s1 = clip.startTime + clip.duration;
    const inside = await playbackRms(page, s0 + 0.1, s1 - 0.1);
    const outside = await playbackRms(page, 0, Math.max(0.05, s0 - 0.05));
    check(inside > 0.003 && outside < 1e-4, `${label}: preview mix — sound inside the clip, silence before it`, `inside ${inside.toFixed(4)}, before ${outside.toExponential(2)}`);
    // …and it actually plays: start playback over the clip and let the scheduler run.
    const chunks0 = await page.evaluate(() => window.__editor.controller.client.audioStats?.chunks ?? 0);
    await page.evaluate((t) => window.__editor.controller.seek(t), s0);
    await page.waitForTimeout(300);
    await page.evaluate(() => window.__editor.controller.togglePlay());
    await page.waitForTimeout(1200);
    await page.screenshot({ path: join(OUT, `${label}-playback.png`) });
    await page.evaluate(() => window.__editor.controller.pause());
    const chunks1 = await page.evaluate(() => window.__editor.controller.client.audioStats?.chunks ?? 0);
    check(chunks1 > chunks0 + 5, `${label}: playback scheduled audio over the clip`, `${chunks1 - chunks0} chunks`);

    // Export: decode the exported file's audio with ffmpeg.
    const exp = join(OUT, `${label}-export.mp4`);
    const audioInfo = await exportAudio(page, exp);
    check(audioInfo !== null, `${label}: export has an audio track`, JSON.stringify(audioInfo));
    const epcm = decodePcm(exp);
    const eIn = rms(epcm, s0 + 0.1, s1 - 0.1);
    const eBefore = rms(epcm, 0, Math.max(0.05, s0 - 0.05));
    const eAfter = rms(epcm, s1 + 0.1, Math.max(s1 + 0.2, epcm.length / 48000));
    check(eIn > 0.003 && eBefore < 1e-3 && eAfter < 1e-3, `${label}: exported audio is non-silent in the clip window only`, `in ${eIn.toFixed(4)}, before ${eBefore.toExponential(2)}, after ${eAfter.toExponential(2)}`);
    // Preview == export for sound: the export's window matches the playback mixer's.
    const ratio = eIn / Math.max(1e-9, inside);
    check(ratio > 0.8 && ratio < 1.25, `${label}: export level ≈ preview level`, `ratio ${ratio.toFixed(3)}`);
    check(errors.length === 0, `${label}: no page errors`, errors.slice(0, 3).join(" | "));
  } finally {
    await context.close();
  }
}

/** Mic key again while playing: the take stops, playback keeps going (resumePlayback: isPlaying). */
async function scenarioMicKeyStop(label) {
  log(`\n[${label}]`);
  const { context, page, errors } = await openEditor(browser);
  try {
    await page.evaluate(() => window.__editor.controller.seek(0.5));
    await page.waitForTimeout(300);
    await clickMic(page);
    await page.waitForFunction(() => window.__editor.voiceOver.isRecording, null, { timeout: 20_000 });
    await page.waitForTimeout(1000);
    await clickMic(page);
    await page.waitForFunction(() => !window.__editor.voiceOver.isRecording, null, { timeout: 10_000 });
    const playing = await page.evaluate(() => window.__editor.controller.client.transport.playing);
    check(playing, `${label}: playback continues after the mic key stops the take`);
    await page.waitForFunction(() => window.__editor.store.getState().project.voiceOverClips.length === 1, null, { timeout: 10_000 });
    const loop = await page.evaluate(() => window.__editor.controller.client.transport.loop);
    check(loop === true, `${label}: the editor's looping is restored`);
    const clip = await page.evaluate(() => window.__editor.store.getState().project.voiceOverClips[0]);
    check(Math.abs(clip.startTime - 0.5) < 0.02 && clip.duration > 0.7 && clip.duration < 1.6, `${label}: clip at 0.5 s, ≈ 1 s long`, `${clip.startTime} + ${clip.duration.toFixed(3)}`);
    await page.evaluate(() => window.__editor.controller.pause());
    await page.evaluate(() => window.__editor.voiceOver.lastPersist);
    check(errors.length === 0, `${label}: no page errors`, errors.slice(0, 3).join(" | "));
  } finally {
    await context.close();
  }
}

/** The take runs to the end of the timeline: it stops there, the playhead returns to the start. */
async function scenarioEnd(label) {
  log(`\n[${label}]`);
  const { context, page, errors } = await openEditor(browser);
  try {
    await page.evaluate(() => window.__editor.controller.seek(2.8));
    await page.waitForTimeout(300);
    await clickMic(page);
    await page.waitForFunction(() => window.__editor.voiceOver.isRecording, null, { timeout: 20_000 });
    await page.waitForFunction(() => !window.__editor.voiceOver.isRecording, null, { timeout: 10_000 });
    await page.waitForFunction(() => window.__editor.store.getState().project.voiceOverClips.length === 1, null, { timeout: 10_000 });
    await page.waitForTimeout(300);
    const s = await page.evaluate(() => ({
      clip: window.__editor.store.getState().project.voiceOverClips[0],
      playing: window.__editor.controller.client.transport.playing,
      loop: window.__editor.controller.client.transport.loop,
      playhead: window.__editor.controller.playhead.get(),
    }));
    await page.screenshot({ path: join(OUT, `${label}-stopped.png`) });
    check(!s.playing, `${label}: playback stopped at the end (no loop while recording)`);
    check(s.playhead === 0, `${label}: playhead back at the trim start`, `${s.playhead}`);
    check(s.loop === true, `${label}: looping restored`);
    // min(file, max(0.1, duration 4 − start 2.8)) ≤ 1.2
    check(Math.abs(s.clip.startTime - 2.8) < 0.02 && s.clip.duration <= 1.2 + 1e-9 && s.clip.duration > 1.0, `${label}: clip spans to the end`, `${s.clip.startTime} + ${s.clip.duration.toFixed(3)}`);
    await page.evaluate(() => window.__editor.voiceOver.lastPersist);
    check(errors.length === 0, `${label}: no page errors`, errors.slice(0, 3).join(" | "));
  } finally {
    await context.close();
  }
}

/** A LOCAL (dev server, read-only) project: the take lives in the tab — it plays, nothing is written. */
async function scenarioLocal(label) {
  log(`\n[${label}]`);
  const { context, page, errors, localWrites } = await openEditor(browser, { local: true });
  try {
    const origin = await page.evaluate(() => window.__editor.store.getState().origin);
    check(origin === "local", `${label}: opened the dev server's local project`, origin);
    await page.evaluate(() => window.__editor.controller.seek(1.0));
    await page.waitForTimeout(300);
    await clickMic(page);
    await page.waitForFunction(() => window.__editor.voiceOver.isRecording, null, { timeout: 20_000 });
    await page.waitForTimeout(1200);
    await page.evaluate(() => window.__editor.controller.togglePlay());
    await page.waitForFunction(() => window.__editor.store.getState().project.voiceOverClips.length === 1, null, { timeout: 10_000 });
    const clip = await page.evaluate(() => window.__editor.store.getState().project.voiceOverClips[0]);
    await page.waitForFunction((name) => window.__editor.controller.client.audioPlan?.voiceOvers?.some((v) => v.fileName === name), clip.fileName, { timeout: 10_000 });
    const inside = await playbackRms(page, clip.startTime + 0.1, clip.startTime + clip.duration - 0.1);
    check(inside > 0.003, `${label}: the take plays from the tab`, `rms ${inside.toFixed(4)}`);
    const sync = await page.evaluate(() => window.__editor.store.getState().sync);
    check(sync === "local" && localWrites.length === 0, `${label}: nothing written to the Mac's folder (read-only, edits live in the tab)`, `sync=${sync}, writes=${localWrites.length}`);
    await page.screenshot({ path: join(OUT, `${label}-committed.png`) });
    check(errors.length === 0, `${label}: no page errors`, errors.slice(0, 3).join(" | "));
  } finally {
    await context.close();
  }
}

async function scenarioDenied(label, errorName, expected) {
  log(`\n[${label}]`);
  const init = `(() => {
    const gum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = (c) => c && c.audio && !c.video ? Promise.reject(new DOMException("mock", ${JSON.stringify(errorName)})) : gum(c);
  })();`;
  const { context, page, cloud, errors } = await openEditor(browser, { init });
  try {
    await clickMic(page);
    await page.waitForSelector(".cc-alert [role=alertdialog]", { timeout: 10_000 });
    await page.waitForTimeout(400);
    const text = await page.locator(".cc-alert [role=alertdialog]").innerText();
    await page.screenshot({ path: join(OUT, `${label}-alert.png`) });
    check(text.includes("Voice Over") && text.includes(expected) && text.includes("OK"), `${label}: house alert with the Mac's copy`, JSON.stringify(text));
    const rec = await page.evaluate(() => window.__editor.voiceOver.isRecording || window.__editor.controller.client.transport.playing);
    check(!rec, `${label}: nothing records or plays`);
    await page.keyboard.press("Enter");
    await page.waitForSelector(".cc-alert", { state: "detached", timeout: 5_000 });
    check(true, `${label}: Return dismisses the alert`);
    check(cloud.state.events.length === 0, `${label}: nothing uploaded`);
    check(errors.length === 0, `${label}: no page errors`, errors.slice(0, 3).join(" | "));
  } finally {
    await context.close();
  }
}

try {
  if (ONLY.has("record")) await scenarioRecord("record");
  if (ONLY.has("wav")) await scenarioRecord("wav", "globalThis.__ccVoiceOverCodec = 'pcm-s16';");
  if (ONLY.has("mickey")) await scenarioMicKeyStop("mickey");
  if (ONLY.has("end")) await scenarioEnd("end");
  if (ONLY.has("local")) await scenarioLocal("local");
  if (ONLY.has("denied")) await scenarioDenied("denied", "NotAllowedError", "Microphone access is required to record a voice over.");
  if (ONLY.has("missing")) await scenarioDenied("missing", "NotFoundError", "Unable to start voice-over recording.");
} catch (e) {
  failures.push(`harness: ${e?.stack ?? e}`);
  console.error(e);
} finally {
  await browser.close();
}

log(`\n${failures.length === 0 ? "PASS" : `FAIL (${failures.length})`} — artifacts in ${OUT}`);
if (failures.length) {
  for (const f of failures) log(`  - ${f}`);
  process.exit(1);
}
