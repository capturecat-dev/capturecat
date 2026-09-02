import AppKit
import CoreGraphics

/// THE one selection chrome for every on-canvas selectable region — accent
/// outline, eight resize dots, and the floating value pill — in pure
/// CoreGraphics. Blur, highlight and depth-focus regions all render through
/// HERE; there are no per-type chrome drawings left.
///
/// Contract: chrome exists ONLY for the selected object. Unselected regions
/// draw nothing (`image` returns nil when no region is selected), and the
/// exporter never links this type at all.
///
/// Replaces `FocusChromeView` (SwiftUI, rasterized through `ImageRenderer`).
/// Purely decorative and read-only: every gesture lives in
/// `PreviewInteractionView`, which owns the matching hit zones, so this
/// renderer draws the IDLE state of each control (no hover growth, no drag
/// highlight) exactly as the rasterized view did — `ImageRenderer` never had a
/// hover to capture either.
///
/// Geometry constants come from `RegionHandleChrome` / `RegionPillPlacement`
/// so the chrome and the hit zones stay defined in one place.
enum SelectionChromeKit {
    /// Idle sizes — see `RegionHandleDot` / `InspectorSliderTrack`.
    private static let dotSize = RegionHandleChrome.dotSize
    private static let pillHeight = RegionHandleChrome.pillHeight
    private static let railHeight: CGFloat = 3
    private static let knobIdle: CGFloat = 12
    private static let iconSize: CGFloat = 9
    private static let pillSpacing: CGFloat = 8

    struct Region {
        var rect: CGRect               // normalized, in container space
        var cornerRadius: CGFloat
        var isSelected: Bool
        var sliderValue: Double
        var sliderRange: ClosedRange<Double>
        var leadingIcon: String
        var trailingIcon: String
    }

    static func image(
        size: CGSize,
        regions allRegions: [Region],
        containerRect: CGRect,
        scale: CGFloat
    ) -> CGImage? {
        // Selected-only, enforced HERE: whatever a caller passes, unselected
        // objects get zero chrome.
        let regions = allRegions.filter(\.isSelected)
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, !regions.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        for region in regions {
            draw(region, in: ctx, containerRect: containerRect)
        }
        return ctx.makeImage()
    }

    private static func draw(_ region: Region, in ctx: CGContext, containerRect: CGRect) {
        let norm = region.rect
        let r = CGRect(
            x: containerRect.minX + norm.minX * containerRect.width,
            y: containerRect.minY + norm.minY * containerRect.height,
            width: max(30, norm.width * containerRect.width),
            height: max(20, norm.height * containerRect.height)
        )

        // The ONE outline spec: 2pt accent stroke, drawn INSIDE the region
        // box, radius matching the object's actual shape.
        ctx.addPath(ContinuousRoundedRect.path(
            rect: r.insetBy(dx: 1, dy: 1),
            cornerRadius: max(0, region.cornerRadius - 1)))
        ctx.setStrokeColor(NSColor.controlAccentColor
            .usingColorSpace(.sRGB)?.cgColor
            ?? SRGBA(white: 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()

        // Eight resize dots, aligned to the region's edges and mid-points.
        for (fx, fy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0),
                         (0.5, 0.0), (0.5, 1.0), (0.0, 0.5), (1.0, 0.5)] as [(CGFloat, CGFloat)] {
            // `.frame(alignment:)` pins the dot inside the box, so an edge dot
            // sits fully within the region rather than centred on the edge.
            let cx = r.minX + dotSize / 2 + fx * (r.width - dotSize)
            let cy = r.minY + dotSize / 2 + fy * (r.height - dotSize)
            drawDot(in: ctx, center: CGPoint(x: cx, y: cy))
        }

        drawPill(region, in: ctx, regionRect: r, containerRect: containerRect)
    }

    /// White 90% with a 1pt black 40% inner ring.
    /// Deliberately NOT theme-inked: handles float over arbitrary user video,
    /// so the hard white-fill/dark-ring contrast must hold in both app themes.
    private static func drawDot(in ctx: CGContext, center: CGPoint) {
        let box = CGRect(x: center.x - dotSize / 2, y: center.y - dotSize / 2,
                         width: dotSize, height: dotSize)
        ctx.setFillColor(SRGBA(white: 1, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: box)
        ctx.setStrokeColor(SRGBA(white: 0, alpha: 0.4).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: box.insetBy(dx: 0.5, dy: 0.5))
    }

    private static func drawPill(
        _ region: Region, in ctx: CGContext, regionRect r: CGRect, containerRect: CGRect
    ) {
        let sliderWidth = min(max(90, r.width - 60), 150)
        // `pillWidth` is what the placement math is clamped against — the same
        // value SwiftUI passes it. It is NOT the drawn width: `.frame(width:)`
        // only PROPOSES a size, and the pill lays itself out around its
        // content, so the capsule ends up as wide as icons + slider + padding
        // (measured 210.5pt where pillWidth said 204).
        let pillWidth = sliderWidth + 54
        let leading = symbolSize(region.leadingIcon)
        let trailing = symbolSize(region.trailingIcon)
        let drawnWidth = 8 + leading.width + pillSpacing + sliderWidth
            + pillSpacing + trailing.width + 8

        let offset = RegionPillPlacement.offset(
            regionRect: r, containerRect: containerRect, pillWidth: pillWidth)
        // `.overlay(alignment: .bottom)` aligns the pill's BOTTOM EDGE with the
        // region's bottom edge, so the unoffset centre is half a pill up.
        let center = CGPoint(x: r.midX + offset.width,
                             y: r.maxY - pillHeight / 2 + offset.height)
        let pill = CGRect(x: center.x - drawnWidth / 2, y: center.y - pillHeight / 2,
                          width: drawnWidth, height: pillHeight)

        let capsule = ContinuousRoundedRect.circularPath(rect: pill, cornerRadius: pillHeight / 2)
        ctx.addPath(capsule)
        ctx.setFillColor(EditorThemeKit.panelElevated.cgColor)
        ctx.fillPath()
        ctx.addPath(ContinuousRoundedRect.circularPath(
            rect: pill.insetBy(dx: 0.5, dy: 0.5), cornerRadius: pillHeight / 2 - 0.5))
        ctx.setStrokeColor(EditorThemeKit.hairline.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // Contents: icon, slider track, icon — 8pt apart inside 8pt padding.
        let contentLeft = pill.minX + 8
        symbol(region.leadingIcon, in: ctx,
               center: CGPoint(x: contentLeft + leading.width / 2, y: pill.midY))
        let trackX = contentLeft + leading.width + pillSpacing
        drawSliderTrack(in: ctx,
                        rect: CGRect(x: trackX, y: pill.midY - (knobIdle + 2) / 2,
                                     width: sliderWidth, height: knobIdle + 2),
                        value: region.sliderValue, range: region.sliderRange)
        symbol(region.trailingIcon, in: ctx,
               center: CGPoint(x: trackX + sliderWidth + pillSpacing + trailing.width / 2,
                               y: pill.midY))
    }

    /// SwiftUI lays `Image(systemName:)` out from the FONT, and AppKit's
    /// point-size symbol configuration lands on the same frame (measured to
    /// within the 0.5pt raster resolution at 9pt for every icon used here).
    private static func symbolSize(_ name: String) -> CGSize {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let configured = image.withSymbolConfiguration(
                  NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular))
        else { return CGSize(width: iconSize, height: iconSize) }
        return configured.size
    }

    /// The slider sits INSIDE the pill's panelElevated fill — an editor panel,
    /// not the video — so its inks track the theme (white chrome on a light
    /// pill would vanish). All colors here are read at image() time, and
    /// CCTheme.apply invalidates every window, so a theme flip re-renders.
    ///
    /// Drawn in CCSlider's language — faint tick marks with a vertical bar
    /// thumb (idle metrics) — so the on-canvas pill reads as the SAME control
    /// as the properties panel's sliders, not a second slider design.
    private static func drawSliderTrack(
        in ctx: CGContext, rect: CGRect, value: Double, range: ClosedRange<Double>
    ) {
        let span = range.upperBound - range.lowerBound
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let fraction = span > 0 ? CGFloat((clamped - range.lowerBound) / span) : 0
        // Ink = the theme's hard-contrast chrome white/black, same alphas.
        let ink: CGFloat = CCTheme.isDark ? 1 : 0

        // Ticks: 1×8pt, ~18pt apart, thinned out exactly like CCSlider.layout.
        let visibleTicks = rect.width < 54 ? 0 : min(9, Int(rect.width / 18))
        if visibleTicks > 0 {
            ctx.setFillColor(SRGBA(white: ink, alpha: 0.22).cgColor)
            for index in 0..<visibleTicks {
                let t = CGFloat(index + 1) / CGFloat(visibleTicks + 1)
                ctx.fill(CGRect(x: rect.minX + rect.width * t, y: rect.midY - 4,
                                width: 1, height: 8))
            }
        }

        // Thumb: CCSlider's idle 4×18pt bar (corner 2, soft black shadow),
        // travelling (width − barWidth) like its layout does.
        let barWidth: CGFloat = 4
        let barHeight: CGFloat = 18
        let bar = CGRect(x: rect.minX + (rect.width - barWidth) * fraction,
                         y: rect.midY - barHeight / 2,
                         width: barWidth, height: barHeight)
        ctx.saveGState()
        SwiftUIShadow.apply(to: ctx, radius: 3, dy: 0, color: SRGBA(white: 0, alpha: 0.35))
        ctx.setFillColor(SRGBA(white: ink, alpha: CCTheme.isDark ? 1 : 0.85).cgColor)
        ctx.addPath(ContinuousRoundedRect.path(rect: bar, cornerRadius: 2))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// SF Symbol via AppKit — `NSImage(systemSymbolName:)` is the same glyph
    /// source `Image(systemName:)` draws from.
    private static func symbol(_ name: String, in ctx: CGContext, center: CGPoint) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
        guard let configured = image.withSymbolConfiguration(config) else { return }
        let size = configured.size
        let box = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                         width: size.width, height: size.height)
        guard let cg = configured.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        ctx.saveGState()
        // Tint: clip to the glyph's alpha and flood it with the label colour.
        ctx.translateBy(x: box.minX, y: box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: box.size)
        ctx.clip(to: local, mask: cg)
        ctx.setFillColor(EditorThemeKit.textSecondary.cgColor)
        ctx.fill(local)
        ctx.restoreGState()
    }
}
