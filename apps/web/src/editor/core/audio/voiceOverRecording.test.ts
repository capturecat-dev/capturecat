import { describe, expect, it } from "vitest";

import { newProject, newSpeedRegion, parseProjectText, serializeProject, serializeProjectText } from "../model";
import { SpeedTimeMap } from "../time/speedTimeMap";
import {
  LIVE_PLACEHOLDER_SAMPLES,
  VOICE_OVER_METER_CAP,
  alignFirstChunk,
  appendMeterSample,
  liveVoiceBlock,
  meterLevel,
  recordedVoiceOverClip,
  voiceOverFileName,
  voiceOverRecordingStart,
} from "./voiceOverRecording";

const ID = "11111111-2222-4333-8444-555555555555";

function project(opts: { duration?: number; trimStart?: number; trimEnd?: number } = {}) {
  const p = newProject({ id: ID, duration: opts.duration ?? 20, videoURL: "file:///CaptureCat/Projects/x/recording.mov" });
  p.trimStart = opts.trimStart ?? 0;
  p.trimEnd = opts.trimEnd ?? 0;
  return p;
}

describe("voiceOverRecordingStart (startVoiceOverRecording)", () => {
  it("is the playhead, clamped to the trim window", () => {
    const p = project({ trimStart: 2, trimEnd: 12 });
    expect(voiceOverRecordingStart(p, 5)).toBe(5);
    expect(voiceOverRecordingStart(p, 0.5)).toBe(2);
    expect(voiceOverRecordingStart(p, 19)).toBe(12);
  });
  it("trimEnd 0 means the end of the recording", () => {
    expect(voiceOverRecordingStart(project(), 25)).toBe(20);
  });
});

describe("recordedVoiceOverClip (stopVoiceOverRecording)", () => {
  it("builds the Mac's VoiceOverClip: start, duration = file length, defaults", () => {
    const clip = recordedVoiceOverClip(project(), { fileName: "voiceover-A.m4a", clipStart: 3, finalizedDuration: 4.25, id: "C1" })!;
    expect(clip).toEqual({
      id: "C1",
      fileName: "voiceover-A.m4a",
      startTime: 3,
      sourceStartTime: 0,
      duration: 4.25,
      sourceDuration: 4.25,
      gain: 1,
      label: "Voice Over",
    });
  });
  it("clamps the duration to the recording's end but keeps the whole file as source", () => {
    const clip = recordedVoiceOverClip(project({ duration: 10 }), { fileName: "v.m4a", clipStart: 8, finalizedDuration: 5 })!;
    expect(clip.duration).toBe(2);
    expect(clip.sourceDuration).toBe(5);
  });
  it("uses project.duration (not the trim end), like the Mac", () => {
    const clip = recordedVoiceOverClip(project({ duration: 10, trimEnd: 6 }), { fileName: "v.m4a", clipStart: 5, finalizedDuration: 3 })!;
    expect(clip.duration).toBe(3);
  });
  it("drops takes of 0.1 s or less (and a start at the very end)", () => {
    expect(recordedVoiceOverClip(project(), { fileName: "v.m4a", clipStart: 1, finalizedDuration: 0.1 })).toBeNull();
    expect(recordedVoiceOverClip(project(), { fileName: "v.m4a", clipStart: 1, finalizedDuration: 0.05 })).toBeNull();
    expect(recordedVoiceOverClip(project({ duration: 10 }), { fileName: "v.m4a", clipStart: 10, finalizedDuration: 3 })).toBeNull();
    expect(recordedVoiceOverClip(project(), { fileName: "v.m4a", clipStart: 1, finalizedDuration: 0.1001 })?.duration).toBeCloseTo(0.1001, 12);
  });
  it("round-trips through project.json with the Swift CodingKeys", () => {
    const p = project();
    const clip = recordedVoiceOverClip(p, { fileName: voiceOverFileName("abcdef00-1111-4222-8333-444455556666"), clipStart: 1.5, finalizedDuration: 2.75 })!;
    p.voiceOverClips.push(clip);
    const json = serializeProject(p) as { voiceOverClips: Record<string, unknown>[] };
    expect(Object.keys(json.voiceOverClips[0]).sort()).toEqual(
      ["duration", "fileName", "gain", "id", "label", "sourceDuration", "sourceStartTime", "startTime"].sort(),
    );
    const back = parseProjectText(serializeProjectText(p));
    expect(back.voiceOverClips[0]).toMatchObject({
      id: clip.id,
      fileName: "voiceover-ABCDEF00-1111-4222-8333-444455556666.m4a",
      startTime: 1.5,
      duration: 2.75,
      sourceStartTime: 0,
      sourceDuration: 2.75,
      gain: 1,
      label: "Voice Over",
    });
  });
});

describe("voiceOverFileName", () => {
  it("is voiceover-<UPPERCASE UUID>.m4a (wav only for the PCM fallback)", () => {
    expect(voiceOverFileName("3f2504e0-4f89-11d3-9a0c-0305e82c3301")).toBe("voiceover-3F2504E0-4F89-11D3-9A0C-0305E82C3301.m4a");
    expect(voiceOverFileName("3F2504E0-4F89-11D3-9A0C-0305E82C3301", "wav")).toBe("voiceover-3F2504E0-4F89-11D3-9A0C-0305E82C3301.wav");
  });
});

describe("meter (VoiceOverRecorder.currentMeterLevel)", () => {
  it("is the RMS amplitude, clamped to 0…1", () => {
    expect(meterLevel(new Float32Array(64))).toBe(0);
    expect(meterLevel(new Float32Array(64).fill(0.5))).toBeCloseTo(0.5, 6);
    const sine = Float32Array.from({ length: 4800 }, (_, i) => Math.sin((2 * Math.PI * 440 * i) / 48000));
    expect(meterLevel(sine)).toBeCloseTo(Math.SQRT1_2, 3);
    expect(meterLevel(new Float32Array(8).fill(3))).toBe(1);
    expect(meterLevel([])).toBe(0);
  });
  it("keeps the newest 240 samples", () => {
    let s: number[] = [];
    for (let i = 0; i < 300; i++) s = appendMeterSample(s, i);
    expect(s.length).toBe(VOICE_OVER_METER_CAP);
    expect(s[0]).toBe(60);
    expect(s[239]).toBe(299);
  });
});

describe("liveVoiceBlock (TimelineVoiceRowModel live item + voiceLiveRect)", () => {
  it("is gated until the playhead passes the start", () => {
    const p = project();
    const map = new SpeedTimeMap(0, 20, []);
    expect(liveVoiceBlock(p, map, { startSource: 4, currentSource: 4, samples: [] })).toBeNull();
    expect(liveVoiceBlock(p, map, { startSource: 4, currentSource: 3, samples: [] })).toBeNull();
    expect(liveVoiceBlock({ ...p, duration: 0 }, map, { startSource: 4, currentSource: 5, samples: [] })).toBeNull();
  });
  it("spans start → current in OUTPUT time, at least 0.1 s, placeholder bars before the first meter tick", () => {
    const p = project();
    const map = new SpeedTimeMap(0, 20, []);
    const a = liveVoiceBlock(p, map, { startSource: 4, currentSource: 4.05, samples: [] })!;
    expect(a.start).toBe(4);
    expect(a.end).toBeCloseTo(4.1, 12);
    expect(Array.from(a.samples)).toEqual(Array.from(LIVE_PLACEHOLDER_SAMPLES));
    expect(a.samples.length).toBe(24);
    const b = liveVoiceBlock(p, map, { startSource: 4, currentSource: 7, samples: [0.3, 0.4] })!;
    expect([b.start, b.end, Array.from(b.samples)]).toEqual([4, 7, [0.3, 0.4]]);
  });
  it("maps through trim + speed regions", () => {
    const p = project({ trimStart: 2 });
    p.speedRegions.push({ ...newSpeedRegion(4, 8), speed: 2 });
    const map = new SpeedTimeMap(2, 20, p.speedRegions);
    const live = liveVoiceBlock(p, map, { startSource: 3, currentSource: 8, samples: [0.5] })!;
    expect(live.start).toBeCloseTo(1, 12); // 3 − 2
    expect(live.end).toBeCloseTo(4, 12); // 1 + (4 − 3) + (8 − 4) / 2
  });
});

describe("alignFirstChunk", () => {
  it("drops samples captured before the timeline started", () => {
    expect(alignFirstChunk(1000, 1300)).toEqual({ skip: 300, pad: 0 });
  });
  it("pads with silence when the microphone started late", () => {
    expect(alignFirstChunk(1300, 1000)).toEqual({ skip: 0, pad: 300 });
    expect(alignFirstChunk(1000, 1000)).toEqual({ skip: 0, pad: 0 });
  });
});
