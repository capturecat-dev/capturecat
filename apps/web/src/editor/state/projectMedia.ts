/**
 * ProjectMedia — one open project's media: reference → URL resolution that
 * stays valid for as long as the editor is open, plus the files the user
 * adds while editing (a background image, a watermark, a curtain logo).
 *
 *   mediaUrl(ref)   project.json reference → fetchable URL, in order:
 *                   0. while an old version is previewed (History), that
 *                      version's manifest (`setOverride` — its presigned GETs)
 *                   1. a file added this session (an object URL — renders at
 *                      once, no network)
 *                   2. CLOUD: the project's presigned GETs, kept fresh by
 *                      MediaUrlRefresher (refreshed before they expire)
 *                   3. LOCAL (dev server): the read-only Mac project folder
 *   addFile(…)      a new file: usable immediately; a CLOUD project stages
 *                   its complete manifest + the file, uploads, finalizes
 *                   (record/publish.ts `commitCloudFiles`, restage on expiry
 *                   included) — serialized, one commit at a time. A LOCAL
 *                   project's folder is read-only (vite/localProjects.ts), so
 *                   the file lives in this tab's memory for the session.
 *   settled()       resolves once every upload has finished — the page's
 *                   project.json save waits for it, so the cloud document
 *                   never references a file the cloud does not have yet.
 *   bindEngine(…)   pushes the engine's media map (EngineClient.setMediaFiles)
 *                   whenever URLs refresh, a file is added, or an edit
 *                   references a file the engine was not told about; and
 *                   answers the engine's "a URL expired" with a refresh.
 */
import type { Project } from "../core/model";
import { refsOf } from "../engine/media/assets";
import { commitCloudFiles } from "../record/publish";
import { sha256Blob } from "../record/sha256";
import { resolveMediaRef, type LoadedCloudProject, type ManifestFile, type MediaUrls } from "./cloud";
import { projectFilePath } from "./imageImport";
import { MediaUrlRefresher } from "./mediaRefresh";

export type SessionFileState = "local" | "uploading" | "committed" | "failed";

export interface SessionFile {
  /** The reference exactly as project.json spells it. */
  ref: string;
  /** Logical path in the project folder (the cloud manifest path). */
  path: string;
  blob: Blob;
  /** Object URL for the engine and thumbnails. */
  url: string;
  sha256: string;
  contentType: string;
  state: SessionFileState;
  error?: string;
  /** The upload's original error (a CloudApiError keeps its status for retry decisions). */
  cause?: unknown;
}

/** What the engine needs (EngineClient.setMediaFiles). */
export interface EngineMediaMap {
  video?: string;
  files: Record<string, string>;
  /** Epoch ms the cloud URLs expire (null: they never do). */
  expiresAt: number | null;
}

/** The slice of EngineClient this binds to. */
export interface MediaEngine {
  setMediaFiles(media: EngineMediaMap): void;
  onMediaExpired(listener: () => void): () => void;
}

/** The slice of EditorStore this watches for new references. */
export interface MediaStoreLike {
  subscribe(listener: () => void): () => void;
  getState(): { project: Project | null };
  documentJSON(): Record<string, unknown>;
}

export interface ProjectMediaOptions {
  projectId: string;
  origin: "cloud" | "local";
  /** CLOUD: the loaded project (its media URLs + access). */
  cloud?: LoadedCloudProject;
  /** LOCAL: the dev server's resolver. */
  localUrl?: (ref: string) => string | undefined;
  /** Refresher override (tests). */
  refresher?: MediaUrlRefresher;
  /** Upload override (tests). */
  commitFiles?: typeof commitCloudFiles;
  createObjectURL?: (blob: Blob) => string;
}

/** Files every project folder may hold that an added image must not shadow. */
const RESERVED_LOCAL_NAMES = ["thumbnail.jpg", "camera_poster.png", "project.json"];

export class ProjectMedia {
  readonly projectId: string;
  readonly origin: "cloud" | "local";
  readonly refresher: MediaUrlRefresher | null;
  private readonly cloudAccess: "owner" | "member" | null;
  private cloudName: string;
  private readonly localUrl: ((ref: string) => string | undefined) | null;
  private readonly commit: typeof commitCloudFiles;
  private readonly objectURL: (blob: Blob) => string;
  private session = new Map<string, SessionFile>();
  /** A previewed version's manifest (History): consulted before everything else. */
  private override: Pick<MediaUrls, "media" | "sources"> | null = null;
  private listeners = new Set<() => void>();
  private queue: Promise<void> = Promise.resolve();
  private pending = 0;

  constructor(opts: ProjectMediaOptions) {
    this.projectId = opts.projectId;
    this.origin = opts.origin;
    this.cloudAccess = opts.cloud?.access ?? null;
    this.cloudName = opts.cloud?.name ?? "Untitled";
    this.localUrl = opts.localUrl ?? null;
    this.commit = opts.commitFiles ?? commitCloudFiles;
    this.objectURL = opts.createObjectURL ?? ((blob) => URL.createObjectURL(blob));
    this.refresher =
      opts.refresher ??
      (opts.origin === "cloud" && opts.cloud
        ? new MediaUrlRefresher(opts.projectId, { media: opts.cloud.media, sources: opts.cloud.sources, urlsExpireAt: opts.cloud.urlsExpireAt })
        : null);
    this.refresher?.subscribe(() => this.emit());
  }

  // ── Resolution ────────────────────────────────────────────────────────

  /** The cloud's current URL set (null for a local project). */
  get urls(): MediaUrls | null {
    return this.refresher?.current ?? null;
  }

  /** project.json reference → fetchable URL (undefined = not available). */
  mediaUrl = (ref: string | null | undefined): string | undefined => {
    if (!ref) return undefined;
    if (this.override) {
      const pinned = resolveMediaRef(this.override, ref)?.url;
      if (pinned) return pinned;
    }
    const added = this.session.get(ref);
    if (added) return added.url;
    const urls = this.urls;
    if (urls) return resolveMediaRef(urls, ref)?.url;
    return this.localUrl?.(ref);
  };

  /** The SHA-256 of the file behind a reference, when known. */
  sha256Of(ref: string | null | undefined): string | undefined {
    if (!ref) return undefined;
    const added = this.session.get(ref);
    if (added) return added.sha256 || undefined; // "" while still hashing
    const urls = this.urls;
    return urls ? resolveMediaRef(urls, ref)?.sha256 : undefined;
  }

  private knownRefs = new Map<string, string>();

  /** Remember that `ref` (a file the project already has) holds these bytes — e.g. its wallpaper, once hashed. */
  rememberBackgroundRef(sha256: string, ref: string): void {
    this.knownRefs.set(sha256, ref);
    this.emit();
  }

  /** A reference to a file this project already holds with exactly these bytes, as a backgroundImagePath. */
  backgroundRefForSha(sha256: string): string | undefined {
    const known = this.knownRefs.get(sha256);
    if (known) return known;
    for (const f of this.session.values()) if (f.sha256 === sha256 && f.ref.startsWith("/")) return f.ref;
    const urls = this.urls;
    if (!urls) return undefined;
    for (const f of Object.values(urls.media)) {
      if (f.sha256 !== sha256 || !f.contentType.startsWith("image/")) continue;
      // The Mac's own spelling when it recorded one (its absolute path), so a
      // Mac that pulls the project finds the file it already has.
      return f.source && f.source.startsWith("/") ? f.source : projectFilePath(this.projectId, f.path);
    }
    return undefined;
  }

  /** The sha256 stored under a folder-relative file name (undefined = free). */
  takenBy = (fileName: string): string | undefined => {
    const lower = fileName.toLowerCase();
    for (const f of this.session.values()) if (f.path.toLowerCase() === lower) return f.sha256;
    const urls = this.urls;
    if (urls) {
      for (const f of Object.values(urls.media)) if (f.path.toLowerCase() === lower) return f.sha256;
    } else if (RESERVED_LOCAL_NAMES.includes(lower)) {
      return "";
    }
    return undefined;
  };

  /** New files can be added (a team member cannot change a project's media). */
  get canAddFiles(): boolean {
    return this.origin === "local" || this.cloudAccess === "owner";
  }

  /** Files added this session live only in this tab (a local project's folder is read-only). */
  get addsAreSessionOnly(): boolean {
    return this.origin === "local";
  }

  /**
   * Resolve media through an old version's manifest while it is previewed
   * (History → Preview): media that version used but the project has since
   * dropped (or replaced) still plays. Null restores the live resolution.
   * References the version's manifest lacks fall through to the live map.
   */
  setOverride(urls: Pick<MediaUrls, "media" | "sources"> | null): void {
    if (urls === this.override) return;
    this.override = urls;
    this.emit();
  }

  get hasOverride(): boolean {
    return this.override != null;
  }

  // ── Changes ───────────────────────────────────────────────────────────

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(): void {
    for (const l of [...this.listeners]) l();
  }

  /**
   * Begin keeping the cloud URLs fresh: the refresh timer, plus a check when
   * the tab becomes visible or the browser comes back online (timers sleep
   * with the tab). Returns `stop`.
   */
  start(): () => void {
    const refresher = this.refresher;
    if (!refresher) return () => undefined;
    const stop = refresher.start();
    const wake = () => {
      if (typeof document === "undefined" || document.visibilityState === "visible") void refresher.ensureFresh();
    };
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", wake);
    if (typeof window !== "undefined") window.addEventListener("online", wake);
    return () => {
      stop();
      if (typeof document !== "undefined") document.removeEventListener("visibilitychange", wake);
      if (typeof window !== "undefined") window.removeEventListener("online", wake);
    };
  }

  /** Refresh now (a reader hit an expired URL). */
  refreshNow(): Promise<boolean> {
    return this.refresher ? this.refresher.refreshNow() : Promise.resolve(true);
  }

  /** Refresh when close to expiry (tab woke up / came back online). */
  ensureFresh(): Promise<boolean> {
    return this.refresher ? this.refresher.ensureFresh() : Promise.resolve(true);
  }

  /** The project's display name for staging (the API stores it with the manifest). */
  setName(name: string): void {
    if (name.trim()) this.cloudName = name.trim();
  }

  // ── Adding files ──────────────────────────────────────────────────────

  /**
   * Add a file under `ref` (folder path `path`). It resolves through
   * `mediaUrl` immediately; the promise settles when it is persisted
   * (cloud: committed; local: at once) and rejects with the upload error.
   * `sha256` may be left out (a just-recorded voice over): it is hashed in
   * the upload queue. `url` reuses an object URL the caller already made.
   */
  addFile(file: { ref: string; path: string; blob: Blob; sha256?: string; contentType: string; url?: string }): Promise<void> {
    const existing = this.session.get(file.ref);
    if (file.sha256 && existing && existing.sha256 === file.sha256 && existing.state !== "failed") {
      return existing.state === "uploading" ? this.settled().then(() => this.throwIfFailed(file.ref)) : Promise.resolve();
    }
    const entry: SessionFile = {
      ...file,
      sha256: file.sha256 ?? "",
      url: file.url ?? (file.sha256 && existing?.sha256 === file.sha256 ? existing.url : this.objectURL(file.blob)),
      state: this.origin === "local" ? "local" : "uploading",
      cause: undefined,
    };
    this.session.set(file.ref, entry);
    this.emit();
    if (this.origin === "local") return Promise.resolve();
    this.pending++;
    const job = this.queue.then(() => this.upload());
    this.queue = job.catch(() => undefined);
    return job.then(() => this.throwIfFailed(file.ref));
  }

  private throwIfFailed(ref: string): void {
    const f = this.session.get(ref);
    if (f?.state === "failed") throw f.cause instanceof Error ? f.cause : new Error(f.error ?? "Upload failed.");
  }

  /** Resolves when every queued upload has finished (successfully or not). */
  settled(): Promise<void> {
    return this.queue;
  }

  get uploading(): boolean {
    return this.pending > 0;
  }

  /** The manifest the cloud keeps: every committed file + every file added this session. */
  private manifest(): ManifestFile[] {
    const byPath = new Map<string, ManifestFile>();
    for (const f of Object.values(this.urls?.media ?? {})) {
      byPath.set(f.path.toLowerCase(), { path: f.path, sha256: f.sha256, bytes: f.bytes, contentType: f.contentType, source: f.source });
    }
    for (const f of this.session.values()) {
      if (f.state === "local") continue;
      byPath.set(f.path.toLowerCase(), {
        path: f.path,
        sha256: f.sha256,
        bytes: f.blob.size,
        contentType: f.contentType,
        source: f.ref !== f.path ? f.ref : null,
      });
    }
    return [...byPath.values()];
  }

  private async upload(): Promise<void> {
    const batch = [...this.session.values()].filter((f) => f.state === "uploading" || f.state === "failed");
    if (batch.length === 0) {
      this.pending = Math.max(0, this.pending - 1);
      return;
    }
    for (const f of batch) {
      f.state = "uploading";
      f.error = undefined;
    }
    try {
      for (const f of batch) if (!f.sha256) f.sha256 = await sha256Blob(f.blob);
    } catch (error) {
      for (const f of batch) {
        f.state = "failed";
        f.error = error instanceof Error ? error.message : String(error);
      }
      this.pending = Math.max(0, this.pending - 1);
      this.emit();
      return;
    }
    const bySha = new Map(batch.map((f) => [f.sha256, f.blob]));
    try {
      await this.commit(this.projectId, { name: this.cloudName, manifest: this.manifest(), blobFor: (sha) => bySha.get(sha) });
      for (const f of batch) f.state = "committed";
      // Pick up the committed files' presigned URLs (and their sha/paths for
      // the next manifest). The session's object URLs keep serving them.
      void this.refresher?.refreshNow();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      for (const f of batch) {
        f.state = "failed";
        f.error = message;
        f.cause = error;
      }
    } finally {
      this.pending = Math.max(0, this.pending - 1);
      this.emit();
    }
  }

  // ── Engine ────────────────────────────────────────────────────────────

  private sent = new Set<string>();

  /** The engine's media map for `doc` — every reference ever sent stays in it (undo can bring one back). */
  engineMedia(doc: Record<string, unknown>): EngineMediaMap {
    const refs = refsOf(doc);
    for (const ref of [refs.cursor, refs.keystrokes, refs.camera, ...refs.images, ...refs.audio]) if (ref) this.sent.add(ref);
    for (const ref of this.session.keys()) this.sent.add(ref);
    const files: Record<string, string> = {};
    for (const ref of this.sent) {
      const url = this.mediaUrl(ref);
      if (url) files[ref] = url;
    }
    const videoRef = typeof doc.videoURL === "string" ? doc.videoURL : null;
    return { video: this.mediaUrl(videoRef), files, expiresAt: this.urls ? this.urls.urlsExpireAt : null };
  }

  /**
   * Keep an engine's media map current. Also watches the store: an edit
   * that references a file the engine has no URL for (undo into an added
   * image, an MCP edit naming a project file) pushes the map first.
   */
  bindEngine(engine: MediaEngine, store: MediaStoreLike): () => void {
    const push = () => engine.setMediaFiles(this.engineMedia(store.documentJSON()));
    const offMedia = this.subscribe(push);
    const offExpired = engine.onMediaExpired(() => void this.refreshNow());
    let last: Project | null = store.getState().project;
    const offStore = store.subscribe(() => {
      const project = store.getState().project;
      if (!project || project === last) return;
      last = project;
      const s = project.settings;
      const refs = [s.backgroundImagePath, s.watermarkFileName, s.curtainLogoFileName, ...project.voiceOverClips.map((c) => c.fileName)];
      if (refs.some((r) => typeof r === "string" && r && !this.sent.has(r) && this.mediaUrl(r))) push();
    });
    // Tell the engine the URLs' expiry now (it learned the URLs at load).
    push();
    return () => {
      offMedia();
      offExpired();
      offStore();
    };
  }

  dispose(): void {
    this.refresher?.stop();
    for (const f of this.session.values()) {
      try {
        URL.revokeObjectURL(f.url);
      } catch {
        // not an object URL (tests)
      }
    }
    this.listeners.clear();
  }
}
