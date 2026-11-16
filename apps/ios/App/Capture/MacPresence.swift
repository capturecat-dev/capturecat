import Network
import Observation
import UIKit

/// While the app is in the foreground it keeps a presence-only connection
/// (role "app") to a Mac on the same account and Wi-Fi, so the Mac lists this
/// phone as soon as CaptureCat is open — and can ask it to start streaming
/// (control "requestBroadcast"), which routes to the same place a push does.
/// Stopped in the background: iOS would suspend it anyway, and an idle phone
/// is reachable through push instead.
@MainActor
@Observable
final class MacPresence {
    static let shared = MacPresence()

    enum Status: Equatable {
        case signedOut
        case unavailable(String)
        case searching
        case connected(macName: String)
    }

    private(set) var status: Status = .signedOut
    private(set) var nearbyMacs: [WirelessMacClient.Mac] = []
    private(set) var connectedMacID: String?

    private var client: WirelessMacClient?
    private var refreshedLink = false
    /// Waiting "Continue on Mac" requests by project id (nil = timed out).
    private var pendingOpens: [String: CheckedContinuation<Bool?, Never>] = [:]

    enum HandoffResult: Equatable {
        case opened(macName: String)
        /// The Mac answered but refused (not a project id it can open).
        case refused
        /// No Mac on this account answered on the local network.
        case noMac
        case signedOut
    }

    /// "Continue on Mac": ask the connected Mac to open this cloud project in
    /// its editor (it clones if needed and comes to the front). Starts the
    /// presence link if it isn't up — the user just asked for the Mac.
    func openOnMac(projectID: String, name: String) async -> HandoffResult {
        guard SessionStore.load() != nil else { return .signedOut }
        if client == nil { await start() }
        let deadline = Date().addingTimeInterval(4)
        while connectedMacID == nil, client != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let client, connectedMacID != nil, case let .connected(macName) = status else { return .noMac }
        let id = projectID.uppercased()
        client.send(.openProject, WirelessJSON.encode(WirelessOpenProject(projectId: id, name: name)))
        let answer: Bool? = await withCheckedContinuation { continuation in
            pendingOpens.removeValue(forKey: id)?.resume(returning: nil)
            pendingOpens[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                MacPresence.shared.pendingOpens.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
        switch answer {
        case true?: return .opened(macName: macName)
        case false?: return .refused
        case nil: return .noMac
        }
    }

    private func resolveOpen(projectID: String, ok: Bool) {
        pendingOpens.removeValue(forKey: projectID.uppercased())?.resume(returning: ok)
    }

    /// Start (or keep) presence. Asks for Local Network access the first time
    /// — so call it when the user is looking at streaming, not at launch.
    func start() async {
        guard SessionStore.load() != nil else { status = .signedOut; return }
        guard client == nil else { return }
        guard let link = await WirelessLinkStore.current() else {
            status = .unavailable("Couldn't reach CaptureCat to link this \(ThisDevice.noun). Check your connection.")
            return
        }
        begin(with: link)
    }

    func stop() {
        client?.stop(reason: "background")
        client = nil
        nearbyMacs = []
        connectedMacID = nil
        if case .connected = status { status = .searching }
    }

    /// Tell the stream which Mac to use (the one that asked, or the user's pick).
    func prefer(macID: String?) {
        AppGroup.defaults.set(macID, forKey: AppGroup.Keys.preferredMacID)
        client?.prefer(macID: macID)
    }

    private func begin(with link: WirelessLink) {
        let client = WirelessMacClient(role: WirelessDevice.roleApp, hello: Self.hello())
        client.onMacsChanged = { macs in
            Task { @MainActor in MacPresence.shared.nearbyMacs = macs }
        }
        client.onStateChange = { state in
            Task { @MainActor in MacPresence.shared.apply(state) }
        }
        client.onControl = { control in
            if control.command == "openedProject", let id = control.projectId {
                let ok = control.ok ?? false
                Task { @MainActor in MacPresence.shared.resolveOpen(projectID: id, ok: ok) }
                return
            }
            guard control.command == WirelessControl.requestBroadcast.command else { return }
            Task { @MainActor in
                let presence = MacPresence.shared
                let mac = presence.nearbyMacs.first(where: { $0.id == presence.connectedMacID })
                PushRouter.shared.deliver(macID: presence.connectedMacID, macName: mac?.name)
            }
        }
        client.onLinkRejected = {
            Task { @MainActor in await MacPresence.shared.relink() }
        }
        self.client = client
        status = .searching
        client.start(link: link, preferredMacID: AppGroup.defaults.string(forKey: AppGroup.Keys.preferredMacID))
    }

    private func apply(_ state: WirelessMacClient.State) {
        switch state {
        case .idle, .searching, .connecting:
            connectedMacID = nil
            status = .searching
        case let .connected(mac, hello):
            connectedMacID = mac.id
            status = .connected(macName: hello.macName.isEmpty ? mac.name : hello.macName)
        }
    }

    /// The Mac refused our key — it was rotated ("Forget my devices"). Refetch once.
    private func relink() async {
        guard !refreshedLink else { return }
        refreshedLink = true
        stop()
        guard let link = try? await WirelessLinkStore.refresh() else { return }
        begin(with: link)
    }

    static func hello() -> @Sendable () -> WirelessHello {
        // The display the app is on when the link starts (iPhone Duo: outer or
        // inner). A broadcast reports its real frame size in its own video
        // format messages, so a later fold doesn't need this to change.
        let display = ThisDevice.activeScreen
        let screen = display?.nativeBounds.size ?? .zero
        let hello = WirelessHello(
            role: WirelessDevice.roleApp,
            deviceID: DeviceIdentity.deviceID,
            deviceName: DeviceIdentity.name,
            model: DeviceIdentity.model,
            systemVersion: DeviceIdentity.systemVersion,
            appVersion: DeviceIdentity.appVersion,
            screenWidth: Int(min(screen.width, screen.height)),
            screenHeight: Int(max(screen.width, screen.height)),
            screenScale: Double(display?.nativeScale ?? 0)
        )
        return { hello }
    }
}
