import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The iOS studio's inspector (docs/ios-studio-plan.md Phase 4d): all nine of
/// the Mac's panes, built from the shared specs (Studio/Editor/Inspector) —
/// every control writes exactly what the Mac pane writes.
///
///   iPad (regular width): a side column in the editor's inspector container
///   — the pane scrolls, the pane rail runs down its trailing edge, like the
///   Mac's column.
///   iPhone (compact): a bottom sheet docked over that container — a grabber,
///   the pane rail across the top, the pane below. Drag (or tap) the grabber
///   to raise it over the timeline and stage; it springs to the nearest stop.
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
    private(set) var panes: [InspectorTab: InspectorPaneView] = [:]
    private var paneBottoms: [InspectorTab: NSLayoutConstraint] = [:]
    private(set) var shownTab: InspectorTab?
    private var observations: [SurfaceObservation] = []
    private var follower = InspectorTabFollower()
    private(set) var isRegular = true
    private var regularLayout: [NSLayoutConstraint] = []
    private var compactLayout: [NSLayoutConstraint] = []
    private var hostRegular: [NSLayoutConstraint] = []
    private var hostCompact: [NSLayoutConstraint] = []
    private var sheetTop: NSLayoutConstraint?
    private weak var hostRoot: UIView?
    private var sheetMaxRaise: () -> CGFloat = { 0 }
    private(set) var isSheetRaised = false

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
        for v in [grabber, scroll, hairline, rail] as [UIView] { card.addSubview(v) }

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
            grabber.heightAnchor.constraint(equalToConstant: 22),
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
        ]
        NSLayoutConstraint.activate(regularLayout)
        grabber.isHidden = true

        rail.onSelect = { [weak self] index in
            self?.selection.inspectorTab = InspectorTab.allCases[index]
        }
        rail.onTrailing = { [weak self] in self?.runFeature(.showHistory) }
        grabber.onTap = { [weak self] in self?.setSheetRaised(!(self?.isSheetRaised ?? true), animated: true) }
        grabber.onPan = { [weak self] phase, dy in self?.panSheet(phase, dy) }

        hairline.backgroundColor = CCTheme.color.border
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
    }

    /// Mounts the inspector in the editor: the column fills the inspector
    /// container; the sheet docks on it and can rise to the header.
    @available(iOS 26, *)
    func install(in editor: EditorViewController) {
        editor.addChild(self)
        editor.view.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        let container = editor.inspectorContainer
        hostRoot = editor.view
        let top = view.topAnchor.constraint(equalTo: container.topAnchor)
        sheetTop = top
        hostRegular = [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        hostCompact = [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            top,
        ]
        let header = editor.header
        sheetMaxRaise = { [weak container, weak header, weak editor] in
            guard let container, let header, let root = editor?.view else { return 0 }
            let containerTop = container.convert(container.bounds, to: root).minY
            let limit = header.convert(header.bounds, to: root).maxY + CCSpace.sm
            return max(0, containerTop - limit)
        }
        NSLayoutConstraint.activate(hostRegular)
        didMove(toParent: editor)
    }

    /// The editor's width class (its own ≥ 700 pt rule).
    func setRegularWidth(_ regular: Bool) {
        guard regular != isRegular || (hostRegular.first?.isActive != true && hostCompact.first?.isActive != true) else { return }
        isRegular = regular
        loadViewIfNeeded()
        NSLayoutConstraint.deactivate(regular ? compactLayout : regularLayout)
        NSLayoutConstraint.activate(regular ? regularLayout : compactLayout)
        NSLayoutConstraint.deactivate(regular ? hostCompact : hostRegular)
        NSLayoutConstraint.activate(regular ? hostRegular : hostCompact)
        rail.axis = regular ? .vertical : .horizontal
        grabber.isHidden = regular
        if regular { sheetTop?.constant = 0; isSheetRaised = false }
        view.setNeedsLayout()
    }

    // MARK: Sheet

    func setSheetRaised(_ raised: Bool, animated: Bool) {
        guard !isRegular, let sheetTop else { return }
        isSheetRaised = raised
        let target = raised ? -sheetMaxRaise() : 0
        if animated {
            CCMotion.animate(sheetTop, to: target, in: hostRoot, duration: 0.42, curve: raised ? .bounce : .settle)
        } else {
            sheetTop.constant = target
            hostRoot?.layoutIfNeeded()
        }
        grabber.accessibilityValue = raised ? "Expanded" : "Collapsed"
    }

    private var panStart: CGFloat = 0

    private func panSheet(_ phase: UIGestureRecognizer.State, _ dy: CGFloat) {
        guard !isRegular, let sheetTop else { return }
        let maxRaise = sheetMaxRaise()
        switch phase {
        case .began:
            panStart = sheetTop.constant
        case .changed:
            sheetTop.constant = min(0, max(-maxRaise, panStart + dy))
            hostRoot?.layoutIfNeeded()
        default:
            setSheetRaised(-sheetTop.constant > maxRaise / 2, animated: true)
        }
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
        rail.setSelectedIndex(InspectorTab.allCases.firstIndex(of: tab) ?? 0, animated: animated)
        new.isHidden = false
        new.refresh(scope)
        scroll.setContentOffset(.zero, animated: false)
        view.layoutIfNeeded()
        var snap = !animated || view.window == nil || CCMotion.reduceMotion
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
                if !self.isRegular, !self.isSheetRaised { /* the docked sheet already shows the pane */ }
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

/// The sheet's grabber: a pill on a 22 pt strip; drag moves the sheet, a tap
/// toggles it. One VoiceOver button ("Inspector sheet", Expanded/Collapsed).
@MainActor
final class InspectorGrabber: UIControl {
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
        accessibilityLabel = "Inspector sheet"
        accessibilityValue = "Collapsed"
        accessibilityTraits = .button
        accessibilityIdentifier = "inspector.grabber"
        ccOnThemeChange { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyTheme() { pill.backgroundColor = cc(CCTheme.color.faintForeground) }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.frame = CGRect(x: bounds.midX - 18, y: bounds.midY - 2.5, width: 36, height: 5)
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
