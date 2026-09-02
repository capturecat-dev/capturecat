import Foundation
import CryptoKit

/// User-added background images, remembered as reusable wallpapers.
///
/// When the user picks a custom image (Choose Image… in the Background pane),
/// a copy lands in Application Support next to the catalog cache
/// (`CaptureCat/Wallpapers/Custom`) and shows up as a tile in the wallpaper
/// picker from then on. The library is the directory listing itself — same
/// convention as `WallpaperCatalog.cacheDirectory`, no separate index file.
///
/// Projects keep referencing whatever absolute path was applied at the time
/// (`settings.backgroundImagePath`); the preview compositor and the exporter
/// both read that same path, so nothing here forks the render paths.
enum CustomWallpaperStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Wallpapers/Custom", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp",
    ]

    /// Library images, stable order (newest first so a fresh add is visible).
    static func listItems() -> [WallpaperCatalog.Item] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        return files.map { url in
            WallpaperCatalog.Item(
                name: displayName(for: url),
                thumbnailURL: url,
                localURL: url
            )
        }
    }

    static func contains(path: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().path == directory.path
    }

    /// Copies `source` into the library and returns the stored copy.
    /// De-duplicated by content hash: adding the same image twice returns the
    /// existing copy. A name collision with different content gets a short
    /// hash suffix so both survive.
    @discardableResult
    static func add(from source: URL) -> URL? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: source) else { return nil }
        let digest = SHA256.hash(data: data)
        let hashPrefix = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(10)

        // Already in the library (added before, or a re-add of the same file)?
        for item in listItems() {
            guard let url = item.localURL,
                  let existing = try? Data(contentsOf: url),
                  existing.count == data.count,
                  SHA256.hash(data: existing) == digest else { continue }
            return url
        }

        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        var dest = directory.appendingPathComponent("\(base).\(ext)")
        if fm.fileExists(atPath: dest.path) {
            dest = directory.appendingPathComponent("\(base)-\(hashPrefix).\(ext)")
        }
        do {
            try data.write(to: dest)
            return dest
        } catch {
            print("[Wallpaper] failed to store custom image \(source.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Deletes a stored copy. Projects that applied it keep their own
    /// `backgroundImagePath` reference; the renderers already tolerate a
    /// missing file (background decodes to nil).
    static func remove(path: String) {
        guard contains(path: path) else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        if defaultBackground()?.path == path {
            clearDefaultBackground()
        }
    }

    private static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Default background for new projects

    // UserDefaults is the app's convention for user-level (non-project)
    // settings — see AppState.DefaultsKey. Raw values are persistence
    // identity; never rename these keys.
    private static let defaultPathKey = "defaultBackgroundImagePath"
    private static let defaultTypeKey = "defaultBackgroundType"

    /// The wallpaper new projects start with, if the user set one and the
    /// file still exists. Custom tiles live inside the wallpaper picker, so
    /// the type is `.wallpaper` for both catalog and custom defaults — the
    /// Background pane then opens on the grid with the tile highlighted.
    static func defaultBackground() -> (path: String, type: ProjectSettings.BackgroundType)? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: defaultPathKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        let type = defaults.string(forKey: defaultTypeKey)
            .flatMap(ProjectSettings.BackgroundType.init(rawValue:)) ?? .wallpaper
        return (path, type)
    }

    static func setDefaultBackground(path: String) {
        let defaults = UserDefaults.standard
        defaults.set(path, forKey: defaultPathKey)
        defaults.set(ProjectSettings.BackgroundType.wallpaper.rawValue, forKey: defaultTypeKey)
    }

    static func clearDefaultBackground() {
        UserDefaults.standard.removeObject(forKey: defaultPathKey)
        UserDefaults.standard.removeObject(forKey: defaultTypeKey)
    }

    /// Applies the user's default wallpaper to a freshly created project's
    /// settings. Called from the real creation flows in AppState — NOT from
    /// `Project.init`, which the deterministic harness fixtures also use.
    static func applyDefaultBackground(to settings: ProjectSettings) {
        guard let def = defaultBackground() else { return }
        settings.backgroundType = def.type
        settings.backgroundImagePath = def.path
    }
}
