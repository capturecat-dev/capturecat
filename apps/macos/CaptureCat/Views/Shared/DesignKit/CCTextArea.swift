import AppKit

/// CCKit text area — shadcn's Textarea: a multi-line recessed well with a
/// placeholder and the kit's INK focus ring. It auto-grows between
/// `minLines` and `maxLines` as you type — the bottom edge extends on the
/// house bounce (curve-true, top pinned) — and scrolls in place once the
/// text outgrows `maxLines`.
///
///     let notes = CCTextArea(placeholder: "Add a note…", minLines: 3, maxLines: 8)
///     notes.onTextChange = { text in ... }
///     notes.text = "Prefilled"            // grows (animated) to fit
@MainActor
final class CCTextArea: NSView, NSTextViewDelegate {
    var onTextChange: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            refreshPlaceholder()
            fitHeight(animated: true)
        }
    }

    var placeholder: String {
        didSet { placeholderField.stringValue = placeholder }
    }

    var minLines: Int { didSet { fitHeight(animated: true) } }
    var maxLines: Int { didSet { fitHeight(animated: true) } }

    /// Text inset inside the well (matches CCField's 10pt horizontal pad).
    static let inset = NSSize(width: 10, height: 7)

    let textView: NSTextView
    private let scroll = NSScrollView()
    private let placeholderField = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private var lastLaidOutWidth: CGFloat = 0
    private(set) var isFocused = false
    private var themeObservation: CCThemeObservation?

    init(placeholder: String = "", minLines: Int = 3, maxLines: Int = 8) {
        self.placeholder = placeholder
        self.minLines = max(1, minLines)
        self.maxLines = max(minLines, maxLines)
        // TextKit 1 explicitly: the auto-grow measures with the layout
        // manager, and touching `layoutManager` on a TextKit 2 view forces a
        // noisy compatibility fallback at runtime.
        let textView = CCTextAreaTextView(usingTextLayoutManager: false)
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = Self.inset
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.focusRingType = .none
        textView.delegate = self
        textView.onFocusChange = { [weak self] focused in self?.setFocused(focused) }

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed

        placeholderField.stringValue = placeholder
        placeholderField.lineBreakMode = .byTruncatingTail
        placeholderField.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        for view in [scroll, placeholderField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: height(forLines: self.minLines))
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            placeholderField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset.width + 1),
            placeholderField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset.width),
            placeholderField.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset.height + 1),
            heightConstraint,
        ])
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Sizing

    private var font: NSFont { CCTheme.font.chip }

    private var lineHeight: CGFloat {
        textView.layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender)
    }

    private func height(forLines lines: Int) -> CGFloat {
        ceil(CGFloat(lines) * lineHeight + Self.inset.height * 2 + 2)
    }

    /// The height the current text wants, clamped to [minLines, maxLines].
    private var fittedHeight: CGFloat {
        guard let manager = textView.layoutManager, let container = textView.textContainer else {
            return height(forLines: minLines)
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        let content = ceil(used + Self.inset.height * 2 + 2)
        return min(max(content, height(forLines: minLines)), height(forLines: maxLines))
    }

    /// Re-fit the well to its text: growth lands on the bounce (bottom edge
    /// only), shrink glides.
    private func fitHeight(animated: Bool) {
        guard let heightConstraint else { return }
        let target = fittedHeight
        guard abs(target - heightConstraint.constant) > 0.5 || CCMotion.isAnimating(heightConstraint) else { return }
        let growing = target > heightConstraint.constant
        if animated, window != nil {
            CCMotion.animate(heightConstraint, to: target, in: window?.contentView,
                             duration: growing ? 0.38 : 0.24,
                             curve: growing ? CCMotion.bouncePoints : CCMotion.glidePoints)
        } else {
            heightConstraint.constant = target
        }
        scroll.hasVerticalScroller = target >= height(forLines: maxLines) - 0.5
    }

    override func layout() {
        super.layout()
        let radius = CCTheme.radius(.md)
        layer?.cornerRadius = radius
        if let layer { CCMaterial.refit(layer, radius: radius) }
        // A width change re-wraps the text: re-fit instantly (a resize is
        // not a growth moment).
        if abs(bounds.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = bounds.width
            DispatchQueue.main.async { [weak self] in self?.fitHeight(animated: false) }
        }
    }

    // MARK: - Theme / focus

    private func applyTheme() {
        guard let layer else { return }
        let colors = CCTheme.color
        layer.backgroundColor = colors.elevated.cgColor
        CCMaterial.dress(layer, as: .recessed(tint: colors.elevated), radius: CCTheme.radius(.md))
        textView.font = font
        textView.textColor = colors.foreground
        textView.insertionPointColor = colors.foreground
        textView.typingAttributes = [.font: font, .foregroundColor: colors.foreground]
        placeholderField.font = font
        placeholderField.textColor = colors.mutedForeground
        refreshBorder(animated: false)
    }

    private func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        refreshBorder(animated: true)
        onFocusChange?(focused)
    }

    /// The ONLY ring in the house language: keyboard focus on a text input,
    /// ink-colored (never accent-blue).
    private func refreshBorder(animated: Bool) {
        guard let layer else { return }
        let border = isFocused ? CCTheme.current.ringColor : CCTheme.color.border
        layer.borderWidth = isFocused ? max(CCTheme.current.ring.focusWidth, 1) : 1
        if animated {
            CCMotion.fade(layer, keyPath: "borderColor", to: border.cgColor)
        } else {
            layer.borderColor = border.cgColor
        }
    }

    private func refreshPlaceholder() {
        placeholderField.isHidden = !textView.string.isEmpty
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        refreshPlaceholder()
        fitHeight(animated: true)
        onTextChange?(textView.string)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    // MARK: - Harness seams

    var probeHeightConstraint: NSLayoutConstraint { heightConstraint }
    var probeFittedHeight: CGFloat { fittedHeight }
    var probeLineHeight: CGFloat { lineHeight }
    var probeScroll: NSScrollView { scroll }
}

/// Reports first-responder changes so the well can draw its focus ring.
private final class CCTextAreaTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}
