/**
 * TEST-ONLY in-memory R2Bucket: what the cloud-project routes use (head /
 * get / put / delete), keeping `httpMetadata` and `customMetadata` the way R2
 * does — history snapshots are gzipped and say so in
 * `customMetadata.enc`, so a bucket that dropped metadata would hand the
 * reader compressed bytes. Never imported by Worker code.
 */

export interface StoredObject {
  bytes: Uint8Array;
  contentType?: string;
  customMetadata?: Record<string, string>;
}

export class MemoryBucket {
  objects = new Map<string, StoredObject>();

  put(
    key: string,
    value: Uint8Array | ArrayBuffer | string,
    opts?: { httpMetadata?: { contentType?: string }; customMetadata?: Record<string, string> },
  ) {
    const bytes =
      typeof value === "string"
        ? new TextEncoder().encode(value)
        : value instanceof Uint8Array
          ? new Uint8Array(value)
          : new Uint8Array(value);
    this.objects.set(key, {
      bytes,
      contentType: opts?.httpMetadata?.contentType,
      customMetadata: opts?.customMetadata ? { ...opts.customMetadata } : undefined,
    });
    return Promise.resolve({ key, size: bytes.byteLength });
  }

  async head(key: string) {
    const o = this.objects.get(key);
    return o
      ? { key, size: o.bytes.byteLength, etag: `etag-${o.bytes.byteLength}`, customMetadata: o.customMetadata ?? {} }
      : null;
  }

  async get(key: string) {
    const o = this.objects.get(key);
    if (!o) return null;
    const bytes = o.bytes;
    return {
      key,
      size: bytes.byteLength,
      etag: `etag-${bytes.byteLength}`,
      customMetadata: o.customMetadata ?? {},
      httpMetadata: { contentType: o.contentType },
      body: new Response(bytes).body!,
      text: async () => new TextDecoder().decode(bytes),
      arrayBuffer: async () => bytes.slice().buffer,
    };
  }

  async delete(keys: string | string[]) {
    for (const k of Array.isArray(keys) ? keys : [keys]) this.objects.delete(k);
  }

  /** Keys of document snapshots (`…/doc/…`), sorted. */
  docKeys(): string[] {
    return [...this.objects.keys()].filter((k) => k.includes("/doc/")).sort();
  }
}

/** Gunzip helper for assertions on stored snapshots. */
export async function gunzipText(bytes: Uint8Array): Promise<string> {
  const stream = new Response(bytes).body!.pipeThrough(new DecompressionStream("gzip"));
  return new TextDecoder().decode(await new Response(stream).arrayBuffer());
}
