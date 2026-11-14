import Foundation

/// Renders the replacement menu bar as a single image used by BOTH the
/// preview overlay and the exporter, so the fake bar is pixel-identical in
/// the editor and the file. Drawn at the exact target pixel size per caller.
enum MenuBarRenderer {
    struct Spec: Hashable {
        var style: ProjectSettings.MenuBarReplacement // .dark or .light
        var title: String
        var titleAlignment: ProjectSettings.MenuBarTitleAlignment = .left
        var showStatusIcons: Bool = true
        var clock: String
        var width: Int
        var height: Int
    }

    private static var cache: [Spec: PlatformImage] = [:]

    static func image(for spec: Spec) -> PlatformImage? {
        guard spec.style == .dark || spec.style == .light,
              spec.width > 4, spec.height > 4 else { return nil }
        if let cached = cache[spec] { return cached }

        // The drawing is platform code (MenuBarArt); the Mac's is an NSImage
        // drawing closure, so the bar stays resolution-independent there.
        let image = MenuBarArt.image(for: spec)
        cache[spec] = image
        return image
    }
}
