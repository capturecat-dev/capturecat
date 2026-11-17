import UIKit

/// The window CaptureCat's screens live in (the app's scene, StudioLab).
///
/// Kit controls draw smaller than they answer: a 34 pt key or a 36 pt chip
/// takes touches across 44 × 44 pt (`point(inside:)`). UIKit only asks a
/// view that when every ANCESTOR contains the point, so a tight row or stack
/// silently cut those targets back to the drawn size. This window restores
/// them: when a touch lands on something that is not itself interactive
/// (a row's background, a label, a stack), the nearest enabled control
/// around it whose own `point(inside:)` claims the point gets the touch.
/// What the touch hit first still wins when it IS a control or carries a
/// gesture (the timeline canvas, a scroll view's pan, a text field).
/// Pointer hover is left alone (it never activates anything).
///
/// The a11y gate measures targets through `UIWindow.hitTest` — this method.
class CCWindow: UIWindow {
    /// How many ancestors up from the hit view the search looks (a control's
    /// expanded zone reaches only ~5 pt past its edge: it is a near relative).
    static let searchDepth = 7

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard event?.type != .hover, let hit, !Self.isInteractive(hit) else { return hit }
        var scope: UIView = hit
        for _ in 0..<Self.searchDepth {
            guard let parent = scope.superview, !(parent is UIWindow) else { break }
            scope = parent
        }
        return Self.expandedTarget(at: point, in: scope, window: self, event: event) ?? hit
    }

    private static func isInteractive(_ view: UIView) -> Bool {
        if view is UIControl || view is UITextView { return true }
        // A scroll view's own background: its pan still sees the touch (a
        // recognizer gets its view's descendants' touches), so a control
        // beside it may take it.
        if view is UIScrollView { return false }
        return (view.gestureRecognizers ?? []).contains { $0.isEnabled }
    }

    /// The topmost enabled control under `scope` whose touch target reaches
    /// past its bounds to `point`.
    private static func expandedTarget(at point: CGPoint, in scope: UIView, window: UIWindow, event: UIEvent?) -> UIView? {
        guard !scope.isHidden, scope.alpha > 0.01, scope.isUserInteractionEnabled else { return nil }
        for sub in scope.subviews.reversed() {
            if let found = expandedTarget(at: point, in: sub, window: window, event: event) { return found }
        }
        guard let control = scope as? UIControl, control.isEnabled else { return nil }
        let p = control.convert(point, from: window)
        return !control.bounds.contains(p) && control.point(inside: p, with: event) ? control : nil
    }
}
