/**
 * Audio golden vectors — `core/audio/sounds.ts` against the REAL Swift
 * ClickSoundPlayer / KeySoundPlayer (`CaptureCat --web-audio-fixtures`,
 * compacted into core/audio/audioSounds.golden.json: every Nth sample plus
 * full-length sums, so the whole waveform is covered), and the
 * ProjectAudioMix port's composition semantics.
 */
import { describe, expect, it } from "vitest";
import golden from "../audio/audioSounds.golden.json";
import { EditTrack, buildAudioMixPlan, cmFrames } from "../audio/mixPlan";
import { newProject, newVoiceOverClip } from "../model/defaults";
import { KEY_MIN_INTERVAL, KeyTrack, STROKE_DURATION, TICK_DURATION, keyVariation, strokeSamples, tickSamples } from "../audio/sounds";
import type { ClickSoundStyle, KeySoundStyle, KeystrokeCategory } from "../model/enums";

interface Summary {
  count: number;
  step: number;
  sampled: number[];
  sum: number;
  sumSquares: number;
  sumAbsDiff: number;
}

function expectMatches(actual: Float32Array, g: Summary, label: string) {
  expect(actual.length, `${label} length`).toBe(g.count);
  for (let k = 0; k < g.sampled.length; k++) {
    // Swift Float widened to Double, printed to 9 significant digits.
    const want = Math.fround(g.sampled[k]);
    const got = actual[k * g.step];
    if (Math.abs(got - want) > 2e-7) {
      throw new Error(`${label}[${k * g.step}] = ${got}, Swift ${want}`);
    }
  }
  let sum = 0;
  let sq = 0;
  let tv = 0;
  for (let i = 0; i < actual.length; i++) {
    sum += actual[i];
    sq += actual[i] * actual[i];
    if (i > 0) tv += Math.abs(actual[i] - actual[i - 1]);
  }
  expect(Math.abs(sum - g.sum), `${label} sum`).toBeLessThan(1e-5);
  expect(Math.abs(sq - g.sumSquares), `${label} sumSquares`).toBeLessThan(1e-5);
  expect(Math.abs(tv - g.sumAbsDiff), `${label} total variation`).toBeLessThan(1e-4);
}

describe("audioSounds (ClickSoundPlayer / KeySoundPlayer)", () => {
  it("constants", () => {
    expect(TICK_DURATION).toBe(golden.tickDuration);
    expect(STROKE_DURATION).toBe(golden.strokeDuration);
    expect(KEY_MIN_INTERVAL).toBe(golden.minInterval);
  });

  it("tickSamples(style:) for every style", () => {
    const ticks = golden.ticks as Record<string, Summary>;
    expect(Object.keys(ticks).length).toBe(4);
    for (const [style, g] of Object.entries(ticks)) expectMatches(tickSamples(style as ClickSoundStyle), g, `tick ${style}`);
  });

  it("strokeSamples(style:pitch:) for every style", () => {
    expect(golden.strokes.length).toBe(35);
    for (const s of golden.strokes as (Summary & { style: string; pitch: number })[]) {
      expectMatches(strokeSamples(s.style as KeySoundStyle, s.pitch), s, `stroke ${s.style}@${s.pitch}`);
    }
  });

  it("variation(timestamp:category:) — exact", () => {
    for (const v of golden.variations as { timestamp: number; category: string; pitch: number; level: number }[]) {
      const got = keyVariation(v.timestamp, v.category as KeystrokeCategory);
      expect(got.pitch, `${v.timestamp} ${v.category}`).toBe(v.pitch);
      expect(got.level, `${v.timestamp} ${v.category}`).toBe(v.level);
    }
  });
});

describe("KeyTrack (renderTrackWAV)", () => {
  it("windowed render == full render, density floor applied", () => {
    const cues = [0.1, 0.104, 0.2, 0.25, 0.2505, 0.9].map((t, i) => ({
      outputTime: t,
      seedTimestamp: t + 1,
      category: (i % 2 ? "space" : "key") as KeystrokeCategory,
    }));
    const track = new KeyTrack(cues, 1.0, "Typewriter");
    expect(track.strokeCount).toBe(4); // 0.104 and 0.2505 merge (< 8 ms)
    const full = track.render(0, track.frameCount);
    for (const [start, count] of [
      [0, 1000],
      [4700, 5000],
      [9990, 300],
      [12000, 30000],
    ]) {
      const part = track.render(start, count);
      for (let i = 0; i < count; i++) {
        const want = start + i < track.frameCount ? full[start + i] : 0;
        expect(part[i]).toBe(want);
      }
    }
  });
});

describe("buildAudioMixPlan (ProjectAudioMix.prepare)", () => {
  // The `CaptureCat --web-audio-fixtures` projects; the expected numbers are
  // the ones the web mix reproduced against the Mac's own read-back of the
  // exporter mix (voice-over, ticks and keys sample-exact at these positions).
  const media = { assetDuration: 6, recordingTracks: [{ duration: 6 }, { duration: 6 }], voiceDurations: { "voice.m4a": 3 } };
  const macClicks = [0.30000000000000016, 1.199999999999997, 2.200000000000004, 3.300000000000059, 4.100000000000088, 4.950000000000039, 5.400000000000014];

  it("a2: trim + 2x/0.5x speed + split clips + voice-over + ticks + keys", () => {
    const p = newProject({ id: "00000000-0000-4000-8000-000000002200", duration: 6 });
    p.trimStart = 0.5;
    p.trimEnd = 5.6;
    p.speedRegions = [
      { id: "a", startTime: 1, endTime: 2, speed: 2 },
      { id: "b", startTime: 3, endTime: 3.5, speed: 0.5 },
    ];
    p.videoClipSegments = [
      { id: "c", startTime: 0.5, endTime: 2.6 },
      { id: "d", startTime: 3.1, endTime: 5.2 },
    ];
    p.voiceOverClips = [newVoiceOverClip("voice.m4a", 1.2, 1.5, { sourceStartTime: 0.3, sourceDuration: 3, gain: 0.8 })];
    Object.assign(p.settings, {
      voiceOverVolume: 1.2,
      microphoneVolume: 0.7,
      clickSoundEnabled: true,
      clickSoundVolume: 0.7,
      keySoundEnabled: true,
      keySoundVolume: 0.6,
    });
    const keys = [0.4, 0.8, 2.7, 3.2].map((timestamp) => ({ timestamp, category: "key" as const }));
    const plan = buildAudioMixPlan(p, { clickTimes: macClicks, keystrokes: keys }, media)!;
    expect(plan.path).toBe("composed");
    expect(plan.endFrame).toBe(225_600);
    expect(plan.recording.timePitch).toBe(true);
    expect(plan.recording.edits.map((e) => [e.start, e.dur, e.src, e.srcDur])).toEqual([
      [0, 24_000, 24_000, 24_000],
      [24_000, 24_000, 48_000, 48_000],
      [48_000, 28_800, 96_000, 28_800],
      [105_600, 38_320, 148_800, 19_120],
      [144_000, 81_600, 168_000, 81_600],
    ]);
    expect(plan.recording.tracks.map((t) => t.volume)).toEqual([1, Math.fround(0.7)]);
    expect(plan.voiceOvers.map((v) => [v.edit.start, v.edit.src, v.edit.dur, v.volume])).toEqual([[28_800, 14_400, 72_000, Math.fround(0.96)]]);
    expect(plan.clicks!.outputTimes.map((t) => +t.toFixed(6))).toEqual([0.6, 1.2, 2.6, 3.6, 4.45]);
    expect(plan.keys!.cues.map((c) => +c.outputTime.toFixed(6))).toEqual([0.3, 2.4]); // 0.4 trimmed, 2.7 cut (clip gap), 3.2 in the 0.5x span
  });

  it("a3: trim only → the fast path (source read from CMTime(trimStart, 600))", () => {
    const p = newProject({ id: "00000000-0000-4000-8000-000000002300", duration: 6 });
    p.trimStart = 0.5;
    p.trimEnd = 5.5;
    Object.assign(p.settings, { microphoneVolume: 0.3 });
    const plan = buildAudioMixPlan(p, { clickTimes: [], keystrokes: [] }, media)!;
    expect(plan.path).toBe("fast");
    expect(plan.endFrame).toBe(240_000);
    expect(plan.recording.edits).toEqual([{ start: 0, dur: 240_000, src: 24_000, srcDur: 240_000 }]);
  });

  it("muteRecordedAudio zeroes every recorded track; no media → no audio track", () => {
    const p = newProject({ id: "00000000-0000-4000-8000-000000002400", duration: 6 });
    p.settings.muteRecordedAudio = true;
    expect(buildAudioMixPlan(p, { clickTimes: [], keystrokes: [] }, media)!.recording.tracks.map((t) => t.volume)).toEqual([0, 0]);
    expect(buildAudioMixPlan(p, { clickTimes: [], keystrokes: [] }, { ...media, recordingTracks: [] })).toBeNull();
  });
});

describe("EditTrack (AVMutableCompositionTrack semantics)", () => {
  it("CMTime(…, 600) truncation on the 48 kHz grid", () => {
    expect(cmFrames(0.07)).toBe(3360);
    expect(cmFrames(5.199999999999999)).toBe(3119 * 80);
  });

  it("inserting inside an edit splits it and pushes the tail", () => {
    const t = new EditTrack();
    t.insert(1000, 0, 3360);
    t.insert(3000, 0, 3360); // lands inside the first tick
    expect(t.edits.map((e) => [e.start, e.dur, e.src])).toEqual([
      [1000, 2000, 0],
      [3000, 3360, 0],
      [6360, 1360, 2000],
    ]);
    expect(t.end).toBe(7720);
  });

  it("scaleTimeRange retimes the inserted edit and shifts later ones", () => {
    const t = new EditTrack();
    const a = t.insert(0, 48000, 48000);
    t.scale(a, 24000);
    const b = t.insert(24000, 96000, 48000);
    expect([a.start, a.dur, a.srcDur, b.start, b.dur]).toEqual([0, 24000, 48000, 24000, 48000]);
    expect(t.end).toBe(72000);
  });
});
