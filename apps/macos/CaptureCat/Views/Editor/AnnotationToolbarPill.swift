import AppKit

/// Contextual annotation toolbar — the dark pill floating above the SELECTED
/// annotation. Its controls are the selected annotation's own properties:
///
///   text/callout   font ▾ · weight ▾ · background toggle + color · text color
///   rect/ellipse   border width · border color · fill toggle + color
///   arrow/drawing  line width · color
///   tap            ripple size · color
///
/// It hides during playback and while a drag is in flight (Keynote does the
/// same — and not laying out a toolbar per mouse-move is also what keeps
/// dragging at frame rate).
///
/// Color wells are the SAME InspectorColorWellControl the properties panel
/// uses; menus are real NSMenus with the current value checked.
final class AnnotationToolbarPill: NSView {

    // MARK: - Outbound

    var onFontChange: ((String?) -> Void)?
    var onWeightChange: ((ProjectSettings.SubtitleWeight) -> Void)?
    var onColorChange: ((NSColor) -> Void)?
    var onBackgroundColorChange: ((NSColor) -> Void)?
    var onBackgroundToggle: (() -> Void)?
    /// Border/line width for shapes and strokes; ripple size for taps.
    var onSizeChange: ((Double) -> Void)?
    var colorProvider: (() -> NSColor)?
    var backgroundColorProvider: (() -> NSColor)?

    // MARK: - State

    /// The fields the controls display — configure() rebuilds/refreshes only
    /// when one of them actually changed, so per-frame calls are free.
    private struct Snapshot: Equatable {
        var id: UUID
        var type: AnnotationType
        var fontName: String?
        var weight: ProjectSettings.SubtitleWeight
        var showBackground: Bool
        var lineWidth: Double
        var fontSize: Double
    }
    private var snapshot: Snapshot?

    private let stack = NSStackView()
    private let colorWell = InspectorColorWellControl()
    private let backgroundWell = InspectorColorWellControl()
    private let fontButton = CaptureCatButton(style: .quiet, height: 26, horizontalPadding: 7)
    private let weightButton = CaptureCatButton(style: .quiet, height: 26, horizontalPadding: 7)
    private let sizeSlider = InspectorSliderControl()
    private var dividers: [NSView] = []
    private var themeObservation: CCThemeObservation?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 18, bottom: 9, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        configureMenuButton(fontButton, tip: "Font") { [weak self] in self?.fontClicked() }
        configureMenuButton(weightButton, tip: "Weight") { [weak self] in self?.weightClicked() }

        sizeSlider.onChange = { [weak self] value in self?.onSizeChange?(value) }
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 72).isActive = true

        colorWell.getColor = { [weak self] in self?.colorProvider?() ?? .white }
        colorWell.setColor = { [weak self] color in self?.onColorChange?(color) }
        colorWell.toolTip = "Color"
        backgroundWell.getColor = { [weak self] in self?.backgroundColorProvider?() ?? .black }
        backgroundWell.setColor = { [weak self] color in self?.onBackgroundColorChange?(color) }
        backgroundWell.toolTip = "Background color"
        for well in [colorWell, backgroundWell] {
            well.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                well.widthAnchor.constraint(equalToConstant: 16),
                well.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Pill chrome only — the color WELLS show annotation colors (content)
    /// and stay whatever the user picked.
    private func applyTheme() {
        layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
        layer?.borderColor = EditorThemeKit.hairline.cgColor
        for d in dividers { d.layer?.backgroundColor = EditorThemeKit.hairline.cgColor }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    // MARK: - Configure (per selected annotation)

    /// Cheap when nothing changed; rebuilds the control row when the
    /// annotation (or a displayed property) did.
    func configure(with annotation: Annotation) {
        let next = Snapshot(
            id: annotation.id, type: annotation.type,
            fontName: annotation.fontName, weight: annotation.fontWeight,
            showBackground: annotation.showBackground,
            lineWidth: annotation.lineWidth, fontSize: annotation.fontSize
        )
        guard next != snapshot else { return }
        let typeChanged = snapshot?.id != next.id || snapshot?.type != next.type
        snapshot = next

        if typeChanged { rebuildControls(for: annotation.type) }

        // Refresh displayed values.
        setMenuTitle(fontButton, annotation.fontName ?? FontCatalog.systemName)
        setMenuTitle(weightButton, annotation.fontWeight.rawValue)
        switch annotation.type {
        case .tap:
            sizeSlider.range = 20...140
            sizeSlider.doubleValue = annotation.fontSize
            sizeSlider.toolTip = "Ripple size"
        default:
            sizeSlider.range = 1...14
            sizeSlider.doubleValue = annotation.lineWidth
            sizeSlider.toolTip = "Line width"
        }
        colorWell.refresh()
        backgroundWell.refresh()
        invalidateIntrinsicContentSize()
    }

    private func rebuildControls(for type: AnnotationType) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        dividers.removeAll()
        switch type {
        case .text, .callout:
            stack.addArrangedSubview(fontButton)
            stack.addArrangedSubview(weightButton)
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(chipButton(symbol: "square.fill.on.square", tip: "Background pill on/off") { [weak self] in
                self?.backgroundClicked()
            })
            stack.addArrangedSubview(backgroundWell)
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(colorWell)
        case .rectangle, .ellipse:
            stack.addArrangedSubview(sizeSlider)
            stack.addArrangedSubview(colorWell)
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(chipButton(symbol: "square.fill.on.square", tip: "Fill on/off") { [weak self] in
                self?.backgroundClicked()
            })
            stack.addArrangedSubview(backgroundWell)
        case .arrow, .drawing:
            stack.addArrangedSubview(sizeSlider)
            stack.addArrangedSubview(colorWell)
        case .tap:
            stack.addArrangedSubview(sizeSlider)
            stack.addArrangedSubview(colorWell)
        }
    }

    // MARK: - Building blocks

    /// Menu-style chip: current value + a chevron, so it READS as a dropdown.
    private func configureMenuButton(_ button: CaptureCatButton, tip: String, action: @escaping () -> Void) {
        button.symbol = "chevron.down"
        button.toolTip = tip
        button.onClick = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setMenuTitle(_ button: CaptureCatButton, _ title: String) {
        button.title = title
    }

    private func chipButton(symbol: String, tip: String, action: @escaping () -> Void) -> CaptureCatButton {
        let button = CaptureCatButton(
            title: "", symbol: symbol, style: .quiet,
            height: 26, horizontalPadding: 4, action: action
        )
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    private func divider() -> NSView {
        let d = NSView()
        d.wantsLayer = true
        d.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
        d.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            d.widthAnchor.constraint(equalToConstant: 1),
            d.heightAnchor.constraint(equalToConstant: 16),
        ])
        dividers.append(d)
        return d
    }

    // MARK: - Actions

    private var fontPopup: CCComboboxPopup?

    private func fontClicked() {
        // Searchable combobox popup — the font list is long; typing beats
        // scrolling. Selection commits through the same onFontChange path
        // the old menu used.
        fontPopup?.dismiss()
        let names = FontCatalog.menuNames
        let current = snapshot?.fontName ?? FontCatalog.systemName
        let popup = CCComboboxPopup(
            options: names.map { .init(title: $0) },
            selectedIndex: names.firstIndex(of: current),
            searchPlaceholder: "Search fonts…",
            emptyText: "No fonts",
            minWidth: 240
        )
        popup.onCommit = { [weak self] index in
            self?.fontPopup?.dismiss()
            let name = names[index]
            self?.onFontChange?(name == FontCatalog.systemName ? nil : name)
        }
        popup.onDismiss = { [weak self] in self?.fontPopup = nil }
        fontPopup = popup
        popup.present(below: fontButton)
    }

    private func weightClicked() {
        let menu = NSMenu()
        for weight in ProjectSettings.SubtitleWeight.allCases {
            let item = NSMenuItem(title: weight.rawValue, action: #selector(weightPicked(_:)), keyEquivalent: "")
            item.target = self
            item.state = weight == snapshot?.weight ? .on : .off
            menu.addItem(item)
        }
        CaptureCatMenuPresenter.show(menu, from: weightButton, edge: .below)
    }

    @objc private func weightPicked(_ item: NSMenuItem) {
        guard let weight = ProjectSettings.SubtitleWeight(rawValue: item.title) else { return }
        onWeightChange?(weight)
    }

    @objc private func backgroundClicked() { onBackgroundToggle?() }

}
