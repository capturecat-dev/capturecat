import { describe, expect, it } from "vitest";

import { micStartError, voiceOverEncoding } from "./voiceOverRecorder";

describe("micStartError (ensureMicrophonePermission / AVAudioRecorder.record())", () => {
  it("a denied permission → the Mac's permission copy", () => {
    for (const name of ["NotAllowedError", "SecurityError", "PermissionDeniedError"]) {
      const e = micStartError(Object.assign(new Error("x"), { name }));
      expect(e.reason).toBe("permission");
      expect(e.message).toBe("Microphone access is required to record a voice over.");
    }
  });
  it("no microphone / busy device → the Mac's start-failure copy", () => {
    for (const name of ["NotFoundError", "NotReadableError", "OverconstrainedError", "AbortError"]) {
      const e = micStartError(Object.assign(new Error("x"), { name }));
      expect(e.reason).toBe("unavailable");
      expect(e.message).toBe("Unable to start voice-over recording.");
    }
    expect(micStartError(null).message).toBe("Unable to start voice-over recording.");
  });
});

describe("voiceOverEncoding", () => {
  it("falls back to 16-bit PCM WAV when AAC cannot be encoded", async () => {
    // Node has no WebCodecs AudioEncoder → the fallback.
    expect(await voiceOverEncoding()).toEqual({ codec: "pcm-s16", ext: "wav", contentType: "audio/wav" });
  });
});
