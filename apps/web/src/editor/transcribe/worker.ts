/// <reference lib="webworker" />
/**
 * On-device transcription worker — the browser's `TranscriptionService`.
 * Created by transcribe/client.ts as
 * `new Worker(new URL("./worker.ts", import.meta.url), { type: "module" })`.
 *
 * Nothing leaves the device: the recording is decoded here (speechAudio.ts)
 * and Whisper runs here (transformers.js on ONNX Runtime Web — WebGPU, else
 * WASM). The only network traffic is the one-time model download from
 * huggingface.co, cached by the browser afterwards.
 *
 * Flow (the Mac's progress stages): probe the audio track first (a recording
 * without audio fails before a 200 MB download) → load the model → read the
 * recording 30 s window by window (core/transcription/windows: cut at the
 * quietest moment, silent windows skipped) → Whisper with word timestamps →
 * words in recording seconds. The main thread groups them into cues.
 */
import { env, pipeline } from "@huggingface/transformers";

import { SPEECH_SAMPLE_RATE } from "../core/audio/decimate";
import { isSilent, nextWindow, WINDOW_SECONDS } from "../core/transcription/windows";
import { wordsFromWhisperChunks, type TranscribedWord, type WhisperWordChunk } from "../core/transcription/words";
import { WHISPER_DTYPES, WHISPER_MODEL, type AsrDevice } from "./model";
import type { TranscribeReply, TranscribeRequest } from "./protocol";
import { SpeechAudio } from "./speechAudio";

declare const self: DedicatedWorkerGlobalScope;

// Hub only (never probe this site's /models/ path), browser Cache Storage on.
env.allowLocalModels = false;
env.allowRemoteModels = true;
env.useBrowserCache = true;

type AsrOutput = { text: string; chunks?: WhisperWordChunk[] };
type Asr = (audio: Float32Array, options: Record<string, unknown>) => Promise<AsrOutput | AsrOutput[]>;

let loaded: { asr: Asr; device: AsrDevice } | null = null;
let loading: Promise<{ asr: Asr; device: AsrDevice }> | null = null;

const post = (msg: TranscribeReply) => self.postMessage(msg);

async function webgpuUsable(): Promise<boolean> {
  const gpu = (navigator as Navigator & { gpu?: { requestAdapter(): Promise<unknown> } }).gpu;
  if (!gpu) return false;
  try {
    return (await gpu.requestAdapter()) != null;
  } catch {
    return false;
  }
}

const DTYPE_SUFFIX: Record<string, string> = { fp32: "", fp16: "_fp16", q8: "_quantized", q4: "_q4", q4f16: "_q4f16" };

/** Are this runtime's weights already in transformers.js's Cache Storage?
 *  (Its progress events look the same for a cache read and a download.) */
async function weightsCached(device: AsrDevice): Promise<boolean> {
  try {
    const cache = await caches.open(env.cacheKey);
    const urls = (await cache.keys()).map((r) => r.url).filter((u) => u.includes(`/${WHISPER_MODEL}/`));
    return Object.entries(WHISPER_DTYPES[device]).every(([file, dtype]) =>
      urls.some((u) => u.endsWith(`/onnx/${file}${DTYPE_SUFFIX[dtype] ?? ""}.onnx`)),
    );
  } catch {
    return false;
  }
}

function loadAsr(jobId: number, forced?: AsrDevice): Promise<{ asr: Asr; device: AsrDevice }> {
  if (loaded && (!forced || loaded.device === forced)) return Promise.resolve(loaded);
  loading ??= (async () => {
    const devices: AsrDevice[] = forced ? [forced] : (await webgpuUsable()) ? ["webgpu", "wasm"] : ["wasm"];
    let lastError: unknown = null;
    for (const device of devices) {
      try {
        const cached = await weightsCached(device);
        const asr = (await pipeline("automatic-speech-recognition", WHISPER_MODEL, {
          device,
          dtype: WHISPER_DTYPES[device] as never,
          progress_callback: (p: { status: string; loaded?: number; total?: number }) => {
            if (!cached && p.status === "progress_total" && p.total && p.loaded !== undefined) {
              const stage = p.loaded < p.total ? "download" : "load";
              post({ type: "progress", jobId, stage, loaded: p.loaded, total: p.total });
            }
          },
        })) as unknown as Asr;
        loaded = { asr, device };
        return loaded;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError instanceof Error ? lastError : new Error(String(lastError));
  })().finally(() => {
    loading = null;
  });
  return loading;
}

async function transcribe(req: TranscribeRequest): Promise<void> {
  const { jobId } = req;
  const t0 = performance.now();
  post({ type: "progress", jobId, stage: "load" });
  const audio = await SpeechAudio.open(req.url);
  try {
    let asr: Asr;
    let device: AsrDevice;
    try {
      ({ asr, device } = await loadAsr(jobId, req.device));
    } catch (error) {
      throw new Error(`Transcription failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    const t1 = performance.now();
    post({ type: "progress", jobId, stage: "extract" });

    const words: TranscribedWord[] = [];
    const full = WINDOW_SECONDS * SPEECH_SAMPLE_RATE;
    let extractMs = 0;
    let transcribeMs = 0;
    let windows = 0;
    let silentWindows = 0;
    let pos = 0;
    while (pos < audio.total) {
      const r0 = performance.now();
      const ahead = await audio.read(pos, Math.min(full, audio.total - pos));
      const plan = nextWindow(pos, audio.total, ahead);
      const samples = ahead.subarray(0, plan.end - plan.start);
      extractMs += performance.now() - r0;
      windows++;
      post({ type: "progress", jobId, stage: "transcribe", fraction: pos / Math.max(1, audio.total) });
      if (isSilent(samples)) {
        silentWindows++;
      } else {
        const a0 = performance.now();
        let out: AsrOutput;
        try {
          out = await runAsr(asr, samples);
        } catch (error) {
          // A GPU that loaded the model but cannot run it (driver / op
          // support): once, fall back to the CPU runtime and redo the window.
          if (device !== "webgpu" || req.device) throw error;
          loaded = null;
          ({ asr, device } = await loadAsr(jobId, "wasm"));
          out = await runAsr(asr, samples);
        }
        transcribeMs += performance.now() - a0;
        words.push(...wordsFromWhisperChunks(out.chunks ?? [], plan.start / SPEECH_SAMPLE_RATE, samples.length / SPEECH_SAMPLE_RATE));
      }
      pos = plan.end;
    }
    post({ type: "progress", jobId, stage: "transcribe", fraction: 1 });
    post({
      type: "done",
      jobId,
      words,
      stats: {
        device,
        audioSeconds: audio.duration,
        windows,
        silentWindows,
        loadMs: Math.round(t1 - t0),
        extractMs: Math.round(extractMs),
        transcribeMs: Math.round(transcribeMs),
        trackIndex: audio.trackIndex,
        trackCount: audio.trackCount,
      },
    });
  } finally {
    audio.dispose();
  }
}

async function runAsr(asr: Asr, samples: Float32Array): Promise<AsrOutput> {
  try {
    // English-only model (base.en): no `language` / `task` — the Mac's
    // `language: "en"` is implied. Greedy decoding (temperature 0), words.
    const out = await asr(samples, { return_timestamps: "word" });
    return Array.isArray(out) ? out[0] : out;
  } catch (error) {
    throw new Error(`Transcription failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}

self.onmessage = (event: MessageEvent<TranscribeRequest>) => {
  const req = event.data;
  if (req?.type !== "transcribe") return;
  transcribe(req).catch((error: unknown) => {
    post({ type: "error", jobId: req.jobId, message: error instanceof Error ? error.message : String(error) });
  });
};
