/**
 * Port of the PURE parts of Services/WallpaperCatalog.swift.
 *
 * WallpaperCatalog is not a data catalog: it lists the macOS system wallpapers
 * found on disk (`/System/Library/Desktop Pictures/.thumbnails/*.heic`, the
 * "Solid Colors" PNGs, MobileAsset downloads and the app's own cache) and
 * downloads missing ones from Apple's CDN. None of that exists on the web.
 * A wallpaper background in project.json is just `backgroundType =
 * "Wallpaper"` + `backgroundImagePath` (a Mac file path): the web must use the
 * image uploaded with the cloud project bundle, and when it is missing fall
 * back exactly like BackgroundLook (vertical Oklab ramp white 0.16 → 0.09 —
 * see backgroundLook.ts `baseFill`).
 *
 * Ported (private in Swift → verbatim oracle): `baseName(strippingVariant:)`,
 * the `listItems()` name filter (calibration targets skipped; " Dark"/" Light"
 * appearance variants hidden when their base artwork is listed) over an
 * ALREADY SORTED name list, and the cache file name `"<name>.heic"`.
 * NOT ported: the filesystem scan, the `localizedStandardCompare` (Finder)
 * sort, the MobileAsset XML parse and the download/unzip.
 *
 * Locked by the golden-vector unit `wallpaperCatalogNames`.
 */

/** `baseName(strippingVariant:)` — the name without a " Dark"/" Light" suffix, else null. */
export function baseName(name: string): string | null {
  for (const suffix of [" Dark", " Light"]) {
    if (name.endsWith(suffix)) return name.slice(0, name.length - suffix.length);
  }
  return null;
}

/** The `listItems()` name filter over sorted thumbnail base names. */
export function listedNames(sortedNames: readonly string[]): string[] {
  const names = new Set(sortedNames);
  const out: string[] = [];
  for (const name of sortedNames) {
    if (name.toLowerCase().startsWith("calibrate")) continue;
    const base = baseName(name);
    if (base !== null && names.has(base)) continue;
    out.push(name);
  }
  return out;
}

/** Cached full-res file name for a wallpaper. */
export function cacheFileName(name: string): string {
  return `${name}.heic`;
}
