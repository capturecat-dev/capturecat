import CoreGraphics

/// Shared geometry + materials for the iPhone 16 Pro bezel drawn around device
/// recordings. Every visual constant lives here; `DeviceBezelRenderer` turns
/// them into pixels for BOTH the preview compositor and the exporter, so there
/// is only one frame to keep honest.
///
/// All fractions are relative to the SCREEN WIDTH (the video rect's width), so
/// the frame scales identically in points and pixels. Values are taken from the
/// real handset: 402 × 874 pt screen inside a 71.5 × 149.6 mm titanium body.
///
/// iPad-aspect video keeps a thin generic frame (flat corners, no cutout).
enum DeviceFrameLayout {
    // MARK: - Colors

    /// Tiny sRGB triple every renderer reads its tones from. `color` exists
    /// only for the retiring SwiftUI preview; native drawing uses `srgba`.
    struct RGB: Sendable, Equatable {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        var a: CGFloat = 1

        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        /// From an 8-bit hex literal, e.g. `0x8E8B87`.
        init(hex: UInt32, alpha: CGFloat = 1) {
            self.init(
                CGFloat((hex >> 16) & 0xFF) / 255,
                CGFloat((hex >> 8) & 0xFF) / 255,
                CGFloat(hex & 0xFF) / 255,
                alpha
            )
        }

        /// Linear blend — used for the middle gradient stop.
        static func mix(_ x: RGB, _ y: RGB, _ t: CGFloat = 0.5) -> RGB {
            RGB(
                x.r + (y.r - x.r) * t,
                x.g + (y.g - x.g) * t,
                x.b + (y.b - x.b) * t,
                x.a + (y.a - x.a) * t
            )
        }

        var cgColor: CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

        var srgba: SRGBA { SRGBA(red: r, green: g, blue: b, alpha: a) }
    }

    // MARK: - Black titanium finish

    /// Band gradient, screen-top → screen-bottom (stops at 0 / 0.5 / 1).
    /// Deep near-black with a warm metallic sheen — Apple's Black Titanium.
    static let bandTop = RGB(hex: 0x4C4A47)
    static let bandMid = RGB(hex: 0x2E2C2A)
    static let bandBottom = RGB(hex: 0x242220)
    /// The extruded side slab behind the body (faux-3D tilt face).
    static let sideTop = RGB(hex: 0x232120)
    static let sideBottom = RGB(hex: 0x0D0C0C)
    /// Black glass margin between the band and the first screen pixel.
    static let glassColor = RGB(hex: 0x0A0A0B)

    /// Specular rim highlight: top-leading → mid → bottom-trailing. Black
    /// titanium still takes a bright polished edge where the chamfer catches
    /// the light.
    static let rimHighlight: CGFloat = 0.58
    static let rimMid: CGFloat = 0.10
    static let rimShadowSide: CGFloat = 0.28
    /// Dark contact line just inside the polished rim.
    static let innerShadow: CGFloat = 0.50

    // MARK: - Side buttons

    /// Buttons are milled from the band itself: same tone, a touch lighter at
    /// the top of their own gradient, plus a hairline highlight so they read as
    /// raised rather than painted on.
    static let buttonTop = RGB(hex: 0x3E3C3A)
    static let buttonBottom = RGB(hex: 0x232120)
    static let buttonRim: CGFloat = 0.30

    /// One physical control on the band. `centerFraction` / `lengthFraction`
    /// are fractions of the BODY height measured from the screen-TOP end;
    /// `thicknessFraction` is how far it protrudes, as a fraction of the screen
    /// width. Positions follow the current iPhone Pro: Action + both volume
    /// keys on the left, side (power) button and the flush Camera Control on
    /// the right.
    struct SideButton: Sendable, Equatable {
        var centerFraction: CGFloat
        var lengthFraction: CGFloat
        var isLeft: Bool
        var thicknessFraction: CGFloat
    }

    static let sideButtons: [SideButton] = [
        // Left rail
        SideButton(centerFraction: 0.185, lengthFraction: 0.045, isLeft: true, thicknessFraction: 0.012),   // Action
        SideButton(centerFraction: 0.268, lengthFraction: 0.072, isLeft: true, thicknessFraction: 0.013),   // Volume up
        SideButton(centerFraction: 0.360, lengthFraction: 0.072, isLeft: true, thicknessFraction: 0.013),   // Volume down
        // Right rail
        SideButton(centerFraction: 0.283, lengthFraction: 0.118, isLeft: false, thicknessFraction: 0.013),  // Side / power
        SideButton(centerFraction: 0.455, lengthFraction: 0.075, isLeft: false, thicknessFraction: 0.008)   // Camera Control (flush)
    ]

    // MARK: - Metrics (fractions of the screen width)

    /// Screen edge → outer body edge, uniform on all four sides.
    static let borderFraction: CGFloat = 0.042
    /// Black glass margin between the band and the first screen pixel.
    static let glassMarginFraction: CGFloat = 0.012
    /// Real display corner radius: 62 pt on a 402 pt-wide screen.
    static let screenCornerFraction: CGFloat = 0.155
    /// Dynamic Island: 125 × 37 pt, sitting 11 pt below the screen's top edge.
    static let islandWidthFraction: CGFloat = 0.315
    static let islandHeightFraction: CGFloat = 0.093
    static let islandTopFraction: CGFloat = 0.028
    /// Front-camera lens inside the island.
    static let cameraDotFraction: CGFloat = 0.030
    static let cameraDotOffsetFraction: CGFloat = 0.100

    /// iPad-aspect video keeps the original thin, flat-cornered frame.
    static let padCornerFraction: CGFloat = 0.045

    /// Polished-rim stroke width, in points/pixels.
    static func rimWidth(forVideoWidth width: CGFloat) -> CGFloat {
        max(1, width * 0.0045)
    }

    /// Dark seam stroked around the screen so the glass reads as recessed.
    static func seamWidth(forVideoWidth width: CGFloat) -> CGFloat {
        max(1, width * 0.002)
    }

    // MARK: - Continuous ("squircle") corners

    /// Shared corner path. `ContinuousRoundedRect` reproduces SwiftUI's
    /// continuous-corner geometry in pure CoreGraphics (verified to 1e-5 pt),
    /// so every renderer draws the identical squircle.
    static func continuousRoundedPath(rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        ContinuousRoundedRect.path(rect: rect, cornerRadius: cornerRadius)
    }

    // MARK: - Derived geometry

    /// Portrait-phone aspect (≈19.5:9). iPads get flatter corners, no island.
    static func isPhoneAspect(_ size: CGSize) -> Bool {
        size.height > size.width * 1.5
    }

    /// Border width in points for a given screen width.
    static func bezelWidth(forVideoWidth width: CGFloat) -> CGFloat {
        max(4, width * borderFraction)
    }

    static func screenCornerRadius(forVideoSize size: CGSize) -> CGFloat {
        size.width * (isPhoneAspect(size) ? screenCornerFraction : padCornerFraction)
    }

    static func bezelRect(forVideoRect videoRect: CGRect) -> CGRect {
        let bezel = bezelWidth(forVideoWidth: videoRect.width)
        return videoRect.insetBy(dx: -bezel, dy: -bezel)
    }

    static func bezelCornerRadius(forVideoSize size: CGSize) -> CGFloat {
        screenCornerRadius(forVideoSize: size) + bezelWidth(forVideoWidth: size.width)
    }

    /// Dynamic Island pill size; only meaningful for phone-aspect video.
    static func islandSize(forVideoWidth width: CGFloat) -> CGSize {
        CGSize(width: width * islandWidthFraction, height: width * islandHeightFraction)
    }

    static func islandTopInset(forVideoWidth width: CGFloat) -> CGFloat {
        width * islandTopFraction
    }

    // MARK: - Resolved metrics

    /// Everything both renderers need, resolved to points/pixels for one screen
    /// rect. All insets are symmetric, so the struct is orientation agnostic —
    /// each renderer decides for itself which end is the screen's top.
    struct Metrics {
        var isPhone: Bool
        /// Screen width — the unit all fractions are expressed in.
        var unit: CGFloat
        var screenRect: CGRect
        var screenCornerRadius: CGFloat
        var bodyRect: CGRect
        var bodyCornerRadius: CGFloat
        /// Black glass ring hugging the screen.
        var glassRect: CGRect
        var glassCornerRadius: CGFloat
        var rimWidth: CGFloat
        var seamWidth: CGFloat

        func value(_ fraction: CGFloat) -> CGFloat { unit * fraction }
    }

    static func metrics(forVideoRect videoRect: CGRect) -> Metrics {
        let isPhone = isPhoneAspect(videoRect.size)
        let unit = videoRect.width
        let screenRadius = screenCornerRadius(forVideoSize: videoRect.size)
        let glassMargin = isPhone ? unit * glassMarginFraction : 0
        return Metrics(
            isPhone: isPhone,
            unit: unit,
            screenRect: videoRect,
            screenCornerRadius: screenRadius,
            bodyRect: bezelRect(forVideoRect: videoRect),
            bodyCornerRadius: bezelCornerRadius(forVideoSize: videoRect.size),
            glassRect: videoRect.insetBy(dx: -glassMargin, dy: -glassMargin),
            glassCornerRadius: screenRadius + glassMargin,
            rimWidth: rimWidth(forVideoWidth: unit),
            seamWidth: seamWidth(forVideoWidth: unit)
        )
    }
}
