/**
 * Scene assets — every NON-video file a project references, loaded ONCE at
 * `Engine.load` (awaited before "loaded"), so preview and export read the
 * same data synchronously and an export can never start before the cursor
 * track or an image has arrived (that would ship a frame the preview never
 * showed).
 *
 *   cursor      cursor.json      (CursorRecording — events + coordinate size)
 *   keystrokes  keys.json        (KeystrokeRecording — keys, scrolls)
 *   images      every referenced image as an ImageBitmap, keyed by the
 *               project.json reference string (backgroundImagePath, the
 *               watermark / curtain-logo file names, …)
 *   cameraMask  camera-mask.ccmask (the person mask the camera looks draw
 *               through — docs/camera-cutout.md §2), parsed; only fetched
 *               while a camera-layout region carries a `look`
 *
 * Media keys are the reference strings exactly as project.json spells them
 * (see `RenderMedia.files`); `refsOf` lists the ones the engine asks for.
 */
import { CAMERA_MASK_FILE, parseCameraMask, type CameraMaskTrack } from "../../core/mask/cameraMaskCodec";
import type { SubtitleWeight } from "../../core/model/enums";
import type { RenderMedia } from "../contract";
import { loadCursorArt, type CursorArt } from "../passes/cursor/cursorArt";
import { ensureFaces } from "../raster/fontCatalog";
import { liveFetch } from "./liveUrls";

/** (fontName, fontWeight) of every annotation in a raw project.json. */
function annotationFonts(doc: Record<string, unknown>): { fontName: string | null; fontWeight: SubtitleWeight }[] {
  const list = Array.isArray(doc.annotations) ? (doc.annotations as Record<string, unknown>[]) : [];
  return list.map((a) => ({
    fontName: typeof a.fontName === "string" ? a.fontName : null,
    fontWeight: (typeof a.fontWeight === "string" ? a.fontWeight : "Semibold") as SubtitleWeight,
  }));
}

export interface SceneAssets {
  /** Parsed cursor.json (Swift CursorRecording JSON), or null. */
  cursor: unknown | null;
  /** Parsed keys.json (Swift keystroke recording JSON), or null. */
  keystrokes: unknown | null;
  /** Decoded images by project.json reference. */
  images: Map<string, ImageBitmap>;
  /** The Swift-rasterized cursor sprites (public/editor/cursors), shared by every project. */
  cursorArt?: CursorArt | null;
  /** camera-mask.ccmask, parsed (null: none / not needed / unreadable). */
  cameraMask?: CameraMaskTrack | null;
}

export const EMPTY_ASSETS: SceneAssets = { cursor: null, keystrokes: null, images: new Map(), cursorArt: null, cameraMask: null };

/** Does a raw project.json use a camera look — the whole-video
 *  `settings.cameraLook` or any camera-layout region's `look`? */
export function usesCameraLook(doc: Json): boolean {
  const settings = doc.settings && typeof doc.settings === "object" ? (doc.settings as Json) : {};
  if (settings.cameraLook === "cutout" || settings.cameraLook === "popOut") return true;
  const regions = Array.isArray(doc.cameraLayoutRegions) ? (doc.cameraLayoutRegions as unknown[]) : [];
  return regions.some((r) => {
    const look = r && typeof r === "object" ? (r as Json).look : undefined;
    return look === "cutout" || look === "popOut";
  });
}

type Json = Record<string, unknown>;

/** Every file reference a project.json carries (besides the recording). */
export function refsOf(doc: Json): { cursor?: string; keystrokes?: string; camera?: string; mask?: string; images: string[]; audio: string[] } {
  const s = (doc.settings ?? {}) as Json;
  const str = (v: unknown) => (typeof v === "string" && v ? v : undefined);
  const images = [
    str(s.backgroundImagePath),
    str(s.watermarkFileName),
    str(s.curtainLogoFileName),
    // The webcam poster the Mac saves beside the project (Project.cameraPosterURL),
    // shown before the camera's first frame — folder-relative, like the Mac.
    s.showCamera === true && str(doc.cameraVideoURL) ? "camera_poster.png" : undefined,
  ].filter((v): v is string => Boolean(v));
  const audio = ((doc.voiceOverClips as Json[] | undefined) ?? [])
    .map((c) => str(c.fileName))
    .filter((v): v is string => Boolean(v));
  return {
    cursor: str(doc.cursorDataURL),
    keystrokes: str(doc.keystrokeDataURL),
    camera: str(doc.cameraVideoURL),
    // The camera person mask (docs/camera-cutout.md §7) — folder-relative,
    // like the poster; only while a look needs it.
    mask: s.showCamera === true && str(doc.cameraVideoURL) && usesCameraLook(doc) ? CAMERA_MASK_FILE : undefined,
    images,
    audio,
  };
}

/**
 * A referenced sidecar/image that is not loaded and only NOW has a URL (a
 * file added after load). A file that already had a URL and still failed
 * (missing on the server) does not qualify — a URL refresh must not refetch it.
 */
export function missingSceneAssets(doc: Json, assets: SceneAssets, files: Record<string, string>, previous: Record<string, string> = {}): boolean {
  const refs = refsOf(doc);
  const fresh = (ref: string) => Boolean(files[ref]) && !previous[ref];
  if (refs.cursor && assets.cursor == null && fresh(refs.cursor)) return true;
  if (refs.keystrokes && assets.keystrokes == null && fresh(refs.keystrokes)) return true;
  if (refs.mask && assets.cameraMask == null && fresh(refs.mask)) return true;
  return refs.images.some((ref) => !assets.images.has(ref) && fresh(ref));
}

/** camera-mask.ccmask → a parsed track (null when absent or unreadable — the looks then draw the plain bubble). */
export async function fetchCameraMask(url: string | undefined): Promise<CameraMaskTrack | null> {
  if (!url) return null;
  try {
    const res = await liveFetch(url);
    if (!res.ok) return null;
    return parseCameraMask(new Uint8Array(await res.arrayBuffer()));
  } catch (error) {
    console.warn(`[camera] the person mask could not be read: ${String(error)}`);
    return null;
  }
}

async function fetchJson(url: string | undefined): Promise<unknown | null> {
  if (!url) return null;
  try {
    const res = await liveFetch(url);
    return res.ok ? await res.json() : null;
  } catch {
    return null;
  }
}

async function fetchBitmap(url: string): Promise<ImageBitmap | null> {
  try {
    const res = await liveFetch(url);
    if (!res.ok) return null;
    // Full colour fidelity: no premultiply surprises, honour embedded profiles.
    return await createImageBitmap(await res.blob(), { premultiplyAlpha: "premultiply", colorSpaceConversion: "default" });
  } catch {
    return null;
  }
}

export async function loadSceneAssets(doc: Json, media: RenderMedia): Promise<SceneAssets> {
  const refs = refsOf(doc);
  const files = media.files ?? {};
  const [cursorArt, cursor, keystrokes, cameraMask, ...bitmaps] = await Promise.all([
    loadCursorArt(),
    fetchJson(refs.cursor && files[refs.cursor]),
    fetchJson(refs.keystrokes && files[refs.keystrokes]),
    fetchCameraMask(refs.mask && files[refs.mask]),
    ...refs.images.map((ref) => (files[ref] ? fetchBitmap(files[ref]) : Promise.resolve(null))),
    // Annotation typefaces (local PostScript faces) — ready before the first frame / export.
    ensureFaces(annotationFonts(doc)).then(() => null),
  ]);
  const images = new Map<string, ImageBitmap>();
  refs.images.forEach((ref, i) => {
    const bmp = bitmaps[i] as ImageBitmap | null;
    if (bmp) images.set(ref, bmp);
  });
  // BackgroundLook.decodedImage: the backdrop image is decoded as an ImageIO
  // thumbnail — orientation applied, longest edge capped at maxImageEdge.
  const bgRef = typeof (doc.settings as Json | undefined)?.backgroundImagePath === "string"
    ? ((doc.settings as Json).backgroundImagePath as string)
    : null;
  const bg = bgRef ? images.get(bgRef) : undefined;
  if (bgRef && bg && Math.max(bg.width, bg.height) > MAX_BACKGROUND_EDGE) {
    const k = MAX_BACKGROUND_EDGE / Math.max(bg.width, bg.height);
    try {
      const capped = await createImageBitmap(bg, {
        resizeWidth: Math.max(1, Math.round(bg.width * k)),
        resizeHeight: Math.max(1, Math.round(bg.height * k)),
        resizeQuality: "high",
        premultiplyAlpha: "premultiply",
      });
      bg.close();
      images.set(bgRef, capped);
    } catch {
      // keep the full-size decode
    }
  }
  return { cursor, keystrokes, images, cursorArt: cursorArt as CursorArt | null, cameraMask: cameraMask as CameraMaskTrack | null };
}

/** `BackgroundLook.maxImageEdge` (core backgroundLook.maxImageEdge). */
const MAX_BACKGROUND_EDGE = 4096;

export function disposeSceneAssets(assets: SceneAssets): void {
  for (const bmp of assets.images.values()) bmp.close();
}
