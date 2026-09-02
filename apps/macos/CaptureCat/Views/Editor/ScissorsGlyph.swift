import AppKit

/// Skeuomorphic editing scissors — polished-steel blades pointing UP, silver
/// finger loops below, like the classic Mac editing icon. Both halves are
/// rigid blade+loop pieces rotated about the pivot, so one `open` parameter
/// drives a physically believable close for the slice tool's snip animation.
enum ScissorsGlyph {
    /// `open`: 1 = blades fully apart, 0 = closed.
    static func image(height: CGFloat, open: CGFloat) -> NSImage {
        let width = height * 0.95
        // flipped: true — the timeline canvas is a flipped view, and the
        // harness snip-shots proved the y-up geometry below renders blades-
        // DOWN there with flipped:false. Verify any change with
        // `--videotrack-math-test --canvas --snip-shot`, not a standalone
        // render (NSImage handler orientation differs between contexts).
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let spread = 0.08 + 0.34 * max(0, min(1, open))
            let pivot = CGPoint(x: width / 2, y: height * 0.38)
            let bladeLen = height * 0.60
            let bladeBulge = height * 0.16
            let loopRadius = height * 0.105
            let loopStroke = max(1.4, height * 0.055)

            let space = CGColorSpaceCreateDeviceRGB()
            let steel = CGGradient(
                colorsSpace: space,
                colors: [
                    NSColor(white: 0.97, alpha: 1).cgColor,
                    NSColor(white: 0.72, alpha: 1).cgColor,
                    NSColor(white: 0.88, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 0.55, 1])!
            let edge = NSColor(white: 0.35, alpha: 0.9)

            for side: CGFloat in [-1, 1] {
                ctx.saveGState()
                ctx.translateBy(x: pivot.x, y: pivot.y)
                ctx.rotate(by: side * spread)

                // Blade: slender lens from pivot to tip, bulge on the outside.
                let blade = CGMutablePath()
                blade.move(to: .zero)
                blade.addQuadCurve(
                    to: CGPoint(x: 0, y: bladeLen),
                    control: CGPoint(x: side * bladeBulge, y: bladeLen * 0.38))
                blade.addQuadCurve(
                    to: .zero,
                    control: CGPoint(x: -side * bladeBulge * 0.15, y: bladeLen * 0.5))
                blade.closeSubpath()

                // Steel fill: gradient across the blade's width, dark cutting
                // edge, and a specular streak along the spine.
                ctx.saveGState()
                ctx.addPath(blade)
                ctx.clip()
                ctx.drawLinearGradient(
                    steel,
                    start: CGPoint(x: -side * bladeBulge, y: bladeLen * 0.4),
                    end: CGPoint(x: side * bladeBulge, y: bladeLen * 0.4),
                    options: [])
                ctx.restoreGState()
                ctx.addPath(blade)
                ctx.setStrokeColor(edge.cgColor)
                ctx.setLineWidth(max(0.6, height * 0.014))
                ctx.strokePath()
                let streak = CGMutablePath()
                streak.move(to: CGPoint(x: 0, y: bladeLen * 0.06))
                streak.addQuadCurve(
                    to: CGPoint(x: 0, y: bladeLen * 0.96),
                    control: CGPoint(x: side * bladeBulge * 0.45, y: bladeLen * 0.4))
                ctx.addPath(streak)
                ctx.setStrokeColor(NSColor(white: 1, alpha: 0.8).cgColor)
                ctx.setLineWidth(max(0.6, height * 0.012))
                ctx.strokePath()

                // Finger loop: a silver ring below the pivot — gradient clipped
                // to the stroked ellipse so the metal wraps around it.
                let loopCenter = CGPoint(x: 0, y: -(pivot.y - loopRadius - loopStroke / 2))
                let ring = CGPath(
                    ellipseIn: CGRect(
                        x: loopCenter.x - loopRadius, y: loopCenter.y - loopRadius,
                        width: loopRadius * 2, height: loopRadius * 2),
                    transform: nil)
                    .copy(strokingWithWidth: loopStroke, lineCap: .round,
                          lineJoin: .round, miterLimit: 10)
                ctx.saveGState()
                ctx.addPath(ring)
                ctx.clip()
                ctx.drawLinearGradient(
                    steel,
                    start: CGPoint(x: 0, y: loopCenter.y + loopRadius),
                    end: CGPoint(x: 0, y: loopCenter.y - loopRadius),
                    options: [])
                ctx.restoreGState()
                ctx.addPath(ring)
                ctx.setStrokeColor(edge.withAlphaComponent(0.5).cgColor)
                ctx.setLineWidth(max(0.5, height * 0.01))
                ctx.strokePath()
                ctx.restoreGState()
            }

            // Pivot rivet: small radial-shaded dome.
            let r = height * 0.055
            let rivet = CGGradient(
                colorsSpace: space,
                colors: [
                    NSColor(white: 0.85, alpha: 1).cgColor,
                    NSColor(white: 0.3, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 1])!
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(
                x: pivot.x - r, y: pivot.y - r, width: r * 2, height: r * 2))
            ctx.clip()
            ctx.drawRadialGradient(
                rivet,
                startCenter: CGPoint(x: pivot.x - r * 0.35, y: pivot.y + r * 0.35),
                startRadius: 0,
                endCenter: pivot, endRadius: r * 1.4,
                options: [])
            ctx.restoreGState()
            return true
        }
    }

    // MARK: Snip animation timing — shared so the harness can assert it.

    static let snipDuration: TimeInterval = 0.55

    /// (open, travel, alpha) at `t` seconds into the snip: a crisp close over
    /// the first third, a small elastic re-part, then a fade. `travel` is the
    /// scissors' eased 0→1 ride UP through the lane (blades lead the cut).
    static func snipState(at t: TimeInterval) -> (open: CGFloat, travel: CGFloat, alpha: CGFloat) {
        let p = max(0, min(1, t / snipDuration))
        // Close: ease-in-out to 0 by 33% of the gesture.
        let closeP = min(1, p / 0.33)
        let eased = closeP * closeP * (3 - 2 * closeP)
        var open = 1 - eased
        // Elastic re-part after the snip: a decaying wiggle, max 12%.
        if p > 0.33 {
            let w = (p - 0.33) / 0.67
            open = 0.12 * CGFloat(sin(w * .pi * 2) * exp(-3 * w))
        }
        let travel = CGFloat(p * p * (3 - 2 * p))
        let alpha: CGFloat = p < 0.6 ? 1 : CGFloat(1 - (p - 0.6) / 0.4)
        return (max(0, open), travel, alpha)
    }

    /// Strip separation at `t`: how far (in points) each clip half leans away
    /// from the cut while the blades pass — opens with the cut, breathes shut
    /// as the snip settles, leaving the real split geometry behind.
    static func stripGap(at t: TimeInterval, maxGap: CGFloat) -> CGFloat {
        let p = max(0, min(1, t / snipDuration))
        return maxGap * CGFloat(sin(p * .pi))
    }
}
