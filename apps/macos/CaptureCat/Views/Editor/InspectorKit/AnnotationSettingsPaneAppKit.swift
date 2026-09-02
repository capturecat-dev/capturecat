import AppKit

/// Bindings/context the Annotate pane needs from EditorView (mirrors the
/// MotionPaneContext pattern).
struct AnnotatePaneContext {
    var selectedAnnotationID: Ref<UUID?>
    var currentTime: TimeInterval
    var undoManager: UndoManager?
}

/// The Annotate tab as a native AppKit pane — faithful port of the redesigned
/// AnnotationSettingsView: type header with destructive delete (undoable),
/// per-type Text/Tap/Style sections, Effects (opacity + Keynote Build In/Out
/// + shadow), Drawing strokes management, and Timing.
@MainActor
final class AnnotationSettingsPaneAppKit: NSView, NSTextFieldDelegate {
    private let project: Project
    private var context: AnnotatePaneContext

    private let stack = NSStackView()

    // Empty state
    private let emptyHeader = InspectorKitViews.header("Annotate")
    private let emptyCaption = InspectorKitViews.caption("Add a text label, arrow, shape, or tap indicator from the toolbar — it lands on the ANNOTATE lane at the playhead. Select one (on the preview or the timeline) to edit its properties here. Double-click a text label on the preview to edit it in place.")

    // Header
    private let headerRow = NSStackView()
    private let typeIcon = NSImageView()
    private let typeLabel = NSTextField(labelWithString: "")
    private let deleteButton = InspectorButton("Delete", destructive: true)

    // Text section
    private let textCaption = InspectorKitViews.caption("Text")
    private let textField = InspectorFlatTextField(placeholder: "Label")
    private let textTip = InspectorKitViews.caption("Tip: double-click the label on the preview to edit it in place.")
    private let fontSizeSlider = InspectorSliderRow(label: "Size", range: 10...72, step: 1)
    private let weightChips = InspectorChipsControl()
    private let fontMenu = InspectorMenuControl()
    private var fontRow: NSView!
    private let uppercaseToggle = InspectorToggleControl("Uppercase")

    // Tap section
    private let tapCaption = InspectorKitViews.caption("Tap Ripple")
    private let tapSizeSlider = InspectorSliderRow(label: "Size", range: 20...120, step: 5)
    private let tapTip = InspectorKitViews.caption("Drag the ripple on the preview over the tapped spot. It pulses for the block's whole duration.")

    // Style section
    private let styleCaption = InspectorKitViews.caption("Style")
    private let colorWell = InspectorColorWellControl()
    private var colorRow: NSView!
    private let fillWell = InspectorColorWellControl()
    private let fillToggle = CaptureCatToggle()
    private var fillRow: NSView!
    private let fillRowLabel = NSTextField(labelWithString: "Background")
    private let cornersSlider = InspectorSliderRow(label: "Corners", range: 0...24, step: 1)
    private let borderSlider = InspectorSliderRow(label: "Border", range: 0...12, step: 0.5)

    // Effects section
    private let effectsCaption = InspectorKitViews.caption("Effects")
    private let opacitySlider = InspectorSliderRow(label: "Opacity", range: 0.2...1.0, step: 0.05)
    private let blackoutSlider = InspectorSliderRow(label: "Blackout", range: 0...0.9, step: 0.05)
    private let buildInMenu = InspectorMenuControl()
    private var buildInRow: NSView!
    private let buildOutMenu = InspectorMenuControl()
    private var buildOutRow: NSView!
    private let shadowToggle = InspectorToggleControl("Shadow")

    // Drawing section
    private let drawingCaption = InspectorKitViews.caption("Strokes")
    private let drawingRow = NSStackView()
    private let strokesLabel = NSTextField(labelWithString: "")
    private let undoStrokeButton = InspectorButton("Undo Last")
    private let clearStrokesButton = InspectorButton("Clear", destructive: true)
    private let drawingTip = InspectorKitViews.caption("Draw directly on the preview canvas.")

    // Timing section
    private let timingCaption = InspectorKitViews.caption("Timing")
    private let timingRow = NSStackView()
    private let startField = InspectorFlatTextField(placeholder: "0.00", width: 56)
    private let endField = InspectorFlatTextField(placeholder: "0.00", width: 56)
    private let atPlayheadButton = InspectorButton("At Playhead")
    private let timingTip = InspectorKitViews.caption("Drag the block's edges on the ANNOTATE lane to retime it.")

    private var editorViews: [NSView] = []
    private var dividers: [NSView] = []
    private var observation: SurfaceObservation?
    private var lastStrokeSignature = ""

    override var isFlipped: Bool { true }

    init(project: Project, context: AnnotatePaneContext) {
        self.project = project
        self.context = context
        super.init(frame: .zero)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        build()
        wire()
        observation = SurfaceObservation { [weak self] in
            self?.apply()
        }
        // Separate from the SurfaceObservation loop — a CCTheme.apply must
        // not re-arm the model observation.
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var themeObservation: CCThemeObservation?
    private var fieldCaptions: [NSTextField] = []

    private func applyTheme() {
        typeIcon.contentTintColor = EditorThemeKit.textSecondary
        typeLabel.textColor = EditorThemeKit.textPrimary
        fillRowLabel.textColor = EditorThemeKit.textPrimary
        strokesLabel.textColor = EditorThemeKit.textSecondary
        for caption in fieldCaptions {
            caption.textColor = EditorThemeKit.textTertiary
        }
    }

    func update(context: AnnotatePaneContext) {
        self.context = context
        apply()
    }

    // MARK: - Layout

    private func fullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func editor(_ view: NSView) {
        fullWidth(view)
        editorViews.append(view)
    }

    private func editorDivider() {
        let d = InspectorKitViews.divider()
        fullWidth(d)
        editorViews.append(d)
        dividers.append(d)
    }

    private func build() {
        // Empty state
        stack.addArrangedSubview(emptyHeader)
        fullWidth(emptyCaption)

        // Header row
        typeLabel.font = EditorThemeKit.header()
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.addArrangedSubview(typeIcon)
        headerRow.addArrangedSubview(typeLabel)
        headerRow.addArrangedSubview(NSView()) // spacer
        headerRow.addArrangedSubview(deleteButton)
        editor(headerRow)

        // Text
        editorDivider()
        editor(textCaption)
        textField.delegate = self
        editor(textField)
        editor(textTip)
        editor(fontSizeSlider)
        fontMenu.items = FontCatalog.menuNames.map { .init(title: $0, icon: nil) }
        fontRow = InspectorKitViews.row("Font", control: fontMenu)
        editor(fontRow)
        weightChips.items = ProjectSettings.SubtitleWeight.allCases.map(\.rawValue)
        editor(weightChips)
        editor(uppercaseToggle)

        // Tap
        editor(tapCaption)
        editor(tapSizeSlider)
        editor(tapTip)

        // Style
        editorDivider()
        editor(styleCaption)
        colorRow = InspectorKitViews.row("Color", control: colorWell)
        editor(colorRow)

        // Fill/background row: label left, well + switch right.
        fillRowLabel.font = EditorThemeKit.label()
        fillToggle.onChange = { [weak self] isOn in
            self?.mutate { $0.showBackground = isOn }
        }
        let fillControls = NSStackView(views: [fillWell, fillToggle])
        fillControls.orientation = .horizontal
        fillControls.spacing = 10
        let fillContainer = NSView()
        for v in [fillRowLabel, fillControls] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fillContainer.addSubview(v)
        }
        NSLayoutConstraint.activate([
            fillRowLabel.leadingAnchor.constraint(equalTo: fillContainer.leadingAnchor),
            fillRowLabel.centerYAnchor.constraint(equalTo: fillContainer.centerYAnchor),
            fillControls.trailingAnchor.constraint(equalTo: fillContainer.trailingAnchor),
            fillControls.centerYAnchor.constraint(equalTo: fillContainer.centerYAnchor),
            fillContainer.heightAnchor.constraint(equalTo: fillControls.heightAnchor),
        ])
        fillRow = fillContainer
        editor(fillRow)

        editor(cornersSlider)
        editor(borderSlider)

        // Effects
        editorDivider()
        editor(effectsCaption)
        opacitySlider.format = { "\(Int(($0 * 100).rounded()))%" }
        editor(opacitySlider)
        blackoutSlider.format = { $0 < 0.026 ? "Off" : "\(Int(($0 * 100).rounded()))%" }
        editor(blackoutSlider)
        buildInMenu.items = AnnotationEffect.allCases.map { .init(title: $0.rawValue) }
        buildInRow = InspectorKitViews.row("Build In", control: buildInMenu)
        editor(buildInRow)
        buildOutMenu.items = AnnotationEffect.allCases.map { .init(title: $0.rawValue) }
        buildOutRow = InspectorKitViews.row("Build Out", control: buildOutMenu)
        editor(buildOutRow)
        editor(shadowToggle)

        // Drawing
        editor(drawingCaption)
        strokesLabel.font = .systemFont(ofSize: 12)
        drawingRow.orientation = .horizontal
        drawingRow.spacing = 8
        drawingRow.addArrangedSubview(strokesLabel)
        drawingRow.addArrangedSubview(NSView())
        drawingRow.addArrangedSubview(undoStrokeButton)
        drawingRow.addArrangedSubview(clearStrokesButton)
        editor(drawingRow)
        editor(drawingTip)

        // Timing
        editorDivider()
        editor(timingCaption)
        startField.delegate = self
        endField.delegate = self
        timingRow.orientation = .horizontal
        timingRow.spacing = 8
        timingRow.alignment = .bottom
        timingRow.addArrangedSubview(labeledField("Start", startField))
        timingRow.addArrangedSubview(labeledField("End", endField))
        timingRow.addArrangedSubview(NSView())
        timingRow.addArrangedSubview(atPlayheadButton)
        editor(timingRow)
        editor(timingTip)
    }

    private func labeledField(_ label: String, _ field: NSTextField) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        fieldCaptions.append(caption)
        let column = NSStackView(views: [caption, field])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        return column
    }

    // MARK: - Wiring (writes)

    private var selectedIndex: Int? {
        guard let id = context.selectedAnnotationID.wrappedValue else { return nil }
        return project.annotations.firstIndex(where: { $0.id == id })
    }

    private func mutate(_ change: (inout Annotation) -> Void) {
        guard let idx = selectedIndex else { return }
        var annotation = project.annotations[idx]
        change(&annotation)
        project.annotations[idx] = annotation
    }

    private func wire() {
        deleteButton.onClick = { [weak self] in
            guard let self, let idx = self.selectedIndex else { return }
            let removed = self.project.annotations[idx]
            self.project.annotations.remove(at: idx)
            self.context.selectedAnnotationID.wrappedValue = nil
            self.context.undoManager?.registerUndo(withTarget: self.project) { p in
                p.annotations.append(removed)
            }
            self.context.undoManager?.setActionName("Delete Annotation")
        }

        fontSizeSlider.onChange = { [weak self] value in
            self?.mutate { $0.fontSize = value }
        }
        tapSizeSlider.onChange = { [weak self] value in
            self?.mutate { $0.fontSize = value }
        }
        fontMenu.onSelect = { [weak self] index in
            self?.mutate { $0.fontName = FontCatalog.storedName(forMenuIndex: index) }
        }
        uppercaseToggle.onChange = { [weak self] on in
            self?.mutate { $0.uppercase = on }
        }
        weightChips.onSelect = { [weak self] index in
            let all = ProjectSettings.SubtitleWeight.allCases
            guard all.indices.contains(index) else { return }
            self?.mutate { $0.fontWeight = all[index] }
        }

        colorWell.getColor = { [weak self] in
            guard let self, let idx = self.selectedIndex else { return .white }
            return self.project.annotations[idx].color.nsColor
        }
        colorWell.setColor = { [weak self] color in
            self?.mutate { $0.color = CodableColor(color) }
        }
        fillWell.getColor = { [weak self] in
            guard let self, let idx = self.selectedIndex else { return .black }
            return self.project.annotations[idx].backgroundColor.nsColor
        }
        fillWell.setColor = { [weak self] color in
            self?.mutate { $0.backgroundColor = CodableColor(color) }
        }

        cornersSlider.onChange = { [weak self] value in
            self?.mutate { $0.cornerRadius = value }
        }
        borderSlider.onChange = { [weak self] value in
            self?.mutate { $0.lineWidth = value }
        }
        opacitySlider.onChange = { [weak self] value in
            self?.mutate { $0.opacity = value }
        }
        blackoutSlider.onChange = { [weak self] value in
            self?.mutate { $0.backdropOpacity = value < 0.026 ? 0 : value }
        }
        buildInMenu.onSelect = { [weak self] index in
            let all = AnnotationEffect.allCases
            guard all.indices.contains(index) else { return }
            self?.mutate { $0.enterEffect = all[index] }
        }
        buildOutMenu.onSelect = { [weak self] index in
            let all = AnnotationEffect.allCases
            guard all.indices.contains(index) else { return }
            self?.mutate { $0.exitEffect = all[index] }
        }
        shadowToggle.onChange = { [weak self] on in
            self?.mutate { $0.showShadow = on }
        }
        undoStrokeButton.onClick = { [weak self] in
            self?.mutate {
                guard !$0.drawingStrokes.isEmpty else { return }
                $0.drawingStrokes.removeLast()
            }
        }
        clearStrokesButton.onClick = { [weak self] in
            self?.mutate { $0.drawingStrokes = [] }
        }
        atPlayheadButton.onClick = { [weak self] in
            guard let self else { return }
            let time = self.context.currentTime
            let duration = self.project.duration
            self.mutate {
                $0.startTime = max(0, time)
                $0.endTime = min(duration, time + 3)
            }
        }
    }

    // NSTextFieldDelegate — commit text/time fields on end editing.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === textField {
            mutate { $0.text = field.stringValue }
        } else if field === startField {
            if let value = Double(field.stringValue) {
                mutate { $0.startTime = max(0, value) }
            }
        } else if field === endField {
            if let value = Double(field.stringValue) {
                mutate { $0.endTime = max($0.startTime + 0.5, value) }
            }
        }
        apply()
    }

    // MARK: - Reads (observation)

    private func apply() {
        // Touch the whole annotations array so any property change re-arms.
        let annotations = project.annotations
        let idx = context.selectedAnnotationID.wrappedValue
            .flatMap { id in annotations.firstIndex(where: { $0.id == id }) }

        let hasSelection = idx != nil
        emptyHeader.isHidden = hasSelection
        emptyCaption.isHidden = hasSelection
        for view in editorViews { view.isHidden = !hasSelection }
        guard let idx else { return }
        let annotation = annotations[idx]
        let type = annotation.type

        // Header
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        typeIcon.image = NSImage(systemSymbolName: icon(for: type), accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        typeLabel.stringValue = name(for: type)

        // Section visibility
        let isText = type == .text || type == .callout
        textCaption.isHidden = !isText
        textField.isHidden = !isText
        textTip.isHidden = !isText
        fontSizeSlider.isHidden = !isText
        weightChips.isHidden = !isText
        uppercaseToggle.isHidden = !isText
        fontRow.isHidden = !isText

        let isTap = type == .tap
        tapCaption.isHidden = !isTap
        tapSizeSlider.isHidden = !isTap
        tapTip.isHidden = !isTap

        let hasFill = isText || type == .rectangle || type == .ellipse
        fillRow.isHidden = !hasFill
        fillRowLabel.stringValue = (type == .rectangle || type == .ellipse) ? "Fill" : "Background"
        cornersSlider.isHidden = !(isText || type == .rectangle)
        let hasBorder = type == .arrow || type == .drawing || type == .rectangle || type == .ellipse
        borderSlider.isHidden = !hasBorder
        shadowToggle.isHidden = isTap

        let isDrawing = type == .drawing
        drawingCaption.isHidden = !isDrawing
        drawingRow.isHidden = !isDrawing
        drawingTip.isHidden = !isDrawing

        // Values (skip fields actively being edited — currentEditor is only
        // non-nil mid-edit; comparing against firstResponder fails the
        // nil-vs-nil case and left the fields stuck on their placeholders)
        if textField.currentEditor() == nil {
            textField.stringValue = annotation.text
        }
        fontSizeSlider.setValue(annotation.fontSize)
        tapSizeSlider.setValue(annotation.fontSize)
        if let wIndex = ProjectSettings.SubtitleWeight.allCases.firstIndex(of: annotation.fontWeight) {
            weightChips.selectedIndex = wIndex
        }
        uppercaseToggle.isOn = annotation.uppercase
        fontMenu.selectedIndex = FontCatalog.menuIndex(for: annotation.fontName)
        colorWell.refresh()
        fillWell.refresh()
        fillWell.isHidden = !annotation.showBackground
        fillToggle.isOn = annotation.showBackground
        cornersSlider.setValue(annotation.cornerRadius)
        borderSlider.slider.range = isDrawing ? 1...30 : 0...12
        borderSlider.setValue(annotation.lineWidth)
        opacitySlider.setValue(annotation.opacity)
        blackoutSlider.setValue(annotation.backdropOpacity)
        if let eIndex = AnnotationEffect.allCases.firstIndex(of: annotation.enterEffect) {
            buildInMenu.selectedIndex = eIndex
        }
        if let xIndex = AnnotationEffect.allCases.firstIndex(of: annotation.exitEffect) {
            buildOutMenu.selectedIndex = xIndex
        }
        shadowToggle.isOn = annotation.showShadow

        let strokes = annotation.drawingStrokes.count
        strokesLabel.stringValue = "\(strokes) stroke\(strokes == 1 ? "" : "s")"
        undoStrokeButton.isHidden = strokes == 0
        clearStrokesButton.isHidden = strokes == 0

        if startField.currentEditor() == nil {
            startField.stringValue = String(format: "%.2f", annotation.startTime)
        }
        if endField.currentEditor() == nil {
            endField.stringValue = String(format: "%.2f", annotation.endTime)
        }
    }

    private func name(for type: AnnotationType) -> String {
        switch type {
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .callout: return "Callout"
        case .drawing: return "Drawing"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .tap: return "Tap Indicator"
        }
    }

    private func icon(for type: AnnotationType) -> String {
        switch type {
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .callout: return "bubble.left"
        case .drawing: return "scribble"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .tap: return "hand.tap"
        }
    }
}
