import CoreGraphics
import Foundation

/// Blur-region style math SHARED by the preview patch pipeline and the
/// exporter — the strength→block-size mapping, the mosaic's grid anchor, and
/// the animated-censor jitter all live HERE and nowhere else.
///
/// The gaussian style keeps the ORIGINAL pipeline untouched
/// (`BlurRegion.blurRadius(in:)` scaled by intensity, CI sigma = radius/2) —
/// legacy regions render byte-identically.
///
/// Animated pixelate is deterministic from the TIMELINE clock (never a wall
/// clock, per house rules): time quantizes to `animationStep` and each step
/// hashes to a small grid-phase offset within one block, so scrubbing,
/// playback and export land on the identical frame.
enum BlurStyleMath {
    /// Censor-style cadence: 8 steps per second.
    static let animationStep: TimeInterval = 0.125
    /// Mosaic block size as a fraction of the region's LONG side.
    static let minBlockFraction: CGFloat = 0.015
    static let maxBlockFraction: CGFloat = 0.09
    static let minBlockPoints: CGFloat = 3

    /// Mosaic block size (CIPixellate inputScale) for a strength and the
    /// region's size IN THE RENDER SPACE — both renderers pass their own
    /// space's region size, so blocks scale proportionally.
    static func pixelScale(strength: Double, regionSize: CGSize) -> CGFloat {
        let s = CGFloat(max(0, min(1, strength)))
        let long = max(regionSize.width, regionSize.height)
        return max(minBlockPoints,
                   (minBlockFraction + s * (maxBlockFraction - minBlockFraction)) * long)
    }

    /// The timeline step index the animated grid is frozen to.
    static func quantizedStep(at time: TimeInterval) -> Int {
        Int(floor(time / animationStep))
    }

    /// Grid-phase jitter for the animated mosaic: zero when not animated,
    /// otherwise a deterministic per-step offset within ±half a block. Added
    /// to the CIPixellate center (which is anchored to the REGION's origin so
    /// blocks don't swim when the region moves).
    static func gridJitter(
        at time: TimeInterval, animated: Bool, blockSize: CGFloat
    ) -> CGPoint {
        guard animated, blockSize > 0 else { return .zero }
        let step = quantizedStep(at: time)
        return CGPoint(
            x: (hash01(step, 0x51) - 0.5) * blockSize,
            y: (hash01(step, 0xA7) - 0.5) * blockSize)
    }

    /// Deterministic 0…1 hash of (step, salt) — splitmix-style.
    static func hash01(_ step: Int, _ salt: Int) -> CGFloat {
        var x = UInt64(bitPattern: Int64(step)) &* 0x9E3779B97F4A7C15
        x = x &+ UInt64(bitPattern: Int64(salt)) &* 0xBF58476D1CE4E5B9
        x ^= x >> 30; x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 27; x = x &* 0x94D049BB133111EB
        x ^= x >> 31
        return CGFloat(Double(x % 1_000_000_000) / 1_000_000_000)
    }
}
