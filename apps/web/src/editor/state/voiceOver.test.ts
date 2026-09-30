import { afterEach, describe, expect, it, vi } from "vitest";

import { VOICE_OVER_PERMISSION_MESSAGE } from "../core/audio/voiceOverRecording";
import { newProject, parseProjectText, serializeProjectText } from "../core/model";
import type { EngineClient } from "../engine/client";
import type { TransportState } from "../engine/protocol";
import type { RecordedVoiceOver } from "../record/voiceOverRecorder";
import { EditorController } from "./controller";
import { EditorStore } from "./store";
import { VoiceOverSession, type VoiceOverMedia, type VoiceOverRecorderLike } from "./voiceOver";

const ID = "11111111-2222-4333-8444-555555555555";

class FakeClient {
  transport: TransportState | null = { playing: false, time: 0, wallMs: 0, rate: 1, loop: true, duration: 20 };
  listeners = new Set<(t: TransportState) => void>();
  calls: string[] = [];
  files: Record<string, string> = {};
  onTransport(cb: (t: TransportState) => void) {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }
  emit(patch: Partial<TransportState>) {
    this.transport = { ...this.transport!, ...patch };
    for (const l of [...this.listeners]) l(this.transport);
  }
  play() {
    this.calls.push("play");
  }
  pause() {
    this.calls.push("pause");
    this.emit({ playing: false });
  }
  setLoop(on: boolean) {
    this.calls.push(`loop:${on}`);
    this.transport = { ...this.transport!, loop: on };
  }
  seek(t: number) {
    this.calls.push(`seek:${t}`);
    return Promise.resolve({ frameIndex: 0, superseded: false, time: t });
  }
  setProject() {}
  addMediaFiles(f: Record<string, string>) {
    Object.assign(this.files, f);
  }
}

class FakeRecorder implements VoiceOverRecorderLike {
  onEnded: (() => void) | null = null;
  anchors: number[] = [];
  stopped: boolean | null = null;
  constructor(private readonly duration = 2.5) {}
  level() {
    return 0.42;
  }
  anchor(wallMs: number) {
    this.anchors.push(wallMs);
  }
  async stop(discard = false): Promise<RecordedVoiceOver | null> {
    this.stopped = discard;
    if (discard) return null;
    const file = new File([new Uint8Array(16)], "voiceover-TAKE.m4a", { type: "audio/mp4" });
    return { file, fileName: "voiceover-TAKE.m4a", contentType: "audio/mp4", codec: "aac", duration: this.duration };
  }
}

function setup(opts: { trimStart?: number; openRecorder?: () => Promise<VoiceOverRecorderLike>; media?: Partial<VoiceOverMedia> } = {}) {
  const p = newProject({ id: ID, duration: 20, videoURL: "file:///CaptureCat/Projects/x/recording.mov" });
  p.trimStart = opts.trimStart ?? 0;
  const store = new EditorStore();
  store.load({ text: serializeProjectText(p), origin: "local", revision: null });
  const controller = new EditorController(store);
  const client = new FakeClient();
  controller.client = client as unknown as EngineClient;
  const recorder = new FakeRecorder();
  const alerts: string[] = [];
  const persisted: RecordedVoiceOver[] = [];
  const registered: Record<string, string> = {};
  const media: VoiceOverMedia = {
    register: (name, url) => {
      registered[name] = url;
      client.addMediaFiles({ [name]: url });
    },
    persist: async (take) => {
      persisted.push(take);
    },
    ...opts.media,
  };
  const session = new VoiceOverSession({
    store,
    controller,
    media,
    openRecorder: opts.openRecorder ?? (async () => recorder),
    onAlert: (m) => alerts.push(m),
    objectUrl: () => "blob:take",
  });
  return { store, controller, client, recorder, session, alerts, persisted, registered };
}

afterEach(() => vi.useRealTimers());

describe("VoiceOverSession (EditorPlaybackController voice over)", () => {
  it("mic key starts at the playhead, plays once, anchors the take to the timeline", async () => {
    const { controller, client, recorder, session } = setup();
    controller.seek(4);
    await session.toggle();
    expect(session.isRecording).toBe(true);
    expect(session.recordingStartTime).toBe(4);
    expect(client.calls).toEqual(["seek:4", "loop:false", "play"]);
    // The engine reports it started at output 4.01 at wall 1000 → t=4 was 10 ms earlier.
    client.emit({ playing: true, time: 4.01, wallMs: 1000 });
    expect(recorder.anchors).toHaveLength(1);
    expect(recorder.anchors[0]).toBeCloseTo(990, 9);
    client.emit({ playing: true, time: 5, wallMs: 2000 }); // a later discontinuity: no re-anchor
    expect(recorder.anchors).toHaveLength(1);
  });

  it("clamps the start into the trim window", async () => {
    const { controller, session } = setup({ trimStart: 3 });
    controller.seek(0);
    await session.toggle();
    expect(session.recordingStartTime).toBe(3);
  });

  it("pause (space) stops the take and appends the Mac-shaped clip as one undo step", async () => {
    const { store, controller, client, session, persisted, registered } = setup();
    controller.seek(2);
    await session.toggle();
    client.emit({ playing: true, time: 2, wallMs: 1 });
    controller.togglePlay(); // space → pause
    await vi.waitFor(() => expect(store.getState().project!.voiceOverClips).toHaveLength(1));
    expect(session.isRecording).toBe(false);
    const clip = store.getState().project!.voiceOverClips[0];
    expect(clip).toMatchObject({ fileName: "voiceover-TAKE.m4a", startTime: 2, sourceStartTime: 0, duration: 2.5, sourceDuration: 2.5, gain: 1, label: "Voice Over" });
    expect(registered).toEqual({ "voiceover-TAKE.m4a": "blob:take" });
    expect(client.files["voiceover-TAKE.m4a"]).toBe("blob:take");
    expect(persisted).toHaveLength(1);
    expect(client.transport!.loop).toBe(true); // looping restored
    expect(store.getState().undoLabel).toBe("Record Voice Over");
    store.undo();
    expect(store.getState().project!.voiceOverClips).toHaveLength(0);
    store.redo();
    expect(store.getState().project!.voiceOverClips[0].id).toBe(clip.id);
    // …and the saved document decodes it back (lossless round trip).
    const back = parseProjectText(store.documentText());
    expect(back.voiceOverClips[0]).toEqual(clip);
  });

  it("mic key while recording stops but keeps playing (resumePlayback: isPlaying)", async () => {
    const { store, client, session } = setup();
    await session.toggle();
    client.emit({ playing: true, time: 0, wallMs: 1 });
    await session.toggle();
    expect(client.calls).not.toContain("pause");
    expect(client.transport!.playing).toBe(true);
    expect(store.getState().project!.voiceOverClips).toHaveLength(1);
  });

  it("the end of the timeline stops the take and returns the playhead to the start", async () => {
    const { store, controller, client, session } = setup();
    controller.seek(18);
    await session.toggle();
    client.emit({ playing: true, time: 18, wallMs: 1 });
    client.emit({ playing: false, time: 20 }); // engine paused at the end (loop off)
    await vi.waitFor(() => expect(store.getState().project!.voiceOverClips).toHaveLength(1));
    expect(client.calls).toContain("seek:0");
    expect(controller.playhead.get()).toBe(0);
    // min(file 2.5, max(0.1, duration 20 − start 18)) = 2
    expect(store.getState().project!.voiceOverClips[0].duration).toBe(2);
  });

  it("a transport that has not started yet does not stop the take", async () => {
    const { client, session } = setup();
    await session.toggle();
    client.emit({ playing: false, time: 0 }); // a stale seek echo before play lands
    expect(session.isRecording).toBe(true);
  });

  it("the live block grows with the playhead and the meter", async () => {
    vi.useFakeTimers();
    const { controller, session } = setup();
    controller.seek(1);
    await session.toggle();
    expect(session.live(1)).toBeNull();
    const first = session.live(1.02)!;
    expect(first.start).toBe(1);
    expect(first.end).toBeCloseTo(1.1, 12);
    expect(first.samples).toHaveLength(24); // placeholder
    vi.advanceTimersByTime(45 * 3);
    expect(session.liveSamples).toEqual([0.42, 0.42, 0.42]);
    expect(session.live(3)!.end).toBe(3);
  });

  it("permission denied → the Mac's alert copy, nothing recorded", async () => {
    const { session, alerts, client } = setup({
      openRecorder: async () => {
        throw new Error(VOICE_OVER_PERMISSION_MESSAGE);
      },
    });
    await session.toggle();
    expect(session.isRecording).toBe(false);
    expect(alerts).toEqual(["Microphone access is required to record a voice over."]);
    expect(client.calls).toEqual([]);
  });

  it("a blocked project (team member) alerts instead of recording", async () => {
    let opened = false;
    const { session, alerts } = setup({
      media: { blocker: () => "Only the project's owner can add a voice over." },
      openRecorder: async () => {
        opened = true;
        return new FakeRecorder();
      },
    });
    await session.toggle();
    expect(opened).toBe(false);
    expect(alerts).toEqual(["Only the project's owner can add a voice over."]);
  });

  it("a too-short take is dropped", async () => {
    const short = new FakeRecorder(0.08);
    const { store, client, session } = setup({ openRecorder: async () => short });
    await session.toggle();
    client.emit({ playing: true, time: 0, wallMs: 1 });
    await session.toggle();
    expect(store.getState().project!.voiceOverClips).toHaveLength(0);
  });

  it("teardown while recording discards the take", async () => {
    const { store, client, recorder, session } = setup();
    await session.toggle();
    client.emit({ playing: true, time: 0, wallMs: 1 });
    session.dispose();
    expect(recorder.stopped).toBe(true);
    expect(client.transport!.loop).toBe(true);
    expect(store.getState().project!.voiceOverClips).toHaveLength(0);
  });

  it("an upload failure surfaces in the alert", async () => {
    const { client, session, alerts } = setup({
      media: {
        persist: async () => {
          throw new Error("The voice over couldn't be uploaded to the cloud. Storage limit reached");
        },
      },
    });
    await session.toggle();
    client.emit({ playing: true, time: 0, wallMs: 1 });
    await session.toggle();
    await session.lastPersist;
    expect(alerts).toEqual(["The voice over couldn't be uploaded to the cloud. Storage limit reached"]);
  });
});
