/**
 * Messages between the main thread (transcribe/client.ts) and the
 * transcription worker (transcribe/worker.ts). Plain structured-clone data.
 */
import type { TranscribedWord } from "../core/transcription/words";
import type { AsrDevice } from "./model";

export type TranscribeStage = "download" | "load" | "extract" | "transcribe";

export interface TranscribeRequest {
  type: "transcribe";
  jobId: number;
  /** The recording (project.videoURL resolved to a fetchable URL). */
  url: string;
  /** DEV/diagnostics: pin the runtime (default: WebGPU, else WASM). */
  device?: AsrDevice;
}

export interface TranscribeProgress {
  type: "progress";
  jobId: number;
  stage: TranscribeStage;
  /** download: bytes so far / expected (transformers.js aggregate). */
  loaded?: number;
  total?: number;
  /** transcribe: recording seconds done / total. */
  fraction?: number;
}

export interface TranscribeStats {
  device: AsrDevice;
  /** Seconds of recording audio. */
  audioSeconds: number;
  windows: number;
  /** Windows skipped as silence. */
  silentWindows: number;
  loadMs: number;
  extractMs: number;
  transcribeMs: number;
  /** Which recording audio track was read (index among the file's audio tracks). */
  trackIndex: number;
  trackCount: number;
}

export interface TranscribeDone {
  type: "done";
  jobId: number;
  /** Recording (SOURCE) seconds, in order. */
  words: TranscribedWord[];
  stats: TranscribeStats;
}

export interface TranscribeFailed {
  type: "error";
  jobId: number;
  /** User-facing, Mac wording (`TranscriptionError.errorDescription`). */
  message: string;
}

export type TranscribeReply = TranscribeProgress | TranscribeDone | TranscribeFailed;

// ── Main-thread API (implemented by client.ts; kept here so importers need
//    not pull in the worker — see state/subtitleGeneration.ts) ────────────

export type TranscriptionResult = Omit<TranscribeDone, "type" | "jobId">;

export interface TranscribeOptions {
  onProgress?(progress: TranscribeProgress): void;
  signal?: AbortSignal;
  device?: AsrDevice;
}

export interface Transcriber {
  transcribe(url: string, options?: TranscribeOptions): Promise<TranscriptionResult>;
  dispose(): void;
}

export class TranscriptionCancelled extends Error {
  constructor() {
    super("Transcription cancelled.");
    this.name = "TranscriptionCancelled";
  }
}
