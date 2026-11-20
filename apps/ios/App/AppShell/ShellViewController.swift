import UIKit

/// The signed-in shell: Library · Capture · Account.
///  • compact width (iPhone, narrow Split View): content full-screen with the
///    FLOATING CCTabBar over it (it slides away while a Library detail is
///    pushed, so the player and the comment composer get the room);
///  • regular width (iPad): a left CCSidebar — a full sidebar when there's
///    room, an icon rail on narrower iPads — and the content beside it.
/// Size-class changes re-lay-out live (and move the Library's detail stack
/// between push and two-pane, see LibraryCoordinator).
final class ShellViewController: UIViewController, UINavigationControllerDelegate {
    enum Tab: Int, CaseIterable {
        case library
        case capture
        case account
    }

    let library = LibraryCoordinator()
    let capture = CaptureHubViewController()
    let account = AccountViewController()
    private lazy var captureNav = HiddenBarNavigationController(rootViewController: capture)
    private lazy var accountNav = HiddenBarNavigationController(rootViewController: account)

    private static let items = [
        CCNavItem(title: String(localized: "Library", comment: "Tab name"), symbol: "grid"),
        CCNavItem(title: String(localized: "Capture", comment: "Tab name"), symbol: "record"),
        CCNavItem(title: String(localized: "Account", comment: "Tab name"), symbol: "person-circle"),
    ]

    private let content = UIView()
    let tabBar = CCTabBar(items: ShellViewController.items)
    private(set) lazy var sidebar = CCSidebar(items: Self.items, header: makeSidebarHeader())
    private let sidebarDivider = CCDivider(vertical: true)
    private var sidebarWidth: NSLayoutConstraint!
    private var tabBarBottom: NSLayoutConstraint!
    private var tabBarWidth: NSLayoutConstraint!
    private var tabBarHeight: NSLayoutConstraint!
    /// Bottom placement (the floating capsule) vs. a vertical bar in the
    /// system's bar region on a vertical edge (iPhone Duo folded).
    private var bottomPlacement: [NSLayoutConstraint] = []
    private var sidePlacement: [NSLayoutConstraint] = []
    private var sideSlide: NSLayoutConstraint?
    private(set) var tabBarEdge: NSDirectionalRectEdge?
    private(set) var selected: Tab = .library
    private(set) var isRegular: Bool?
    private var tabBarHidden = false
    /// Below this width the sidebar is an icon rail (fixtures can override).
    static var railBelowWidth: CGFloat = 1050

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        view.addSubview(sidebar)
        view.addSubview(sidebarDivider)
        view.addSubview(tabBar)
        library.openCapture = { [weak self] in self?.select(.capture, animated: true) }
        library.toggleSidebar = { [weak self] in self?.toggleSidebar() ?? true }
        library.sidebarVisible = { [weak self] in !(self?.sidebarCollapsed ?? false) }
        library.nav.delegate = self

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        tabBarBottom = tabBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        tabBarWidth = tabBar.widthAnchor.constraint(equalToConstant: 320)
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: tabBar.barHeight)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarWidth,
            sidebarDivider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarDivider.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebarDivider.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tabBarWidth, tabBarHeight,
        ])
        bottomPlacement = [tabBar.centerXAnchor.constraint(equalTo: view.centerXAnchor), tabBarBottom]
        NSLayoutConstraint.activate(bottomPlacement)

        tabBar.onSelect = { [weak self] index in self?.select(Tab(rawValue: index) ?? .library, animated: true) }
        tabBar.onReselect = { [weak self] _ in self?.reselect() }
        sidebar.onSelect = { [weak self] index in self?.select(Tab(rawValue: index) ?? .library, animated: true) }
        sidebar.onReselect = { [weak self] _ in self?.reselect() }
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self] + FoldingDisplay.traitsAffectingVerticalBarEdge) { (self: ShellViewController, _: UITraitCollection) in
            self.applyLayout(animated: true)
        }
        show(.library, animated: false)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyLayout(animated: false)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Full sidebar when there's room, an icon rail on narrower iPads.
        if isRegular == true, !CCMotion.isAnimating(sidebarWidth) {
            let wantsRail = view.bounds.width < Self.railBelowWidth
            if sidebar.isRail != wantsRail { sidebar.isRail = wantsRail }
            sidebarWidth.constant = sidebarCollapsed ? 0 : expandedSidebarWidth
        }
        placeTabBar()
        if tabBarEdge != nil {
            tabBarWidth.constant = 48
            tabBarHeight.constant = tabBar.verticalLength
            // Hidden: slid out past the screen edge it sits on.
            let away: CGFloat = tabBarHidden ? 48 + 40 : 0
            sideSlide?.constant = tabBarEdge == .trailing ? away : -away
        } else {
            tabBarWidth.constant = min(tabBar.intrinsicContentSize.width, view.bounds.width - CCSpace.lg * 2)
            tabBarHeight.constant = tabBar.barHeight
            tabBarBottom.constant = tabBarHidden ? tabBar.barHeight + 40 : (view.safeAreaInsets.bottom > 0 ? 0 : -CCSpace.md)
        }
        updateInsets()
    }

    // MARK: - Layout

    private func applyLayout(animated: Bool) {
        let regular = traitCollection.horizontalSizeClass == .regular
        let changed = regular != isRegular
        isRegular = regular
        library.adapt(regular: regular)
        if changed {
            let apply = {
                self.sidebar.isHidden = !regular || self.sidebarCollapsed
                self.sidebarDivider.isHidden = !regular || self.sidebarCollapsed
                self.tabBar.isHidden = regular
                if !regular { self.sidebarWidth.constant = 0 }
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            }
            if animated, view.window != nil {
                UIView.transition(with: view, duration: CCMotion.paced(0.25), options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply)
            } else {
                apply()
            }
        }
        refreshTabBarVisibility(animated: false)
        view.setNeedsLayout()
    }

    /// Where the compact tab bar goes: on the edge the system puts vertical
    /// bars (in its bar region, beside the content — so the content keeps
    /// its bottom), else the floating capsule at the bottom.
    private func placeTabBar() {
        var edge: NSDirectionalRectEdge?
        if #available(iOS 27.2, *), isRegular == false, let e = FoldingDisplay.verticalBarEdge(traitCollection) {
            edge = e
        }
        guard edge != tabBarEdge || (edge != nil && sidePlacement.isEmpty) else { return }
        NSLayoutConstraint.deactivate(bottomPlacement + sidePlacement)
        sidePlacement = []
        sideSlide = nil
        tabBarEdge = edge
        if #available(iOS 27.2, *), let edge {
            let region = view.layoutGuide(for: .bar(onEdge: edge))
            let slide = tabBar.centerXAnchor.constraint(equalTo: region.centerXAnchor)
            let fits = tabBar.heightAnchor.constraint(lessThanOrEqualTo: region.heightAnchor)
            sidePlacement = [slide, tabBar.centerYAnchor.constraint(equalTo: region.centerYAnchor), fits]
            sideSlide = slide
            NSLayoutConstraint.activate(sidePlacement)
        } else {
            NSLayoutConstraint.activate(bottomPlacement)
        }
        tabBar.isVertical = edge != nil
    }

    private func updateInsets() {
        // A vertical bar sits in the system's bar region, outside the
        // content's safe area: the content needs no extra inset for it.
        let compactBar = isRegular == false && !tabBarHidden && tabBarEdge == nil
        let inset = compactBar ? tabBar.barHeight + CCSpace.md : 0
        for child in [library.nav, captureNav, accountNav] where child.additionalSafeAreaInsets.bottom != inset {
            child.additionalSafeAreaInsets.bottom = inset
        }
        AppToaster.shared.bottomInset = view.safeAreaInsets.bottom + (compactBar ? tabBar.barHeight + CCSpace.md + 4 : CCSpace.md)
    }

    // MARK: - Sidebar collapse (the Mac browser's sidebar toggle)

    private(set) var sidebarCollapsed = false
    private var expandedSidebarWidth: CGFloat { view.bounds.width < Self.railBelowWidth ? 92 : 248 }

    /// Slide the sidebar away / back; the content's leading edge is the one
    /// that moves (growth lands on the bounce). Returns visibility.
    func toggleSidebar() -> Bool {
        sidebarCollapsed.toggle()
        let target: CGFloat = sidebarCollapsed ? 0 : expandedSidebarWidth
        sidebar.clipsToBounds = true
        if !sidebarCollapsed { sidebar.isHidden = false; sidebarDivider.isHidden = false }
        CCMotion.fadeAlpha(sidebar, to: sidebarCollapsed ? 0 : 1, duration: 0.2)
        CCMotion.animate(sidebarWidth, to: target, in: view, duration: 0.4, curve: sidebarCollapsed ? .settle : .bounce) { [weak self] in
            guard let self, self.sidebarCollapsed else { return }
            self.sidebar.isHidden = true
            self.sidebarDivider.isHidden = true
        }
        return !sidebarCollapsed
    }

    // MARK: - Tabs

    private func controller(for tab: Tab) -> UIViewController {
        switch tab {
        case .library: return library.nav
        case .capture: return captureNav
        case .account: return accountNav
        }
    }

    func select(_ tab: Tab, animated: Bool) {
        guard tab != selected else { return }
        tabBar.setSelectedIndex(tab.rawValue, animated: animated)
        sidebar.setSelectedIndex(tab.rawValue, animated: animated)
        show(tab, animated: animated)
    }

    private func show(_ tab: Tab, animated: Bool) {
        let old = children.first { $0 === controller(for: selected) && $0.view.superview === content }
        selected = tab
        let new = controller(for: tab)
        if new.parent !== self { addChild(new) }
        new.view.frame = content.bounds
        new.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(new.view)
        new.didMove(toParent: self)
        refreshTabBarVisibility(animated: animated)
        if let old, old !== new {
            if animated, view.window != nil {
                new.view.alpha = 0
                CCMotion.fadeAlpha(new.view, to: 1, duration: 0.2, from: 0)
                if !CCMotion.reduceMotion {
                    CCMotion.spring(new.view.layer, keyPath: "transform.translation.y", from: 6, to: 0, .smooth)
                }
                CCMotion.fadeAlpha(old.view, to: 0, duration: 0.14)
                DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.15)) {
                    guard old !== self.controller(for: self.selected) else { return }
                    old.view.removeFromSuperview()
                    old.view.alpha = 1
                }
            } else {
                old.view.removeFromSuperview()
            }
        }
        view.bringSubviewToFront(tabBar)
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func reselect() {
        switch selected {
        case .library: library.popToRoot()
        case .capture, .account: break
        }
    }

    // MARK: - Floating tab bar hides on pushed Library screens

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        guard navigationController === library.nav else { return }
        refreshTabBarVisibility(animated: animated, coordinator: navigationController.transitionCoordinator)
    }

    private func refreshTabBarVisibility(animated: Bool, coordinator: UIViewControllerTransitionCoordinator? = nil) {
        let hide = selected == .library && library.nav.viewControllers.count > 1 && isRegular == false
        guard hide != tabBarHidden else { return }
        tabBarHidden = hide
        let changes = {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.tabBar.alpha = hide ? 0 : 1
        }
        if animated, let coordinator {
            coordinator.animate(alongsideTransition: { _ in changes() }, completion: { [weak self] context in
                guard let self, context.isCancelled else { return }
                self.tabBarHidden = !hide
                UIView.performWithoutAnimation { changes() }
                self.refreshTabBarVisibility(animated: false)
            })
        } else if animated {
            CCMotion.springViews(.smooth, crossFading: view, changes)
        } else {
            changes()
        }
    }

    // MARK: - Deep links

    func openProject(_ id: String) {
        select(.library, animated: false)
        library.open(projectID: id)
    }

    private func makeSidebarHeader() -> UIView {
        let mark = UIImageView(image: SignInViewController.appMark())
        mark.contentMode = .scaleAspectFill
        mark.clipsToBounds = true
        mark.layer.cornerRadius = CCTheme.radius(.md)
        mark.layer.cornerCurve = .continuous
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 34), mark.heightAnchor.constraint(equalToConstant: 34)])
        let title = ccLabel("CaptureCat", font: CCFont.header, color: CCTheme.color.foreground)
        let row = UIStackView(arrangedSubviews: [mark, title])
        row.spacing = CCSpace.sm + 2
        row.alignment = .center
        row.isAccessibilityElement = true
        row.accessibilityLabel = "CaptureCat"
        row.accessibilityTraits = .header
        return row
    }

    // Probe seams.
    var probeContent: UIView { content }
    var probeTabBarEdge: NSDirectionalRectEdge? { tabBarEdge }
    /// The view that crossfades in when `tab` is selected (its navigation
    /// controller's view — NOT the screen's own view, which never fades).
    func probeTabView(_ tab: Tab) -> UIView { controller(for: tab).view }
}
