/**
 * Persistent per-media-file cache for the timeline's filmstrip thumbnails
 * and waveform envelopes (IndexedDB; works in the media worker and on the
 * main thread). Keys are media IDENTITIES — a cloud file's SHA-256 or a URL
 * with its presigned query stripped (mediaIdentity.ts) — so reopening a
 * project, or the same recording in another project, is instant.
 *
 * Every failure (private mode, quota, blocked IDB) degrades to "no cache".
 */
const DB_NAME = "capturecat-timeline-media";
const STORE = "entries";
/** Entries kept; the least recently used beyond it are evicted. */
const MAX_ENTRIES = 96;

interface Row {
  key: string;
  usedAt: number;
  value: unknown;
}

let dbPromise: Promise<IDBDatabase | null> | null = null;

function open(): Promise<IDBDatabase | null> {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise<IDBDatabase | null>((resolve) => {
    try {
      if (typeof indexedDB === "undefined") return resolve(null);
      const req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains(STORE)) {
          const store = db.createObjectStore(STORE, { keyPath: "key" });
          store.createIndex("usedAt", "usedAt");
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
      req.onblocked = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
  return dbPromise;
}

function done(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => resolve();
    tx.onabort = () => resolve();
  });
}

export async function cacheGet<T>(key: string): Promise<T | null> {
  const db = await open();
  if (!db) return null;
  try {
    const tx = db.transaction(STORE, "readwrite");
    const store = tx.objectStore(STORE);
    const row = await new Promise<Row | undefined>((resolve) => {
      const r = store.get(key);
      r.onsuccess = () => resolve(r.result as Row | undefined);
      r.onerror = () => resolve(undefined);
    });
    if (row) store.put({ ...row, usedAt: Date.now() });
    await done(tx);
    return row ? (row.value as T) : null;
  } catch {
    return null;
  }
}

export async function cachePut(key: string, value: unknown): Promise<void> {
  const db = await open();
  if (!db) return;
  try {
    const tx = db.transaction(STORE, "readwrite");
    const store = tx.objectStore(STORE);
    store.put({ key, usedAt: Date.now(), value } satisfies Row);
    // LRU eviction beyond MAX_ENTRIES.
    const count = await new Promise<number>((resolve) => {
      const r = store.count();
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => resolve(0);
    });
    if (count > MAX_ENTRIES) {
      let excess = count - MAX_ENTRIES;
      const cursor = store.index("usedAt").openCursor();
      cursor.onsuccess = () => {
        const c = cursor.result;
        if (!c || excess <= 0) return;
        c.delete();
        excess--;
        c.continue();
      };
    }
    await done(tx);
  } catch {
    // quota / blocked — the next open simply decodes again
  }
}

/** Test/dev hook: drop everything (the perf harness measures cold generation). */
export async function cacheClear(): Promise<void> {
  const db = await open();
  if (!db) return;
  try {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).clear();
    await done(tx);
  } catch {
    // ignore
  }
}
