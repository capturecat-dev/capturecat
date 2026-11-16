import UIKit

/// The iPhone Duo's fold as UIKit reports it to a view (iOS 27.1+).
///
/// Unfolded, the inner display has a crease: a `.division` reserved region,
/// "where an element should divide into two separate regions". Folded, the
/// outer display has none, and the system puts vertical bars on the edge
/// `verticalBarEdge` names (trailing on the Duo's outer display, in the
/// strip beside the sensor). Both are read here so layouts share one rule.
enum FoldingDisplay {
    /// A crease that splits the view into two usable panes.
    enum Crease: Equatable {
        /// Runs top to bottom (the book posture): panes left and right.
        case vertical(CGRect)
        /// Runs side to side: panes above and below.
        case horizontal(CGRect)

        var rect: CGRect {
            switch self {
            case .vertical(let r), .horizontal(let r): return r
            }
        }
    }

    #if DEBUG
    /// Gate seam: a crease in the view's coordinates instead of UIKit's
    /// (the simulator can only fold from its window's hardware menu).
    @MainActor static var creaseOverride: ((UIView) -> CGRect?)?
    #endif

    /// The crease across `view` (see `systemCrease`), if it leaves two panes of at least
    /// `minPane` points on each side; nil otherwise (folded, no fold
    /// hardware, or a crease that would leave a sliver).
    @MainActor
    static func crease(in view: UIView, minPane: CGFloat = 280) -> Crease? {
        var rect: CGRect?
        #if DEBUG
        if let creaseOverride { rect = creaseOverride(view) } else { rect = systemCrease(in: view) }
        #else
        rect = systemCrease(in: view)
        #endif
        guard let r = rect else { return nil }
        return classify(r, in: view.bounds, minPane: minPane)
    }

    /// Pure: which way `rect` divides `bounds`, if both panes are usable.
    static func classify(_ rect: CGRect, in bounds: CGRect, minPane: CGFloat = 280) -> Crease? {
        let r = rect.intersection(bounds)
        guard !r.isNull, r.width >= 0, r.height >= 0 else { return nil }
        if r.height >= bounds.height * 0.5, r.width < bounds.width * 0.25 {
            guard r.minX - bounds.minX >= minPane, bounds.maxX - r.maxX >= minPane else { return nil }
            return .vertical(r)
        }
        if r.width >= bounds.width * 0.5, r.height < bounds.height * 0.25 {
            guard r.minY - bounds.minY >= minPane, bounds.maxY - r.maxY >= minPane else { return nil }
            return .horizontal(r)
        }
        return nil
    }

    /// The fold, active or not. UIKit makes a division active only while
    /// the device is partly open (content across it is then hard to use);
    /// flat, it is inactive — but Apple's guidance is that an inactive
    /// division still drives high-level layout decisions, so panes that
    /// meet at the fold stay put as the hinge moves.
    @MainActor
    private static func systemCrease(in view: UIView) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        let regions = view.reservedRegions(kind: .division, options: .includeInactive)
        return (regions.first { $0.isActive } ?? regions.first)?.frame
    }

    #if DEBUG
    /// Gate seam: the vertical-bar edge instead of the trait's.
    @MainActor static var verticalBarEdgeOverride: NSDirectionalRectEdge?
    #endif

    /// The edge the system puts vertical bars on (`.leading` / `.trailing`),
    /// or nil for the usual bottom bar.
    @MainActor
    static func verticalBarEdge(_ traits: UITraitCollection) -> NSDirectionalRectEdge? {
        #if DEBUG
        if let verticalBarEdgeOverride { return verticalBarEdgeOverride }
        #endif
        guard #available(iOS 27.1, *) else { return nil }
        switch traits.verticalBarEdge {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return nil
        }
    }

    /// The traits whose change can move the vertical bar.
    @MainActor
    static var traitsAffectingVerticalBarEdge: [UITrait] {
        guard #available(iOS 27.1, *) else { return [] }
        return UITraitCollection.systemTraitsAffectingVerticalBarEdge
    }
}
