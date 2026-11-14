import Foundation
import UIKit

/// This phone, as the Mac and the API see it. The id is minted once per
/// install and shared through the App Group, so the app's presence connection
/// and the broadcast extension's stream are the SAME phone to the Mac, and the
/// API's device row (push) uses the same id.
nonisolated enum DeviceIdentity {
    static var deviceID: String {
        let defaults = AppGroup.defaults
        if let id = defaults.string(forKey: AppGroup.Keys.deviceID), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: AppGroup.Keys.deviceID)
        return id
    }

    /// "iPhone18,1" — the hardware identifier (the Simulator reports its host
    /// model through SIMULATOR_MODEL_IDENTIFIER).
    static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var isPad: Bool { model.hasPrefix("iPad") }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    @MainActor static var name: String { UIDevice.current.name }
    @MainActor static var systemVersion: String { UIDevice.current.systemVersion }
}
