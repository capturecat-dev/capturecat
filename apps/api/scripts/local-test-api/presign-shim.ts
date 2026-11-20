// lib/presign for the local test API: every presigned URL points back at this
// server's /__r2/ route (the in-memory bucket) — never at Cloudflare R2.
export * from "../../src/lib/presign";

const origin = () => process.env.LOCAL_TEST_API_ORIGIN ?? "http://127.0.0.1:0";

export async function createPresignedUploadUrl(options: { key: string }): Promise<string> {
  return `${origin()}/__r2/${encodeURIComponent(options.key)}?put=1`;
}

export async function createPresignedDownloadUrl(options: { key: string }): Promise<string> {
  return `${origin()}/__r2/${encodeURIComponent(options.key)}`;
}
