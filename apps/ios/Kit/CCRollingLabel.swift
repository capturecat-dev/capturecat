import UIKit

/// CCKit rolling label (port of the Mac's CCRollingLabel) — text whose
/// CHANGED characters roll vertically, odometer-style, instead of swapping:
/// on an increase the new glyph rises in from below while the old one leaves
/// upward; a decrease rolls the other way. Unchanged characters hold still and
/// only glide sideways when the string's width changes. Monospaced digits keep
/// the columns stable.
///
///     let value = CCRollingLabel()
///     value.setText("12", direction: .up)
///
/// Used by `CCStepper`; any live counter can adopt it. Dynamic Type: the font
/// comes from `fontProvider(traitCollection)` and is rebuilt when the user's
/// text size changes.
final class CCRollingLabel: UIView {
    enum Direction {
        case up
        case down
        /// No roll — replace in place (initial value, theme swaps).
        case none
    }

    enum Alignment {
        case leading
        case center
        case trailing
    }

    var alignment: Alignment = .center { didSet { setNeedsLayout() } }

    /// The glyph font for the current traits (defaults to the kit's
    /// monospaced-digit value face).
    var fontProvider: (UITraitCollection) -> UIFont = { CCFont.monoValue($0) } {
        didSet { rebuild() }
    }

    private(set) var font: UIFont

    var textColor: UIColor = CCTheme.color.foreground { didSet { applyColor() } }

    private(set) var text = ""
    private var columns: [CATextLayer] = []
    /// Layers added / retired by the most recent roll (probe seams).
    private(set) var lastIncoming: [CATextLayer] = []
    private(set) var lastLeaving: [CATextLayer] = []

    override init(frame: CGRect) {
        font = CCFont.monoValue(nil)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        // The rolling glyphs are clipped by the label's own box.
        layer.masksToBounds = true
        font = fontProvider(traitCollection)
        ccOnThemeChange { [weak self] in self?.applyColor() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) { (self: CCRollingLabel, _: UITraitCollection) in
            self.rebuild()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(Self.width(of: text, font: font)), height: lineHeight)
    }

    private var lineHeight: CGFloat { ceil(font.lineHeight) }

    static func width(of string: String, font: UIFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func makeColumn(_ character: Character) -> CATextLayer {
        let column = CATextLayer()
        column.string = String(character)
        column.font = font
        column.fontSize = font.pointSize
        column.foregroundColor = cc(textColor)
        column.alignmentMode = .center
        column.contentsScale = max(traitCollection.displayScale, 1)
        column.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.addSublayer(column)
        return column
    }

    /// Frames for `string`'s characters inside the current bounds.
    private func frames(for string: String) -> [CGRect] {
        let total = Self.width(of: string, font: font)
        var x: CGFloat
        switch alignment {
        case .leading: x = 0
        case .center: x = (bounds.width - total) / 2
        case .trailing: x = bounds.width - total
        }
        let y = (bounds.height - lineHeight) / 2
        return string.map { character in
            let w = Self.width(of: String(character), font: font)
            defer { x += w }
            return CGRect(x: x, y: y, width: w, height: lineHeight)
        }
    }

    /// Change the text. Characters are aligned from the RIGHT (numbers grow
    /// leftward), and only the positions that differ roll.
    func setText(_ newText: String, direction: Direction) {
        guard newText != text else { return }
        let oldText = text
        text = newText
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        let animate = direction != .none && window != nil && !CCMotion.reduceMotion
        let oldColumns = columns
        let newChars = Array(newText)
        let oldChars = Array(oldText)
        let newFrames = frames(for: newText)
        var kept: [Int: CATextLayer] = [:]   // new index → reused layer
        var leaving: [CATextLayer] = []
        for (offset, column) in oldColumns.reversed().enumerated() {
            let newIndex = newChars.count - 1 - offset
            let oldIndex = oldChars.count - 1 - offset
            if newIndex >= 0, oldIndex >= 0, oldChars[oldIndex] == newChars[newIndex] {
                kept[newIndex] = column
            } else {
                leaving.append(column)
            }
        }
        var next: [CATextLayer] = []
        var incoming: [CATextLayer] = []
        for (index, character) in newChars.enumerated() {
            if let column = kept[index] {
                let target = newFrames[index]
                if animate {
                    CCMotion.spring(column, keyPath: "position",
                                    to: NSValue(cgPoint: CGPoint(x: target.midX, y: target.midY)), .smooth)
                } else {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    column.frame = target
                    CATransaction.commit()
                }
                next.append(column)
            } else {
                let column = makeColumn(character)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                column.frame = newFrames[index]
                CATransaction.commit()
                next.append(column)
                incoming.append(column)
            }
        }
        columns = next
        lastIncoming = incoming
        lastLeaving = leaving

        // Y-down: Up = the new glyph rises in from BELOW (+y).
        let travel = lineHeight * 0.9
        let enterFrom: CGFloat = direction == .down ? -travel : travel
        guard animate else {
            leaving.forEach { $0.removeFromSuperlayer() }
            return
        }
        for column in incoming {
            CCMotion.spring(column, keyPath: "transform.translation.y", from: enterFrom, to: 0, .smooth)
            CCMotion.fade(column, keyPath: "opacity", to: Float(1), duration: 0.18, from: Float(0))
        }
        for column in leaving {
            CCMotion.spring(column, keyPath: "transform.translation.y", to: -enterFrom, .smooth)
            CCMotion.fade(column, keyPath: "opacity", to: Float(0), duration: 0.16)
            DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.36)) {
                column.removeFromSuperlayer()
            }
        }
    }

    private func rebuild() {
        font = fontProvider(traitCollection)
        let current = text
        columns.forEach { $0.removeFromSuperlayer() }
        columns = []
        text = ""
        setText(current, direction: .none)
        invalidateIntrinsicContentSize()
    }

    private func applyColor() {
        let color = cc(textColor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        columns.forEach { $0.foregroundColor = color }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let targets = frames(for: text)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (column, frame) in zip(columns, targets) where column.animation(forKey: "ccmotion.position") == nil {
            column.frame = frame
        }
        CATransaction.commit()
    }

    // MARK: - Probe seams

    var probeColumns: [CATextLayer] { columns }
}

extension CCFont {
    /// Monospaced-digit value text (stepper wells, live counters), scaled
    /// for `traits` (nil = the app's current text size).
    static func monoValue(_ traits: UITraitCollection?) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 16, weight: .medium),
            maximumPointSize: 24,
            compatibleWith: traits
        )
    }

    /// The slider/stepper readout face (the Mac's `mono`), scaled for `traits`.
    static func monoReadout(_ traits: UITraitCollection?) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            maximumPointSize: 20,
            compatibleWith: traits
        )
    }
}
