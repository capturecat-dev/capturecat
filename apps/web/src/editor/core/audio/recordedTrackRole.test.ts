import { describe, expect, it } from "vitest";
import { buildAudioMixPlan, recordedTrackRole } from "./mixPlan";
import { newProject } from "../model";

// Port of ProjectAudioMix.recordedTrackRole (the Mac's --audio-role-test):
// a take whose ONLY audio track is mono is a mic-only take → Microphone.
describe("recorded track roles", () => {
  it("maps each layout like the Mac", () => {
    expect(recordedTrackRole(0, 1, 1)).toBe("microphone"); // mic-only take
    expect(recordedTrackRole(0, 1, 2)).toBe("systemAudio"); // system-only take
    expect(recordedTrackRole(0, 1, undefined)).toBe("systemAudio"); // unknown: index rule
    expect(recordedTrackRole(0, 2, 2)).toBe("systemAudio"); // system + mic
    expect(recordedTrackRole(1, 2, 1)).toBe("microphone");
  });

  it("a mic-only take follows the Microphone slider in the mix plan", () => {
    const p = newProject({ name: "t", duration: 6 });
    p.trimEnd = 6;
    p.settings.systemAudioVolume = 0.3;
    p.settings.microphoneVolume = 0.7;
    const cues = { clickTimes: [], keystrokes: [] };
    const volumes = (tracks: { duration: number; channels?: number }[]) =>
      buildAudioMixPlan(p, cues, { assetDuration: 6, recordingTracks: tracks, voiceDurations: {} })!
        .recording!.tracks.map((t) => t.volume);
    expect(volumes([{ duration: 6, channels: 1 }])).toEqual([Math.fround(0.7)]);
    expect(volumes([{ duration: 6, channels: 2 }])).toEqual([Math.fround(0.3)]);
    expect(volumes([{ duration: 6, channels: 2 }, { duration: 6, channels: 1 }])).toEqual([Math.fround(0.3), Math.fround(0.7)]);
  });
});
