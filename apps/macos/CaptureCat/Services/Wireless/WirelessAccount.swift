import Foundation
import Security
import os

nonisolated private let accountLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "WirelessAccount")

// "iPhone over Wi-Fi" — the account side, Mac only.
//
// Linking is by ACCOUNT (Shared/WirelessDeviceProtocol.swift): the API hands
// every native app of an account the same 256-bit link key. This file holds
// the Mac's identity, the Keychain cache of that key, the API client
// (/api/wireless/link, /api/devices), and the pure listing merge the
// recording panel shows — LAN phones first, then push-only phones from the
// API, one row per phone however many ways it is reachable.

// MARK: - Identity

nonisolated enum WirelessIdentity {
    static let macIDDefaultsKey = "wirelessMacID"

    /// This Mac's stable id: a UUID minted on first use, lowercase (the API
    /// stores device ids lowercase and the Bonjour TXT advertises it so).
    static var macID: String {
        // Harness runs (any `--flag`) share the app's defaults domain: never
        // mint the user's Mac id from one — an ephemeral id will do.
        guard WirelessIdentityPolicy.persists else { return ephemeralMacID }
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: macIDDefaultsKey), UUID(uuidString: existing) != nil {
            return existing.lowercased()
        }
        let minted = UUID().uuidString.lowercased()
        defaults.set(minted, forKey: macIDDefaultsKey)
        return minted
    }

    private static let ephemeralMacID = UUID().uuidString.lowercased()

    /// The Mac's user-facing name ("Mike's MacBook Pro").
    static var macName: String {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Mac" : name
    }

    /// Hardware model, e.g. "Mac16,10" (nil when unreadable).
    static var model: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// Ids compare case-insensitively everywhere: the API returns them
    /// lowercase, an iPhone's hello carries `UUID().uuidString` (uppercase).
    static func key(_ id: String) -> String { id.lowercased() }
}

nonisolated enum WirelessIdentityPolicy {
    /// Only a plain app launch persists the Mac id (same rule as
    /// `WirelessDeviceHub.liveEnabled`).
    static let persists = !CommandLine.arguments.dropFirst().contains {
        $0.hasPrefix("--") && $0 != "--show-onboarding"
    }
}

// MARK: - Keychain cache of the account link

/// The link key cached on this Mac so the feature works offline. Same item
/// discipline as AuthKeychain (data-protection keychain first, file keychain
/// for ad-hoc builds; this device only, never synced). The account uid rides
/// along: a different signed-in account never reuses another's key.
nonisolated enum WirelessLinkKeychain {
    static let service = "co.capturecat.wireless-link"
    static let account = "link"

    struct Stored: Codable, Equatable {
        var key: String
        var keyId: String
        var userId: String

        enum CodingKeys: String, CodingKey { case key, keyId, userId }

        init(key: String, keyId: String, userId: String) {
            self.key = key
            self.keyId = keyId
            self.userId = userId
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            keyId = try c.decodeIfPresent(String.self, forKey: .keyId) ?? ""
            userId = try c.decodeIfPresent(String.self, forKey: .userId) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(keyId, forKey: .keyId)
            try c.encode(userId, forKey: .userId)
        }
    }

    /// The cached link for `userId` (nil = none, another account's, or corrupt).
    static func load(userId: String) -> WirelessLink? {
        guard let data = read(), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.userId == userId, let link = WirelessLink(base64URLKey: stored.key),
              link.keyID == stored.keyId else { return nil }
        return link
    }

    static func save(_ link: WirelessLink, userId: String) {
        let stored = Stored(key: WirelessLink.base64URL(link.key), keyId: link.keyID, userId: userId)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        for useDataProtection in [true, false] {
            let status = write(data, useDataProtection: useDataProtection)
            if status == errSecSuccess { return }
            guard status == errSecMissingEntitlement || status == errSecParam || status == errSecNotAvailable else {
                accountLogger.error("link keychain save failed: \(status, privacy: .public)")
                return
            }
        }
    }

    static func clear() {
        for useDataProtection in [true, false] {
            SecItemDelete(query(useDataProtection: useDataProtection) as CFDictionary)
        }
    }

    private static func query(useDataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    private static func read() -> Data? {
        for useDataProtection in [true, false] {
            var q = query(useDataProtection: useDataProtection)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
                return data
            }
        }
        return nil
    }

    private static func write(_ data: Data, useDataProtection: Bool) -> OSStatus {
        let q = query(useDataProtection: useDataProtection)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return update }
        if update == errSecMissingEntitlement || update == errSecParam || update == errSecNotAvailable { return update }
        SecItemDelete(q as CFDictionary)
        var insert = q
        insert[kSecValueData as String] = data
        insert[kSecAttrLabel as String] = "CaptureCat device link"
        if useDataProtection {
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(insert as CFDictionary, nil)
    }
}

// MARK: - API shapes (pure parsing)

/// One row of `GET /api/devices` (`publicDevice` in apps/api/src/routes/devices.ts).
nonisolated struct WirelessCloudDevice: Equatable, Sendable {
    /// Lowercase, as the API stores it.
    let deviceID: String
    let platform: String
    let name: String
    let model: String?
    let systemVersion: String?
    let appVersion: String?
    /// The server can wake this phone with a notification.
    let canPush: Bool
    let lastSeenAt: String?
}

/// What `POST /api/devices/:id/request-broadcast` said.
nonisolated enum WirelessPushOutcome: Equatable, Sendable {
    case sent
    /// 409 push_unavailable / 503 push_not_configured / 404 not_found / 400 —
    /// the phone can't be woken; ask the user to open the app instead.
    case unavailable(code: String)
    /// 502 push_failed, a transport error, or an unexpected status — retryable.
    case failed(String)
}

nonisolated enum WirelessAPIError: LocalizedError, Equatable {
    case notSignedIn
    case unavailable          // 503 wireless_unavailable
    case keyMismatch          // decoded key's fingerprint ≠ the API's keyId
    case invalidResponse
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return String(localized: "Sign in to use your iPhone over Wi-Fi.", comment: "iPhone over Wi-Fi error: needs a signed-in account")
        case .unavailable: return String(localized: "iPhone over Wi-Fi isn't available on this server.", comment: "iPhone over Wi-Fi error: the feature is turned off on the server")
        case .keyMismatch: return String(localized: "The device link key didn't verify.", comment: "iPhone over Wi-Fi error: the pairing key check failed")
        case .invalidResponse: return String(localized: "Unexpected response from the server.", comment: "iPhone over Wi-Fi error: unreadable server reply")
        case .http(let status, let code): return "HTTP \(status)\(code.map { " (\($0))" } ?? "")"
        }
    }
}

nonisolated enum WirelessAPIParse {
    /// `{ key, keyId, createdAt }` → the link, only if the key decodes to 32
    /// bytes AND its fingerprint equals the server's `keyId`.
    static func link(_ data: Data) throws -> WirelessLink {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let encoded = object["key"] as? String, let keyId = object["keyId"] as? String,
              let link = WirelessLink(base64URLKey: encoded) else { throw WirelessAPIError.invalidResponse }
        guard link.keyID == keyId.lowercased() else { throw WirelessAPIError.keyMismatch }
        return link
    }

    static func devices(_ data: Data) -> [WirelessCloudDevice]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["devices"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row["deviceId"] as? String, !id.isEmpty,
                  let platform = row["platform"] as? String else { return nil }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return WirelessCloudDevice(
                deviceID: WirelessIdentity.key(id),
                platform: platform,
                name: (name?.isEmpty == false ? name! : "iPhone"),
                model: row["model"] as? String,
                systemVersion: row["systemVersion"] as? String,
                appVersion: row["appVersion"] as? String,
                canPush: (row["canPush"] as? Bool) ?? false,
                lastSeenAt: row["lastSeenAt"] as? String
            )
        }
    }

    static func pushOutcome(status: Int, data: Data) -> WirelessPushOutcome {
        let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["code"] as? String
        switch status {
        case 200:
            let sent = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["sent"] as? Bool
            return sent == true ? .sent : .failed("unexpected body")
        case 400, 404, 409, 503:
            return .unavailable(code: code ?? "http_\(status)")
        default:
            return .failed(code ?? "http_\(status)")
        }
    }

    /// PUT /api/devices/:macId body. Never an apnsToken — the API refuses
    /// one from a Mac (400).
    static func registrationBody(name: String, model: String?, systemVersion: String?, appVersion: String?) -> [String: Any] {
        var body: [String: Any] = ["platform": "mac", "name": name]
        if let model { body["model"] = model }
        if let systemVersion { body["systemVersion"] = systemVersion }
        if let appVersion { body["appVersion"] = appVersion }
        return body
    }

    /// POST …/request-broadcast body (`macId` lowercase).
    static func requestBroadcastBody(macID: String, macName: String) -> [String: Any] {
        ["macId": macID.lowercased(), "macName": macName]
    }
}

// MARK: - API client

/// What the wireless feature needs from the API. `HTTPWirelessAccountAPI`
/// talks to the Worker with the Mac's Bearer session; the gate swaps in a stub.
protocol WirelessAccountAPI: AnyObject, Sendable {
    func fetchLink(rotate: Bool) async throws -> WirelessLink
    func registerMac(macID: String, name: String) async throws
    func unregisterMac(macID: String, token: String) async
    func devices() async throws -> [WirelessCloudDevice]
    func requestBroadcast(deviceID: String, macID: String, macName: String) async -> WirelessPushOutcome
}

nonisolated final class HTTPWirelessAccountAPI: WirelessAccountAPI, @unchecked Sendable {
    private let baseURL: String
    private let token: @Sendable () -> String?

    init(baseURL: String = CaptureCatAPI.baseURL, token: @escaping @Sendable () -> String? = { AuthKeychain.currentToken() }) {
        self.baseURL = baseURL
        self.token = token
    }

    private func request(_ method: String, _ path: String, token explicit: String? = nil, body: [String: Any]? = nil) throws -> URLRequest {
        guard let bearer = explicit ?? token() else { throw WirelessAPIError.notSignedIn }
        guard let url = URL(string: "\(baseURL)/api\(path)") else { throw WirelessAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("capturecat-v1-9f3a7c2e", forHTTPHeaderField: "X-App-Token")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WirelessAPIError.invalidResponse }
        return (data, http.statusCode)
    }

    private static func code(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["code"] as? String
    }

    func fetchLink(rotate: Bool) async throws -> WirelessLink {
        let req = try request(rotate ? "POST" : "GET", rotate ? "/wireless/link/rotate" : "/wireless/link")
        let (data, status) = try await send(req)
        if status == 503 { throw WirelessAPIError.unavailable }
        guard status == 200 else { throw WirelessAPIError.http(status, Self.code(data)) }
        return try WirelessAPIParse.link(data)
    }

    func registerMac(macID: String, name: String) async throws {
        let body = WirelessAPIParse.registrationBody(
            name: name, model: WirelessIdentity.model,
            systemVersion: WirelessIdentity.systemVersion, appVersion: WirelessIdentity.appVersion
        )
        let req = try request("PUT", "/devices/\(macID.lowercased())", body: body)
        let (data, status) = try await send(req)
        guard status == 200 else { throw WirelessAPIError.http(status, Self.code(data)) }
    }

    /// Best effort (sign-out): the token is passed in because the Keychain
    /// copy is already gone by the time this runs.
    func unregisterMac(macID: String, token: String) async {
        guard let req = try? request("DELETE", "/devices/\(macID.lowercased())", token: token) else { return }
        _ = try? await send(req)
    }

    func devices() async throws -> [WirelessCloudDevice] {
        let (data, status) = try await send(try request("GET", "/devices"))
        guard status == 200 else { throw WirelessAPIError.http(status, Self.code(data)) }
        guard let devices = WirelessAPIParse.devices(data) else { throw WirelessAPIError.invalidResponse }
        return devices
    }

    func requestBroadcast(deviceID: String, macID: String, macName: String) async -> WirelessPushOutcome {
        do {
            let req = try request(
                "POST", "/devices/\(deviceID.lowercased())/request-broadcast",
                body: WirelessAPIParse.requestBroadcastBody(macID: macID, macName: macName)
            )
            let (data, status) = try await send(req)
            return WirelessAPIParse.pushOutcome(status: status, data: data)
        } catch WirelessAPIError.notSignedIn {
            return .unavailable(code: "not_signed_in")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - The panel's phone list (pure)

/// The recording panel's iPhone rows, merged from what this Mac can see on
/// the LAN and what the account's device registry knows. Pure, so the gate
/// pins every rule without a network.
nonisolated enum WirelessDeviceListing {
    /// A phone seen on the LAN — one per CONNECTION (an "app" and a
    /// "broadcast" connection of the same phone are two of these).
    struct LANPhone: Equatable, Sendable {
        var deviceID: String
        var name: String
        var hasApp: Bool
        /// Broadcasting with at least one decoded keyframe.
        var isStreaming: Bool
    }

    enum Availability: Int, Equatable, Sendable {
        /// Broadcasting to this Mac now — can be recorded.
        case streaming = 0
        /// The iOS app is open (presence over Wi-Fi): ask over the LAN.
        case appOpen = 1
        /// Known to the account, not on the LAN: ask with a notification.
        case notOpen = 2
    }

    struct Entry: Equatable, Sendable {
        /// Lowercase device id — the row's identity.
        var key: String
        var name: String
        var availability: Availability

        var title: String { String(localized: "\(name) · Wi-Fi", comment: "Recording source list: an iPhone available over Wi-Fi; the placeholder is the phone's name") }
        var subtitle: String? {
            switch availability {
            case .streaming: return nil
            case .appOpen: return String(localized: "start on iPhone", comment: "Recording source list subtitle (lowercase): the CaptureCat app is open on the iPhone, start the broadcast there")
            case .notOpen: return String(localized: "not open", comment: "Recording source list subtitle (lowercase): the CaptureCat app is not open on the iPhone")
            }
        }
    }

    /// LAN phones (deduped by id, case-insensitively: app + broadcast = one
    /// row), then the registry's iOS phones that can be woken by push and
    /// are not already on the LAN. Streaming first, then app-open, then
    /// not-open; by name within each, id as the tie-break.
    static func merge(lan: [LANPhone], cloud: [WirelessCloudDevice]) -> [Entry] {
        var byKey: [String: Entry] = [:]
        var order: [String] = []
        var groups: [String: [LANPhone]] = [:]
        for phone in lan {
            let key = WirelessIdentity.key(phone.deviceID)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(phone)
        }
        for key in order {
            let connections = groups[key] ?? []
            let availability: Availability
            if connections.contains(where: \.isStreaming) {
                availability = .streaming
            } else if connections.contains(where: \.hasApp) {
                availability = .appOpen
            } else {
                // A broadcast that hasn't decoded a keyframe yet, with no app
                // connection: not a usable row yet (it will be in a moment).
                continue
            }
            let name = connections.map(\.name).first { !$0.isEmpty && $0 != "iPhone" }
                ?? connections.first?.name ?? "iPhone"
            byKey[key] = Entry(key: key, name: name.isEmpty ? "iPhone" : name, availability: availability)
        }
        let lanKeys = Set(order)
        for device in cloud where device.platform == "ios" && device.canPush {
            let key = WirelessIdentity.key(device.deviceID)
            guard !lanKeys.contains(key), byKey[key] == nil else { continue }
            byKey[key] = Entry(key: key, name: device.name, availability: .notOpen)
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.availability != rhs.availability { return lhs.availability.rawValue < rhs.availability.rawValue }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.key < rhs.key
        }
    }

    /// Whether the account has an iPhone at all — the listener only starts
    /// then (no Local Network prompt for people who never use the feature).
    static func accountHasIPhone(_ cloud: [WirelessCloudDevice]) -> Bool {
        cloud.contains { $0.platform == "ios" }
    }
}
