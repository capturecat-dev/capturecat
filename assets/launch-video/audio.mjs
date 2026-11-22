// ElevenLabs audio for the launch video.
//   node audio.mjs voice   -> one continuous take out/vo/full.mp3, out/vo.json (where each scene's
//                             line starts in it), out/words.json (take-time word timings)   [eleven_v4]
//   node audio.mjs music   -> out/music.mp3 sized to the timeline           [music_v2_5]
//   node audio.mjs sfx     -> out/sfx/click.mp3, out/sfx/whoosh.mp3
// Key: ELEVENLABS_API_KEY from the environment or ./.env (never printed).
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const { SCENES, buildTimeline } = require('./scenes.js');
const out = path.join(here, 'out');

function key() {
  if (process.env.ELEVENLABS_API_KEY) return process.env.ELEVENLABS_API_KEY.trim();
  const f = path.join(here, '.env');
  if (fs.existsSync(f)) {
    const m = fs.readFileSync(f, 'utf8').match(/^\s*(?:export\s+)?(?:ELEVENLABS_API_KEY|XI_API_KEY|ELEVEN_LABS_API_KEY)\s*=\s*["']?([^"'\s]+)/m);
    if (m) return m[1];
  }
  throw new Error('No ELEVENLABS_API_KEY in env or assets/launch-video/.env');
}
const KEY = key();
const VOICE = process.env.VOICE_ID || 'EXAVITQu4vr4xnSDxMaL'; // "Sarah": American female, clear and warm
const api = 'https://api.elevenlabs.io/v1';

async function post(url, body, file) {
  const res = await fetch(url, { method: 'POST', headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json', Accept: 'audio/mpeg' }, body: JSON.stringify(body) });
  if (!res.ok) throw new Error(`${res.status} ${url.replace(api, '')}: ${(await res.text()).slice(0, 400)}`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, Buffer.from(await res.arrayBuffer()));
  return file;
}
const dur = f => Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).toString().trim());

const cmd = process.argv[2];
if (cmd === 'voice') {
  // One continuous take of the whole script, played unbroken; scenes follow the read.
  const text = SCENES.map(s => s.vo).join(' ');
  const res = await fetch(`${api}/text-to-speech/${VOICE}/with-timestamps?output_format=mp3_44100_128`, {
    method: 'POST', headers: { 'xi-api-key': KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      text,
      model_id: process.env.TTS_MODEL || 'eleven_v4',
      // lower stability = more natural variation; a little style for personality
      voice_settings: { stability: 0.38, similarity_boost: 0.8, style: 0.35, use_speaker_boost: true },
    }),
  });
  if (!res.ok) throw new Error(`${res.status} tts: ${(await res.text()).slice(0, 400)}`);
  const j = await res.json();
  fs.mkdirSync(path.join(out, 'vo'), { recursive: true });
  const full = path.join(out, 'vo', 'full.mp3');
  fs.writeFileSync(full, Buffer.from(j.audio_base64, 'base64'));
  const a = j.alignment || j.normalized_alignment;
  const ws = []; let cur = null;
  a.characters.forEach((ch, i) => {
    if (/\s/.test(ch)) { if (cur) { ws.push(cur); cur = null; } return; }
    if (!cur) cur = { w: '', s: a.character_start_times_seconds[i], e: 0 };
    cur.w += ch; cur.e = a.character_end_times_seconds[i];
  });
  if (cur) ws.push(cur);
  const counts = SCENES.map(s => s.vo.split(/\s+/).length);
  if (ws.length !== counts.reduce((x, y) => x + y)) throw new Error(`alignment has ${ws.length} words, script has ${counts.reduce((x, y) => x + y)}`);
  // scene boundaries = midpoint of the breath before each scene's first word
  const words = {}, scenes = {};
  let k = 0;
  SCENES.forEach((s, i) => {
    const mine = ws.slice(k, k + counts[i]), prev = ws[k - 1];
    k += counts[i];
    scenes[s.id] = { t0: +(prev ? (prev.e + mine[0].s) / 2 : 0).toFixed(3) };
    if (i) scenes[SCENES[i - 1].id].t1 = scenes[s.id].t0;
    words[s.id] = mine.map(w => ({ w: w.w, s: +w.s.toFixed(3), e: +w.e.toFixed(3) }));
    console.log(`${s.id.padEnd(4)} @${scenes[s.id].t0.toFixed(2)}s  ${s.vo}`);
  });
  const take = { take: 'vo/full.mp3', duration: dur(full), scenes };
  scenes[SCENES[SCENES.length - 1].id].t1 = take.duration;
  fs.writeFileSync(path.join(out, 'words.json'), JSON.stringify(words, null, 2));
  fs.writeFileSync(path.join(out, 'vo.json'), JSON.stringify(take, null, 2));
  for (const fmt of ['youtube', 'x']) console.log(`${fmt} timeline: ${buildTimeline(take, fmt).total.toFixed(2)}s`);
} else if (cmd === 'music') {
  const voPath = path.join(out, 'vo.json');
  // sized for the longer (YouTube) cut; the X cut fades it out early
  const tl = buildTimeline(fs.existsSync(voPath) ? JSON.parse(fs.readFileSync(voPath, 'utf8')) : null, 'youtube');
  const ms = Math.ceil((tl.total + 1.5) * 1000);
  await post(`${api}/music`, {
    model_id: process.env.MUSIC_MODEL || 'music_v2_5',
    music_length_ms: ms,
    force_instrumental: true,
    prompt: 'Instrumental product launch track for a Mac app. Modern, minimal, optimistic electronic pop: clean plucked synth arpeggios, soft punchy kick, warm sub bass, airy pads, light claps. ~112 BPM, steady energy that lifts at the two-thirds mark, then resolves into a clean, satisfying ending with a final sustained chord. Polished, Apple-keynote feel, no vocals.',
  }, path.join(out, 'music.mp3'));
  console.log(`music ${(ms / 1000).toFixed(1)}s -> out/music.mp3`);
} else if (cmd === 'sfx') {
  await post(`${api}/sound-generation`, { text: 'A single soft, crisp computer mouse click, close up, clean, no room reverb', duration_seconds: 0.5, prompt_influence: 0.7 }, path.join(out, 'sfx/click.mp3'));
  await post(`${api}/sound-generation`, { text: 'A short, soft, airy whoosh transition for a clean UI motion graphic, subtle', duration_seconds: 0.8, prompt_influence: 0.6 }, path.join(out, 'sfx/whoosh.mp3'));
  console.log('sfx -> out/sfx/');
} else {
  console.log('usage: node audio.mjs voice [s1,s2] | music | sfx');
}
