import CoreGraphics

/// Soft edge falloff for blur regions — the single source of truth shared by
/// the live preview (`PreviewView.blurPreviewLayers`) and the export
/// (`VideoExporter.applyRegionBlur`), so the two can never drift.
///
/// The falloff is produced by blurring the region MASK, not by growing the
/// region: the mask rect stays exactly the user's rect and the blur spreads
/// half inside / half outside that boundary. Mask ≈ 0.5 sits precisely on the
/// user's edge, which is what "feather" means to a designer and keeps the
/// blurred area from visibly expanding.
extension BlurRegion {
    /// Feather width as a fraction of the region's smaller dimension.
    static let blurFeatherFraction: CGFloat = 0.10

    /// Floor so a small region still fades instead of hard-clipping. Expressed
    /// in the units of whatever space it is evaluated in — points in the
    /// preview, pixels in the export — and only engages when the smaller side
    /// is under ~60 units, where the two spaces are close enough that no
    /// visible parity gap appears.
    static let blurFeatherMinimum: CGFloat = 6

    /// Ceiling as a fraction of the smaller dimension, so a tiny region can't
    /// feather itself into nothing but a smudge.
    static let blurFeatherMaxFraction: CGFloat = 0.25

    /// Feather radius in SwiftUI terms — the value handed to `.blur(radius:)`
    /// when masking the preview's blurred video layer.
    ///
    /// `containerSize` is the size of the space `rect` is normalised against:
    /// the on-screen video rect in the preview, the video pixel rect in export.
    func featherRadius(in containerSize: CGSize) -> CGFloat {
        let width = rect.width * containerSize.width
        let height = rect.height * containerSize.height
        let smallerSide = min(width, height)
        guard smallerSide > 0 else { return 0 }

        let ceiling = smallerSide * Self.blurFeatherMaxFraction
        let preferred = max(smallerSide * Self.blurFeatherFraction, Self.blurFeatherMinimum)
        return min(ceiling, preferred)
    }

    /// The same falloff expressed as a Core Image Gaussian sigma.
    ///
    /// `CIGaussianBlur`'s `inputRadius` IS the sigma, while SwiftUI's
    /// `.blur(radius:)` is a blur extent of roughly 2σ — the same relationship
    /// the shadow parity fix uses (`VideoExporter`: `shadowRadius / 2`). So the
    /// export gets half the preview's feather radius.
    func featherSigma(in containerSize: CGSize) -> CGFloat {
        featherRadius(in: containerSize) / 2
    }
}
