#if canImport(AppKit)
import AppKit
#else
import ImageIO
import UIKit
import UniformTypeIdentifiers
#endif

/// Image decode/encode and the few `PlatformImage` members the renderers
/// read. On the Mac each helper is the exact AppKit chain its caller used.
enum PlatformImageIO {
    /// The image's size in points: `image.size`.
    static func pointSize(of image: PlatformImage) -> CGSize {
        image.size
    }

    /// Loads an image file: `NSImage(contentsOf: url)`.
    static func image(contentsOf url: URL) -> PlatformImage? {
        #if canImport(AppKit)
        return NSImage(contentsOf: url)
        #else
        return UIImage(contentsOfFile: url.path)
        #endif
    }

    /// A CGImage of an in-memory image:
    /// `image.cgImage(forProposedRect: nil, context: nil, hints: nil)`.
    static func cgImage(of image: PlatformImage) -> CGImage? {
        #if canImport(AppKit)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    /// Decodes an image file:
    /// `NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)`.
    static func cgImage(contentsOf url: URL) -> CGImage? {
        #if canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return decode(url)
        #endif
    }

    /// Decodes an image file through a TIFF round trip:
    /// `NSImage(contentsOf:)` → `tiffRepresentation` → `NSBitmapImageRep(data:)` → `cgImage`.
    static func bitmapCGImage(contentsOf url: URL) -> CGImage? {
        #if canImport(AppKit)
        guard let nsImage = NSImage(contentsOf: url),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage
        else { return nil }
        return cgImage
        #else
        return decode(url)
        #endif
    }

    /// PNG bytes: `NSBitmapImageRep(cgImage:).representation(using: .png, properties: [:])`.
    static func pngData(_ cgImage: CGImage) -> Data? {
        #if canImport(AppKit)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
        #else
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
        #endif
    }

    #if !canImport(AppKit)
    /// First frame of an image file, decoded by ImageIO (no EXIF rotation).
    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    #endif
}
