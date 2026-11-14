import Foundation
import Network

/// The iPhone side of "iPhone over Wi-Fi" (contract: WirelessDeviceProtocol.swift,
/// compiled from the Mac tree). Finds the account's Macs on the local network
/// (Bonjour `_ccwireless._tcp`, matched by the link-key fingerprint in TXT —
/// Macs of other accounts are never contacted), opens the TLS-PSK link to one,
/// says hello in its role, and keeps it up: reconnects after drops, and
/// reports a handshake rejection (the account key was rotated) so the caller
/// can refetch the link once.
///
/// Used by the app (role "app": presence while open, so the Mac lists the
/// phone and can ask it to start a broadcast) and by the broadcast extension
/// (role "broadcast": the media stream). Everything runs on `queue`.
nonisolated final class WirelessMacClient: @unchecked Sendable {
    struct Mac: Equatable, Sendable {
        var id: String
        var name: String
        var endpoint: NWEndpoint
    }

    enum State: Equatable, Sendable {
        case idle
        case searching
        case connecting(Mac)
        case connected(Mac, WirelessMacHello)
    }

    let role: String
    let queue: DispatchQueue

    /// Called on `queue`.
    var onStateChange: (@Sendable (State) -> Void)?
    var onMacsChanged: (@Sendable ([Mac]) -> Void)?
    var onControl: (@Sendable (WirelessControl) -> Void)?
    /// The Mac refused our key (TLS handshake failed) — refresh the link.
    var onLinkRejected: (@Sendable () -> Void)?

    private let makeHello: @Sendable () -> WirelessHello
    private var link: WirelessLink?
    private var preferredMacID: String?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var macs: [Mac] = []
    private var state: State = .idle
    private var running = false
    private var retryWork: DispatchWorkItem?
    private var inFlight = 0

    init(role: String, queue: DispatchQueue = DispatchQueue(label: "so.capturecat.ios.wireless"), hello: @escaping @Sendable () -> WirelessHello) {
        self.role = role
        self.queue = queue
        self.makeHello = hello
    }

    // MARK: Lifecycle

    func start(link: WirelessLink, preferredMacID: String?) {
        queue.async {
            self.link = link
            self.preferredMacID = preferredMacID?.lowercased()
            guard !self.running else { self.reconsider(); return }
            self.running = true
            self.startBrowsing()
        }
    }

    /// Prefer this Mac from now on (e.g. the one that asked for a broadcast).
    func prefer(macID: String?) {
        queue.async {
            self.preferredMacID = macID?.lowercased()
            self.reconsider()
        }
    }

    func stop(reason: String = "stopped") {
        queue.async {
            self.running = false
            self.retryWork?.cancel()
            if let connection = self.connection {
                connection.sendWireless(.bye, WirelessJSON.encode(WirelessBye(reason: reason))) { _ in connection.cancel() }
            }
            self.connection = nil
            self.browser?.cancel()
            self.browser = nil
            self.macs = []
            self.setState(.idle)
        }
    }

    // MARK: Sending

    /// Bytes handed to the connection and not yet processed by the stack —
    /// the broadcast extension drops non-key frames above a budget.
    var bytesInFlight: Int { queue.sync { inFlight } }

    var isConnected: Bool {
        queue.sync { if case .connected = state { return true }; return false }
    }

    /// Send one message if connected (drops silently otherwise).
    func send(_ type: WirelessMessageType, _ payload: Data) {
        queue.async { [weak self] in
            guard let self, case .connected = self.state, let connection = self.connection else { return }
            self.inFlight += payload.count
            let count = payload.count
            connection.sendWireless(type, payload) { [weak self] _ in
                self?.queue.async { [weak self] in self?.inFlight -= count }
            }
        }
    }

    // MARK: Browsing

    private func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WirelessDevice.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updateMacs(from: results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.browser?.cancel()
                self.browser = nil
                self.scheduleRetry { [weak self] in self?.startBrowsing() }
            }
        }
        self.browser = browser
        setState(.searching)
        browser.start(queue: queue)
    }

    private func updateMacs(from results: Set<NWBrowser.Result>) {
        guard let link else { return }
        macs = results.compactMap { result -> Mac? in
            guard WirelessDevice.keyID(of: result) == link.keyID,
                  let id = WirelessDevice.macID(of: result) else { return nil }
            var name = "Mac"
            if case let .service(serviceName, _, _, _) = result.endpoint { name = serviceName }
            return Mac(id: id.lowercased(), name: name, endpoint: result.endpoint)
        }.sorted { $0.name < $1.name }
        onMacsChanged?(macs)
        reconsider()
    }

    /// Connect to the preferred Mac (else the first one) if not already.
    private func reconsider() {
        guard running else { return }
        let target = macs.first(where: { $0.id == preferredMacID }) ?? macs.first
        switch state {
        case let .connecting(mac), let .connected(mac, _):
            if let target, target.id != mac.id, target.id == preferredMacID {
                connection?.cancel()
                connection = nil
                connect(to: target)
            } else if !macs.contains(where: { $0.id == mac.id }) {
                // It went away from Bonjour; keep the live connection until it drops.
            }
        case .idle, .searching:
            if let target { connect(to: target) } else { setState(.searching) }
        }
    }

    // MARK: Connection

    private func connect(to mac: Mac) {
        guard let link else { return }
        let connection = NWConnection(to: mac.endpoint, using: WirelessDevice.parameters(link: link))
        self.connection = connection
        inFlight = 0
        setState(.connecting(mac))
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .ready:
                connection.sendWireless(.hello, WirelessJSON.encode(self.makeHello()))
                self.receive(on: connection, mac: mac)
            case let .waiting(error), let .failed(error):
                if case .tls = error { self.onLinkRejected?() }
                self.dropConnection()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, mac: Mac) {
        connection.receiveWireless({ [weak self] type, payload in
            guard let self, connection === self.connection else { return false }
            switch type {
            case .macHello:
                if let hello = WirelessJSON.decode(WirelessMacHello.self, from: payload) {
                    self.setState(.connected(mac, hello))
                }
            case .control:
                if let control = WirelessJSON.decode(WirelessControl.self, from: payload) {
                    self.onControl?(control)
                }
            case .bye:
                self.dropConnection()
                return false
            default:
                break
            }
            return true
        }, onEnd: { [weak self] _ in
            self?.queue.async {
                guard let self, connection === self.connection else { return }
                self.dropConnection()
            }
        })
    }

    private func dropConnection() {
        connection?.cancel()
        connection = nil
        inFlight = 0
        guard running else { return }
        setState(.searching)
        scheduleRetry { [weak self] in self?.reconsider() }
    }

    private func scheduleRetry(_ work: @escaping () -> Void) {
        retryWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            work()
        }
        retryWork = item
        queue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onStateChange?(new)
    }
}
