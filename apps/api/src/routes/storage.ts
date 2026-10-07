import { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { requireEntitlement, userRateLimit } from "../lib/entitlement";
import { featuresForTier } from "../lib/plans";
import { parseJsonBody } from "../lib/validate";
import { generateId } from "../lib/id";
import { webOrigins } from "../lib/origins";
import {
  createPresignedUploadUrl,
  deleteS3Object,
  headR2ObjectMeta,
  putS3Object,
} from "../lib/presign";
import {
  aadFor,
  activeStorageBucket,
  bucketVideoCount,
  customStorageAvailable,
  encryptSecret,
  listStorageBuckets,
  storeFromRecord,
  STORAGE_PROVIDERS,
  StorageUnavailableError,
  type ObjectStore,
  type StorageBucketRecord,
} from "../lib/storage";

/**
 * Bring-your-own bucket for share videos (migration 0029).
 *
 *   GET    /storage/bucket             the connected bucket (secret never returned)
 *   PUT    /storage/bucket             connect or update — test-writes, reads and
 *                                      deletes an object first; nothing is saved
 *                                      unless the bucket passes
 *   DELETE /storage/bucket             disconnect: new uploads go back to CaptureCat
 *   POST   /storage/bucket/cors-probe  presigned PUT the web app uses to prove
 *   DELETE /storage/bucket/cors-probe  the bucket's CORS lets browsers upload
 *
 * Paid only: connecting (and the CORS probe) require the plan feature
 * `customStorage` — Pro and Business; free never has it. GET and DELETE are
 * open on purpose so a downgraded user can see and disconnect their bucket,
 * and `uploadStoreFor` stops routing uploads to it the moment the plan lapses.
 *
 * Both clients (the Mac Settings pane and the web dashboard) drive these; the
 * upload routes then presign into the active bucket (lib/storage.ts
 * `uploadStoreFor`), so neither client's upload code changes.
 */
export const storageRoutes = new Hono<{
  Bindings: Env;
  Variables: Variables;
}>();

/** S3 / R2 / B2 bucket names, plus legacy mixed-case and underscores. */
const BUCKET_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{1,253}[A-Za-z0-9]$/;
/** Printable ASCII, no spaces — every provider's key format fits. */
const KEY_RE = /^[\x21-\x7e]+$/;
const CHECK_BODY = "capturecat storage check";
const CORS_PROBE_KEY = ".capturecat-cors-check";
const STEP_TIMEOUT_MS = 10_000;

const BucketBodySchema = z.object({
  provider: z.enum(STORAGE_PROVIDERS, { error: "Choose a storage provider" }),
  endpoint: z.string().trim().max(300).nullish(),
  region: z
    .string({ error: "Region is required" })
    .trim()
    .toLowerCase()
    .regex(/^[a-z0-9-]{1,40}$/, { error: "Enter a region, e.g. us-east-1 (R2 uses auto)" }),
  bucket: z
    .string({ error: "Bucket is required" })
    .trim()
    .regex(BUCKET_RE, { error: "Enter a valid bucket name" }),
  pathPrefix: z.string().trim().max(200).optional(),
  forcePathStyle: z.boolean().optional(),
  publicBaseUrl: z.string().trim().max(500).nullish(),
  accessKeyId: z
    .string({ error: "Access key ID is required" })
    .trim()
    .min(1, { error: "Access key ID is required" })
    .max(128)
    .regex(KEY_RE, { error: "Access key ID contains invalid characters" }),
  secretAccessKey: z
    .string({ error: "Secret access key is required" })
    .trim()
    .min(1, { error: "Secret access key is required" })
    .max(256)
    .regex(KEY_RE, { error: "Secret access key contains invalid characters" }),
});

/**
 * An https URL on a public hostname. The Worker itself calls the endpoint
 * (the bucket check) and fetches the public URL, so loopback, private-looking
 * names and IP literals are refused outright rather than trusted to egress.
 */
function parsePublicHttpsUrl(raw: string): URL | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) return null;
  const host = url.hostname.toLowerCase();
  if (!host.includes(".")) return null;
  if (host === "localhost" || /\.(localhost|local|internal|lan|home\.arpa)$/.test(host)) return null;
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.startsWith("[")) return null;
  return url;
}

type NormalizedBucket = {
  provider: StorageBucketRecord["provider"];
  endpoint: string | null;
  region: string;
  bucket: string;
  pathPrefix: string;
  forcePathStyle: boolean;
  publicBaseUrl: string | null;
  accessKeyId: string;
  secretAccessKey: string;
};

function normalize(body: z.infer<typeof BucketBodySchema>): { ok: true; value: NormalizedBucket } | { ok: false; error: string } {
  let endpoint: string | null = null;
  if (body.provider === "aws") {
    // AWS derives the endpoint from the region; a custom one here is almost
    // always a pasted bucket URL, which would sign against the wrong host.
    if (body.endpoint) {
      const url = parsePublicHttpsUrl(body.endpoint);
      if (!url || !url.hostname.endsWith(".amazonaws.com") || url.pathname !== "/") {
        return { ok: false, error: "Leave Endpoint empty for AWS S3 — the region decides it" };
      }
    }
  } else {
    if (!body.endpoint) return { ok: false, error: "Endpoint is required for this provider" };
    const url = parsePublicHttpsUrl(body.endpoint);
    if (!url) return { ok: false, error: "Endpoint must be an https:// URL on a public hostname" };
    if (url.pathname !== "/" && url.pathname !== "") {
      return { ok: false, error: "Endpoint is the host only — put the bucket name in Bucket" };
    }
    endpoint = url.origin;
  }

  let pathPrefix = (body.pathPrefix ?? "").replace(/^\/+/, "").replace(/\/{2,}/g, "/");
  if (pathPrefix && !pathPrefix.endsWith("/")) pathPrefix += "/";
  if (!/^[A-Za-z0-9!_.*'()/-]*$/.test(pathPrefix)) {
    return { ok: false, error: "Folder may only use letters, numbers, / and !_.*'()-" };
  }
  if (pathPrefix.split("/").some((seg) => seg === "." || seg === "..")) {
    return { ok: false, error: "Folder may not contain . or .. segments" };
  }

  let publicBaseUrl: string | null = null;
  if (body.publicBaseUrl) {
    const url = parsePublicHttpsUrl(body.publicBaseUrl);
    if (!url) return { ok: false, error: "Public URL must be an https:// URL on a public hostname" };
    publicBaseUrl = `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
  }

  return {
    ok: true,
    value: {
      provider: body.provider,
      endpoint,
      region: body.region,
      bucket: body.bucket,
      pathPrefix,
      // MinIO serves path-style only; everything else defaults to virtual-hosted.
      forcePathStyle: body.forcePathStyle ?? body.provider === "minio",
      publicBaseUrl,
      accessKeyId: body.accessKeyId,
      secretAccessKey: body.secretAccessKey,
    },
  };
}

function withTimeout<T>(promise: Promise<T>, what: string): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`Timed out ${what} — check Endpoint and Region`)), STEP_TIMEOUT_MS)
    ),
  ]);
}

/** S3 error → one sentence a user can act on. */
function describeS3Error(err: unknown, bucket: string, action: string): string {
  const e = err as { name?: string; Code?: string; message?: string; $metadata?: { httpStatusCode?: number } };
  const code = e?.Code ?? e?.name ?? "";
  switch (code) {
    case "NoSuchBucket":
      return `Bucket "${bucket}" doesn't exist at this endpoint and region.`;
    case "InvalidAccessKeyId":
      return "The access key ID wasn't recognised.";
    case "SignatureDoesNotMatch":
      return "The secret access key doesn't match the access key ID.";
    case "AccessDenied":
    case "Forbidden":
      return `The key is valid but isn't allowed to ${action} objects in this bucket.`;
    case "PermanentRedirect":
    case "AuthorizationHeaderMalformed":
    case "IllegalLocationConstraintException":
      return "The bucket is in a different region — check Region.";
  }
  if (e?.$metadata?.httpStatusCode === 403) {
    return `The bucket refused to let this key ${action} objects (HTTP 403).`;
  }
  const message = (e?.message ?? String(err)).slice(0, 200);
  return code && !message.startsWith(code) ? `${code}: ${message}` : message;
}

type VerifyResult = { ok: true } | { ok: false; step: "write" | "read" | "public_url" | "delete"; error: string };

/**
 * Prove the bucket works the way uploads and playback will use it: write a
 * small object, read it back, fetch it through the public URL if one is set,
 * delete it. The object is removed on every path that wrote it.
 */
async function verifyBucket(store: ObjectStore): Promise<VerifyResult> {
  const key = `${store.pathPrefix}.capturecat-check-${generateId()}`;
  const target = { ...store.connection, bucket: store.bucket, key };
  try {
    await withTimeout(putS3Object({ ...target, body: CHECK_BODY, contentType: "text/plain" }), "writing a test file");
  } catch (err) {
    return { ok: false, step: "write", error: describeS3Error(err, store.bucket, "write") };
  }

  let result: VerifyResult = { ok: true };
  try {
    const head = await withTimeout(headR2ObjectMeta(target), "reading the test file back");
    if (!head) {
      result = {
        ok: false,
        step: "read",
        error: "Wrote a test file but couldn't read it back — the key needs read access (s3:GetObject).",
      };
    } else if (store.publicBaseUrl) {
      const publicUrl = `${store.publicBaseUrl}/${key.split("/").map(encodeURIComponent).join("/")}`;
      const res = await withTimeout(fetch(publicUrl, { redirect: "follow" }), "fetching the public URL").catch(
        (err: unknown) => err as Error
      );
      const text = res instanceof Response && res.ok ? await res.text().catch(() => "") : "";
      if (!text.includes(CHECK_BODY)) {
        const why = res instanceof Response ? `HTTP ${res.status}` : res.message;
        result = {
          ok: false,
          step: "public_url",
          error: `Couldn't fetch the test file through ${store.publicBaseUrl} (${why}). Make the bucket or its CDN publicly readable, or leave Public URL empty to use signed links.`,
        };
      }
    }
  } catch (err) {
    result = { ok: false, step: "read", error: describeS3Error(err, store.bucket, "read") };
  }

  try {
    await withTimeout(deleteS3Object(target), "deleting the test file");
  } catch (err) {
    // Only report a delete failure when nothing earlier failed: deleting a
    // share video needs this permission too.
    if (result.ok) return { ok: false, step: "delete", error: describeS3Error(err, store.bucket, "delete") };
  }
  return result;
}

function accessKeyHint(id: string): string {
  return id.length > 10 ? `${id.slice(0, 4)}…${id.slice(-4)}` : `…${id.slice(-2)}`;
}

async function bucketState(env: Env, uid: string, tier: Variables["entitlement"]) {
  const features = await featuresForTier(env.DB, tier.tier, tier.planName);
  const buckets = await listStorageBuckets(env.DB, uid);
  const active = buckets.find((b) => b.active) ?? null;
  let retainedCount = 0;
  for (const b of buckets) if (!b.active) retainedCount += await bucketVideoCount(env.DB, b.id);
  return {
    enabled: features.customStorage,
    available: customStorageAvailable(env),
    bucket: active
      ? {
          id: active.id,
          provider: active.provider,
          endpoint: active.endpoint,
          region: active.region,
          bucket: active.bucket,
          pathPrefix: active.pathPrefix,
          forcePathStyle: active.forcePathStyle,
          publicBaseUrl: active.publicBaseUrl,
          accessKeyIdHint: accessKeyHint(active.accessKeyId),
          verifiedAt: active.verifiedAt,
          videoCount: await bucketVideoCount(env.DB, active.id),
        }
      : null,
    retainedCount,
    /** Origins the bucket's CORS must allow for browser (web app) uploads. */
    corsOrigins: webOrigins(env).filter((o) => !o.includes("admin.")),
  };
}

/** The paid gate (plan feature `customStorage`), or the 402 body. */
async function requireCustomStorage(env: Env, entitlement: Variables["entitlement"]) {
  const features = await featuresForTier(env.DB, entitlement.tier, entitlement.planName);
  return features.customStorage
    ? null
    : {
        error: "Storing videos in your own bucket is included in CaptureCat Pro.",
        code: "custom_storage_required",
      };
}

storageRoutes.get("/storage/bucket", requireAuth, requireEntitlement(), async (c) => {
  return c.json(await bucketState(c.env, c.get("user").uid, c.get("entitlement")));
});

storageRoutes.put(
  "/storage/bucket",
  requireAuth,
  requireEntitlement(),
  // Each save makes four calls to a third-party endpoint.
  userRateLimit({ limit: 10, windowSec: 60, scope: "storage" }),
  async (c) => {
    const uid = c.get("user").uid;
    const entitlement = c.get("entitlement");
    const denied = await requireCustomStorage(c.env, entitlement);
    if (denied) return c.json(denied, 402);
    if (!customStorageAvailable(c.env)) {
      return c.json({ error: "Custom storage isn't available right now.", code: "storage_unavailable" }, 503);
    }

    const parsed = await parseJsonBody(c.req, BucketBodySchema, { emptyOnInvalidJson: true });
    if (!parsed.ok) return c.json({ error: parsed.error, code: "invalid" }, 400);
    const normalized = normalize(parsed.data);
    if (!normalized.ok) return c.json({ error: normalized.error, code: "invalid" }, 400);
    const input = normalized.value;

    const check = await verifyBucket({
      storageId: "pending",
      bucket: input.bucket,
      connection: {
        endpoint: input.endpoint ?? undefined,
        region: input.region,
        forcePathStyle: input.forcePathStyle,
        accessKeyId: input.accessKeyId,
        secretAccessKey: input.secretAccessKey,
      },
      pathPrefix: input.pathPrefix,
      publicBaseUrl: input.publicBaseUrl,
    });
    if (!check.ok) {
      return c.json({ error: check.error, code: "verify_failed", step: check.step }, 422);
    }

    // The same bucket+folder (active or retained) is updated in place, so its
    // existing videos keep resolving to this row. Anything else becomes a new
    // row; the previously active bucket is retained while videos still play
    // from it, and dropped when none do.
    const now = new Date().toISOString();
    const existing = await listStorageBuckets(c.env.DB, uid);
    const same = existing.find(
      (b) => b.endpoint === input.endpoint && b.bucket === input.bucket && b.pathPrefix === input.pathPrefix
    );
    const id = same?.id ?? generateId();
    const secretCiphertext = await encryptSecret(c.env, input.secretAccessKey, aadFor(id, uid));

    const statements: D1PreparedStatement[] = [];
    for (const b of existing) {
      if (b.id === id || !b.active) continue;
      statements.push(
        (await bucketVideoCount(c.env.DB, b.id)) > 0
          ? c.env.DB.prepare("UPDATE storage_buckets SET active = 0, updated_at = ? WHERE id = ?").bind(now, b.id)
          : c.env.DB.prepare("DELETE FROM storage_buckets WHERE id = ?").bind(b.id)
      );
    }
    statements.push(
      same
        ? c.env.DB.prepare(
            `UPDATE storage_buckets
                SET provider = ?, region = ?, force_path_style = ?, public_base_url = ?,
                    access_key_id = ?, secret_ciphertext = ?, active = 1, verified_at = ?, updated_at = ?
              WHERE id = ? AND uid = ?`
          ).bind(
            input.provider,
            input.region,
            input.forcePathStyle ? 1 : 0,
            input.publicBaseUrl,
            input.accessKeyId,
            secretCiphertext,
            now,
            now,
            id,
            uid
          )
        : c.env.DB.prepare(
            `INSERT INTO storage_buckets (
               id, uid, provider, endpoint, region, bucket, path_prefix, force_path_style,
               public_base_url, access_key_id, secret_ciphertext, active, verified_at, created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)`
          ).bind(
            id,
            uid,
            input.provider,
            input.endpoint,
            input.region,
            input.bucket,
            input.pathPrefix,
            input.forcePathStyle ? 1 : 0,
            input.publicBaseUrl,
            input.accessKeyId,
            secretCiphertext,
            now,
            now,
            now
          )
    );
    // One transaction: never two active buckets, never none mid-switch.
    await c.env.DB.batch(statements);

    return c.json(await bucketState(c.env, uid, entitlement));
  }
);

/** Disconnect. Allowed on any plan: a downgraded user must be able to stop
 *  using a bucket. Videos already in it keep playing from it. */
storageRoutes.delete("/storage/bucket", requireAuth, requireEntitlement(), async (c) => {
  const uid = c.get("user").uid;
  const active = await activeStorageBucket(c.env.DB, uid);
  if (!active) return c.json({ disconnected: false, retained: false, videoCount: 0 });
  const videoCount = await bucketVideoCount(c.env.DB, active.id);
  if (videoCount > 0) {
    await c.env.DB.prepare("UPDATE storage_buckets SET active = 0, updated_at = ? WHERE id = ?")
      .bind(new Date().toISOString(), active.id)
      .run();
  } else {
    await c.env.DB.prepare("DELETE FROM storage_buckets WHERE id = ?").bind(active.id).run();
  }
  return c.json({ disconnected: true, retained: videoCount > 0, videoCount });
});

async function activeStore(env: Env, uid: string): Promise<ObjectStore | null> {
  const active = await activeStorageBucket(env.DB, uid);
  if (!active) return null;
  try {
    return await storeFromRecord(env, active);
  } catch (err) {
    if (err instanceof StorageUnavailableError) return null;
    throw err;
  }
}

/**
 * A presigned PUT of a 2-byte object, for the web app to try from the browser:
 * the only way to learn whether the bucket's CORS admits our origin, which a
 * server-side check cannot see. The Mac app uploads natively and skips this.
 */
storageRoutes.post(
  "/storage/bucket/cors-probe",
  requireAuth,
  requireEntitlement(),
  userRateLimit({ limit: 10, windowSec: 60, scope: "storage" }),
  async (c) => {
    const denied = await requireCustomStorage(c.env, c.get("entitlement"));
    if (denied) return c.json(denied, 402);
    const store = await activeStore(c.env, c.get("user").uid);
    if (!store) return c.json({ error: "No bucket connected" }, 404);
    const uploadUrl = await createPresignedUploadUrl({
      ...store.connection,
      bucket: store.bucket,
      key: `${store.pathPrefix}${CORS_PROBE_KEY}`,
      contentType: "text/plain",
      contentLength: 2,
      expiresIn: 300,
    });
    return c.json({ uploadUrl, contentType: "text/plain", body: "ok" });
  }
);

storageRoutes.delete("/storage/bucket/cors-probe", requireAuth, requireEntitlement(), async (c) => {
  const store = await activeStore(c.env, c.get("user").uid);
  if (!store) return c.json({ deleted: false });
  await deleteS3Object({ ...store.connection, bucket: store.bucket, key: `${store.pathPrefix}${CORS_PROBE_KEY}` }).catch(
    () => {}
  );
  return c.json({ deleted: true });
});
