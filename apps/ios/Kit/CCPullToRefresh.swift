import UIKit

/// CCKit pull-to-refresh — the house replacement for UIRefreshControl: the
/// breathing spinner appears in the gap you pull open, its arc filling as you
/// pull; release past the threshold and it spins while the content rests one
/// spinner-height down, then glides back on `endRefreshing()`.
///
///     pull = CCPullToRefresh(scrollView: collectionView) { [weak self] in self?.reload() }
///     … pull.endRefreshing()
final class CCPullToRefresh: NSObject {
    private weak var scrollView: UIScrollView?
    private let spinner = CCSpinner(diameter: 24)
    private let onRefresh: () -> Void
    private var offsetObservation: NSKeyValueObservation?
    private(set) var isRefreshing = false
    private let restHeight: CGFloat = 56
    private let threshold: CGFloat = 72

    init(scrollView: UIScrollView, onRefresh: @escaping () -> Void) {
        self.scrollView = scrollView
        self.onRefresh = onRefresh
        super.init()
        spinner.hidesWhenStopped = false
        spinner.alpha = 0
        spinner.accessibilityLabel = "Refreshing"
        scrollView.addSubview(spinner)
        scrollView.alwaysBounceVertical = true
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
    }

    private var pull: CGFloat {
        guard let scrollView else { return 0 }
        let extra = isRefreshing ? restHeight : 0
        return -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top - extra)
    }

    private func scrolled() {
        guard let scrollView else { return }
        let distance = max(0, pull)
        let side = spinner.diameter
        let centerY = isRefreshing ? -restHeight / 2 : -max(distance, 0) / 2
        spinner.frame = CGRect(x: (scrollView.bounds.width - side) / 2, y: centerY - side / 2, width: side, height: side)
        guard !isRefreshing else { return }
        let progress = min(1, distance / threshold)
        spinner.alpha = progress < 0.15 ? 0 : progress
        spinner.progress = progress * 0.78
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, !isRefreshing, pull >= threshold else { return }
        beginRefreshing()
    }

    /// Start programmatically too (e.g. a forced refresh with visible feedback).
    func beginRefreshing() {
        guard let scrollView, !isRefreshing else { return }
        isRefreshing = true
        CCHaptics.light()
        spinner.alpha = 1
        spinner.startAnimating()
        let offset = scrollView.contentOffset
        scrollView.contentInset.top += restHeight
        scrollView.setContentOffset(offset, animated: false)
        UIAccessibility.post(notification: .announcement, argument: "Refreshing")
        onRefresh()
    }

    func endRefreshing() {
        guard let scrollView, isRefreshing else { return }
        isRefreshing = false
        CCMotion.fadeAlpha(spinner, to: 0, duration: 0.18)
        CCMotion.run(duration: 0.4, curve: .settle, {
            scrollView.contentInset.top -= self.restHeight
        }, completion: { [weak self] in
            self?.spinner.stopAnimating()
        })
    }
}
