#!/usr/bin/env node
// CaptureCat's App Store app previews, cut from the simulator takes that
// record-tour.sh makes (-uiStoreTour, App/Fixtures/StoreCreative.swift).
// Adapted from the Strobia pipeline (Strobia/apps/ios/scripts/app-preview),
// which passed App Review after its v1 was rejected under guideline 2.3.4
// for drawing a phone round the footage and ending on a logo. So here too:
//
//   - the real app footage fills the frame: no device frame, no logo, no
//     end card; the last frame is the app;
//   - a virtual camera makes one eased move per idea, and every cut is
//     hidden inside a move or a quick punch-in, with motion blur
//     (subframes blended at 60 fps);
//   - one short headline per idea, in the house style (ink + violet-to-blue),
//     from copy.json, localized: every locale gets its own file;
//   - the synth soundtrack (soundtrack.py, from Strobia's promo) scored to
//     the take's own moments; stereo AAC;
//   - 30 fps output from the 60 fps master (pairs of frames blended),
//     H.264 High 4.0.
//
// Two passes, so twelve locales don't cost twelve full renders: the
// footage + camera + taps once per device (base, lossless 60 fps), then the
// localized headlines per locale on a transparent page, overlaid on it.
//
//   node render.mjs --device iphone|ipad [--locales en-GB,ja] [--at 3,9.5]
//
// Writes out/<locale>/app-preview/{iphone-6.9,ipad-13}.mp4 and
// source/build/preview/<device>/textfit.json (per-locale headline fit).
// Needs ffmpeg, python3 + numpy + Pillow, Playwright (PLAYWRIGHT env or the npx cache).
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.resolve(here, '..');
const ROOT = path.resolve(SRC, '..');
const FPS = 60, SUB = 6, SHUTTER = 0.5, SOURCE_FPS = 120, BPM = 100, LEAD = 1.9;
const WORKERS = Number(process.env.WORKERS ?? 6);

const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const DEVICE = arg('--device', 'iphone');
const stills = arg('--at', null)?.split(',').map(Number) ?? null;
const COPY = JSON.parse(fs.readFileSync(path.join(SRC, 'copy.json'), 'utf8'));
// One locale per run: every locale has its own take (the app runs in that language).
const LOCALE = arg('--locale', 'en-GB');
const LOCALES = [LOCALE];

const DEVICES = {
  // Output size (Apple's app-preview resolutions), the take's size, the size
  // frames are kept at for the camera, the headline's place and size.
  iphone: { width: 886, height: 1920, take: [1320, 2868], work: [1080, 2346], file: 'iphone-6.9.mp4', unmask: true,
            captionTop: 66, captionSize: 60, scrimHeight: 330 },
  ipad: { width: 1200, height: 1600, take: [2064, 2752], work: [1500, 2000], file: 'ipad-13.mp4', unmask: true,
          captionTop: 46, captionSize: 62, scrimHeight: 270 },
};
const dev = DEVICES[DEVICE];
const work = path.join(SRC, 'build', 'preview', DEVICE, LOCALE);
const frames = path.join(work, 'frames');
fs.mkdirSync(work, { recursive: true });

// The take and its step log (record-tour.sh: step times from the app's launch;
// the recording starts LEAD seconds earlier).
const take = path.join(SRC, 'footage', LOCALE, `${DEVICE}-tour.mov`);
const step = {};
for (const line of fs.readFileSync(path.join(SRC, 'footage', LOCALE, `${DEVICE}-tour.steps.txt`), 'utf8').split('\n')) {
  const m = line.match(/^([\d.]+) .*STORETOUR (\S+)/);
  if (m && !(m[2] in step)) step[m[2]] = Number(m[1]) + LEAD;
}

// ---------------------------------------------------------------- helpers
// Every child is tracked: if anything fails, all of them are killed and the
// process exits non-zero. (A feeder that threw used to leave its ffmpeg
// waiting on stdin, and the other workers' pipes kept node alive: a hang.)
const children = new Set();
function killAll() { for (const c of children) { try { c.kill('SIGKILL'); } catch {} } }
function die(error) { console.error(`render.mjs failed: ${error?.stack ?? error}`); killAll(); process.exit(1); }
process.on('unhandledRejection', die);
process.on('uncaughtException', die);
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { killAll(); process.exit(1); });

function run(command, commandArgs, feed) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, { stdio: [feed ? 'pipe' : 'ignore', 'inherit', 'inherit'] });
    children.add(child);
    child.on('error', reject);
    child.on('exit', (code) => { children.delete(child); code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`)); });
    if (feed) feed(child.stdin).catch((error) => { child.kill('SIGKILL'); reject(error); });
  });
}
/** A promise that fails if it takes longer than ms (a stuck page or decode). */
function within(ms, promise, what) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timed out: ${what}`)), ms); })])
    .finally(() => clearTimeout(timer));
}
async function write(stream, buffer) {
  if (!stream.write(buffer)) await new Promise((resolve) => stream.once('drain', resolve));
}
const fresh = (file, ...deps) => fs.existsSync(file) && deps.every((d) => fs.statSync(file).mtimeMs >= fs.statSync(d).mtimeMs);

// 1. Frames: the variable-rate take resampled to a constant 120 fps by
// holding each recorded frame until the next (the simulator only sends a
// frame when the screen changes, so blending neighbours, as Strobia's takes
// allowed, would dissolve across every still stretch), cut per shot, and the
// screen mask (--mask=black: rounded corners, Dynamic Island) painted out.
const steady = path.join(work, `take-${SOURCE_FPS}fps.mp4`);
if (!fresh(steady, take)) {
  await run('ffmpeg', ['-v', 'error', '-y', '-i', take,
    '-vf', `fps=${SOURCE_FPS},scale=${dev.work[0]}:${dev.work[1]}:flags=lanczos`,
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '14', '-g', '30', '-pix_fmt', 'yuv420p', '-an', steady]);
}

// The moments after the export, read off the footage: the simulator's
// recorder loses time while the export keeps the Mac busy, so the step log
// drifts there. Scene changes in the middle of the screen, sampled at 20 fps:
// the first big one after the export starts is the sheet finishing (the
// share sheet follows at once); the last one is the share page settling.
async function sceneChanges(file, from) {
  const child = spawn('ffmpeg', ['-v', 'info', '-ss', String(from), '-i', file, '-vf',
    'fps=20,crop=iw*0.6:ih*0.5:iw*0.2:ih*0.3,scale=1:1,showinfo', '-f', 'null', '-'], { stdio: ['ignore', 'ignore', 'pipe'] });
  let err = '';
  child.stderr.on('data', (d) => { err += d; });
  await new Promise((resolve) => child.on('exit', resolve));
  const rows = [...err.matchAll(/pts_time:([\d.]+).*?mean:\[(\d+) (\d+) (\d+)\]/g)].map((m) => ({ t: from + Number(m[1]), m: [Number(m[2]), Number(m[3]), Number(m[4])] }));
  const out = [];
  for (let i = 1; i < rows.length; i++) {
    const d = rows[i].m.reduce((a, v, k) => a + Math.abs(v - rows[i - 1].m[k]), 0);
    if (d > 3) out.push({ t: rows[i].t, d });
  }
  return { changes: out, end: rows.length ? rows[rows.length - 1].t : from };
}
const late = {};
{
  const { changes, end } = await sceneChanges(steady, step.exporting + 2.0);
  const done = changes.find((c) => c.d > 6);
  const settle = changes.length ? changes[changes.length - 1].t : end - 3.5;
  if (done) late[7] = done.t - 1.4;
  late[8] = Math.min(settle + 0.4, end - 3.3);
  console.log(`late shots from the footage: export done ${done?.t.toFixed(2)}, share page settled ${settle.toFixed(2)} (take ends ${end.toFixed(2)})`);
}
// ---------------------------------------------------------------- the cut
// Each shot plays [from, to] seconds of the take in real time; shots start
// after the simulator's own transitions finish (it renders them at a low
// rate), and the camera, rendered at 60 fps, carries the motion between them.
const SHOTS = [
  { key: 'library', from: step.library + 1.2, len: 2.3 },              // the library
  { key: 'library', from: step.project + 0.55, len: 1.5 },             // a project opens
  { key: 'editor', from: step.editor + 0.75, len: 4.45 },              // the editor; the timeline zooms; the zoom block
  { key: 'editor', from: step.play + 0.05, len: 4.3 },                 // it plays: the stage zooms, captions on it
  { key: 'background', from: step.background + 0.5, len: 3.9 },        // the Background pane; Mesh
  { key: 'captions', from: step.subtitles + 0.75, len: 2.4 },          // the Subtitles pane
  { key: 'share', from: step.export + 0.55, len: 1.6 },                // Export
  { key: 'share', from: step.exported - 1.4, len: 4.0 },               // the export finishing; the share sheet rises
  { key: 'share', from: step['share-detail'] + (DEVICE === 'iphone' ? 1.5 : 1.3), len: 3.2 }, // the share link and its comments
];
// The simulator's recorder loses time while the export keeps the Mac busy,
// so after it the step log drifts from the footage: footage/<device>-tour.cuts.json
// gives those shots' starts read off the footage itself (seconds in the take).
// footage/<locale>/<device>-tour.cuts.json, when present, overrides the detected starts.
const cutsFile = path.join(SRC, 'footage', LOCALE, `${DEVICE}-tour.cuts.json`);
Object.assign(late, fs.existsSync(cutsFile) ? JSON.parse(fs.readFileSync(cutsFile, 'utf8')).late ?? {} : {});
SHOTS.forEach((shot, i) => { if (late[i] !== undefined) shot.from = late[i]; });
let at = 0;
const SEGMENTS = SHOTS.map((s) => {
  const seg = { take: 1, from: s.from, to: s.from + s.len, start: at, end: at + s.len, fade: 0, speed: 1, key: s.key };
  at += s.len;
  return seg;
});
const duration = at;
const cut = (i) => SEGMENTS[i].start;
const src = (i, t) => SEGMENTS[i].start + (t - SEGMENTS[i].from);   // a take moment, in output time

// The camera (see index.html): zoom s, the point looked at (fx, fy as
// fractions of the screen) and where it sits in the frame (ax, ay, px).
// Positions are the app's own layout, read off the takes.
const L = DEVICE === 'iphone'
  ? { grid: [0.5, 0.42], player: [0.5, 0.2], stage: [0.5, 0.28], block: [0.86, 0.67], colour: [0.92, 0.8],
      pane: [0.5, 0.78], sheet: [0.5, 0.74], shareSheet: [0.5, 0.74], detail: [0.5, 0.45], exportButton: [0.5, 0.88], sheetS: 1.06 }
  : { grid: [0.3, 0.42], player: [0.72, 0.2], stage: [0.37, 0.2], block: [0.55, 0.49], colour: [0.95, 0.2],
      pane: [0.82, 0.3], sheet: [0.5, 0.48], shareSheet: [0.5, 0.48], detail: [0.72, 0.45], exportButton: [0.5, 0.62], sheetS: 1.4 };
const W = dev.width, H = dev.height;
const pos = (p, s, ay) => ({ s, fx: p[0], fy: p[1], ax: W * 0.5, ay: H * ay });
const CAMERA = {
  start: pos(L.grid, 1.12, 0.5),
  moves: [
    { t: 0, dur: 2.0, to: { s: 1.0 } },                                              // the library, settling
    { t: cut(1) - 0.3, dur: 0.3, ease: 'in', to: { s: 1.3 } },                       // punch through to the project
    { t: cut(1), jump: true, to: pos(L.player, 1.35, 0.42) },
    { t: cut(1), dur: 0.6, ease: 'out', to: { s: 1.12 } },
    { t: cut(2) - 0.25, dur: 0.25, ease: 'in', to: { s: 1.34 } },                    // into the editor
    { t: cut(2), jump: true, to: pos(L.stage, 1.2, 0.4) },
    { t: cut(2), dur: 0.6, ease: 'out', to: { s: 1.0 } },
    { t: src(2, step['select-zoom']) - 0.5, dur: 0.8, to: pos(L.block, 1.55, 0.55) }, // punch into the zoom block
    { t: cut(3) - 0.25, dur: 0.25, ease: 'in', to: { s: 1.75 } },
    { t: cut(3), jump: true, to: pos(L.stage, 1.3, 0.36) },                           // the stage, zooming as it plays
    { t: cut(3), dur: 0.6, ease: 'out', to: { s: 1.08 } },
    { t: cut(3) + 1.0, dur: 3.0, to: { s: 1.03 } },
    { t: cut(4) - 0.28, dur: 0.28, ease: 'in', to: { s: 1.5 } },
    { t: cut(4), jump: true, to: pos(L.pane, 1.3, 0.62) },                           // the Background pane
    { t: cut(4), dur: 0.6, ease: 'out', to: { s: 1.06 } },
    { t: src(4, step.mesh) - 0.35, dur: 0.7, to: pos(L.stage, 1.04, 0.4) },          // new colours: watch the stage change
    { t: cut(5) - 0.25, dur: 0.25, ease: 'in', to: { s: 1.4 } },
    { t: cut(5), jump: true, to: pos(L.pane, 1.25, 0.62) },                          // the Subtitles pane
    { t: cut(5), dur: 0.6, ease: 'out', to: { s: 1.04 } },
    { t: cut(6) - 0.25, dur: 0.25, ease: 'in', to: { s: 1.32 } },
    { t: cut(6), jump: true, to: pos(L.sheet, L.sheetS + 0.2, 0.6) },                // Export
    { t: cut(6), dur: 0.5, ease: 'out', to: { s: L.sheetS } },
    { t: cut(7) - 0.2, dur: 0.2, ease: 'in', to: { s: 1.2 } },
    { t: cut(7), jump: true, to: pos(L.sheet, L.sheetS + 0.12, 0.62) },              // the export finishing
    { t: cut(7), dur: 0.5, ease: 'out', to: { s: L.sheetS } },
    { t: cut(7) + 1.5, dur: 1.2, to: pos(L.shareSheet, L.sheetS - 0.04, 0.6) },    // the share sheet rising
    { t: cut(8) - 0.25, dur: 0.25, ease: 'in', to: { s: 1.3 } },
    { t: cut(8), jump: true, to: pos(L.detail, 1.22, 0.5) },                         // the share link and comments
    { t: cut(8), dur: 0.7, ease: 'out', to: { s: 1.02 } },
  ],
};

// Where the finger would touch for the scripted actions (fractions of the screen).
const TAPS = [
  { t: src(2, step['select-zoom']) - 0.05, x: L.block[0], y: L.block[1] },
  { t: src(4, step.mesh) - 0.05, x: L.colour[0], y: L.colour[1] },
  { t: cut(6) + 1.3, x: L.exportButton[0], y: L.exportButton[1] },
].filter((tap) => tap.t > 0 && tap.t < duration);

// One headline per idea (copy.json keys), in at the idea's first shot.
function captionsFor(locale) {
  const order = [];
  SEGMENTS.forEach((s) => { if (!order.length || order[order.length - 1].key !== s.key) order.push({ key: s.key, in: s.start }); });
  return order.map((c, i) => ({ lines: COPY[locale][c.key], key: c.key, in: c.in + (i === 0 ? 0.25 : 0.15),
                                out: i + 1 < order.length ? order[i + 1].in - 0.05 : duration + 1 }));
}

// Sound cues on the take's own moments and on the cut.
const events = [
  ...TAPS.map((tap) => ({ t: tap.t, kind: 'tap' })),
  { t: src(2, step['timeline-zoom']), kind: 'tick' },
  { t: src(4, step.mesh), kind: 'morph' },
  { t: cut(7) + 1.4, kind: 'ready' },
  ...SEGMENTS.slice(1).map((s) => ({ t: s.start - 0.15, kind: s.key === SEGMENTS[SEGMENTS.indexOf(s) - 1].key ? 'swish' : 'whoosh' })),
  { t: 0.05, kind: 'bell' },
  { t: cut(8) + 0.1, kind: 'session' },   // the share page: the pulse rests, the chord resolves
].sort((p, q) => p.t - q.t);

const planHash = crypto.createHash('sha1').update(JSON.stringify({ SEGMENTS, dev })).digest('hex').slice(0, 12);
const stamp = path.join(frames, `.plan-${planHash}`);
if (!fs.existsSync(stamp) || !fresh(stamp, steady)) {
  fs.rmSync(frames, { recursive: true, force: true });
  fs.mkdirSync(frames, { recursive: true });
  for (const s of SEGMENTS) {
    await run('ffmpeg', ['-v', 'error', '-y', '-ss', String(s.from), '-i', steady, '-t', String(s.to - s.from + 0.05),
      '-q:v', '3', '-start_number', String(Math.round(s.from * SOURCE_FPS)), path.join(frames, `t1_%06d.jpg`)]);
  }
  if (dev.unmask) {
    // The mask's shape, from a light screen (the library): only the mask is black there.
    const reference = path.join(work, 'mask-reference.png');
    await run('ffmpeg', ['-v', 'error', '-y', '-ss', String(step.library + 1.4), '-i', steady, '-frames:v', '1', reference]);
    await run('python3', [path.join(here, 'unmask.py'), reference, frames]);
  }
  fs.writeFileSync(stamp, '');
}

// 2. The page, and a way to photograph any moment.
const playwrightPath = process.env.PLAYWRIGHT ?? path.join(os.homedir(), '.npm/_npx/705bc6b22212b352/node_modules/playwright/index.mjs');
const { chromium } = await import(fs.existsSync(playwrightPath) ? pathToFileURL(playwrightPath).href : 'playwright');
async function openScene(mode, locale = 'en-GB') {
  const browser = await chromium.launch({ channel: 'chrome' });
  process.on('exit', () => { try { browser.process()?.kill('SIGKILL'); } catch {} });
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  page.on('pageerror', (error) => console.error('page error:', error.message));
  await page.goto(pathToFileURL(path.join(here, 'index.html')).href);
  await page.waitForFunction(() => window.READY === true);
  const fits = await page.evaluate((plan) => window.setup(plan), {
    mode, lang: locale, width: W, height: H, sourceAspect: dev.take[1] / dev.take[0],
    captionTop: dev.captionTop, captionSize: dev.captionSize, scrimHeight: dev.scrimHeight,
    frames: pathToFileURL(frames).href, fps: SOURCE_FPS,
    segments: SEGMENTS, camera: CAMERA, taps: TAPS, captions: captionsFor(locale),
  });
  const cdp = await page.context().newCDPSession(page);
  if (mode === 'captions') await cdp.send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  const shot = async (t) => {
    await within(30000, page.evaluate((time) => window.seek(time), t), `seek ${t.toFixed(3)} s`);
    const { data } = await within(30000, cdp.send('Page.captureScreenshot', { format: 'png', optimizeForSpeed: true }), `screenshot ${t.toFixed(3)} s`);
    return Buffer.from(data, 'base64');
  };
  return { browser, shot, fits };
}

if (stills) {
  const dir = path.join(work, 'stills');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const scene = await openScene('all', LOCALES[0]);
  for (const [i, t] of stills.entries()) fs.writeFileSync(path.join(dir, `${String(i).padStart(2, '0')}_${t}.png`), await scene.shot(t));
  await scene.browser.close();
  console.log(`${stills.length} stills in ${path.relative(ROOT, dir)} (preview runs ${duration.toFixed(2)} s)`);
  process.exit(0);
}

// 3. The sound, scored to the cut.
const cues = path.join(work, 'events.json');
fs.writeFileSync(cues, JSON.stringify({ duration, bpm: BPM, loop: false, intro_bars: 1, music: 0.7, sfx: 2.2, events }, null, 1));
const sound = path.join(work, 'soundtrack.wav');
await run('python3', [path.join(here, 'soundtrack.py'), cues, sound]);

// 4. The base: footage, camera and taps at 60 fps, subframes blended for
// motion blur, rendered in stretches side by side. Lossless; kept between runs.
const total = Math.round(duration * FPS);
const base = path.join(work, `base-${planHash}.mkv`);
const started = Date.now();
if (!fresh(base, stamp, path.join(here, 'index.html'), fileURLToPath(import.meta.url))) {
  const per = Math.ceil(total / WORKERS);
  const done = new Array(WORKERS).fill(0);
  const pieces = await Promise.all(Array.from({ length: WORKERS }, async (_, w) => {
    const from = w * per, to = Math.min(total, from + per);
    const piece = path.join(work, `piece-${w}.mkv`);
    const scene = await openScene('base');
    await run('ffmpeg', [
      '-v', 'error', '-y', '-f', 'image2pipe', '-framerate', String(FPS * SUB), '-c:v', 'png', '-i', '-',
      '-vf', `tmix=frames=${SUB},select='eq(mod(n\\,${SUB})\\,${SUB - 1})',setpts=N/(${FPS}*TB)`,
      '-r', String(FPS), '-c:v', 'libx264rgb', '-qp', '0', '-preset', 'ultrafast', piece,
    ], async (stdin) => {
      for (let f = from; f < to; f++) {
        for (let s = 0; s < SUB; s++) await write(stdin, await scene.shot((f + (s / SUB) * SHUTTER) / FPS));
        done[w]++;
        if (w === 0) process.stdout.write(`\rbase ${DEVICE}: ${done.reduce((a, c) => a + c, 0)}/${total} frames  ${((Date.now() - started) / 1000).toFixed(0)} s `);
      }
      stdin.end();
    });
    await scene.browser.close();
    return piece;
  }));
  process.stdout.write('\n');
  const list = path.join(work, 'pieces.txt');
  fs.writeFileSync(list, pieces.map((piece) => `file '${piece}'`).join('\n'));
  for (const old of fs.readdirSync(work).filter((f) => f.startsWith('base-'))) fs.rmSync(path.join(work, old));
  await run('ffmpeg', ['-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', base]);
  pieces.forEach((piece) => fs.rmSync(piece));
  fs.rmSync(list);
}

// 5. Per locale: the headlines on a transparent page at 60 fps, laid over
// the base; then Apple's 30 fps, each frame two master frames blended.
const fitPath = path.join(work, 'textfit.json');
const fitAll = fs.existsSync(fitPath) ? JSON.parse(fs.readFileSync(fitPath, 'utf8')) : {};
const color = ['-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709'];
const audio = ['-c:a', 'aac', '-b:a', '256k', '-ar', '48000', '-ac', '2', '-shortest', '-movflags', '+faststart'];
for (const locale of LOCALES) {
  const capDir = path.join(work, `captions-${locale}`);
  fs.rmSync(capDir, { recursive: true, force: true });
  fs.mkdirSync(capDir, { recursive: true });
  const CAP_WORKERS = 4, per = Math.ceil(total / CAP_WORKERS);
  let fits;
  await Promise.all(Array.from({ length: CAP_WORKERS }, async (_, w) => {
    const scene = await openScene('captions', locale);
    if (w === 0) fits = scene.fits;
    for (let f = w * per; f < Math.min(total, (w + 1) * per); f++) {
      fs.writeFileSync(path.join(capDir, `c_${String(f).padStart(5, '0')}.png`), await scene.shot(f / FPS));
    }
    await scene.browser.close();
  }));
  fitAll[locale] = { device: DEVICE, width: W, height: H, scrimHeight: dev.scrimHeight, captions: fits };
  const dest = path.join(ROOT, 'out', locale, 'app-preview', dev.file);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  if (fs.existsSync(dest)) fs.rmSync(dest);   // replaces the old hard links
  await run('ffmpeg', [
    '-v', 'error', '-y', '-i', base, '-framerate', String(FPS), '-i', path.join(capDir, 'c_%05d.png'), '-i', sound,
    '-filter_complex',
    "[0:v][1:v]overlay=0:0:format=auto,tmix=frames=2,select='eq(mod(n\\,2)\\,1)',setpts=N/(30*TB),scale=out_color_matrix=bt709:out_range=tv,format=yuv420p[v]",
    '-map', '[v]', '-map', '2:a',
    '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.0', '-preset', 'slow',
    '-b:v', '10M', '-maxrate', '12M', '-bufsize', '24M', '-r', '30', '-g', '30', ...color, ...audio, dest,
  ]);
  fs.rmSync(capDir, { recursive: true, force: true });
  console.log(`${locale}: ${path.relative(ROOT, dest)}`);
}
fs.writeFileSync(fitPath, JSON.stringify(fitAll, null, 1));
if (!process.env.KEEP) {   // the big intermediates; everything regenerates from the take
  for (const f of [frames, steady, base]) fs.rmSync(f, { recursive: true, force: true });
}
console.log(`done in ${((Date.now() - started) / 1000).toFixed(0)} s: ${duration.toFixed(2)} s per preview`);
