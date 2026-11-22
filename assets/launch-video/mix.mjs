// Mux out/video-<fmt>.mp4 with voice-over, ducked music and SFX.
//   node mix.mjs --fmt youtube   -> out/capturecat-open-source-youtube.mp4 + .srt (upload as subtitles)
//   node mix.mjs --fmt x         -> out/capturecat-open-source-x.mp4 (captions already burned in)
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, 'out');
const fmt = (process.argv.includes('--fmt') && process.argv[process.argv.indexOf('--fmt') + 1]) || 'youtube';
const tl = JSON.parse(fs.readFileSync(path.join(out, `timeline-${fmt}.json`), 'utf8'));
const has = f => fs.existsSync(path.join(out, f));

const inputs = ['-i', path.join(out, `video-${fmt}.mp4`)];
const f = [];
const mixIns = [];
let idx = 1;

// voice-over: the continuous take, unbroken, from tl.voice.at
const vo = tl.voice && has(tl.voice.file) ? [tl.voice] : [];
if (vo.length) {
  inputs.push('-i', path.join(out, tl.voice.file));
  const ms = Math.round(tl.voice.at * 1000);
  f.push(`[${idx}:a]aresample=48000,aformat=channel_layouts=stereo,adelay=${ms}|${ms},apad=whole_dur=${tl.total.toFixed(3)},atrim=0:${tl.total.toFixed(3)},asplit=2[vo][vosc]`);
  mixIns.push('[vo]');
  idx++;
}

// music is opt-in (--music); the default cut is voice + SFX only
if (process.argv.includes('--music') && has('music.mp3')) {
  inputs.push('-i', path.join(out, 'music.mp3'));
  const fadeAt = Math.max(0, tl.total - 2.5);
  f.push(`[${idx}:a]aresample=48000,aformat=channel_layouts=stereo,atrim=0:${tl.total.toFixed(3)},volume=0.42,afade=t=in:d=0.6,afade=t=out:st=${fadeAt.toFixed(2)}:d=2.5[m0]`);
  if (vo.length) { f.push('[m0][vosc]sidechaincompress=threshold=0.04:ratio=5:attack=25:release=450:makeup=1[music]'); }
  else f.push('[m0]anull[music]');
  mixIns.push('[music]');
  idx++;
} else if (vo.length) f.push('[vosc]anullsink');

function sfx(file, times, vol, label) {
  if (!has(file) || !times.length) return;
  inputs.push('-i', path.join(out, file));
  f.push(`[${idx}:a]aresample=48000,aformat=channel_layouts=stereo,volume=${vol},asplit=${times.length}${times.map((_, i) => `[${label}s${i}]`).join('')}`);
  times.forEach((t, i) => { const ms = Math.max(0, Math.round(t * 1000)); f.push(`[${label}s${i}]adelay=${ms}|${ms}[${label}d${i}]`); });
  f.push(`${times.map((_, i) => `[${label}d${i}]`).join('')}amix=inputs=${times.length}:normalize=0,apad=whole_dur=${tl.total.toFixed(3)},atrim=0:${tl.total.toFixed(3)}[${label}]`);
  mixIns.push(`[${label}]`);
  idx++;
}
sfx('sfx/click.mp3', tl.scenes.flatMap(s => s.clicks), 0.55, 'clk');
sfx('sfx/whoosh.mp3', tl.scenes.slice(1).map(s => s.start - 0.2), 0.22, 'wsh');

if (!mixIns.length) { console.error('no audio yet: run node audio.mjs voice|music|sfx'); process.exit(1); }
f.push(`${mixIns.join('')}amix=inputs=${mixIns.length}:normalize=0:duration=longest,loudnorm=I=-14:TP=-1.5:LRA=11,aresample=48000,atrim=0:${tl.total.toFixed(3)}[aout]`);

const file = path.join(out, `capturecat-open-source-${fmt}.mp4`);
const r = spawnSync('ffmpeg', ['-y', '-loglevel', 'error', ...inputs, '-filter_complex', f.join(';'),
  '-map', '0:v', '-map', '[aout]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', fmt === 'x' ? '192k' : '384k', '-ar', '48000', '-t', tl.total.toFixed(3), '-movflags', '+faststart', file], { stdio: 'inherit' });
if (r.status) process.exit(r.status);
console.log(`wrote ${file}`);

// YouTube: subtitles from the ElevenLabs word timings, grouped like the X captions.
if (fmt === 'youtube' && has('words.json')) {
  const words = JSON.parse(fs.readFileSync(path.join(out, 'words.json'), 'utf8'));
  const ts = t => { const ms = Math.max(0, Math.round(t * 1000)); const h = Math.floor(ms / 3.6e6), m = Math.floor(ms / 6e4) % 60, sec = Math.floor(ms / 1000) % 60;
    return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')},${String(ms % 1000).padStart(3, '0')}`; };
  const cues = [];
  for (const sc of tl.scenes) {
    const ws = (words[sc.id] || []).map(w => ({ ...w, s: tl.voice.at + w.s, e: tl.voice.at + w.e }));
    let g = [];
    ws.forEach((w, i) => { g.push(w); if (/[.,!?]$/.test(w.w) && g.length >= 3 || g.length >= 8 || i === ws.length - 1) { cues.push(g); g = []; } });
  }
  const srt = cues.map((g, i) => `${i + 1}\n${ts(g[0].s)} --> ${ts(Math.min(g[g.length - 1].e + 0.3, cues[i + 1] ? cues[i + 1][0].s - 0.02 : Infinity))}\n${g.map(w => w.w).join(' ')}\n`).join('\n');
  fs.writeFileSync(file.replace('.mp4', '.srt'), srt);
  console.log(`wrote ${file.replace('.mp4', '.srt')}`);
}
