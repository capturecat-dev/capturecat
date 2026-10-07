/**
 * Where a share video's bytes live (migration 0029).
 *
 * A file is either in CaptureCat's own R2 bucket (`storage_id` NULL — every
 * row before 0029) or in a bucket the user connected (`storage_id` → a
 * `storage_buckets` row). Every route that presigns, HEADs, serves or deletes
 * a share video resolves an `ObjectStore` here instead of hard-coding the
 * `capturecat` bucket, so the two cases cannot drift apart.
 *
 * The user's secret access key is encrypted at rest with AES-GCM under
 * STORAGE_CREDENTIALS_KEY (base64, 32 bytes). The row id and uid are bound in
 * as additional data, so a ciphertext copied onto another row will not
 * decrypt. Without that secret the feature reports itself unavailable — it
 * never stores a key in clear.
 */

import type { Env } from "../types";
import {
  createPresignedDownloadUrl,
  deleteS3Object,
  type S3Connection,
} from "./presign";

/** CaptureCat's own bucket (wrangler.toml `bucket_name`). */
export const CAPTURECAT_BUCKET = "capturecat";

export const STORAGE_PROVIDERS = ["aws", "r2", "b2", "wasabi", "minio", "other"] as const;
export type StorageProvider = (typeof STORAGE_PROVIDERS)[number];

export interface StorageBucketRecord {
  id: string;
  uid: string;
  provider: StorageProvider;
  endpoint: string | null;
  region: string;
  bucket: string;
  pathPrefix: string;
  forcePathStyle: boolean;
  publicBaseUrl: string | null;
  accessKeyId: string;
  secretCiphertext: string;
  active: boolean;
  verifiedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

/** A bucket plus how to reach it. `storageId` null = CaptureCat R2. */
export interface ObjectStore {
  storageId: string | null;
  bucket: string;
  connection: S3Connection;
  /** Prepended to every new key in a custom bucket; "" for CaptureCat. */
  pathPrefix: string;
  /** Custom buckets only: serve `${publicBaseUrl}/${key}` instead of a
   *  presigned GET. */
  publicBaseUrl: string | null;
}

/** A custom bucket's row is gone or its key cannot be decrypted. */
export class StorageUnavailableError extends Error {
  constructor(message = "Your storage bucket is not available right now.") {
    super(message);
    this.name = "StorageUnavailableError";
  }
}

export function capturecatStore(env: Env): ObjectStore {
  return {
    storageId: null,
    bucket: CAPTURECAT_BUCKET,
    connection: {
      endpoint: env.R2_ENDPOINT,
      accessKeyId: env.R2_ACCESS_KEY_ID,
      secretAccessKey: env.R2_SECRET_ACCESS_KEY,
    },
    pathPrefix: "",
    publicBaseUrl: null,
  };
}

/** Whether the server can hold bucket credentials at all. */
export function customStorageAvailable(env: Env): boolean {
  try {
    return decodeKey(env.STORAGE_CREDENTIALS_KEY) !== null;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

interface StorageBucketRow {
  id: string;
  uid: string;
  provider: string;
  endpoint: string | null;
  region: string;
  bucket: string;
  path_prefix: string;
  force_path_style: number;
  public_base_url: string | null;
  access_key_id: string;
  secret_ciphertext: string;
  active: number;
  verified_at: string | null;
  created_at: string;
  updated_at: string;
}

function rowToBucket(row: StorageBucketRow): StorageBucketRecord {
  return {
    id: row.id,
    uid: row.uid,
    provider: (STORAGE_PROVIDERS as readonly string[]).includes(row.provider)
      ? (row.provider as StorageProvider)
      : "other",
    endpoint: row.endpoint,
    region: row.region,
    bucket: row.bucket,
    pathPrefix: row.path_prefix ?? "",
    forcePathStyle: row.force_path_style === 1,
    publicBaseUrl: row.public_base_url,
    accessKeyId: row.access_key_id,
    secretCiphertext: row.secret_ciphertext,
    active: row.active === 1,
    verifiedAt: row.verified_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export async function getStorageBucket(db: D1Database, id: string): Promise<StorageBucketRecord | null> {
  const row = await db.prepare("SELECT * FROM storage_buckets WHERE id = ?").bind(id).first<StorageBucketRow>();
  return row ? rowToBucket(row) : null;
}

export async function activeStorageBucket(db: D1Database, uid: string): Promise<StorageBucketRecord | null> {
  const row = await db
    .prepare("SELECT * FROM storage_buckets WHERE uid = ? AND active = 1")
    .bind(uid)
    .first<StorageBucketRow>();
  return row ? rowToBucket(row) : null;
}

export async function listStorageBuckets(db: D1Database, uid: string): Promise<StorageBucketRecord[]> {
  const { results } = await db
    .prepare("SELECT * FROM storage_buckets WHERE uid = ? ORDER BY created_at DESC")
    .bind(uid)
    .all<StorageBucketRow>();
  return (results ?? []).map(rowToBucket);
}

/** Distinct share videos with any file (any version, any status) in a bucket. */
export async function bucketVideoCount(db: D1Database, storageId: string): Promise<number> {
  const row = await db
    .prepare(
      `SELECT COUNT(*) AS n FROM (
         SELECT video_id FROM video_versions WHERE storage_id = ?1
         UNION
         SELECT video_id FROM shared_videos WHERE storage_id = ?1
       )`
    )
    .bind(storageId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

// ---------------------------------------------------------------------------
// Resolving a store
// ---------------------------------------------------------------------------

/** The store a file recorded with `storageId` lives in. */
export async function storeFor(env: Env, storageId: string | null | undefined): Promise<ObjectStore> {
  if (!storageId) return capturecatStore(env);
  const record = await getStorageBucket(env.DB, storageId);
  if (!record) throw new StorageUnavailableError("The bucket this video was stored in is no longer connected.");
  return storeFromRecord(env, record);
}

export async function storeFromRecord(env: Env, record: StorageBucketRecord): Promise<ObjectStore> {
  let secretAccessKey: string;
  try {
    secretAccessKey = await decryptSecret(env, record.secretCiphertext, aadFor(record.id, record.uid));
  } catch {
    throw new StorageUnavailableError();
  }
  return {
    storageId: record.id,
    bucket: record.bucket,
    connection: {
      endpoint: record.endpoint ?? undefined,
      region: record.region,
      forcePathStyle: record.forcePathStyle,
      accessKeyId: record.accessKeyId,
      secretAccessKey,
    },
    pathPrefix: record.pathPrefix,
    publicBaseUrl: record.publicBaseUrl,
  };
}

/**
 * Where a NEW share upload goes: the user's active bucket when their plan
 * includes custom storage, otherwise CaptureCat R2. A downgraded user with a
 * bucket still connected uploads to CaptureCat again (and their quota
 * applies); their existing files keep playing from their bucket.
 */
export async function uploadStoreFor(
  env: Env,
  uid: string,
  plan: { features: { customStorage: boolean } }
): Promise<ObjectStore> {
  if (!plan.features.customStorage) return capturecatStore(env);
  const record = await activeStorageBucket(env.DB, uid);
  return record ? storeFromRecord(env, record) : capturecatStore(env);
}

// ---------------------------------------------------------------------------
// Object operations that differ by store
// ---------------------------------------------------------------------------

/**
 * Delete one object. CaptureCat R2 goes through the binding (as before 0029);
 * a custom bucket goes through its S3 API. Throws when the bucket refuses.
 */
export async function deleteStoredObject(env: Env, storageId: string | null | undefined, key: string): Promise<void> {
  if (!storageId) {
    await env.R2.delete(key);
    return;
  }
  const store = await storeFor(env, storageId);
  await deleteS3Object({ ...store.connection, bucket: store.bucket, key });
}

/**
 * The URL a viewer is redirected to for a file in a custom bucket: the public
 * base URL when the owner set one (their bucket or CDN is public), otherwise a
 * presigned GET — which works for a private bucket and lapses on its own.
 * Downloads always presign: only a signed URL can force `attachment`.
 */
export async function customObjectUrl(
  store: ObjectStore,
  key: string,
  options: { expiresIn: number; contentType?: string; downloadFileName?: string }
): Promise<string> {
  if (store.publicBaseUrl && !options.downloadFileName) {
    return `${store.publicBaseUrl}/${key.split("/").map(encodeURIComponent).join("/")}`;
  }
  return createPresignedDownloadUrl({
    ...store.connection,
    bucket: store.bucket,
    key,
    expiresIn: options.expiresIn,
    responseContentType: options.contentType,
    responseContentDisposition: options.downloadFileName
      ? `attachment; filename="${options.downloadFileName}"`
      : undefined,
  });
}

// ---------------------------------------------------------------------------
// Credential encryption (AES-GCM, 96-bit IV, id+uid as additional data)
// ---------------------------------------------------------------------------

export function aadFor(id: string, uid: string): string {
  return `storage_buckets:${id}:${uid}`;
}

function decodeKey(raw: string | undefined): Uint8Array | null {
  if (!raw) return null;
  const bytes = Uint8Array.from(atob(raw.trim()), (ch) => ch.charCodeAt(0));
  return bytes.byteLength === 32 ? bytes : null;
}

async function credentialsKey(env: Env): Promise<CryptoKey> {
  const raw = decodeKey(env.STORAGE_CREDENTIALS_KEY);
  if (!raw) throw new StorageUnavailableError("Custom storage is not configured on this server.");
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function encryptSecret(env: Env, plaintext: string, aad: string): Promise<string> {
  const key = await credentialsKey(env);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(aad) },
      key,
      new TextEncoder().encode(plaintext)
    )
  );
  const out = new Uint8Array(iv.byteLength + sealed.byteLength);
  out.set(iv, 0);
  out.set(sealed, iv.byteLength);
  let binary = "";
  for (const b of out) binary += String.fromCharCode(b);
  return btoa(binary);
}

export async function decryptSecret(env: Env, ciphertext: string, aad: string): Promise<string> {
  const key = await credentialsKey(env);
  const bytes = Uint8Array.from(atob(ciphertext), (ch) => ch.charCodeAt(0));
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: bytes.slice(0, 12), additionalData: new TextEncoder().encode(aad) },
    key,
    bytes.slice(12)
  );
  return new TextDecoder().decode(plain);
}
