#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// The few platform names the shared harness scripts (PreviewParityHarness) use
// for their host views — NSView on the Mac, UIView in StudioLab.
#if canImport(AppKit)
typealias HarnessView = NSView
extension NSView {
    /// The view's backing layer (optional on both platforms, so the scripts
    /// bind it the same way).
    var harnessLayer: CALayer? { layer }
}
#else
typealias HarnessView = UIView
extension UIView {
    var harnessLayer: CALayer? { layer }
}
#endif
