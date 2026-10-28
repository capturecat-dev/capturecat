/**
 * Messages between the main thread (segment/client.ts) and the camera
 * segmentation worker (segment/worker.ts). Plain structured-clone data.
 */
import type { MattingDevice } from "./model";

export type SegmentStage = "check" | "download" | "load" | "segment" | "encode";

export interface SegmentRequest {
  type: "segment";
  jobId: number;
  /** The camera recording (project.cameraVideoURL resolved to a fetchable URL). */
  cameraUrl: string;
  /** The project's current camera-mask.ccmask, when it has one (checked for staleness first). */
  maskUrl?: string;
  /** Only report whether the mask is fresh — never run the model (a member's editor). */
  checkOnly?: boolean;
  /** DEV/diagnostics: pin the delegate (default: GPU, else CPU). */
  device?: MattingDevice;
}

export interface SegmentProgress {
  type: "progress";
  jobId: number;
  stage: SegmentStage;
  /** download: model bytes so far / expected. */
  loaded?: number;
  total?: number;
  /** segment: camera frames done / total. */
  fraction?: number;
}

export interface SegmentStats {
  device: MattingDevice;
  frames: number;
  width: number;
  height: number;
  bytes: number;
  loadMs: number;
  segmentMs: number;
}

/** The existing mask matches the camera file — nothing to do. */
export interface SegmentFresh {
  type: "fresh";
  jobId: number;
}

/** checkOnly: the mask is missing or stale. */
export interface SegmentStale {
  type: "stale";
  jobId: number;
}

export interface SegmentDone {
  type: "done";
  jobId: number;
  /** camera-mask.ccmask bytes (transferred). */
  bytes: ArrayBuffer;
  stats: SegmentStats;
}

export interface SegmentFailed {
  type: "error";
  jobId: number;
  message: string;
}

export type SegmentReply = SegmentProgress | SegmentFresh | SegmentStale | SegmentDone | SegmentFailed;

// ── Main-thread API (implemented by client.ts) ─────────────────────────────

export type SegmentResult =
  | { kind: "fresh" }
  | { kind: "stale" }
  | { kind: "done"; bytes: Uint8Array; stats: SegmentStats };

export interface SegmentOptions {
  maskUrl?: string;
  checkOnly?: boolean;
  onProgress?(progress: SegmentProgress): void;
  signal?: AbortSignal;
  device?: MattingDevice;
}

export interface Segmenter {
  segment(cameraUrl: string, options?: SegmentOptions): Promise<SegmentResult>;
  dispose(): void;
}

export class SegmentationCancelled extends Error {
  constructor() {
    super("Background removal cancelled.");
    this.name = "SegmentationCancelled";
  }
}
