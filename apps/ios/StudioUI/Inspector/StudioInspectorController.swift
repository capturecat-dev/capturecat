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
///   `.bottomPanel` (portrait phone): a PANEL the editor grows directly ABOVE
///   its tool bar (which stays on screen and selects the pane) — a strip with
///   a swipe pill, the pane's title and Done, then ONLY the active tool's
///   pane. No pane rail inside (the tool bar is it). Its height fits the
///   pane, capped by the editor; beyond that the pane scrolls. Done, a swipe
///   down on the strip, a pull down past the pane's top or the active tool
///   again closes it.
///   `.sidePanel` (landscape phone): the same panel beside the editor's
///   vertical tool rail — the same strip (a swipe toward the rail closes).
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
    /// Clips the card's contents while the panel grows (the card keeps its
    /// material and shadow unclipped).
    private let clip = UIView()
    private let hairline = UIView()
    private let grabber = InspectorGrabber()
    /// The panel's Done key (both panel presentations) — closes it.
    let closeButton = CCButton(title: "Done", style: .ghost, size: .sm, radius: .full)
    /// The panel's title (its pane's name; the tool bar selects the pane).
    let panelTitle = ccLabel("", font: CCFont.header, color: CCTheme.color.foreground)
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
    /// The panel's Done key, a pull down past the pane's top, VoiceOver's
    /// escape (the editor closes the panel).
    var onClosePanel: (() -> Void)?
    /// A drag on the panel's strip: the editor moves the panel with the finger.
    var onPanelPan: ((UIGestureRecognizer.State, _ translation: CGPoint, _ velocity: CGPoint) -> Void)?
    /// The grab pill tapped / VoiceOver's Expand-Collapse: the editor toggles the detent.
    var onToggleDetent: (() -> Void)?
    /// Whether the panel can still grow (an upward drag on the pane moves it).
    var panelCanGrow: (() -> Bool)?
    /// The whole panel's drag (controls excluded) — `panelDragAccepts`.
    private(set) lazy var panelPan = UIPanGestureRecognizer(target: self, action: #selector(panelPanned(_:)))
    #if DEBUG
    /// Probe seam — INJECTED DEFECT: only the grab pill's strip drags.
    static var probeDragOnlyOnGrabber = false
    var probeGrabber: UIView { grabber }
    #endif
    /// The shown pane or its height changed (`animated`: a pane switch —
    /// the panel resizes on the growth curve; else it follows the pane's own
    /// growth frame by frame).
    var onPanelContentChange: ((_ animated: Bool) -> Void)?
    private var reportedContentHeight: CGFloat = -1
    private var switchingPane = false

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
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.clipsToBounds = true
        clip.layer.cornerRadius = CCTheme.radius(.lg)
        clip.layer.cornerCurve = .continuous
        card.addSubview(clip)
        pinEdges(clip, to: card)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        scroll.keyboardDismissMode = .interactive
        scroll.delegate = self
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        rail.translatesAutoresizingMaskIntoConstraints = false
        grabber.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabelOverride = "Done"
        closeButton.accessibilityIdentifier = "inspector.close"
        closeButton.accessibilityHint = "Closes the panel."
        panelTitle.translatesAutoresizingMaskIntoConstraints = false
        panelTitle.accessibilityTraits = .header
        panelTitle.adjustsFontSizeToFitWidth = true
        panelTitle.minimumScaleFactor = 0.7
        for v in [grabber, scroll, hairline, rail, panelTitle, closeButton] as [UIView] { clip.addSubview(v) }

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
        // Both panels: a strip (swipe pill, the pane's title, Done), a
        // hairline, then ONLY the active tool's pane — no pane rail (the
        // editor's tool bar beside or under the panel is the switcher).
        func panelLayout() -> [NSLayoutConstraint] {
            [
                grabber.topAnchor.constraint(equalTo: card.topAnchor),
                grabber.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                grabber.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                grabber.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.panelStripHeight),
                // The title sits under the pill band (a large text size grows the strip).
                panelTitle.topAnchor.constraint(greaterThanOrEqualTo: grabber.topAnchor, constant: 20),
                panelTitle.bottomAnchor.constraint(lessThanOrEqualTo: grabber.bottomAnchor, constant: -4),
                panelTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.lg),
                { let c = panelTitle.centerYAnchor.constraint(equalTo: grabber.centerYAnchor, constant: 3); c.priority = .defaultLow; return c }(),
                { let c = grabber.heightAnchor.constraint(equalToConstant: Self.panelStripHeight); c.priority = .init(700); return c }(),
                panelTitle.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -CCSpace.sm),
                closeButton.centerYAnchor.constraint(equalTo: panelTitle.centerYAnchor),
                closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.sm),
                hairline.topAnchor.constraint(equalTo: grabber.bottomAnchor),
                hairline.heightAnchor.constraint(equalToConstant: 1),
                hairline.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: CCSpace.md),
                hairline.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -CCSpace.md),
                scroll.topAnchor.constraint(equalTo: hairline.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            ]
        }
        compactLayout = panelLayout()
        sideLayout = panelLayout()
        NSLayoutConstraint.activate(regularLayout)
        activeLayout = regularLayout
        grabber.isHidden = true
        closeButton.isHidden = true
        panelTitle.isHidden = true

        rail.onSelect = { [weak self] index in
            self?.selection.inspectorTab = InspectorTab.allCases[index]
        }
        rail.onTrailing = { [weak self] in self?.runFeature(.showHistory) }
        grabber.onTap = { [weak self] in self?.onToggleDetent?() }
        panelPan.delegate = self
        card.addGestureRecognizer(panelPan)
        // The pane scrolls only once the panel drag declined the touch.
        scroll.panGestureRecognizer.require(toFail: panelPan)
        closeButton.onTap = { [weak self] in self?.onClosePanel?() }

        hairline.backgroundColor = CCTheme.color.border
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The pane's own growth (a section opening) resizes the panel with it.
        let h = scroll.contentSize.height
        guard presentation == .bottomPanel, !switchingPane, abs(h - reportedContentHeight) > 0.5 else { return }
        reportedContentHeight = h
        onPanelContentChange?(false)
    }

    /// The panel strip's height (swipe pill, title, Done).
    static let panelStripHeight: CGFloat = 48

    /// The height the panel needs to show its whole pane without scrolling.
    var panelFittingHeight: CGFloat {
        max(Self.panelStripHeight, grabber.bounds.height) + 1 + scroll.contentSize.height + scroll.contentInset.bottom
    }

    #if DEBUG
    /// Probe seam — INJECTED DEFECT: the pane tabs repeated inside the panel
    /// (the old sheet's row, under the strip, over the pane).
    func probeShowTabRow() {
        rail.isHidden = false
        rail.axis = .horizontal
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: grabber.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rail.heightAnchor.constraint(equalToConstant: CCIconRail.keyHeight + 12),
        ])
    }
    #endif

    /// The bottom panel is at its TALL detent: the pill reads Collapse, and
    /// the title carries the matching VoiceOver action.
    func setPanelExpanded(_ tall: Bool, canExpand: Bool) {
        grabber.accessibilityLabel = tall ? "Collapse panel" : "Expand panel"
        grabber.isAccessibilityElement = presentation == .bottomPanel && (tall || canExpand)
        let name = tall ? "Collapse panel" : "Expand panel"
        panelTitle.accessibilityCustomActions = presentation == .bottomPanel && (tall || canExpand)
            ? [UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.onToggleDetent?(); return true }] : nil
    }

    /// VoiceOver's escape (two-finger scrub) closes a panel.
    override func accessibilityPerformEscape() -> Bool {
        guard presentation != .column, !view.isHidden else { return false }
        onClosePanel?()
        return true
    }

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
        rail.axis = .vertical
        // A panel never repeats the pane tabs: the tool bar is the switcher.
        rail.isHidden = presentation != .column
        grabber.isHidden = presentation == .column
        grabber.showsPill = presentation == .bottomPanel
        grabber.isAccessibilityElement = presentation == .bottomPanel
        closeButton.isHidden = presentation == .column
        panelTitle.isHidden = presentation == .column
        refreshPanelTitle()
        // The last row scrolls clear of the panel's bottom edge (its 44 pt
        // hit target stays inside the pane).
        scroll.contentInset.bottom = presentation == .column ? 0 : CCSpace.md
        reportedContentHeight = -1
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
        switchingPane = true
        view.layoutIfNeeded()
        switchingPane = false
        reportedContentHeight = scroll.contentSize.height
        // A panel resizes to the new pane on the growth curve.
        if presentation != .column { onPanelContentChange?(animated && view.window != nil) }
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


extension StudioInspectorController: UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// A touch the panel drag may take: anywhere on the panel but a control
    /// (sliders, toggles, Done keep their touches) — the strip and its pill,
    /// the title, section headers, the gaps between rows.
    func panelDragAccepts(_ hit: UIView?) -> Bool {
        guard presentation != .column, let hit else { return false }
        #if DEBUG
        if Self.probeDragOnlyOnGrabber { return hit === grabber }
        #endif
        var v: UIView? = hit
        while let view = v, view !== self.view {
            if view === grabber { return true }
            if view is UIControl { return false }
            v = view.superview
        }
        return true
    }

    /// Whether a drag starting on the pane's scroll content moves the panel
    /// (the scroll-to-drag handoff of a sheet): UP only while the panel can
    /// still grow (compact); DOWN only with the pane scrolled to its top.
    func panelDragBegins(onContent: Bool, upward: Bool) -> Bool {
        guard onContent else { return true }
        if upward { return panelCanGrow?() ?? false }
        return scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 0.5
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard g === panelPan else { return true }
        return panelDragAccepts(touch.view)
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === panelPan, let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: view)
        switch presentation {
        case .column:
            return false
        case .sidePanel:
            // A swipe toward the rail, from the strip.
            return abs(v.x) > abs(v.y) && grabber.bounds.contains(pan.location(in: grabber))
        case .bottomPanel:
            guard abs(v.y) > abs(v.x) else { return false }
            let onContent = scroll.bounds.contains(pan.location(in: scroll))
            return panelDragBegins(onContent: onContent, upward: v.y < 0)
        }
    }

    @objc func panelPanned(_ g: UIPanGestureRecognizer) {
        onPanelPan?(g.state, g.translation(in: view.superview), g.velocity(in: view.superview))
    }
}

/// The panel's strip and its grab pill. The whole panel drags (the
/// inspector's pan); this is its visible affordance and, for VoiceOver and
/// a tap, a button that expands / collapses the panel.
@MainActor
final class InspectorGrabber: UIControl {
    var onTap: (() -> Void)?
    private let pill = CALayer()

    init() {
        super.init(frame: .zero)
        layer.addSublayer(pill)
        addAction(UIAction { [weak self] _ in
            guard let self, self.pillBand.insetBy(dx: 0, dy: -8).contains(self.touchPoint) else { return }
            self.onTap?()
        }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Expand panel"
        accessibilityHint = "Or drag the panel up or down."
        accessibilityIdentifier = "inspector.grabber"
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() { pill.backgroundColor = cc(CCTheme.color.mutedForeground) }

    var showsPill = true { didSet { pill.isHidden = !showsPill } }

    /// The pill's band: a 120 × 20 pt key over the strip's top (VoiceOver's
    /// frame; the title and Done sit under it).
    var pillBand: CGRect { CGRect(x: bounds.midX - 60, y: 0, width: 120, height: 20) }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.frame = CGRect(x: bounds.midX - 20, y: 7, width: 40, height: 5)
        pill.cornerRadius = 2.5
    }

    /// A tap on the pill's band toggles; the rest of the strip only drags.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }

    private var touchPoint: CGPoint = .zero
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchPoint = touch.location(in: self)
        return super.beginTracking(touch, with: event)
    }

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(pillBand, in: self) }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    // Keyboard: Space / Return toggles, as a tap does.
    override var canBecomeFocused: Bool { isEnabled && !isHidden && isUserInteractionEnabled && showsPill }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if ccIsActivation(presses), isEnabled { onTap?(); return }
        super.pressesEnded(presses, with: event)
    }
}
