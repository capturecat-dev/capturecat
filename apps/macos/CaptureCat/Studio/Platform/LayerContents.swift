#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// What a compositor layer shows for an image. On the Mac the contents
/// object is an `NSImage` — load-bearing, not a convenience: AppKit orients
/// NSImage contents for the compositor's flipped host view, while a raw
/// CGImage in the same layer lands mirrored in the real window chain (it
/// passed the offscreen harness and shipped wrong). iOS layers take the
/// CGImage, which UIKit's y-down layer tree shows upright.
enum LayerContents {
    /// `cgImage` laid out at `size` points: `NSImage(cgImage: cgImage, size: size)`.
    static func image(_ cgImage: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: size)
        #else
        let scale = size.width > 0 ? CGFloat(cgImage.width) / size.width : 1
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        #endif
    }

    /// The contents object for `image`: the NSImage itself on the Mac.
    static func contents(_ image: PlatformImage?) -> Any? {
        #if canImport(AppKit)
        return image
        #else
        return image?.cgImage
        #endif
    }

    /// The contents object for `cgImage` shown at `size` points:
    /// `NSImage(cgImage: cgImage, size: size)` on the Mac.
    static func contents(_ cgImage: CGImage, size: CGSize) -> Any {
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: size)
        #else
        return cgImage
        #endif
    }
}
