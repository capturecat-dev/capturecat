/**
 * The editor's share job — the web twin of the Mac's `ShareJobCenter` for the
 * open project: one job at a time (a second share never races an active
 * upload), states the export sheet and the top-bar Share button both render,
 * and the project's "shared" mark (its last link + video id, so a re-share
 * REPLACES the video in place like the Mac's `library.sharedVideoID`).
 *
 *   shareExported(file)  the sheet's "Share link after export" (and auto-sync)
 *   shareProject()       the top-bar Share: export an MP4, then upload
 *                        (ShareJobCenter.shareProject — comments off)
 *   retry()              re-runs the last failed job (reusing its file)
 *   copyLink()           the Copy button
 *
 * React-free: subscribe + snapshot for useSyncExternalStore.
 */
import { annotationMarkers } from "../core/export/shareMarkers";
import type { Project } from "../core/model";
import { runShareUpload, transcriptForShare, type ShareState, type ShareUploadInput } from "./share";

export interface ShareCenterDeps {
  /** The project as edited (markers + transcript come from it at share time). */
  project(): Project | null;
  /** Renders the project to an MP4 for the top-bar Share (progress 0…1). */
  exportMovie(onProgress: (fraction: number) => void, signal: AbortSignal): Promise<{ blob: Blob; fileName: string }>;
  /** Clipboard write (injectable for tests). */
  copy?(text: string): Promise<void>;
  /** Where the shared marks live (default: localStorage when available). */
  storage?: Pick<Storage, "getItem" | "setItem"> | null;
  /** Injectable upload runner (tests). */
  upload?: typeof runShareUpload;
}

interface SharedMark {
  url: string;
  videoId: string;
}

const MARKS_KEY = "capturecat.editor.sharedVideos";

export class ShareCenter {
  private state: ShareState = { phase: "idle" };
  private readonly listeners = new Set<() => void>();
  private last: Omit<ShareUploadInput, "replaceVideoId" | "annotations" | "transcript"> | null = null;
  private abort: AbortController | null = null;

  constructor(private readonly deps: ShareCenterDeps) {}

  // ── store ─────────────────────────────────────────────────────────────

  subscribe = (fn: () => void): (() => void) => {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  };

  getState = (): ShareState => this.state;

  private set(state: ShareState): void {
    this.state = state;
    for (const fn of this.listeners) fn();
  }

  get isActive(): boolean {
    const p = this.state.phase;
    return p === "exporting" || p === "uploading" || p === "completing";
  }

  /** The project's last share link (the Mac's "Copy Share Link"), if any. */
  sharedURL(): string | null {
    const id = this.deps.project()?.id;
    return id ? (this.marks()[id]?.url ?? null) : null;
  }

  // ── jobs ──────────────────────────────────────────────────────────────

  /** The sheet's share-after-export: upload the file the export just wrote. */
  async shareExported(file: Blob, fileName: string, opts: { commentsEnabled: boolean }): Promise<void> {
    if (this.isActive) return;
    const project = this.deps.project();
    if (!project) return;
    this.last = {
      file,
      fileName,
      durationSeconds: project.duration,
      commentsEnabled: opts.commentsEnabled,
      projectId: project.id,
      projectName: project.name,
    };
    await this.runUpload();
  }

  /** The top-bar Share: headless MP4 export of the project, then the upload. */
  async shareProject(): Promise<void> {
    if (this.isActive) return;
    const project = this.deps.project();
    if (!project) return;
    const abort = new AbortController();
    this.abort = abort;
    this.set({ phase: "exporting", progress: 0 });
    let file: { blob: Blob; fileName: string };
    try {
      file = await this.deps.exportMovie((p) => this.set({ phase: "exporting", progress: p }), abort.signal);
    } catch (e) {
      this.abort = null;
      if ((e as DOMException)?.name === "AbortError") return this.set({ phase: "idle" });
      return this.set({ phase: "failed", message: e instanceof Error ? e.message : String(e) });
    }
    this.last = {
      file: file.blob,
      fileName: file.fileName,
      durationSeconds: project.duration,
      commentsEnabled: false,
      projectId: project.id,
      projectName: project.name,
    };
    await this.runUpload();
  }

  /** Error → Retry: the same file again (or a fresh export if there is none). */
  async retry(): Promise<void> {
    if (this.isActive) return;
    if (this.last) await this.runUpload();
    else await this.shareProject();
  }

  /** Stops an in-flight export / upload (the job fails as cancelled). */
  cancel(): void {
    this.abort?.abort();
  }

  /** Clears a finished / failed job (the Mac card's dismiss). */
  dismiss(): void {
    if (!this.isActive) this.set({ phase: "idle" });
  }

  async copyLink(): Promise<boolean> {
    const url = this.state.phase === "done" ? this.state.url : this.sharedURL();
    if (!url) return false;
    const copy = this.deps.copy ?? ((text: string) => navigator.clipboard.writeText(text));
    try {
      await copy(url);
      return true;
    } catch {
      return false;
    }
  }

  private async runUpload(): Promise<void> {
    const last = this.last;
    const project = this.deps.project();
    if (!last || !project) return;
    const abort = new AbortController();
    this.abort = abort;
    const upload = this.deps.upload ?? runShareUpload;
    try {
      const result = await upload(
        {
          ...last,
          annotations: annotationMarkers(project),
          transcript: transcriptForShare(project),
          replaceVideoId: last.projectId ? (this.marks()[last.projectId]?.videoId ?? null) : null,
        },
        (s) => this.set(s),
        { signal: abort.signal },
      );
      if (last.projectId) this.saveMark(last.projectId, { url: result.url, videoId: result.videoId });
    } catch {
      // The state already says "failed" (runShareUpload reports it).
    } finally {
      this.abort = null;
    }
  }

  // ── shared marks ──────────────────────────────────────────────────────

  private storage(): Pick<Storage, "getItem" | "setItem"> | null {
    if (this.deps.storage !== undefined) return this.deps.storage;
    try {
      return typeof localStorage === "undefined" ? null : localStorage;
    } catch {
      return null;
    }
  }

  private marks(): Record<string, SharedMark> {
    try {
      const raw = this.storage()?.getItem(MARKS_KEY);
      const parsed = raw ? (JSON.parse(raw) as unknown) : null;
      return parsed && typeof parsed === "object" ? (parsed as Record<string, SharedMark>) : {};
    } catch {
      return {};
    }
  }

  private saveMark(projectId: string, mark: SharedMark): void {
    try {
      this.storage()?.setItem(MARKS_KEY, JSON.stringify({ ...this.marks(), [projectId]: mark }));
    } catch {
      // Storage full / blocked: the link still works, the next share is fresh.
    }
  }
}
