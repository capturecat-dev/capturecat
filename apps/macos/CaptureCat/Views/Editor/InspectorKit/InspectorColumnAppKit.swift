import AppKit

/// The inspector column as a single AppKit view: NSScrollView content on the
/// left, hairline, icon rail on the right (the inspector docks at the
/// window's right edge).
@MainActor
final class InspectorColumnAppKit: NSView {
    private let project: Project
    private var onSelectTab: ((InspectorTab) -> Void)?

    private let scroll = NSScrollView()
    private let paneContainer = FlippedStackHost()
    private let hairline = NSView()
    private let railStack = NSStackView()
    private var railButtons: [InspectorTab: RailButton] = [:]
    /// The inspector tabs are one sibling rail, so their hover wash must be
    /// one travelling layer rather than independent button fills.
    private var railGlide: CCGlideHighlight?
    private var themeObservation: CCThemeObservation?

    // Native panes
    private let backgroundPane: BackgroundSettingsPaneAppKit
    private let cursorPane: CursorSettingsPaneAppKit
    private let cameraPane: CameraSettingsPaneAppKit
    private let audioPane: AudioSettingsPaneAppKit
    private let feelPane: MotionFeelPaneAppKit
    let motionPane: MotionSettingsPaneAppKit

    // Native (final-conversion) panes
    private let subtitlesPane: SubtitleSettingsPaneAppKit
    private let brandPane: BrandSettingsPaneAppKit
    private let annotatePane: AnnotationSettingsPaneAppKit

    private var panes: [InspectorTab: NSView] = [:]
    /// Only the SELECTED pane's bottom pins the document height — pinning all
    /// eight at once made the heights fight (and the collapsed loser was
    /// whichever pane was visible).
    private var paneBottomConstraints: [InspectorTab: NSLayoutConstraint] = [:]

    override var isFlipped: Bool { true }

    init(
        project: Project,
        motionContext: MotionPaneContext,
        annotateContext: AnnotatePaneContext,
        onSelectTab: @escaping (InspectorTab) -> Void
    ) {
        self.project = project
        self.onSelectTab = onSelectTab

        backgroundPane = BackgroundSettingsPaneAppKit(
            settings: project.settings,
            isDeviceRecording: project.recordingSourceKind == .device
                || project.sourceSegments.contains { $0.kind == .device },
            supportsMenuBar: project.recordingSourceKind != .device
        )
        cursorPane = CursorSettingsPaneAppKit(settings: project.settings)
        cursorPane.hasKeystrokeData = project.keystrokeDataURL != nil
        cursorPane.isWindowRecording = project.recordingSourceKind == .window
        cursorPane.hasShortcutData = project.keystrokeDataURL
            .flatMap { try? KeystrokeTracker.loadRecording(from: $0).events }?
            .contains { $0.shortcut != nil } ?? false
        cameraPane = CameraSettingsPaneAppKit(
            settings: project.settings,
            hasRecordedCamera: project.cameraVideoURL != nil
        )
        audioPane = AudioSettingsPaneAppKit(settings: project.settings)
        feelPane = MotionFeelPaneAppKit(settings: project.settings)
        motionPane = MotionSettingsPaneAppKit(project: project, context: motionContext)

        subtitlesPane = SubtitleSettingsPaneAppKit(project: project)
        brandPane = BrandSettingsPaneAppKit(project: project)
        annotatePane = AnnotationSettingsPaneAppKit(project: project, context: annotateContext)

        super.init(frame: .zero)
        wantsLayer = true

        panes = [
            .background: backgroundPane,
            .cursor: cursorPane,
            .camera: cameraPane,
            .audio: audioPane,
            .effects: motionPane,
            .motion: feelPane,
            .subtitles: subtitlesPane,
            .brand: brandPane,
            .annotations: annotatePane,
        ]

        buildLayout()
        buildRail()
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        layer?.backgroundColor = EditorThemeKit.panel.cgColor
        hairline.layer?.backgroundColor = EditorThemeKit.hairline.cgColor
    }

    private func buildLayout() {
        // Pane container: all panes stacked, one visible at a time — native
        // panes keep their observation loops alive across tab switches.
        for tab in InspectorTab.allCases {
            guard let pane = panes[tab] else { continue }
            pane.translatesAutoresizingMaskIntoConstraints = false
            paneContainer.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor, constant: 18),
                pane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor, constant: -18),
                pane.topAnchor.constraint(equalTo: paneContainer.topAnchor, constant: 18),
            ])
            // Inactive until the tab is selected — see update().
            let bottom = pane.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor, constant: -18)
            paneBottomConstraints[tab] = bottom
            pane.isHidden = true
        }

        // A constrained documentView MUST opt out of autoresizing-mask
        // constraints and be pinned to the clip view: with the mask left on,
        // the document collapsed to 0×0 under the live NSHostingController
        // topology (the P3 harness's pre-sized bare window masked it) — the
        // in-app "empty inspector pane" bug.
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = paneContainer
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        // Unobtrusive overlay scroller — the column is a flat card, a legacy
        // scroller gutter would read as chrome.
        scroll.scrollerStyle = .overlay
        // The card's bottom sits on the window edge (square, like the
        // timeline), so give the content a breathing inset — the last control
        // must never kiss the edge or clip mid-control.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)

        hairline.wantsLayer = true

        railStack.orientation = .vertical
        railStack.spacing = 6
        railStack.alignment = .centerX

        for v in [scroll, hairline, railStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // The soft minimum keeps the pane readable in fitting-size contexts
        // without ever fighting the width SwiftUI proposes for the column.
        let minWidth = scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        minWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            minWidth,

            hairline.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),

            railStack.leadingAnchor.constraint(equalTo: hairline.trailingAnchor),
            railStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            railStack.widthAnchor.constraint(equalToConstant: 84),
            railStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            paneContainer.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            paneContainer.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            paneContainer.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    private func buildRail() {
        railGlide = CCGlideHighlight(host: railStack, radius: .md)
        for tab in InspectorTab.allCases {
            let button = RailButton(icon: tab.icon, title: tab.rawValue)
            button.onClick = { [weak self] in
                self?.onSelectTab?(tab)
            }
            button.onHighlight = { [weak self] row, active in
                self?.railGlide?.update(row: row, active: active)
            }
            railStack.addArrangedSubview(button)
            railButtons[tab] = button
        }
    }

    func update(
        selectedTab: InspectorTab,
        motionContext: MotionPaneContext,
        annotateContext: AnnotatePaneContext,
        onSelectTab: @escaping (InspectorTab) -> Void
    ) {
        self.onSelectTab = onSelectTab
        motionPane.update(context: motionContext)
        annotatePane.update(context: annotateContext)
        // Subtitles/Brand panes re-render themselves via @Observable.

        for (tab, pane) in panes {
            pane.isHidden = tab != selectedTab
            // The visible pane alone drives the document height.
            paneBottomConstraints[tab]?.isActive = tab == selectedTab
        }
        for (tab, button) in railButtons {
            button.setSelected(tab == selectedTab)
        }
    }

    /// Flipped document view for the scroll area — panes lay out top-down.
    private final class FlippedStackHost: NSView {
        override var isFlipped: Bool { true }
    }

    /// Icon + label rail button: 72×56 rounded rect, panelElevated when
    /// selected, hover wash otherwise.
    private final class RailButton: NSControl {
        var onClick: (() -> Void)?

        private let iconView = NSImageView()
        private let titleField = NSTextField(labelWithString: "")
        private let iconName: String
        private var isSelected = false
        private var isHovering = false
        private var trackingArea: NSTrackingArea?
        private var themeObservation: CCThemeObservation?
        /// Assigned by the tab rail to use its single persistent wash.
        var onHighlight: ((RailButton, Bool) -> Void)?

        override var isFlipped: Bool { true }

        init(icon: String, title: String) {
            self.iconName = icon
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = EditorThemeKit.controlRadius
            layer?.cornerCurve = .continuous

            iconView.contentTintColor = EditorThemeKit.textSecondary
            titleField.stringValue = title
            titleField.font = .systemFont(ofSize: 10, weight: .medium)
            titleField.textColor = EditorThemeKit.textSecondary
            titleField.alignment = .center
            titleField.lineBreakMode = .byTruncatingTail

            for v in [iconView, titleField] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 72),
                heightAnchor.constraint(equalToConstant: 56),
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.topAnchor.constraint(equalTo: topAnchor, constant: 9),
                titleField.centerXAnchor.constraint(equalTo: centerXAnchor),
                titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 68),
                titleField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            ])
            // restyle() re-resolves every color, so it doubles as applyTheme.
            themeObservation = CCThemeObservation { [weak self] in self?.restyle() }
        }

        required init?(coder: NSCoder) { fatalError() }

        func setSelected(_ selected: Bool) {
            isSelected = selected
            restyle()
        }

        private func restyle() {
            let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
            let name = isSelected ? "\(iconName).fill" : iconName
            // Not every symbol has a .fill variant — fall back to the base.
            iconView.image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: iconName, accessibilityDescription: nil))?
                .withSymbolConfiguration(config)
            let color = isSelected ? EditorThemeKit.textPrimary : EditorThemeKit.textSecondary
            iconView.contentTintColor = color
            titleField.textColor = color
            onHighlight?(self, isHovering && !isSelected)
            if isSelected {
                layer?.backgroundColor = EditorThemeKit.panelElevated.cgColor
            } else if isHovering && onHighlight == nil {
                layer?.backgroundColor = EditorThemeKit.hoverFill.cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true; restyle() }
        override func mouseExited(with event: NSEvent) { isHovering = false; restyle() }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }
    }
}
