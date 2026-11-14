import ReplayKit
import UIKit

/// Opens the system "Start Broadcast" sheet for CaptureCat's broadcast
/// extension, in a chosen mode. iOS only starts screen capture after the
/// user taps Start Broadcast in that sheet — there is no silent start — so
/// this is the shortest honest path: one tap in our UI (or on the Mac's push),
/// one tap in the system sheet.
///
/// The picker is a real RPSystemBroadcastPickerView placed (nearly invisible)
/// in the key window and activated through its own button, so it works from
/// any screen, including straight after a push brings the app forward.
@MainActor
enum BroadcastLauncher {
    enum Mode: String {
        /// Stream to a Mac on the same account (fail clearly if none answers).
        case stream
        /// Record on this iPhone; uploads as a cloud project afterwards.
        case record
    }

    static let extensionBundleID = "so.capturecat.ios.broadcast"

    static func launch(_ mode: Mode, preferredMacID: String? = nil, in window: UIWindow?) {
        AppGroup.defaults.set(mode.rawValue, forKey: AppGroup.Keys.broadcastMode)
        if let preferredMacID { MacPresence.shared.prefer(macID: preferredMacID) }
        guard let window = window ?? keyWindow else { return }

        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = extensionBundleID
        // Narration: the Mac records its own mic while streaming; a phone-only
        // take offers the mic toggle in the system sheet.
        picker.showsMicrophoneButton = mode == .record
        picker.alpha = 0.011
        picker.isUserInteractionEnabled = false
        window.addSubview(picker)
        if let button = picker.subviews.compactMap({ $0 as? UIButton }).first ?? picker.allSubviews.compactMap({ $0 as? UIButton }).first {
            button.sendActions(for: .touchUpInside)
        }
        // The sheet is presented by now; the picker view itself is not needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { picker.removeFromSuperview() }
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}
