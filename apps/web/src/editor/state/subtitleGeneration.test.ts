import { describe, expect, it, vi } from "vitest";

import { newProject, serializeProjectText, type Project, type SubtitleSegment } from "../core/model";
import type { TranscribedWord } from "../core/transcription/words";
import {
  TranscriptionCancelled,
  type TranscribeOptions,
  type TranscribeStats,
  type Transcriber,
  type TranscriptionResult,
} from "../transcribe/protocol";
import { EditorStore } from "./store";
import { NO_SPEECH_MESSAGE, progressText, SubtitleGenerator } from "./subtitleGeneration";

const STATS: TranscribeStats = {
  device: "wasm",
  audioSeconds: 10,
  windows: 1,
  silentWindows: 0,
  loadMs: 1,
  extractMs: 1,
  transcribeMs: 1,
  trackIndex: 1,
  trackCount: 2,
};

const OLD: SubtitleSegment = { id: "AAAAAAAA-0000-4000-8000-000000000001", startTime: 1, endTime: 2, text: "old cue", words: [] };

function store(mut?: (p: Project) => void) {
  const p = newProject({ id: "11111111-2222-4333-8444-555555555555", duration: 20, videoURL: "recording.mov" });
  mut?.(p);
  const s = new EditorStore();
  s.load({ text: serializeProjectText(p), origin: "local", revision: null });
  return s;
}

/** A transcriber whose runs the test resolves / rejects by hand. */
class FakeTranscriber implements Transcriber {
  calls: { url: string; options: TranscribeOptions }[] = [];
  private settle: { resolve(r: TranscriptionResult): void; reject(e: unknown): void } | null = null;
  disposed = 0;

  transcribe(url: string, options: TranscribeOptions = {}): Promise<TranscriptionResult> {
    this.calls.push({ url, options });
    return new Promise((resolve, reject) => {
      this.settle = { resolve, reject };
      options.signal?.addEventListener("abort", () => reject(new TranscriptionCancelled()));
    });
  }
  /** Resolves once the generator has asked for run number `n` (it loads the client first). */
  async started(n = 1) {
    for (let i = 0; i < 100 && this.calls.length < n; i++) await new Promise((r) => setTimeout(r, 0));
    expect(this.calls.length).toBeGreaterThanOrEqual(n);
  }
  async finish(words: TranscribedWord[], n = 1) {
    await this.started(n);
    this.settle?.resolve({ words, stats: STATS });
  }
  async fail(message: string) {
    await this.started();
    this.settle?.reject(new Error(message));
  }
  dispose() {
    this.disposed++;
  }
}

const WORDS: TranscribedWord[] = [
  { startTime: 1.1, endTime: 1.5, text: "Hello" },
  { startTime: 1.5, endTime: 2.0, text: "world." },
  { startTime: 2.2, endTime: 2.6, text: "Again" },
];

function setup(mut?: (p: Project) => void) {
  const s = store(mut);
  const fake = new FakeTranscriber();
  const gen = new SubtitleGenerator(s, (ref) => `/media?ref=${ref}`, () => fake);
  return { s, fake, gen };
}

describe("SubtitleGenerator (Generate / Regenerate Subtitles)", () => {
  it("transcribes the project's recording and writes the cues as ONE undo step", async () => {
    const { s, fake, gen } = setup();
    const run = gen.generate();
    expect(gen.getStatus()).toEqual({ busy: true, progress: "Loading model...", error: null });
    await fake.started();
    expect(fake.calls[0].url).toBe("/media?ref=recording.mov");
    fake.calls[0].options.onProgress?.({ type: "progress", jobId: 1, stage: "transcribe", fraction: 0.5 });
    expect(gen.getStatus().progress).toBe("Transcribing... 50%");
    await fake.finish(WORDS);
    expect(await run).toBe(2);
    const cues = s.getState().project!.subtitles;
    expect(cues.map((c) => [c.startTime, c.endTime, c.text])).toEqual([
      [1.1, 2.0, "Hello world."],
      [2.2, 2.6, "Again"],
    ]);
    expect(gen.getStatus()).toEqual({ busy: false, progress: "Done — 2 subtitles", error: null });
    expect(s.getState().undoLabel).toBe("Generate Subtitles");
    s.undo();
    expect(s.getState().project!.subtitles).toEqual([]);
    expect(s.getState().canUndo).toBe(false);
  });

  it("Regenerate replaces the cues only after success; undo brings the old ones back", async () => {
    const { s, fake, gen } = setup((p) => (p.subtitles = [OLD]));
    const run = gen.generate("regenerate");
    // While running, the old cues are untouched.
    expect(s.getState().project!.subtitles).toEqual([OLD]);
    await fake.finish(WORDS);
    await run;
    expect(s.getState().project!.subtitles.map((c) => c.text)).toEqual(["Hello world.", "Again"]);
    expect(s.getState().undoLabel).toBe("Regenerate Subtitles");
    s.undo();
    expect(s.getState().project!.subtitles).toEqual([OLD]);
  });

  it("a failed Regenerate never deletes the existing cues", async () => {
    const { s, fake, gen } = setup((p) => (p.subtitles = [OLD]));
    const run = gen.generate("regenerate");
    await fake.fail("Audio extraction failed: No audio track found");
    expect(await run).toBeNull();
    expect(s.getState().project!.subtitles).toEqual([OLD]);
    expect(s.getState().canUndo).toBe(false);
    expect(gen.getStatus()).toEqual({ busy: false, progress: "", error: "Audio extraction failed: No audio track found" });
  });

  it("no speech → the cues stay and the pane says so", async () => {
    const { s, fake, gen } = setup((p) => (p.subtitles = [OLD]));
    const run = gen.generate("regenerate");
    await fake.finish([]);
    expect(await run).toBeNull();
    expect(s.getState().project!.subtitles).toEqual([OLD]);
    expect(gen.getStatus().error).toBe(NO_SPEECH_MESSAGE);
  });

  it("Cancel stops at once and changes nothing, even if the run would have finished", async () => {
    const { s, fake, gen } = setup((p) => (p.subtitles = [OLD]));
    const listener = vi.fn();
    gen.subscribe(listener);
    const run = gen.generate("regenerate");
    await fake.started();
    gen.cancel();
    expect(gen.getStatus()).toEqual({ busy: false, progress: "", error: null });
    expect(fake.calls[0].options.signal?.aborted).toBe(true);
    await fake.finish(WORDS); // too late
    expect(await run).toBeNull();
    expect(s.getState().project!.subtitles).toEqual([OLD]);
    expect(s.getState().canUndo).toBe(false);
    expect(listener).toHaveBeenCalled();
    // A new run works after a cancel.
    const again = gen.generate();
    await fake.finish(WORDS, 2);
    expect(await again).toBe(2);
  });

  it("ignores a second click while busy, and projects without a recording", async () => {
    const { fake, gen } = setup();
    const first = gen.generate();
    expect(await gen.generate()).toBeNull();
    await fake.finish(WORDS);
    expect(fake.calls).toHaveLength(1);
    await first;

    const bare = setup((p) => (p.videoURL = null));
    expect(await bare.gen.generate()).toBeNull();
    expect(bare.fake.calls).toHaveLength(0);
    expect(bare.gen.getStatus().busy).toBe(false);
  });

  it("reports a recording the page cannot fetch", async () => {
    const s = store();
    const gen = new SubtitleGenerator(s, () => undefined, () => new FakeTranscriber());
    expect(await gen.generate()).toBeNull();
    expect(gen.getStatus().error).toMatch(/^Audio extraction failed: /);
  });

  it("dispose cancels and releases the worker", async () => {
    const { fake, gen } = setup();
    const run = gen.generate();
    gen.dispose(); // before the client even loaded: it never gets asked
    expect(await run).toBeNull();
    await new Promise((r) => setTimeout(r, 0));
    expect(fake.disposed).toBe(1);
    expect(fake.calls).toHaveLength(0);

    const mid = setup();
    const running = mid.gen.generate();
    await mid.fake.started();
    mid.gen.dispose();
    expect(await running).toBeNull();
    await new Promise((r) => setTimeout(r, 0));
    expect(mid.fake.disposed).toBe(1);
    expect(mid.fake.calls[0].options.signal?.aborted).toBe(true);
  });
});

describe("progress copy (TranscriptionService.progress)", () => {
  it("names each stage", () => {
    expect(progressText({ type: "progress", jobId: 1, stage: "download", loaded: 52_000_000, total: 206_000_000 })).toBe(
      "Downloading model... 25% of 206 MB",
    );
    expect(progressText({ type: "progress", jobId: 1, stage: "load" })).toBe("Loading model...");
    expect(progressText({ type: "progress", jobId: 1, stage: "extract" })).toBe("Extracting audio...");
    expect(progressText({ type: "progress", jobId: 1, stage: "transcribe", fraction: 1 })).toBe("Transcribing... 100%");
  });
});
