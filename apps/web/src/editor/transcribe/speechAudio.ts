/**
 * The audio the Mac transcribes, decoded in the browser (worker side).
 *
 * `TranscriptionService.extractAudio` reads
 * `asset.loadTracks(withMediaType: .audio).last` — "prefer mic track (last)
 * over system audio (first)": ScreenRecorder writes system audio first and
 * the microphone last; a web recording has one (mixed) track — through an
 * `AVAssetReaderTrackOutput` converting to 16 kHz mono PCM. Here: the same
 * track, demuxed by mediabunny and decoded by WebCodecs through the
 * engine's `PcmTrackReader` (the reader the playback/export mix uses: the
 * track's own timeline, AAC priming handled, any source rate served at
 * 48 kHz), averaged to mono and decimated to 16 kHz (core/audio/decimate).
 *
 * One deliberate difference: a trailing audio track with NO packets (a mic
 * input that never received a sample) is passed over for the one before it
 * — the Mac would transcribe that empty track into zero subtitles.
 *
 * Samples sit on the track's presentation timeline (a late first packet is
 * preceded by silence), so word times are recording = SOURCE seconds.
 */
import { ALL_FORMATS, EncodedPacketSink, Input, UrlSource, type InputAudioTrack } from "mediabunny";

import { decimate48kTo16k, decimationInputSpan, downmixStereo, SPEECH_SAMPLE_RATE } from "../core/audio/decimate";
import { PcmTrackReader } from "../engine/audio/pcm";

/** `TranscriptionError.audioExtractionFailed` — the Mac's wording. */
export class AudioExtractionError extends Error {
  constructor(detail: string) {
    super(`Audio extraction failed: ${detail}`);
    this.name = "AudioExtractionError";
  }
}

export class SpeechAudio {
  private constructor(
    private readonly input: Input,
    private readonly reader: PcmTrackReader,
    /** 16 kHz samples in the track. */
    readonly total: number,
    readonly trackIndex: number,
    readonly trackCount: number,
  ) {}

  static async open(url: string): Promise<SpeechAudio> {
    const input = new Input({ formats: ALL_FORMATS, source: new UrlSource(url) });
    try {
      let tracks: InputAudioTrack[];
      try {
        tracks = await input.getAudioTracks();
      } catch (error) {
        throw new AudioExtractionError(error instanceof Error ? error.message : String(error));
      }
      // `.last`, skipping trailing tracks that hold no samples at all.
      let index = tracks.length - 1;
      while (index > 0 && !(await new EncodedPacketSink(tracks[index]).getFirstPacket({ metadataOnly: true }))) index--;
      if (index < 0) throw new AudioExtractionError("No audio track found");
      const track = tracks[index];
      const reader = await PcmTrackReader.open(track);
      if (!reader) {
        const codec = (await track.getCodec()) ?? "unknown";
        throw new AudioExtractionError(`This browser can't decode the recording's ${codec} audio.`);
      }
      const total = Math.floor(reader.duration * SPEECH_SAMPLE_RATE);
      return new SpeechAudio(input, reader, total, index, tracks.length);
    } catch (error) {
      input.dispose();
      throw error;
    }
  }

  /** Seconds of audio. */
  get duration(): number {
    return this.total / SPEECH_SAMPLE_RATE;
  }

  /** 16 kHz mono samples [start, start + count) (zeros past the end). */
  async read(start: number, count: number): Promise<Float32Array> {
    const n = Math.max(0, Math.min(count, this.total - start));
    if (n <= 0) return new Float32Array(0);
    const span = decimationInputSpan(start, n);
    const [left, right] = await this.reader.read(span.start, span.end - span.start);
    return decimate48kTo16k(downmixStereo(left, right, left), span.start, start, n);
  }

  dispose(): void {
    this.reader.dispose();
    this.input.dispose();
  }
}
