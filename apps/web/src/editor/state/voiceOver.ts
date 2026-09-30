/**
 * Voice-over recording in the editor — the web port of the Mac's record
 * flow (`EditorPlaybackController` "Voice over" + the EditorShellViewController
 * observation that stops it), React-free:
 *
 *   mic key (TransportBar → hooks.toggleVoiceOver)
 *     idle       → start: microphone (permission first), the clip start =
 *                  the playhead clamped to the trim window, then PLAY
 *     recording  → stop, keeping playback running (`resumePlayback: isPlaying`)
 *   playback stops while recording (space/pause, the end of the timeline)
 *     → stop (`resumePlayback: false`); at the end the playhead returns to
 *       the trim start like the Mac's end-of-playback reset
 *   stop → the finished file becomes a `VoiceOverClip` exactly as the Mac
 *     builds it (core/audio/voiceOverRecording.ts), appended as ONE undoable
 *     edit ("Record Voice Over"), its file registered with the engine so it
 *     plays and exports at once, then persisted (cloud upload; local dev
 *     projects keep it in the tab)
 *   teardown while recording → the take is discarded (the Mac's teardown)
 *
 * The web engine loops playback by default; while recording it plays once
 * (loop off) so the end of the timeline ends the take, as on the Mac.
 */
import {
  VOICE_OVER_METER_INTERVAL_MS,
  VOICE_OVER_START_FAILED_MESSAGE,
  appendMeterSample,
  liveVoiceBlock,
  recordedVoiceOverClip,
  voiceOverRecordingStart,
  type LiveVoiceBlock,
} from "../core/audio/voiceOverRecording";
import type { VoiceOverClip } from "../core/model";
import type { TransportState } from "../engine/protocol";
import type { RecordedVoiceOver } from "../record/voiceOverRecorder";
import type { EditorController } from "./controller";
import { fullTimeMap, type Edit } from "./edits";
import type { EditorStore } from "./store";

/** Append a recorded clip (`project.voiceOverClips.append(clip)`) — one undo step. */
export function addVoiceOverClip(clip: VoiceOverClip): Edit {
  return (p) => {
    if (p.voiceOverClips.some((c) => c.id === clip.id)) return null;
    p.voiceOverClips.push({ ...clip });
    return { label: "Record Voice Over" };
  };
}

/** What a recorder must offer the session (record/voiceOverRecorder.ts; fakes in tests). */
export interface VoiceOverRecorderLike {
  level(): number;
  anchor(wallMs: number): void;
  stop(discard?: boolean): Promise<RecordedVoiceOver | null>;
  onEnded: (() => void) | null;
}

/** Where a finished take goes. */
export interface VoiceOverMedia {
  /** Make `fileName` fetchable at `url` for the engine (playback + export) and the page. */
  register(fileName: string, url: string): void;
  /** Persist the file with the project (cloud: upload; local: nothing). Rejects with a user-facing Error. */
  persist(take: RecordedVoiceOver): Promise<void>;
  /** A reason this project cannot take a new recording (e.g. a team member's read-only media), or null. */
  blocker?(): string | null;
}

export interface VoiceOverSessionDeps {
  store: EditorStore;
  controller: EditorController;
  media: VoiceOverMedia;
  openRecorder(): Promise<VoiceOverRecorderLike>;
  /** The house "Voice Over" alert. */
  onAlert(message: string): void;
  /** `isRecording` (or the live samples) changed. */
  onChange?(): void;
  /** blob: URL for a finished file (tests stub it). */
  objectUrl?(file: Blob): string;
}

type Phase = "idle" | "starting" | "recording" | "stopping";

export class VoiceOverSession {
  private phase: Phase = "idle";
  private recorder: VoiceOverRecorderLike | null = null;
  private startSource = 0;
  private startOutput = 0;
  private samples: number[] = [];
  private meterTimer: ReturnType<typeof setInterval> | null = null;
  private unsubscribeTransport: (() => void) | null = null;
  private restoreLoop = false;
  private anchored = false;
  private sawPlaying = false;
  private disposed = false;
  /** The last take's persist promise (tests / harness await it). */
  lastPersist: Promise<void> | null = null;

  constructor(private readonly deps: VoiceOverSessionDeps) {}

  /** `isRecordingVoiceOver`. */
  get isRecording(): boolean {
    return this.phase === "recording";
  }

  /** `voiceOverRecordingStartTime` (SOURCE s) while recording. */
  get recordingStartTime(): number | null {
    return this.phase === "recording" ? this.startSource : null;
  }

  /** `liveVoiceOverSamples`. */
  get liveSamples(): readonly number[] {
    return this.samples;
  }

  /** toggleVoiceOverRecording. */
  async toggle(): Promise<void> {
    if (this.phase === "recording") {
      await this.stop({ resumePlayback: this.deps.controller.client?.transport?.playing ?? false });
    } else if (this.phase === "idle") {
      await this.start();
    }
  }

  /** startVoiceOverRecording. */
  async start(): Promise<void> {
    const { store, controller } = this.deps;
    const project = store.getState().project;
    const client = controller.client;
    if (this.phase !== "idle" || this.disposed || !project || !client) return;
    if (project.videoURL == null) return; // `guard project.videoURL != nil`
    const blocked = this.deps.media.blocker?.() ?? null;
    if (blocked) {
      this.deps.onAlert(blocked);
      return;
    }
    this.phase = "starting";
    let recorder: VoiceOverRecorderLike;
    try {
      recorder = await this.deps.openRecorder();
    } catch (error) {
      this.phase = "idle";
      this.changed();
      if (!this.disposed) this.deps.onAlert(error instanceof Error && error.message ? error.message : VOICE_OVER_START_FAILED_MESSAGE);
      return;
    }
    const current = store.getState().project;
    if (this.disposed || this.phase !== "starting" || controller.client !== client || !current) {
      this.phase = "idle";
      await recorder.stop(true);
      return;
    }
    this.recorder = recorder;
    this.startSource = voiceOverRecordingStart(current, store.playheadSource());
    this.startOutput = fullTimeMap(current).outputTime(this.startSource);
    this.samples = [];
    this.anchored = false;
    this.sawPlaying = false;
    this.phase = "recording";
    recorder.onEnded = () => void this.stop({ resumePlayback: false });
    this.meterTimer = setInterval(() => {
      if (this.phase !== "recording" || !this.recorder) return;
      this.samples = appendMeterSample(this.samples, this.recorder.level());
      this.changed();
    }, VOICE_OVER_METER_INTERVAL_MS);

    // Play once: the end of the timeline ends the take.
    this.restoreLoop = client.transport?.loop ?? true;
    if (this.restoreLoop) client.setLoop(false);
    this.unsubscribeTransport = client.onTransport((t) => this.onTransport(t));
    this.changed();
    if (client.transport?.playing) this.onTransport(client.transport);
    else client.play(); // `if !isPlaying { isPlaying = true }`
  }

  private onTransport(t: TransportState): void {
    if (this.phase !== "recording" || !this.recorder) return;
    if (t.playing) {
      if (!this.anchored) {
        // The wall time the timeline was (or will be) at the clip start.
        const rate = t.rate > 0 ? t.rate : 1;
        this.recorder.anchor(t.wallMs + ((this.startOutput - t.time) / rate) * 1000);
        this.anchored = true;
      }
      this.sawPlaying = true;
    } else if (this.sawPlaying) {
      // `if !playing, isRecordingVoiceOver { stopVoiceOverRecording(resumePlayback: false) }`
      void this.stop({ resumePlayback: false, reachedEnd: t.time >= t.duration - 1e-3 });
    }
  }

  /** stopVoiceOverRecording(discard: false, resumePlayback:). */
  async stop(opts: { resumePlayback: boolean; reachedEnd?: boolean }): Promise<void> {
    if (this.phase !== "recording" || !this.recorder) return;
    const { store, controller } = this.deps;
    const recorder = this.recorder;
    const clipStart = this.startSource;
    this.phase = "stopping";
    this.teardownLive();
    const client = controller.client;
    if (!opts.resumePlayback && client?.transport?.playing) client.pause();
    this.changed();

    let take: RecordedVoiceOver | null = null;
    try {
      take = await recorder.stop(false);
    } catch (error) {
      if (!this.disposed) this.deps.onAlert(error instanceof Error ? error.message : String(error));
    }
    this.recorder = null;
    // The Mac's end-of-playback: the playhead returns to the trim start.
    if (opts.reachedEnd && !this.disposed) controller.seek(0);
    this.phase = "idle";
    this.changed();
    if (!take || this.disposed) return;

    const project = store.getState().project;
    if (!project) return;
    const clip = recordedVoiceOverClip(project, { fileName: take.fileName, clipStart, finalizedDuration: take.duration });
    if (!clip) return; // too short: the Mac removes the file
    const url = (this.deps.objectUrl ?? ((f: Blob) => URL.createObjectURL(f)))(take.file);
    this.deps.media.register(take.fileName, url);
    // Persist BEFORE the clip lands: the file resolves (and reaches the
    // engine) synchronously, so the edit never names a file the engine lacks.
    this.lastPersist = this.deps.media.persist(take).catch((error: unknown) => {
      if (!this.disposed) this.deps.onAlert(error instanceof Error ? error.message : String(error));
    });
    store.apply(addVoiceOverClip(clip));
  }

  /** The timeline's live "Recording Voice Over" block for the playhead (OUTPUT s). */
  live(playheadOutput: number): LiveVoiceBlock | null {
    if (this.phase !== "recording") return null;
    const project = this.deps.store.getState().project;
    if (!project) return null;
    const map = fullTimeMap(project);
    return liveVoiceBlock(project, map, {
      startSource: this.startSource,
      currentSource: map.sourceTime(Math.max(0, playheadOutput)),
      samples: this.samples,
    });
  }

  /** Editor teardown: a take in progress is discarded. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    // "starting" discards when the microphone opens; "stopping" finishes and
    // drops its take (both check `disposed`).
    if (this.phase !== "recording") return;
    const recorder = this.recorder;
    this.recorder = null;
    this.teardownLive();
    this.phase = "idle";
    void recorder?.stop(true);
  }

  private teardownLive(): void {
    if (this.meterTimer) clearInterval(this.meterTimer);
    this.meterTimer = null;
    this.unsubscribeTransport?.();
    this.unsubscribeTransport = null;
    if (this.restoreLoop) this.deps.controller.client?.setLoop(true);
    this.restoreLoop = false;
    this.samples = [];
  }

  private changed(): void {
    if (!this.disposed) this.deps.onChange?.();
  }
}
