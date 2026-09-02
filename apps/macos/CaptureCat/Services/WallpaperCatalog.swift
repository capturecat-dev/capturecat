import Foundation

/// The full macOS wallpaper catalog. Thumbnails for EVERY wallpaper ship with
/// the OS in `/System/Library/Desktop Pictures/.thumbnails`, but full-res
/// images only exist locally once downloaded (System Settings does this via
/// MobileAsset). The asset catalog XML maps every wallpaper to a public
/// Apple-CDN zip, so we can fetch missing ones on demand and cache them in
/// the app container.
enum WallpaperCatalog {
    struct Item: Identifiable, Equatable {
        let name: String
        let thumbnailURL: URL
        /// Full-resolution local file, if the wallpaper is available (system
        /// download, app cache, or a Solid Colors PNG). nil = needs download.
        var localURL: URL?

        var id: String { name }
    }

    private static let systemDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
    private static let assetsDir = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture", isDirectory: true)

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Listing

    static func listItems() -> [Item] {
        let fm = FileManager.default
        let localByName = downloadedAssetMap().merging(cachedMap()) { _, cached in cached }

        let thumbsDir = systemDir.appendingPathComponent(".thumbnails")
        let thumbs = ((try? fm.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "heic" }
        let names = Set(thumbs.map { $0.deletingPathExtension().lastPathComponent })

        var items: [Item] = []
        for url in thumbs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = url.deletingPathExtension().lastPathComponent
            // Display calibration targets are not wallpapers.
            if name.lowercased().hasPrefix("calibrate") { continue }
            // Dark/Light appearance variants resolve to the same downloadable
            // asset — list only the base artwork when it exists.
            if let base = baseName(strippingVariant: name), names.contains(base) { continue }
            items.append(Item(name: name, thumbnailURL: url, localURL: localByName[name]))
        }

        // Solid Colors ship as ready-to-use PNGs.
        let solidDir = systemDir.appendingPathComponent("Solid Colors")
        let solids = ((try? fm.contentsOfDirectory(at: solidDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in solids {
            let name = url.deletingPathExtension().lastPathComponent
            items.append(Item(name: name, thumbnailURL: url, localURL: url))
        }

        return items
    }

    private static func baseName(strippingVariant name: String) -> String? {
        for suffix in [" Dark", " Light"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    /// Full-res wallpapers System Settings has already downloaded.
    private static func downloadedAssetMap() -> [String: URL] {
        let fm = FileManager.default
        var map: [String: URL] = [:]
        let assets = (try? fm.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil)) ?? []
        for asset in assets where asset.pathExtension == "asset" {
            let dataDir = asset.appendingPathComponent("AssetData")
            let files = (try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension.lowercased() == "heic" {
                map[file.deletingPathExtension().lastPathComponent] = file
            }
        }
        return map
    }

    /// Wallpapers this app downloaded itself.
    private static func cachedMap() -> [String: URL] {
        let fm = FileManager.default
        var map: [String: URL] = [:]
        let files = (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "heic" {
            map[file.deletingPathExtension().lastPathComponent] = file
        }
        return map
    }

    // MARK: - On-demand download

    enum DownloadError: LocalizedError {
        case notInCatalog
        case badArchive

        var errorDescription: String? {
            switch self {
            case .notInCatalog: return "This wallpaper isn't in the system catalog."
            case .badArchive: return "The downloaded wallpaper couldn't be unpacked."
            }
        }
    }

    /// DesktopPictureID → CDN zip URL, parsed once from the MobileAsset XML.
    private static let remoteAssets: [String: URL] = {
        let xml = assetsDir.appendingPathComponent("com_apple_MobileAsset_DesktopPicture.xml")
        guard let data = try? Data(contentsOf: xml),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let assets = plist["Assets"] as? [[String: Any]] else {
            return [:]
        }
        var map: [String: URL] = [:]
        for entry in assets {
            guard let id = entry["DesktopPictureID"] as? String,
                  let base = entry["__BaseURL"] as? String,
                  let relative = entry["__RelativePath"] as? String,
                  let url = URL(string: base + relative) else { continue }
            map[id] = url
        }
        return map
    }()

    /// Downloads the full-res wallpaper for `name`, caches it, and returns
    /// the cached file URL.
    static func download(_ name: String) async throws -> URL {
        let remote = remoteAssets[name]
            ?? baseName(strippingVariant: name).flatMap { remoteAssets[$0] }
        guard let remote else { throw DownloadError.notInCatalog }

        let (zipURL, _) = try await URLSession.shared.download(from: remote)
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capturecat-wallpaper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        try await extractZip(zipURL, to: extractDir)

        guard let heic = firstHEIC(in: extractDir) else { throw DownloadError.badArchive }
        let dest = cacheDirectory.appendingPathComponent("\(name).heic")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: heic, to: dest)
        return dest
    }

    private static func extractZip(_ zip: URL, to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, dir.path]
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: DownloadError.badArchive)
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private static func firstHEIC(in dir: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension.lowercased() == "heic" { return file }
        }
        return nil
    }
}
