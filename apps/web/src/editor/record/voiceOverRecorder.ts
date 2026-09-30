/**
 * The web twin of the Mac's `Services/VoiceOverRecorder.swift`: records the
 * microphone into a voice-over file while the editor plays.
 *
 * Format (VoiceOverRecorder's AVAudioRecorder settings): AAC-LC, 48 kHz,
 * mono, 192 kbps, in an MPEG-4 audio file named `voiceover-<UUID>.m4a` —
 * WebCodecs `AudioEncoder` through mediabunny. A browser without an AAC
 * encoder (Firefox) writes 16-bit PCM WAV (`voiceover-<UUID>.wav`, 48 kHz
 * mono) instead: lossless, and a format the Mac's AVFoundation (and the
 * cloud manifest, `wav` → audio/wav) already reads.
 *
 * Capture: getUserMedia (capture.ts `openMic`) → a 48 kHz AudioContext (the
 * device's own rate where the browser cannot resample a microphone) →
 * an AudioWorklet that down-mixes to mono and posts ~43 ms chunks stamped
 * with their capture-clock frame. The meter (`level()`) is the RMS of the
 * newest chunk — AVAudioRecorder's `pow(10, averagePower / 20)`.
 *
 * Alignment: the file's first sample is the instant the timeline left the
 * clip start (`anchor(wallMs)`): earlier samples are dropped, a microphone
 * that starts late is padded with silence — so what is said over a frame
 * lands on that frame.
 */
import { AudioSample, AudioSampleSource, BufferTarget, Mp4OutputFormat, Output, WavOutputFormat, canEncodeAudio } from "mediabunny";

import {
  VOICE_OVER_AAC_BITRATE,
  VOICE_OVER_CHANNELS,
  VOICE_OVER_MIN_DURATION,
  VOICE_OVER_PERMISSION_MESSAGE,
  VOICE_OVER_SAMPLE_RATE,
  VOICE_OVER_START_FAILED_MESSAGE,
  alignFirstChunk,
  meterLevel,
  voiceOverFileName,
  type VoiceOverFileExtension,
} from "../core/audio/voiceOverRecording";
import { newUUID } from "../core/model";
import { openMic, stopStream } from "./capture";

export interface VoiceOverEncoding {
  codec: "aac" | "pcm-s16";
  bitrate?: number;
  ext: VoiceOverFileExtension;
  contentType: "audio/mp4" | "audio/wav";
}

export interface RecordedVoiceOver {
  file: File;
  fileName: string;
  contentType: VoiceOverEncoding["contentType"];
  codec: VoiceOverEncoding["codec"];
  /** Seconds of audio written (48 kHz frames / 48 000). */
  duration: number;
}

/** Why recording could not start — maps to the Mac's two messages. */
export class VoiceOverStartError extends Error {
  constructor(
    readonly reason: "permission" | "unavailable",
    message: string,
  ) {
    super(message);
    this.name = "VoiceOverStartError";
  }
}

/** getUserMedia failure → the Mac's copy (ensureMicrophonePermission / AVAudioRecorder.record()). */
export function micStartError(error: unknown): VoiceOverStartError {
  const name = (error as { name?: string } | null)?.name;
  if (name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError") {
    return new VoiceOverStartError("permission", VOICE_OVER_PERMISSION_MESSAGE);
  }
  return new VoiceOverStartError("unavailable", VOICE_OVER_START_FAILED_MESSAGE);
}

let encodingProbe: Promise<VoiceOverEncoding> | null = null;

/** AAC at the Mac's 192 kbps when WebCodecs can, else AAC at 128 kbps, else PCM WAV. */
export function voiceOverEncoding(): Promise<VoiceOverEncoding> {
  const forced = (globalThis as { __ccVoiceOverCodec?: string }).__ccVoiceOverCodec; // DEV/test override
  if (forced === "pcm-s16") return Promise.resolve({ codec: "pcm-s16", ext: "wav", contentType: "audio/wav" });
  encodingProbe ??= (async () => {
    for (const bitrate of [VOICE_OVER_AAC_BITRATE, 128_000]) {
      const ok = await canEncodeAudio("aac", {
        numberOfChannels: VOICE_OVER_CHANNELS,
        sampleRate: VOICE_OVER_SAMPLE_RATE,
        bitrate,
      }).catch(() => false);
      if (ok) return { codec: "aac", bitrate, ext: "m4a", contentType: "audio/mp4" } as const;
    }
    return { codec: "pcm-s16", ext: "wav", contentType: "audio/wav" } as const;
  })();
  return encodingProbe;
}

/** ~43 ms at 48 kHz — the meter's window and the worklet's post size. */
const CHUNK = 2048;
/** Pre-anchor audio kept while the timeline starts (older chunks are dropped). */
const MAX_PENDING_CHUNKS = 96;

const WORKLET = `
class CCVoiceOverCapture extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.size = options.processorOptions.chunk;
    this.buf = new Float32Array(this.size);
    this.fill = 0;
    this.start = 0;
    this.done = false;
    this.port.onmessage = (e) => {
      if (e.data !== "flush" || this.done) return;
      this.done = true;
      const data = this.buf.slice(0, this.fill);
      this.port.postMessage({ frame: this.start, data, final: true }, [data.buffer]);
    };
  }
  process(inputs) {
    if (this.done) return false;
    const channels = inputs[0] || [];
    const n = channels.length ? channels[0].length : 128;
    const k = channels.length;
    for (let i = 0; i < n; i++) {
      let v = 0;
      for (let c = 0; c < k; c++) v += channels[c][i];
      if (k > 1) v /= k;
      if (this.fill === 0) this.start = currentFrame + i;
      this.buf[this.fill++] = v;
      if (this.fill === this.size) {
        const data = this.buf;
        this.port.postMessage({ frame: this.start, data, final: false }, [data.buffer]);
        this.buf = new Float32Array(this.size);
        this.fill = 0;
      }
    }
    return true;
  }
}
registerProcessor("cc-voice-over-capture", CCVoiceOverCapture);
`;

interface Chunk {
  frame: number;
  data: Float32Array;
}

export class VoiceOverRecorder {
  readonly fileName: string;
  /** Fired once if the microphone goes away mid-take (unplugged, revoked). */
  onEnded: (() => void) | null = null;

  private anchorFrame: number | null = null;
  private pending: Chunk[] = [];
  private started = false;
  private written = 0;
  private chain: Promise<void> = Promise.resolve();
  private encodeError: unknown = null;
  private lastLevel = 0;
  private finalChunk: ((c: Chunk | null) => void) | null = null;
  private stopped = false;
  private stopCalled = false;

  private constructor(
    private readonly stream: MediaStream,
    private readonly ctx: AudioContext,
    private readonly source: MediaStreamAudioSourceNode,
    private readonly node: AudioWorkletNode,
    private readonly sink: GainNode,
    private readonly output: Output,
    private readonly target: BufferTarget,
    private readonly audio: AudioSampleSource,
    readonly encoding: VoiceOverEncoding,
  ) {
    this.fileName = voiceOverFileName(newUUID(), encoding.ext);
    node.port.onmessage = (ev: MessageEvent<{ frame: number; data: Float32Array; final: boolean }>) => {
      const chunk = { frame: ev.data.frame, data: ev.data.data };
      if (ev.data.final) {
        this.finalChunk?.(chunk);
        return;
      }
      this.lastLevel = meterLevel(chunk.data);
      this.accept(chunk);
    };
    stream.getAudioTracks()[0]?.addEventListener("ended", () => {
      if (!this.stopped) this.onEnded?.();
    });
  }

  /**
   * Opens the microphone and the encoder. Rejects with VoiceOverStartError
   * (the Mac's "Microphone access is required…" / "Unable to start…").
   */
  static async open(opts: { deviceId?: string | null } = {}): Promise<VoiceOverRecorder> {
    if (typeof navigator === "undefined" || typeof navigator.mediaDevices?.getUserMedia !== "function") {
      throw new VoiceOverStartError("unavailable", VOICE_OVER_START_FAILED_MESSAGE);
    }
    let stream: MediaStream;
    try {
      stream = await openMic(opts.deviceId ?? null);
    } catch (error) {
      throw micStartError(error);
    }
    if (stream.getAudioTracks().length === 0) {
      stopStream(stream);
      throw new VoiceOverStartError("unavailable", VOICE_OVER_START_FAILED_MESSAGE);
    }
    let ctx: AudioContext | null = null;
    try {
      const encoding = await voiceOverEncoding();
      ctx = new AudioContext({ sampleRate: VOICE_OVER_SAMPLE_RATE, latencyHint: "interactive" });
      let source: MediaStreamAudioSourceNode;
      try {
        source = ctx.createMediaStreamSource(stream);
      } catch {
        // Firefox cannot resample a microphone into a context at another
        // rate: record at the device's rate (the file carries it; every
        // reader, the web's and the Mac's, resamples to 48 kHz).
        void ctx.close().catch(() => undefined);
        ctx = new AudioContext({ latencyHint: "interactive" });
        source = ctx.createMediaStreamSource(stream);
      }
      await ctx.resume().catch(() => undefined);
      const moduleUrl = URL.createObjectURL(new Blob([WORKLET], { type: "text/javascript" }));
      try {
        await ctx.audioWorklet.addModule(moduleUrl);
      } finally {
        URL.revokeObjectURL(moduleUrl);
      }
      const node = new AudioWorkletNode(ctx, "cc-voice-over-capture", {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: [1],
        channelCount: 2,
        channelCountMode: "max",
        processorOptions: { chunk: CHUNK },
      });
      // A silent path to the destination keeps the graph pulling the node.
      const sink = ctx.createGain();
      sink.gain.value = 0;
      source.connect(node);
      node.connect(sink);
      sink.connect(ctx.destination);

      const target = new BufferTarget();
      const output = new Output({
        format: encoding.codec === "aac" ? new Mp4OutputFormat({ fastStart: "in-memory" }) : new WavOutputFormat(),
        target,
      });
      const audio = new AudioSampleSource(
        encoding.codec === "aac" ? { codec: "aac", bitrate: encoding.bitrate } : { codec: "pcm-s16" },
      );
      output.addAudioTrack(audio, { name: "Voice Over" });
      await output.start();
      return new VoiceOverRecorder(stream, ctx, source, node, sink, output, target, audio, encoding);
    } catch {
      stopStream(stream);
      void ctx?.close().catch(() => undefined);
      throw new VoiceOverStartError("unavailable", VOICE_OVER_START_FAILED_MESSAGE);
    }
  }

  /** The meter (0…1): RMS of the newest ~43 ms. */
  level(): number {
    return this.lastLevel;
  }

  /** Seconds written to the file so far. */
  get duration(): number {
    return this.written / this.ctx.sampleRate;
  }

  /**
   * The timeline left the clip start at wall time `wallMs`
   * (performance.timeOrigin + performance.now() ms). Only the first call counts.
   */
  anchor(wallMs: number): void {
    if (this.anchorFrame !== null || this.stopped) return;
    const nowWall = performance.timeOrigin + performance.now();
    // The capture clock: the context's current frame is "now"; the mic's
    // own latency means a sample spoken at t arrives `latency` later.
    const latency = (this.stream.getAudioTracks()[0]?.getSettings() as { latency?: number } | undefined)?.latency ?? 0;
    const seconds = this.ctx.currentTime - (nowWall - wallMs) / 1000 + (Number.isFinite(latency) ? latency : 0);
    this.anchorFrame = Math.round(seconds * this.ctx.sampleRate);
    const pending = this.pending;
    this.pending = [];
    for (const c of pending) this.write(c);
  }

  private accept(chunk: Chunk): void {
    if (this.stopped) return;
    if (this.anchorFrame === null) {
      this.pending.push(chunk);
      if (this.pending.length > MAX_PENDING_CHUNKS) this.pending.shift();
      return;
    }
    this.write(chunk);
  }

  private write(chunk: Chunk): void {
    let data = chunk.data;
    if (!this.started) {
      const { skip, pad } = alignFirstChunk(chunk.frame, this.anchorFrame ?? chunk.frame);
      if (skip >= data.length) return;
      if (pad > 0) this.emit(new Float32Array(pad));
      data = skip > 0 ? data.slice(skip) : data;
      this.started = true;
    }
    this.emit(data);
  }

  private emit(pcm: Float32Array): void {
    if (pcm.length === 0) return;
    const rate = this.ctx.sampleRate;
    const timestamp = this.written / rate;
    this.written += pcm.length;
    const sample = new AudioSample({
      data: pcm,
      format: "f32",
      numberOfChannels: VOICE_OVER_CHANNELS,
      sampleRate: rate,
      timestamp,
    });
    this.chain = this.chain
      .then(() => this.audio.add(sample))
      .catch((e) => {
        this.encodeError ??= e;
      })
      .finally(() => sample.close());
  }

  /**
   * Stops the take. `discard` (or a take ≤ 0.1 s) → null, like
   * `VoiceOverRecorder.stopRecording(discard:)`; else the finished file.
   */
  async stop(discard = false): Promise<RecordedVoiceOver | null> {
    if (this.stopCalled) return null;
    this.stopCalled = true;
    // The worklet's partial chunk (≤ 43 ms) is part of the take.
    const last = discard
      ? null
      : await new Promise<Chunk | null>((resolve) => {
          const timer = setTimeout(() => resolve(null), 250);
          this.finalChunk = (c) => {
            clearTimeout(timer);
            resolve(c);
          };
          this.node.port.postMessage("flush");
        });
    this.stopped = true;
    this.finalChunk = null;
    this.release();
    if (discard) {
      await this.output.cancel().catch(() => undefined);
      return null;
    }
    // Never anchored (stopped before the timeline moved): keep what was heard.
    if (this.anchorFrame === null) {
      this.anchorFrame = this.pending[0]?.frame ?? last?.frame ?? 0;
      const pending = this.pending;
      this.pending = [];
      for (const c of pending) this.write(c);
    }
    if (last && last.data.length > 0) this.write(last);
    await this.chain;
    if (this.duration <= VOICE_OVER_MIN_DURATION || this.encodeError) {
      await this.output.cancel().catch(() => undefined);
      if (this.encodeError) throw new Error(`Voice-over encoding failed: ${String((this.encodeError as Error)?.message ?? this.encodeError)}`);
      return null;
    }
    this.audio.close();
    await this.output.finalize();
    const buffer = this.target.buffer;
    if (!buffer) return null;
    const file = new File([buffer], this.fileName, { type: this.encoding.contentType });
    return {
      file,
      fileName: this.fileName,
      contentType: this.encoding.contentType,
      codec: this.encoding.codec,
      duration: this.duration,
    };
  }

  private release(): void {
    try {
      this.source.disconnect();
      this.node.disconnect();
      this.sink.disconnect();
    } catch {
      /* already disconnected */
    }
    this.node.port.onmessage = null;
    stopStream(this.stream);
    void this.ctx.close().catch(() => undefined);
  }
}
