import Foundation
import CryptoKit
import DeviceCheck
import os

private let attestLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "AppAttest")

/// App Attest client: proves to the API that requests come from the genuine,
/// unmodified CaptureCat binary on real Apple hardware.
///
/// Design rules:
///  • NEVER blocks or breaks a request — on unsupported hardware (Intel,
///    macOS < 14), missing network, or any Apple/service error the request
///    simply goes out without attestation headers. The server's report mode
///    logs the gap; enforcement exempts such uids server-side.
///  • The hardware key is generated once; its id lives in UserDefaults (the
///    key itself never leaves the Secure Enclave).
///  • Registration: POST /api/attest/challenge → DCAppAttestService.attestKey
///    over SHA256(challenge) → POST /api/attest/register.
///  • Per request: generateAssertion over SHA256(request body) → headers
///    `X-CaptureCat-Key-Id` + `X-CaptureCat-Assertion` (matches the Worker middleware).
@MainActor
final class AppAttestService {
    static let shared = AppAttestService()

    private let keyIdDefaultsKey = "capturecat.appAttest.keyId"
    private let registeredDefaultsKey = "capturecat.appAttest.registered"
    private var registrationTask: Task<Void, Never>?

    private var service: DCAppAttestService { .shared }

    private init() {}

    /// Attestation headers for `body`, or [:] when unavailable. Kicks off
    /// (but does not wait for) key registration the first time.
    func assertionHeaders(for body: Data, apiBaseURL: String, bearerToken: String) async -> [String: String] {
        guard service.isSupported else { return [:] }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: registeredDefaultsKey),
              let keyId = defaults.string(forKey: keyIdDefaultsKey) else {
            // Not registered yet — do it in the background; this request and
            // possibly a few more go unattested (fine in report mode; the
            // server exempts nothing silently once enforcing).
            ensureRegistered(apiBaseURL: apiBaseURL, bearerToken: bearerToken)
            return [:]
        }

        do {
            let hash = Data(SHA256.hash(data: body))
            let assertion = try await service.generateAssertion(keyId, clientDataHash: hash)
            return [
                "X-CaptureCat-Key-Id": keyId,
                "X-CaptureCat-Assertion": assertion.base64EncodedString(),
            ]
        } catch {
            attestLogger.warning("assertion failed: \(error.localizedDescription, privacy: .public)")
            // A permanently invalidated key (OS reinstall etc.) must re-register.
            if (error as? DCError)?.code == .invalidKey {
                defaults.removeObject(forKey: keyIdDefaultsKey)
                defaults.set(false, forKey: registeredDefaultsKey)
            }
            return [:]
        }
    }

    /// One-shot background registration; coalesces concurrent callers.
    private func ensureRegistered(apiBaseURL: String, bearerToken: String) {
        guard registrationTask == nil else { return }
        registrationTask = Task { [weak self] in
            defer { self?.registrationTask = nil }
            do {
                try await self?.register(apiBaseURL: apiBaseURL, bearerToken: bearerToken)
                attestLogger.info("App Attest key registered")
            } catch {
                attestLogger.warning("registration failed (will retry next call): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func register(apiBaseURL: String, bearerToken: String) async throws {
        let defaults = UserDefaults.standard

        // 1. Hardware key (once).
        let keyId: String
        if let existing = defaults.string(forKey: keyIdDefaultsKey) {
            keyId = existing
        } else {
            keyId = try await service.generateKey()
            defaults.set(keyId, forKey: keyIdDefaultsKey)
        }

        // 2. Server challenge.
        var challengeReq = URLRequest(url: URL(string: "\(apiBaseURL)/api/attest/challenge")!)
        challengeReq.httpMethod = "POST"
        challengeReq.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let (challengeData, challengeResp) = try await URLSession.shared.data(for: challengeReq)
        guard (challengeResp as? HTTPURLResponse)?.statusCode == 200,
              let challengeJSON = try JSONSerialization.jsonObject(with: challengeData) as? [String: Any],
              let challengeB64 = challengeJSON["challenge"] as? String,
              let challenge = Data(base64Encoded: challengeB64) else {
            throw URLError(.badServerResponse)
        }

        // 3. Attest the key over SHA256(challenge).
        let clientDataHash = Data(SHA256.hash(data: challenge))
        let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)

        // 4. Register with the server.
        var registerReq = URLRequest(url: URL(string: "\(apiBaseURL)/api/attest/register")!)
        registerReq.httpMethod = "POST"
        registerReq.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        registerReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        registerReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
        ])
        let (_, registerResp) = try await URLSession.shared.data(for: registerReq)
        guard (registerResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        defaults.set(true, forKey: registeredDefaultsKey)
    }
}
