import Foundation

/// What this Mac may record, by plan. Free is for personal use and stops
/// each recording at `freeRecordingSeconds`; a plan with `commercialUse`
/// (Pro, Business) records for as long as the user's own Maximum Duration
/// says. No account is needed to record — no account simply means Free.
///
/// Same rule as the web recorder (apps/web/src/editor/record/planCap.ts);
/// the number is the API's FREE_RECORDING_SECONDS (apps/api/src/lib/plans.ts).
/// It lives in the clients because a Mac with no account, or offline, is
/// capped too — the server never sees a take until it ends.
///
/// Pure: AppState applies it, `--plan-gate-test` proves it.
enum LicenceState: Equatable, Sendable {
    /// No account, a Free account, or a paid plan that could not be confirmed.
    case personal
    /// A plan with `commercialUse` — the server's display name for it.
    case pro(planName: String)

    var allowsCommercialUse: Bool {
        if case .pro = self { return true }
        return false
    }

    /// The badge every account surface shows.
    var badgeTitle: String {
        switch self {
        case .personal: return "Personal use"
        case .pro(let name): return name.isEmpty ? "Pro" : name
        }
    }
}

enum PlanGate {
    /// = FREE_RECORDING_SECONDS in apps/api/src/lib/plans.ts.
    static let freeRecordingSeconds: TimeInterval = 300

    /// How long a confirmed paid plan holds while the server can't be
    /// reached (offline, or a server error) — never on a definite "free".
    static let offlineGrace: TimeInterval = 7 * 24 * 60 * 60

    static let pricingURL = URL(string: "https://capturecat.so/pricing")!

    /// The limit a take actually runs to (nil = none). `userLimit` is the
    /// Maximum Duration setting (nil or 0 = no limit).
    static func effectiveLimit(userLimit: TimeInterval?, licence: LicenceState) -> TimeInterval? {
        let own = (userLimit ?? 0) > 0 ? userLimit : nil
        if licence.allowsCommercialUse { return own }
        return min(own ?? freeRecordingSeconds, freeRecordingSeconds)
    }

    /// Whether the Free cap — not the user's own limit — is what ends a take.
    static func cappedByPlan(userLimit: TimeInterval?, licence: LicenceState) -> Bool {
        guard !licence.allowsCommercialUse else { return false }
        let own = (userLimit ?? 0) > 0 ? userLimit! : .infinity
        return own > freeRecordingSeconds
    }

    /// Whether a Maximum Duration choice is beyond what this plan records
    /// (0 = "No Limit"). Menus show these as Pro.
    static func isProOnlyLimit(_ seconds: TimeInterval, licence: LicenceState) -> Bool {
        !licence.allowsCommercialUse && (seconds <= 0 || seconds > freeRecordingSeconds)
    }

    /// The answer when /api/me could not be read: the last confirmed paid
    /// plan, for the SAME account, within the grace — else personal.
    static func licenceWithoutServer(
        verifiedAt: Date?, verifiedPlanName: String?, sameAccount: Bool, now: Date = Date()
    ) -> LicenceState {
        guard sameAccount, let verifiedAt, now.timeIntervalSince(verifiedAt) <= offlineGrace,
              now >= verifiedAt.addingTimeInterval(-60)
        else { return .personal }
        return .pro(planName: verifiedPlanName ?? "Pro")
    }
}
