import UIKit

/// The Library tab's navigation, in both size classes:
///  • compact width (iPhone, iPad Split View narrow): one stack — the grid,
///    details pushed on top (the in-content back button + swipe-back);
///  • regular width: TWO PANES — the grid on the left, the selected item's
///    detail on the right (its own stack, so project → share can push).
/// `adapt(regular:)` moves the detail stack between the two live when the
/// size class changes — nothing the user opened is lost.
final class LibraryCoordinator {
    let nav: HiddenBarNavigationController
    let split: LibrarySplitViewController
    var openCapture: (() -> Void)?
    /// iPad: show/hide the shell's sidebar; returns whether it's now visible.
    var toggleSidebar: (() -> Bool)?
    var sidebarVisible: (() -> Bool)?
    private(set) var isRegular = false

    init() {
        split = LibrarySplitViewController()
        nav = HiddenBarNavigationController(rootViewController: split)
        split.list.coordinator = self
    }

    private var detailNav: HiddenBarNavigationController { split.detailNav }

    // MARK: - Showing things

    func showProject(_ id: String) {
        show(row: .project(id)) { ProjectDetailViewController(projectID: id, coordinator: self) }
    }

    func showShare(_ videoID: String) {
        show(row: .share(videoID)) { ShareDetailViewController(videoID: videoID, coordinator: self) }
    }

    /// Push a share from within a detail (project → its share).
    func pushShare(_ videoID: String, from controller: UIViewController) {
        let detail = ShareDetailViewController(videoID: videoID, coordinator: self)
        (controller.navigationController ?? nav).pushViewController(detail, animated: true)
    }

    func pushProject(_ id: String, from controller: UIViewController) {
        let detail = ProjectDetailViewController(projectID: id, coordinator: self)
        (controller.navigationController ?? nav).pushViewController(detail, animated: true)
    }

    private func show(row: LibraryRow, make: () -> UIViewController) {
        if isRegular {
            if split.list.selectedRow == row, detailNav.viewControllers.count == 1 { return }
            split.list.selectedRow = row
            split.showDetail(make())
        } else {
            if nav.viewControllers.count > 1 { nav.popToRootViewController(animated: false) }
            nav.pushViewController(make(), animated: true)
        }
    }

    /// Deep link: `capturecat://open-project?id=…`.
    func open(projectID: String) {
        nav.dismiss(animated: false)
        if !isRegular, nav.viewControllers.count > 1 { nav.popToRootViewController(animated: false) }
        showProject(projectID)
    }

    /// A project was deleted: close any detail showing it.
    func projectDeleted(_ id: String) {
        let matches: (UIViewController) -> Bool = { ($0 as? ProjectDetailViewController)?.projectID.caseInsensitiveCompare(id) == .orderedSame }
        if isRegular {
            if detailNav.viewControllers.contains(where: matches) {
                split.list.selectedRow = nil
                split.showDetail(nil)
            }
        } else if let index = nav.viewControllers.firstIndex(where: matches) {
            nav.popToViewController(nav.viewControllers[max(0, index - 1)], animated: true)
        }
    }

    func popToRoot() {
        if isRegular {
            detailNav.popToRootViewController(animated: true)
        } else if nav.viewControllers.count > 1 {
            nav.popToRootViewController(animated: true)
        } else {
            split.list.scrollToTop()
        }
    }

    // MARK: - Size classes

    func adapt(regular: Bool) {
        guard regular != isRegular || split.mode == nil else { return }
        isRegular = regular
        split.list.setSidebarToggleAvailable(regular, sidebarVisible: sidebarVisible?() ?? true)
        if regular {
            let carried = Array(nav.viewControllers.dropFirst())
            nav.setViewControllers([split], animated: false)
            split.setMode(.twoPane)
            split.showDetail(carried.first, rest: Array(carried.dropFirst()), animated: false)
            if let project = carried.first as? ProjectDetailViewController {
                split.list.selectedRow = .project(project.projectID)
            } else if let share = carried.first as? ShareDetailViewController {
                split.list.selectedRow = .share(share.videoID)
            }
        } else {
            let carried = split.takeDetailStack()
            split.setMode(.single)
            split.list.selectedRow = nil
            nav.setViewControllers([split] + carried, animated: false)
        }
    }
}

/// A navigation controller whose system bar is NEVER shown (screens draw
/// CCHeaderBar instead) — with the interactive swipe-back kept alive.
final class HiddenBarNavigationController: UINavigationController, UIGestureRecognizerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        setNavigationBarHidden(true, animated: false)
        setToolbarHidden(true, animated: false)
        interactivePopGestureRecognizer?.delegate = self
        view.backgroundColor = CCTheme.color.background
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1 && transitionCoordinator == nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

/// The Library tab root: the grid alone (compact) or grid + detail pane.
final class LibrarySplitViewController: UIViewController {
    enum Mode {
        case single
        case twoPane
    }

    let list = LibraryViewController()
    let detailNav = HiddenBarNavigationController(rootViewController: DetailPlaceholderViewController())
    private(set) var mode: Mode?
    private let divider = CCDivider(vertical: true)
    private var listWidth: NSLayoutConstraint!
    private var listTrailing: NSLayoutConstraint!
    private let detailHost = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(list.view)
        list.didMove(toParent: self)
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(detailHost)
        view.addSubview(divider)
        listWidth = list.view.widthAnchor.constraint(equalToConstant: 380)
        listTrailing = list.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        NSLayoutConstraint.activate([
            list.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.view.topAnchor.constraint(equalTo: view.topAnchor),
            list.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: list.view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            detailHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailHost.topAnchor.constraint(equalTo: view.topAnchor),
            detailHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if mode == nil { setMode(.single) }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // The list pane: ~40% of the width, kept between 340 and 440 pt.
        listWidth.constant = min(440, max(340, view.bounds.width * 0.4))
    }

    func setMode(_ mode: Mode) {
        loadViewIfNeeded()
        guard mode != self.mode else { return }
        self.mode = mode
        switch mode {
        case .single:
            listWidth.isActive = false
            listTrailing.isActive = true
            divider.isHidden = true
            detailHost.isHidden = true
            if detailNav.parent != nil {
                detailNav.willMove(toParent: nil)
                detailNav.view.removeFromSuperview()
                detailNav.removeFromParent()
            }
        case .twoPane:
            listTrailing.isActive = false
            listWidth.isActive = true
            divider.isHidden = false
            detailHost.isHidden = false
            if detailNav.parent == nil {
                addChild(detailNav)
                detailNav.view.frame = detailHost.bounds
                detailNav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                detailHost.addSubview(detailNav.view)
                detailNav.didMove(toParent: self)
            }
        }
        view.setNeedsLayout()
    }

    /// Replace the detail pane's stack (nil = the placeholder). Crossfades.
    func showDetail(_ root: UIViewController?, rest: [UIViewController] = [], animated: Bool = true) {
        let stack = [root ?? DetailPlaceholderViewController()] + rest
        if animated, detailNav.view.window != nil {
            UIView.transition(with: detailNav.view, duration: CCMotion.paced(0.22), options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.detailNav.setViewControllers(stack, animated: false)
            }
        } else {
            detailNav.setViewControllers(stack, animated: false)
        }
    }

    /// Hand the detail stack over (going compact); leaves the placeholder.
    func takeDetailStack() -> [UIViewController] {
        let stack = detailNav.viewControllers.filter { !($0 is DetailPlaceholderViewController) }
        detailNav.setViewControllers([DetailPlaceholderViewController()], animated: false)
        return stack
    }
}

/// The empty detail pane.
final class DetailPlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        let empty = CCEmptyState(symbol: "play-fill", title: "Pick a recording",
                                 message: "Choose something from your library to watch it here.", showsWell: false)
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: CCSpace.xl),
        ])
    }
}
