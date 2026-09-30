/**
 * MP4/MOV demux via mediabunny + a presentation-order frame index.
 *
 * The index (built once from packet METADATA — no sample data is read) is
 * what makes seeks frame-accurate: every frame's PTS, duration, key flag
 * and decode position, so "which frame is on screen at source time t" and
 * "which keyframe must decoding start from" are array lookups.
 */
import { ALL_FORMATS, EncodedPacketSink, Input, UrlSource, type EncodedPacket, type InputVideoTrack } from "mediabunny";
import { workingSpaceForPrimaries, type WorkingSpace } from "../color";
import { EngineCapabilityError } from "../gpu/device";

export interface FrameEntry {
  /** Presentation timestamp, seconds. */
  pts: number;
  duration: number;
  key: boolean;
  /** Position in decode order. */
  decodeIndex: number;
}

export interface VideoMediaInfo {
  codec: string; // "avc" | "hevc" | …
  codecString: string;
  width: number;
  height: number;
  /** AVAssetTrack.naturalSize: square-pixel (PAR-corrected), BEFORE rotation. */
  naturalWidth: number;
  naturalHeight: number;
  fps: number;
  duration: number;
  frameCount: number;
  colorSpace: VideoColorSpaceInit;
  workingSpace: WorkingSpace;
  keyframeInterval: number;
  hasBFrames: boolean;
  hasAudio: boolean;
  hardwareDecode: boolean | null;
}

/** Tolerance when comparing a time to a PTS (container timescales are integers; floats are not). */
export const PTS_EPSILON = 1e-6;

export class DemuxedVideo {
  private constructor(
    readonly url: string,
    readonly input: Input,
    readonly track: InputVideoTrack,
    readonly sink: EncodedPacketSink,
    readonly decoderConfig: VideoDecoderConfig,
    readonly frames: FrameEntry[],
    /** decode index → presentation index */
    readonly decodeToFrame: Int32Array,
    readonly info: VideoMediaInfo,
  ) {}

  static async open(url: string): Promise<DemuxedVideo> {
    const input = new Input({ formats: ALL_FORMATS, source: new UrlSource(url) });
    const track = await input.getPrimaryVideoTrack();
    if (!track) throw new Error("The recording has no video track.");
    const decoderConfig = await track.getDecoderConfig();
    const codec = (await track.getCodec()) ?? "unknown";
    if (!decoderConfig) {
      throw new EngineCapabilityError("codec-unsupported", `This browser cannot decode the recording's ${codec} video.`);
    }
    const support = await VideoDecoder.isConfigSupported(decoderConfig).catch(() => ({ supported: false }));
    if (!support.supported) {
      const hevcHint =
        codec === "hevc"
          ? " HEVC (H.265) decoding needs hardware support: Chrome/Edge on macOS 11+ or Windows with HEVC extensions, or Safari. Re-export the recording as H.264 to edit it here."
          : "";
      throw new EngineCapabilityError(
        "codec-unsupported",
        `This browser cannot decode the recording's ${codec} video (${decoderConfig.codec}).${hevcHint}`,
      );
    }
    // Probe whether the hardware path takes it (informational — the decoder
    // itself is configured "no-preference" so software can still carry it).
    const hw = await VideoDecoder.isConfigSupported({ ...decoderConfig, hardwareAcceleration: "prefer-hardware" })
      .then((r) => !!r.supported)
      .catch(() => null);

    const sink = new EncodedPacketSink(track);
    const decodeOrder: { pts: number; duration: number; key: boolean }[] = [];
    for await (const p of sink.packets(undefined, undefined, { metadataOnly: true })) {
      decodeOrder.push({ pts: p.timestamp, duration: p.duration, key: p.type === "key" });
    }
    if (decodeOrder.length === 0) throw new Error("The recording's video track is empty.");
    const frames: FrameEntry[] = decodeOrder
      .map((p, i) => ({ ...p, decodeIndex: i }))
      .sort((a, b) => a.pts - b.pts);
    const decodeToFrame = new Int32Array(decodeOrder.length);
    frames.forEach((f, i) => (decodeToFrame[f.decodeIndex] = i));
    const hasBFrames = frames.some((f, i) => f.decodeIndex !== i);

    const durations = frames.map((f) => f.duration).filter((d) => d > 0).sort((a, b) => a - b);
    const medianDur = durations.length ? durations[durations.length >> 1] : 1 / 30;
    const fps = Math.round((1 / medianDur) * 1000) / 1000;
    const last = frames[frames.length - 1];
    const duration = last.pts + (last.duration > 0 ? last.duration : medianDur) - frames[0].pts;
    const keys = decodeOrder.map((p, i) => (p.key ? i : -1)).filter((i) => i >= 0);
    const keyframeInterval = keys.length > 1 ? (keys[keys.length - 1] - keys[0]) / (keys.length - 1) : decodeOrder.length;
    const colorSpace = decoderConfig.colorSpace ?? (await track.getColorSpace());
    const audio = await input.getPrimaryAudioTrack();
    const naturalWidth = await track.getSquarePixelWidth();
    const naturalHeight = await track.getSquarePixelHeight();

    return new DemuxedVideo(url, input, track, sink, decoderConfig, frames, decodeToFrame, {
      codec,
      codecString: decoderConfig.codec,
      width: track.displayWidth,
      height: track.displayHeight,
      naturalWidth,
      naturalHeight,
      fps,
      duration,
      frameCount: frames.length,
      colorSpace: colorSpace ?? {},
      workingSpace: workingSpaceForPrimaries(colorSpace?.primaries ?? null),
      keyframeInterval,
      hasBFrames,
      hasAudio: !!audio,
      hardwareDecode: hw,
    });
  }

  /**
   * The frame on screen at source time `t`: the LAST frame whose PTS ≤ t
   * (the exporter's `while samplePTS <= sourceCMTime` walk). −1 before the
   * first frame (Mac: no sample yet → background only).
   */
  frameIndexAt(t: number): number {
    const f = this.frames;
    let lo = 0;
    let hi = f.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (f[mid].pts <= t + PTS_EPSILON) lo = mid + 1;
      else hi = mid;
    }
    return lo - 1;
  }

  /** Presentation index for a decoded frame's µs timestamp (−1 when unknown). */
  frameIndexForTimestamp(us: number): number {
    const i = this.frameIndexAt(us / 1e6 + 5e-7);
    if (i < 0) return -1;
    return Math.abs(this.frames[i].pts * 1e6 - us) < 2 ? i : -1;
  }

  /** Decode index to start from so presentation frame `index` is producible. */
  keyDecodeIndexFor(index: number): number {
    const target = this.frames[index];
    // Last key (decode order) at or before the target's decode position whose
    // PTS does not exceed the target's (closed-GOP safe; open-GOP leading
    // pictures still come out because we start at the previous key).
    for (let d = target.decodeIndex; d >= 0; d--) {
      const f = this.frames[this.decodeToFrame[d]];
      if (f.key && f.pts <= target.pts + PTS_EPSILON) return d;
    }
    return 0;
  }

  /** Full (data-bearing) key packet at decode index `d`. */
  async keyPacketAt(d: number): Promise<EncodedPacket> {
    const f = this.frames[this.decodeToFrame[d]];
    const p = await this.sink.getKeyPacket(f.pts + PTS_EPSILON, { verifyKeyPackets: true });
    if (!p) throw new Error(`No key packet at ${f.pts}s`);
    return p;
  }

  dispose(): void {
    this.input.dispose();
  }
}
