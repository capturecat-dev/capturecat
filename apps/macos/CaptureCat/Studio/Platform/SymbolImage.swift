#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// SF Symbols for the CG chrome renderers (SelectionChromeKit's value-pill
/// icons). On the Mac each helper is the `NSImage(systemSymbolName:)` chain
/// its caller used inline: the symbol configured at a point size, regular
/// weight.
enum SymbolImage {
    /// The configured symbol's size in points, nil when the symbol (or its
    /// configuration) doesn't exist.
    static func size(_ name: String, pointSize: CGFloat) -> CGSize? {
        #if canImport(AppKit)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let configured = image.withSymbolConfiguration(
                  NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        else { return nil }
        return configured.size
        #else
        return configured(name, pointSize: pointSize)?.size
        #endif
    }

    /// The configured symbol's size in points and a raster of it (callers
    /// use its alpha as a mask) — `configured.cgImage(forProposedRect: nil,
    /// context: nil, hints: nil)` on the Mac.
    static func raster(_ name: String, pointSize: CGFloat) -> (size: CGSize, image: CGImage)? {
        #if canImport(AppKit)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let configured = image.withSymbolConfiguration(config) else { return nil }
        let size = configured.size
        guard let cg = configured.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (size, cg)
        #else
        guard let configured = configured(name, pointSize: pointSize) else { return nil }
        let size = configured.size
        // Symbol images are vector; draw one into a bitmap to get pixels.
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            configured.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = rendered.cgImage else { return nil }
        return (size, cg)
        #endif
    }

    #if !canImport(AppKit)
    private static func configured(_ name: String, pointSize: CGFloat) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
    }
    #endif
}
