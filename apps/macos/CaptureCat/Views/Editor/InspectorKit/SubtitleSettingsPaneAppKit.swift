import AppKit

/// The Subtitles tab as a native AppKit pane — faithful port of
/// SubtitleSettingsView on the InspectorKit: generate/manage section, preset
/// cards with live styled "Aa" previews, text/style sections with chips and
/// color wells, position pad, and the carded editable caption list.
@MainActor
final class SubtitleSettingsPaneAppKit: NSView, NSTextFieldDelegate {
    private let project: Project
    private let transcription = TranscriptionService()

    private let stack = NSStackView()
    private let showToggle = InspectorToggleControl("Show Subtitles")

    // Generate / manage
    private let generateButton = InspectorButton("Generate Subtitles")
    private let generateCaption = InspectorKitViews.caption("Auto-transcribes audio with Whisper AI. The model downloads automatically on first use (~150 MB).")
    private let progressSpinner = CCSpinner()
    private let progressLabel = InspectorKitViews.caption("")
    private let errorLabel = InspectorKitViews.caption("")
    private let manageRow = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let regenerateButton = InspectorButton("Regenerate")
    private let deleteButton = InspectorButton("Delete", destructive: true)

    // Presets
    private let presetsScroll = NSScrollView()
    private let presetsRow = NSStackView()
    private var presetCards: [SubtitlePresetCardControl] = []

    // Text
    private let sizeSlider = InspectorSliderRow(label: "Size", range: 16...64, step: 2)
    private let weightChips = InspectorChipsControl()
    private let fontMenu = InspectorMenuControl()
    private let uppercaseToggle = InspectorToggleControl("Uppercase")
    private let textColorWell = InspectorColorWellControl()

    // Style
    private let positionChips = InspectorChipsControl()
    private let positionPad: SubtitlePositionPadControl
    private let styleChips = InspectorChipsControl()
    private let bgColorRow: NSView
    private let bgColorWell = InspectorColorWellControl()
    private let karaokeToggle = InspectorToggleControl("Karaoke Highlight")
    private let highlightColorRow: NSView
    private let highlightColorWell = InspectorColorWellControl()

    // Captions list
    private var editBox: NSView!
    private let captionsStack = NSStackView()
    private var captionFields: [UUID: NSTextField] = [:]
    private var captionCards: [NSView] = []
    private var captionTimeLabels: [NSTextField] = []
    private var lastCaptionSignature = ""

    private var detailViews: [NSView] = []

    override var isFlipped: Bool { true }

    init(project: Project) {
        self.project = project
        self.positionPad = SubtitlePositionPadControl(settings: project.settings)
        self.bgColorRow = InspectorKitViews.row("Background", control: bgColorWell)
        self.highlightColorRow = InspectorKitViews.row("Highlight", control: highlightColorWell)
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
        observe()
        // Separate from the settings observation loop — a CCTheme.apply must
        // not re-arm withObservationTracking.
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var themeObservation: CCThemeObservation?

    private func applyTheme() {
        countLabel.textColor = EditorThemeKit.textTertiary
        restyleCaptionCards()
    }

    private func fullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func build() {
        let subtitlesBox = InspectorSectionBox("Subtitles")
        subtitlesBox.addRow(showToggle)

        // Generate / manage
        subtitlesBox.addRow(generateButton)
        subtitlesBox.addRow(generateCaption, attached: true)
        subtitlesBox.addRow(progressSpinner)
        subtitlesBox.addRow(progressLabel, attached: true)
        errorLabel.textColor = .systemRed
        subtitlesBox.addRow(errorLabel, attached: true)

        countLabel.font = EditorThemeKit.label()
        manageRow.orientation = .horizontal
        manageRow.spacing = 8
        manageRow.addArrangedSubview(countLabel)
        manageRow.addArrangedSubview(NSView()) // spacer
        manageRow.addArrangedSubview(regenerateButton)
        manageRow.addArrangedSubview(deleteButton)
        subtitlesBox.addRow(manageRow)
        fullWidth(subtitlesBox)

        var details: [NSView] = []

        // Presets — horizontally scrolling card row
        let presetsBox = InspectorSectionBox("Presets")
        presetsRow.orientation = .horizontal
        presetsRow.spacing = 8
        for preset in SubtitlePreset.all {
            let card = SubtitlePresetCardControl(preset: preset)
            card.onClick = { [weak self] in
                guard let self else { return }
                preset.apply(to: self.project.settings)
            }
            presetsRow.addArrangedSubview(card)
            presetCards.append(card)
        }
        presetsScroll.documentView = presetsRow
        presetsRow.translatesAutoresizingMaskIntoConstraints = false
        presetsRow.topAnchor.constraint(equalTo: presetsScroll.contentView.topAnchor).isActive = true
        presetsRow.leadingAnchor.constraint(equalTo: presetsScroll.contentView.leadingAnchor).isActive = true
        presetsScroll.drawsBackground = false
        presetsScroll.hasHorizontalScroller = false
        presetsScroll.hasVerticalScroller = false
        presetsScroll.horizontalScrollElasticity = .allowed
        presetsScroll.verticalScrollElasticity = .none
        presetsScroll.heightAnchor.constraint(equalToConstant: 62).isActive = true
        presetsBox.addRow(presetsScroll)
        fullWidth(presetsBox)
        details.append(presetsBox)

        // Text
        let textBox = InspectorSectionBox("Text")
        textBox.addRow(sizeSlider)
        fontMenu.items = FontCatalog.menuNames.map { .init(title: $0, icon: nil) }
        textBox.addRow(InspectorKitViews.row("Font", control: fontMenu))
        weightChips.items = ProjectSettings.SubtitleWeight.allCases.map(\.rawValue)
        textBox.addRow(weightChips)
        textBox.addRow(uppercaseToggle)
        textBox.addRow(InspectorKitViews.row("Color", control: textColorWell))
        fullWidth(textBox)
        details.append(textBox)

        // Style
        let styleBox = InspectorSectionBox("Style")
        positionChips.items = ProjectSettings.SubtitlePosition.allCases.map(\.rawValue)
        styleBox.addRow(positionChips)
        styleBox.addRow(positionPad, attached: true)
        positionPad.heightAnchor.constraint(equalToConstant: 96).isActive = true
        styleChips.items = ProjectSettings.SubtitleStyle.allCases.map(\.rawValue)
        styleBox.addRow(styleChips)
        styleBox.addRow(bgColorRow)
        styleBox.addRow(karaokeToggle)
        styleBox.addRow(highlightColorRow)
        fullWidth(styleBox)
        details.append(styleBox)

        let captionsBox = InspectorSectionBox("Edit Subtitles")
        captionsStack.orientation = .vertical
        captionsStack.alignment = .leading
        captionsStack.spacing = 8
        captionsBox.addRow(captionsStack)
        fullWidth(captionsBox)
        editBox = captionsBox

        detailViews = details
    }

    private func wire() {
        showToggle.onChange = { [weak self] on in self?.project.settings.showSubtitles = on }
        generateButton.onClick = { [weak self] in self?.generate() }
        regenerateButton.onClick = { [weak self] in
            self?.project.subtitles.removeAll()
            self?.generate()
        }
        deleteButton.onClick = { [weak self] in self?.project.subtitles.removeAll() }

        sizeSlider.onChange = { [weak self] v in self?.project.settings.subtitleFontSize = v }
        fontMenu.onSelect = { [weak self] i in
            self?.project.settings.subtitleFontName = FontCatalog.storedName(forMenuIndex: i)
        }
        weightChips.onSelect = { [weak self] i in
            self?.project.settings.subtitleWeight = ProjectSettings.SubtitleWeight.allCases[i]
        }
        uppercaseToggle.onChange = { [weak self] on in self?.project.settings.subtitleUppercase = on }
        textColorWell.getColor = { [weak self] in
            self?.project.settings.subtitleColor.nsColor ?? .white
        }
        textColorWell.setColor = { [weak self] c in
            self?.project.settings.subtitleColor = CodableColor(c)
        }

        positionChips.onSelect = { [weak self] i in
            guard let self else { return }
            // Picking a stock anchor clears free placement (pad/preview drag).
            project.settings.subtitlePosition = ProjectSettings.SubtitlePosition.allCases[i]
            project.settings.subtitleCustomX = nil
            project.settings.subtitleCustomY = nil
        }
        styleChips.onSelect = { [weak self] i in
            self?.project.settings.subtitleStyle = ProjectSettings.SubtitleStyle.allCases[i]
        }
        bgColorWell.getColor = { [weak self] in
            self?.project.settings.subtitleBackgroundColor.nsColor ?? .black
        }
        bgColorWell.setColor = { [weak self] c in
            self?.project.settings.subtitleBackgroundColor = CodableColor(c)
        }
        karaokeToggle.onChange = { [weak self] on in self?.project.settings.highlightWords = on }
        highlightColorWell.getColor = { [weak self] in
            self?.project.settings.subtitleHighlightColor.nsColor ?? .systemYellow
        }
        highlightColorWell.setColor = { [weak self] c in
            self?.project.settings.subtitleHighlightColor = CodableColor(c)
        }
    }

    private func generate() {
        guard let videoURL = project.videoURL else { return }
        Task { @MainActor in
            do {
                let segments = try await transcription.transcribe(videoURL: videoURL)
                project.subtitles = segments
            } catch {
                transcription.error = error.localizedDescription
            }
        }
    }

    private func observe() {
        withObservationTracking { [weak self] in
            self?.apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
    }

    private func apply() {
        let s = project.settings
        showToggle.isOn = s.showSubtitles

        let show = s.showSubtitles
        let hasSubtitles = !project.subtitles.isEmpty
        let busy = transcription.isTranscribing

        generateButton.isHidden = !show || hasSubtitles || busy
        generateCaption.isHidden = generateButton.isHidden
        progressSpinner.isHidden = !show || !busy
        if busy { progressSpinner.startAnimation(nil) } else { progressSpinner.stopAnimation(nil) }
        progressLabel.isHidden = progressSpinner.isHidden
        progressLabel.stringValue = transcription.progress
        errorLabel.isHidden = !show || transcription.error == nil
        errorLabel.stringValue = transcription.error ?? ""
        manageRow.isHidden = !show || !hasSubtitles
        countLabel.stringValue = "\(project.subtitles.count) subtitles"

        for view in detailViews { view.isHidden = !show }
        bgColorRow.isHidden = !show || s.subtitleStyle != .background
        highlightColorRow.isHidden = !show || !s.highlightWords
        editBox.isHidden = !show || !hasSubtitles

        for card in presetCards {
            card.setActive(card.preset.matches(s))
        }
        sizeSlider.setValue(s.subtitleFontSize)
        weightChips.selectedIndex = ProjectSettings.SubtitleWeight.allCases.firstIndex(of: s.subtitleWeight) ?? 0
        uppercaseToggle.isOn = s.subtitleUppercase
        fontMenu.selectedIndex = FontCatalog.menuIndex(for: s.subtitleFontName)
        positionChips.selectedIndex = ProjectSettings.SubtitlePosition.allCases.firstIndex(of: s.subtitlePosition) ?? 0
        styleChips.selectedIndex = ProjectSettings.SubtitleStyle.allCases.firstIndex(of: s.subtitleStyle) ?? 0
        karaokeToggle.isOn = s.highlightWords
        textColorWell.refresh()
        bgColorWell.refresh()
        highlightColorWell.refresh()
        positionPad.refresh()

        rebuildCaptionListIfNeeded()
    }

    // MARK: - Caption list (flat cards with editable text fields)

    private func rebuildCaptionListIfNeeded() {
        let signature = project.subtitles.map { "\($0.id)" }.joined(separator: ",")
        guard signature != lastCaptionSignature else {
            // Text edits flow FROM the fields; only push model → field when
            // the field isn't being edited.
            for segment in project.subtitles {
                if let field = captionFields[segment.id],
                   field.currentEditor() == nil, field.stringValue != segment.text {
                    field.stringValue = segment.text
                }
            }
            return
        }
        lastCaptionSignature = signature
        captionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        captionFields.removeAll()
        captionCards.removeAll()
        captionTimeLabels.removeAll()

        for segment in project.subtitles {
            let card = NSView()
            card.wantsLayer = true
            card.layer?.cornerRadius = CCTheme.radius(.md)
            card.layer?.cornerCurve = .continuous
            card.layer?.borderWidth = 1
            captionCards.append(card)

            let time = NSTextField(labelWithString: "\(segment.startTime.formattedTimecode) — \(segment.endTime.formattedTimecode)")
            time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            captionTimeLabels.append(time)

            // House flat field — same chrome, padding and focus accent as
            // every other inspector text input.
            let field = InspectorFlatTextField(placeholder: "Text")
            field.stringValue = segment.text
            field.delegate = self
            field.identifier = NSUserInterfaceItemIdentifier(segment.id.uuidString)
            captionFields[segment.id] = field

            for v in [time, field] {
                v.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(v)
            }
            NSLayoutConstraint.activate([
                time.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
                time.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
                field.topAnchor.constraint(equalTo: time.bottomAnchor, constant: 4),
                field.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            ])

            captionsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: captionsStack.widthAnchor).isActive = true
        }
        restyleCaptionCards()
    }

    /// Caption-card chrome — rebuilt cards and theme changes share this path.
    private func restyleCaptionCards() {
        for card in captionCards {
            card.layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
            card.layer?.borderColor = EditorThemeKit.hairline.cgColor
        }
        for time in captionTimeLabels {
            time.textColor = EditorThemeKit.textTertiary
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let idString = field.identifier?.rawValue,
              let id = UUID(uuidString: idString),
              let index = project.subtitles.firstIndex(where: { $0.id == id }) else { return }
        project.subtitles[index].text = field.stringValue
    }
}

// MARK: - Preset card (live styled "Aa" — mirrors SubtitlePresetCard)

@MainActor
final class SubtitlePresetCardControl: NSControl {
    let preset: SubtitlePreset
    var onClick: (() -> Void)?

    private let sampleBox = NSView()
    private let sampleLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private var isActive = false
    private var themeObservation: CCThemeObservation?

    override var isFlipped: Bool { true }

    init(preset: SubtitlePreset) {
        self.preset = preset
        super.init(frame: .zero)

        sampleBox.wantsLayer = true
        sampleBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        sampleBox.layer?.cornerRadius = CCTheme.radius(.md)
        sampleBox.layer?.cornerCurve = .continuous
        sampleBox.layer?.borderWidth = 1

        sampleLabel.attributedStringValue = Self.sample(for: preset)
        sampleLabel.wantsLayer = true

        nameLabel.stringValue = preset.name
        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.alignment = .center

        for v in [sampleBox, sampleLabel, nameLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(sampleBox)
        sampleBox.addSubview(sampleLabel)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 66),
            sampleBox.topAnchor.constraint(equalTo: topAnchor),
            sampleBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            sampleBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            sampleBox.heightAnchor.constraint(equalToConstant: 40),
            sampleLabel.centerXAnchor.constraint(equalTo: sampleBox.centerXAnchor),
            sampleLabel.centerYAnchor.constraint(equalTo: sampleBox.centerYAnchor),
            nameLabel.topAnchor.constraint(equalTo: sampleBox.bottomAnchor, constant: 5),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setActive(false)
        // Card chrome only — the sampleBox backdrop and the styled "Aa" are
        // content (they preview the exported subtitle style) and keep their
        // fixed colors.
        themeObservation = CCThemeObservation { [weak self] in
            guard let self else { return }
            self.setActive(self.isActive)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The "Aa" rendered with the preset's REAL style recipe: weight,
    /// uppercase, color, background pill hue, and outline/glow shadow.
    private static func sample(for preset: SubtitlePreset) -> NSAttributedString {
        let color: NSColor = preset.karaoke ? (preset.highlight ?? .systemYellow) : preset.color
        let shadow = NSShadow()
        switch preset.style {
        case .glow:
            shadow.shadowColor = preset.color.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 5
        case .outline:
            shadow.shadowColor = .black
            shadow.shadowBlurRadius = 1.5
        case .background, .plain:
            shadow.shadowColor = .clear
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: preset.weight.nsWeight),
            .foregroundColor: color,
            .shadow: shadow,
        ]
        if preset.style == .background {
            attributes[.backgroundColor] = (preset.background ?? .black).withAlphaComponent(0.75)
        }
        return NSAttributedString(string: preset.uppercase ? "AA" : "Aa", attributes: attributes)
    }

    func setActive(_ active: Bool) {
        isActive = active
        let ink: NSColor = CCTheme.isDark ? .white : .black
        sampleBox.layer?.borderColor = active
            ? EditorThemeKit.selectionOutline.cgColor
            : ink.withAlphaComponent(0.09).cgColor
        sampleBox.layer?.borderWidth = active ? 1.5 : 1
        nameLabel.textColor = active ? EditorThemeKit.textPrimary : EditorThemeKit.textSecondary
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Position pad (native twin of SubtitlePositionPad)

@MainActor
final class SubtitlePositionPadControl: NSView {
    private let settings: ProjectSettings
    private let inset: CGFloat = 8
    private let pillSize = CGSize(width: 30, height: 16)
    private let fauxCard = CALayer()
    private let pill = CALayer()
    private let pillLabel = CATextLayer()

    override var isFlipped: Bool { true }

    init(settings: ProjectSettings) {
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CCTheme.radius(.lg)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        fauxCard.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        fauxCard.cornerRadius = 3
        fauxCard.cornerCurve = .continuous
        layer?.addSublayer(fauxCard)

        pill.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        pill.cornerRadius = 4
        pill.cornerCurve = .continuous
        pill.borderWidth = 1
        pill.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer?.addSublayer(pill)

        pillLabel.string = "Aa"
        pillLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        pillLabel.fontSize = 11
        pillLabel.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        pillLabel.alignmentMode = .center
        pillLabel.contentsScale = 2
        pill.addSublayer(pillLabel)

        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var themeObservation: CCThemeObservation?

    /// Pad chrome only — the faux video card and the "Aa" pill mimic the
    /// exported frame and keep their fixed colors.
    private func applyTheme() {
        let ink: NSColor = CCTheme.isDark ? .white : .black
        layer?.backgroundColor = ink.withAlphaComponent(0.06).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.12).cgColor
    }

    private var fraction: CGPoint {
        if let x = settings.subtitleCustomX, let y = settings.subtitleCustomY {
            return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }
        switch settings.subtitlePosition {
        case .top: return CGPoint(x: 0.5, y: 0)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        }
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fauxCard.frame = CGRect(
            x: (bounds.width - bounds.width * 0.42) / 2,
            y: (bounds.height - bounds.height * 0.42) / 2 - 6,
            width: bounds.width * 0.42, height: bounds.height * 0.42
        )
        let f = fraction
        let usableW = max(1, bounds.width - 2 * inset - pillSize.width)
        let usableH = max(1, bounds.height - 2 * inset - pillSize.height)
        pill.frame = CGRect(
            x: inset + usableW * f.x, y: inset + usableH * f.y,
            width: pillSize.width, height: pillSize.height
        )
        pillLabel.frame = CGRect(x: 0, y: 1, width: pillSize.width, height: 14)
        CATransaction.commit()
    }

    private func setFraction(from point: CGPoint) {
        let usableW = max(1, bounds.width - 2 * inset - pillSize.width)
        let usableH = max(1, bounds.height - 2 * inset - pillSize.height)
        let fx = (point.x - inset - pillSize.width / 2) / usableW
        let fy = (point.y - inset - pillSize.height / 2) / usableH
        settings.subtitleCustomX = Double(min(1, max(0, fx)))
        settings.subtitleCustomY = Double(min(1, max(0, fy)))
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        setFraction(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        setFraction(from: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        // Anchor snap — same thresholds as the SwiftUI pad.
        guard let x = settings.subtitleCustomX, let y = settings.subtitleCustomY,
              abs(x - 0.5) < 0.08 else { return }
        let anchors: [(ProjectSettings.SubtitlePosition, Double)] = [(.top, 0), (.center, 0.5), (.bottom, 1)]
        for (anchor, fy) in anchors where abs(y - fy) < 0.08 {
            settings.subtitlePosition = anchor
            settings.subtitleCustomX = nil
            settings.subtitleCustomY = nil
            refresh()
            return
        }
    }
}
