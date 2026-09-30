/**
 * Main thread ⇄ render worker message protocol.
 *
 * The main thread never waits on the GPU or the decoder: every command is a
 * fire-and-forget post; the few that answer (load, seek, snapshot, export)
 * carry a `requestId` and resolve a promise in `EngineClient`. Per-frame
 * state never crosses the boundary — the worker pushes a `transport` message
 * on state changes (the UI extrapolates the playhead from it) and `stats` at
 * 4 Hz.
 */
import type { WorkingSpace } from "./color";
import type { RenderMedia } from "./contract";
import type { Rect, Size } from "./layout";
import type { StreamStats } from "./media/videoStream";

// ── Main → worker ───────────────────────────────────────────────────────────

export interface ViewportSpec {
  /** CSS pixels of the stage canvas (the Mac's `previewCanvasSize`, in points). */
  cssWidth: number;
  cssHeight: number;
  dpr: number;
  /** Explicit backing size (tests/export parity); default round(css × dpr). */
  pixelWidth?: number;
  pixelHeight?: number;
  /** Reference canvas for spatial settings; default the CSS size (Mac editor semantics). */
  reference?: Size | null;
}

export type ToWorker =
  | { type: "init"; canvas: OffscreenCanvas; viewport: ViewportSpec }
  | { type: "load"; requestId: number; project: unknown; media: RenderMedia }
  | { type: "setProject"; project: unknown }
  /** Replace `RenderMedia.files` (a voice-over recorded in the editor, refreshed URLs). */
  | { type: "setMediaFiles"; files: Record<string, string> }
  | { type: "play" }
  | { type: "pause" }
  | { type: "seek"; requestId: number; time: number }
  | { type: "rate"; rate: number }
  | { type: "loop"; enabled: boolean }
  | { type: "resize"; viewport: ViewportSpec }
  | { type: "clock"; mediaTime: number; wallMs: number }
  | { type: "snapshot"; requestId: number; png?: boolean }
  | { type: "debug"; camera?: { zoom: number; focalX: number; focalY: number } | null; forceLayer?: boolean }
  | { type: "export"; requestId: number; options: ExportOptions }
  | { type: "exportCancel" }
  | { type: "resetStats" }
  | { type: "bench"; requestId: number; frames: number; refit: boolean }
  | { type: "dispose" };

export interface ExportOptions {
  /** Output-time range; default the whole timeline. */
  start?: number;
  end?: number;
  /** Override the project's export size / fps. */
  width?: number;
  height?: number;
  fps?: number;
  /** Reference canvas for canvasScale (the editor stage in points); null = output size (headless). */
  reference?: Size | null;
  codec?: "hevc" | "avc" | "auto";
  bitrate?: number;
  /** Output frame indices whose pre-encode RGBA should be returned (parity tests). */
  captureFrames?: number[];
  /** Container (`ExportSettings.Format`). The Mac writes an MPEG-4 file for "GIF" too. Default MP4. */
  format?: "MP4" | "MOV" | "GIF";
  /** Mux the project's audio mix (default true). */
  audio?: boolean;
  /** Return the pre-encode interleaved PCM mix (parity tests). */
  captureAudio?: boolean;
}

// ── Worker → main ───────────────────────────────────────────────────────────

export interface EngineCapabilities {
  adapter: { vendor: string; architecture: string; description: string };
  timestampQuery: boolean;
  canvasFormat: GPUTextureFormat;
}

export interface LoadedInfo {
  codec: string;
  codecString: string;
  width: number;
  height: number;
  /** AVAssetTrack.naturalSize (square-pixel, pre-rotation) — Auto Zoom's screen size / 2. */
  naturalSize: Size;
  fps: number;
  frameCount: number;
  mediaDuration: number;
  outputDuration: number;
  outputSize: Size;
  workingSpace: WorkingSpace;
  canvasColorSpace: PredefinedColorSpace;
  keyframeInterval: number;
  hasBFrames: boolean;
  hasAudio: boolean;
  hardwareDecode: boolean | null;
  unsupportedFeatures: string[];
}

export interface TransportState {
  playing: boolean;
  /** Output seconds at `wallMs`. */
  time: number;
  wallMs: number;
  rate: number;
  loop: boolean;
  duration: number;
}

export interface EngineStats {
  /** Presented frames per second over the last second. */
  fps: number;
  /** CPU encode ms per rendered frame over the last 120 renders. */
  frameMs: { median: number; p99: number; last: number };
  /** GPU ms per frame (timestamp queries), when available. */
  gpuMs: { median: number; p99: number; last: number } | null;
  /** Wall ms between presented frames while playing. */
  intervalMs: { median: number; p99: number };
  rendered: number;
  /** Ticks where the wanted frame was not decoded in time (a stale frame stayed up). */
  lateFrames: number;
  /** Source frames the playhead passed that were never presented (rate ≤ 1). */
  skippedFrames: number;
  displayedIndex: number;
  targetIndex: number;
  stream: StreamStats | null;
  gpuResidentBytes: number;
  staticBakeMs: number;
  clockSyncErrorMs: number;
}

export interface SnapshotResult {
  width: number;
  height: number;
  colorSpace: PredefinedColorSpace;
  /** RGBA8, row-major, premultiplied (as presented). */
  rgba: ArrayBuffer;
  png?: Blob;
  /** Geometry of what was drawn (Y-down px) + which source frame. */
  meta: {
    videoRect: Rect;
    contentRect: Rect;
    canvasScale: number;
    videoScale: number;
    frameIndex: number;
    outputTime: number;
  };
}

export interface ExportResult {
  buffer: ArrayBuffer;
  mimeType: string;
  codec: string;
  width: number;
  height: number;
  fps: number;
  frames: number;
  encodeMs: number;
  /** Source frame index rendered at each output frame (timing proof). */
  sourceIndices: number[];
  captures: { frame: number; rgba: ArrayBuffer }[];
  /** The muxed audio track (null: the project exports without audio). */
  audio: {
    codec: string;
    sampleRate: number;
    channels: number;
    frames: number;
    primingFrames: number;
    pcm?: ArrayBuffer;
  } | null;
}

export type FromWorker =
  | { type: "ready"; capabilities: EngineCapabilities }
  | { type: "error"; requestId?: number; code: string; message: string }
  | { type: "loaded"; requestId: number; info: LoadedInfo }
  | { type: "seeked"; requestId: number; time: number; frameIndex: number; superseded: boolean }
  | { type: "transport"; state: TransportState }
  | { type: "stats"; stats: EngineStats }
  | { type: "snapshot"; requestId: number; result: SnapshotResult }
  | { type: "exportProgress"; requestId: number; done: number; total: number }
  | { type: "exported"; requestId: number; result: ExportResult }
  | { type: "benchResult"; requestId: number; result: BenchResult }
  | { type: "frame"; info: FrameInfo };

/**
 * Geometry of the frame just presented — the web twin of the Mac preview's
 * per-frame `PreviewInteractionView.HitContext` inputs. Posted after every
 * rendered frame so on-canvas editing chrome (stage interactions) maps
 * pointer ↔ card space through the SAME camera the pixels used.
 */
export interface FrameInfo {
  outputTime: number;
  sourceTime: number;
  playing: boolean;
  /** Canvas backing-store size (device px) the rects below live in. */
  target: Size;
  canvasScale: number;
  /** Y-DOWN px, card (pre-camera) space. */
  contentRect: Rect;
  videoRect: Rect;
  /** Card → canvas homography (row-major Mat3, Y-down px). */
  camera: number[];
}

/** Saturated GPU cost: N back-to-back renders of the current frame, wall ms / N. */
export interface BenchResult {
  frames: number;
  refit: boolean;
  msPerFrame: number;
  target: { width: number; height: number };
  videoScale: number;
}
