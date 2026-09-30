import AppKit

/// CCKit rolling label — text whose CHANGED characters roll vertically
/// (odometer-style) instead of swapping: on an increase the new glyph rises
/// in from below while the old one leaves upward; a decrease rolls the other
/// way. Unchanged characters hold still and only glide sideways when the
/// string's width changes. Monospaced digits keep columns stable.
///
///     let value = CCRollingLabel()
///     value.setText("12", direction: .up)
///
/// Used by `CCStepper`; any live counter can adopt it.
@MainActor
final class CCRollingLabel: NSView {
    enum Direction {
        case up
        case down
        /// No roll — replace in place (initial value, theme swaps).
        case none
    }

    enum Alignment {
        case center
        case trailing
    }

    var alignment: Alignment = .center {
        didSet { needsLayout = true }
    }

    /// Font for every glyph (defaults to the kit's monospaced-digit face).
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .medium) {
        didSet { rebuild() }
    }

    var textColor: NSColor = .labelColor {
        didSet { columns.forEach { $0.foregroundColor = textColor.cgColor } }
    }

    private(set) var text = ""
    private var columns: [CATextLayer] = []
    /// Layers added by the most recent roll (harness seam).
    private(set) var lastIncoming: [CATextLayer] = []

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(Self.width(of: text, font: font)), height: lineHeight)
    }

    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The rolling glyphs are clipped by the label's own box.
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func width(of string: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: font]).size().width
    }

    private func makeColumn(_ character: Character) -> CATextLayer {
        let column = CATextLayer()
        column.string = String(character)
        column.font = font
        column.fontSize = font.pointSize
        column.foregroundColor = textColor.cgColor
        column.alignmentMode = .center
        column.contentsScale = window?.backingScaleFactor ?? 2
        column.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(column)
        return column
    }

    /// Frames for `string`'s characters inside the current bounds.
    private func frames(for string: String) -> [CGRect] {
        let total = Self.width(of: string, font: font)
        var x = alignment == .center ? (bounds.width - total) / 2 : bounds.width - total
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
        superview?.needsLayout = true
        let animate = direction != .none && window != nil
        let oldColumns = columns
        let newChars = Array(newText)
        let oldChars = Array(oldText)
        let newFrames = frames(for: newText)
        var kept: [Int: CATextLayer] = [:]   // new index → reused layer
        var leaving: [CATextLayer] = []
        for (offset, column) in oldColumns.reversed().enumerated() {
            let newIndex = newChars.count - 1 - offset
            let oldIndex = oldChars.count - 1 - offset
            if newIndex >= 0, oldChars[oldIndex] == newChars[newIndex] {
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
                                    to: NSValue(point: CGPoint(x: target.midX, y: target.midY)), .smooth)
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

        // Flipped host: +y is DOWN. Up = new glyph rises in from below.
        let travel = lineHeight * 0.9
        let enterFrom: CGFloat = direction == .down ? -travel : travel
        guard animate else {
            leaving.forEach { $0.removeFromSuperlayer() }
            return
        }
        for column in incoming {
            CCMotion.spring(column, keyPath: "transform.translation.y", from: enterFrom, to: 0, .smooth)
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = CCMotion.paced(0.18)
            fadeIn.timingFunction = CCMotion.glide
            column.add(fadeIn, forKey: "ccroll.fadeIn")
        }
        for column in leaving {
            CCMotion.spring(column, keyPath: "transform.translation.y", to: -enterFrom, .smooth)
            CCMotion.fade(column, keyPath: "opacity", to: 0, duration: 0.16)
            DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.36)) {
                column.removeFromSuperlayer()
            }
        }
    }

    private func rebuild() {
        let current = text
        columns.forEach { $0.removeFromSuperlayer() }
        columns = []
        text = ""
        setText(current, direction: .none)
    }

    override func layout() {
        super.layout()
        let targets = frames(for: text)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (column, frame) in zip(columns, targets) where column.animation(forKey: "capmotion.position") == nil {
            column.frame = frame
        }
        CATransaction.commit()
    }

    // MARK: - Harness seams

    var probeColumns: [CATextLayer] { columns }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        columns.forEach { $0.contentsScale = scale }
    }
}
