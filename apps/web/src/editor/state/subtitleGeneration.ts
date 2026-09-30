/**
 * Generate / Regenerate Subtitles — the web's `SubtitleSettingsPaneAppKit
 * .generate()` + `TranscriptionService` state (isTranscribing / progress /
 * error), wired to the editor store.
 *
 * Differences from the Mac, all on the side of not losing work:
 *  - Regenerate REPLACES the cues only after a successful run (the Mac
 *    empties `project.subtitles` first, so a failed run lost them). A run
 *    that recognizes no speech leaves the existing cues alone too.
 *  - The new cues land as ONE undo step ("Generate Subtitles" /
 *    "Regenerate Subtitles"); undo restores the previous cues.
 *  - Cancel stops the run at once and changes nothing.
 *
 * Cue times are recording seconds = SOURCE time (see
 * core/transcription/words.ts); the timeline and exporter retime them.
 */
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";

import type { Project } from "../core/model";
import { subtitlesFromWords } from "../core/transcription/words";
import type { AsrDevice } from "../transcribe/model";
import { TranscriptionCancelled, type TranscribeProgress, type TranscribeStats, type Transcriber } from "../transcribe/protocol";
import type { PaneActions } from "../ui/panes/types";

export interface SubtitleGenerationStatus {
  busy: boolean;
  /** TranscriptionService.progress */
  progress: string;
  /** TranscriptionService.error */
  error: string | null;
}

/** The slice of EditorStore generation writes through. */
export interface GenerationStore {
  getState(): { project: Project | null };
  transact<R>(label: string, recipe: (draft: Project) => R): R;
}

const IDLE: SubtitleGenerationStatus = { busy: false, progress: "", error: null };

export const NO_SPEECH_MESSAGE = "No speech was found in the recording.";

/**
 * The worker client, loaded on first use and only in the browser: the SSR
 * build then never bundles the transcription worker (transformers.js + ONNX
 * Runtime) into the server Worker.
 */
async function browserTranscriber(): Promise<Transcriber> {
  if (import.meta.env.SSR) throw new Error("Transcription runs in the browser.");
  const { TranscriptionClient } = await import("../transcribe/client");
  return new TranscriptionClient();
}

/** The pane's progress line for a worker update (the Mac's stage strings,
 *  plus the download and the share of the recording done). */
export function progressText(p: TranscribeProgress): string {
  switch (p.stage) {
    case "download": {
      const total = p.total ?? 0;
      if (total <= 0) return "Downloading model...";
      const pct = Math.min(100, Math.floor(((p.loaded ?? 0) / total) * 100));
      return `Downloading model... ${pct}% of ${Math.round(total / 1e6)} MB`;
    }
    case "load":
      return "Loading model...";
    case "extract":
      return "Extracting audio...";
    case "transcribe":
      return `Transcribing... ${Math.min(100, Math.floor((p.fraction ?? 0) * 100))}%`;
  }
}

export class SubtitleGenerator {
  private status: SubtitleGenerationStatus = IDLE;
  private listeners = new Set<() => void>();
  private abort: AbortController | null = null;
  /** The worker client, created on the first run (a promise: it loads lazily). */
  private transcriber: Promise<Transcriber> | null = null;
  /** The last successful run's numbers (diagnostics / DEV harness). */
  lastStats: TranscribeStats | null = null;

  constructor(
    private readonly store: GenerationStore,
    /** project.json media reference → fetchable URL. */
    private readonly resolveMedia: (ref: string) => string | undefined,
    private readonly makeTranscriber: () => Transcriber | Promise<Transcriber> = browserTranscriber,
  ) {}

  getStatus = (): SubtitleGenerationStatus => this.status;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private set(status: SubtitleGenerationStatus) {
    this.status = status;
    for (const l of [...this.listeners]) l();
  }

  /**
   * Transcribe the recording and store the cues. Resolves with the number of
   * cues written, or null when nothing was written (busy, no recording,
   * cancelled, failed — the status says which).
   */
  async generate(mode: "generate" | "regenerate" = "generate", opts: { device?: AsrDevice } = {}): Promise<number | null> {
    if (this.status.busy) return null;
    const project = this.store.getState().project;
    // `guard let videoURL = project.videoURL else { return }`
    if (!project?.videoURL) return null;
    const url = this.resolveMedia(project.videoURL);
    if (!url) {
      this.set({ busy: false, progress: "", error: "Audio extraction failed: The recording isn't available here." });
      return null;
    }
    const abort = new AbortController();
    this.abort = abort;
    this.set({ busy: true, progress: "Loading model...", error: null });
    try {
      this.transcriber ??= Promise.resolve().then(this.makeTranscriber);
      const transcriber = await this.transcriber;
      if (abort.signal.aborted) return null;
      const result = await transcriber.transcribe(url, {
        signal: abort.signal,
        device: opts.device,
        onProgress: (p) => {
          if (!abort.signal.aborted) this.set({ busy: true, progress: progressText(p), error: null });
        },
      });
      if (abort.signal.aborted) return null;
      this.set({ busy: true, progress: "Processing subtitles...", error: null });
      const segments = subtitlesFromWords(result.words);
      this.lastStats = result.stats;
      if (segments.length === 0) {
        this.set({ busy: false, progress: "", error: NO_SPEECH_MESSAGE });
        return null;
      }
      this.store.transact(mode === "regenerate" ? "Regenerate Subtitles" : "Generate Subtitles", (draft) => {
        draft.subtitles = segments;
      });
      this.set({ busy: false, progress: `Done — ${segments.length} subtitles`, error: null });
      return segments.length;
    } catch (error) {
      if (abort.signal.aborted || error instanceof TranscriptionCancelled) return null;
      this.set({ busy: false, progress: "", error: error instanceof Error ? error.message : String(error) });
      return null;
    } finally {
      if (this.abort === abort) this.abort = null;
    }
  }

  /** Stop the running transcription; the project is left untouched. */
  cancel(): void {
    const abort = this.abort;
    if (!abort) return;
    this.abort = null;
    abort.abort();
    this.set(IDLE);
  }

  /** Cancel and release the worker (reusable: a later run starts a new one). */
  dispose(): void {
    this.cancel();
    const transcriber = this.transcriber;
    this.transcriber = null;
    void transcriber?.then((t) => t.dispose(), () => undefined);
  }
}

/**
 * The Subtitles pane's generate actions for an editor page: one generator
 * per page, disposed with it. `mediaUrl` resolves project.json references
 * (LoadedEditorProject.mediaUrl); null until the project has loaded.
 */
export function useSubtitleGeneration(
  store: GenerationStore,
  mediaUrl: ((ref: string) => string | undefined) | null | undefined,
): Partial<PaneActions> {
  const media = useRef(mediaUrl);
  media.current = mediaUrl;
  const [generator] = useState(() => new SubtitleGenerator(store, (ref) => media.current?.(ref)));
  useEffect(() => {
    if (import.meta.env.DEV) (window as unknown as { __editorSubtitles?: SubtitleGenerator }).__editorSubtitles = generator;
    return () => {
      generator.dispose();
      if (import.meta.env.DEV) delete (window as unknown as { __editorSubtitles?: SubtitleGenerator }).__editorSubtitles;
    };
  }, [generator]);
  const status = useSyncExternalStore(generator.subscribe, generator.getStatus, generator.getStatus);
  return useMemo(
    () => ({
      onGenerateSubtitles: () => void generator.generate("generate"),
      onRegenerateSubtitles: () => void generator.generate("regenerate"),
      onCancelSubtitles: () => generator.cancel(),
      subtitleStatus: status,
    }),
    [generator, status],
  );
}
