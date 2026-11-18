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

    // MARK: Edge fade

    /// A soft fade this long (pt) at each edge that has more content past
    /// it — the hint that the row slides. 0 = none. The fade grows in as
    /// the content moves off that edge (no pop), along the axis that
    /// overflows.
    var edgeFade: CGFloat = 0 { didSet { if edgeFade != oldValue { updateFade() } } }
    private var fadeMask: CAGradientLayer?
    #if DEBUG
    var probeFadeMask: CAGradientLayer? { fadeMask }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        // A scroll view lays out on every offset change: the mask rides along.
        updateFade()
    }

    private func updateFade() {
        let horizontal = contentSize.width - bounds.width >= contentSize.height - bounds.height
        let length = horizontal ? bounds.width : bounds.height
        let overflow = horizontal ? contentSize.width - bounds.width : contentSize.height - bounds.height
        guard edgeFade > 0, overflow > 0.5, length > 2 * edgeFade else {
            // Only ever remove our own mask.
            if let fadeMask, layer.mask === fadeMask { layer.mask = nil }
            fadeMask = nil
            return
        }
        let offset = horizontal ? contentOffset.x : contentOffset.y
        let lead = min(1, max(0, offset / edgeFade))
        let trail = min(1, max(0, (overflow - offset) / edgeFade))
        let mask = fadeMask ?? CAGradientLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.startPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        mask.endPoint = horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        let f = edgeFade / length
        mask.locations = [0, NSNumber(value: Double(f)), NSNumber(value: Double(1 - f)), 1]
        mask.colors = [UIColor(white: 0, alpha: 1 - lead * 0.94).cgColor, UIColor.black.cgColor,
                       UIColor.black.cgColor, UIColor(white: 0, alpha: 1 - trail * 0.94).cgColor]
        CATransaction.commit()
        if fadeMask == nil {
            fadeMask = mask
            layer.mask = mask
        }
    }

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
