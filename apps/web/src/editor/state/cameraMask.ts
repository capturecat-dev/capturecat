/**
 * Camera background removal for the looks (docs/camera-cutout.md §6) — the
 * web's twin of the Mac's segmentation job, wired to the editor.
 *
 *  - Queued when a look is applied (Effects → Cutout / Pop-out card) and when
 *    a project that already uses a look opens, but only if the project has no
 *    FRESH camera-mask.ccmask (same camera byte size, duration within 0.05 s —
 *    the worker checks the header first and stops there when it matches).
 *  - Runs on this device (segment/worker.ts: MODNet over every camera frame),
 *    hands the bytes to the engine at once (the look draws before the upload
 *    lands), then uploads them as the project's file through
 *    `ProjectMedia.addFile` — owner only. A team member's editor only checks:
 *    when the mask is missing it says the owner has to open it.
 *  - Cancellable; a cancelled or failed run changes nothing (the looks keep
 *    drawing the plain bubble until a mask exists).
 */
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";

import { CAMERA_MASK_FILE } from "../core/mask/cameraMaskCodec";
import type { Project } from "../core/model";
import type { MattingDevice } from "../segment/model";
import { SegmentationCancelled, type SegmentProgress, type SegmentStats, type Segmenter } from "../segment/protocol";

export interface CameraMaskStatus {
  busy: boolean;
  /** 0…1 while frames are being processed; null when not measurable. */
  fraction: number | null;
  /** The progress line ("Removing background… 42%"). */
  progress: string;
  error: string | null;
  /** Not an error: why no mask is being made here (a team member's editor). */
  notice: string | null;
}

export const CAMERA_MASK_IDLE: CameraMaskStatus = { busy: false, fraction: null, progress: "", error: null, notice: null };

export const MEMBER_NOTICE =
  "Only the project's owner can remove the camera background. Cutout and Pop-out card show as the plain bubble until they open the project.";

/** The slices this needs (EditorStore, ProjectMedia, the engine client). */
export interface CameraMaskStore {
  getState(): { project: Project | null };
}
export interface CameraMaskMedia {
  mediaUrl(ref: string | null | undefined): string | undefined;
  readonly canAddFiles: boolean;
  addFile(file: { ref: string; path: string; blob: Blob; contentType: string }): Promise<void>;
}
export interface CameraMaskEngine {
  setCameraMask(bytes: Uint8Array): void;
}

async function browserSegmenter(): Promise<Segmenter> {
  if (import.meta.env.SSR) throw new Error("Background removal runs in the browser.");
  const { SegmentationClient } = await import("../segment/client");
  return new SegmentationClient();
}

export function segmentProgressText(p: SegmentProgress): string {
  switch (p.stage) {
    case "check":
      return "Checking the camera...";
    case "download": {
      const total = p.total ?? 0;
      if (total <= 0) return "Downloading model...";
      const pct = Math.min(100, Math.floor(((p.loaded ?? 0) / total) * 100));
      return `Downloading model... ${pct}% of ${Math.round(total / 1e6)} MB`;
    }
    case "load":
      return "Loading model...";
    case "segment":
      return `Removing background... ${Math.min(100, Math.floor((p.fraction ?? 0) * 100))}%`;
    case "encode":
      return "Saving mask...";
  }
}

/** Does the project use a camera look anywhere (a region's `look`)? */
export function projectUsesLook(project: Project | null): boolean {
  return !!project?.cameraVideoURL && project.cameraLayoutRegions.some((r) => r.look === "cutout" || r.look === "popOut");
}

export class CameraMaskJob {
  private status: CameraMaskStatus = CAMERA_MASK_IDLE;
  private listeners = new Set<() => void>();
  private abort: AbortController | null = null;
  private segmenter: Promise<Segmenter> | null = null;
  /** Camera reference a mask was made or confirmed fresh for in this session. */
  private settledFor: string | null = null;
  lastStats: SegmentStats | null = null;

  constructor(
    private readonly store: CameraMaskStore,
    private readonly media: () => CameraMaskMedia | null,
    private readonly engine: () => CameraMaskEngine | null,
    private readonly makeSegmenter: () => Segmenter | Promise<Segmenter> = browserSegmenter,
  ) {}

  getStatus = (): CameraMaskStatus => this.status;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  private set(status: CameraMaskStatus) {
    this.status = status;
    for (const l of [...this.listeners]) l();
  }

  /**
   * Make sure the project's looks have a fresh mask: check, and segment when
   * missing or stale. Resolves true when a fresh mask exists afterwards.
   */
  async ensure(opts: { device?: MattingDevice; force?: boolean } = {}): Promise<boolean> {
    const project = this.store.getState().project;
    if (!projectUsesLook(project)) return false;
    if (this.status.busy) return false;
    const cameraRef = project!.cameraVideoURL!;
    if (!opts.force && this.settledFor === cameraRef) return true;
    const media = this.media();
    if (!media) return false;
    const cameraUrl = media.mediaUrl(cameraRef);
    if (!cameraUrl) {
      this.set({ ...CAMERA_MASK_IDLE, error: "Background removal needs the camera recording, which isn't available here." });
      return false;
    }
    const owner = media.canAddFiles;
    const abort = new AbortController();
    this.abort = abort;
    this.set({ busy: true, fraction: null, progress: "Checking the camera...", error: null, notice: null });
    try {
      this.segmenter ??= Promise.resolve().then(this.makeSegmenter);
      const segmenter = await this.segmenter;
      if (abort.signal.aborted) return false;
      const result = await segmenter.segment(cameraUrl, {
        maskUrl: opts.force ? undefined : media.mediaUrl(CAMERA_MASK_FILE),
        checkOnly: !owner,
        device: opts.device,
        signal: abort.signal,
        onProgress: (p) => {
          if (!abort.signal.aborted) {
            this.set({ busy: true, fraction: p.stage === "segment" ? (p.fraction ?? 0) : null, progress: segmentProgressText(p), error: null, notice: null });
          }
        },
      });
      if (abort.signal.aborted) return false;
      if (result.kind === "fresh") {
        this.settledFor = cameraRef;
        this.set(CAMERA_MASK_IDLE);
        return true;
      }
      if (result.kind === "stale") {
        this.set({ ...CAMERA_MASK_IDLE, notice: MEMBER_NOTICE });
        return false;
      }
      this.lastStats = result.stats;
      // Draw with it now; the upload makes it the project's file.
      this.engine()?.setCameraMask(result.bytes);
      this.settledFor = cameraRef;
      this.set({ busy: true, fraction: 1, progress: "Uploading mask...", error: null, notice: null });
      try {
        await media.addFile({
          ref: CAMERA_MASK_FILE,
          path: CAMERA_MASK_FILE,
          blob: new Blob([result.bytes as BlobPart], { type: "application/octet-stream" }),
          contentType: "application/octet-stream",
        });
      } catch (error) {
        // The look keeps drawing here; other devices segment again.
        this.set({ ...CAMERA_MASK_IDLE, error: `The background mask could not be uploaded: ${error instanceof Error ? error.message : String(error)}` });
        return true;
      }
      this.set(CAMERA_MASK_IDLE);
      return true;
    } catch (error) {
      if (abort.signal.aborted || error instanceof SegmentationCancelled) return false;
      this.set({ ...CAMERA_MASK_IDLE, error: error instanceof Error ? error.message : String(error) });
      return false;
    } finally {
      if (this.abort === abort) this.abort = null;
    }
  }

  /** Stop the running job; nothing changes. */
  cancel(): void {
    const abort = this.abort;
    if (!abort) return;
    this.abort = null;
    abort.abort();
    this.set(CAMERA_MASK_IDLE);
  }

  dispose(): void {
    this.cancel();
    const segmenter = this.segmenter;
    this.segmenter = null;
    void segmenter?.then((s) => s.dispose(), () => undefined);
  }
}

/**
 * The editor page's segmentation job: one per page, disposed with it. Runs
 * once when a project that uses a look opens, and whenever `kick` is called
 * (a look was applied). `engine` is the live engine client (null until mounted).
 */
export function useCameraMask(
  store: CameraMaskStore,
  media: CameraMaskMedia | null | undefined,
  engine: () => CameraMaskEngine | null,
): { status: CameraMaskStatus; kick: () => void; cancel: () => void; job: CameraMaskJob } {
  const mediaRef = useRef(media ?? null);
  mediaRef.current = media ?? null;
  const engineRef = useRef(engine);
  engineRef.current = engine;
  const [job] = useState(() => new CameraMaskJob(store, () => mediaRef.current, () => engineRef.current()));
  useEffect(() => {
    if (import.meta.env.DEV) (window as unknown as { __editorCameraMask?: CameraMaskJob }).__editorCameraMask = job;
    return () => {
      job.dispose();
      if (import.meta.env.DEV) delete (window as unknown as { __editorCameraMask?: CameraMaskJob }).__editorCameraMask;
    };
  }, [job]);
  // A project that already uses a look: check (and segment) once it has loaded.
  const hasMedia = media != null;
  useEffect(() => {
    if (!hasMedia) return;
    if (projectUsesLook(store.getState().project)) void job.ensure();
  }, [hasMedia, job, store]);
  const status = useSyncExternalStore(job.subscribe, job.getStatus, job.getStatus);
  return useMemo(() => ({ status, kick: () => void job.ensure(), cancel: () => job.cancel(), job }), [status, job]);
}
