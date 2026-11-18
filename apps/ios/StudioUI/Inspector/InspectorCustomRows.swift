import UIKit

/// The rows each front end draws itself (`InspectorRow.custom`): pads,
/// pickers, the Subtitles presets / caption list, the Annotate header,
/// strokes and timing, the demo previews. Their writes are the shared
/// specs' (the pane enums and InspectorPadMath).
@MainActor
enum InspectorCustomRows {
    static func make(id: String, visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) -> InspectorRowView {
        switch id {
        case "background.placementPad": return InspectorPlacementPad(host: host)
        case "camera.pad": return InspectorCameraPad(host: host)
        case "camera.tiltPad":
            return InspectorTiltPad(
                id: id, maxAngle: CameraPane.tiltMaxAngle, host: host, visible: visible,
                angles: { ($0.settings.cameraTiltPitch, $0.settings.cameraTiltYaw, 0) },
                write: { CameraPane.tilt($0, pitch: $1, yaw: $2) })
        case "blocks.tiltPad":
            return InspectorTiltPad(
                id: id, maxAngle: EffectBlocksPane.tiltMaxAngle, host: host, visible: visible,
                angles: { EffectBlocksPane.tiltAngles($0) },
                write: { EffectBlocksPane.tilt($0, pitch: $1, yaw: $2) })
        case "blocks.focusPad":
            return InspectorPointPad(
                id: id, title: "Focus", host: host, visible: visible,
                read: { EffectBlocksPane.focal($0) },
                write: { EffectBlocksPane.focus($0, fx: $1.x, fy: $1.y) })
        case "blocks.offsetPad":
            return InspectorPointPad(
                id: id, title: "Offset", host: host, visible: visible,
                read: { EffectBlocksPane.offsetPoint($0) },
                write: { EffectBlocksPane.offset($0, point: $1) })
        case "subtitles.positionPad": return InspectorSubtitlePad(host: host)
        case "brand.pad": return InspectorWatermarkPad(host: host)

        case "background.chooseImage":
            return InspectorImagePickRow(
                id: id, title: "Choose Image…", visible: visible, host: host,
                path: { $0.settings.backgroundImagePath },
                adopt: { BackgroundPane.adoptImage($0, path: $1) })
        case "camera.cardImage":
            return InspectorImagePickRow(
                id: id, title: "Choose Image…", visible: visible, host: host,
                path: { $0.settings.cameraCardImagePath },
                adopt: { CameraPane.adoptCardImage($0, path: $1) })
        case "background.wallpaperGrid":
            return InspectorNoteRow(
                id: id, visible: visible,
                text: "macOS wallpapers are picked on the Mac — a project's wallpaper renders here exactly as there.")
        case "effects.curtainLogo": return InspectorCurtainLogoRow(visible: visible, host: host)
        case "brand.logo": return InspectorBrandLogoRow(host: host)
        case "cursor.keyPermission":
            // iOS records no keystrokes and has no Input Monitoring to ask for.
            return InspectorNoteRow(id: id, visible: visible, text: "")

        case "subtitles.generate": return InspectorSubtitleGenerateRow(visible: visible, host: host)
        case "subtitles.manage": return InspectorSubtitleManageRow(visible: visible, host: host)
        case "subtitles.presets": return InspectorPresetRow(host: host)
        case "subtitles.captions": return InspectorCaptionListRow(host: host)

        case "annotate.empty": return InspectorAnnotateEmptyRow(visible: visible)
        case "annotate.header": return InspectorAnnotateHeaderRow(visible: visible, host: host)
        case "annotate.fillRow": return InspectorAnnotateFillRow(visible: visible, host: host)
        case "annotate.strokes": return InspectorStrokesRow(visible: visible, host: host)
        case "annotate.timing": return InspectorTimingRow(visible: visible, host: host)

        default:
            // The effect previews loop live on the shared maths (the Mac's
            // pads); the frame and cursor previews: the house preview well.
            if InspectorLivePreviewRow.ids.contains(id) {
                return InspectorLivePreviewRow(id: id, visible: visible, host: host)
            }
            return InspectorPreviewRow(id: id, visible: visible)
        }
    }
}

// MARK: - Base

@MainActor
class InspectorCustomRow: UIView, InspectorRowView {
    let rowID: String
    weak var host: InspectorHost?
    private let visible: (InspectorScope) -> Bool

    init(id: String, visible: @escaping (InspectorScope) -> Bool, host: InspectorHost?) {
        rowID = id
        self.visible = visible
        self.host = host
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func isRowVisible(_ scope: InspectorScope) -> Bool { visible(scope) }
    func refresh(_ scope: InspectorScope) {}

    func perform(_ id: String, _ name: String, _ edit: (InspectorScope) -> Void) {
        guard let host else { return }
        host.session.perform(id, name: name) { edit(host.scope) }
    }

    static func button(_ id: String, _ title: String, style: CCButton.Style = .secondary, symbol: String? = nil) -> CCButton {
        let b = CCButton(title: title, symbol: symbol, style: style, size: .sm)
        b.accessibilityIdentifier = id
        return b
    }

    static func hstack(_ views: [UIView], spacing: CGFloat = CCSpace.sm) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.spacing = spacing
        s.alignment = .center
        return s
    }
}

/// A muted line of copy.
final class InspectorNoteRow: InspectorCustomRow {
    init(id: String, visible: @escaping (InspectorScope) -> Bool, text: String) {
        super.init(id: id, visible: visible, host: nil)
        let label = ccLabel(text, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        label.adjustsFontForContentSizeCategory = true
        addSubview(label)
        pinEdges(label, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Image pick (Background ▸ Image, Camera ▸ Card image)

final class InspectorImagePickRow: InspectorCustomRow {
    private let thumb = CCSurface(.recessed, tint: CCTheme.color.elevated, radius: .sm)
    private let image = UIImageView()
    private let path: (InspectorScope) -> String?
    private var shownPath: String??

    init(id: String, title: String, visible: @escaping (InspectorScope) -> Bool, host: InspectorHost,
         path: @escaping (InspectorScope) -> String?, adopt: @escaping (InspectorScope, String) -> Void) {
        self.path = path
        super.init(id: id, visible: visible, host: host)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = CCTheme.radius(.sm)
        thumb.addSubview(image)
        pinEdges(image, to: thumb, inset: 3)
        thumb.widthAnchor.constraint(equalToConstant: 64).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let choose = Self.button(id, title, symbol: "photo")
        choose.onTap = { [weak self] in
            guard let self, let host = self.host else { return }
            host.pickImage(logo: false) { [weak self] url in
                self?.perform(id, "Background Image") { adopt($0, url.path) }
            }
        }
        let row = Self.hstack([thumb, choose, UIView()], spacing: CCSpace.md)
        addSubview(row)
        pinEdges(row, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        let p = path(scope)
        guard p != shownPath else { return }
        shownPath = p
        image.image = p.flatMap { UIImage(contentsOfFile: $0) }
    }
}

// MARK: - Curtain logo (Effects ▸ Curtain Unveil)

final class InspectorCurtainLogoRow: InspectorCustomRow {
    private let choose: CCButton
    private let remove: CCButton

    init(visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        choose = Self.button("effects.curtainLogoChoose", "Choose Logo…")
        remove = Self.button(EffectsPane.curtainLogoRemove.id, EffectsPane.curtainLogoRemove.title(host.scope),
                             style: .destructive)
        super.init(id: "effects.curtainLogo", visible: visible, host: host)
        choose.onTap = { [weak self] in
            guard let self, let host = self.host else { return }
            host.pickImage(logo: true) { [weak self] url in
                self?.perform("effects.curtainLogoChoose", "Curtain Logo") { try? EffectsPane.adoptCurtainLogo($0, from: url) }
            }
        }
        remove.onTap = { [weak self] in
            self?.perform(EffectsPane.curtainLogoRemove.id, "Remove Logo") { EffectsPane.curtainLogoRemove.run($0) }
        }
        let row = Self.hstack([choose, remove, UIView()])
        addSubview(row)
        pinEdges(row, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        choose.title = EffectsPane.curtainLogoChooseTitle(scope)
        remove.isHidden = !EffectsPane.curtainLogoRemove.visible(scope)
    }
}

// MARK: - Brand logo

final class InspectorBrandLogoRow: InspectorCustomRow {
    private let thumb = CCSurface(.recessed, tint: CCTheme.color.elevated, radius: .sm)
    private let image = UIImageView()
    private let placeholder = CCIconView("photo.badge.plus", pointSize: 15, tint: CCTheme.color.faintForeground)
    private let choose: CCButton
    private let remove: CCButton
    private let error = ccLabel("", font: CCFont.caption, color: CCTheme.color.destructive, lines: 0)
    private var loadedName: String??

    init(host: InspectorHost) {
        choose = Self.button("brand.choose", "Choose Logo…")
        remove = Self.button(BrandPane.remove.id, "Remove", style: .destructive)
        super.init(id: "brand.logo", visible: { _ in true }, host: host)
        image.contentMode = .scaleAspectFit
        thumb.addSubview(image)
        thumb.addSubview(placeholder)
        pinEdges(image, to: thumb, inset: 4)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 48), thumb.heightAnchor.constraint(equalToConstant: 48),
            placeholder.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
        ])
        choose.onTap = { [weak self] in
            guard let self, let host = self.host else { return }
            host.pickImage(logo: true) { [weak self] url in
                guard let self else { return }
                self.perform("brand.choose", "Watermark Logo") { scope in
                    do {
                        try BrandPane.adoptLogo(scope, from: url)
                        self.error.text = nil
                    } catch InspectorMediaError.noProjectFolder {
                        self.error.text = "Project folder not available."
                    } catch {
                        self.error.text = "Couldn't copy logo: \(error.localizedDescription)"
                    }
                }
            }
        }
        remove.onTap = { [weak self] in self?.perform(BrandPane.remove.id, "Remove Logo") { BrandPane.remove.run($0) } }
        let buttons = UIStackView(arrangedSubviews: [choose, remove])
        buttons.axis = .vertical
        buttons.alignment = .leading
        buttons.spacing = CCSpace.xs
        // Room for the keys' 44 pt hit targets (a 34 pt stack would clip them).
        buttons.isLayoutMarginsRelativeArrangement = true
        buttons.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
        let row = Self.hstack([thumb, buttons, UIView()], spacing: CCSpace.md)
        let column = UIStackView(arrangedSubviews: [row, error])
        column.axis = .vertical
        column.spacing = CCSpace.xs
        addSubview(column)
        pinEdges(column, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        choose.title = BrandPane.chooseTitle(scope)
        remove.isHidden = !BrandPane.remove.visible(scope)
        error.isHidden = (error.text ?? "").isEmpty
        let name = scope.settings.watermarkFileName
        if loadedName != name {
            loadedName = name
            image.image = scope.project?.watermarkImageURL.flatMap { UIImage(contentsOfFile: $0.path) }
            placeholder.isHidden = image.image != nil
        }
    }
}

// MARK: - Subtitles

/// Generate (the host transcribes — Studio 4e wires `onTranscribe`).
final class InspectorSubtitleGenerateRow: InspectorCustomRow {
    private let generate: CCButton
    private let caption = ccLabel("Auto-transcribes the recording's speech into editable subtitles.",
                                  font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    private let spinner = CCSpinner(diameter: 18)
    private let progress = ccLabel("", font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
    private let error = ccLabel("", font: CCFont.caption, color: CCTheme.color.destructive, lines: 0)

    init(visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        generate = CCButton(title: InspectorFeature.transcribe.title, symbol: InspectorFeature.transcribe.symbol,
                            style: .secondary, size: .sm)
        super.init(id: "subtitles.generate", visible: visible, host: host)
        generate.accessibilityIdentifier = "feature.transcribe"
        generate.onTap = { [weak host] in host?.runFeature(.transcribe) }
        let busyRow = Self.hstack([spinner, progress])
        let column = UIStackView(arrangedSubviews: [Self.hstack([generate, UIView()]), caption, busyRow, error])
        column.axis = .vertical
        column.spacing = CCSpace.xs
        addSubview(column)
        pinEdges(column, to: self)
        self.busyRow = busyRow
    }

    private var busyRow: UIView?

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        let state = host?.transcription ?? InspectorTranscriptionState()
        let canGenerate = SubtitlePane.generateVisible(scope, busy: state.isBusy)
        generate.superview?.isHidden = !canGenerate
        caption.isHidden = !canGenerate
        busyRow?.isHidden = !state.isBusy
        progress.text = state.progress
        error.text = state.error
        error.isHidden = state.error == nil
    }
}

final class InspectorSubtitleManageRow: InspectorCustomRow {
    private let count = ccLabel("", font: CCFont.labelMedium, color: CCTheme.color.mutedForeground)
    private let regenerate = InspectorCustomRow.button("subtitles.regenerate", "Regenerate")
    private let delete: CCButton

    init(visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        delete = Self.button(SubtitlePane.delete.id, "Delete", style: .destructive)
        super.init(id: "subtitles.manage", visible: visible, host: host)
        regenerate.onTap = { [weak self] in
            guard let self, let host = self.host else { return }
            self.perform("subtitles.regenerate", "Regenerate Subtitles") { SubtitlePane.clearForRegenerate($0) }
            host.runFeature(.transcribe)
        }
        delete.onTap = { [weak self] in self?.perform(SubtitlePane.delete.id, "Delete Subtitles") { SubtitlePane.delete.run($0) } }
        // Big Dynamic Type: the count wraps beside the keys instead of losing its end.
        count.numberOfLines = 0
        let row = Self.hstack([count, UIView(), regenerate, delete])
        addSubview(row)
        pinEdges(row, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) { count.text = SubtitlePane.countText(scope) }
}

/// Preset cards: a live styled "Aa" each; the active one rings.
final class InspectorPresetRow: InspectorCustomRow {
    private var cards: [(SubtitlePreset, InspectorPresetCard)] = []

    init(host: InspectorHost) {
        super.init(id: "subtitles.presets", visible: { _ in true }, host: host)
        accessibilityIdentifier = "subtitles.presets"
        let scroll = CCScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let row = UIStackView()
        row.spacing = CCSpace.sm
        for preset in SubtitlePreset.all {
            let card = InspectorPresetCard(preset: preset)
            card.addAction(UIAction { [weak self] _ in
                self?.perform("subtitles.presets", "Subtitle Preset") { SubtitlePane.applyPreset($0, preset) }
            }, for: .touchUpInside)
            row.addArrangedSubview(card)
            cards.append((preset, card))
        }
        scroll.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        addSubview(scroll)
        pinEdges(scroll, to: self)
        scroll.heightAnchor.constraint(equalToConstant: 78).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var probeCards: [UIControl] { cards.map(\.1) }

    override func refresh(_ scope: InspectorScope) {
        for (preset, card) in cards { card.isSelected = preset.matches(scope.settings) }
    }
}

final class InspectorPresetCard: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    private let sample = CCSurface(.recessed, tint: UIColor(white: 0, alpha: 0.6), radius: .md)
    private let label = UILabel()
    private let name: UILabel

    init(preset: SubtitlePreset) {
        name = ccLabel(preset.name, font: CCFont.scaled(11, .medium, .caption2, max: 15),
                       color: CCTheme.color.mutedForeground, alignment: .center)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.attributedText = Self.sample(preset, traits: traitCollection)
        label.textAlignment = .center
        // Dynamic Type: the sample is re-set at each text size.
        label.registerForTraitChanges([UITraitPreferredContentSizeCategory.self, CCAccessibilityTrait.self]) { (label: UILabel, _: UITraitCollection) in
            label.attributedText = Self.sample(preset, traits: label.traitCollection)
        }
        sample.addSubview(label)
        pinEdges(label, to: sample)
        let column = UIStackView(arrangedSubviews: [sample, name])
        column.axis = .vertical
        column.spacing = 4
        column.isUserInteractionEnabled = false
        addSubview(column)
        pinEdges(column, to: self)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            sample.heightAnchor.constraint(equalToConstant: 48),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(preset.name) preset"
        accessibilityTraits = .button
        sample.layer.borderWidth = 2
        restyle()
        ccOnThemeChange { [weak self] in self?.restyle() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            restyle()
            if isSelected { CCMotion.pop(sample, from: 0.94) }
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    override var isHighlighted: Bool {
        didSet { CCMotion.quick { self.alpha = self.isHighlighted ? 0.7 : 1 } }
    }

    private func restyle() {
        sample.layer.borderColor = isSelected ? cc(CCTheme.color.foreground) : UIColor.clear.cgColor
        name.textColor = isSelected ? CCTheme.color.foreground : CCTheme.color.mutedForeground
    }

    /// The "Aa" in the preset's real recipe: weight, case, colour, pill, shadow.
    private static func sample(_ preset: SubtitlePreset, traits: UITraitCollection) -> NSAttributedString {
        let color: UIColor = preset.karaoke ? (preset.highlight?.platformColor ?? .systemYellow) : preset.color.platformColor
        let shadow = NSShadow()
        switch preset.style {
        case .glow: shadow.shadowColor = preset.color.platformColor.withAlphaComponent(0.9); shadow.shadowBlurRadius = 5
        case .outline: shadow.shadowColor = UIColor.black; shadow.shadowBlurRadius = 1.5
        case .background, .plain: shadow.shadowColor = UIColor.clear
        }
        let weight: UIFont.Weight = {
            switch preset.weight {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            }
        }()
        var attributes: [NSAttributedString.Key: Any] = [
            // Dynamic Type: the sample grows with the text size (to 24 pt).
            .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: CCFont.legible(weight)), maximumPointSize: 24, compatibleWith: traits),
            .foregroundColor: color, .shadow: shadow,
        ]
        if preset.style == .background {
            attributes[.backgroundColor] = (preset.background?.platformColor ?? .black).withAlphaComponent(0.75)
        }
        return NSAttributedString(string: preset.uppercase ? "AA" : "Aa", attributes: attributes)
    }
}

/// The editable caption list: a card per caption with its times and text.
final class InspectorCaptionListRow: InspectorCustomRow {
    private let stack = UIStackView()
    private var signature = ""
    private(set) var fields: [UUID: CCField] = [:]

    init(host: InspectorHost) {
        super.init(id: "subtitles.captions", visible: { _ in true }, host: host)
        accessibilityIdentifier = "subtitles.captions"
        stack.axis = .vertical
        stack.spacing = CCSpace.sm
        addSubview(stack)
        pinEdges(stack, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        let subtitles = scope.project?.subtitles ?? []
        let sig = subtitles.map(\.id.uuidString).joined(separator: ",")
        guard sig != signature else {
            for segment in subtitles {
                if let field = fields[segment.id], !field.isFirstResponder, field.text != segment.text {
                    field.text = segment.text
                }
            }
            return
        }
        signature = sig
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fields.removeAll()
        for segment in subtitles {
            let card = CCCard(tint: CCTheme.color.elevated, radius: .md)
            let time = ccLabel("\(Self.timecode(segment.startTime)) — \(Self.timecode(segment.endTime))",
                               font: CCFont.monoSmall, color: CCTheme.color.faintForeground)
            let field = CCField(placeholder: "Text", value: segment.text)
            field.accessibilityIdentifier = "subtitles.caption.\(segment.id.uuidString)"
            field.accessibilityLabel = "Caption \(Self.timecode(segment.startTime))"
            let id = segment.id
            field.onTextChange = { [weak self] text in
                guard let host = self?.host else { return }
                host.session.begin("subtitles.caption.\(id)", name: "Edit Subtitle")
                SubtitlePane.setCaption(host.scope, id: id, text: text)
            }
            field.addAction(UIAction { [weak self] _ in self?.host?.session.commit() }, for: .editingDidEnd)
            field.onReturn = { [weak field] _ in field?.resignFirstResponder() }
            let column = UIStackView(arrangedSubviews: [time, field])
            column.axis = .vertical
            column.spacing = CCSpace.xs
            card.addSubview(column)
            pinEdges(column, to: card, inset: CCSpace.sm)
            stack.addArrangedSubview(card)
            fields[segment.id] = field
        }
    }

    static func timecode(_ t: TimeInterval) -> String {
        let total = max(0, t)
        return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Annotate

final class InspectorAnnotateEmptyRow: InspectorCustomRow {
    init(visible: @escaping (InspectorScope) -> Bool) {
        super.init(id: "annotate.empty", visible: visible, host: nil)
        let header = ccLabel(AnnotationPane.emptyHeader, font: CCFont.header, color: CCTheme.color.foreground)
        let caption = ccLabel(AnnotationPane.emptyCaption, font: CCFont.caption, color: CCTheme.color.mutedForeground, lines: 0)
        for l in [header, caption] { l.adjustsFontForContentSizeCategory = true }
        let column = UIStackView(arrangedSubviews: [header, caption])
        column.axis = .vertical
        column.spacing = CCSpace.sm
        addSubview(column)
        pinEdges(column, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class InspectorAnnotateHeaderRow: InspectorCustomRow {
    private let icon = CCIconView("textformat", pointSize: 15, weight: .semibold, tint: CCTheme.color.mutedForeground)
    private let name = ccLabel("", font: CCFont.header, color: CCTheme.color.foreground)
    private let delete: CCButton
    private var shownType: AnnotationType?

    init(visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        delete = Self.button(AnnotationPane.delete.id, "Delete", style: .destructive)
        super.init(id: "annotate.header", visible: visible, host: host)
        name.adjustsFontForContentSizeCategory = true
        delete.onTap = { [weak self] in self?.perform(AnnotationPane.delete.id, "Delete Annotation") { AnnotationPane.delete.run($0) } }
        let row = Self.hstack([icon, name, UIView(), delete])
        addSubview(row)
        pinEdges(row, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        guard let type = AnnotationPane.selected(scope)?.type, type != shownType else { return }
        shownType = type
        icon.image = CCIcon.image(AnnotationPane.icon(for: type), pointSize: 15, weight: .semibold)
        name.text = AnnotationPane.name(for: type)
    }
}

/// "Background"/"Fill": a well (while on) and a switch.
final class InspectorAnnotateFillRow: InspectorCustomRow {
    private let title = ccLabel("Background", font: CCFont.body, color: CCTheme.color.foreground)
    private let well = CCColorWell(title: "Background", color: .black)
    private let toggle = CCToggle()

    init(visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        super.init(id: "annotate.fillRow", visible: visible, host: host)
        title.adjustsFontForContentSizeCategory = true
        well.accessibilityIdentifier = AnnotationPane.fillColor.id
        toggle.accessibilityIdentifier = AnnotationPane.fillToggle.id
        toggle.accessibilityLabel = "Background"
        well.onChange = { [weak self] color in
            guard let host = self?.host else { return }
            host.session.begin(AnnotationPane.fillColor.id, name: "Fill Color")
            AnnotationPane.fillColor.write(host.scope, CodableColor(color))
        }
        well.onCommit = { [weak self] _ in self?.host?.session.commit() }
        toggle.onChange = { [weak self] on in
            self?.perform(AnnotationPane.fillToggle.id, "Background") { AnnotationPane.fillToggle.write($0, on) }
        }
        let row = Self.hstack([title, UIView(), well, toggle], spacing: CCSpace.md)
        addSubview(row)
        pinEdges(row, to: self)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        let t = AnnotationPane.fillTitle(scope)
        title.text = t
        well.title = t
        toggle.accessibilityLabel = t
        let on = AnnotationPane.fillToggle.read(scope)
        if toggle.isOn != on { toggle.setOn(on, animated: window != nil && toggle.bounds.width > 0) }
        well.isHidden = !AnnotationPane.fillColor.visible(scope)
        let color = AnnotationPane.fillColor.read(scope).platformColor
        if !well.color.isEqual(color) { well.color = color }
    }

    var probeToggle: CCToggle { toggle }
    var probeWell: CCColorWell { well }
}

final class InspectorStrokesRow: InspectorCustomRow {
    private let label = ccLabel("", font: CCFont.label, color: CCTheme.color.mutedForeground)
    private let undoLast: CCButton
    private let clear: CCButton

    init(visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        undoLast = Self.button(AnnotationPane.undoStroke.id, "Undo Last")
        clear = Self.button(AnnotationPane.clearStrokes.id, "Clear", style: .destructive)
        super.init(id: "annotate.strokes", visible: visible, host: host)
        undoLast.onTap = { [weak self] in self?.perform(AnnotationPane.undoStroke.id, "Undo Last Stroke") { AnnotationPane.undoStroke.run($0) } }
        clear.onTap = { [weak self] in self?.perform(AnnotationPane.clearStrokes.id, "Clear Strokes") { AnnotationPane.clearStrokes.run($0) } }
        let row = Self.hstack([label, UIView(), undoLast, clear])
        addSubview(row)
        pinEdges(row, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        label.text = AnnotationPane.strokesText(scope)
        undoLast.isHidden = !AnnotationPane.undoStroke.visible(scope)
        clear.isHidden = !AnnotationPane.clearStrokes.visible(scope)
    }
}

final class InspectorTimingRow: InspectorCustomRow {
    let start: InspectorTextRowView
    let end: InspectorTextRowView
    private let atPlayhead: CCButton

    init(visible: @escaping (InspectorScope) -> Bool, host: InspectorHost) {
        start = InspectorTextRowView(AnnotationPane.start, host: host, showsTitle: false)
        end = InspectorTextRowView(AnnotationPane.end, host: host, showsTitle: false)
        atPlayhead = Self.button(AnnotationPane.atPlayhead.id, "At Playhead")
        super.init(id: "annotate.timing", visible: visible, host: host)
        for field in [start.field, end.field] { field.keyboardType = .decimalPad }
        atPlayhead.onTap = { [weak self] in self?.perform(AnnotationPane.atPlayhead.id, "At Playhead") { AnnotationPane.atPlayhead.run($0) } }
        func labelled(_ title: String, _ view: UIView) -> UIView {
            let caption = ccLabel(title, font: CCFont.captionMedium, color: CCTheme.color.faintForeground)
            let column = UIStackView(arrangedSubviews: [caption, view])
            column.axis = .vertical
            column.spacing = 3
            view.widthAnchor.constraint(equalToConstant: 80).isActive = true
            return column
        }
        let row = UIStackView(arrangedSubviews: [labelled("Start", start), labelled("End", end), UIView(), atPlayhead])
        row.alignment = .bottom
        row.spacing = CCSpace.sm
        addSubview(row)
        pinEdges(row, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        start.refresh(scope)
        end.refresh(scope)
    }
}

// MARK: - Demo previews

/// The house preview well with a mini window card — the Background frame
/// style and the Cursor preview (the effect previews are
/// InspectorLivePreviewRow).
final class InspectorPreviewRow: InspectorCustomRow {
    private let well = CCPreviewPad(showsGridDots: false)
    private let card = CALayer()
    private let dim = CALayer()
    /// The Cursor pane's preview: the shared cursor artwork
    /// (`CursorStyleProvider`, the exporter's) at the project's size.
    let cursorLayer = CALayer()
    private var lastScope: InspectorScope?
    #if DEBUG
    /// Probe seam — INJECTED DEFECT (`blank-cursor-preview`): the cursor
    /// artwork is never set (the blank well the owner saw).
    static var probeBlankCursor = false
    #endif

    init(id: String, visible: @escaping (InspectorScope) -> Bool) {
        super.init(id: id, visible: visible, host: nil)
        well.ccInspectorHeight(84, compact: InspectorPadSize.compact(84))
        addSubview(well)
        pinEdges(well, to: self)
        card.backgroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        card.cornerCurve = .continuous
        card.shadowColor = UIColor.black.cgColor
        card.shadowOffset = CGSize(width: 0, height: 1)
        well.layer.addSublayer(card)
        dim.backgroundColor = UIColor.black.cgColor
        well.layer.addSublayer(dim)
        cursorLayer.contentsGravity = .resizeAspect
        well.layer.addSublayer(cursorLayer)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func refresh(_ scope: InspectorScope) {
        lastScope = scope
        let s = scope.settings
        let b = well.bounds
        // Laid out later (a panel opening): `layoutSubviews` runs this again.
        guard b.width > 1 else { return }
        refreshCursor(s, in: b)
        let scale: CGFloat = 1
        let offset = CGPoint.zero
        var corner: CGFloat = 4
        var shadow: Float = 0.3
        let maskAlpha: Float = 0
        switch rowID {
        case "background.framePad":
            corner = CGFloat(s.windowCornerRadius) / 2
            shadow = Float(s.shadowOpacity) * Float(min(1, s.shadowRadius / 30))
        default:
            break
        }
        let w = b.width * 0.46 * scale, h = b.height * 0.56 * scale
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        card.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        card.position = CGPoint(x: b.midX + offset.x, y: b.midY + offset.y)
        card.cornerRadius = corner
        card.shadowOpacity = shadow
        card.shadowRadius = 4
        dim.frame = b
        dim.cornerRadius = CCTheme.radius(.lg)
        dim.opacity = maskAlpha
        CATransaction.commit()
    }

    /// The cursor glyph over the mini window (cursor.preview only). iOS
    /// layers take a CGImage, never a UIImage (`LayerContents`).
    private func refreshCursor(_ s: ProjectSettings, in b: CGRect) {
        guard rowID == "cursor.preview" else { cursorLayer.isHidden = true; return }
        cursorLayer.isHidden = false
        let side = min(b.height * 0.6, 22 * CGFloat(max(0.5, min(3, s.cursorScale))))
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        var image = CursorStyleProvider.rasterizedCGImage(for: s.cursorStyle,
                                                          pixelSize: CGSize(width: side * scale, height: side * scale))
        #if DEBUG
        if Self.probeBlankCursor { image = nil }
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image.map { LayerContents.contents($0, size: CGSize(width: side, height: side)) }
        cursorLayer.contentsScale = scale
        cursorLayer.frame = CGRect(x: b.midX + b.width * 0.08, y: b.midY - side * 0.2, width: side, height: side)
        cursorLayer.opacity = s.showCursor ? 1 : 0.35
        CATransaction.commit()
    }

    private var laidOutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if let lastScope, well.bounds.width != laidOutWidth {
            laidOutWidth = well.bounds.width
            refresh(lastScope)
        }
    }
}
