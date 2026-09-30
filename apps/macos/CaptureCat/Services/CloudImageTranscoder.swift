import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cloud sync's image normalizer: projects may reference images every
/// browser can't decode (macOS wallpapers are HEIC; TIFF/BMP/HEIF show up in
/// backgrounds and logos). Before upload they are re-encoded ONCE into a
/// format every browser decodes — lossless PNG, carrying the source's colour
/// profile so the web renders the same pixels the Mac's exporter decodes
/// from the original. A PNG that would blow the 64 MB image ceiling falls
/// back to a high-quality JPEG (same profile) rather than skipping the image.
///
/// Converted copies live in a content-keyed cache (the original's SHA-256),
/// so an unchanged wallpaper is converted and hashed once, not every sync.
/// The original file is never touched; project.json keeps pointing at it —
/// the manifest's `source` maps the reference onto the converted upload.
nonisolated enum CloudImageTranscoder {
    /// Extensions a browser cannot decode reliably (Chrome/Firefox: no HEIC,
    /// no TIFF; BMP support is patchy in WebCodecs/ImageDecoder paths).
    static let transcodedExtensions: Set<String> = ["heic", "heif", "tif", "tiff", "bmp"]

    /// The image ceiling the API enforces (`KIND_MAX_BYTES.image`).
    static let maxImageBytes: Int64 = 64 << 20

    struct Output: Equatable, Sendable {
        let url: URL
        /// "png" or "jpg".
        let fileExtension: String
    }

    enum Failure: Error, Equatable {
        case unreadable
        case encodeFailed
        case tooLarge
    }

    static func needsTranscode(_ url: URL) -> Bool {
        transcodedExtensions.contains(url.pathExtension.lowercased())
    }

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureCat/CloudImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A browser-decodable copy of `url`, keyed by `sourceSHA256` in `cache`.
    static func webCompatibleCopy(
        of url: URL,
        sourceSHA256: String,
        cache: URL = cacheDirectory,
        maxBytes: Int64 = maxImageBytes
    ) throws -> Output {
        let stem = String(sourceSHA256.prefix(32))
        let fm = FileManager.default
        for ext in ["png", "jpg"] {
            let hit = cache.appendingPathComponent("\(stem).\(ext)")
            if fm.fileExists(atPath: hit.path) { return Output(url: hit, fileExtension: ext) }
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw Failure.unreadable }
        // Carry orientation + colour metadata forward; the profile rides on
        // the CGImage's colour space, which ImageIO embeds on write.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        var metadata: [CFString: Any] = [:]
        if let orientation = properties[kCGImagePropertyOrientation] {
            metadata[kCGImagePropertyOrientation] = orientation
        }

        let png = cache.appendingPathComponent("\(stem).png")
        try encode(image, as: .png, to: png, properties: metadata)
        let pngBytes = ((try? fm.attributesOfItem(atPath: png.path))?[.size] as? NSNumber)?.int64Value ?? .max
        if pngBytes <= maxBytes { return Output(url: png, fileExtension: "png") }

        try? fm.removeItem(at: png)
        let jpg = cache.appendingPathComponent("\(stem).jpg")
        var jpegProperties = metadata
        jpegProperties[kCGImageDestinationLossyCompressionQuality] = 0.95
        try encode(image, as: .jpeg, to: jpg, properties: jpegProperties)
        let jpgBytes = ((try? fm.attributesOfItem(atPath: jpg.path))?[.size] as? NSNumber)?.int64Value ?? .max
        guard jpgBytes <= maxBytes else {
            try? fm.removeItem(at: jpg)
            throw Failure.tooLarge
        }
        return Output(url: jpg, fileExtension: "jpg")
    }

    private static func encode(_ image: CGImage, as type: UTType, to url: URL, properties: [CFString: Any]) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
        guard let destination = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tmp)
            throw Failure.encodeFailed
        }
        // Atomic publish: a crash mid-write never leaves a torn cache hit.
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
