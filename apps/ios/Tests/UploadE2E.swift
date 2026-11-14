// End-to-end: the iOS client against Tests/mock_api.py (never production).
// Sign-in (real loopback listener + PKCE), publish a real video through the
// real CloudUploader, conflict + rebase-a-rename, download back. Run by
// apps/ios/scripts/upload-e2e.sh.
import CoreGraphics
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS  \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

let base = CommandLine.arguments[1]
let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

func run() async throws {
    // ── 1. Sign-in: the iOS AuthService's steps without the web sheet (the
    // mock "consents" at once, URLSession plays the browser).
    let pkce = OAuthPKCE.makeChallenge()
    let state = OAuthPKCE.randomURLSafeToken(byteCount: 24)
    let listener = LoopbackAuthServer()
    let port = try await listener.start()
    let redirect = OAuthPKCE.loopbackRedirectURI(port: port)
    var components = URLComponents(string: base + "/api/desktop/authorize")!
    components.queryItems = [
        .init(name: "redirect_uri", value: redirect), .init(name: "code_challenge", value: pkce.challenge),
        .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state), .init(name: "client", value: "ios"),
    ]
    let browser = Task { _ = try? await URLSession.shared.data(from: components.url!) } // follows 302 → loopback → 303 capturecat://
    let callback = try await listener.waitForCallback(timeout: 20)
    browser.cancel()
    check(callback.state == state && callback.code != nil, "loopback received code + matching state")
    let anon = APIClient(baseURL: { base }, token: { nil })
    let session = try await anon.redeem(code: callback.code!, verifier: pkce.verifier, redirectURI: redirect)
    check(!session.token.isEmpty && session.apiBaseURL == base, "code redeemed with verifier → session for this API")
    let replay = try? await anon.redeem(code: callback.code!, verifier: pkce.verifier, redirectURI: redirect)
    check(replay == nil, "code is single-use")
    let token = session.token
    let api = APIClient(baseURL: { base }, token: { token })
    let me = try await api.me()
    check(me.planDisplayName == "Pro" && me.features["commercialUse"] == true, "me() parses plan + features")

    // ── 2. A real take: a still movie from a synthetic phone-shaped frame.
    let width = 590, height = 1278
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 40, y: 600, width: 510, height: 80))
    let movie = work.appendingPathComponent("recording.mp4")
    let size = try await StillMovieWriter.write(image: ctx.makeImage()!, to: movie, duration: 2)
    let id = UUID().uuidString
    let doc = try ProjectDocument.make(.init(id: id, name: "E2E Screenshot", createdAt: Date(), videoFileName: "recording.mp4",
                                             duration: 2, sourceKind: PendingTake.sourceKind(width: Int(size.width), height: Int(size.height)),
                                             isStillCapture: true, showDeviceFrame: true))
    var phases: [PublishProgress.Phase] = []
    let lock = NSLock()
    let revision = try await CloudUploader.publish(projectID: id, name: "E2E Screenshot",
                                                   files: [LocalProjectFile(path: "recording.mp4", url: movie, contentType: "video/mp4")],
                                                   document: doc, api: api) { p in lock.lock(); phases.append(p.phase); lock.unlock() }
    check(revision == 1, "published: first save is revision 1")
    check(phases.contains(.uploading) && phases.contains(.verifying) && phases.last == .done, "progress went preparing → uploading → verifying → done")

    // ── 3. Library sees it, with the document the phone wrote.
    let list = try await api.cloudProjects()
    check(list.projects.contains { $0.projectId == id && $0.revision == 1 && $0.name == "E2E Screenshot" }, "listed in cloud projects")
    let detail = try await api.cloudProject(id)
    let facts = detail.document.flatMap { ProjectDocument.facts(Data($0.utf8)) }
    check(facts?.isStillCapture == true && facts?.sourceKind == "device", "document round-trips through the API (still, device)")

    // ── 4. Re-publishing the same id never overwrites.
    let dupDoc = try ProjectDocument.renamed(doc, to: "Dup")
    let again = try await CloudUploader.publish(projectID: id, name: "Dup", files: [LocalProjectFile(path: "recording.mp4", url: movie, contentType: "video/mp4")],
                                                document: dupDoc, api: api)
    let afterRetry = try await api.cloudProject(id)
    check(again == 1 && afterRetry.revision == 1 && afterRetry.name == "E2E Screenshot", "retrying a published take is a no-op (never overwrites)")

    // ── 5. Another device edits (adds a zoom) → our stale rename gets 409 with
    // their document; re-applying the rename onto it keeps their zoom.
    var bump = URLRequest(url: URL(string: base + "/__bump/\(id)")!); bump.httpMethod = "POST"
    _ = try await URLSession.shared.data(for: bump)
    let stale = try ProjectDocument.renamed(Data(detail.document!.utf8), to: "Renamed on iPhone")
    let first = try await api.saveProject(id, document: stale, baseRevision: detail.revision)
    guard case let .conflict(currentRevision, currentDoc?) = first else { check(false, "stale save → 409 conflict"); return }
    check(currentRevision == 2, "stale save → 409 conflict with the current revision")
    let rebased = try ProjectDocument.renamed(Data(currentDoc.utf8), to: "Renamed on iPhone")
    let second = try await api.saveProject(id, document: rebased, baseRevision: currentRevision)
    if case let .saved(rev) = second { check(rev == 3, "rebased rename saved (revision 3)") } else { check(false, "rebased rename saved") }
    let after = try await api.cloudProject(id)
    let afterDoc = try LosslessJSON.parse(Data(after.document!.utf8))
    if case let .array(zooms)? = afterDoc["zoomRegions"] {
        check(zooms.count == 1 && afterDoc["name"]?.stringValue == "Renamed on iPhone", "other device's zoom kept + rename applied")
    } else { check(false, "zoomRegions present after rebase") }

    // ── 6. Media downloads back byte-identical (Range-capable presigned GET).
    let file = after.files.first!
    let (bytes, _) = try await URLSession.shared.data(from: file.url)
    let (localSHA, _) = try CloudUploader.sha256(of: movie)
    check(file.sha256 == localSHA && CryptoSHA.hex(bytes) == localSHA, "downloaded media matches the uploaded SHA-256")

    // ── 7. Wireless link from the API decodes to the shared vector.
    let response = try await api.wirelessLink()
    let link = WirelessLink(base64URLKey: response.key)
    check(link?.keyID == response.keyId && response.keyId == "8f40509a77686376", "wireless link key decodes; keyID matches the server's")

    // ── 8. Device registration round trip (uppercase in, any case out).
    try await api.registerDevice(DeviceRegistration(deviceID: id, name: "Test iPhone", model: "iPhone18,1", systemVersion: "27.0", appVersion: "1.0 (1)"))
    let devices = try await api.devices()
    check(devices.contains { $0.deviceId.caseInsensitiveCompare(id) == .orderedSame }, "device registered and listed")

    // ── 9. A 401 is reported as signed-out.
    let bad = APIClient(baseURL: { base }, token: { "wrong" })
    do { _ = try await bad.cloudProjects(); check(false, "bad token → signedOut") } catch APIError.signedOut { check(true, "bad token → signedOut") }
}

import CryptoKit
enum CryptoSHA { static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() } }

// Top-level await runs on the main actor without blocking it (a semaphore
// here deadlocks: MainActor-isolated code — this file's functions under the
// project's default isolation, StillMovieWriter — needs the main thread).
do { try await run() } catch { print("FAIL  threw: \(error)"); failures += 1 }
print(failures == 0 ? "UPLOAD E2E: ALL PASS" : "UPLOAD E2E: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
