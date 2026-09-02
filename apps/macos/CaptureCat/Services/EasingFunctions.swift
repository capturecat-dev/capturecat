import Foundation
import CoreGraphics

enum Easing {
    static func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func smootherStep(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }

    static func easeOutCubic(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    static func easeInCubic(_ t: Double) -> Double {
        t * t * t
    }

    static func easeOutQuart(_ t: Double) -> Double {
        1 - pow(1 - t, 4)
    }

    static func easeOutExpo(_ t: Double) -> Double {
        t == 1 ? 1 : 1 - pow(2, -10 * t)
    }

    static func spring(_ t: Double, damping: Double = 0.7, frequency: Double = 1.5) -> Double {
        let decay = exp(-damping * frequency * t)
        let oscillation = cos(frequency * .pi * 2 * t * sqrt(1 - damping * damping))
        return 1 - decay * oscillation
    }

    /// Symmetric smootherStep envelope — used by highlight / blur layers.
    static func regionEnvelope(
        at time: TimeInterval,
        startTime: TimeInterval,
        endTime: TimeInterval,
        transitionDuration: Double
    ) -> Double {
        guard endTime >= startTime else { return 0 }
        guard time >= startTime && time <= endTime else { return 0 }

        let regionDuration = max(0, endTime - startTime)
        let effectiveTransition = max(0.12, min(transitionDuration, regionDuration * 0.5))
        let inT  = effectiveTransition > 0 ? min(1, (time - startTime) / effectiveTransition) : 1
        let outT = effectiveTransition > 0 ? min(1, (endTime - time)   / effectiveTransition) : 1
        return min(smootherStep(inT), smootherStep(outT))
    }

    /// Screen Studio-style zoom envelope for a single region.
    ///
    /// - **Zoom in**: `easeOutQuart` — snappy pull-in that decelerates smoothly
    ///   into the hold.
    /// - **Zoom out**: `easeInCubic` reversed — the hold lingers right up to the
    ///   start of the out-ramp, then releases with a clean deceleration.  The
    ///   out-ramp lives **inside** the region so the block end-edge is exactly
    ///   where the zoom returns to 1×.
    ///
    /// Uses a slightly asymmetric split: 40 % of the region duration is reserved
    /// for transitions (20 % in, 20 % out), capped by `transitionDuration`.
    static func zoomEnvelope(
        at time: TimeInterval,
        startTime: TimeInterval,
        endTime: TimeInterval,
        transitionDuration: Double
    ) -> Double {
        guard time >= startTime && time <= endTime else { return 0 }

        let regionDuration = max(0, endTime - startTime)
        // Asymmetric: snappy in, lingering out (Screen Studio style)
        let effIn  = max(0.08, min(transitionDuration * 0.55, regionDuration * 0.28))
        let effOut = max(0.12, min(transitionDuration, regionDuration * 0.48))

        let inT  = effIn  > 0 ? min(1, (time - startTime) / effIn)  : 1
        let outT = effOut > 0 ? min(1, (endTime - time)   / effOut) : 1

        let inVal  = easeOutExpo(inT)    // very fast snap in, decelerates to hold
        let outVal = easeOutQuart(outT)  // lingers near peak, then returns cleanly to 1×
        return min(inVal, outVal)
    }

    static func zoomLevel(
        at time: TimeInterval,
        regions: [ZoomRegion],
        transitionDuration: Double
    ) -> (zoom: Double, focalPoint: CGPoint, envelope: Double) {
        let center = CGPoint(x: 0.5, y: 0.5)

        // Find the active region (first match; regions shouldn't overlap)
        for region in regions {
            guard time >= region.startTime && time <= region.endTime else { continue }

            let envelope = zoomEnvelope(
                at: time,
                startTime: region.startTime,
                endTime: region.endTime,
                transitionDuration: transitionDuration
            )
            let zoom = 1.0 + (region.zoomLevel - 1.0) * envelope
            let focal = CGPoint(
                x: center.x + (region.focalPoint.x - center.x) * envelope,
                y: center.y + (region.focalPoint.y - center.y) * envelope
            )
            return (zoom, focal, envelope)
        }

        return (1.0, center, 0)
    }
}
