import AppKit

/// Keynote/Final Cut-style inspector section: an uppercase tracked header
/// with rows sitting DIRECTLY on the pane surface — no fill, no border, no
/// row separators. Sections separate with generous whitespace plus a single
/// full-width hairline drawn above every section except the first (the pane
/// stack's spacing supplies the air above the line; `hairlineGap` the air
/// below it, before the header).
///
/// Two rounds of grouped-box treatments (filled slab, then hairline outline)
/// both read as "grey boxes" against the near-black card — the correct Apple
/// reference for a media editor is the Keynote inspector, not System
/// Settings. The class keeps its name and API so no pane call site moved.
///
/// Rows are added with `addRow(_:)` on a 16pt rhythm. A caption or preview
/// pad that belongs to the row above is added with `addRow(_:attached: true)`
/// and sits tight under it. Rows may be hidden/shown freely — NSStackView
/// collapses the hidden ones.
@MainActor
final class InspectorSectionBox: NSView {
    private let headerField: NSTextField?
    private let hairline = NSView()
    private let content = NSStackView()

    /// Rhythm between rows (8pt grid).
    private static let rowGap: CGFloat = 16
    /// Tight gap for an attached caption/pad under its row.
    private static let attachedGap: CGFloat = 6
    /// Air between the section hairline and the header below it. The pane
    /// stack's inter-section spacing sits above the line, so the full
    /// section break is spacing + this (~24–28pt of whitespace + one line).
    private static let hairlineGap: CGFloat = 18
    /// Air between the header and the first row.
    private static let headerGap: CGFloat = 10

    private var hairlineHeight: NSLayoutConstraint!
    private var headerTopGap: NSLayoutConstraint!
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init(_ title: String? = nil) {
        if let title {
            // Apple grouped-list header voice: small, tracked, uppercase,
            // muted — visually distinct from row labels so sections scan.
            let field = NSTextField(labelWithString: "")
            field.attributedStringValue = NSAttributedString(
                string: title.uppercased(),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .kern: 0.8,
                ]
            )
            headerField = field
        } else {
            headerField = nil
        }
        super.init(frame: .zero)

        hairline.wantsLayer = true
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Self.rowGap
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        hairlineHeight = hairline.heightAnchor.constraint(equalToConstant: 1)
        var constraints = [
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairlineHeight!,
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if let headerField {
            headerField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(headerField)
            headerTopGap = headerField.topAnchor.constraint(
                equalTo: hairline.bottomAnchor, constant: Self.hairlineGap)
            constraints += [
                headerField.leadingAnchor.constraint(equalTo: leadingAnchor),
                headerTopGap!,
                content.topAnchor.constraint(
                    equalTo: headerField.bottomAnchor, constant: Self.headerGap),
            ]
        } else {
            headerTopGap = content.topAnchor.constraint(
                equalTo: hairline.bottomAnchor, constant: Self.hairlineGap)
            constraints.append(headerTopGap!)
        }
        NSLayoutConstraint.activate(constraints)

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        headerField?.textColor = EditorThemeKit.textSecondary
        hairline.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
    }

    override func layout() {
        super.layout()
        updateHairlineVisibility()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateHairlineVisibility()
    }

    /// The first visible section on a pane starts flush under the pane top —
    /// the hairline (and its gap) only separates a section from content ABOVE
    /// it, exactly like Keynote's inspector.
    private func updateHairlineVisibility() {
        guard let stack = superview as? NSStackView else { return }
        let isFirst = stack.arrangedSubviews.first(where: { !$0.isHidden }) === self
        let wantsLine = !isFirst
        hairline.isHidden = !wantsLine
        let height: CGFloat = wantsLine ? 1 : 0
        let gap: CGFloat = wantsLine ? Self.hairlineGap : 0
        if hairlineHeight.constant != height { hairlineHeight.constant = height }
        if headerTopGap.constant != gap { headerTopGap.constant = gap }
    }

    /// Adds a full-width row. `attached: true` glues the view to the row above
    /// (tight spacing) — for captions and preview pads that belong to the
    /// preceding control.
    func addRow(_ view: NSView, attached: Bool = false) {
        if attached, let previous = content.arrangedSubviews.last {
            content.setCustomSpacing(Self.attachedGap, after: previous)
        }
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
}

extension InspectorKitViews {
    /// One-line muted caption — truncates instead of wrapping, with the full
    /// text as a tooltip. For rows whose explanation should not become a
    /// paragraph in the pane.
    static func captionLine(_ short: String, full: String? = nil) -> NSTextField {
        let field = caption(short)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.toolTip = full ?? short
        return field
    }
}
