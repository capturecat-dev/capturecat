import UIKit

// iOS-only glue for the Mac's vector harness files (apps/ios/scripts/ios-vectors.sh).
//
// The harness files compile unchanged on iOS except their AppKit import, which
// is `#if canImport(AppKit) … #else import UIKit`. The few AppKit type NAMES
// they use map onto UIKit here — harness glue only; the code under test is the
// shared Studio/ source either way.
typealias NSColor = UIColor
typealias NSImage = UIImage
typealias NSFont = UIFont
typealias NSRect = CGRect

extension UIColor {
    /// NSColor(srgbRed:…). UIColor(red:…) is extended sRGB — the same
    /// components for every in-range value the harness writes.
    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

// Unit clusters whose harness files are not compiled for iOS yet. Empty here,
// so `WebVectors.all` lists only units that really ran on iOS; the comparer
// names every Mac unit the iOS run did not produce.
extension WebVectors {
    /// WebVectors+Merge — needs ProjectHistory / ProjectMerge (the sync core
    /// moves into Studio/ in Phase 5).
    static var mergeUnits: [WebVectorUnit] { [] }
    /// WebVectors+ModelHelpers — needs SubtitlePreset (a Mac-only model: its
    /// presets are built from NSColor system colours).
    static var modelHelperUnits: [WebVectorUnit] { [] }
    /// WebVectors+OverlaySubtitle — measures with AppKit text layout
    /// (NSLayoutManager); iOS text metrics are gated in Phase 2.
    static var subtitleUnits: [WebVectorUnit] { [] }
    /// WebVectors+RegionsOracle — the menu-bar oracle draws through NSImage
    /// (the menu bar is a documented iOS approximation).
    static var regionOracleUnits: [WebVectorUnit] { [] }
    /// WebVectors+StyleCamera / +StyleExportCamera — the camera name tag lays
    /// out with AppKit text (NSLayoutManager, CodableColor.nsColor).
    static var styleCameraUnits: [WebVectorUnit] { [] }
    static var styleExportCameraUnits: [WebVectorUnit] { [] }
}
