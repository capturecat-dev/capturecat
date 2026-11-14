import Foundation
// WirelessServer.swift (Mac) reads these from WirelessAccount.swift, which
// also pulls in the Mac's AuthService; the two members it needs, verbatim.
nonisolated enum WirelessIdentity {
    static func key(_ id: String) -> String { id.lowercased() }
    static let appVersion = "interop-test"
}
