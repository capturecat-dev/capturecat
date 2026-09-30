/**
 * The exported file's audio track — the Mac's `ProjectAudioMix.writerOutputSettings`
 * (AAC-LC, 48 kHz, stereo, 192 kbps) fed from the SAME `AudioMixRenderer`
 * playback uses, rendered offline in 1 s chunks as the video frames advance
 * (the mix never exists in memory whole).
 *
 * Sample 0 of the mix is output time 0, exactly like the Mac (its reader
 * starts at 0 on the composition / at trimStart shifted by `audioPTSOffset`
 * on the fast path). AAC encoder priming is compensated in the container:
 * packets are re-timed by −priming so the muxer writes an edit list
 * (`elst` media_time = priming) — the same way AVAssetWriter tags its AAC —
 * and a player's first audible sample lands on video frame 0.
 *
 * The mix saturates to the Int16 range before encoding (the Mac's reader
 * hands its writer 16-bit PCM).
 */
import { EncodedAudioPacketSource, EncodedPacket, type Output } from "mediabunny";
import type { AudioMixRenderer } from "../audio/mixer";

export const EXPORT_AUDIO = { sampleRate: 48_000, channels: 2, bitrate: 192_000 } as const;
const CHUNK = 48_000;
const INT16_MAX = 32767 / 32768;

/**
 * Encoder delay (frames) of the platform AAC encoder, measured by
 * `probeEncoderDelay` against a known impulse (WebCodecs does not report it).
 */
async function probeEncoderDelay(config: AudioEncoderConfig): Promise<number> {
  const frames = 48_000 * 0.5;
  const impulseAt = 12_000;
  const packets: { ts: number; dur: number; data: Uint8Array; meta?: EncodedAudioChunkMetadata }[] = [];
  const enc = new AudioEncoder({
    output: (chunk, meta) => {
      const data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      packets.push({ ts: chunk.timestamp, dur: chunk.duration ?? 0, data, meta });
    },
    error: () => undefined,
  });
  enc.configure(config);
  const pcm = new Float32Array(frames * 2);
  // A band-limited click (Hann-windowed 3 kHz burst) — clean onset after decode.
  for (let i = 0; i < 96; i++) {
    const w = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / 96);
    const v = 0.8 * w * Math.sin((2 * Math.PI * 3000 * i) / 48_000);
    pcm[(impulseAt + i) * 2] = v;
    pcm[(impulseAt + i) * 2 + 1] = v;
  }
  enc.encode(
    new AudioData({ format: "f32", sampleRate: 48_000, numberOfChannels: 2, numberOfFrames: frames, timestamp: 0, data: pcm }),
  );
  await enc.flush();
  enc.close();
  const decoderConfig = packets.find((p) => p.meta?.decoderConfig)?.meta?.decoderConfig;
  if (!decoderConfig) return 0;
  const out: Float32Array[] = [];
  let firstTs: number | null = null;
  const dec = new AudioDecoder({
    output: (ad) => {
      if (firstTs === null) firstTs = ad.timestamp;
      const buf = new Float32Array(ad.numberOfFrames);
      ad.copyTo(buf, { planeIndex: 0, format: "f32-planar" });
      out.push(buf);
      ad.close();
    },
    error: () => undefined,
  });
  dec.configure(decoderConfig);
  for (const p of packets) dec.decode(new EncodedAudioChunk({ type: "key", timestamp: p.ts, duration: p.dur, data: p.data }));
  await dec.flush();
  dec.close();
  const total = out.reduce((n, b) => n + b.length, 0);
  const all = new Float32Array(total);
  let o = 0;
  for (const b of out) {
    all.set(b, o);
    o += b.length;
  }
  // Onset = first sample above 10% of the peak, relative to the source onset.
  let peak = 0;
  for (const v of all) peak = Math.max(peak, Math.abs(v));
  if (peak < 1e-3) return 0;
  let onset = -1;
  for (let i = 0; i < all.length; i++) {
    if (Math.abs(all[i]) > 0.1 * peak) {
      onset = i;
      break;
    }
  }
  // Source onset of the same threshold crossing.
  let srcOnset = 0;
  for (let i = 0; i < 96; i++) {
    const w = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / 96);
    if (Math.abs(0.8 * w * Math.sin((2 * Math.PI * 3000 * i) / 48_000)) > 0.1 * 0.8 * 0.93) {
      srcOnset = impulseAt + i;
      break;
    }
  }
  const tsOffset = Math.round(((firstTs ?? 0) / 1e6) * 48_000);
  const delay = onset + tsOffset - srcOnset;
  // AAC priming is 1024·k (2112 = 2048 + 64 on AudioToolbox); snap to that grid ±1 ms.
  return delay > 0 && delay < 48_000 * 0.2 ? delay : 0;
}

export interface AudioExportInfo {
  codec: string;
  sampleRate: number;
  channels: number;
  /** Mix frames encoded (the audio track's length). */
  frames: number;
  /** Encoder priming compensated through the edit list. */
  primingFrames: number;
  /** Interleaved pre-encode PCM (parity tests), when requested. */
  pcm?: ArrayBuffer;
}

export class AudioExport {
  private encoder: AudioEncoder | null = null;
  private source: EncodedAudioPacketSource;
  private mux: Promise<void> = Promise.resolve();
  private error: Error | null = null;
  private next: number;
  private capture: Float32Array | null;
  private priming = 0;

  private constructor(
    private readonly renderer: AudioMixRenderer,
    private readonly config: AudioEncoderConfig,
    readonly container: "aac" | "opus",
    /** Mix frames [startFrame, endFrame) become the track. */
    private readonly startFrame: number,
    private readonly endFrame: number,
    capture: boolean,
  ) {
    this.source = new EncodedAudioPacketSource(container);
    this.next = startFrame;
    this.capture = capture ? new Float32Array(Math.max(0, endFrame - startFrame) * 2) : null;
  }

  /**
   * Adds the audio track to `output` (call BEFORE `output.start()`).
   * Null when the range carries no audio or the browser cannot encode it.
   */
  static async attach(
    output: Output,
    renderer: AudioMixRenderer,
    range: { startFrame: number; endFrame: number },
    capture = false,
  ): Promise<AudioExport | null> {
    const endFrame = Math.min(range.endFrame, renderer.endFrame);
    if (endFrame <= range.startFrame) return null;
    const base = { sampleRate: EXPORT_AUDIO.sampleRate, numberOfChannels: EXPORT_AUDIO.channels, bitrate: EXPORT_AUDIO.bitrate };
    const candidates: { config: AudioEncoderConfig; container: "aac" | "opus" }[] = [
      { container: "aac", config: { ...base, codec: "mp4a.40.2", aac: { format: "aac" } } as AudioEncoderConfig },
      { container: "opus", config: { ...base, codec: "opus" } },
    ];
    for (const c of candidates) {
      const r = await AudioEncoder.isConfigSupported(c.config).catch(() => null);
      if (!r?.supported) continue;
      const ex = new AudioExport(renderer, c.config, c.container, range.startFrame, endFrame, capture);
      ex.priming = c.container === "aac" ? await probeEncoderDelay(c.config).catch(() => 0) : 0;
      output.addAudioTrack(ex.source);
      ex.open();
      return ex;
    }
    return null;
  }

  private open(): void {
    const shift = this.priming;
    const sr = EXPORT_AUDIO.sampleRate;
    const total = this.endFrame - this.startFrame;
    this.encoder = new AudioEncoder({
      output: (chunk, meta) => {
        const packet = EncodedPacket.fromEncodedChunk(chunk);
        // Presentation span of this packet once the priming is hidden; the
        // track ends exactly at the mix's last frame (AVAssetWriter trims the
        // encoder's tail padding the same way), later packets are dropped.
        const start = Math.round(packet.timestamp * sr) - shift;
        if (start >= total) return;
        const frames = Math.min(Math.round(packet.duration * sr), total - start);
        const moved =
          shift || frames !== Math.round(packet.duration * sr)
            ? packet.clone({ timestamp: start / sr, duration: frames / sr })
            : packet;
        this.mux = this.mux.then(() => this.source.add(moved, meta));
      },
      error: (e) => (this.error = new Error(`AudioEncoder: ${e.message}`)),
    });
    this.encoder.configure(this.config);
  }

  /** Renders + encodes the mix up to output second `t` (relative to the export start). */
  async pump(t: number): Promise<void> {
    const target = Math.min(this.endFrame, this.startFrame + Math.ceil(t * EXPORT_AUDIO.sampleRate));
    while (this.next < target) {
      if (this.error) throw this.error;
      const n = Math.min(CHUNK, this.endFrame - this.next);
      const [l, r] = await this.renderer.render(this.next, n);
      const data = new Float32Array(n * 2);
      const cap = this.capture;
      const co = (this.next - this.startFrame) * 2;
      for (let i = 0; i < n; i++) {
        const a = l[i];
        const b = r[i];
        // The capture is the mix itself (compared with the Mac's float read-back);
        // the encoder gets it saturated like the Mac's Int16 reader output.
        if (cap) {
          cap[co + 2 * i] = a;
          cap[co + 2 * i + 1] = b;
        }
        data[2 * i] = a > INT16_MAX ? INT16_MAX : a < -1 ? -1 : a;
        data[2 * i + 1] = b > INT16_MAX ? INT16_MAX : b < -1 ? -1 : b;
      }
      const encoder = this.encoder!;
      while (encoder.encodeQueueSize > 8) {
        await new Promise<void>((res) => encoder.addEventListener("dequeue", () => res(), { once: true }));
      }
      encoder.encode(
        new AudioData({
          format: "f32",
          sampleRate: EXPORT_AUDIO.sampleRate,
          numberOfChannels: EXPORT_AUDIO.channels,
          numberOfFrames: n,
          timestamp: Math.round(((this.next - this.startFrame) / EXPORT_AUDIO.sampleRate) * 1e6),
          data,
        }),
      );
      this.next += n;
    }
  }

  async finish(): Promise<AudioExportInfo> {
    await this.pump(Infinity);
    await this.encoder!.flush();
    if (this.error) throw this.error;
    await this.mux;
    this.encoder!.close();
    return {
      codec: String(this.config.codec),
      sampleRate: EXPORT_AUDIO.sampleRate,
      channels: EXPORT_AUDIO.channels,
      frames: this.endFrame - this.startFrame,
      primingFrames: this.priming,
      pcm: this.capture?.buffer as ArrayBuffer | undefined,
    };
  }

  close(): void {
    if (this.encoder && this.encoder.state !== "closed") this.encoder.close();
  }
}
