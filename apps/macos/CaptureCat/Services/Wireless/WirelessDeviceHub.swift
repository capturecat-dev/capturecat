import AppKit
import CoreVideo
import Foundation
import Observation
import os

nonisolated private let hubLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "WirelessDeviceHub")

/// "iPhone over Wi-Fi" on the main actor: the phones the recording panel
/// lists, the account link that secures them, and asking a phone to start
/// streaming.
///
/// Lifecycle (the app process only — never --mcp / harness runs):
/// • Signed in → the cached link (Keychain) starts the listener at once if
///   the account has ever had an iPhone; then the API is asked for the link,
///   this Mac is registered (`PUT /api/devices/:macId`) and the account's
///   devices are listed. The listener only ever starts for an account with
///   an iPhone, so nobody who never uses the feature sees the Local Network
///   prompt.
/// • App activation → link + devices refetched (throttled).
/// • Recording panel open → devices relisted now and every 60 s.
/// • Signed out → listener stopped, link deleted from the Keychain, this Mac
///   unregistered. No calls at all while signed out.
///
/// The panel observes `entries` / `pending` / `notice` through its
/// `withObservationTracking` loop.
@MainActor
@Observable
final class WirelessDeviceHub {
    static let shared = WirelessDeviceHub()

    /// The live feature runs only in a plain app launch (same rule as plan
    /// checks): harness flags, --mcp and --export never open a listener.
    static let liveEnabled = !CommandLine.arguments.dropFirst().contains {
        $0.hasPrefix("--") && $0 != "--show-onboarding"
    }

    /// Phones connected over Wi-Fi (merged app + broadcast connections).
    private(set) var phones: [WirelessPhoneSnapshot] = []
    /// The account's registered devices (`GET /api/devices`), signed in only.
    private(set) var cloudDevices: [WirelessCloudDevice] = []
    private(set) var isSignedIn = false
    /// Port the listener is bound to (nil = not listening).
    private(set) var listenerPort: UInt16?
    /// A phone we asked to start broadcasting and are waiting for.
    private(set) var pending: PendingBroadcast?
    /// Quiet one-line message after a failed request (auto-clears).
    private(set) var notice: String?
    /// Fingerprint of the link the listener uses (harness / UI diagnostics).
    private(set) var activeKeyID: String?
    /// Harness seam: the panel's signed-in state for its Wi-Fi rows (nil =
    /// the real session). Observed, so flipping it re-renders the panel.
    var signedInOverride: Bool?

    /// Whether the panel shows Wi-Fi rows (else the "Sign in…" row).
    func showsWirelessRows(appSignedIn: Bool) -> Bool { signedInOverride ?? appSignedIn }

    struct PendingBroadcast: Equatable {
        enum Route: Equatable { case lan, push }
        let key: String
        let name: String
        let route: Route
        let startedAt: Date

        /// What the user should do on the phone.
        var prompt: String {
            switch route {
            case .lan: return String(localized: "Tap Start Broadcast on your iPhone", comment: "Recording panel prompt while waiting for an iPhone over Wi-Fi; Start Broadcast is the iOS button name")
            case .push: return String(localized: "Check your iPhone — tap the notification, then Start Broadcast", comment: "Recording panel prompt after a push was sent to the iPhone; Start Broadcast is the iOS button name")
            }
        }
    }

    /// The panel's rows: LAN phones first, then push-only phones.
    var entries: [WirelessDeviceListing.Entry] {
        let lan = phones.map {
            WirelessDeviceListing.LANPhone(deviceID: $0.deviceID, name: $0.name, hasApp: $0.hasApp, isStreaming: $0.isStreaming)
        }
        return WirelessDeviceListing.merge(lan: lan, cloud: isSignedIn ? cloudDevices : [])
    }

    func phone(_ key: String) -> WirelessPhoneSnapshot? {
        let key = WirelessIdentity.key(key)
        return phones.first { $0.key == key }
    }

    func isStreaming(_ key: String) -> Bool { phone(key)?.isStreaming ?? false }

    // MARK: - Dependencies

    @ObservationIgnored var api: WirelessAccountAPI
    /// The listener + decoder core (nil while signed out / no link).
    @ObservationIgnored private(set) var server: WirelessServer?
    @ObservationIgnored let macID: String
    @ObservationIgnored let macName: String
    /// Seconds to wait for a requested broadcast before giving up.
    @ObservationIgnored var broadcastTimeout: TimeInterval = 30
    @ObservationIgnored var noticeDuration: TimeInterval = 6
    /// Harness: keep the Keychain and Bonjour out of it.
    @ObservationIgnored var usesKeychain = true
    @ObservationIgnored var advertises = true
    @ObservationIgnored var loopbackOnly = false

    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var lastAccountRefresh: Date?
    @ObservationIgnored private var lastDevicesRefresh: Date?
    @ObservationIgnored private var panelTimer: Timer?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var pendingTimeout: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(api: WirelessAccountAPI = HTTPWirelessAccountAPI(),
         macID: String = WirelessIdentity.macID,
         macName: String = WirelessIdentity.macName) {
        self.api = api
        self.macID = macID.lowercased()
        self.macName = macName
    }

    // MARK: - App wiring

    /// Hook into the app: auth changes, activation, sign-out. Plain app
    /// launches only (`liveEnabled`).
    func attach(authService: AuthService) {
        guard Self.liveEnabled, activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccount(force: false) }
        }
        authService.onWillSignOut = { [weak self] token in
            MainActor.assumeIsolated { self?.willSignOut(token: token) }
        }
        authDidChange(userID: authService.currentUser?.uid)
    }

    /// Sign-in, sign-out or an account switch.
    func authDidChange(userID newUser: String?) {
        guard newUser != userID || (newUser != nil && !isSignedIn) else { return }
        userID = newUser
        isSignedIn = newUser != nil
        accountTask?.cancel()
        accountTask = nil
        lastAccountRefresh = nil
        lastDevicesRefresh = nil
        guard let newUser else {
            stopServer(reason: "signed out")
            cloudDevices = []
            cancelPending(message: nil)
            if usesKeychain { WirelessLinkKeychain.clear() }
            return
        }
        // Offline-first: the cached link listens right away for an account
        // that has an iPhone; the API refresh below corrects it.
        if usesKeychain, accountHadIPhone(newUser), let cached = WirelessLinkKeychain.load(userId: newUser) {
            startServer(link: cached)
        }
        refreshAccount(force: true)
    }

    /// AuthService is about to drop the session: unregister with the token
    /// it still holds (the Keychain copy is gone a moment later).
    private func willSignOut(token: String) {
        let api = self.api
        let macID = self.macID
        Task.detached(priority: .utility) { await api.unregisterMac(macID: macID, token: token) }
    }

    /// Link + registration + device list. `force` skips the 60 s throttle.
    func refreshAccount(force: Bool) {
        guard isSignedIn, let user = userID, accountTask == nil else { return }
        if !force, let last = lastAccountRefresh, Date().timeIntervalSince(last) < 60 { return }
        lastAccountRefresh = Date()
        accountTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.userID == user { self.accountTask = nil } }
            try? await self.api.registerMac(macID: self.macID, name: self.macName)
            guard self.userID == user, !Task.isCancelled else { return }
            await self.refreshDevicesNow()
            guard self.userID == user, !Task.isCancelled else { return }
            guard accountHadIPhone(user) else { return }
            do {
                let link = try await self.api.fetchLink(rotate: false)
                guard self.userID == user, !Task.isCancelled else { return }
                if self.usesKeychain { WirelessLinkKeychain.save(link, userId: user) }
                if self.activeKeyID != link.keyID { self.startServer(link: link) }
            } catch {
                hubLogger.info("link refresh skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Relist the account's devices (the panel's push-only rows).
    func refreshDevices(force: Bool = false) {
        guard isSignedIn else { return }
        if !force, let last = lastDevicesRefresh, Date().timeIntervalSince(last) < 10 { return }
        Task { await refreshDevicesNow() }
    }

    private func refreshDevicesNow() async {
        guard isSignedIn, let user = userID else { return }
        lastDevicesRefresh = Date()
        do {
            let devices = try await api.devices()
            guard userID == user else { return }
            if devices != cloudDevices { cloudDevices = devices }
            if WirelessDeviceListing.accountHasIPhone(devices), !accountHadIPhone(user) {
                setAccountHadIPhone(user)
                // First iPhone on the account: get the link and listen.
                if server == nil, accountTask == nil { refreshAccount(force: true) }
            }
        } catch {
            hubLogger.info("device list skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The recording panel opened / closed: keep the push rows fresh while
    /// it is up (60 s; the API allows 30 requests a minute).
    func panelDidOpen() {
        guard Self.liveEnabled, isSignedIn else { return }
        refreshDevices()
        if server == nil { refreshAccount(force: false) }
        panelTimer?.invalidate()
        panelTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDevices(force: true) }
        }
    }

    func panelDidClose() {
        panelTimer?.invalidate()
        panelTimer = nil
    }

    private static func hadIPhoneKey(_ user: String) -> String { "wirelessAccountHasIPhone.\(user)" }

    /// "This account has had an iPhone" — remembered per account so an
    /// offline launch still listens. The harness keeps it in memory.
    @ObservationIgnored var persistsAccountFlags = true
    @ObservationIgnored private var memoryAccountFlags: Set<String> = []

    func accountHadIPhone(_ user: String) -> Bool {
        persistsAccountFlags ? UserDefaults.standard.bool(forKey: Self.hadIPhoneKey(user)) : memoryAccountFlags.contains(user)
    }

    func setAccountHadIPhone(_ user: String) {
        if persistsAccountFlags {
            UserDefaults.standard.set(true, forKey: Self.hadIPhoneKey(user))
        } else {
            memoryAccountFlags.insert(user)
        }
    }

    // MARK: - Listener

    /// (Re)start the listener with `link`. Existing connections drop — after
    /// a rotation every phone reconnects with the new key.
    func startServer(link: WirelessLink) {
        stopServer(reason: "relinking")
        let server = WirelessServer(link: link, macID: macID, macName: macName)
        server.onPhonesChanged = { [weak self] snapshot in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(snapshot) } }
        }
        server.onListenerState = { [weak self] port in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerPort = port } }
        }
        server.onOpenProject = { projectID, phoneName in
            DispatchQueue.main.async {
                hubLogger.info("continue on Mac: \(projectID, privacy: .public) from \(phoneName, privacy: .public)")
                NotificationCenter.default.post(name: .ccContinueProjectOnMac, object: nil, userInfo: ["id": projectID])
            }
        }
        do {
            try server.start(advertise: advertises, loopbackOnly: loopbackOnly)
            self.server = server
            activeKeyID = link.keyID
            hubLogger.info("wireless listener started (key \(link.keyID, privacy: .public))")
        } catch {
            hubLogger.error("wireless listener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopServer(reason: String) {
        server?.stop(reason: reason)
        server = nil
        activeKeyID = nil
        listenerPort = nil
        if !phones.isEmpty { phones = [] }
    }

    /// Wait for the listener's port (harness).
    func waitForPort(timeout: TimeInterval = 3) async -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while listenerPort == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return listenerPort
    }

    private func apply(_ snapshot: [WirelessPhoneSnapshot]) {
        if snapshot != phones { phones = snapshot }
        if let pending, isStreaming(pending.key) { resolvePending(true) }
    }

    // MARK: - Forget my devices

    /// Rotate the account key: every phone and every other Mac holding the
    /// old one is unlinked until it refetches. Re-advertises with the new
    /// fingerprint and drops current connections.
    func forgetDevices() async throws {
        guard isSignedIn, let user = userID else { throw WirelessAPIError.notSignedIn }
        let link = try await api.fetchLink(rotate: true)
        guard userID == user else { return }
        if usesKeychain { WirelessLinkKeychain.save(link, userId: user) }
        startServer(link: link)
    }

    // MARK: - Asking a phone to stream

    /// Ask the phone `key` to start broadcasting and wait until it streams
    /// (a decoded keyframe) or `broadcastTimeout` passes. LAN control when
    /// its app is connected here, a push notification otherwise.
    /// true = streaming now. A new request supersedes the previous one.
    func requestBroadcast(_ key: String) async -> Bool {
        let key = WirelessIdentity.key(key)
        if isStreaming(key) { return true }
        cancelPending(message: nil)
        let entry = entries.first { $0.key == key }
        let name = entry?.name ?? phone(key)?.name ?? "iPhone"
        if let server, phone(key)?.hasApp == true, server.requestBroadcast(from: key) {
            beginPending(PendingBroadcast(key: key, name: name, route: .lan, startedAt: Date()))
        } else if isSignedIn, cloudDevices.contains(where: { $0.deviceID == key && $0.canPush }) {
            let outcome = await api.requestBroadcast(deviceID: key, macID: macID, macName: macName)
            guard case .sent = outcome else {
                hubLogger.info("request-broadcast: \(String(describing: outcome), privacy: .public)")
                showNotice(String(localized: "Open CaptureCat on your iPhone to stream", comment: "Recording panel notice: the iPhone app must be open to stream over Wi-Fi"))
                return false
            }
            if isStreaming(key) { return true }
            beginPending(PendingBroadcast(key: key, name: name, route: .push, startedAt: Date()))
        } else {
            showNotice(String(localized: "Open CaptureCat on your iPhone to stream", comment: "Recording panel notice: the iPhone app must be open to stream over Wi-Fi"))
            return false
        }
        return await withCheckedContinuation { continuation in
            if pending == nil {
                continuation.resume(returning: isStreaming(key))
            } else {
                pendingWaiters.append(continuation)
            }
        }
    }

    /// Stop waiting (user picked something else, closed the panel…).
    func cancelPending(message: String?) {
        guard pending != nil else { return }
        if let message { showNotice(message) }
        resolvePending(false)
    }

    private func beginPending(_ request: PendingBroadcast) {
        pending = request
        pendingTimeout?.cancel()
        let timeout = broadcastTimeout
        pendingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.pending == request else { return }
            self.showNotice(String(localized: "Open CaptureCat on your iPhone to stream", comment: "Recording panel notice: the iPhone app must be open to stream over Wi-Fi"))
            self.resolvePending(false)
        }
    }

    private func resolvePending(_ streaming: Bool) {
        pendingTimeout?.cancel()
        pendingTimeout = nil
        pending = nil
        let waiters = pendingWaiters
        pendingWaiters = []
        for waiter in waiters { waiter.resume(returning: streaming) }
    }

    func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        let duration = noticeDuration
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func clearNotice() {
        noticeTask?.cancel()
        notice = nil
    }
}

extension Notification.Name {
    /// An iPhone on this account asked to continue a cloud project here
    /// ("Continue on Mac" over the Wi-Fi link). userInfo["id"] = project UUID.
    /// The app delegate routes it through capturecat://open-project.
    static let ccContinueProjectOnMac = Notification.Name("so.capturecat.continueProjectOnMac")
}
