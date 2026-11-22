// Frame-exact renderer: loads index.html in headless Chrome, calls renderAt(t)
// for every frame and pipes JPEG frames into ffmpeg. No wall clock involved.
//   node render.mjs [--fmt youtube|x] --stills 1.5,8,20   -> out/still-<fmt>-<t>.png
//   node render.mjs [--fmt youtube|x] --fps 60 [--from 0 --to 10]  -> out/video-<fmt>.mp4 (silent)
// youtube = 1920x1080; x = 1080x1080 with a header/footer around a cropped stage.
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const { chromium } = require(path.join(here, '../../node_modules/playwright-core'));
const { buildTimeline, FORMATS } = require('./scenes.js');

const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => {
  if (v.startsWith('--')) a.push([v.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : true]);
  return a;
}, []));
const out = path.join(here, 'out');
fs.mkdirSync(out, { recursive: true });

const fmt = args.fmt || 'youtube';
const F = FORMATS[fmt];
if (!F) throw new Error(`unknown --fmt ${fmt}`);
const readJSON = f => (fs.existsSync(path.join(out, f)) ? JSON.parse(fs.readFileSync(path.join(out, f), 'utf8')) : null);
// Word timings from the ElevenLabs take (take-time). If the take doesn't match the
// script any more (or there isn't one), fall back to even placeholder timings so
// previews still pace sensibly.
const { SCENES } = require('./scenes.js');
const takeWords = readJSON('words.json') || {}, vo = readJSON('vo.json');
const matches = vo && vo.scenes && SCENES.every(sc => takeWords[sc.id] && takeWords[sc.id].map(w => w.w).join(' ') === sc.vo.trim());
const timeline = buildTimeline(matches ? vo : null, fmt);
fs.writeFileSync(path.join(out, `timeline-${fmt}.json`), JSON.stringify(timeline, null, 2));
// scene-local seconds at which each word is spoken
const words = {};
timeline.scenes.forEach((sc, i) => {
  words[sc.id] = matches
    ? takeWords[sc.id].map(w => ({ w: w.w, s: timeline.voice.at + w.s - sc.start, e: timeline.voice.at + w.e - sc.start }))
    : SCENES[i].vo.split(' ').map((w, j) => ({ w, s: 0.2 + j * 0.3, e: 0.46 + j * 0.3 }));
});
const placeholders = matches ? 0 : SCENES.length;
console.log(`${fmt}: ${timeline.total.toFixed(2)}s, ${timeline.scenes.length} scenes${placeholders ? `, ${placeholders} with placeholder voice timings` : ''}`);

const browser = await chromium.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  args: ['--force-color-profile=srgb', '--disable-lcd-text', '--font-render-hinting=none'],
});
const page = await browser.newPage({ viewport: { width: F.width, height: F.height }, deviceScaleFactor: 1 });
await page.addInitScript(([tl, ws]) => { window.TIMELINE = tl; window.WORDS = ws; }, [timeline, words]);
page.on('pageerror', e => console.error('page error:', e.message));
await page.goto(pathToFileURL(path.join(here, 'index.html')).href + `?fmt=${fmt}`);
await page.evaluate(() => window.ready);
const stage = await page.$(fmt === 'x' ? '#frame' : '#stage');

if (args.stills) {
  for (const t of String(args.stills).split(',').map(Number)) {
    await page.evaluate(t => window.renderAt(t), t);
    const f = path.join(out, `still-${fmt}-${t.toFixed(2)}.png`);
    await stage.screenshot({ path: f });
    console.log(f);
  }
} else {
  const fps = Number(args.fps || F.fps);
  const from = Number(args.from || 0), to = Math.min(Number(args.to || timeline.total), timeline.total);
  const file = path.join(out, args.out || `video-${fmt}.mp4`);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', ...F.enc, '-r', String(fps), '-fps_mode', 'cfr', '-pix_fmt', 'yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-movflags', '+faststart', file], { stdio: ['pipe', 'inherit', 'inherit'] });
  const frames = Math.round((to - from) * fps);
  const t0 = Date.now();
  for (let i = 0; i < frames; i++) {
    await page.evaluate(t => window.renderAt(t), from + i / fps);
    const buf = await stage.screenshot({ type: 'jpeg', quality: 95 });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % fps === 0) process.stdout.write(`\r${i}/${frames} frames  ${((Date.now() - t0) / 1000).toFixed(0)}s`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
  console.log(`\nwrote ${file}`);
}
await browser.close();
