/**
 * The web's image library — CustomWallpaperStore, per browser.
 *
 * The Mac remembers every image picked with "Choose Image…" as a copy in
 * Application Support (`CaptureCat/Wallpapers/Custom`) and shows it as a
 * tile in the Background pane's Image grid, with "Set as Default" and
 * "Remove from Library". A browser has no such folder, so the library lives
 * in this browser's IndexedDB:
 *
 *   images  one record per image, keyed by the SHA-256 of its (browser-
 *           decodable, cloud-uploadable) bytes — adding the same picture
 *           twice returns the existing entry, like `CustomWallpaperStore.add`
 *   meta    `defaultBackground` → { sha256, type } — the Mac's
 *           UserDefaults `defaultBackgroundImagePath` / `defaultBackgroundType`
 *           (type is always "Wallpaper", as `setDefaultBackground` writes)
 *
 * Why IndexedDB (not OPFS, not the cloud): library images are small (≤ 64 MB
 * after normalization) and need metadata, newest-first listing and atomic
 * add/remove/default updates — a keyed object store does all of that in one
 * transaction, stores Blobs natively in every browser the editor supports
 * (Safari included) and needs no quota-accounted cloud storage for images
 * that no project uses yet. OPFS earns its keep for multi-GB streaming
 * writes (the recorder's takes live there), not for a handful of keyed
 * images. The library is private to this browser profile, like the Mac's is
 * to that Mac; an image a cloud project USES is uploaded into that project
 * (ProjectMedia), so the project never depends on this store.
 */

export interface LibraryImage {
  sha256: string;
  /** Display name (the picked file's name without extension). */
  name: string;
  /** Lowercased extension of `blob`. */
  ext: string;
  contentType: string;
  bytes: number;
  /** Epoch ms — the grid lists newest first. */
  addedAt: number;
  blob: Blob;
  /** ≤ 320 px preview (the Mac grid's CGImageSource thumbnail size); absent → use `blob`. */
  thumb?: Blob | null;
}

export interface DefaultBackground {
  sha256: string;
  /** ProjectSettings.BackgroundType raw value — "Wallpaper", as the Mac writes it. */
  type: "Wallpaper" | "Image";
}

/** Storage behind the library (IndexedDB in browsers, memory in tests). */
export interface LibraryBackend {
  all(): Promise<LibraryImage[]>;
  get(sha256: string): Promise<LibraryImage | undefined>;
  put(image: LibraryImage): Promise<void>;
  delete(sha256: string): Promise<void>;
  getMeta<T>(key: string): Promise<T | undefined>;
  setMeta(key: string, value: unknown | undefined): Promise<void>;
}

const DEFAULT_KEY = "defaultBackground";

export class ImageLibrary {
  private listeners = new Set<() => void>();
  private thumbUrls = new Map<string, string>();

  constructor(
    private readonly backend: LibraryBackend,
    private readonly opts: { now?: () => number; makeThumb?: (blob: Blob) => Promise<Blob | null>; channel?: BroadcastChannel | null } = {},
  ) {
    opts.channel?.addEventListener("message", () => this.emit(false));
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(broadcast = true): void {
    for (const l of [...this.listeners]) l();
    if (broadcast) {
      try {
        this.opts.channel?.postMessage("changed");
      } catch {
        // another tab closed its end — nothing to tell
      }
    }
  }

  /** Library images, newest first (CustomWallpaperStore.listItems order). */
  async list(): Promise<LibraryImage[]> {
    const all = await this.backend.all();
    return all.sort((a, b) => b.addedAt - a.addedAt || a.name.localeCompare(b.name));
  }

  get(sha256: string): Promise<LibraryImage | undefined> {
    return this.backend.get(sha256);
  }

  /** Remember an image. The same bytes twice → the existing entry (content de-dupe). */
  async add(image: { blob: Blob; name: string; ext: string; contentType: string; sha256: string }): Promise<LibraryImage> {
    const existing = await this.backend.get(image.sha256);
    if (existing) return existing;
    const thumb = this.opts.makeThumb ? await this.opts.makeThumb(image.blob).catch(() => null) : null;
    const record: LibraryImage = {
      sha256: image.sha256,
      name: image.name,
      ext: image.ext,
      contentType: image.contentType,
      bytes: image.blob.size,
      addedAt: this.opts.now ? this.opts.now() : Date.now(),
      blob: image.blob,
      thumb,
    };
    await this.backend.put(record);
    this.emit();
    return record;
  }

  /** "Remove from Library". Projects that use the image keep their own copy. */
  async remove(sha256: string): Promise<void> {
    await this.backend.delete(sha256);
    const def = await this.backend.getMeta<DefaultBackground>(DEFAULT_KEY);
    if (def?.sha256 === sha256) await this.backend.setMeta(DEFAULT_KEY, undefined);
    const url = this.thumbUrls.get(sha256);
    if (url) {
      URL.revokeObjectURL(url);
      this.thumbUrls.delete(sha256);
    }
    this.emit();
  }

  /** "Set as Default" (CustomWallpaperStore.setDefaultBackground — type Wallpaper). */
  async setDefault(sha256: string): Promise<void> {
    if (!(await this.backend.get(sha256))) return;
    await this.backend.setMeta(DEFAULT_KEY, { sha256, type: "Wallpaper" } satisfies DefaultBackground);
    this.emit();
  }

  async clearDefault(): Promise<void> {
    await this.backend.setMeta(DEFAULT_KEY, undefined);
    this.emit();
  }

  /** The image new projects start with — only while it is still in the library. */
  async defaultBackground(): Promise<{ image: LibraryImage; type: DefaultBackground["type"] } | null> {
    const def = await this.backend.getMeta<DefaultBackground>(DEFAULT_KEY);
    if (!def) return null;
    const image = await this.backend.get(def.sha256);
    return image ? { image, type: def.type === "Image" ? "Image" : "Wallpaper" } : null;
  }

  async defaultSha(): Promise<string | null> {
    return (await this.backend.getMeta<DefaultBackground>(DEFAULT_KEY))?.sha256 ?? null;
  }

  /** A tile URL for an image (cached object URL of its thumbnail, else the image). */
  thumbnailUrl(image: LibraryImage): string {
    let url = this.thumbUrls.get(image.sha256);
    if (!url) {
      url = URL.createObjectURL(image.thumb ?? image.blob);
      this.thumbUrls.set(image.sha256, url);
    }
    return url;
  }
}

// ── Backends ──────────────────────────────────────────────────────────────

export class MemoryLibraryBackend implements LibraryBackend {
  private images = new Map<string, LibraryImage>();
  private meta = new Map<string, unknown>();
  async all() {
    return [...this.images.values()];
  }
  async get(sha256: string) {
    return this.images.get(sha256);
  }
  async put(image: LibraryImage) {
    this.images.set(image.sha256, image);
  }
  async delete(sha256: string) {
    this.images.delete(sha256);
  }
  async getMeta<T>(key: string) {
    return this.meta.get(key) as T | undefined;
  }
  async setMeta(key: string, value: unknown) {
    if (value === undefined) this.meta.delete(key);
    else this.meta.set(key, value);
  }
}

const DB_NAME = "capturecat-image-library";
const DB_VERSION = 1;

function promisify<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export class IndexedDbLibraryBackend implements LibraryBackend {
  private db: Promise<IDBDatabase> | null = null;

  private open(): Promise<IDBDatabase> {
    if (!this.db) {
      this.db = new Promise((resolve, reject) => {
        const req = indexedDB.open(DB_NAME, DB_VERSION);
        req.onupgradeneeded = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains("images")) db.createObjectStore("images", { keyPath: "sha256" });
          if (!db.objectStoreNames.contains("meta")) db.createObjectStore("meta");
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
      this.db.catch(() => (this.db = null));
    }
    return this.db;
  }

  private async store(name: "images" | "meta", mode: IDBTransactionMode): Promise<IDBObjectStore> {
    return (await this.open()).transaction(name, mode).objectStore(name);
  }

  async all() {
    return promisify((await this.store("images", "readonly")).getAll() as IDBRequest<LibraryImage[]>);
  }
  async get(sha256: string) {
    return promisify((await this.store("images", "readonly")).get(sha256) as IDBRequest<LibraryImage | undefined>);
  }
  async put(image: LibraryImage) {
    await promisify((await this.store("images", "readwrite")).put(image));
  }
  async delete(sha256: string) {
    await promisify((await this.store("images", "readwrite")).delete(sha256));
  }
  async getMeta<T>(key: string) {
    return promisify((await this.store("meta", "readonly")).get(key) as IDBRequest<T | undefined>);
  }
  async setMeta(key: string, value: unknown) {
    const store = await this.store("meta", "readwrite");
    if (value === undefined) await promisify(store.delete(key));
    else await promisify(store.put(value, key));
  }
}

/** A ≤ 320 px PNG preview (keeps transparency, like the Mac's thumbnails). */
async function makeThumb(blob: Blob): Promise<Blob | null> {
  if (typeof createImageBitmap !== "function" || typeof OffscreenCanvas === "undefined") return null;
  const probe = await createImageBitmap(blob);
  const scale = Math.min(1, 320 / Math.max(probe.width, probe.height));
  const width = Math.max(1, Math.round(probe.width * scale));
  const height = Math.max(1, Math.round(probe.height * scale));
  probe.close();
  if (scale === 1 && blob.size < 512 * 1024) return null; // already small — use the image
  const bitmap = await createImageBitmap(blob, { resizeWidth: width, resizeHeight: height, resizeQuality: "high" });
  const canvas = new OffscreenCanvas(width, height);
  canvas.getContext("2d")?.drawImage(bitmap, 0, 0);
  bitmap.close();
  return canvas.convertToBlob({ type: "image/png" });
}

let shared: ImageLibrary | null = null;

/** This browser's library (IndexedDB; an in-memory one where IndexedDB is unavailable). */
export function imageLibrary(): ImageLibrary {
  if (!shared) {
    const hasIdb = typeof indexedDB !== "undefined";
    const channel = typeof BroadcastChannel !== "undefined" ? new BroadcastChannel(DB_NAME) : null;
    shared = new ImageLibrary(hasIdb ? new IndexedDbLibraryBackend() : new MemoryLibraryBackend(), { makeThumb, channel });
  }
  return shared;
}
