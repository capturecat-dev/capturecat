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

    /// Start (or keep) presence. Asks for Local Network access the first time
    /// — so call it when the user is looking at streaming, not at launch.
    func start() async {
        guard SessionStore.load() != nil else { status = .signedOut; return }
        guard client == nil else { return }
        guard let link = await WirelessLinkStore.current() else {
            status = .unavailable("Couldn't reach CaptureCat to link this iPhone. Check your connection.")
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
        let screen = UIScreen.main.nativeBounds.size
        let hello = WirelessHello(
            role: WirelessDevice.roleApp,
            deviceID: DeviceIdentity.deviceID,
            deviceName: DeviceIdentity.name,
            model: DeviceIdentity.model,
            systemVersion: DeviceIdentity.systemVersion,
            appVersion: DeviceIdentity.appVersion,
            screenWidth: Int(min(screen.width, screen.height)),
            screenHeight: Int(max(screen.width, screen.height)),
            screenScale: Double(UIScreen.main.nativeScale)
        )
        return { hello }
    }
}
