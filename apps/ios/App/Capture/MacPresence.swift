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
        /// iOS refuses local network access to the app.
        case localNetworkOff
        /// Only Macs of another account are nearby (the link was refetched
        /// and still doesn't match). Still searching.
        case otherAccount(macName: String)
        case connecting(macName: String)
        case connected(macName: String)
    }

    private(set) var status: Status = .signedOut
    private(set) var nearbyMacs: [WirelessMacClient.Mac] = []
    private(set) var connectedMacID: String?

    private var client: WirelessMacClient?
    private var refreshedLink = false
    /// What the client last reported; `status` is derived from them.
    private var clientState: WirelessMacClient.State = .idle
    private var denied = false
    private var otherMacs: [String] = []
    private var otherMacsConfirmed = false
    private var denialWork: Task<Void, Never>?
    private var relinkWork: Task<Void, Never>?
    private var lastRelink: Date?
    private var activeKeyID: String?
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
            status = .unavailable(String(localized: "Couldn't reach CaptureCat to link this \(ThisDevice.noun). Check your connection.", comment: "Argument is iPhone or iPad"))
            return
        }
        begin(with: link)
    }

    func stop() {
        guard client != nil else { return }
        client?.stop(reason: "background")
        client = nil
        denialWork?.cancel()
        relinkWork?.cancel()
        relinkWork = nil
        nearbyMacs = []
        connectedMacID = nil
        clientState = .idle
        denied = false
        otherMacs = []
        otherMacsConfirmed = false
        status = .searching
    }

    /// Tell the stream which Mac to use (the one that asked, or the user's pick).
    func prefer(macID: String?) {
        AppGroup.defaults.set(macID, forKey: AppGroup.Keys.preferredMacID)
        client?.prefer(macID: macID)
    }

    private func begin(with link: WirelessLink) {
        let client = WirelessMacClient(role: WirelessDevice.roleApp, hello: Self.hello())
        // A stopped client's last callbacks must not speak for the new one.
        let token = ObjectIdentifier(client)
        let current: @Sendable (@escaping @MainActor @Sendable (MacPresence) -> Void) -> Void = { body in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let presence = MacPresence.shared
                    guard presence.client.map(ObjectIdentifier.init) == token else { return }
                    body(presence)
                }
            }
        }
        client.onMacsChanged = { macs in
            current { $0.nearbyMacs = macs; $0.refreshStatus() }
        }
        client.onStateChange = { state in
            current { $0.apply(state) }
        }
        client.onOtherMacsChanged = { names in
            current { $0.applyOtherMacs(names) }
        }
        client.onLocalNetworkDenied = { denied in
            current { $0.applyDenied(denied) }
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
            current { presence in Task { await presence.relink() } }
        }
        self.client = client
        activeKeyID = link.keyID
        refreshStatus()
        client.start(link: link, preferredMacID: AppGroup.defaults.string(forKey: AppGroup.Keys.preferredMacID))
    }

    private func apply(_ state: WirelessMacClient.State) {
        clientState = state
        if case let .connected(mac, _) = state {
            connectedMacID = mac.id
            refreshedLink = false
        } else {
            connectedMacID = nil
        }
        refreshStatus()
    }

    private func refreshStatus() {
        let new: Status
        switch clientState {
        case let .connected(mac, hello):
            new = .connected(macName: hello.macName.isEmpty ? mac.name : hello.macName)
        case let .connecting(mac):
            new = .connecting(macName: mac.name)
        case .idle, .searching:
            if denied {
                new = .localNetworkOff
            } else if let mac = nearbyMacs.first {
                // Found, between attempts: don't flicker back to searching.
                new = .connecting(macName: nearbyMacs.first { $0.id == AppGroup.defaults.string(forKey: AppGroup.Keys.preferredMacID) }?.name ?? mac.name)
            } else if otherMacsConfirmed, let other = otherMacs.first {
                new = .otherAccount(macName: other)
            } else {
                new = .searching
            }
        }
        if new != status { status = new }
    }

    /// iOS also refuses while its own prompt is up: wait for it to last.
    private func applyDenied(_ new: Bool) {
        denialWork?.cancel()
        guard new else {
            denied = false
            refreshStatus()
            return
        }
        denialWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.denied = true
            self.refreshStatus()
        }
    }

    /// Macs that don't match our key: the cached key may be out of date
    /// (rotated elsewhere), so refetch it before saying "another account".
    private func applyOtherMacs(_ names: [String]) {
        otherMacs = names
        if names.isEmpty { otherMacsConfirmed = false }
        refreshStatus()
        guard !names.isEmpty, nearbyMacs.isEmpty, !otherMacsConfirmed, relinkWork == nil else { return }
        if let lastRelink, Date().timeIntervalSince(lastRelink) < 30 { return }
        lastRelink = Date()
        relinkWork = Task { @MainActor [weak self] in
            // Our own Mac may still be about to answer.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            let before = WirelessLinkStore.cached()
            let fresh = try? await WirelessLinkStore.refresh()
            guard !Task.isCancelled else { return }
            self.relinkWork = nil
            guard let fresh, let client = self.client else { return }
            self.otherMacsConfirmed = true
            if fresh != before || fresh.keyID != self.activeKeyID {
                self.activeKeyID = fresh.keyID
                client.start(link: fresh, preferredMacID: AppGroup.defaults.string(forKey: AppGroup.Keys.preferredMacID))
            }
            self.refreshStatus()
        }
    }

    /// The Mac refused our key — it was rotated ("Forget my devices"). Refetch once.
    private func relink() async {
        guard !refreshedLink else { return }
        refreshedLink = true
        guard let link = try? await WirelessLinkStore.refresh(), client != nil else { return }
        activeKeyID = link.keyID
        client?.start(link: link, preferredMacID: AppGroup.defaults.string(forKey: AppGroup.Keys.preferredMacID))
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
