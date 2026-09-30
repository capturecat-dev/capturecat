/**
 * The inspector's image pickers, wired like the Mac panes:
 *
 *   Background "Choose Image…"  BackgroundSettingsPaneAppKit: the image is
 *                               used as the background AND remembered in the
 *                               image library (CustomWallpaperStore.add)
 *   library tiles               use / "Set as Default" / "Remove from Library"
 *   Brand "Choose/Replace Logo…" BrandSettingsPaneAppKit.pickLogo:
 *                               `watermark-<UUID8>.<ext>`, Show Watermark on
 *   Curtain "Choose Logo…"      EffectsSettingsPaneAppKit.pickCurtainLogo:
 *                               `curtain-logo-<UUID8>.<ext>`
 *
 * A chosen file is normalized (state/imageImport.ts — the Mac's accepted
 * types, CloudImageTranscoder's HEIC/TIFF/BMP → PNG, the 64 MB ceiling),
 * handed to the project's media (state/projectMedia.ts: renders at once via
 * the engine's live media map; a cloud project uploads it, a local dev
 * project keeps it in this tab), and only then does the setting change — so
 * the engine already has the file when the new project reaches it.
 *
 * Replacing a logo does not delete the previous file (the Mac does): undo
 * must be able to bring it back, and the cloud keeps it content-addressed.
 */
import { useCallback, useEffect, useMemo, useState } from "react";

import type { ProjectSettings } from "../core/model";
import {
  backgroundFileName,
  curtainLogoFileName,
  extensionForType,
  ImageImportError,
  imageDisplayName,
  importImage,
  PICKER_ACCEPT,
  projectFilePath,
  watermarkFileName,
  type ImagePickerKind,
} from "../state/imageImport";
import { imageLibrary, type LibraryImage } from "../state/imageLibrary";
import type { LoadedEditorProject } from "../state/projectSource";
import { useEditorStore, type EditorStore } from "../state/store";
import type { BackgroundImageTile, PaneActions, PickerStatus } from "./panes/types";

/** A library tile whose image is not in this project yet. */
const LIBRARY_PREFIX = "library:";

/** Open the browser's file chooser. Resolves null when cancelled. */
export function pickFile(accept: string): Promise<File | null> {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = accept;
    input.style.display = "none";
    let settled = false;
    const done = (file: File | null) => {
      if (settled) return;
      settled = true;
      input.remove();
      resolve(file);
    };
    input.addEventListener("change", () => done(input.files?.[0] ?? null), { once: true });
    input.addEventListener("cancel", () => done(null), { once: true });
    document.body.appendChild(input);
    input.click();
  });
}

function messageOf(error: unknown): string {
  if (error instanceof ImageImportError) return error.message;
  const text = error instanceof Error ? error.message : String(error);
  return `Couldn’t add the image: ${text}`;
}

interface PickedImage {
  blob: Blob;
  name: string;
  ext: string;
  contentType: string;
  sha256: string;
}

export function useMediaPickers(store: EditorStore, loaded: LoadedEditorProject | null): Partial<PaneActions> {
  const media = loaded?.media ?? null;
  const project = useEditorStore(store, (s) => s.project);
  const [library, setLibrary] = useState<LibraryImage[]>([]);
  const [status, setStatus] = useState<Partial<Record<ImagePickerKind, PickerStatus>>>({});
  const [, setMediaVersion] = useState(0);

  useEffect(() => {
    const lib = imageLibrary();
    let alive = true;
    const load = () =>
      void lib.list().then(
        (list) => alive && setLibrary(list),
        () => undefined,
      );
    load();
    const off = lib.subscribe(load);
    return () => {
      alive = false;
      off();
    };
  }, []);

  // URL refreshes and uploads re-render the tiles (fresh thumbnail URLs, new refs).
  useEffect(() => media?.subscribe(() => setMediaVersion((n) => n + 1)), [media]);

  const setKind = useCallback((kind: ImagePickerKind, value: PickerStatus | null) => {
    setStatus((prev) => {
      const next = { ...prev };
      if (value) next[kind] = value;
      else delete next[kind];
      return next;
    });
  }, []);

  const run = useCallback(
    async (kind: ImagePickerKind, task: () => Promise<void>) => {
      setKind(kind, { busy: "Preparing image…" });
      try {
        await task();
        setKind(kind, null);
      } catch (error) {
        setKind(kind, { error: messageOf(error) });
      }
    },
    [setKind],
  );

  const apply = useCallback(
    (patch: Partial<ProjectSettings>, label: string) => {
      store.updateSettings(patch, label);
      store.endCoalescing();
    },
    [store],
  );

  /** Add a file to the project (engine sees it first), then write the setting. */
  const addAndApply = useCallback(
    async (kind: ImagePickerKind, file: { ref: string; path: string; image: PickedImage }, patch: Partial<ProjectSettings>, label: string) => {
      if (!media) throw new ImageImportError("The project is still loading.");
      if (!media.canAddFiles) throw new ImageImportError("Only the project’s owner can add images to it.");
      const name = store.getState().project?.name;
      if (name) media.setName(name);
      const persisted = media.addFile({
        ref: file.ref,
        path: file.path,
        blob: file.image.blob,
        sha256: file.image.sha256,
        contentType: file.image.contentType,
      });
      apply(patch, label);
      if (media.origin === "cloud") {
        setKind(kind, { busy: kind === "background" ? "Uploading image…" : "Uploading logo…" });
        try {
          await persisted;
        } catch (error) {
          // The file stays in this tab (the next pick retries its upload).
          const what = kind === "background" ? "image" : "logo";
          throw new ImageImportError(`Couldn’t upload the ${what}: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
    },
    [media, store, apply, setKind],
  );

  /** Use an image as the background: an identical file already in the project is reused. */
  const applyBackgroundImage = useCallback(
    async (image: PickedImage) => {
      if (!media) throw new ImageImportError("The project is still loading.");
      const current = store.getState().project?.settings.backgroundImagePath;
      const existing = media.backgroundRefForSha(image.sha256);
      if (existing) {
        if (existing !== current) apply({ backgroundImagePath: existing }, "Background Image");
        return;
      }
      const fileName = backgroundFileName(image.name, image.ext, image.sha256, media.takenBy);
      const ref = projectFilePath(media.projectId, fileName);
      await addAndApply("background", { ref, path: fileName, image }, { backgroundImagePath: ref }, "Background Image");
    },
    [media, store, apply, addAndApply],
  );

  const chooseBackground = useCallback(async () => {
    const file = await pickFile(PICKER_ACCEPT.background);
    if (!file) return;
    await run("background", async () => {
      const img = await importImage(file, "background");
      const picked: PickedImage = { blob: img.blob, name: img.baseName, ext: img.ext, contentType: img.contentType, sha256: img.sha256 };
      // CustomWallpaperStore.add — the pick reappears as a library tile.
      await imageLibrary()
        .add(picked)
        .catch(() => undefined);
      await applyBackgroundImage(picked);
    });
  }, [run, applyBackgroundImage]);

  const chooseLogo = useCallback(
    async (kind: "watermark" | "curtainLogo") => {
      const file = await pickFile(PICKER_ACCEPT[kind]);
      if (!file) return;
      await run(kind, async () => {
        const img = await importImage(file, kind);
        const image: PickedImage = { blob: img.blob, name: img.baseName, ext: img.ext, contentType: img.contentType, sha256: img.sha256 };
        if (kind === "watermark") {
          const name = watermarkFileName(img.ext);
          await addAndApply(kind, { ref: name, path: name, image }, { watermarkFileName: name, showWatermark: true }, "Choose Logo");
        } else {
          const name = curtainLogoFileName(img.ext);
          await addAndApply(kind, { ref: name, path: name, image }, { curtainLogoFileName: name }, "Choose Logo");
        }
      });
    },
    [run, addAndApply],
  );

  // ── Background tiles ──────────────────────────────────────────────────

  const shaByPath = new Map<string, string>();
  const libraryTiles: BackgroundImageTile[] = library.map((image) => {
    const path = media?.backgroundRefForSha(image.sha256) ?? `${LIBRARY_PREFIX}${image.sha256}`;
    shaByPath.set(path, image.sha256);
    return { path, name: image.name, thumbnailUrl: imageLibrary().thumbnailUrl(image) };
  });
  const settings = project?.settings;
  const bgPath = settings?.backgroundImagePath;
  const usesImage = settings?.backgroundType === "Wallpaper" || settings?.backgroundType === "Image";
  const currentTile: BackgroundImageTile | null =
    bgPath && usesImage ? { path: bgPath, name: imageDisplayName(bgPath), thumbnailUrl: media?.mediaUrl(bgPath) } : null;

  const selectTile = (tile: BackgroundImageTile) => {
    const sha = shaByPath.get(tile.path);
    if (tile.path.startsWith(LIBRARY_PREFIX) && sha) {
      void run("background", async () => {
        const image = await imageLibrary().get(sha);
        if (!image) throw new ImageImportError("This image is no longer in your library.");
        await applyBackgroundImage({ blob: image.blob, name: image.name, ext: image.ext, contentType: image.contentType, sha256: image.sha256 });
      });
      return;
    }
    if (tile.path !== store.getState().project?.settings.backgroundImagePath) apply({ backgroundImagePath: tile.path }, "Background Image");
  };

  const setDefault = (tile: BackgroundImageTile) => {
    const sha = shaByPath.get(tile.path);
    if (sha) {
      void imageLibrary().setDefault(sha);
      return;
    }
    // The project's own image (a Mac wallpaper, say): remember it, then default to it.
    void run("background", async () => {
      const url = media?.mediaUrl(tile.path);
      if (!url) throw new ImageImportError("This image isn’t available in the browser.");
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const blob = await res.blob();
      const ext = extensionForType(blob.type) || "png";
      const img = await importImage(new File([blob], `${tile.name}.${ext}`, { type: blob.type }), "background");
      const saved = await imageLibrary().add({ blob: img.blob, name: tile.name, ext: img.ext, contentType: img.contentType, sha256: img.sha256 });
      await imageLibrary().setDefault(saved.sha256);
      // The new library tile IS this project's image — one tile, already selected.
      media?.rememberBackgroundRef(saved.sha256, tile.path);
    });
  };

  const removeFromLibrary = (tile: BackgroundImageTile) => {
    const sha = shaByPath.get(tile.path);
    if (sha) void imageLibrary().remove(sha);
  };

  const onChooseBackgroundImage = useCallback(() => void chooseBackground(), [chooseBackground]);
  const onChooseWatermark = useCallback(() => void chooseLogo("watermark"), [chooseLogo]);
  const onChooseCurtainLogo = useCallback(() => void chooseLogo("curtainLogo"), [chooseLogo]);

  const libraryKey = libraryTiles.map((t) => `${t.path}|${t.thumbnailUrl}`).join(",");
  const currentKey = currentTile ? `${currentTile.path}|${currentTile.thumbnailUrl}` : "";
  const backgroundImages = useMemo(
    () => ({ library: libraryTiles, current: currentTile, onSelect: selectTile, onSetDefault: setDefault, onRemoveFromLibrary: removeFromLibrary }),
    // Tiles are rebuilt each render; the object only changes when they do.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [libraryKey, currentKey, media, run, applyBackgroundImage, apply],
  );

  if (!loaded) return {};
  return {
    onChooseBackgroundImage,
    onChooseWatermark,
    onChooseCurtainLogo,
    pickerStatus: status,
    backgroundImages,
  };
}
