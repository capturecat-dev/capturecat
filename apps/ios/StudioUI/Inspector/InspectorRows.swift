import UIKit

/// What a pane's rows need from the inspector that hosts them.
@MainActor
protocol InspectorHost: AnyObject {
    /// The scope as of now (built fresh: an undo may have swapped settings).
    var scope: InspectorScope { get }
    var session: InspectorEditSession { get }
    var presenter: UIViewController { get }
    func runFeature(_ feature: InspectorFeature)
    /// A Cutout / Pop-out look was picked: start finding the person quietly
    /// (the Mac's `ensureMask`), no sheet.
    func ensureCameraMask()
    /// The photo/file picker: hands back a local copy of the picked image.
    func pickImage(logo: Bool, _ completion: @escaping (URL) -> Void)
    /// The transcription state the Subtitles pane shows (Studio 4e sets it).
    var transcription: InspectorTranscriptionState { get }
}

/// What the Subtitles pane shows about a transcription the host runs.
struct InspectorTranscriptionState: Equatable {
    var isBusy = false
    var progress = ""
    var error: String?
}

/// One row of a pane: it shows/hides by its spec and re-reads its value.
@MainActor
protocol InspectorRowView: UIView {
    var rowID: String { get }
    func isRowVisible(_ scope: InspectorScope) -> Bool
    func refresh(_ scope: InspectorScope)
}

// MARK: - Slider

final class InspectorSliderRowView: UIView, InspectorRowView {
    #if DEBUG
    /// Probe seam — INJECTED DEFECT (`values-defect`): this slider writes one
    /// step past the value it shows.
    static var probeSkewWriteID: String?
    #endif
    let spec: InspectorSlider
    let slider: CCSlider
    private weak var host: InspectorHost?
    private let symbolFor: ((Double) -> String)?
    var rowID: String { spec.id }

    init(_ spec: InspectorSlider, host: InspectorHost, symbol: ((Double) -> String)? = nil) {
        self.spec = spec
        self.host = host
        self.symbolFor = symbol
        slider = CCSlider(title: spec.title, value: spec.range.lowerBound, range: spec.range, step: spec.step,
                          format: spec.format)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        slider.accessibilityIdentifier = spec.id
        // Model values between stops stay as they are (the Mac slider's rule):
        // landing on the nearest stop must still write it.
        slider.keepsOffStepValues = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        pinEdges(slider, to: self)
        slider.onChange = { [weak self] v in
            guard let self, let host = self.host else { return }
            host.session.begin(spec.id, name: spec.title)
            var v = v
            #if DEBUG
            if Self.probeSkewWriteID == spec.id { v += spec.step ?? 0.05 }
            #endif
            spec.write(host.scope, v)
            if let symbolFor = self.symbolFor { self.slider.symbol = symbolFor(v) }
        }
        slider.onCommit = { [weak self] _ in self?.host?.session.commit() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func isRowVisible(_ scope: InspectorScope) -> Bool { spec.visible(scope) }

    func refresh(_ scope: InspectorScope) {
        let range = spec.range(in: scope)
        if slider.range != range { slider.range = range }
        let value = spec.read(scope)
        if !slider.probeIsDragging { slider.setValue(value, animated: window != nil) }
        if let symbolFor { slider.symbol = symbolFor(value) }
    }
}

// MARK: - Toggle

final class InspectorToggleRowView: UIView, InspectorRowView {
    let spec: InspectorToggle
    let row: CCToggleRow
    private weak var host: InspectorHost?
    var rowID: String { spec.id }

    init(_ spec: InspectorToggle, host: InspectorHost) {
        self.spec = spec
        self.host = host
        row = CCToggleRow(title: spec.title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        row.accessibilityIdentifier = spec.id
        addSubview(row)
        pinEdges(row, to: self)
        row.onChange = { [weak self] on in self?.write(on) }
    }

    /// Writes `on` — the row's path, also the panel strip's switch when it
    /// stands in for this row (one undo step, the Mac's name).
    func write(_ on: Bool) {
        guard let host else { return }
        host.session.perform(spec.id, name: spec.title) { spec.write(host.scope, on) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func isRowVisible(_ scope: InspectorScope) -> Bool { spec.visible(scope) }

    func refresh(_ scope: InspectorScope) {
        let on = spec.read(scope)
        // Animate only once laid out: a spring started at zero bounds aims
        // the thumb at a wrong spot that the toggle's layout won't correct.
        if row.isOn != on { row.setOn(on, animated: window != nil && row.toggle.bounds.width > 0) }
        let enabled = spec.enabled(scope)
        if row.isEnabled != enabled { row.isEnabled = enabled }
    }
}

// MARK: - Choice (chips or menu)

final class InspectorChoiceRowView: UIView, InspectorRowView {
    let spec: InspectorChoice
    private(set) var chips: CCChipGroup?
    private(set) var select: CCSelect?
    private weak var host: InspectorHost?
    var rowID: String { spec.id }

    /// Chip rows the Mac labels above the chips.
    static let labelledChips: Set<String> = [
        "camera.background", "camera.cardFill", "camera.cardBorder", "background.menuBarAlign",
    ]

    init(_ spec: InspectorChoice, host: InspectorHost) {
        self.spec = spec
        self.host = host
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        switch spec.style {
        case .chips:
            let group = CCChipGroup(items: spec.items.map { CCChipGroup.Item($0) }, mode: .single, selected: [0])
            group.accessibilityIdentifier = spec.id
            group.accessibilityLabel = spec.title
            group.onChange = { [weak self] selection in
                guard let index = selection.first else { return }
                self?.apply(index)
            }
            chips = group
            if Self.labelledChips.contains(spec.id) {
                let label = ccLabel(spec.title, font: CCFont.labelMedium, color: CCTheme.color.foreground)
                label.adjustsFontForContentSizeCategory = true
                let column = UIStackView(arrangedSubviews: [label, group])
                column.axis = .vertical
                column.spacing = CCSpace.sm
                column.translatesAutoresizingMaskIntoConstraints = false
                addSubview(column)
                pinEdges(column, to: self)
            } else {
                addSubview(group)
                pinEdges(group, to: self)
            }
        case .menu:
            let menu = CCSelect(options: spec.items)
            menu.prompt = spec.title
            menu.accessibilityIdentifier = spec.id
            menu.presenter = host.presenter
            menu.onSelect = { [weak self] index in
                guard let host = self?.host else { return }
                host.session.perform(spec.id, name: spec.title) { spec.write(host.scope, index) }
            }
            select = menu
            // Title above a full-width select: in a 340 pt column a side-by-
            // side row truncated either the title or the choice.
            let row = CCFormRow(label: spec.title, control: menu)
            menu.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            addSubview(row)
            pinEdges(row, to: self)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func isRowVisible(_ scope: InspectorScope) -> Bool { spec.visible(scope) }

    /// Writes choice `index` — the chips' path, also the tool bar's when it
    /// offers the choices as keys (one undo step, the Mac's name).
    func apply(_ index: Int) {
        guard let host else { return }
        host.session.perform(spec.id, name: spec.title) { spec.write(host.scope, index) }
        // A Cutout / Pop-out look starts finding the person right away,
        // in the background (the Mac's segmentation ensureMask). The
        // Remove Background key is the one that opens the feature.
        if spec.id == CameraPane.background.id, host.scope.project?.usesCameraLook == true {
            host.ensureCameraMask()
        }
    }

    func refresh(_ scope: InspectorScope) {
        let index = spec.read(scope)
        if let chips {
            let want: Set<Int> = index.map { [$0] } ?? []
            if chips.selection != want { chips.setSelection(want) }
            // Shown again with a wrap it computed while out of view: lay the
            // pane out so the rows below make room.
            DispatchQueue.main.async { [weak chips] in
                guard let chips, chips.window != nil, chips.hasStaleHeight else { return }
                chips.ccRelayoutAncestors()
            }
        }
        if let select {
            if let index, select.selectedIndex != index { select.setSelectedIndex(index) }
            select.overrideTitle = spec.overrideTitle(scope)
        }
    }
}

// MARK: - Colour

final class InspectorColorRowView: UIView, InspectorRowView {
    let specs: [InspectorColor]
    let wells: [CCColorWell]
    private weak var host: InspectorHost?
    var rowID: String { specs[0].id }

    init(title: String, _ specs: [InspectorColor], host: InspectorHost) {
        self.specs = specs
        self.host = host
        wells = specs.map { CCColorWell(title: $0.title, color: .white, supportsOpacity: $0.supportsOpacity) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (spec, well) in zip(specs, wells) {
            well.accessibilityIdentifier = spec.id
            well.onChange = { [weak self] color in
                guard let host = self?.host else { return }
                host.session.begin(spec.id, name: spec.title)
                spec.write(host.scope, CodableColor(color))
            }
            well.onCommit = { [weak self] _ in self?.host?.session.commit() }
        }
        let control: UIView
        if wells.count == 1 {
            control = wells[0]
        } else {
            let pair = UIStackView(arrangedSubviews: wells)
            pair.spacing = CCSpace.sm
            control = pair
            if let first = wells.first { first.title = String(localized: "\(title) — Top", comment: "Color well title for the top color of a gradient pair, e.g. Background — Top") }
            if wells.count > 1 { wells[1].title = String(localized: "\(title) — Bottom", comment: "Color well title for the bottom color of a gradient pair, e.g. Background — Bottom") }
        }
        let row = CCControlRow(title: title, control: control)
        addSubview(row)
        pinEdges(row, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func isRowVisible(_ scope: InspectorScope) -> Bool { specs[0].visible(scope) }

    func refresh(_ scope: InspectorScope) {
        for (spec, well) in zip(specs, wells) {
            let color = spec.read(scope).platformColor
            if !well.color.isEqual(color) { well.color = color }
        }
    }
}

// MARK: - Text

final class InspectorTextRowView: UIView, InspectorRowView {
    let spec: InspectorText
    let field: CCField
    private weak var host: InspectorHost?
    var rowID: String { spec.id }

    init(_ spec: InspectorText, host: InspectorHost, showsTitle: Bool) {
        self.spec = spec
        self.host = host
        field = CCField(placeholder: spec.placeholder)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.accessibilityIdentifier = spec.id
        field.accessibilityLabel = spec.title
        field.returnKeyType = .done
        field.onTextChange = { [weak self] text in
            guard spec.commit == .live, let host = self?.host else { return }
            host.session.begin(spec.id, name: spec.title)
            spec.write(host.scope, text)
        }
        field.addAction(UIAction { [weak self] _ in self?.endEditing() }, for: .editingDidEnd)
        field.onReturn = { [weak field] _ in field?.resignFirstResponder() }
        if showsTitle {
            let row = CCControlRow(title: spec.title, control: field)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
            addSubview(row)
            pinEdges(row, to: self)
        } else {
            addSubview(field)
            pinEdges(field, to: self)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Commit: live edits close their step; end-commit fields write now.
    func endEditing() {
        guard let host else { return }
        switch spec.commit {
        case .live:
            host.session.commit()
        case .onEnd:
            host.session.perform(spec.id, name: spec.title) { spec.write(host.scope, field.text ?? "") }
            field.text = spec.read(host.scope)
        }
    }

    func isRowVisible(_ scope: InspectorScope) -> Bool { spec.visible(scope) }

    func refresh(_ scope: InspectorScope) {
        guard !field.isFirstResponder else { return }
        let text = spec.read(scope)
        if field.text != text { field.text = text }
    }
}

// MARK: - Buttons

final class InspectorActionRowView: UIView, InspectorRowView {
    let specs: [InspectorAction]
    let buttons: [CCButton]
    private weak var host: InspectorHost?
    var rowID: String { specs[0].id }

    init(_ specs: [InspectorAction], host: InspectorHost) {
        self.specs = specs
        self.host = host
        buttons = specs.map { CCButton(title: " ", style: $0.destructive ? .destructive : .secondary, size: .sm) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (spec, button) in zip(specs, buttons) {
            button.accessibilityIdentifier = spec.id
            button.onTap = { [weak self] in
                guard let host = self?.host else { return }
                host.session.perform(spec.id, name: spec.title(host.scope)) { spec.run(host.scope) }
            }
        }
        row.addArrangedSubview(UIView())
        for button in buttons.reversed() { row.insertArrangedSubview(button, at: 0) }
        row.spacing = CCSpace.sm
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        pinEdges(row, to: self)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private let row = UIStackView()

    /// Side by side while the keys fit the column whole; stacked when a
    /// language's titles are too long for one line ("Genereer opnieuw" +
    /// "Verwijder").
    override func layoutSubviews() {
        let shown = buttons.filter { !$0.isHidden }
        let need = shown.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(max(0, shown.count - 1)) * CCSpace.sm
        let axis: NSLayoutConstraint.Axis = bounds.width > 0 && need > bounds.width + 0.5 ? .vertical : .horizontal
        if row.axis != axis {
            row.axis = axis
            row.alignment = axis == .vertical ? .leading : .center
            row.spacing = axis == .vertical ? CCSpace.md : CCSpace.sm
            invalidateIntrinsicContentSize()
            // This pass already placed the rows below: re-run it.
            ccRelayoutAncestors()
        }
        super.layoutSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func isRowVisible(_ scope: InspectorScope) -> Bool { specs.contains { $0.visible(scope) } }

    func refresh(_ scope: InspectorScope) {
        for (spec, button) in zip(specs, buttons) {
            let title = spec.title(scope)
            if button.title != title { button.title = title }
            let shown = spec.visible(scope)
            if button.isHidden == shown { button.isHidden = !shown }
        }
    }
}

// MARK: - Caption

/// Muted copy under a control. A caption with a longer story (the Mac's
/// tooltip, `InspectorCaption.full`) carries an ⓘ key: a tap opens the
/// whole explanation in place — the row grows on the house bounce, the copy
/// cross-fades — and a second tap folds it back. VoiceOver always reads the
/// whole story.
final class InspectorCaptionRowView: UIView, InspectorRowView {
    let spec: InspectorCaption
    let label: UILabel
    /// The ⓘ key (captions with a longer story only).
    let moreKey: CCButton?
    private(set) var isExpanded = false
    private var shortText: String
    var rowID: String { spec.id }

    init(_ spec: InspectorCaption) {
        self.spec = spec
        shortText = spec.fixed ?? ""
        label = ccLabel(spec.fixed ?? "", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        if let full = spec.full, full != spec.fixed {
            let key = CCButton(symbol: "info.circle.fill", style: .ghost, size: .sm, radius: .md)
            key.accessibilityLabelOverride = String(localized: "More", comment: "Inspector caption: expand the explanation (VoiceOver)")
            key.accessibilityHint = String(localized: "Shows the whole explanation.")
            key.accessibilityIdentifier = "\(spec.id).more"
            moreKey = key
        } else {
            moreKey = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = spec.id
        label.accessibilityLabel = spec.full ?? spec.fixed
        if let moreKey {
            let row = UIStackView(arrangedSubviews: [label, moreKey])
            row.alignment = .top
            row.spacing = CCSpace.xs
            moreKey.setContentHuggingPriority(.required, for: .horizontal)
            moreKey.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(row)
            pinEdges(row, to: self)
            moreKey.onTap = { [weak self] in
                guard let self else { return }
                self.setExpanded(!self.isExpanded, animated: true)
            }
        } else {
            addSubview(label)
            pinEdges(label, to: self)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func isRowVisible(_ scope: InspectorScope) -> Bool { spec.visible(scope) }

    func refresh(_ scope: InspectorScope) {
        shortText = spec.text(scope)
        let text = isExpanded ? (spec.full ?? shortText) : shortText
        if label.text != text { label.text = text }
        if spec.full == nil { label.accessibilityLabel = text }
    }

    /// Opens (or folds) the whole explanation: the copy cross-fades while the
    /// row grows on the bounce (its pushed bottom edge only).
    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard let moreKey, expanded != isExpanded else { return }
        isExpanded = expanded
        moreKey.symbol = expanded ? "chevron.up" : "info.circle.fill"
        moreKey.accessibilityLabelOverride = expanded ? String(localized: "Less", comment: "Inspector caption: fold the explanation (VoiceOver)") : String(localized: "More", comment: "Inspector caption: expand the explanation (VoiceOver)")
        moreKey.accessibilityHint = expanded ? String(localized: "Folds the explanation.") : String(localized: "Shows the whole explanation.")
        let text = expanded ? (spec.full ?? shortText) : shortText
        guard animated, window != nil else {
            label.text = text
            return
        }
        let root = ccLayoutRoot
        UIView.transition(with: label, duration: 0.18, options: .transitionCrossDissolve) { self.label.text = text }
        if CCMotion.reduceMotion {
            root.layoutIfNeeded()
        } else {
            CCMotion.run(duration: 0.38, curve: .bounce, { root.layoutIfNeeded() })
        }
    }

    #if DEBUG
    /// What the ⓘ key opens — the Mac's tooltip: the story, else the line.
    var probeFull: String? { spec.full ?? spec.fixed }
    #endif
}

// MARK: - Feature key

/// A key that starts a feature the host wires (Studio 4e/4f).
final class InspectorFeatureRowView: UIView, InspectorRowView {
    let feature: InspectorFeature
    let button: CCButton
    private let visible: (InspectorScope) -> Bool
    var rowID: String { "feature.\(feature.rawValue)" }

    init(_ feature: InspectorFeature, visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        self.feature = feature
        self.visible = visible
        button = CCButton(title: feature.title, symbol: feature.symbol, style: .outline, size: .sm)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "feature.\(feature.rawValue)"
        button.onTap = { [weak host] in host?.runFeature(feature) }
        let row = UIStackView(arrangedSubviews: [button, UIView()])
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        pinEdges(row, to: self)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func isRowVisible(_ scope: InspectorScope) -> Bool { visible(scope) }
    func refresh(_ scope: InspectorScope) {}
}

// MARK: - Helpers

@MainActor
func pinEdges(_ view: UIView, to host: UIView, inset: CGFloat = 0) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
        view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset),
        view.topAnchor.constraint(equalTo: host.topAnchor, constant: inset),
        view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset),
    ])
}
