import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The iOS studio's inspector (docs/ios-studio-plan.md Phase 4d): all nine of
/// the Mac's panes, built from the shared specs (Studio/Editor/Inspector) —
/// every control writes exactly what the Mac pane writes.
///
///   `.column` (iPad, the iPhone Duo's layouts): a side column in the
///   editor's inspector container — the pane scrolls, the pane rail runs down
///   its trailing edge, like the Mac's column.
///   `.bottomPanel` (portrait phone): a PANEL the editor slides up from the
///   bottom over the timeline and tool bar (never the preview) when a tool is
///   tapped — a grabber strip with a close key, the pane rail across the top,
///   the pane below. Tap or drag the grabber down (or the close key) to go
///   back to the tool bar.
///   `.sidePanel` (landscape phone): the same panel beside the editor's
///   vertical tool rail — a title + close strip and the pane (the rail beside
///   it selects the pane).
///
/// The editor owns the panel's geometry and motion (`EditorViewController`);
/// this controller only lays out its card for the presentation.
///
/// Selection drives the pane (InspectorTabFollower, the Mac shell's rule).
/// State flows in through observation loops and out through the specs'
/// writes; every edit is one undo step on the editor's UndoManager
/// (InspectorEditSession). Feature keys (Transcribe, Auto Zoom, background
/// removal, voice-over, History) only call the `on…` closures — the
/// features are built in Studio 4e/4f and wired at merge.
@MainActor
final class StudioInspectorController: UIViewController, InspectorHost {
    let project: Project
    let selection: EditorShellSelection
    private let undo: () -> UndoManager?
    private let currentTime: () -> TimeInterval
    let env: InspectorEnvironment
    private(set) lazy var session = InspectorEditSession(
        project: { [unowned self] in self.project }, undoManager: { [weak self] in self?.undo() })

    // MARK: Feature hooks (wired by Studio 4e / 4f at merge)

    /// Subtitles ▸ Generate / Regenerate.
    var onTranscribe: (() -> Void)?
    /// Effects ▸ Zoom and Motion ▸ Auto Zoom.
    var onAutoZoom: (() -> Void)?
    /// Camera ▸ a Cutout / Pop-out look needs the person found (the Mac's
    /// segmentation ensureMask) — also its Remove Background key.
    var onRemoveBackground: (() -> Void)?
    /// Audio ▸ Record Voice Over.
    var onRecordVoiceOver: (() -> Void)?
    /// The rail's History key.
    var onShowHistory: (() -> Void)?
    /// A camera look that needs the person mask was picked (start it quietly).
    var onEnsureCameraMask: (() -> Void)?
    /// What Subtitles shows while a transcription runs.
    var transcription = InspectorTranscriptionState() {
        didSet { if transcription != oldValue { refreshVisiblePane() } }
    }
    /// Replaces the photo picker (harnesses, a future Files option).
    var imagePicker: ((_ logo: Bool, _ completion: @escaping (URL) -> Void) -> Void)?

    // MARK: Views

    let rail: CCIconRail
    let scroll = UIScrollView()
    private let content = UIView()
    private let card = CCSurface(.raisedMatte, tint: CCTheme.color.card, radius: .lg)
    private let hairline = UIView()
    private let grabber = InspectorGrabber()
    /// The panel's close key (both panel presentations).
    let closeButton = CCButton(symbol: "xmark", style: .ghost, size: .sm, radius: .full)
    /// The side panel's title (its pane's name; the rail beside it selects).
    private let panelTitle = ccLabel("", font: CCFont.header, color: CCTheme.color.foreground)
    private(set) var panes: [InspectorTab: InspectorPaneView] = [:]
    private var paneBottoms: [InspectorTab: NSLayoutConstraint] = [:]
    private(set) var shownTab: InspectorTab?
    private var observations: [SurfaceObservation] = []
    private var follower = InspectorTabFollower()
    /// How the editor shows the inspector.
    enum Presentation { case column, bottomPanel, sidePanel }
    private(set) var presentation: Presentation = .column
    /// A column (always on screen) — as opposed to a panel the tool bar opens.
    var isRegular: Bool { presentation == .column }
    private var regularLayout: [NSLayoutConstraint] = []
    private var compactLayout: [NSLayoutConstraint] = []
    private var sideLayout: [NSLayoutConstraint] = []
    private var activeLayout: [NSLayoutConstraint] = []
    /// The panel's close key / grabber tap (the editor closes the panel).
    var onClosePanel: (() -> Void)?
    /// A drag on the grabber: the editor moves the panel with the finger.
    var onPanelPan: ((UIGestureRecognizer.State, CGFloat) -> Void)?

    #if DEBUG
    /// Probe seam — INJECTED DEFECT: the pane switch snaps (no crossfade).
    static var probeSnapPaneSwitch = false
    #endif

    init(project: Project, selection: EditorShellSelection, undoManager: @escaping () -> UndoManager?,
         currentTime: @escaping () -> TimeInterval) {
        self.project = project
        self.selection = selection
        self.undo = undoManager
        self.currentTime = currentTime
        env = InspectorEnvironment.of(project)
        rail = CCIconRail(items: InspectorTab.allCases.map { CCIconRail.Item(title: $0.rawValue, symbol: $0.icon) },
                          selectedIndex: InspectorTab.allCases.firstIndex(of: selection.inspectorTab) ?? 0,
                          axis: .vertical,
                          trailing: CCIconRail.Item(title: "History", symbol: InspectorFeature.showHistory.symbol))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: InspectorHost

    var scope: InspectorScope {
        // No undo manager for the shared contexts: every inspector edit —
        // block adds and removes, an annotation delete — is ONE step of the
        // edit session, registered when the edit commits.
        let motion = InspectorPaneContexts.motion(
            project: project, selection: selection, undoManager: nil,
            currentTime: currentTime, refused: { CCHaptics.warning() })
        let annotate = InspectorPaneContexts.annotate(
            selection: selection, currentTime: currentTime(), undoManager: nil)
        return InspectorScope(project: project, env: env, motion: motion, annotate: annotate)
    }

    var presenter: UIViewController { self }

    func runFeature(_ feature: InspectorFeature) {
        switch feature {
        case .transcribe: onTranscribe?()
        case .autoZoom: onAutoZoom?()
        case .removeBackground: onRemoveBackground?()
        case .recordVoiceOver: onRecordVoiceOver?()
        case .showHistory: onShowHistory?()
        }
    }

    func ensureCameraMask() { onEnsureCameraMask?() }

    func pickImage(logo: Bool, _ completion: @escaping (URL) -> Void) {
        if let imagePicker { imagePicker(logo, completion); return }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        pickerCompletion = completion
        picker.delegate = pickerDelegate
        present(picker, animated: true)
    }

    private var pickerCompletion: ((URL) -> Void)?
    private lazy var pickerDelegate = PickerDelegate { [weak self] url in
        guard let url else { return }
        self?.pickerCompletion?(url)
        self?.pickerCompletion = nil
    }

    // MARK: Layout

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root
        view.accessibilityIdentifier = "studio.inspector"
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        pinEdges(card, to: root)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        scroll.keyboardDismissMode = .interactive
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        rail.translatesAutoresizingMaskIntoConstraints = false
        grabber.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabelOverride = "Close panel"
        closeButton.accessibilityIdentifier = "inspector.close"
        closeButton.accessibilityHint = "Returns to the tool bar."
        panelTitle.translatesAutoresizingMaskIntoConstraints = false
        panelTitle.accessibilityTraits = .header
        panelTitle.adjustsFontSizeToFitWidth = true
        panelTitle.minimumScaleFactor = 0.7
        for v in [grabber, scroll, hairline, rail, panelTitle, closeButton] as [UIView] { card.addSubview(v) }
        let closeKey = [
            closeButton.centerYAnchor.constraint(equalTo: grabber.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.sm),
        ]

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        // Regular: pane | hairline | rail (the Mac column).
        regularLayout = [
            grabber.heightAnchor.constraint(equalToConstant: 0),
            grabber.topAnchor.constraint(equalTo: card.topAnchor),
            grabber.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            grabber.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
            hairline.topAnchor.constraint(equalTo: card.topAnchor, constant: CCSpace.md),
            hairline.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -CCSpace.md),
            rail.leadingAnchor.constraint(equalTo: hairline.trailingAnchor),
            rail.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rail.topAnchor.constraint(equalTo: card.topAnchor),
            rail.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: CCIconRail.keyWidth + 12),
        ]
        // Compact: grabber, rail strip, hairline, pane (the bottom sheet).
        compactLayout = [
            grabber.topAnchor.constraint(equalTo: card.topAnchor),
            grabber.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            grabber.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            // 44 pt: the grabber is its own touch target (the card clips above it).
            grabber.heightAnchor.constraint(equalToConstant: 44),
            rail.topAnchor.constraint(equalTo: grabber.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rail.heightAnchor.constraint(equalToConstant: CCIconRail.keyHeight + 12),
            hairline.topAnchor.constraint(equalTo: rail.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            hairline.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.md),
            hairline.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.md),
            scroll.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ] + closeKey
        // Side panel: title + close strip, hairline, pane (no rail — the
        // editor's tool rail beside it selects the pane).
        sideLayout = [
            grabber.topAnchor.constraint(equalTo: card.topAnchor),
            grabber.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            grabber.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            grabber.heightAnchor.constraint(equalToConstant: 48),
            panelTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.lg),
            panelTitle.centerYAnchor.constraint(equalTo: grabber.centerYAnchor),
            panelTitle.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -CCSpace.sm),
            hairline.topAnchor.constraint(equalTo: grabber.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            hairline.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.md),
            hairline.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.md),
            scroll.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ] + closeKey
        NSLayoutConstraint.activate(regularLayout)
        activeLayout = regularLayout
        grabber.isHidden = true
        closeButton.isHidden = true
        panelTitle.isHidden = true

        rail.onSelect = { [weak self] index in
            self?.selection.inspectorTab = InspectorTab.allCases[index]
        }
        rail.onTrailing = { [weak self] in self?.runFeature(.showHistory) }
        grabber.onTap = { [weak self] in self?.onClosePanel?() }
        grabber.onPan = { [weak self] phase, dy in self?.onPanelPan?(phase, dy) }
        closeButton.onTap = { [weak self] in self?.onClosePanel?() }

        hairline.backgroundColor = CCTheme.color.border
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
    }

    /// How far the bottom panel runs below the screen (≥ its corner radius):
    /// no band shows under it and its bottom corners are out of sight.
    static let sheetOverhang: CGFloat = 40

    /// Mounts the inspector in the editor as a child; the editor constrains
    /// its view for each presentation.
    @available(iOS 26, *)
    func install(in editor: EditorViewController) {
        editor.addChild(self)
        editor.view.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        didMove(toParent: editor)
    }

    /// Lays the card out for `presentation`.
    func setPresentation(_ presentation: Presentation) {
        loadViewIfNeeded()
        guard presentation != self.presentation || activeLayout.isEmpty else { return }
        self.presentation = presentation
        NSLayoutConstraint.deactivate(activeLayout)
        switch presentation {
        case .column: activeLayout = regularLayout
        case .bottomPanel: activeLayout = compactLayout
        case .sidePanel: activeLayout = sideLayout
        }
        NSLayoutConstraint.activate(activeLayout)
        rail.axis = presentation == .column ? .vertical : .horizontal
        rail.isHidden = presentation == .sidePanel
        grabber.isHidden = presentation == .column
        grabber.showsPill = presentation == .bottomPanel
        // VoiceOver closes through the close key (the strip would overlap it).
        grabber.isAccessibilityElement = false
        closeButton.isHidden = presentation == .column
        panelTitle.isHidden = presentation != .sidePanel
        refreshPanelTitle()
        // The bottom panel runs `sheetOverhang` below the screen; its last
        // row must still scroll into view (the safe-area inset alone stops at
        // the screen's edge).
        let overhang = presentation == .bottomPanel ? Self.sheetOverhang : 0
        scroll.contentInset.bottom = overhang
        scroll.verticalScrollIndicatorInsets.bottom = overhang
        view.setNeedsLayout()
    }

    private func refreshPanelTitle() {
        panelTitle.text = shownTab?.rawValue ?? selection.inspectorTab.rawValue
    }

    // MARK: Panes

    private func pane(_ tab: InspectorTab) -> InspectorPaneView {
        if let pane = panes[tab] { return pane }
        let pane = InspectorPaneView(tab: tab, host: self)
        content.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: CCSpace.lg),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -CCSpace.lg),
            pane.topAnchor.constraint(equalTo: content.topAnchor, constant: CCSpace.lg),
        ])
        paneBottoms[tab] = pane.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -CCSpace.xl)
        pane.isHidden = true
        panes[tab] = pane
        return pane
    }

    /// Shows `tab`'s pane: the new pane rises in while the old one fades.
    func show(_ tab: InspectorTab, animated: Bool) {
        guard tab != shownTab else { return }
        let old = shownTab.flatMap { panes[$0] }
        let new = pane(tab)
        if let shownTab { paneBottoms[shownTab]?.isActive = false }
        paneBottoms[tab]?.isActive = true
        shownTab = tab
        refreshPanelTitle()
        rail.setSelectedIndex(InspectorTab.allCases.firstIndex(of: tab) ?? 0, animated: animated)
        new.isHidden = false
        new.refresh(scope)
        scroll.setContentOffset(.zero, animated: false)
        view.layoutIfNeeded()
        // Reduce Motion keeps the cross-fade; `enter` drops the rise.
        var snap = !animated || view.window == nil
        #if DEBUG
        if Self.probeSnapPaneSwitch { snap = true }
        #endif
        if snap {
            old?.isHidden = true
            old?.alpha = 1
            new.alpha = 1
            return
        }
        if let old {
            CCMotion.fadeAlpha(old, to: 0, duration: 0.14)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self, weak old] in
                guard let old, let self, self.shownTab != old.tab else { return }
                old.isHidden = true
                old.alpha = 1
            }
        }
        CCMotion.fadeAlpha(new, to: 1, duration: 0.22, delay: 0.06, from: 0)
        CCMotion.enter(new.layer, .slideUp(distance: 14))
    }

    var visiblePane: InspectorPaneView? { shownTab.flatMap { panes[$0] } }

    private func refreshVisiblePane() {
        visiblePane?.refresh(scope)
    }

    private func startObserving() {
        // Selection → pane (the Mac shell's rule, shared).
        observations.append(SurfaceObservation { [weak self] in
            guard let self else { return }
            if let tab = self.follower.update(self.selection) {
                self.selection.inspectorTab = tab
            }
        })
        // The tab, then the shown pane's values and rules — ONE loop, so what
        // it tracks is always the pane on screen (two loops raced: the
        // refresh could re-arm on the previous pane's reads and the new one
        // stopped following the model).
        observations.append(SurfaceObservation { [weak self] in
            guard let self else { return }
            let tab = self.selection.inspectorTab
            self.show(tab, animated: self.view.window != nil)
            self.visiblePane?.refresh(self.scope)
        })
    }

    // MARK: Picker

    private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
        let done: (URL?) -> Void
        init(_ done: @escaping (URL?) -> Void) { self.done = done }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { done(nil); return }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                // The provider's file is deleted when this returns: copy it.
                var copy: URL?
                if let url {
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("inspector-pick-\(UUID().uuidString.prefix(8)).\(url.pathExtension.lowercased())")
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { copy = dest }
                }
                DispatchQueue.main.async { self.done(copy) }
            }
        }
    }
}

/// The panel's grabber: a pill on a 44 pt strip; a drag down closes the
/// panel with the finger, a tap closes it. One VoiceOver button ("Close
/// panel") on the bottom panel; the side panel's strip is just its header.
@MainActor
final class InspectorGrabber: UIControl {
    // Keyboard (iPad, Studio 6a): Tab / arrows focus it; Space or Return
    // activates it — the same action a tap sends.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { sendActions(for: .touchUpInside); return }
        super.pressesEnded(presses, with: event)
    }

    var onTap: (() -> Void)?
    var onPan: ((UIGestureRecognizer.State, CGFloat) -> Void)?
    private let pill = CALayer()

    init() {
        super.init(frame: .zero)
        layer.addSublayer(pill)
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityLabel = "Close panel"
        accessibilityTraits = .button
        accessibilityIdentifier = "inspector.grabber"
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() { pill.backgroundColor = cc(CCTheme.color.faintForeground) }

    var showsPill = true { didSet { pill.isHidden = !showsPill } }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The pill keeps its place near the top; the strip below it is target.
        pill.frame = CGRect(x: bounds.midX - 18, y: min(bounds.midY, 11) - 2.5, width: 36, height: 5)
        pill.cornerRadius = 2.5
    }

    /// The touch target is the whole strip, at least 44 pt tall.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: min(0, (bounds.height - 44) / 2)).contains(point)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        onPan?(g.state, g.translation(in: superview).y)
    }
}
