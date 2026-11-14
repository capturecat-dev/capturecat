#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Geometry boxed as `NSValue` for Core Animation (`CABasicAnimation`
/// from/to values). The boxing initialisers are platform-specific
/// (`NSValue(point:)` vs `NSValue(cgPoint:)`).
enum PlatformValue {
    /// `NSValue(point: NSPoint(x: point.x, y: point.y))`
    static func point(_ point: CGPoint) -> NSValue {
        #if canImport(AppKit)
        return NSValue(point: NSPoint(x: point.x, y: point.y))
        #else
        return NSValue(cgPoint: point)
        #endif
    }
}
