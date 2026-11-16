import UIKit

/// How History and Merge Review appear (Studio 4f):
///
/// - **History, regular width (iPad)**: a SIDE PANEL — a floating card over
///   the editor's inspector column, sliding in from the trailing edge. It is
///   not modal: the stage, transport and scrubbing stay live, so a previewed
///   version can be scrubbed with the panel open (the Mac swaps its
///   inspector column for the History pane the same way).
/// - **History, compact width (iPhone)**: a SHEET rising from the bottom
///   edge (swipe down on its header or tap the scrim to close).
/// - **Merge Review**: the same sheet on iPhone; on iPad a modal side panel
///   over a scrim — a decision has to be made before editing goes on.
///
/// Motion is the house's (`CCMotion`): the panel arrives on `.arrive`, the
/// sheet on `.arrive` from below, both fading in; leaving glides out. Probe
/// seams expose the moving layer and its start offset so StudioLab's
/// `--history` can sample the entrance mid-flight.
@available(iOS 26, *)
@MainActor
final class HistoryPresentation {
    enum Style: Equatable { case sidePanel, sheet }

    #if DEBUG
    /// INJECTED DEFECT (`--history --inject snap-panel`): entrances snap.
    static var debugSnap = false
    #endif

    private static var openPanels: [ObjectIdentifier: HistoryPresentation] = [:]

    let panel: HistoryPanelController
    let style: Style
    private weak var editor: EditorViewController?
    /// Side panel: the card in the editor's view.
    private var card: CCCard?
    /// Sheet: the modal controller.
    private var sheet: HistorySheetController?

    static func current(in editor: EditorViewController) -> HistoryPresentation? {
        let key = ObjectIdentifier(editor)
        guard let open = openPanels[key] else { return nil }
        guard open.editor === editor else { openPanels[key] = nil; return nil }
        return open
    }

    static func style(for editor: EditorViewController) -> Style {
        // The editor's own regular/compact rule (EditorViewController.viewWillLayoutSubviews).
        editor.view.bounds.width >= 700 ? .sidePanel : .sheet
    }

    private init(panel: HistoryPanelController, style: Style, editor: EditorViewController) {
        self.panel = panel
        self.style = style
        self.editor = editor
    }

    static func present(_ panel: HistoryPanelController, in editor: EditorViewController) {
        let presentation = HistoryPresentation(panel: panel, style: style(for: editor), editor: editor)
        openPanels[ObjectIdentifier(editor)] = presentation
        panel.presentation = presentation
        switch presentation.style {
        case .sidePanel: presentation.mountSidePanel()
        case .sheet: presentation.mountSheet()
        }
    }

    static func presentReview(_ review: StudioMergeReviewController, in editor: EditorViewController) {
        let layout: HistorySheetController.Layout = style(for: editor) == .sidePanel ? .side : .sheet
        let sheet = HistorySheetController(content: review, layout: layout, modal: true)
        review.container = sheet
        CCAlert.topmost(from: editor).present(sheet, animated: false)
    }

    // MARK: Side panel

    static let panelWidth: CGFloat = 360

    private func mountSidePanel() {
        guard let editor else { return }
        let root = editor.view!
        let card = CCCard(floating: true, tint: CCTheme.color.popover, radius: .xl)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.accessibilityIdentifier = "studio.history.panel"
        root.addSubview(card)
        editor.addChild(panel)
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(panel.view)
        let width = max(Self.panelWidth, editor.inspectorContainer.bounds.width)
        NSLayoutConstraint.activate([
            card.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -CCSpace.md),
            card.widthAnchor.constraint(equalToConstant: min(width, 420)),
            card.topAnchor.constraint(equalTo: editor.header.bottomAnchor, constant: CCSpace.sm),
            card.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -CCSpace.md),
            panel.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            panel.view.topAnchor.constraint(equalTo: card.topAnchor),
            panel.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        panel.didMove(toParent: editor)
        self.card = card
        root.layoutIfNeeded()
        let travel = card.bounds.width + CCSpace.md * 2
        startOffset = travel
        #if DEBUG
        if Self.debugSnap { return }
        #endif
        guard !CCMotion.reduceMotion else {
            CCMotion.fadeAlpha(card, to: 1, duration: 0.2, from: 0)
            return
        }
        CCMotion.fadeAlpha(card, to: 1, duration: 0.18, from: 0)
        CCMotion.spring(card.layer, keyPath: "transform.translation.x", from: travel, to: 0, .arrive)
    }

    private func mountSheet() {
        guard let editor else { return }
        let sheet = HistorySheetController(content: panel, layout: .sheet, modal: true)
        sheet.onDismissed = { [weak self] in self?.finished() }
        self.sheet = sheet
        CCAlert.topmost(from: editor).present(sheet, animated: false)
    }

    /// Closes History (animated) — `completion` after it is gone.
    func dismiss(completion: (() -> Void)? = nil) {
        if let sheet {
            sheet.close(completion: completion)
            return
        }
        guard let card else { completion?(); return }
        let travel = card.bounds.width + CCSpace.md * 2
        CCMotion.fadeAlpha(card, to: 0, duration: 0.2)
        CCMotion.run(duration: 0.22, curve: .glide) {
            card.transform = CGAffineTransform(translationX: travel, y: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.24)) { [weak self] in
            self?.panel.willMove(toParent: nil)
            self?.panel.view.removeFromSuperview()
            self?.panel.removeFromParent()
            card.removeFromSuperview()
            self?.finished()
            completion?()
        }
    }

    private func finished() {
        guard let editor else { return }
        if Self.openPanels[ObjectIdentifier(editor)] === self { Self.openPanels[ObjectIdentifier(editor)] = nil }
        panel.didClose()
    }

    // MARK: Probe seams

    /// The surface that moves on entrance (side card or sheet card).
    var probeMovingView: UIView? { card ?? sheet?.card }
    /// Its entrance offset (x for the side panel, y for the sheet).
    private(set) var startOffset: CGFloat = 0
    var probeStartOffset: CGFloat { sheet?.startOffset ?? startOffset }
    var probeKeyPath: String { style == .sidePanel ? "transform.translation.x" : "transform.translation.y" }
}

/// A floating card presented over a scrim: `.sheet` docks to the bottom edge
/// (compact width), `.side` to the trailing edge (regular width). Hosts a
/// History panel or Merge Review.
@available(iOS 26, *)
@MainActor
final class HistorySheetController: UIViewController, UIGestureRecognizerDelegate {
    enum Layout { case sheet, side }

    let content: UIViewController
    let layout: Layout
    let modal: Bool
    let card = CCCard(floating: true, tint: CCTheme.color.popover, radius: .xl)
    private let scrim = UIView()
    private var hasEntered = false
    private var isFinishing = false
    var onDismissed: (() -> Void)?
    private(set) var startOffset: CGFloat = 0

    init(content: UIViewController, layout: Layout, modal: Bool) {
        self.content = content
        self.layout = layout
        self.modal = modal
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrim.backgroundColor = CCTheme.color.overlay
        scrim.alpha = 0
        scrim.frame = view.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.isAccessibilityElement = false
        view.addSubview(scrim)
        let tap = UITapGestureRecognizer(target: self, action: #selector(scrimTapped))
        scrim.addGestureRecognizer(tap)

        card.accessibilityViewIsModal = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.alpha = 0
        view.addSubview(card)
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: card.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        content.didMove(toParent: self)
        let guide = view.safeAreaLayoutGuide
        switch layout {
        case .sheet:
            let height = card.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.86)
            height.priority = .defaultHigh
            let fill = card.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -CCSpace.sm * 2)
            fill.priority = .required - 1
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                card.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
                fill, height,
                card.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: CCSpace.sm),
                card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -CCSpace.sm),
            ])
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
        case .side:
            NSLayoutConstraint.activate([
                card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -CCSpace.md),
                card.widthAnchor.constraint(equalToConstant: 400),
                card.topAnchor.constraint(equalTo: guide.topAnchor, constant: CCSpace.md),
                card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -CCSpace.md),
            ])
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasEntered else { return }
        hasEntered = true
        view.layoutIfNeeded()
        let keyPath = layout == .sheet ? "transform.translation.y" : "transform.translation.x"
        startOffset = layout == .sheet ? view.bounds.height - card.frame.minY : view.bounds.width - card.frame.minX
        #if DEBUG
        if HistoryPresentation.debugSnap {
            scrim.alpha = 0.6
            card.alpha = 1
            return
        }
        #endif
        CCMotion.fadeAlpha(scrim, to: 0.6, duration: 0.2, from: 0)
        CCMotion.fadeAlpha(card, to: 1, duration: 0.16, from: 0)
        if !CCMotion.reduceMotion {
            CCMotion.spring(card.layer, keyPath: keyPath, from: startOffset, to: 0, .arrive)
        }
        UIAccessibility.post(notification: .screenChanged, argument: card)
    }

    override func accessibilityPerformEscape() -> Bool { close(); return true }

    @objc private func scrimTapped() {
        if let review = content as? StudioMergeReviewController { review.cancel(); return }
        close()
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        let y = gesture.location(in: card).y
        return y < 64 || !card.bounds.contains(gesture.location(in: card))
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let dy = max(0, gesture.translation(in: view).y)
        switch gesture.state {
        case .changed:
            card.transform = CGAffineTransform(translationX: 0, y: dy)
            scrim.alpha = max(0, 0.6 - dy / 500)
        case .ended, .cancelled:
            if dy > 90 || gesture.velocity(in: view).y > 800 {
                scrimTapped()
            } else {
                CCMotion.springViews(.snappy) {
                    self.card.transform = .identity
                    self.scrim.alpha = 0.6
                }
            }
        default:
            break
        }
    }

    /// Glides out, then dismisses.
    func close(completion: (() -> Void)? = nil) {
        guard !isFinishing else { completion?(); return }
        isFinishing = true
        CCMotion.fadeAlpha(scrim, to: 0, duration: 0.18)
        let travel = layout == .sheet ? view.bounds.height - card.frame.minY : view.bounds.width - card.frame.minX
        CCMotion.run(duration: 0.22, curve: .glide) {
            self.card.transform = self.layout == .sheet
                ? CGAffineTransform(translationX: 0, y: travel) : CGAffineTransform(translationX: travel, y: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.22)) { [weak self] in
            guard let self else { return }
            self.dismiss(animated: false) {
                self.onDismissed?()
                completion?()
            }
        }
    }
}
