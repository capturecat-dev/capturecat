/**
 * Shared validation for raw-body image uploads (team logos, custom
 * thumbnails, future avatars). One place for the rules:
 *
 *  • the declared Content-Type must be an allowed image type, AND
 *  • the actual bytes must carry that type's magic number — a header is a
 *    claim, not evidence, and R2 will happily serve whatever we store under
 *    an image/* content type on a public URL.
 *  • size is checked twice: the declared Content-Length for a cheap early
 *    413, then the real byte length as the authoritative cap.
 */

export interface ImageUploadOk {
  ok: true;
  bytes: ArrayBuffer;
  contentType: string;
}
export interface ImageUploadErr {
  ok: false;
  status: 400 | 413 | 415;
  error: string;
}

const MAGIC: Record<string, (b: Uint8Array) => boolean> = {
  "image/png": (b) =>
    b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47,
  "image/jpeg": (b) => b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff,
  "image/webp": (b) =>
    b.length > 12 &&
    b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && // RIFF
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50, // WEBP
};

export async function readValidatedImage(
  req: {
    header(name: string): string | undefined;
    arrayBuffer(): Promise<ArrayBuffer>;
  },
  opts: { maxBytes: number; label?: string }
): Promise<ImageUploadOk | ImageUploadErr> {
  const label = opts.label ?? "Image";
  const mb = Math.round(opts.maxBytes / (1024 * 1024) * 10) / 10;

  const contentType = (req.header("Content-Type") ?? "").split(";")[0].trim().toLowerCase();
  if (!(contentType in MAGIC)) {
    return { ok: false, status: 415, error: `${label} must be a PNG, JPEG, or WebP image` };
  }
  const declared = parseInt(req.header("Content-Length") ?? "", 10);
  if (Number.isFinite(declared) && declared > opts.maxBytes) {
    return { ok: false, status: 413, error: `${label} must be ${mb} MB or smaller` };
  }
  const bytes = await req.arrayBuffer();
  if (bytes.byteLength === 0) return { ok: false, status: 400, error: "Empty body" };
  if (bytes.byteLength > opts.maxBytes) {
    return { ok: false, status: 413, error: `${label} must be ${mb} MB or smaller` };
  }
  if (!MAGIC[contentType](new Uint8Array(bytes))) {
    return {
      ok: false,
      status: 415,
      error: `${label} bytes do not match the declared ${contentType}`,
    };
  }
  return { ok: true, bytes, contentType };
}
