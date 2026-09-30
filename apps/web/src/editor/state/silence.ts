/**
 * describe_project's silence analysis input in the browser — the Mac's
 * `MCPServer.computeSilence` decode half: every audio track of the recording
 * mixed to MONO at 8 kHz, then the shared `analyzeSilence` (webmcp/ops,
 * proved against the Mac) scans 50 ms RMS windows.
 *
 * Decode via mediabunny (WebCodecs AudioDecoder). The Mac resamples with
 * AVAssetReaderAudioMixOutput; here each 8 kHz output sample is the box
 * average of the source frames that fall in it (channels averaged, tracks
 * summed). Exact when the audio is already 8 kHz mono; otherwise windows
 * sitting right at the adaptive threshold can differ (see the ops report).
 */
import { ALL_FORMATS, AudioSampleSink, Input, UrlSource } from "mediabunny";

import { analyzeSilence, type SilenceOutcome } from "../webmcp/ops";

const RATE = 8000;
const cache = new Map<string, Promise<SilenceOutcome>>();

export function recordingSilence(url: string): Promise<SilenceOutcome> {
  let hit = cache.get(url);
  if (!hit) {
    hit = compute(url);
    cache.set(url, hit);
  }
  return hit;
}

async function compute(url: string): Promise<SilenceOutcome> {
  const input = new Input({ formats: ALL_FORMATS, source: new UrlSource(url) });
  try {
    const tracks = await input.getAudioTracks();
    if (tracks.length === 0) return { kind: "noAudio" };
    const duration = await input.computeDuration();
    const n = Math.max(0, Math.ceil(duration * RATE));
    const mix = new Float32Array(n);
    const sum = new Float64Array(n);
    const count = new Uint32Array(n);
    for (const track of tracks) {
      if (!(await track.canDecode())) return { kind: "failed", reason: "this browser cannot decode the recording's audio" };
      sum.fill(0);
      count.fill(0);
      const sink = new AudioSampleSink(track);
      for await (const sample of sink.samples()) {
        const frames = sample.numberOfFrames;
        const channels = sample.numberOfChannels;
        const planes: Float32Array[] = [];
        for (let c = 0; c < channels; c++) {
          const plane = new Float32Array(frames);
          sample.copyTo(plane, { planeIndex: c, format: "f32-planar" });
          planes.push(plane);
        }
        const t0 = sample.timestamp;
        const sr = sample.sampleRate;
        for (let j = 0; j < frames; j++) {
          const k = Math.floor((t0 + j / sr) * RATE);
          if (k < 0 || k >= n) continue;
          let v = 0;
          for (let c = 0; c < channels; c++) v += planes[c][j];
          sum[k] += v / channels;
          count[k]++;
        }
        sample.close();
      }
      for (let k = 0; k < n; k++) if (count[k] > 0) mix[k] += sum[k] / count[k];
    }
    return analyzeSilence(mix, tracks.length, RATE);
  } catch (error) {
    return { kind: "failed", reason: error instanceof Error ? error.message : String(error) };
  } finally {
    input.dispose();
  }
}
