import AppKit
import QuartzCore

/// A `CAGradientLayer` replacement whose ramp follows `OklabGradient`.
///
/// `CAGradientLayer` interpolates its stops in gamma-encoded sRGB. SwiftUI
/// interpolates in Oklab (see `OklabGradient`), and on a saturated ramp the two
/// disagree by tens of levels — white→red reads ~50/255 apart at the midpoint.
/// Anywhere a SwiftUI gradient is being reproduced in AppKit, use this instead.
///
/// Ramps whose endpoints share an RGB triple and differ only in alpha (the
/// clear→black shade overlay, for one) are identical under both interpolations,
/// so a plain `CAGradientLayer` is still fine for those.
final class OklabGradientLayer: CALayer {
    enum Axis { case horizontal, vertical }

    var stops: [(location: CGFloat, color: SRGBA)] = [] {
        didSet { setNeedsDisplay() }
    }

    /// `.vertical` runs top→bottom in the layer's own coordinate space.
    var axis: Axis = .horizontal {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? OklabGradientLayer {
            stops = other.stops
            axis = other.axis
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(from: SRGBA, to: SRGBA) {
        stops = [(0, from), (1, to)]
    }

    override func draw(in ctx: CGContext) {
        guard stops.count >= 2, let gradient = OklabGradient.gradient(stops: stops) else { return }
        let (start, end): (CGPoint, CGPoint)
        switch axis {
        case .horizontal:
            start = CGPoint(x: bounds.minX, y: bounds.midY)
            end = CGPoint(x: bounds.maxX, y: bounds.midY)
        case .vertical:
            // `draw(in:)` hands over a y-up context regardless of the owning
            // view's flippedness, so top→bottom is maxY→minY here.
            start = CGPoint(x: bounds.midX, y: bounds.maxY)
            end = CGPoint(x: bounds.midX, y: bounds.minY)
        }
        ctx.drawLinearGradient(
            gradient, start: start, end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
}

extension NSColor {
    /// sRGB components as the currency `OklabGradient` speaks.
    var srgba: SRGBA {
        guard let c = usingColorSpace(.sRGB) else { return SRGBA(white: 0, alpha: 0) }
        return SRGBA(
            red: c.redComponent, green: c.greenComponent,
            blue: c.blueComponent, alpha: c.alphaComponent
        )
    }
}
