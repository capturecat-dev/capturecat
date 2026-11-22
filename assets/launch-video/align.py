#!/usr/bin/env python3
"""Recover where each per-scene voice clip sits inside the continuous take.

The clips in out/vo/<scene>.mp3 were cut from out/vo/full.mp3, so cross-correlating
each one against the take gives its exact offset. Rewrites out/words.json with
absolute (take-time) word timings and out/vo.json in the continuous-take format:
  { "take": "vo/full.mp3", "duration": s, "scenes": { id: { "t0": s, "t1": s } } }
Only needed for takes generated before audio.mjs wrote that format itself.
"""
import json, subprocess, sys, os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
SR = 16000

def pcm(path):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-ac', '1', '-ar', str(SR), '-f', 'f32le', '-'],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)

def offset(full, clip):
    n = 1 << int(np.ceil(np.log2(len(full) + len(clip))))
    corr = np.fft.irfft(np.fft.rfft(full, n) * np.conj(np.fft.rfft(clip, n)), n)
    return int(np.argmax(corr[:len(full)])) / SR

ids = json.loads(subprocess.run(['node', '-e', "console.log(JSON.stringify(require('./scenes.js').SCENES.map(s=>s.id)))"],
                                capture_output=True, text=True, cwd=HERE, check=True).stdout)
words = json.load(open(os.path.join(OUT, 'words.json')))
full = pcm(os.path.join(OUT, 'vo', 'full.mp3'))
scenes, absw = {}, {}
for sid in ids:
    clip = pcm(os.path.join(OUT, 'vo', f'{sid}.mp3'))
    t0 = offset(full, clip)
    scenes[sid] = {'t0': round(t0, 3), 't1': round(t0 + len(clip) / SR, 3)}
    absw[sid] = [{'w': w['w'], 's': round(t0 + w['s'], 3), 'e': round(t0 + w['e'], 3)} for w in words[sid]]
    print(f'{sid:4} t0={t0:7.3f}  first word "{absw[sid][0]["w"]}" at {absw[sid][0]["s"]:.3f}')
# make boundaries contiguous: each scene ends where the next begins
for a, b in zip(ids, ids[1:]):
    scenes[a]['t1'] = scenes[b]['t0']
json.dump({'take': 'vo/full.mp3', 'duration': round(len(full) / SR, 3), 'scenes': scenes}, open(os.path.join(OUT, 'vo.json'), 'w'), indent=2)
json.dump(absw, open(os.path.join(OUT, 'words.json'), 'w'), indent=2)
print('wrote out/vo.json and out/words.json (take-time)')
