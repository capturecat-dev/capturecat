#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The replacement menu bar's artwork. `MenuBarRenderer` keeps the guard and
/// the cache; this is the drawing. The Mac branch is MenuBarRenderer's
/// NSImage drawing closure, verbatim.
enum MenuBarArt {
    static func image(for spec: MenuBarRenderer.Spec) -> PlatformImage {
        #if canImport(AppKit)
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
        return image
        #else
        // UIKit twin. UIKit draws y-down; every vertical position below is
        // centred, so the y-up numbers above land on the same pixels. The
        // calibrated Mac colours become sRGB components here.
        let size = CGSize(width: spec.width, height: spec.height)
        let h = CGFloat(spec.height)
        let isDark = spec.style == .dark
        let barColor = isDark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        let textColor = isDark ? UIColor.white : UIColor.black
        let format = rasterFormat()

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            barColor.setFill()
            UIRectFill(rect)

            let fontSize = h * 0.52
            let pad = h * 0.55
            let baselineRect = { (s: NSAttributedString) -> CGFloat in
                (rect.height - s.size().height) / 2
            }

            var rightX = rect.width - pad
            if !spec.clock.isEmpty {
                let clock = NSAttributedString(
                    string: spec.clock,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                        .foregroundColor: textColor,
                    ]
                )
                rightX -= clock.size().width
                clock.draw(at: CGPoint(x: rightX, y: baselineRect(clock)))
                rightX -= fontSize * 0.9
            }
            if spec.showStatusIcons {
                let symbolConfig = UIImage.SymbolConfiguration(
                    pointSize: fontSize * 0.95, weight: .medium
                )
                for name in ["battery.100", "wifi"] {
                    guard let symbol = UIImage(systemName: name, withConfiguration: symbolConfig)
                    else { continue }
                    let tinted = UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
                        let r = CGRect(origin: .zero, size: symbol.size)
                        symbol.draw(in: r)
                        textColor.set()
                        UIRectFillUsingBlendMode(r, .sourceAtop)
                    }
                    rightX -= tinted.size.width
                    tinted.draw(in: CGRect(
                        x: rightX,
                        y: (rect.height - tinted.size.height) / 2,
                        width: tinted.size.width,
                        height: tinted.size.height
                    ))
                    rightX -= fontSize * 0.7
                }
            }

            var x = pad
            let logo = NSAttributedString(
                string: "\u{F8FF}",
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize * 1.05),
                    .foregroundColor: textColor,
                ]
            )
            logo.draw(at: CGPoint(x: x, y: baselineRect(logo)))
            x += logo.size().width + fontSize * 0.7

            if !spec.title.isEmpty {
                let title = NSAttributedString(
                    string: spec.title,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
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
                title.draw(at: CGPoint(x: titleX, y: baselineRect(title)))
            }
        }
        #endif
    }

    #if !canImport(AppKit)
    /// A fixed 2× raster (a Retina Mac's backing scale), so the bar doesn't
    /// change with the device it is exported on.
    private static func rasterFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return format
    }
    #endif
}
