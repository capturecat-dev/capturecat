import UIKit

/// The editor header's sync status (Phase 5): one small dot beside the back
/// key — green synced, amber waiting (unsent edits, offline, a merge to
/// review), the accent pulsing while a sync runs, red when it failed;
/// hidden for a project that is on this device only. A change of state lands
/// on the house growth bounce (the dot grows from 55%) and its colour
/// cross-fades; tapping it says the state in words (a toast).
@available(iOS 26, *)
@MainActor
final class StudioSyncBadge: UIControl {
    var onTap: (() -> Void)?
    private let dot = CALayer()
    private let ring = CALayer()
    private(set) var shown: StudioCloudSync.Status?
    static let dotSize: CGFloat = 9

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        for layer in [ring, dot] {
            layer.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            layer.cornerRadius = Self.dotSize / 2
            self.layer.addSublayer(layer)
        }
        ring.borderWidth = 1.5
        ring.backgroundColor = UIColor.clear.cgColor
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 44),
        ])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (badge: StudioSyncBadge, _) in
            if let shown = badge.shown { badge.show(shown, animated: false) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.position = center
        ring.position = center
        CATransaction.commit()
    }

    @objc private func tapped() { onTap?() }

    private func color(for status: StudioCloudSync.Status) -> UIColor {
        switch status {
        case .synced: return CCTheme.color.success
        case .pending, .offline, .review: return CCTheme.color.warning
        case .syncing: return CCTheme.color.primary
        case .failed: return CCTheme.color.destructive
        case .localOnly: return CCTheme.color.mutedForeground
        }
    }

    func show(_ status: StudioCloudSync.Status, animated: Bool) {
        let changed = shown != status
        shown = status
        isHidden = status == .localOnly
        accessibilityLabel = "Sync status"
        accessibilityValue = status.words
        let fill = color(for: status).resolvedColor(with: traitCollection).cgColor
        // Offline: a hollow ring (nothing is moving); otherwise a filled dot.
        let hollow = status == .offline
        if animated && changed && window != nil {
            CCMotion.fade(dot, keyPath: "backgroundColor", to: hollow ? UIColor.clear.cgColor : fill, duration: 0.2)
            CCMotion.spring(dot, keyPath: "transform.scale", from: 0.55, to: 1.0, .bouncy)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.backgroundColor = hollow ? UIColor.clear.cgColor : fill
            CATransaction.commit()
        }
        ring.borderColor = fill
        ring.opacity = hollow ? 1 : 0
        if status == .syncing {
            guard dot.animation(forKey: "studio.sync.pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = CCMotion.paced(0.6)
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "studio.sync.pulse")
        } else {
            dot.removeAnimation(forKey: "studio.sync.pulse")
        }
    }

    // MARK: - Probe seams

    var probeDot: CALayer { dot }
    var probeRing: CALayer { ring }
}
