import AppKit

/// A multi-line label that re-wraps at whatever width auto layout hands it.
///
///     let body = CCWrappingLabel("Long description…")
///
/// Two AppKit traps it closes:
///  • The wrap width must be read in the label's OWN `layout()`: a parent
///    reading it in its layout sees the child's stale frame (parents lay out
///    before children) and wraps at the old width — text truncates on shrink.
///  • A wrapping field reports its current width as intrinsic; at the default
///    750 compression resistance that pins the WINDOW's minimum width, so the
///    horizontal resistance sits below the window's resize priority.
/// Colors/fonts stay with the owner (set them from its applyTheme).
@MainActor
final class CCWrappingLabel: NSTextField {
    init(_ text: String = "") {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        stringValue = text
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.isScrollable = false
        maximumNumberOfLines = 0
        setContentCompressionResistancePriority(.init(250), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
