/**
 * Picked images → files a project can reference, the Mac's rules:
 *
 *   accepted types   per picker, as the Mac's NSOpenPanels:
 *                      background   [.image]                (BackgroundSettingsPaneAppKit)
 *                      watermark    png, jpeg, tiff, heic   (BrandSettingsPaneAppKit)
 *                      curtain logo png, jpeg, tiff, heic   (EffectsSettingsPaneAppKit; its
 *                                   PDF option is Mac-only — the cloud refuses .pdf and a
 *                                   browser cannot rasterize one without a PDF engine)
 *   browser formats  what CloudImageTranscoder does before a cloud upload:
 *                    HEIC/HEIF/TIFF/BMP (and any other decodable type the
 *                    cloud does not accept) are re-encoded ONCE as lossless
 *                    PNG; a PNG over the 64 MB image ceiling falls back to a
 *                    JPEG at quality 0.95; still over → refused. PNG, JPEG,
 *                    WebP and GIF upload as they are (≤ 64 MB, the API's
 *                    KIND_MAX_BYTES.image). SVG is refused (the API never
 *                    serves it — a script vector).
 *   file names       watermark    `watermark-<UUID8>.<ext>`     (folder-relative)
 *                    curtain logo `curtain-logo-<UUID8>.<ext>`  (folder-relative)
 *                    background   `<name>.<ext>`, or `<name>-<sha10>.<ext>` when that
 *                                 name is taken by different bytes (CustomWallpaperStore.add),
 *                                 referenced Mac-style as `/CaptureCat/Projects/<UUID>/<file>`
 *                                 (backgroundImagePath is a path, like the Mac's `url.path`).
 *
 * Decoding/encoding is injected so the rules are unit-testable in Node.
 */
import { sha256Blob } from "../record/sha256";

export type ImagePickerKind = "background" | "watermark" | "curtainLogo";

/** The cloud's image ceiling (apps/api KIND_MAX_BYTES.image = CloudImageTranscoder.maxImageBytes). */
export const MAX_IMAGE_BYTES = 64 * 1024 * 1024;

/** Extension → the canonical content type the cloud accepts (CLOUD_FILE_TYPES, images). */
export const UPLOADABLE_IMAGE_TYPES: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  webp: "image/webp",
  gif: "image/gif",
};

/** CloudImageTranscoder.transcodedExtensions — formats browsers cannot all decode. */
export const TRANSCODED_EXTENSIONS = new Set(["heic", "heif", "tif", "tiff", "bmp"]);

const MIME_EXT: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
  "image/gif": "gif",
  "image/heic": "heic",
  "image/heif": "heif",
  "image/heic-sequence": "heic",
  "image/heif-sequence": "heif",
  "image/tiff": "tiff",
  "image/bmp": "bmp",
  "image/x-ms-bmp": "bmp",
  "image/avif": "avif",
  "image/svg+xml": "svg",
};

/** What each picker accepts, by extension (lowercased). The background takes any image type (`[.image]`). */
const PICKER_EXTENSIONS: Record<ImagePickerKind, readonly string[]> = {
  background: ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp", "avif", "ico", "jxl"],
  watermark: ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif"],
  curtainLogo: ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif"],
};

/** `<input accept>` per picker. */
export const PICKER_ACCEPT: Record<ImagePickerKind, string> = {
  background: "image/*,.heic,.heif,.tif,.tiff,.bmp",
  watermark: ".png,.jpg,.jpeg,.tif,.tiff,.heic,.heif,image/png,image/jpeg,image/tiff,image/heic,image/heif",
  curtainLogo: ".png,.jpg,.jpeg,.tif,.tiff,.heic,.heif,image/png,image/jpeg,image/tiff,image/heic,image/heif",
};

const ACCEPTED_TEXT: Record<ImagePickerKind, string> = {
  background: "Choose a PNG, JPEG, HEIC, TIFF, WebP or GIF image.",
  watermark: "Choose a PNG, JPEG, TIFF or HEIC image.",
  curtainLogo: "Choose a PNG, JPEG, TIFF or HEIC image.",
};

export class ImageImportError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ImageImportError";
  }
}

/** A picked image, normalized for browsers and the cloud. */
export interface ImportedImage {
  blob: Blob;
  /** Lowercased extension of `blob` ("png", "jpg", "jpeg", "webp", "gif"). */
  ext: string;
  contentType: string;
  /** The picked file's name without its extension (display + file naming). */
  baseName: string;
  sha256: string;
  /** Re-encoded from a format browsers cannot all decode. */
  transcoded: boolean;
}

export interface ImageCodec {
  /** True when this browser can decode the blob as an image. */
  decodes(blob: Blob): Promise<boolean>;
  /** Re-encode to PNG (or null when undecodable). */
  toPng(blob: Blob): Promise<Blob | null>;
  /** Re-encode to JPEG at `quality` (or null when undecodable). */
  toJpeg(blob: Blob, quality: number): Promise<Blob | null>;
  sha256(blob: Blob): Promise<string>;
}

/** Lowercased extension of a file name ("" when none). */
export function extensionOf(name: string): string {
  const last = name.split("/").pop() ?? name;
  const dot = last.lastIndexOf(".");
  return dot > 0 ? last.slice(dot + 1).toLowerCase() : "";
}

function baseNameOf(name: string): string {
  const last = name.split("/").pop() ?? name;
  const dot = last.lastIndexOf(".");
  return dot > 0 ? last.slice(0, dot) : last;
}

/** An image MIME type's usual extension ("" when unknown). */
export function extensionForType(type: string): string {
  return MIME_EXT[type.split(";")[0].trim().toLowerCase()] ?? "";
}

/** The picked file's image type, by extension first (Finder's rule), then MIME. */
export function imageExtension(file: { name: string; type: string }): string {
  const ext = extensionOf(file.name);
  if (ext) return ext === "jpe" ? "jpg" : ext;
  return MIME_EXT[file.type.toLowerCase()] ?? "";
}

/**
 * Normalize a picked file for `kind` (see the module comment). Throws
 * ImageImportError with a message in the Mac's voice.
 */
export async function importImage(file: File, kind: ImagePickerKind, codec: ImageCodec = browserImageCodec): Promise<ImportedImage> {
  const ext = imageExtension(file);
  const allowed = PICKER_EXTENSIONS[kind];
  if (!ext || !allowed.includes(ext)) {
    throw new ImageImportError(ACCEPTED_TEXT[kind]);
  }
  const baseName = baseNameOf(file.name) || "Image";
  const passThrough = UPLOADABLE_IMAGE_TYPES[ext];
  if (passThrough) {
    if (file.size > MAX_IMAGE_BYTES) throw new ImageImportError("This image is larger than 64 MB.");
    if (!(await codec.decodes(file))) throw new ImageImportError("Couldn’t read this image.");
    const blob = file.type === passThrough ? file : new Blob([file], { type: passThrough });
    return { blob, ext, contentType: passThrough, baseName, sha256: await codec.sha256(blob), transcoded: false };
  }
  // Transcode once: lossless PNG, JPEG 0.95 when the PNG is over the ceiling.
  let png: Blob | null = null;
  try {
    png = await codec.toPng(file);
  } catch {
    png = null;
  }
  if (!png) {
    const kindName = ext === "heic" || ext === "heif" ? "HEIC" : ext.toUpperCase();
    throw new ImageImportError(`This browser can’t open ${kindName} images. Choose a PNG or JPEG instead.`);
  }
  if (png.size <= MAX_IMAGE_BYTES) {
    return { blob: png, ext: "png", contentType: "image/png", baseName, sha256: await codec.sha256(png), transcoded: true };
  }
  const jpg = await codec.toJpeg(file, 0.95);
  if (!jpg || jpg.size > MAX_IMAGE_BYTES) throw new ImageImportError("This image is larger than 64 MB.");
  return { blob: jpg, ext: "jpg", contentType: "image/jpeg", baseName, sha256: await codec.sha256(jpg), transcoded: true };
}

// ── Names ─────────────────────────────────────────────────────────────────

/** Swift `UUID().uuidString.prefix(8)` — eight uppercase hex digits. */
export function uuid8(): string {
  const id = typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Math.random().toString(16).slice(2)}00000000`;
  return id.replace(/-/g, "").slice(0, 8).toUpperCase();
}

/** BrandSettingsPaneAppKit.pickLogo: `watermark-<UUID8>.<ext>`. */
export function watermarkFileName(ext: string, id = uuid8()): string {
  return `watermark-${id}.${ext.toLowerCase()}`;
}

/** EffectsSettingsPaneAppKit.pickCurtainLogo: `curtain-logo-<UUID8>.<ext>`. */
export function curtainLogoFileName(ext: string, id = uuid8()): string {
  return `curtain-logo-${id}.${ext.toLowerCase()}`;
}

/** A path segment the cloud accepts (apps/api checkLogicalPath SEGMENT_RE), ≤ `max` chars. */
export function sanitizeFileBase(base: string, max = 100): string {
  const cleaned = base
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^A-Za-z0-9 ._()+@,-]+/g, " ")
    .replace(/\s{2,}/g, " ")
    .replace(/^[^A-Za-z0-9]+/, "")
    .replace(/[\s.-]+$/, "")
    .slice(0, max)
    .replace(/[\s.-]+$/, "");
  return cleaned || "Image";
}

/**
 * CustomWallpaperStore.add naming: `<name>.<ext>`; when that name already
 * holds DIFFERENT bytes, `<name>-<sha10>.<ext>` so both survive. `taken`
 * answers the sha256 currently stored under a file name (undefined = free).
 */
export function backgroundFileName(baseName: string, ext: string, sha256: string, taken: (name: string) => string | undefined): string {
  const base = sanitizeFileBase(baseName);
  const plain = `${base}.${ext.toLowerCase()}`;
  const holder = taken(plain);
  if (holder === undefined || holder === sha256) return plain;
  return `${base}-${sha256.slice(0, 10)}.${ext.toLowerCase()}`;
}

/** The Mac-shaped project-folder PATH for a file (backgroundImagePath). */
export function projectFilePath(projectId: string, fileName: string): string {
  return `/CaptureCat/Projects/${projectId}/${fileName}`;
}

/** The display name a Mac tile uses for an image path (file name without extension). */
export function imageDisplayName(pathOrName: string): string {
  let path = pathOrName;
  if (path.startsWith("file://")) {
    try {
      path = decodeURIComponent(new URL(path).pathname);
    } catch {
      // keep as spelled
    }
  }
  return baseNameOf(path) || path;
}

// ── Browser codec ─────────────────────────────────────────────────────────

async function decodeBitmap(blob: Blob): Promise<ImageBitmap | HTMLImageElement | null> {
  try {
    return await createImageBitmap(blob);
  } catch {
    // Safari decodes some formats (HEIC) through <img> but not createImageBitmap.
  }
  if (typeof document === "undefined" || typeof Image === "undefined") return null;
  const url = URL.createObjectURL(blob);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return img.naturalWidth > 0 ? img : null;
  } catch {
    return null;
  } finally {
    URL.revokeObjectURL(url);
  }
}

async function encode(blob: Blob, type: "image/png" | "image/jpeg", quality?: number): Promise<Blob | null> {
  const image = await decodeBitmap(blob);
  if (!image) return null;
  const width = "naturalWidth" in image ? image.naturalWidth : image.width;
  const height = "naturalHeight" in image ? image.naturalHeight : image.height;
  try {
    if (typeof OffscreenCanvas !== "undefined") {
      const canvas = new OffscreenCanvas(width, height);
      const ctx = canvas.getContext("2d");
      if (!ctx) return null;
      ctx.drawImage(image, 0, 0);
      return await canvas.convertToBlob({ type, quality });
    }
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    ctx.drawImage(image, 0, 0);
    return await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, type, quality));
  } finally {
    if ("close" in image) image.close();
  }
}

async function sha256Of(blob: Blob): Promise<string> {
  if (typeof crypto !== "undefined" && crypto.subtle) {
    const digest = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer());
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  }
  return sha256Blob(blob);
}

export const browserImageCodec: ImageCodec = {
  async decodes(blob) {
    const image = await decodeBitmap(blob);
    if (image && "close" in image) image.close();
    return image !== null;
  },
  toPng: (blob) => encode(blob, "image/png"),
  toJpeg: (blob, quality) => encode(blob, "image/jpeg", quality),
  sha256: sha256Of,
};
