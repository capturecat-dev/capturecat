import { API_URL } from "@/lib/api-url";

/** Client-side mirror of the API's limits (routes/video.ts). */
export const THUMBNAIL_MAX_BYTES = 5 * 1024 * 1024;
export const THUMBNAIL_ACCEPT = "image/jpeg,image/png,image/webp";

const ALLOWED_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

/**
 * Upload a custom thumbnail straight from the browser to the API.
 *
 * Deliberately NOT a tRPC mutation: a binary body doesn't belong in a
 * superjson payload. The API accepts the session cookie (credentials:
 * "include") because the browser attaches our trusted Origin automatically.
 */
export async function uploadThumbnail(videoId: string, file: File): Promise<void> {
  if (!ALLOWED_TYPES.has(file.type)) {
    throw new Error("Thumbnail must be a JPEG, PNG or WebP image");
  }
  if (file.size > THUMBNAIL_MAX_BYTES) {
    throw new Error("Thumbnail must be 5 MB or smaller");
  }
  const res = await fetch(
    `${API_URL}/api/video/${encodeURIComponent(videoId)}/thumbnail`,
    {
      method: "PUT",
      credentials: "include",
      headers: { "Content-Type": file.type },
      body: file,
    }
  );
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error ?? "Could not upload thumbnail");
  }
}
