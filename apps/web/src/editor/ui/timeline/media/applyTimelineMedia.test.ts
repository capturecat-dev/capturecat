/**
 * applyTimelineMedia — the decoded-media → TimelineSnapshot join
 * (TimelineViewController.canvasVideoAssets / canvasVoiceAssets).
 */
import { describe, expect, it } from "vitest";

import { PeakEnvelopeBuilder, recordingWaveform, voiceClipWaveform, type PeakEnvelope } from "../../../core/audio/waveformPeaks";
import { newProject, newVoiceOverClip, type Project } from "../../../core/model";
import { EMPTY_SELECTION } from "../../../state/selection";
import { timelineSnapshot } from "../../../state/timeline";
import { applyTimelineMedia, EMPTY_TIMELINE_MEDIA, type TimelineMediaSnapshot } from "./applyTimelineMedia";

function envelope(rate: number, seconds: number, amp: (t: number) => number): PeakEnvelope {
  const b = new PeakEnvelopeBuilder(rate, 1);
  const frames = Math.round(rate * seconds);
  const pcm = new Int16Array(frames);
  for (let i = 0; i < frames; i++) pcm[i] = Math.round(amp(i / rate) * 32000 * (i % 2 ? 1 : -1));
  b.pushInt16Interleaved(0, pcm);
  return b.finish();
}

function project(): Project {
  const p = newProject({ id: "11111111-2222-4333-8444-555555555555", duration: 20, videoURL: "recording.mov" });
  p.trimStart = 2;
  p.trimEnd = 18;
  p.voiceOverClips = [
    newVoiceOverClip("voice-a.m4a", 1, 3, { id: "AAAAAAAA-0000-4000-8000-000000000001", sourceStartTime: 0.5, sourceDuration: 6 }),
    newVoiceOverClip("voice-b.m4a", 8, 2, { id: "AAAAAAAA-0000-4000-8000-000000000002" }),
  ];
  p.sourceSegments = [{ startTime: 0, duration: 5, kind: "device", contentX: 0.1, contentY: 0.1, contentWidth: 0.5, contentHeight: 0.8 }];
  return p;
}

const snap = (p: Project) => timelineSnapshot({ project: p, selection: EMPTY_SELECTION, sliceArmed: false, hasAudio: true });

describe("applyTimelineMedia", () => {
  it("fills assets: thumbnails, trim-window waveform (180), sourceSegments, trim window", () => {
    const p = project();
    const rec = [envelope(48000, 20, (t) => (t < 10 ? 0.2 : 0.9)), null];
    const thumbs = [{ time: 0.25, image: {} as CanvasImageSource, width: 171, height: 96 }];
    const media: TimelineMediaSnapshot = { version: 3, thumbnails: thumbs, recording: rec, voice: new Map() };
    const out = applyTimelineMedia(snap(p), p, media);
    expect(out.assets?.thumbnails).toBe(thumbs);
    expect(out.assets?.sourceSegments).toBe(p.sourceSegments);
    expect(out.assets?.trimSourceStart).toBe(2);
    expect(out.assets?.trimSourceEnd).toBe(18);
    expect(Array.from(out.assets!.audioSamples!)).toEqual(Array.from(recordingWaveform(p, [rec[0]!])));
    expect(out.assets!.audioSamples!.length).toBe(180);
  });

  it("backfills voice clips lacking a waveform (72 buckets over the clip window) and keeps given ones", () => {
    const p = project();
    const a = envelope(44100, 6, (t) => Math.abs(Math.sin(t * 3)));
    const media: TimelineMediaSnapshot = { ...EMPTY_TIMELINE_MEDIA, version: 1, voice: new Map([["voice-a.m4a", a], ["voice-b.m4a", null]]) };
    const base = snap(p);
    const given = [0.5, 0.5];
    base.voice!.clips[1] = { ...base.voice!.clips[1], waveform: given };
    const out = applyTimelineMedia(base, p, media);
    const clipA = out.voice!.clips[0];
    expect(clipA.waveform!.length).toBe(72);
    expect(Array.from(clipA.waveform!)).toEqual(Array.from(voiceClipWaveform(p.voiceOverClips[0], a)));
    expect(out.voice!.clips[1].waveform).toBe(given);
    // Memoised: the same clip + envelope yields the same array (no re-bucketing per snapshot).
    expect(applyTimelineMedia(snap(p), p, media).voice!.clips[0].waveform).toBe(clipA.waveform);
  });

  it("a trim edit re-buckets from the same envelope", () => {
    const p = project();
    const rec = [envelope(48000, 20, (t) => (t < 10 ? 0.2 : 0.9))];
    const media: TimelineMediaSnapshot = { ...EMPTY_TIMELINE_MEDIA, version: 1, recording: rec };
    const before = applyTimelineMedia(snap(p), p, media).assets!.audioSamples!;
    const trimmed = { ...p, trimStart: 11 };
    const after = applyTimelineMedia(snap(trimmed), trimmed, media).assets!.audioSamples!;
    expect(after).not.toBe(before);
    // 2…18 s: quiet first half, loud second → normalised 0.2/0.9; 11…18 s: all loud → 1.
    expect(before[0]).toBeCloseTo(0.2 / 0.9, 2);
    expect(after[0]).toBeCloseTo(1, 5);
  });

  it("no project / no media leaves the snapshot's lanes alone", () => {
    const p = project();
    const s = snap(p);
    expect(applyTimelineMedia(s, null, EMPTY_TIMELINE_MEDIA)).toBe(s);
    const out = applyTimelineMedia(s, p, EMPTY_TIMELINE_MEDIA);
    expect(out.assets?.thumbnails).toBeUndefined();
    expect(out.assets?.audioSamples).toBeUndefined();
    expect(out.voice).toBe(s.voice);
  });
});
