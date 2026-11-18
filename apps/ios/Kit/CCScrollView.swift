import UIKit

/// A scroll view for rows of keys (the editor's tool bar, the timeline's
/// toolbar row, icon rails, preset strips). A stock `UIScrollView` never takes
/// back a touch that began on a `UIControl`, so a row made of `CCButton`s
/// cannot be slid with a finger that lands on a key — which is almost every
/// finger. This one lets a drag win over a key (the key's tap is cancelled, as
/// in every system list), but never over a control that is itself dragged:
/// sliders, toggles and segmented controls keep their touch.
final class CCScrollView: UIScrollView {
    #if DEBUG
    static var probeKeysBlockDrag = false
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        canCancelContentTouches = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        Self.dragWins(over: view)
    }

    /// True when a scroll drag may take the touch from `view`: anything
    /// except a control the finger drags (or a view inside one).
    static func dragWins(over view: UIView) -> Bool {
        #if DEBUG
        // Harness defect (`--inject keys-block-drag`): the stock behaviour —
        // a finger on a key can never slide the row.
        if probeKeysBlockDrag, view is UIControl { return false }
        #endif
        var v: UIView? = view
        while let current = v {
            if current is CCSlider || current is UISlider || current is CCSegmented
                || current is CCToggle || current is UISwitch || current is UITextField {
                return false
            }
            v = current.superview
        }
        return true
    }
}
