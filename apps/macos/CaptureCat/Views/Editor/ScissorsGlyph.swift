import AppKit

/// The slice tool's scissors — the icon kit's `scissors` glyph (CCIcon,
/// 2026 flat look; it replaced a polished-steel skeuomorphic drawing). Blades
/// point UP, finger loops below. Each half (one loop + its blade) is a rigid
/// line through the pivot, rotated about it, so one `open` parameter drives a
/// physically believable close for the snip animation.
///
/// Drawn over arbitrary video thumbnails, so it is a white glyph with a dark
/// outline (the macOS-cursor recipe): legible on black, white and busy frames.
enum ScissorsGlyph {
    /// The kit drawing this mirrors (24-unit grid, Y-down): loops r 2.75 at
    /// (7, 17.25) and (17, 17.25), blades (8.75, 15.12)→(17.25, 4.75) and
    /// (15.25, 15.12)→(6.75, 4.75), crossing at the pivot.
    private static let pivot = CGPoint(x: 12, y: 11.155)
    private static let loopRadius: CGFloat = 2.75
    /// Each blade's lean off vertical in the kit drawing (fully open).
    private static let kitHalfSpread = atan2(17.25 - 12, 11.155 - 4.75)

    /// `open`: 1 = blades fully apart (the kit drawing), 0 = closed.
    /// Orientation-correct in any context — draw it with
    /// `respectFlipped: true` (the timeline canvas is a flipped view).
    static func image(height: CGFloat, open: CGFloat) -> NSImage {
        let width = height * 0.95
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Kit units → points; 20 units of height leaves room for the
            // outline at every opening.
            let unit = rect.height / 20
            let halfSpread = 0.08 + (kitHalfSpread - 0.08) * max(0, min(1, open))
            let swing = kitHalfSpread - halfSpread

            // One half = its loop + its blade, as a path in kit units about
            // the pivot. side -1: left loop, blade leaning right.
            func half(_ side: CGFloat) -> CGPath {
                let path = CGMutablePath()
                let loop = CGPoint(x: 12 + side * 5 - pivot.x, y: 17.25 - pivot.y)
                path.addEllipse(in: CGRect(x: loop.x - loopRadius, y: loop.y - loopRadius,
                                           width: loopRadius * 2, height: loopRadius * 2))
                path.move(to: CGPoint(x: 12 + side * 3.25 - pivot.x, y: 15.12 - pivot.y))
                path.addLine(to: CGPoint(x: 12 - side * 5.25 - pivot.x, y: 4.75 - pivot.y))
                // Closing swings each half toward vertical: the left-loop
                // half turns counter-clockwise on screen (Y-down: negative).
                var turn = CGAffineTransform(rotationAngle: side * swing)
                return path.copy(using: &turn) ?? path
            }
            let halves = [half(-1), half(1)]

            ctx.translateBy(x: rect.midX + (pivot.x - 12) * unit,
                            y: rect.midY + (pivot.y - 12) * unit)
            ctx.scaleBy(x: unit, y: unit)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for (width, color) in [(1.75 + 1.8, NSColor.black.withAlphaComponent(0.55)),
                                   (1.75, NSColor.white)] {
                ctx.setLineWidth(width)
                ctx.setStrokeColor(color.cgColor)
                for path in halves {
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }
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
