/**
 * R2 presigned URL generation via S3-compatible API.
 */

import { S3Client, PutObjectCommand, HeadObjectCommand, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

interface PresignOptions {
  r2Endpoint: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  key: string;
  contentType: string;
  expiresIn?: number;
}

function createS3Client(options: { r2Endpoint: string; accessKeyId: string; secretAccessKey: string }) {
  return new S3Client({
    region: "auto",
    endpoint: options.r2Endpoint,
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
  });

  return getSignedUrl(client, command, {
    expiresIn: options.expiresIn ?? 3600,
  });
}

/**
 * Presigned GET for serving a stored object (screenshot API `store=true`).
 * Same client/checksum settings as the upload path — see the note above.
 */
export async function createPresignedDownloadUrl(options: {
  r2Endpoint: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  key: string;
  expiresIn?: number;
}): Promise<string> {
  const client = createS3Client(options);
  const command = new GetObjectCommand({ Bucket: options.bucket, Key: options.key });
  return getSignedUrl(client, command, { expiresIn: options.expiresIn ?? 3600 });
}

/**
 * Check if an object exists in R2 via S3 HeadObject.
 * Returns the content-length if found, null if not.
 */
export async function headR2Object(options: {
  r2Endpoint: string;
  accessKeyId: string;
  secretAccessKey: string;
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
