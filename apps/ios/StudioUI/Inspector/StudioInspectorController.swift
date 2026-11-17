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
    /// The inspector's ONE surface — flat (the house rule against
    /// card-in-card): a column is a plain region with a hairline on its
    /// leading edge; the bottom panel spans the width with only its top
    /// corners rounded; the side panel is a plain region.
    let surface = UIView()
    private let hairline = UIView()
    /// The panel's edge hairline (top for the bottom panel, leading for a
    /// column or side panel).
    private let edgeLine = UIView()
    /// The panel's strip: the option's title centred, ✓ (Done) trailing.
    let strip = UIView()
    /// The panel's ✓ key (both panel presentations) — confirms and closes.
    let closeButton = CCButton(symbol: "checkmark", style: .ghost, size: .sm, radius: .md)
    /// The panel's title (the option's name, or its pane's).
    let panelTitle = ccLabel("", font: CCFont.scaled(14, .semibold, .subheadline, max: 22), color: CCTheme.color.foreground,
                             alignment: .center)
    private(set) var panes: [InspectorTab: InspectorPaneView] = [:]
    private var paneBottoms: [InspectorTab: NSLayoutConstraint] = [:]
    private(set) var shownTab: InspectorTab?
    /// The option a panel shows (nil = the whole pane).
    private(set) var shownOption: InspectorPanelOption?
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
    /// The panel's ✓, VoiceOver's escape (the editor closes the panel).
    var onClosePanel: (() -> Void)?
    /// The shown pane or its height changed (`animated`: a pane switch —
    /// the panel resizes on the growth curve; else it follows the pane's own
    /// growth frame by frame).
    var onPanelContentChange: ((_ animated: Bool) -> Void)?
    private var reportedContentHeight: CGFloat = -1
    private var switchingPane = false

    #if DEBUG
    /// Probe seam — INJECTED DEFECT: the pane switch snaps (no crossfade).
    static var probeSnapPaneSwitch = false
    /// Probe seam — INJECTED DEFECT (`panel-card`): the panel is an inset
    /// floating card again (all corners rounded, a border, inset from the edges).
    static var probePanelCard = false
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
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.clipsToBounds = true
        surface.layer.cornerCurve = .continuous
        surface.accessibilityIdentifier = "studio.inspector.surface"
        root.addSubview(surface)
        pinEdges(surface, to: root)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        scroll.keyboardDismissMode = .interactive
        scroll.delegate = self
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        for v in [hairline, edgeLine, rail, strip, closeButton, panelTitle] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        closeButton.accessibilityLabelOverride = "Done"
        closeButton.accessibilityIdentifier = "inspector.close"
        closeButton.accessibilityHint = "Closes the panel."
        panelTitle.accessibilityTraits = .header
        panelTitle.adjustsFontForContentSizeCategory = true
        panelTitle.adjustsFontSizeToFitWidth = true
        panelTitle.minimumScaleFactor = 0.7
        strip.addSubview(panelTitle)
        strip.addSubview(closeButton)
        for v in [strip, scroll, hairline, rail, edgeLine] as [UIView] { surface.addSubview(v) }
        edgeLine.isUserInteractionEnabled = false

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            // The strip: title centred, ✓ trailing; it grows with big text.
            panelTitle.centerXAnchor.constraint(equalTo: strip.centerXAnchor),
            panelTitle.leadingAnchor.constraint(greaterThanOrEqualTo: strip.leadingAnchor, constant: 56),
            panelTitle.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -CCSpace.sm),
            panelTitle.topAnchor.constraint(greaterThanOrEqualTo: strip.topAnchor, constant: 6),
            panelTitle.bottomAnchor.constraint(lessThanOrEqualTo: strip.bottomAnchor, constant: -6),
            panelTitle.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            closeButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -CCSpace.sm),
            strip.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.panelStripHeight),
        ])
        panelTitle.setContentCompressionResistancePriority(.required, for: .vertical)
        // Column: pane | hairline | rail (the Mac column), flat.
        regularLayout = [
            edgeLine.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            edgeLine.topAnchor.constraint(equalTo: surface.topAnchor),
            edgeLine.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            edgeLine.widthAnchor.constraint(equalToConstant: 1),
            strip.heightAnchor.constraint(equalToConstant: 0),
            strip.topAnchor.constraint(equalTo: surface.topAnchor),
            strip.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 1),
            scroll.topAnchor.constraint(equalTo: surface.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
            hairline.topAnchor.constraint(equalTo: surface.topAnchor),
            hairline.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: hairline.trailingAnchor),
            rail.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            rail.topAnchor.constraint(equalTo: surface.topAnchor),
            rail.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: CCIconRail.keyWidth + 12),
        ]
        // Panels: the strip, a hairline, then ONLY the option's rows — no
        // pane rail (the tool bar is the switcher), no grabber (no drag).
        func panelLayout(side: Bool) -> [NSLayoutConstraint] {
            var c: [NSLayoutConstraint] = [
                strip.topAnchor.constraint(equalTo: surface.topAnchor),
                strip.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                { let c = strip.heightAnchor.constraint(equalToConstant: Self.panelStripHeight); c.priority = .init(700); return c }(),
                hairline.topAnchor.constraint(equalTo: strip.bottomAnchor),
                hairline.heightAnchor.constraint(equalToConstant: 1),
                hairline.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: hairline.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            ]
            if side {
                c += [edgeLine.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                      edgeLine.topAnchor.constraint(equalTo: surface.topAnchor),
                      edgeLine.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                      edgeLine.widthAnchor.constraint(equalToConstant: 1)]
            } else {
                c += [edgeLine.topAnchor.constraint(equalTo: surface.topAnchor),
                      edgeLine.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                      edgeLine.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                      edgeLine.heightAnchor.constraint(equalToConstant: 1)]
            }
            return c
        }
        compactLayout = panelLayout(side: false)
        sideLayout = panelLayout(side: true)
        NSLayoutConstraint.activate(regularLayout)
        activeLayout = regularLayout
        strip.isHidden = true

        rail.onSelect = { [weak self] index in
            self?.selection.inspectorTab = InspectorTab.allCases[index]
        }
        rail.onTrailing = { [weak self] in self?.runFeature(.showHistory) }
        closeButton.onTap = { [weak self] in self?.onClosePanel?() }
        surface.ccOnThemeChange { [weak self] in self?.restyleSurface() }
        restyleSurface()
    }

    private func restyleSurface() {
        surface.backgroundColor = CCTheme.color.card
        hairline.backgroundColor = CCTheme.color.border
        edgeLine.backgroundColor = CCTheme.color.border
        surface.layer.borderColor = surface.cc(CCTheme.color.border)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The pane's own growth (a row appearing) resizes the panel with it.
        let h = scroll.contentSize.height
        guard presentation == .bottomPanel, !switchingPane, abs(h - reportedContentHeight) > 0.5 else { return }
        reportedContentHeight = h
        onPanelContentChange?(false)
    }

    /// The panel strip's height (title, ✓).
    static let panelStripHeight: CGFloat = 44

    /// The height the panel needs to show its rows without scrolling.
    var panelFittingHeight: CGFloat {
        max(Self.panelStripHeight, strip.bounds.height) + 1 + scroll.contentSize.height + scroll.contentInset.bottom
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

    /// Lays the surface out for `presentation`.
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
        strip.isHidden = presentation == .column
        // Only the bottom panel's top corners round, where it meets the timeline.
        surface.layer.cornerRadius = presentation == .bottomPanel ? CCTheme.radius(.lg) : 0
        surface.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        surface.layer.borderWidth = 0
        #if DEBUG
        if Self.probePanelCard, presentation != .column {
            surface.layer.cornerRadius = CCTheme.radius(.lg)
            surface.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            surface.layer.borderWidth = 1
        }
        #endif
        if presentation == .column { setFocus(nil) }
        refreshPanelTitle()
        // The last row scrolls clear of the panel's bottom edge.
        scroll.contentInset.bottom = presentation == .column ? 0 : CCSpace.sm
        reportedContentHeight = -1
        view.setNeedsLayout()
    }

    private func refreshPanelTitle() {
        panelTitle.text = shownOption?.title ?? shownTab?.rawValue ?? selection.inspectorTab.rawValue
    }

    /// The sub-options the tool bar offers for `tab` (its drill-down level).
    func panelOptions(for tab: InspectorTab) -> [InspectorPanelOption] {
        pane(tab).panelOptions(scope)
    }

    /// Shows only `option`'s rows in the panel (nil = the whole pane); a
    /// choice option is applied first (one undo step) and its panel then
    /// shows the rest of its section.
    func setFocus(_ option: InspectorPanelOption?, apply: Bool = true, animated: Bool = false) {
        let switching = animated && shownOption != nil && shownOption?.id != option?.id && view.window != nil
        shownOption = option
        guard let tab = shownTab, let pane = panes[tab] else { refreshPanelTitle(); return }
        var rows = option.map { Set($0.rows) }
        if let option, let section = option.section, let choice = option.choice {
            if apply, choice.index != (pane.rows[choice.row] as? InspectorChoiceRowView)?.spec.read(scope) { (pane.rows[choice.row] as? InspectorChoiceRowView)?.apply(choice.index) }
            rows = Set(pane.rowsAfterChoice(section: section, scope: scope))
        }
        pane.setFocus(rows, scope: scope)
        refreshPanelTitle()
        scroll.setContentOffset(.zero, animated: false)
        switchingPane = true
        view.layoutIfNeeded()
        switchingPane = false
        reportedContentHeight = scroll.contentSize.height
        // Another option in an open panel: its rows rise in under a fade (the
        // pane switch's motion; a dissolve alone under Reduce Motion).
        var snap = !switching
        #if DEBUG
        if Self.probeSnapPaneSwitch { snap = true }
        #endif
        if !snap {
            CCMotion.fadeAlpha(pane, to: 1, duration: 0.22, delay: 0.04, from: 0)
            CCMotion.enter(pane.layer, .slideUp(distance: 14))
        }
    }

    /// Whether `option` has rows to show once applied (a choice like
    /// Transparent with nothing to adjust just applies).
    func optionHasRows(_ option: InspectorPanelOption, in tab: InspectorTab) -> Bool {
        guard option.choice != nil, let section = option.section else { return !option.rows.isEmpty }
        return !pane(tab).rowsAfterChoice(section: section, scope: scope).isEmpty
    }

    // MARK: Panes

    private func pane(_ tab: InspectorTab) -> InspectorPaneView {
        if let pane = panes[tab] { return pane }
        let pane = InspectorPaneView(tab: tab, host: self)
        content.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: CCSpace.lg),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -CCSpace.lg),
            pane.topAnchor.constraint(equalTo: content.topAnchor, constant: CCSpace.md),
        ])
        paneBottoms[tab] = pane.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -CCSpace.md)
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
        // A new pane shows whole until the tool bar picks one of its options.
        shownOption = nil
        new.setFocus(nil, scope: scope)
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


extension StudioInspectorController: UIScrollViewDelegate {}
