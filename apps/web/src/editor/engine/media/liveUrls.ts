/**
 * Live media URLs — presigned GETs that are swapped while readers stay open.
 *
 * Cloud media URLs are short-lived presigned R2 GETs (~15 min). The editor
 * reads media LAZILY for as long as it is open: mediabunny's `UrlSource`
 * fetches byte ranges of the recording on every seek, the camera stream and
 * voice-overs do the same, and export re-reads sidecars and audio. A reader
 * built around a URL string must therefore keep working after that string
 * has expired, without being torn down (that would stop playback and drop
 * the decoder's caches).
 *
 * The indirection lives here, per JS realm (main thread and render worker
 * each have their own):
 *
 *   LiveUrlTable   one per owner (EngineClient, Engine). `update(entries)`
 *                  diffs by STABLE key (the project.json reference) and
 *                  records old URL → new URL aliases realm-wide.
 *   liveFetch      `fetch` that (1) follows the aliases, so a reader that
 *                  captured an old URL fetches the current one; (2) asks the
 *                  owner for fresh URLs BEFORE fetching when the table knows
 *                  they have expired; (3) on a 403 (R2's answer to an expired
 *                  presign) or a network rejection past expiry, asks for fresh
 *                  URLs and retries ONCE.
 *   liveUrlSource  mediabunny `UrlSource` whose every range request goes
 *                  through `liveFetch`.
 *
 * URLs that were never registered with an expiry (blob:, the dev server's
 * local media, the lab's fixtures) pass straight through to `fetch`.
 */
import { UrlSource, type UrlSourceOptions } from "mediabunny";

/** How long a reader waits for fresh URLs before giving up on its retry. */
export const LIVE_URL_REFRESH_TIMEOUT_MS = 20_000;
/** Treat URLs as expired this long before their stated expiry (clock skew). */
export const LIVE_URL_EXPIRY_SLACK_MS = 5_000;

type FetchLike = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

/** old URL → the URL that replaced it (realm-wide; chains are followed). */
const aliases = new Map<string, string>();
/** Every table that currently holds a URL, by that URL (two engines may share one). */
const owners = new Map<string, Set<LiveUrlTable>>();

function addOwner(url: string, table: LiveUrlTable): void {
  let set = owners.get(url);
  if (!set) owners.set(url, (set = new Set()));
  set.add(table);
}

function removeOwner(url: string, table: LiveUrlTable): void {
  const set = owners.get(url);
  if (!set) return;
  set.delete(table);
  if (set.size === 0) owners.delete(url);
}

/** The table that can refresh `url` (one with an expiry first). */
function ownerOf(url: string): LiveUrlTable | undefined {
  const set = owners.get(url);
  if (!set) return undefined;
  let any: LiveUrlTable | undefined;
  for (const table of set) {
    if (table.refreshable) return table;
    any ??= table;
  }
  return any;
}

/** The current URL for one that may have been replaced since it was handed out. */
export function currentUrl(url: string): string {
  let current = url;
  for (let hops = 0; hops < 64; hops++) {
    const next = aliases.get(current);
    if (next === undefined || next === current) return current;
    current = next;
  }
  return current;
}

export interface LiveUrlTableOptions {
  /** Ask the owner for fresh URLs (it answers later with `update`). */
  onExpired?: () => void;
  now?: () => number;
  refreshTimeoutMs?: number;
}

export class LiveUrlTable {
  private urls = new Map<string, string>();
  private expiresAt: number | null = null;
  private waiters = new Set<() => void>();
  private refreshing: Promise<boolean> | null = null;
  private disposed = false;

  constructor(private readonly opts: LiveUrlTableOptions = {}) {}

  private now(): number {
    return this.opts.now ? this.opts.now() : Date.now();
  }

  /**
   * Replace the table's URLs. `entries` is keyed by a STABLE identity (the
   * project.json reference); a key whose URL changed aliases the old URL to
   * the new one, so every open reader follows. `expiresAt` (epoch ms) marks
   * the URLs refreshable; null/undefined = they never expire.
   */
  update(entries: Record<string, string | undefined>, expiresAt?: number | null): void {
    if (this.disposed) return;
    let changed = false;
    for (const [key, url] of Object.entries(entries)) {
      if (!url) continue;
      const old = this.urls.get(key);
      if (old !== undefined && old !== url) {
        changed = true;
        aliases.set(old, url);
        // Anything that pointed at the old URL now points at the new one.
        for (const [from, to] of aliases) if (to === old) aliases.set(from, url);
        aliases.delete(url);
        if (![...this.urls.entries()].some(([k, u]) => k !== key && u === old)) removeOwner(old, this);
      }
      this.urls.set(key, url);
      addOwner(url, this);
    }
    if (expiresAt !== undefined && (expiresAt ?? null) !== this.expiresAt) {
      this.expiresAt = expiresAt ?? null;
      changed = true;
    }
    // Waiters want fresh URLs — an update that renewed nothing is not it.
    if (!changed) return;
    const woken = [...this.waiters];
    this.waiters.clear();
    for (const wake of woken) wake();
  }

  get(key: string): string | undefined {
    return this.urls.get(key);
  }

  /** The URLs carry an expiry (cloud presigned GETs). */
  get refreshable(): boolean {
    return this.expiresAt !== null;
  }

  /** Known to be past (or within the slack of) its expiry. */
  expired(now = this.now()): boolean {
    return this.expiresAt !== null && now >= this.expiresAt - LIVE_URL_EXPIRY_SLACK_MS;
  }

  /**
   * Ask for fresh URLs and wait until `url` has been replaced. Resolves true
   * when it was, false on timeout. Concurrent callers share one request.
   */
  refresh(url: string): Promise<boolean> {
    const before = currentUrl(url);
    const settled = () => currentUrl(url) !== before;
    if (!this.refreshing) {
      this.refreshing = new Promise<boolean>((resolve) => {
        const timeout = this.opts.refreshTimeoutMs ?? LIVE_URL_REFRESH_TIMEOUT_MS;
        let timer: ReturnType<typeof setTimeout> | null = null;
        const done = (ok: boolean) => {
          if (timer) clearTimeout(timer);
          this.waiters.delete(wake);
          this.refreshing = null;
          resolve(ok);
        };
        const wake = () => done(true);
        this.waiters.add(wake);
        timer = setTimeout(() => done(false), timeout);
        try {
          this.opts.onExpired?.();
        } catch {
          // The owner could not even ask — the timeout answers.
        }
      });
    }
    return this.refreshing.then(() => settled());
  }

  dispose(): void {
    this.disposed = true;
    for (const url of this.urls.values()) removeOwner(url, this);
    this.urls.clear();
    for (const wake of this.waiters) wake();
    this.waiters.clear();
  }
}

function urlOf(input: string | URL | Request): string | null {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.href;
  return null;
}

/**
 * `fetch` for media that may sit behind an expiring presigned URL (see the
 * module comment). Same signature as `fetch`; `base` is the real fetch
 * (tests inject a mock).
 */
export async function liveFetch(input: string | URL | Request, init?: RequestInit, base: FetchLike = (i, o) => fetch(i, o)): Promise<Response> {
  const original = urlOf(input);
  if (original === null) return base(input, init);
  let url = currentUrl(original);
  const table = ownerOf(url);
  if (!table || !table.refreshable) return base(url, init);

  // Known expired (a tab asleep past the refresh timer): refresh first.
  if (table.expired()) {
    await table.refresh(url);
    url = currentUrl(original);
  }
  let response: Response;
  try {
    response = await base(url, init);
  } catch (error) {
    // An expired presign can surface as a CORS/network rejection when the
    // error response carries no CORS headers — only retry when that is the
    // plausible cause.
    const owner = ownerOf(url) ?? table;
    if (!owner.expired() || !(await owner.refresh(url))) throw error;
    return base(currentUrl(original), init);
  }
  if (response.status !== 403) return response;
  // R2 answers an expired (or skewed) presign with 403 — refresh, retry once.
  const owner = ownerOf(url) ?? table;
  if (!(await owner.refresh(url))) return response;
  void response.body?.cancel().catch(() => undefined);
  return base(currentUrl(original), init);
}

/** Table key of the screen recording (media files are keyed by their project.json reference). */
export const VIDEO_KEY = "\u0000video";

/** A RenderMedia-shaped map as table entries. */
export function liveUrlEntries(media: { video?: string; files?: Record<string, string> }): Record<string, string | undefined> {
  return { ...(media.files ?? {}), [VIDEO_KEY]: media.video || undefined };
}

/** A mediabunny UrlSource whose range requests follow refreshed URLs. */
export function liveUrlSource(url: string, options: Omit<UrlSourceOptions, "fetchFn"> = {}): UrlSource {
  return new UrlSource(url, { ...options, fetchFn: ((i: string | URL | Request, o?: RequestInit) => liveFetch(i, o)) as typeof fetch });
}

/** Test hook: forget every alias and owner (tables are per test). */
export function resetLiveUrlsForTests(): void {
  aliases.clear();
  owners.clear();
}
