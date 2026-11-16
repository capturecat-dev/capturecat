import AppKit

/// The Annotate tab as a native AppKit pane — faithful port of the redesigned
/// AnnotationSettingsView: type header with destructive delete (undoable),
/// per-type Text/Tap/Style sections, Effects (opacity + Build In/Out
/// + shadow), Drawing strokes management, and Timing.
@MainActor
final class AnnotationSettingsPaneAppKit: NSView, NSTextFieldDelegate {
    private let project: Project
    private var context: AnnotatePaneContext

    private let stack = NSStackView()

    // Empty state
    // Every control's title/range/step/readout, write and visibility: the
    // shared AnnotationPane spec (Studio/Editor/Inspector).
    private let emptyHeader = InspectorKitViews.header(AnnotationPane.emptyHeader)
    private let emptyCaption = InspectorKitViews.caption(AnnotationPane.emptyCaption)

    // Header
    private let headerRow = NSStackView()
    private let typeIcon = NSImageView()
    private let typeLabel = NSTextField(labelWithString: "")
    private let deleteButton = InspectorButton(AnnotationPane.delete)

    // Text section
    private let textCaption = InspectorKitViews.caption("Text")
    private let textField = InspectorFlatTextField(AnnotationPane.text)
    private let textTip = InspectorKitViews.caption(AnnotationPane.textTipCaption)
    private let fontSizeSlider = InspectorSliderRow(AnnotationPane.fontSize)
    private let weightChips = InspectorChipsControl(AnnotationPane.weight)
    private let fontMenu = InspectorMenuControl(AnnotationPane.font)
    private var fontRow: NSView!
    private let uppercaseToggle = InspectorToggleControl(AnnotationPane.uppercase)

    // Tap section
    private let tapCaption = InspectorKitViews.caption("Tap Ripple")
    private let tapSizeSlider = InspectorSliderRow(AnnotationPane.tapSize)
    private let tapTip = InspectorKitViews.caption(AnnotationPane.tapTipCaption)

    // Style section
    private let styleCaption = InspectorKitViews.caption("Style")
    private let colorWell = InspectorColorWellControl()
    private var colorRow: NSView!
    private let fillWell = InspectorColorWellControl()
    private let fillToggle = CaptureCatToggle()
    private var fillRow: NSView!
    private let fillRowLabel = NSTextField(labelWithString: "Background")
    private let cornersSlider = InspectorSliderRow(AnnotationPane.corners)
    private let borderSlider = InspectorSliderRow(AnnotationPane.border)

    // Effects section
    private let effectsCaption = InspectorKitViews.caption("Effects")
    private let opacitySlider = InspectorSliderRow(AnnotationPane.opacity)
    private let blackoutSlider = InspectorSliderRow(AnnotationPane.blackout)
    private let buildInMenu = InspectorMenuControl(AnnotationPane.buildIn)
    private var buildInRow: NSView!
    private let buildOutMenu = InspectorMenuControl(AnnotationPane.buildOut)
    private var buildOutRow: NSView!
    private let shadowToggle = InspectorToggleControl(AnnotationPane.shadow)

    // Drawing section
    private let drawingCaption = InspectorKitViews.caption("Strokes")
    private let drawingRow = NSStackView()
    private let strokesLabel = NSTextField(labelWithString: "")
    private let undoStrokeButton = InspectorButton(AnnotationPane.undoStroke)
    private let clearStrokesButton = InspectorButton(AnnotationPane.clearStrokes)
    private let drawingTip = InspectorKitViews.caption(AnnotationPane.drawingTipCaption)

    // Timing section
    private let timingCaption = InspectorKitViews.caption("Timing")
    private let timingRow = NSStackView()
    private let startField = InspectorFlatTextField(AnnotationPane.start, width: 56)
    private let endField = InspectorFlatTextField(AnnotationPane.end, width: 56)
    private let atPlayheadButton = InspectorButton(AnnotationPane.atPlayhead)
    private let timingTip = InspectorKitViews.caption(AnnotationPane.timingTipCaption)

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
        fontRow = InspectorKitViews.row(AnnotationPane.font.title, control: fontMenu)
        editor(fontRow)
        editor(weightChips)
        editor(uppercaseToggle)

        // Tap
        editor(tapCaption)
        editor(tapSizeSlider)
        editor(tapTip)

        // Style
        editorDivider()
        editor(styleCaption)
        colorRow = InspectorKitViews.row(AnnotationPane.color.title, control: colorWell)
        editor(colorRow)

        // Fill/background row: label left, well + switch right.
        fillRowLabel.font = EditorThemeKit.label()
        fillToggle.inspectorSpecID = AnnotationPane.fillToggle.id
        fillToggle.onChange = { [weak self] isOn in
            guard let self else { return }
            AnnotationPane.fillToggle.write(self.scope, isOn)
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
        editor(opacitySlider)
        editor(blackoutSlider)
        buildInRow = InspectorKitViews.row(AnnotationPane.buildIn.title, control: buildInMenu)
        editor(buildInRow)
        buildOutRow = InspectorKitViews.row(AnnotationPane.buildOut.title, control: buildOutMenu)
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

    /// The pane's scope for the shared spec: the selected annotation through
    /// the current context (rebuilt per use, so it always sees the latest).
    private var scope: InspectorScope {
        InspectorScope(settings: project.settings, project: project, annotate: context)
    }

    private func wire() {
        let scope: () -> InspectorScope? = { [weak self] in self?.scope }
        deleteButton.bind(AnnotationPane.delete, scope)
        fontSizeSlider.bind(AnnotationPane.fontSize, scope)
        tapSizeSlider.bind(AnnotationPane.tapSize, scope)
        fontMenu.bind(AnnotationPane.font, scope)
        uppercaseToggle.bind(AnnotationPane.uppercase, scope)
        weightChips.bind(AnnotationPane.weight, scope)
        colorWell.bind(AnnotationPane.color, scope)
        fillWell.bind(AnnotationPane.fillColor, scope, fallback: .black)
        cornersSlider.bind(AnnotationPane.corners, scope)
        borderSlider.bind(AnnotationPane.border, scope)
        opacitySlider.bind(AnnotationPane.opacity, scope)
        blackoutSlider.bind(AnnotationPane.blackout, scope)
        buildInMenu.bind(AnnotationPane.buildIn, scope)
        buildOutMenu.bind(AnnotationPane.buildOut, scope)
        shadowToggle.bind(AnnotationPane.shadow, scope)
        undoStrokeButton.bind(AnnotationPane.undoStroke, scope)
        clearStrokesButton.bind(AnnotationPane.clearStrokes, scope)
        atPlayheadButton.bind(AnnotationPane.atPlayhead, scope)
    }

    // NSTextFieldDelegate — commit text/time fields on end editing.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === textField {
            AnnotationPane.text.write(scope, field.stringValue)
        } else if field === startField {
            AnnotationPane.start.write(scope, field.stringValue)
        } else if field === endField {
            AnnotationPane.end.write(scope, field.stringValue)
        }
        apply()
    }

    // MARK: - Reads (observation)

    private func apply() {
        // Touch the whole annotations array so any property change re-arms.
        let annotations = project.annotations
        let scope = self.scope
        let idx = AnnotationPane.selectedIndex(scope)

        let hasSelection = idx != nil
        emptyHeader.isHidden = hasSelection
        emptyCaption.isHidden = hasSelection
        for view in editorViews { view.isHidden = !hasSelection }
        guard let idx else { return }
        let annotation = annotations[idx]
        let type = annotation.type

        // Header
        typeIcon.image = CCIcon.image(AnnotationPane.icon(for: type), pointSize: 13, weight: .semibold)
        typeLabel.stringValue = AnnotationPane.name(for: type)

        // Section visibility
        let isText = AnnotationPane.isText(scope)
        textCaption.isHidden = !isText
        textField.isHidden = !AnnotationPane.text.visible(scope)
        textTip.isHidden = !isText
        fontSizeSlider.isHidden = !AnnotationPane.fontSize.visible(scope)
        weightChips.isHidden = !AnnotationPane.weight.visible(scope)
        uppercaseToggle.isHidden = !AnnotationPane.uppercase.visible(scope)
        fontRow.isHidden = !AnnotationPane.font.visible(scope)

        let isTap = AnnotationPane.isTap(scope)
        tapCaption.isHidden = !isTap
        tapSizeSlider.isHidden = !AnnotationPane.tapSize.visible(scope)
        tapTip.isHidden = !isTap

        fillRow.isHidden = !AnnotationPane.hasFill(scope)
        fillRowLabel.stringValue = AnnotationPane.fillTitle(scope)
        cornersSlider.isHidden = !AnnotationPane.corners.visible(scope)
        borderSlider.isHidden = !AnnotationPane.border.visible(scope)
        shadowToggle.isHidden = !AnnotationPane.shadow.visible(scope)

        let isDrawing = AnnotationPane.isDrawing(scope)
        drawingCaption.isHidden = !isDrawing
        drawingRow.isHidden = !isDrawing
        drawingTip.isHidden = !isDrawing

        // Values (skip fields actively being edited — currentEditor is only
        // non-nil mid-edit; comparing against firstResponder fails the
        // nil-vs-nil case and left the fields stuck on their placeholders)
        if textField.currentEditor() == nil {
            textField.stringValue = AnnotationPane.text.read(scope)
        }
        fontSizeSlider.setValue(AnnotationPane.fontSize.read(scope))
        tapSizeSlider.setValue(AnnotationPane.tapSize.read(scope))
        if let wIndex = AnnotationPane.weight.read(scope) {
            weightChips.selectedIndex = wIndex
        }
        uppercaseToggle.isOn = AnnotationPane.uppercase.read(scope)
        fontMenu.selectedIndex = AnnotationPane.font.read(scope) ?? 0
        colorWell.refresh()
        fillWell.refresh()
        fillWell.isHidden = !annotation.showBackground
        fillToggle.isOn = AnnotationPane.fillToggle.read(scope)
        cornersSlider.setValue(AnnotationPane.corners.read(scope))
        borderSlider.slider.range = AnnotationPane.border.range(in: scope)
        borderSlider.setValue(AnnotationPane.border.read(scope))
        opacitySlider.setValue(AnnotationPane.opacity.read(scope))
        blackoutSlider.setValue(AnnotationPane.blackout.read(scope))
        if let eIndex = AnnotationPane.buildIn.read(scope) {
            buildInMenu.selectedIndex = eIndex
        }
        if let xIndex = AnnotationPane.buildOut.read(scope) {
            buildOutMenu.selectedIndex = xIndex
        }
        shadowToggle.isOn = AnnotationPane.shadow.read(scope)

        let strokes = AnnotationPane.strokeCount(scope)
        strokesLabel.stringValue = AnnotationPane.strokesText(scope)
        undoStrokeButton.isHidden = strokes == 0
        clearStrokesButton.isHidden = strokes == 0

        if startField.currentEditor() == nil {
            startField.stringValue = AnnotationPane.start.read(scope)
        }
        if endField.currentEditor() == nil {
            endField.stringValue = AnnotationPane.end.read(scope)
        }
    }
}
