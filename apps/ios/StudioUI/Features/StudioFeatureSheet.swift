import UIKit

/// The chrome the four editor features share (Studio 4e): each is a house
/// `CCAlert` in `.sheet` presentation — docked to the bottom on compact
/// width so the stage stays visible above it, a centred card on regular
/// width — with the feature's own controls as its accessory. Async actions
/// keep the sheet up with the button busy and show a thrown error inline.
@MainActor
enum StudioFeatureSheet {
    static func make(title: String, message: String, symbol: String, content: [UIView]) -> CCAlert {
        let alert = CCAlert(title: title, message: message)
        alert.symbol = symbol
        alert.presentation = .sheet
        if !content.isEmpty {
            let stack = UIStackView(arrangedSubviews: content)
            stack.axis = .vertical
            stack.spacing = CCSpace.md
            stack.translatesAutoresizingMaskIntoConstraints = false
            alert.accessoryView = stack
        }
        return alert
    }

    static func caption(_ text: String) -> UILabel {
        ccLabel(text, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    }
}

/// A feature's long-running state: a line of text over a house progress bar
/// that springs to each value (transcription, background removal). The
/// probe seams expose what the bar is DRAWING (its presentation layer), so a
/// gate can catch it mid-flight.
@MainActor
final class StudioFeatureProgressRow: UIView {
    let label = ccLabel("", font: CCFont.captionMedium, color: CCTheme.color.foreground, lines: 0)
    let bar = CCProgressBar()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [label, bar])
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `value` nil = indeterminate (waiting); the bar hides when `showsBar` is false.
    func update(text: String, value: Double?, showsBar: Bool = true) {
        if label.text != text {
            label.text = text
            accessibilityLabel = text
        }
        bar.isHidden = !showsBar
        bar.isIndeterminate = value == nil
        if let value {
            #if DEBUG
            if probeValuesShown.last != value { probeValuesShown.append(value) }
            #endif
            bar.value = value
        }
    }

    /// Probe seams: the fill the bar draws now, and every value it was told
    /// to show (a snapped bar only ever draws one of those).
    var probeDrawnWidth: CGFloat { bar.probeFillWidth }
    #if DEBUG
    private(set) var probeValuesShown: [Double] = [0]
    var probeTargetWidths: [CGFloat] {
        probeValuesShown.map { bar.bounds.width * CGFloat(min(max($0, 0), 1)) }
    }
    #endif
}
