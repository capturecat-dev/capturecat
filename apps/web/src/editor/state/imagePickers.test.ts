/**
 * The image pickers' rules (Mac parity) and persistence:
 *   imageImport  accepted types per picker, HEIC/TIFF/BMP → PNG (→ JPEG 0.95
 *                over 64 MB), file naming (watermark-/curtain-logo-<UUID8>,
 *                CustomWallpaperStore collision suffix), project-folder refs
 *   imageLibrary content de-dupe, newest first, default background (type
 *                Wallpaper), Remove clears the default
 *   ProjectMedia a chosen file resolves at once, a cloud project stages the
 *                COMPLETE manifest (existing files + sources kept) and the
 *                save waits for the upload; local projects stay in memory
 *   publish      a new web project starts with the default background
 */
import { describe, expect, it, vi } from "vitest";

import { parseProjectText, serializeProjectText } from "../core/model";
import { missingSceneAssets } from "../engine/media/assets";
import { projectDocumentFor } from "../record/publish";
import type { RecordedTake } from "../record/session";
import { resolveMediaRef, type CloudMediaFile, type LoadedCloudProject, type ManifestFile } from "./cloud";
import {
  backgroundFileName,
  curtainLogoFileName,
  imageDisplayName,
  ImageImportError,
  importImage,
  MAX_IMAGE_BYTES,
  projectFilePath,
  sanitizeFileBase,
  watermarkFileName,
  type ImageCodec,
} from "./imageImport";
import { ImageLibrary, MemoryLibraryBackend } from "./imageLibrary";
import { MediaUrlRefresher } from "./mediaRefresh";
import { ProjectMedia } from "./projectMedia";

const ID = "0B8D6C1E-3A7F-4E2B-9C5D-1F2E3A4B5C6D";

/** A codec where every image decodes; `undecodable` extensions fail like HEIC in Chrome. */
function codec(opts: { undecodable?: boolean; pngBytes?: number; jpegBytes?: number } = {}): ImageCodec & { toPng: ReturnType<typeof vi.fn> } {
  return {
    decodes: async () => true,
    toPng: vi.fn(async () => (opts.undecodable ? null : new Blob([new Uint8Array(opts.pngBytes ?? 10)], { type: "image/png" }))),
    toJpeg: async () => new Blob([new Uint8Array(opts.jpegBytes ?? 8)], { type: "image/jpeg" }),
    sha256: async (b) => `${b.type.replace("/", "-")}-${b.size}`.padEnd(64, "0"),
  };
}

const file = (name: string, type = "", size = 16) => new File([new Uint8Array(size)], name, { type });

describe("importImage — the Mac's accepted types + CloudImageTranscoder", () => {
  it("passes browser formats through untouched", async () => {
    const c = codec();
    const img = await importImage(file("Logo.PNG", "image/png"), "watermark", c);
    expect(img).toMatchObject({ ext: "png", contentType: "image/png", baseName: "Logo", transcoded: false });
    expect(c.toPng).not.toHaveBeenCalled();
    const jpeg = await importImage(file("photo.jpeg"), "background", c);
    expect(jpeg).toMatchObject({ ext: "jpeg", contentType: "image/jpeg" });
  });

  it("re-encodes HEIC / TIFF / BMP as PNG once", async () => {
    for (const name of ["Sonoma.heic", "scan.tiff", "old.bmp", "shot.HEIF"]) {
      const img = await importImage(file(name), "background", codec());
      expect(img).toMatchObject({ ext: "png", contentType: "image/png", transcoded: true });
    }
  });

  it("falls back to JPEG 0.95 when the PNG is over 64 MB, refuses when both are", async () => {
    const big = await importImage(file("huge.tiff"), "background", codec({ pngBytes: MAX_IMAGE_BYTES + 1 }));
    expect(big).toMatchObject({ ext: "jpg", contentType: "image/jpeg" });
    await expect(importImage(file("huge.tiff"), "background", codec({ pngBytes: MAX_IMAGE_BYTES + 1, jpegBytes: MAX_IMAGE_BYTES + 1 }))).rejects.toThrow(
      "larger than 64 MB",
    );
    await expect(importImage(file("huge.png", "image/png", MAX_IMAGE_BYTES + 1), "background", codec())).rejects.toThrow("larger than 64 MB");
  });

  it("says plainly when this browser cannot open HEIC", async () => {
    await expect(importImage(file("IMG_0001.heic"), "watermark", codec({ undecodable: true }))).rejects.toThrow(
      "This browser can’t open HEIC images. Choose a PNG or JPEG instead.",
    );
  });

  it("enforces each picker's types (logos: PNG, JPEG, TIFF, HEIC; never SVG or PDF)", async () => {
    await expect(importImage(file("logo.gif", "image/gif"), "watermark", codec())).rejects.toBeInstanceOf(ImageImportError);
    await expect(importImage(file("logo.webp"), "curtainLogo", codec())).rejects.toThrow("Choose a PNG, JPEG, TIFF or HEIC image.");
    await expect(importImage(file("logo.pdf"), "curtainLogo", codec())).rejects.toThrow();
    await expect(importImage(file("icon.svg"), "background", codec())).rejects.toThrow();
    await expect(importImage(file("notes.txt"), "background", codec())).rejects.toThrow();
    expect((await importImage(file("anim.gif"), "background", codec())).ext).toBe("gif");
    // No extension: the MIME type decides.
    expect((await importImage(file("pasted", "image/png"), "background", codec())).ext).toBe("png");
  });
});

describe("file names + project refs", () => {
  it("names logos like the Mac panes (8 uppercase hex from a UUID)", () => {
    expect(watermarkFileName("PNG", "AB12CD34")).toBe("watermark-AB12CD34.png");
    expect(curtainLogoFileName("jpeg", "0F0F0F0F")).toBe("curtain-logo-0F0F0F0F.jpeg");
    expect(watermarkFileName("png")).toMatch(/^watermark-[0-9A-F]{8}\.png$/);
  });

  it("keeps a background's name, suffixing the hash only on a collision (CustomWallpaperStore.add)", () => {
    const sha = "0123456789abcdef".repeat(4);
    expect(backgroundFileName("Beach Day", "jpg", sha, () => undefined)).toBe("Beach Day.jpg");
    expect(backgroundFileName("Beach Day", "jpg", sha, () => sha)).toBe("Beach Day.jpg"); // same bytes: reuse
    expect(backgroundFileName("Beach Day", "jpg", sha, () => "other")).toBe("Beach Day-0123456789.jpg");
  });

  it("sanitizes names to the cloud's path rules", () => {
    expect(sanitizeFileBase("Café — «Summer»")).toBe("Cafe Summer");
    expect(sanitizeFileBase("Screen Shot 2026-09-30 at 10.00.00")).toBe("Screen Shot 2026-09-30 at 10.00.00");
    expect(sanitizeFileBase(".hidden")).toBe("hidden");
    expect(sanitizeFileBase("日本")).toBe("Image");
    expect(sanitizeFileBase("a".repeat(300)).length).toBeLessThanOrEqual(100);
  });

  it("refers to a background Mac-style and resolves it against the cloud manifest", () => {
    const ref = projectFilePath(ID, "Beach Day.jpg");
    expect(ref).toBe(`/CaptureCat/Projects/${ID}/Beach Day.jpg`);
    const f: CloudMediaFile = { path: "Beach Day.jpg", sha256: "x", bytes: 1, contentType: "image/jpeg", source: null, url: "https://r2/b" };
    expect(resolveMediaRef({ media: { [f.path]: f }, sources: {} }, ref)?.url).toBe("https://r2/b");
    expect(imageDisplayName(ref)).toBe("Beach Day");
    expect(imageDisplayName("/Users/me/Library/Application Support/CaptureCat/Wallpapers/Sonoma Horizon.heic")).toBe("Sonoma Horizon");
  });
});

describe("image library (CustomWallpaperStore, per browser)", () => {
  const img = (sha: string, name = sha) => ({ blob: new Blob([sha]), name, ext: "png", contentType: "image/png", sha256: sha });

  it("de-dupes by content, lists newest first, and defaults as Wallpaper", async () => {
    let now = 1;
    const lib = new ImageLibrary(new MemoryLibraryBackend(), { now: () => now++ });
    await lib.add(img("a", "First"));
    await lib.add(img("b", "Second"));
    const again = await lib.add(img("a", "Renamed copy"));
    expect(again.name).toBe("First");
    expect((await lib.list()).map((i) => i.sha256)).toEqual(["b", "a"]);

    expect(await lib.defaultBackground()).toBeNull();
    await lib.setDefault("a");
    expect(await lib.defaultBackground()).toMatchObject({ image: { sha256: "a" }, type: "Wallpaper" });
    await lib.setDefault("missing"); // not in the library → ignored
    expect(await lib.defaultSha()).toBe("a");

    const heard = vi.fn();
    lib.subscribe(heard);
    await lib.remove("a");
    expect(heard).toHaveBeenCalled();
    expect(await lib.defaultBackground()).toBeNull(); // Remove clears the default
    expect((await lib.list()).map((i) => i.sha256)).toEqual(["b"]);
  });
});

describe("ProjectMedia — adding a chosen file", () => {
  const cloudFile = (path: string, source: string | null = null, sha = path.padEnd(64, "0")): CloudMediaFile => ({
    path,
    sha256: sha,
    bytes: 3,
    contentType: path.endsWith(".mov") ? "video/quicktime" : path.endsWith(".json") ? "application/json" : "image/png",
    source,
    url: `https://r2.test/${path}`,
  });

  function cloudProject(files: CloudMediaFile[], access: "owner" | "member" = "owner"): LoadedCloudProject {
    const media: Record<string, CloudMediaFile> = {};
    const sources: Record<string, string> = {};
    for (const f of files) {
      media[f.path] = f;
      if (f.source) sources[f.source] = f.path;
    }
    return {
      projectId: ID,
      name: "Demo",
      revision: 2,
      documentSha256: null,
      access,
      isOwner: access === "owner",
      orgId: null,
      updatedAt: "",
      document: "{}",
      media,
      sources,
      urlsExpireAt: Date.now() + 900_000,
    };
  }

  it("CLOUD: resolves at once, stages the complete manifest, and settles after finalize", async () => {
    const wall = "/Users/me/Library/Application Support/CaptureCat/Wallpapers/Sonoma.heic";
    const existing = [cloudFile("recording.mov"), cloudFile("cursor.json"), cloudFile("external/aaaabbbbcccc.png", wall, "f".repeat(64))];
    const loaded = cloudProject(existing);
    let release!: () => void;
    const commits: { name: string; manifest: ManifestFile[]; blob: Blob | undefined }[] = [];
    const commitFiles = vi.fn(async (_id: string, opts: { name: string; manifest: ManifestFile[]; blobFor: (s: string) => Blob | undefined }) => {
      commits.push({ name: opts.name, manifest: opts.manifest, blob: opts.blobFor("b".repeat(64)) });
      await new Promise<void>((r) => (release = r));
      return { projectId: ID, revision: 2, documentSha256: null, missing: [], presentCount: 3, expiresIn: 900 };
    });
    const refresher = new MediaUrlRefresher(ID, loaded, { fetchUrls: async () => loaded });
    const media = new ProjectMedia({ projectId: ID, origin: "cloud", cloud: loaded, refresher, commitFiles, createObjectURL: () => "blob:bg" });
    media.setName("Renamed");

    const ref = projectFilePath(ID, "Beach.png");
    const blob = new Blob(["img"], { type: "image/png" });
    const persisted = media.addFile({ ref, path: "Beach.png", blob, sha256: "b".repeat(64), contentType: "image/png" });
    expect(media.mediaUrl(ref)).toBe("blob:bg"); // renders before the upload finishes
    expect(media.uploading).toBe(true);

    let saved = false;
    const save = media.settled().then(() => (saved = true));
    await Promise.resolve();
    await vi.waitFor(() => expect(commits).toHaveLength(1));
    expect(saved).toBe(false); // the save waits for the upload
    const { manifest } = commits[0];
    expect(commits[0].name).toBe("Renamed");
    expect(commits[0].blob).toBe(blob);
    expect(manifest.map((m) => m.path).sort()).toEqual(["Beach.png", "cursor.json", "external/aaaabbbbcccc.png", "recording.mov"]);
    // The Mac's source mapping of its converted wallpaper survives the restage.
    expect(manifest.find((m) => m.path === "external/aaaabbbbcccc.png")?.source).toBe(wall);
    expect(manifest.find((m) => m.path === "Beach.png")?.source).toBe(ref);

    release();
    await persisted;
    await save;
    expect(saved).toBe(true);
    expect(media.uploading).toBe(false);
    // Reuse: the same bytes again → the ref the project already has (the Mac's own spelling for its wallpaper).
    expect(media.backgroundRefForSha("b".repeat(64))).toBe(ref);
    expect(media.backgroundRefForSha("f".repeat(64))).toBe(wall);
    expect(media.takenBy("beach.PNG")).toBe("b".repeat(64));
  });

  it("CLOUD: a failed upload rejects the pick but never blocks the save", async () => {
    const loaded = cloudProject([cloudFile("recording.mov")]);
    const media = new ProjectMedia({
      projectId: ID,
      origin: "cloud",
      cloud: loaded,
      refresher: new MediaUrlRefresher(ID, loaded, { fetchUrls: async () => loaded }),
      commitFiles: async () => {
        throw new Error("Storage limit reached");
      },
      createObjectURL: () => "blob:x",
    });
    const pick = media.addFile({ ref: "watermark-AB12CD34.png", path: "watermark-AB12CD34.png", blob: new Blob(["x"]), sha256: "c".repeat(64), contentType: "image/png" });
    await expect(pick).rejects.toThrow("Storage limit reached");
    await expect(media.settled()).resolves.toBeUndefined();
  });

  it("CLOUD: a team member cannot add files (media is owner-only)", () => {
    const loaded = cloudProject([cloudFile("recording.mov")], "member");
    const media = new ProjectMedia({ projectId: ID, origin: "cloud", cloud: loaded, refresher: new MediaUrlRefresher(ID, loaded, { fetchUrls: async () => loaded }) });
    expect(media.canAddFiles).toBe(false);
  });

  it("LOCAL (dev, read-only folder): the file lives in this tab only", async () => {
    const commitFiles = vi.fn();
    const media = new ProjectMedia({
      projectId: ID,
      origin: "local",
      localUrl: (r) => `/__dev/local-projects/${ID}/media?ref=${encodeURIComponent(r)}`,
      commitFiles,
      createObjectURL: () => "blob:logo",
    });
    await media.addFile({ ref: "curtain-logo-0F0F0F0F.png", path: "curtain-logo-0F0F0F0F.png", blob: new Blob(["x"]), sha256: "d".repeat(64), contentType: "image/png" });
    expect(commitFiles).not.toHaveBeenCalled();
    expect(media.addsAreSessionOnly).toBe(true);
    expect(media.mediaUrl("curtain-logo-0F0F0F0F.png")).toBe("blob:logo");
    expect(media.mediaUrl("recording.mov")).toContain("/__dev/local-projects/");
    expect(media.takenBy("thumbnail.jpg")).toBe(""); // never shadow the Mac's own files
    // The engine map includes the new file (and keeps it for undo).
    const map = media.engineMedia({ videoURL: "file:///x/recording.mov", settings: {} });
    expect(map.files["curtain-logo-0F0F0F0F.png"]).toBe("blob:logo");
    expect(map.expiresAt).toBeNull();
  });
});

describe("live injection — the engine reloads assets only for a file that just arrived", () => {
  const doc = { settings: { backgroundImagePath: "/CaptureCat/Projects/X/Beach.png", watermarkFileName: "watermark-AB12CD34.png" } };
  const assets = (loaded: string[]) => ({ cursor: null, keystrokes: null, images: new Map(loaded.map((r) => [r, {} as ImageBitmap])) });

  it("a referenced image that now has a URL loads; a refresh of one that failed does not refetch", () => {
    const bg = doc.settings.backgroundImagePath;
    const wm = doc.settings.watermarkFileName;
    // The watermark was chosen: it had no URL before this push.
    expect(missingSceneAssets(doc, assets([bg]), { [bg]: "u1", [wm]: "blob:w" }, { [bg]: "u1" })).toBe(true);
    // Everything loaded: a URL refresh changes nothing.
    expect(missingSceneAssets(doc, assets([bg, wm]), { [bg]: "u2", [wm]: "blob:w" }, { [bg]: "u1", [wm]: "blob:w" })).toBe(false);
    // The watermark had a URL and still failed (missing on the server): a refresh must not refetch it every 13 minutes.
    expect(missingSceneAssets(doc, assets([bg]), { [bg]: "u2", [wm]: "u2w" }, { [bg]: "u1", [wm]: "u1w" })).toBe(false);
  });
});

describe("new web projects start with the default background", () => {
  const take: RecordedTake = {
    id: ID,
    screen: new File([new Uint8Array(8)], "recording.mov"),
    camera: null,
    poster: null,
    duration: 3,
    cameraTimeOffset: 0,
    surface: "monitor",
    sourceLabel: "Screen",
    width: 1920,
    height: 1080,
    hasSystemAudio: false,
    hasMic: false,
    folder: null,
  };

  it("applies it like CustomWallpaperStore.applyDefaultBackground (type Wallpaper + project path)", () => {
    const text = projectDocumentFor(take, "Demo", { fileName: "Beach.png", type: "Wallpaper" });
    const doc = JSON.parse(text);
    expect(doc.settings.backgroundType).toBe("Wallpaper");
    expect(doc.settings.backgroundImagePath).toBe(`/CaptureCat/Projects/${ID}/Beach.png`);
    expect(serializeProjectText(parseProjectText(text))).toBe(text);
  });

  it("without one, the Mac's defaults", () => {
    const doc = JSON.parse(projectDocumentFor(take, "Demo", null));
    expect(doc.settings).toEqual(JSON.parse(projectDocumentFor(take)).settings);
    expect(doc.settings.backgroundImagePath ?? null).toBeNull();
  });
});
