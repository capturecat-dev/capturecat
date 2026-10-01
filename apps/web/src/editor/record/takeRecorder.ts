/**
 * Which engine records a take in this browser.
 *
 *   webcodecs      Chrome, Edge (and Firefox): mediabunny's MediaStream
 *                  sources → WebCodecs → QuickTime streamed into OPFS
 *                  (RecordingSession)
 *   mediarecorder  Safari: native MediaRecorder MP4, remuxed to QuickTime
 *                  (MediaRecorderSession) — WebKit crashes encoding the
 *                  worker-transferred frames the WebCodecs engine needs there
 *
 * The switch is capability-based, not a user-agent sniff: no main-thread
 * MediaStreamTrackProcessor + an MP4-capable MediaRecorder = Safari's shape.
 */
import type { TakeClock } from "./barHidden";
import { MediaRecorderSession, mediaRecorderMp4Supported } from "./mediaRecorderSession";
import { RecordingSession, type RecordedTake, type SessionState, type SessionStreams } from "./session";

export type RecorderEngine = "webcodecs" | "mediarecorder";

/** What both engines offer the page. */
export interface TakeRecorder {
  readonly id: string;
  state: SessionState;
  onSourceEnded: (() => void) | null;
  elapsed(now?: number): number;
  start(): Promise<void>;
  pause(): void;
  resume(): void;
  stop(): Promise<RecordedTake>;
  discard(): Promise<void>;
  releaseStreams(): void;
  /**
   * Log the page's recorder UI coming on screen (true) or leaving it (false)
   * at `at` (performance.now ms) — stop() turns the log into the take's
   * `uiReveals`, on its own media clock (barHidden.ts).
   */
  markUi(visible: boolean, at?: number): void;
  /** The media clock so far (zero, pauses), null before the first frame. */
  clock(now?: number): TakeClock | null;
}

export function recorderEngine(): RecorderEngine {
  const g = globalThis as unknown as Record<string, unknown>;
  const forced = g.__ccRecorderEngine; // DEV/test override
  if (forced === "webcodecs" || forced === "mediarecorder") return forced;
  const mainThreadProcessor = typeof g.MediaStreamTrackProcessor === "function";
  return !mainThreadProcessor && mediaRecorderMp4Supported() ? "mediarecorder" : "webcodecs";
}

export function createTakeRecorder(streams: SessionStreams, fps: number, id: string): TakeRecorder {
  return recorderEngine() === "mediarecorder"
    ? new MediaRecorderSession(streams, fps, id)
    : new RecordingSession(streams, fps, id);
}
