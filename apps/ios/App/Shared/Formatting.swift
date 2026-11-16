import UIKit

/// What this device is called in copy that talks about it ("this iPhone",
/// "Record on iPad"). Content labels (a project's "iPhone" badge) describe
/// the recording, not this device, and don't use it.
@MainActor
enum ThisDevice {
    static var noun: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The screen the app is showing on now — on iPhone Duo the outer or the
    /// inner display, which changes as it folds — never a stored or `main`
    /// screen. The foreground scene's, else any connected scene's.
    static var activeScreen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }
}

/// Text the screens show for times, sizes and dates.
enum Format {
    /// "2:14", "1:02:05".
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Spoken durations for VoiceOver ("2 minutes, 14 seconds").
    static func spokenDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: seconds) ?? ""
    }

    static func bytes(_ count: Int64?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "2 hours ago", "Yesterday".
    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// "12 Nov 2026 at 16:21".
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The app-wide toaster (above the tab bar; reattached to whatever root is up).
final class AppToaster {
    static let shared = AppToaster()
    private var toaster: CCToaster?
    private weak var host: UIView?

    func attach(to view: UIView) {
        guard host !== view else { return }
        host = view
        toaster = CCToaster(host: view)
        toaster?.bottomInset = bottomInset
    }

    var bottomInset: CGFloat = 24 {
        didSet { toaster?.bottomInset = bottomInset }
    }

    /// Returns the toast so a progress toast ("Opening…") can be dismissed
    /// when its result arrives instead of lingering in the stack behind it.
    @discardableResult
    func show(title: String, message: String? = nil, variant: CCToast.Variant = .default, symbol: String? = nil, action: CCToast.Action? = nil) -> CCToast? {
        toaster?.show(title: title, message: message, variant: variant, symbol: symbol, action: action)
    }

    func bringToFront() { toaster?.bringToFront() }
}

/// Share privacy, as the web dashboard names it.
enum SharePrivacy {
    case privateShare
    case unlisted
    case publicShare

    init(video: SharedVideo, extras: ShareExtras?) {
        if video.isPrivate { self = .privateShare } else if extras?.profileVisible == true { self = .publicShare } else { self = .unlisted }
    }

    var title: String {
        switch self {
        case .privateShare: return "Private"
        case .unlisted: return "Unlisted"
        case .publicShare: return "Public"
        }
    }

    var symbol: String {
        switch self {
        case .privateShare: return "eye-off"
        case .unlisted: return "link"
        case .publicShare: return "globe"
        }
    }

    var explanation: String {
        switch self {
        case .privateShare: return "Only you (signed in) can watch."
        case .unlisted: return "Anyone with the link can watch."
        case .publicShare: return "Listed on your public profile."
        }
    }
}
