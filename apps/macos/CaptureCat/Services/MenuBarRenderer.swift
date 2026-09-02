import AppKit

/// Renders the replacement menu bar as a single NSImage used by BOTH the
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

    private static var cache: [Spec: NSImage] = [:]

    static func image(for spec: Spec) -> NSImage? {
        guard spec.style == .dark || spec.style == .light,
              spec.width > 4, spec.height > 4 else { return nil }
        if let cached = cache[spec] { return cached }

        let size = NSSize(width: spec.width, height: spec.height)
        let h = CGFloat(spec.height)
        let isDark = spec.style == .dark
        let barColor = isDark
            ? NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        let textColor = isDark ? NSColor.white : NSColor.black

        let image = NSImage(size: size, flipped: false) { rect in
            barColor.setFill()
            rect.fill()

            let fontSize = h * 0.52
            let pad = h * 0.55
            let baselineRect = { (s: NSAttributedString) -> CGFloat in
                (rect.height - s.size().height) / 2
            }

            // Right side first (clock, then optional wifi/battery glyphs) so
            // a right-aligned title knows where it must stop.
            var rightX = rect.width - pad
            if !spec.clock.isEmpty {
                let clock = NSAttributedString(
                    string: spec.clock,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                        .foregroundColor: textColor,
                    ]
                )
                rightX -= clock.size().width
                clock.draw(at: NSPoint(x: rightX, y: baselineRect(clock)))
                rightX -= fontSize * 0.9
            }
            if spec.showStatusIcons {
                let symbolConfig = NSImage.SymbolConfiguration(
                    pointSize: fontSize * 0.95, weight: .medium
                )
                for name in ["battery.100", "wifi"] {
                    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                        .withSymbolConfiguration(symbolConfig) else { continue }
                    let tinted = NSImage(size: symbol.size, flipped: false) { r in
                        symbol.draw(in: r)
                        textColor.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    rightX -= tinted.size.width
                    tinted.draw(in: NSRect(
                        x: rightX,
                        y: (rect.height - tinted.size.height) / 2,
                        width: tinted.size.width,
                        height: tinted.size.height
                    ))
                    rightX -= fontSize * 0.7
                }
            }

            //  logo stays anchored left; the title goes where the user says.
            var x = pad
            let logo = NSAttributedString(
                string: "\u{F8FF}",
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize * 1.05),
                    .foregroundColor: textColor,
                ]
            )
            logo.draw(at: NSPoint(x: x, y: baselineRect(logo)))
            x += logo.size().width + fontSize * 0.7

            if !spec.title.isEmpty {
                let title = NSAttributedString(
                    string: spec.title,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                        .foregroundColor: textColor,
                    ]
                )
                let titleX: CGFloat
                switch spec.titleAlignment {
                case .left:
                    titleX = x
                case .center:
                    titleX = (rect.width - title.size().width) / 2
                case .right:
                    titleX = rightX - title.size().width
                }
                title.draw(at: NSPoint(x: titleX, y: baselineRect(title)))
            }
            return true
        }
        cache[spec] = image
        return image
    }
}
