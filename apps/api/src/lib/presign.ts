/**
 * Presigned URLs and object calls over the S3 API — CaptureCat's own R2
 * bucket and, since 0029, a user's own S3-compatible bucket (lib/storage.ts
 * builds the connection for either).
 */

import {
  S3Client,
  PutObjectCommand,
  HeadObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

/** Where to reach a bucket. R2 needs only `endpoint` (region "auto");
 *  AWS needs only `region` (the SDK derives the endpoint). */
export interface S3Connection {
  /** Omit for AWS S3. */
  endpoint?: string;
  /** Default "auto" (R2). */
  region?: string;
  /** `endpoint/bucket/key` instead of `bucket.endpoint/key` (MinIO). */
  forcePathStyle?: boolean;
  accessKeyId: string;
  secretAccessKey: string;
}

interface PresignOptions extends S3Connection {
  bucket: string;
  key: string;
  contentType: string;
  expiresIn?: number;
  contentLength?: number;
}

function createS3Client(options: S3Connection) {
  return new S3Client({
    region: options.region ?? "auto",
    endpoint: options.endpoint,
    forcePathStyle: options.forcePathStyle ?? false,
    credentials: {
      accessKeyId: options.accessKeyId,
      secretAccessKey: options.secretAccessKey,
    },
    // AWS SDK ≥3.729 defaults to WHEN_SUPPORTED, which stamps
    // x-amz-sdk-checksum-algorithm/x-amz-checksum-crc32 into presigned
    // PutObject URLs. R2 rejects those with SignatureDoesNotMatch — this pair
    // is Cloudflare's documented compatibility setting.
    requestChecksumCalculation: "WHEN_REQUIRED",
    responseChecksumValidation: "WHEN_REQUIRED",
  });
}

export async function createPresignedUploadUrl(
  options: PresignOptions
): Promise<string> {
  const client = createS3Client(options);

  const command = new PutObjectCommand({
    Bucket: options.bucket,
    Key: options.key,
    ContentType: options.contentType,
    // Signed into the URL: the PUT must carry exactly this Content-Length,
    // so a presign is a permit for ONE upload of a declared size — not an
    // hour-long 5 GB blank cheque.
    ContentLength: options.contentLength,
  });

  return getSignedUrl(client, command, {
    // Short: the signature is only checked when the PUT starts, so a slow
    // upload is unaffected, but the window to re-PUT after /complete is small.
    expiresIn: options.expiresIn ?? 900,
  });
}

/** HEAD with the verified size and (unquoted) ETag, or null if missing. */
export async function headR2ObjectMeta(options: S3Connection & {
  bucket: string;
  key: string;
}): Promise<{ size: number; etag: string | null } | null> {
  const client = createS3Client(options);
  try {
    const result = await client.send(
      new HeadObjectCommand({ Bucket: options.bucket, Key: options.key })
    );
    return { size: result.ContentLength ?? 0, etag: result.ETag?.replace(/"/g, "") ?? null };
  } catch {
    return null;
  }
}

/**
 * Presigned GET for serving a stored object (screenshot API `store=true`).
 * Same client/checksum settings as the upload path — see the note above.
 */
export async function createPresignedDownloadUrl(options: S3Connection & {
  bucket: string;
  key: string;
  expiresIn?: number;
  /** Signed `response-content-type` override, so the object is served as
   *  exactly this type regardless of what the PUT stored (cloud projects). */
  responseContentType?: string;
  /** Signed `response-content-disposition` (share-page downloads). */
  responseContentDisposition?: string;
}): Promise<string> {
  const client = createS3Client(options);
  const command = new GetObjectCommand({
    Bucket: options.bucket,
    Key: options.key,
    ResponseContentType: options.responseContentType,
    ResponseContentDisposition: options.responseContentDisposition,
  });
  return getSignedUrl(client, command, { expiresIn: options.expiresIn ?? 3600 });
}

/**
 * Check if an object exists in R2 via S3 HeadObject.
 * Returns the content-length if found, null if not.
 */
export async function headR2Object(options: S3Connection & {
  bucket: string;
  key: string;
}): Promise<number | null> {
  const client = createS3Client(options);

  try {
    const result = await client.send(
      new HeadObjectCommand({ Bucket: options.bucket, Key: options.key })
    );
    return result.ContentLength ?? 0;
  } catch {
    return null;
  }
}

/** PUT a small object directly (the bucket check in routes/storage.ts).
 *  Throws the SDK error, whose message names what the bucket refused. */
export async function putS3Object(options: S3Connection & {
  bucket: string;
  key: string;
  body: string;
  contentType: string;
}): Promise<void> {
  await createS3Client(options).send(
    new PutObjectCommand({
      Bucket: options.bucket,
      Key: options.key,
      Body: options.body,
      ContentType: options.contentType,
    })
  );
}

/** DELETE one object. S3 answers 204 for a key that is already gone, so this
 *  only throws when the bucket refuses (credentials, permissions, network). */
export async function deleteS3Object(options: S3Connection & {
  bucket: string;
  key: string;
}): Promise<void> {
  await createS3Client(options).send(
    new DeleteObjectCommand({ Bucket: options.bucket, Key: options.key })
  );
}
