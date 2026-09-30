/**
 * Keeps a cloud project's presigned media URLs alive while the editor is open.
 *
 * The API hands out ~15-minute presigned GETs (GET_URL_TTL_SECONDS). This
 * schedules `refreshMediaUrls` MEDIA_URL_REFRESH_MARGIN_MS before they expire
 * (cloud.ts `mediaUrlsNeedRefresh`), retries with a short backoff when the
 * network is down, and refreshes immediately when a reader reports an
 * expired URL (`refreshNow`, deduped) or the tab wakes up (`ensureFresh`).
 * Every new set of URLs goes to the listeners — ProjectMedia, which pushes
 * them into the engine and the demuxers (engine/media/liveUrls.ts) without
 * restarting playback.
 *
 * Pure timers + an injected fetcher: the vitest suite drives it with fake
 * timers and a mocked fetch that expires URLs.
 */
import { MEDIA_URL_REFRESH_MARGIN_MS, mediaUrlsNeedRefresh, refreshMediaUrls, type MediaUrls } from "./cloud";

/** Backoff after a failed refresh (offline, API hiccup): 5 s, 15 s, 30 s, 60 s… */
const RETRY_MS = [5_000, 15_000, 30_000, 60_000];
/** Never schedule tighter than this (a server clock far behind ours). */
const MIN_DELAY_MS = 1_000;

export interface MediaUrlRefresherOptions {
  /** Fresh URLs for the project (default: GET /cloud-projects/:id/files). */
  fetchUrls?: () => Promise<MediaUrls>;
  now?: () => number;
  marginMs?: number;
}

export class MediaUrlRefresher {
  private urls: MediaUrls;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private inflight: Promise<boolean> | null = null;
  private failures = 0;
  private running = false;
  private listeners = new Set<(urls: MediaUrls) => void>();
  private readonly fetchUrls: () => Promise<MediaUrls>;

  constructor(
    readonly projectId: string,
    initial: MediaUrls,
    private readonly opts: MediaUrlRefresherOptions = {},
  ) {
    this.urls = initial;
    this.fetchUrls = opts.fetchUrls ?? (() => refreshMediaUrls(projectId));
  }

  private now(): number {
    return this.opts.now ? this.opts.now() : Date.now();
  }

  get current(): MediaUrls {
    return this.urls;
  }

  subscribe(listener: (urls: MediaUrls) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Start the refresh schedule. Returns `stop`. */
  start(): () => void {
    this.running = true;
    this.schedule();
    return () => this.stop();
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  /** Refresh if the URLs are within the margin of expiry (tab woke, came online). */
  ensureFresh(): Promise<boolean> {
    if (!mediaUrlsNeedRefresh(this.urls, this.now(), this.opts.marginMs ?? MEDIA_URL_REFRESH_MARGIN_MS)) {
      return Promise.resolve(true);
    }
    return this.refreshNow();
  }

  /** Fetch fresh URLs now (a reader hit an expired one). Concurrent calls share one request. */
  refreshNow(): Promise<boolean> {
    if (this.inflight) return this.inflight;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.inflight = (async () => {
      try {
        const next = await this.fetchUrls();
        this.urls = { media: next.media, sources: next.sources, urlsExpireAt: next.urlsExpireAt };
        this.failures = 0;
        for (const listener of [...this.listeners]) listener(this.urls);
        return true;
      } catch {
        this.failures++;
        return false;
      } finally {
        this.inflight = null;
        this.schedule();
      }
    })();
    return this.inflight;
  }

  /** Replace the URLs from another source (e.g. a project reload) and reschedule. */
  replace(urls: MediaUrls): void {
    this.urls = urls;
    this.failures = 0;
    for (const listener of [...this.listeners]) listener(this.urls);
    this.schedule();
  }

  private schedule(): void {
    if (!this.running) return;
    if (this.timer) clearTimeout(this.timer);
    const margin = this.opts.marginMs ?? MEDIA_URL_REFRESH_MARGIN_MS;
    let delay: number;
    if (this.failures > 0) {
      delay = RETRY_MS[Math.min(this.failures - 1, RETRY_MS.length - 1)];
    } else if (!Number.isFinite(this.urls.urlsExpireAt)) {
      delay = MIN_DELAY_MS;
    } else {
      delay = Math.max(MIN_DELAY_MS, this.urls.urlsExpireAt - margin - this.now());
    }
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.refreshNow();
    }, delay);
  }
}
