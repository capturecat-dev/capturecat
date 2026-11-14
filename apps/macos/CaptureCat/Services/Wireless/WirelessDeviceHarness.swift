import AppKit
import AVFoundation
import CoreMedia
import Network
import VideoToolbox

/// `CaptureCat --wireless-device-test` — the "iPhone over Wi-Fi" gate.
///
/// The REAL protocol end to end over loopback, no LAN, no Keychain, no API:
/// the real `WirelessServer` behind a real `WirelessDeviceHub` (test link,
/// loopback-only listener, stub account API), fake iPhones that speak the
/// wire contract with `WirelessDevice.parameters(link:)` and encode
/// synthetic frames with VideoToolbox H.264, the real
/// `WirelessDeviceRecorder` writing real segments, the real
/// `RecordingStitcher`, and the real recording panel in its real floating
/// panel (FloatingPanelController) for the device rows, the waiting state's
/// motion and the live monitor.
///
/// Every check prints; exits 0 only when all pass. Negative checks are
/// paired with their positive twin (a wrong key fails AND the right key
/// succeeds with the same fake phone) so none can pass vacuously.
@MainActor
enum WirelessDeviceHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        AppState.suppressAutoToolbar = true
        CCTheme.setMode(.dark, persist: false)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let ok = await execute()
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    final class Checks {
        var passed = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if condition {
                passed += 1
                print("  ✓ \(label)")
            } else {
                failures.append(label)
                print("  ✘ \(label)")
            }
        }
    }

    static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return true
    }

    static let vectorKey = Data((0..<32).map { UInt8($0) })

    static func execute() async -> Bool {
        let checks = Checks()
        if CommandLine.arguments.contains("--inject-defect") {
            // Self-test: each of these must turn the gate red.
            print("INJECTED DEFECTS: title snap, stretch instead of letterbox, no phone-audio track")
            RecordingMenuFieldChip.debugInjectSnap = true
            WirelessSegmentWriter.debugInjectStretch = true
            WirelessSegmentWriter.debugInjectNoPhoneTrack = true
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capturecat-wireless-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        pureChecks(checks)
        await endToEnd(checks, root: root)

        if checks.failures.isEmpty {
            print("WIRELESS DEVICE PASS (\(checks.passed) checks)")
            return true
        }
        print("WIRELESS DEVICE FAIL (\(checks.failures.count) of \(checks.passed + checks.failures.count)):")
        for failure in checks.failures { print("  ✘ \(failure)") }
        return false
    }

    // MARK: - Pure

    static func pureChecks(_ checks: Checks) {
        let expect = checks.expect
        print("link key + fingerprint")
        guard let vector = WirelessLink(key: vectorKey) else {
            expect(false, "a 32-byte key makes a link")
            return
        }
        expect(vector.keyID == "8f40509a77686376", "keyId vector: bytes 00…1f → 8f40509a77686376 (got \(vector.keyID))")
        let encoded = WirelessLink.base64URL(vectorKey)
        expect(encoded.count == 43 && !encoded.contains("=") && !encoded.contains("+") && !encoded.contains("/"),
               "base64url, no padding, 43 chars (\(encoded))")
        expect(WirelessLink(base64URLKey: encoded) == vector, "the API's key string decodes back to the same link")
        expect(WirelessLink(key: Data(count: 31)) == nil && WirelessLink(base64URLKey: "AAAA") == nil,
               "anything but 32 bytes is refused")

        let ok = Data(#"{"key":"\#(encoded)","keyId":"8f40509a77686376","createdAt":"2026-11-14T00:00:00Z"}"#.utf8)
        expect((try? WirelessAPIParse.link(ok)) == vector, "GET /api/wireless/link body → link, keyId verified")
        let wrongID = Data(#"{"key":"\#(encoded)","keyId":"0000000000000000"}"#.utf8)
        var mismatch = false
        do { _ = try WirelessAPIParse.link(wrongID) } catch let error as WirelessAPIError { mismatch = error == .keyMismatch } catch {}
        expect(mismatch, "a keyId that doesn't match the decoded key is refused (keyMismatch)")
        let shortKey = Data(#"{"key":"AAAA","keyId":"8f40509a77686376"}"#.utf8)
        expect((try? WirelessAPIParse.link(shortKey)) == nil, "a short key is refused")

        let txt = WirelessDevice.txtRecord(macID: "ABCDEF12-0000-4000-8000-000000000001", link: vector)
        expect(txt[WirelessDevice.txtMacIDKey] == "abcdef12-0000-4000-8000-000000000001"
               && txt[WirelessDevice.txtKeyIDKey] == "8f40509a77686376" && txt[WirelessDevice.txtVersionKey] == "1",
               "Bonjour TXT: id lowercase, a=keyID, v=1")

        print("API shapes")
        let devicesJSON = Data(#"""
        {"devices":[
          {"deviceId":"aaaaaaaa-0000-4000-8000-000000000001","platform":"ios","name":"Mike's iPhone","model":"iPhone18,1","systemVersion":"26.1","appVersion":"1.0 (3)","canPush":true,"lastSeenAt":"2026-11-14T00:00:00Z"},
          {"deviceId":"bbbbbbbb-0000-4000-8000-000000000002","platform":"mac","name":"Studio","model":null,"systemVersion":null,"appVersion":null,"canPush":false,"lastSeenAt":"2026-11-13T00:00:00Z"}
        ]}
        """#.utf8)
        let devices = WirelessAPIParse.devices(devicesJSON) ?? []
        expect(devices.count == 2 && devices[0].canPush && devices[0].platform == "ios" && devices[1].platform == "mac",
               "GET /api/devices parses (\(devices.count) rows)")
        expect(WirelessDeviceListing.accountHasIPhone(devices) && !WirelessDeviceListing.accountHasIPhone([devices[1]]),
               "the listener only starts for an account with an iPhone")
        let body = WirelessAPIParse.registrationBody(name: "Mac", model: "Mac16,10", systemVersion: "26.1", appVersion: "1.6 (10)")
        expect(body["platform"] as? String == "mac" && body["apnsToken"] == nil && body["name"] as? String == "Mac",
               "PUT /api/devices/:macId body: platform mac, never an apnsToken")
        let push = WirelessAPIParse.requestBroadcastBody(macID: "ABCDEF12-0000-4000-8000-000000000001", macName: "Mac")
        expect(push["macId"] as? String == "abcdef12-0000-4000-8000-000000000001", "request-broadcast sends macId lowercase")
        expect(WirelessAPIParse.pushOutcome(status: 200, data: Data(#"{"sent":true}"#.utf8)) == .sent
               && WirelessAPIParse.pushOutcome(status: 409, data: Data(#"{"code":"push_unavailable"}"#.utf8)) == .unavailable(code: "push_unavailable")
               && WirelessAPIParse.pushOutcome(status: 503, data: Data(#"{"code":"push_not_configured"}"#.utf8)) == .unavailable(code: "push_not_configured")
               && WirelessAPIParse.pushOutcome(status: 404, data: Data(#"{"code":"not_found"}"#.utf8)) == .unavailable(code: "not_found")
               && WirelessAPIParse.pushOutcome(status: 502, data: Data(#"{"code":"push_failed"}"#.utf8)) == .failed("push_failed"),
               "request-broadcast outcomes: 200 sent · 409/503/404 unavailable · 502 failed")

        print("device list merge (LAN × API, case-insensitive)")
        let upper = "AAAAAAAA-0000-4000-8000-000000000001"
        typealias LAN = WirelessDeviceListing.LANPhone
        func cloud(_ id: String, _ name: String, platform: String = "ios", canPush: Bool = true) -> WirelessCloudDevice {
            WirelessCloudDevice(deviceID: id.lowercased(), platform: platform, name: name, model: nil,
                                systemVersion: nil, appVersion: nil, canPush: canPush, lastSeenAt: nil)
        }
        // App + broadcast of the same phone (the phone's id is UPPERCASE; the
        // API's lowercase) → ONE streaming row, no "not open" twin.
        let merged = WirelessDeviceListing.merge(
            lan: [LAN(deviceID: upper, name: "Mike's iPhone", hasApp: true, isStreaming: false),
                  LAN(deviceID: upper, name: "Mike's iPhone", hasApp: false, isStreaming: true)],
            cloud: [cloud(upper, "Mike's iPhone")]
        )
        expect(merged.count == 1 && merged[0].availability == .streaming && merged[0].key == upper.lowercased()
               && merged[0].title == "Mike's iPhone · Wi-Fi" && merged[0].subtitle == nil,
               "app + broadcast + API row of one phone = one streaming row (\(merged.map(\.title)))")
        let appOnly = WirelessDeviceListing.merge(lan: [LAN(deviceID: upper, name: "Mike's iPhone", hasApp: true, isStreaming: false)], cloud: [])
        expect(appOnly.first?.availability == .appOpen && appOnly.first?.subtitle == "start on iPhone",
               "app-only phone → \"<name> · Wi-Fi — start on iPhone\"")
        let pushOnly = WirelessDeviceListing.merge(lan: [], cloud: [
            cloud("cccccccc-0000-4000-8000-000000000003", "iPad"),
            cloud("dddddddd-0000-4000-8000-000000000004", "Old iPhone", canPush: false),
            cloud("eeeeeeee-0000-4000-8000-000000000005", "Studio", platform: "mac"),
        ])
        expect(pushOnly.count == 1 && pushOnly[0].availability == .notOpen && pushOnly[0].subtitle == "not open",
               "API rows: only iOS + canPush, as \"— not open\" (\(pushOnly.map(\.title)))")
        let connecting = WirelessDeviceListing.merge(
            lan: [LAN(deviceID: upper, name: "Mike's iPhone", hasApp: false, isStreaming: false)],
            cloud: [cloud(upper.lowercased(), "Mike's iPhone")]
        )
        expect(connecting.isEmpty, "a broadcast still waiting for its keyframe shows no row (and no \"not open\" twin)")
        let order = WirelessDeviceListing.merge(
            lan: [LAN(deviceID: "11111111-0000-4000-8000-000000000001", name: "B phone", hasApp: true, isStreaming: false),
                  LAN(deviceID: "22222222-0000-4000-8000-000000000002", name: "A phone", hasApp: false, isStreaming: true)],
            cloud: [cloud("33333333-0000-4000-8000-000000000003", "C phone")]
        )
        expect(order.map(\.availability) == [.streaming, .appOpen, .notOpen], "streaming, then app-open, then not-open")
    }

    // MARK: - End to end

    static func endToEnd(_ checks: Checks, root: URL) async {
        let expect = checks.expect
        guard let link = WirelessLink(key: vectorKey),
              let wrongLink = WirelessLink(key: Data((0..<32).map { UInt8(255 - $0) })),
              let rotatedLink = WirelessLink(key: Data((0..<32).map { UInt8(($0 * 7 + 3) & 0xFF) })) else { return }
        let stub = StubAccountAPI(link: link, rotated: rotatedLink)
        let hub = WirelessDeviceHub(api: stub, macID: "ABCDEF12-0000-4000-8000-0000000000AA", macName: "Probe Mac")
        hub.usesKeychain = false
        hub.advertises = false
        hub.loopbackOnly = true
        hub.persistsAccountFlags = false
        hub.noticeDuration = 30
        hub.startServer(link: link)
        guard let port = await hub.waitForPort(), let server = hub.server else {
            expect(false, "loopback listener starts (TLS-PSK parameters)")
            return
        }
        expect(true, "loopback listener starts on port \(port)")

        print("handshake")
        let phoneID = "AAAAAAAA-1111-4000-8000-000000000001" // iOS: UUID().uuidString — uppercase
        let app = FakePhone(link: link, role: WirelessDevice.roleApp, deviceID: phoneID, name: "Probe iPhone")
        app.connect(port: port)
        expect(await waitUntil(5) { app.macHello != nil }, "app connection: hello → macHello")
        expect(app.macHello?.macID == "abcdef12-0000-4000-8000-0000000000aa" && app.macHello?.recording == false,
               "macHello carries the lowercase Mac id, recording=false")
        expect(await waitUntil(2) { hub.phones.count == 1 }, "the hub lists the phone")
        expect(hub.entries.first?.availability == .appOpen && hub.entries.first?.subtitle == "start on iPhone",
               "app-only phone listed as \"start on iPhone\"")

        // Wrong key: same fake phone, other link → no handshake. Positive twin above.
        let intruder = FakePhone(link: wrongLink, role: WirelessDevice.roleBroadcast, deviceID: "99999999-0000-4000-8000-000000000009", name: "Intruder")
        intruder.connect(port: port)
        try? await Task.sleep(for: .seconds(2))
        expect(intruder.macHello == nil && !intruder.becameReady,
               "a WRONG key never completes the handshake (state: \(intruder.lastState))")
        expect(hub.phones.count == 1, "…and never appears in the list")
        intruder.close()

        // Protocol version check: a hello from the future is refused.
        let future = FakePhone(link: link, role: WirelessDevice.roleApp, deviceID: "88888888-0000-4000-8000-000000000008", name: "Future", protocolVersion: 99)
        future.connect(port: port)
        expect(await waitUntil(3) { future.bye != nil || future.ended }, "hello with protocol 99 is refused (bye/close)")
        expect(future.macHello == nil && server.snapshotStats().rejectedHello >= 1, "…without a macHello")
        future.close()

        print("requestBroadcast over the LAN → broadcast arrives → one phone")
        var resolved: Bool?
        Task { @MainActor in resolved = await hub.requestBroadcast(phoneID.lowercased()) }
        expect(await waitUntil(3) { app.controls.contains { $0.command == "requestBroadcast" } },
               "\"requestBroadcast\" control delivered on the APP connection")
        expect(hub.pending?.route == .lan && hub.pending?.prompt == "Tap Start Broadcast on your iPhone",
               "waiting state: \"Tap Start Broadcast on your iPhone\"")
        let broadcast = FakePhone(link: link, role: WirelessDevice.roleBroadcast, deviceID: phoneID, name: "Probe iPhone")
        broadcast.remoteClockOffset = 987_654_321_000 // the phone's host clock is NOT the Mac's
        broadcast.connect(port: port)
        expect(await waitUntil(5) { broadcast.macHello != nil }, "broadcast connection: hello → macHello")
        broadcast.startVideo(width: 360, height: 640, fps: 30)
        expect(await waitUntil(6) { resolved != nil }, "the request resolves once the first keyframe decodes")
        expect(resolved == true && hub.pending == nil, "…as streaming")
        expect(hub.phones.count == 1 && hub.phones.first?.hasApp == true && hub.phones.first?.hasBroadcast == true,
               "app + broadcast with the same deviceID = ONE phone (\(hub.phones.count))")
        expect(hub.entries.count == 1 && hub.entries.first?.availability == .streaming && hub.entries.first?.title == "Probe iPhone · Wi-Fi",
               "listed once, as \"Probe iPhone · Wi-Fi\"")
        expect(await waitUntil(2) { server.snapshotStats().framesDecoded > 10 }, "frames decode (\(server.snapshotStats().framesDecoded))")

        // MARK: Segment A — rotation, no app audio, mic on its own track
        print("segment A: portrait → rotate → landscape, mic injected, no app audio")
        let recorderA = WirelessDeviceRecorder()
        let keyframeRequestsBefore = broadcast.keyframeControls
        let controlKeyframesBefore = broadcast.keyframesForcedByControl
        let originA = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            try recorderA.startRecording(phone: phoneID.lowercased(), server: server, sharedOrigin: originA,
                                         captureMicrophone: true, microphoneFeed: .injected, directory: root)
        } catch {
            expect(false, "recorder starts (\(error))")
            return
        }
        let mic = MicTone(frequency: 660)
        mic.start { recorderA.injectMicrophone($0) }
        await recorderA.waitForSessionStart()
        expect(recorderA.sessionStartHostTimeSeconds != nil, "segment starts (first frame written)")
        expect(broadcast.keyframeControls > keyframeRequestsBefore, "\"keyframe\" control round-trips to the phone at segment start")
        expect(broadcast.keyframesForcedByControl > controlKeyframesBefore, "…and the phone answers with a forced IDR")
        expect(broadcast.controls.contains { $0.command == "state" && $0.recording == true }, "\"state\" recording=true reaches the phone")
        try? await Task.sleep(for: .milliseconds(1400))
        // Rotate: new parameter sets, swapped dimensions, keyframe.
        let formatChangesBefore = server.snapshotStats().formatChanges
        broadcast.rotate(width: 640, height: 360)
        expect(await waitUntil(2) { server.snapshotStats().formatChanges > formatChangesBefore }, "the new videoFormat rebuilds the decoder")
        expect(await waitUntil(2) { hub.phones.first?.width == 640 && hub.phones.first?.height == 360 }, "the hub sees the rotated 640×360 format")
        try? await Task.sleep(for: .milliseconds(1100))
        let stopA = CMClockGetTime(CMClockGetHostTimeClock())
        await recorderA.stopRecording()
        mic.stop()
        let statsA = recorderA.lastStats
        let stateOff = await waitUntil(1) { broadcast.controls.contains { $0.command == "state" && $0.recording == false } }
        expect(stateOff, "\"state\" recording=false at segment end")
        guard let urlA = recorderA.outputURL else {
            expect(false, "segment A was written (\(statsA?.writerError ?? "no error"))")
            return
        }
        expect(statsA?.firstWrittenWasKeyframe == true, "the first written frame is a keyframe")
        expect((statsA?.letterboxedFrames ?? 0) > 10, "rotated frames written letterboxed (\(statsA?.letterboxedFrames ?? 0))")
        let spanA = CMTimeGetSeconds(CMTimeSubtract(stopA, originA))
        let infoA = await MovieInfo.read(urlA)
        expect(infoA.size == CGSize(width: 360, height: 640), "canvas fixed at segment start: 360×640 (\(infoA.size))")
        expect(abs(infoA.duration - spanA) < 0.3, String(format: "duration ≈ streamed span (%.2fs vs %.2fs)", infoA.duration, spanA))
        expect(infoA.videoMonotonic && infoA.videoSamples > 60, "video PTS strictly increasing (\(infoA.videoSamples) samples) — clock mapping is monotonic")
        expect(infoA.audioChannels == [2, 1], "audio tracks in DeviceRecorder order: phone (2 ch) FIRST, mic (1 ch) SECOND (\(infoA.audioChannels))")
        expect(infoA.audioRMS.count == 2 && infoA.audioRMS[0] < 0.001, String(format: "no app audio → track 0 is silence (rms %.4f)", infoA.audioRMS.first ?? -1))
        expect(infoA.audioRMS.count == 2 && infoA.audioRMS[1] > 0.02, String(format: "the mic tone is on track 1 (rms %.4f)", infoA.audioRMS.last ?? -1))
        expect((infoA.audioDurations.first ?? 0) > infoA.duration - 0.3, String(format: "the silent phone track spans the segment (%.2fs)", infoA.audioDurations.first ?? 0))
        if let late = await MovieInfo.frame(urlA, at: max(0, infoA.duration - 0.3)),
           let early = await MovieInfo.frame(urlA, at: 0.6) {
            let topBand = late.luma(x: 0.5, y: 0.08)
            let center = late.luma(x: 0.5, y: 0.5)
            expect(topBand < 0.06 && center > 0.25,
                   String(format: "after rotation: black bars top/bottom (%.3f), picture in the middle (%.3f) — letterbox, not stretch", topBand, center))
            expect(early.luma(x: 0.5, y: 0.08) > 0.25, String(format: "before rotation the picture fills the canvas (%.3f)", early.luma(x: 0.5, y: 0.08)))
        } else {
            expect(false, "frames read back from segment A")
        }

        // MARK: Segment B — app audio, disconnect mid-segment
        print("segment B: app audio, phone drops mid-segment")
        broadcast.startAudio(sampleRate: 44_100, channels: 2, frequency: 440)
        try? await Task.sleep(for: .milliseconds(300))
        let recorderB = WirelessDeviceRecorder()
        let originB = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            try recorderB.startRecording(phone: phoneID.lowercased(), server: server, sharedOrigin: originB,
                                         captureMicrophone: false, microphoneFeed: .injected, directory: root)
        } catch {
            expect(false, "recorder B starts (\(error))")
            return
        }
        await recorderB.waitForSessionStart()
        try? await Task.sleep(for: .milliseconds(1200))
        let dropB = CMClockGetTime(CMClockGetHostTimeClock())
        broadcast.close() // like pulling the cable
        expect(await waitUntil(3) { hub.phones.first?.hasBroadcast == false }, "the hub sees the broadcast drop (app connection stays)")
        try? await Task.sleep(for: .milliseconds(600))
        await recorderB.stopRecording()
        guard let urlB = recorderB.outputURL else {
            expect(false, "a phone that drops mid-segment still leaves a finished segment (\(recorderB.lastStats?.writerError ?? "-"))")
            return
        }
        expect(true, "a phone that drops mid-segment still leaves a finished segment — the take is never lost")
        let infoB = await MovieInfo.read(urlB)
        let spanB = CMTimeGetSeconds(CMTimeSubtract(dropB, originB))
        expect(abs(infoB.duration - spanB) < 0.35, String(format: "…ending where the phone dropped (%.2fs vs %.2fs)", infoB.duration, spanB))
        expect(infoB.audioChannels == [2], "one phone-audio track, no mic (\(infoB.audioChannels))")
        expect((infoB.audioRMS.first ?? 0) > 0.05, String(format: "app audio (44.1 kHz → 48 kHz) is on track 0 (rms %.4f)", infoB.audioRMS.first ?? 0))
        expect((recorderB.lastStats?.appAudioChunks ?? 0) > 20, "app audio chunks written (\(recorderB.lastStats?.appAudioChunks ?? 0))")

        // MARK: Stitch with a display segment
        print("stitch: display + Wi-Fi segment")
        let displayURL = root.appendingPathComponent("display.mov")
        do {
            try await writeDisplayMovie(to: displayURL)
            let result = try await RecordingStitcher.stitch(
                [.init(url: displayURL, kind: .display), .init(url: urlA, kind: .device)],
                outputURL: root.appendingPathComponent("stitched.mov")
            )
            expect(result.segments.map(\.kind) == [.display, .device], "stitched take marks the Wi-Fi span .device (\(result.segments.map(\.kind)))")
            if let device = result.segments.last {
                expect(device.contentHeight > 0.99 && device.contentWidth < 0.4,
                       String(format: "the phone is aspect-fit into the display canvas (%.3f × %.3f) — bezel geometry", device.contentWidth, device.contentHeight))
            }
        } catch {
            expect(false, "stitch display + Wi-Fi (\(error))")
        }

        // MARK: Push route + API dedupe through the hub
        print("signed in: API devices × LAN, push route, quiet failure, timeout")
        hub.authDidChange(userID: "probe-user")
        expect(await waitUntil(3) { !hub.cloudDevices.isEmpty }, "signed in: GET /api/devices listed (\(stub.devicesCalls) call)")
        expect(stub.registered == ["abcdef12-0000-4000-8000-0000000000aa"], "this Mac registered as platform mac with its lowercase id")
        expect(hub.activeKeyID == link.keyID, "the API's link (same key) keeps the listener as is")
        let pushKey = StubAccountAPI.pushPhone.lowercased()
        expect(hub.entries.contains { $0.key == pushKey && $0.availability == .notOpen && $0.subtitle == "not open" },
               "the account's closed iPhone listed as \"— not open\"")
        expect(hub.entries.filter { $0.key == phoneID.lowercased() }.count == 1,
               "the LAN phone isn't listed twice although the API knows it too")
        var pushResolved: Bool?
        Task { @MainActor in pushResolved = await hub.requestBroadcast(pushKey) }
        expect(await waitUntil(3) { hub.pending?.route == .push }, "push route: POST …/request-broadcast sent")
        expect(stub.pushRequests.first?.deviceID == pushKey && stub.pushRequests.first?.macID == "abcdef12-0000-4000-8000-0000000000aa",
               "…to the lowercase device id with the lowercase macId")
        expect(hub.pending?.prompt == "Check your iPhone — tap the notification, then Start Broadcast", "waiting state for a notification")
        let woken = FakePhone(link: link, role: WirelessDevice.roleBroadcast, deviceID: StubAccountAPI.pushPhone.uppercased(), name: "Desk iPhone")
        woken.connect(port: port)
        woken.startVideo(width: 360, height: 640, fps: 30)
        expect(await waitUntil(6) { pushResolved != nil }, "the woken phone's broadcast (UPPERCASE id) resolves the request")
        expect(pushResolved == true, "…as streaming")
        expect(hub.entries.filter { $0.key == pushKey }.count == 1 && hub.entries.first { $0.key == pushKey }?.availability == .streaming,
               "the API row and the LAN broadcast merge case-insensitively into one streaming row")

        let failed = await hub.requestBroadcast(StubAccountAPI.deadPhone.lowercased())
        expect(!failed && hub.pending == nil && hub.notice == "Open CaptureCat on your iPhone to stream",
               "push_unavailable → quiet \"Open CaptureCat on your iPhone to stream\", nothing pending")

        hub.broadcastTimeout = 1.0
        let idle = FakePhone(link: link, role: WirelessDevice.roleApp, deviceID: "77777777-0000-4000-8000-000000000007", name: "Idle iPhone")
        idle.connect(port: port)
        _ = await waitUntil(3) { hub.phone("77777777-0000-4000-8000-000000000007") != nil }
        hub.clearNotice()
        let started = Date()
        let timedOut = await hub.requestBroadcast("77777777-0000-4000-8000-000000000007")
        expect(!timedOut && Date().timeIntervalSince(started) >= 0.9 && hub.notice != nil,
               String(format: "no Start Broadcast tap → times out (%.1fs) with the quiet notice", Date().timeIntervalSince(started)))
        hub.broadcastTimeout = 30

        // MARK: Real panel
        await panelChecks(checks, hub: hub, phoneKey: phoneID.lowercased(), root: root)

        // MARK: Forget my devices
        print("forget my devices: rotate → re-advertise, connections dropped")
        let oldPort = port
        do {
            try await hub.forgetDevices()
        } catch {
            expect(false, "rotation (\(error))")
        }
        expect(stub.rotations == 1 && hub.activeKeyID == rotatedLink.keyID && hub.activeKeyID != link.keyID,
               "POST /api/wireless/link/rotate → new keyID \(hub.activeKeyID ?? "nil")")
        expect(await waitUntil(3) { app.ended && woken.ended }, "existing connections are dropped")
        guard let newPort = await hub.waitForPort() else {
            expect(false, "the listener comes back after rotation")
            return
        }
        let stale = FakePhone(link: link, role: WirelessDevice.roleApp, deviceID: phoneID, name: "Probe iPhone")
        stale.connect(port: newPort)
        let fresh = FakePhone(link: rotatedLink, role: WirelessDevice.roleApp, deviceID: phoneID, name: "Probe iPhone")
        fresh.connect(port: newPort)
        expect(await waitUntil(5) { fresh.macHello != nil }, "a phone with the NEW key connects (port \(newPort), was \(oldPort))")
        try? await Task.sleep(for: .milliseconds(800))
        expect(stale.macHello == nil, "a phone still holding the OLD key cannot")
        for phone in [stale, fresh, idle, woken, app] { phone.close() }

        hub.authDidChange(userID: nil)
        expect(hub.server == nil && hub.cloudDevices.isEmpty && hub.entries.isEmpty, "sign-out stops the listener and forgets the account's phones")
    }

    // MARK: - The real panel

    static func panelChecks(_ checks: Checks, hub: WirelessDeviceHub, phoneKey: String, root: URL) async {
        let expect = checks.expect
        print("recording panel (real FloatingPanelController)")
        // The panel reads the shared hub: point it at this test's server.
        let shared = WirelessDeviceHub.shared
        shared.usesKeychain = false
        shared.advertises = false
        shared.loopbackOnly = true
        shared.persistsAccountFlags = false
        guard let link = hub.server?.link else { return }
        shared.startServer(link: link)
        guard let port = await shared.waitForPort(), let server = shared.server else {
            expect(false, "shared hub listens for the panel probe")
            return
        }
        let streaming = FakePhone(link: link, role: WirelessDevice.roleBroadcast, deviceID: phoneKey.uppercased(), name: "Probe iPhone")
        streaming.connect(port: port)
        streaming.startVideo(width: 360, height: 640, fps: 30)
        let openApp = FakePhone(link: link, role: WirelessDevice.roleApp, deviceID: "66666666-0000-4000-8000-000000000006", name: "Couch iPhone")
        openApp.connect(port: port)
        _ = await waitUntil(5) { shared.entries.count == 2 && shared.isStreaming(phoneKey) }

        let appState = AppState()
        appState.panelController.show(size: RecordingPanelMetrics.setupPanelSize())
        guard let panel = appState.panelController.panel, let vc = appState.panelController.debugRecordingController else {
            expect(false, "the real recording panel is up")
            return
        }
        defer {
            shared.signedInOverride = nil
            appState.recordingSession.phase = .idle
            appState.panelController.close()
            streaming.close()
            openApp.close()
            shared.stopServer(reason: "probe done")
        }
        panel.setFrameOrigin(NSPoint(x: -20_000, y: 200))
        vc.debugSelectTab(.device)
        try? await Task.sleep(for: .milliseconds(500))

        // Signed out: no Wi-Fi rows, a light sign-in row instead.
        shared.signedInOverride = false
        try? await Task.sleep(for: .milliseconds(100))
        let signedOut = vc.debugDeviceOptionList()
        let signedOutTitles = signedOut.presentedOptions.map(\.title)
        expect(!signedOutTitles.contains { $0.contains("· Wi-Fi") }, "signed out: no Wi-Fi rows (\(signedOutTitles))")
        expect(signedOut.actions.map(\.option.title) == ["Sign in to use your iPhone over Wi-Fi"],
               "signed out: a light \"Sign in to use your iPhone over Wi-Fi\" row")

        shared.signedInOverride = true
        try? await Task.sleep(for: .milliseconds(100))
        let list = vc.debugDeviceOptionList()
        let titles = list.presentedOptions.map { $0.title + ($0.subtitle.map { " — \($0)" } ?? "") }
        print("  · device rows: \(titles)")
        expect(titles.contains("Probe iPhone · Wi-Fi") && titles.contains("Couch iPhone · Wi-Fi — start on iPhone"),
               "signed in: streaming + app-open phones listed in the device picker")
        expect(list.actions.map(\.option.title) == ["Forget my devices…"], "…with \"Forget my devices…\" last")

        // Pick the streaming phone through the real option list (the path a
        // click takes), then check the row can start.
        if let index = list.presentedOptions.firstIndex(where: { $0.title == "Probe iPhone · Wi-Fi" }) {
            list.pick(index)
            try? await Task.sleep(for: .milliseconds(100))
            let state = vc.debugDeviceChipState
            expect(state.title == "Probe iPhone · Wi-Fi" && state.canStart, "picking the streaming phone makes it recordable (\(state.title))")
        }
        if let index = list.presentedOptions.firstIndex(where: { $0.title == "Couch iPhone · Wi-Fi" }) {
            list.pick(index)
            try? await Task.sleep(for: .milliseconds(40))
            let state = vc.debugDeviceChipState
            let asked = await waitUntil(2) { openApp.controls.contains { $0.command == "requestBroadcast" } }
            expect(asked, "picking an app-open phone asks it to broadcast")
            expect(state.title == "Tap Start Broadcast on your iPhone" && state.spinnerVisible && !state.canStart,
                   "waiting state on the chip: prompt + spinner, Record disabled (\(state.title))")
            expect(state.titleSwapInFlight, "the chip title CROSSFADES into the prompt (mid-flight), never snaps (\(vc.debugDeviceTitleLayerInfo))")
            shared.cancelPending(message: "Open CaptureCat on your iPhone to stream")
            try? await Task.sleep(for: .milliseconds(150))
            let after = vc.debugDeviceChipState
            expect(after.error == "Open CaptureCat on your iPhone to stream" && after.title == "Probe iPhone · Wi-Fi",
                   "cancelled: the previous pick comes back with the quiet notice (\(after.title))")
        }

        // Live monitor: a Wi-Fi segment in the recording phase shows the
        // phone's decoded frames in the real monitor panel.
        let recorder = appState.wirelessRecorder
        do {
            try recorder.startRecording(phone: phoneKey, server: server, sharedOrigin: CMClockGetTime(CMClockGetHostTimeClock()),
                                        captureMicrophone: false, directory: root)
        } catch {
            expect(false, "panel probe recorder starts (\(error))")
            return
        }
        appState.recordingSession.phase = .recording
        expect(await waitUntil(2) { vc.debugDeviceMonitorPanel != nil }, "recording a Wi-Fi phone opens the live monitor")
        if let monitor = vc.debugDeviceMonitorPanel {
            try? await Task.sleep(for: .milliseconds(60))
            let alpha = monitor.alphaValue
            expect(alpha > 0.01 && alpha < 0.99, String(format: "the monitor fades in (alpha %.2f mid-flight)", alpha))
            let content = findView(WirelessMonitorContentView.self, in: monitor.contentView)
            expect(content != nil, "the monitor hosts the Wi-Fi feed view inside the device monitor chassis")
            expect(await waitUntil(2) { (content?.framesShown ?? 0) > 5 }, "decoded frames reach the monitor (\(content?.framesShown ?? 0))")
            expect(content?.lastFrameSize == CGSize(width: 360, height: 640), "…at the phone's size")
        }
        await recorder.stopRecording()
        appState.recordingSession.phase = .idle
        expect(await waitUntil(2) { vc.debugDeviceMonitorPanel == nil }, "the monitor closes with the segment")
    }

    static func findView<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let match = root as? T { return match }
        for sub in root.subviews { if let found = findView(type, in: sub) { return found } }
        return nil
    }

    // MARK: - Fixtures

    static func writeDisplayMovie(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let buffer = FakePhone.makeFrame(width: 1280, height: 720, index: frame, pool: adaptor.pixelBufferPool) else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - Stub account API

nonisolated final class StubAccountAPI: WirelessAccountAPI, @unchecked Sendable {
    static let pushPhone = "bbbbbbbb-2222-4000-8000-000000000002"
    static let deadPhone = "cccccccc-3333-4000-8000-000000000003"
    private let lock = NSLock()
    private let link: WirelessLink
    private let rotated: WirelessLink
    private var _registered: [String] = []
    private var _pushRequests: [(deviceID: String, macID: String)] = []
    private var _rotations = 0
    private var _devicesCalls = 0

    init(link: WirelessLink, rotated: WirelessLink) {
        self.link = link
        self.rotated = rotated
    }

    var registered: [String] { lock.withLock { _registered } }
    var pushRequests: [(deviceID: String, macID: String)] { lock.withLock { _pushRequests } }
    var rotations: Int { lock.withLock { _rotations } }
    var devicesCalls: Int { lock.withLock { _devicesCalls } }

    func fetchLink(rotate: Bool) async throws -> WirelessLink {
        lock.withLock {
            if rotate { _rotations += 1 }
            return _rotations > 0 ? rotated : link
        }
    }

    func registerMac(macID: String, name: String) async throws {
        lock.withLock { _registered.append(macID) }
    }

    func unregisterMac(macID: String, token: String) async {}

    func devices() async throws -> [WirelessCloudDevice] {
        lock.withLock { _devicesCalls += 1 }
        func row(_ id: String, _ name: String, canPush: Bool) -> WirelessCloudDevice {
            WirelessCloudDevice(deviceID: id.lowercased(), platform: "ios", name: name, model: "iPhone18,1",
                                systemVersion: "26.1", appVersion: "1.0", canPush: canPush, lastSeenAt: nil)
        }
        return [
            // The LAN phone (the API knows it too — must not be listed twice).
            row("AAAAAAAA-1111-4000-8000-000000000001", "Probe iPhone", canPush: true),
            row(Self.pushPhone, "Desk iPhone", canPush: true),
            row(Self.deadPhone, "Drawer iPhone", canPush: true),
            WirelessCloudDevice(deviceID: "abcdef12-0000-4000-8000-0000000000aa", platform: "mac", name: "Probe Mac",
                                model: nil, systemVersion: nil, appVersion: nil, canPush: false, lastSeenAt: nil),
        ]
    }

    func requestBroadcast(deviceID: String, macID: String, macName: String) async -> WirelessPushOutcome {
        lock.withLock { _pushRequests.append((deviceID, macID)) }
        return deviceID == Self.deadPhone ? .unavailable(code: "push_unavailable") : .sent
    }
}

// MARK: - Fake iPhone (the sender side of the wire contract)

nonisolated final class FakePhone: @unchecked Sendable {
    let queue = DispatchQueue(label: "so.capturecat.CaptureCat.fakePhone")
    private let hello: WirelessHello
    private let lock = NSLock()
    private var _macHello: WirelessMacHello?
    private var _controls: [WirelessControl] = []
    private var _bye: WirelessBye?
    private var _ended = false
    private var _ready = false
    private var _state = "setup"
    private var _keyframeControls = 0
    private var _forcedKeyframes = 0
    private var _forcedByControl = 0
    private var controlAskedKeyframe = false

    /// remote pts = Mac host time + this (a different clock domain).
    var remoteClockOffset: Int64 = 0

    private var encoder: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var frameIndex = 0
    private var videoTimer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private var forceKeyframe = true
    private var sentFormat: WirelessVideoFormat?
    private var lastSendAt: DispatchTime = .now()
    private var audioFramesSent: Int64 = 0
    private var audioStartPTS: Int64 = 0

    var macHello: WirelessMacHello? { lock.withLock { _macHello } }
    var controls: [WirelessControl] { lock.withLock { _controls } }
    var bye: WirelessBye? { lock.withLock { _bye } }
    var ended: Bool { lock.withLock { _ended } }
    var becameReady: Bool { lock.withLock { _ready } }
    var lastState: String { lock.withLock { _state } }
    var keyframeControls: Int { lock.withLock { _keyframeControls } }
    var forcedKeyframes: Int { lock.withLock { _forcedKeyframes } }
    /// IDRs encoded BECAUSE a "keyframe" control arrived.
    var keyframesForcedByControl: Int { lock.withLock { _forcedByControl } }

    init(link: WirelessLink, role: String, deviceID: String, name: String, protocolVersion: UInt32 = WirelessDevice.protocolVersion) {
        let params = WirelessDevice.parameters(link: link)
        params.requiredInterfaceType = .loopback
        params.includePeerToPeer = false
        hello = WirelessHello(protocolVersion: protocolVersion, role: role, deviceID: deviceID, deviceName: name,
                              model: "iPhone18,1", systemVersion: "26.1", appVersion: "1.0 (1)",
                              screenWidth: 1206, screenHeight: 2622, screenScale: 3)
        self.params = params
    }

    private let params: NWParameters
    private var live: NWConnection?

    func connect(port: UInt16) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params)
        live = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.withLock { self._state = "\(state)" }
            switch state {
            case .ready:
                self.lock.withLock { self._ready = true }
                connection.sendWireless(.hello, WirelessJSON.encode(self.hello))
            case .failed, .cancelled:
                self.lock.withLock { self._ended = true }
            default:
                break
            }
        }
        connection.receiveWireless({ [weak self] type, payload in
            guard let self else { return false }
            switch type {
            case .macHello:
                let reply = WirelessJSON.decode(WirelessMacHello.self, from: payload)
                self.lock.withLock { self._macHello = reply }
            case .control:
                if let control = WirelessJSON.decode(WirelessControl.self, from: payload) {
                    self.lock.withLock {
                        self._controls.append(control)
                        if control.command == "keyframe" { self._keyframeControls += 1 }
                    }
                    if control.command == "keyframe" {
                        self.forceKeyframe = true
                        self.controlAskedKeyframe = true
                    }
                }
            case .bye:
                let bye = WirelessJSON.decode(WirelessBye.self, from: payload)
                self.lock.withLock { self._bye = bye }
            default:
                break
            }
            return true
        }, onEnd: { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self._ended = true }
        })
        connection.start(queue: queue)
    }

    func close() {
        queue.sync {
            videoTimer?.cancel()
            videoTimer = nil
            audioTimer?.cancel()
            audioTimer = nil
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
        }
        live?.cancel()
        lock.withLock { _ended = true }
    }

    // MARK: Video

    func startVideo(width: Int, height: Int, fps: Double) {
        queue.async { [self] in
            makeEncoder(width: width, height: height)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / fps)
            timer.setEventHandler { [weak self] in self?.encodeNextFrame() }
            videoTimer = timer
            timer.resume()
        }
    }

    /// The phone rotated: new encoder (new parameter sets), swapped size.
    func rotate(width: Int, height: Int) {
        queue.async { [self] in
            makeEncoder(width: width, height: height)
            forceKeyframe = true
        }
    }

    private func makeEncoder(width: Int, height: Int) {
        if let encoder { VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(encoder) }
        var session: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                   codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Keyframes only when asked (first frame, rotation, "keyframe"
        // control) — so the gate can see the control actually work.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_000_000 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        self.width = width
        self.height = height
        forceKeyframe = true
    }

    private func encodeNextFrame() {
        guard let encoder else { return }
        frameIndex += 1
        guard let buffer = Self.makeFrame(width: width, height: height, index: frameIndex, pool: nil) else { return }
        let captureNanos = WirelessDevice.hostTimeNanos()
        let remotePTS = captureNanos + remoteClockOffset
        let force = forceKeyframe
        let byControl = force && controlAskedKeyframe
        forceKeyframe = false
        controlAskedKeyframe = false
        if force { lock.withLock { _forcedKeyframes += 1; if byControl { _forcedByControl += 1 } } }
        let properties: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: buffer,
            presentationTimeStamp: CMTime(value: remotePTS, timescale: 1_000_000_000),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            nonisolated(unsafe) let encoded = sample
            self.queue.async { self.send(encoded, pts: remotePTS) }
        }
    }

    private func send(_ sample: CMSampleBuffer, pts: Int64) {
        guard let live, let description = CMSampleBufferGetFormatDescription(sample) else { return }
        // Parameter sets → videoFormat, whenever they change (rotation).
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let pointer { sets.append(Data(bytes: pointer, count: size)) }
        }
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        let format = WirelessVideoFormat(codec: "avc1", width: Int(dims.width), height: Int(dims.height), parameterSets: sets, frameRate: 30)
        if format != sentFormat {
            sentFormat = format
            live.sendWireless(.videoFormat, WirelessJSON.encode(format))
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        data.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
        }
        let frame = WirelessVideoFrame(pts: pts, isKeyframe: !notSync, data: data)
        // Wi-Fi-ish jitter: 0–12 ms extra delay, order preserved.
        let jitter = DispatchTimeInterval.milliseconds(Int.random(in: 0...12))
        let at = max(lastSendAt, .now() + jitter)
        lastSendAt = at
        queue.asyncAfter(deadline: at) { live.sendWireless(.videoFrame, frame.encoded()) }
    }

    /// BGRA test card: warm field with a moving white bar (center bright).
    static func makeFrame(width: Int, height: Int, index: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return buffer }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bar = (index * 7) % max(1, width)
        var row = [UInt8](repeating: 0, count: width * 4)
        for x in 0..<width {
            let lit = abs(x - bar) < 12
            row[x * 4 + 0] = lit ? 255 : 60
            row[x * 4 + 1] = lit ? 255 : 150
            row[x * 4 + 2] = 255
            row[x * 4 + 3] = 255
        }
        for y in 0..<height {
            row.withUnsafeBufferPointer { memcpy(base.advanced(by: y * stride), $0.baseAddress!, width * 4) }
        }
        return buffer
    }

    // MARK: App audio

    func startAudio(sampleRate: Double, channels: Int, frequency: Double) {
        queue.async { [self] in
            guard let live else { return }
            live.sendWireless(.audioFormat, WirelessJSON.encode(WirelessAudioFormat(sampleRate: sampleRate, channels: channels)))
            audioStartPTS = WirelessDevice.hostTimeNanos() + remoteClockOffset
            audioFramesSent = 0
            let chunk = 1024
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Double(chunk) / sampleRate)
            timer.setEventHandler { [weak self] in
                guard let self, let live = self.live else { return }
                var samples = Data(count: chunk * channels * 2)
                samples.withUnsafeMutableBytes { raw in
                    let out = raw.bindMemory(to: Int16.self)
                    for i in 0..<chunk {
                        let t = Double(self.audioFramesSent + Int64(i)) / sampleRate
                        let v = Int16(sin(2 * .pi * frequency * t) * 12_000)
                        for c in 0..<channels { out[i * channels + c] = v.littleEndian }
                    }
                }
                let pts = self.audioStartPTS + Int64(Double(self.audioFramesSent) / sampleRate * 1e9)
                self.audioFramesSent += Int64(chunk)
                live.sendWireless(.audioPCM, WirelessAudioChunk(pts: pts, frameCount: UInt32(chunk), samples: samples).encoded())
            }
            audioTimer = timer
            timer.resume()
        }
    }
}

// MARK: - Mic tone (the injected Mac microphone)

nonisolated final class MicTone: @unchecked Sendable {
    private let frequency: Double
    private let queue = DispatchQueue(label: "so.capturecat.CaptureCat.micTone")
    private var timer: DispatchSourceTimer?
    private var frames: Int64 = 0

    init(frequency: Double) { self.frequency = frequency }

    func start(_ deliver: @escaping @Sendable (CMSampleBuffer) -> Void) {
        let rate = 48_000.0
        let chunk = 960
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Double(chunk) / rate)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
            buffer.frameLength = AVAudioFrameCount(chunk)
            let data = buffer.floatChannelData![0]
            for i in 0..<chunk {
                data[i] = Float(sin(2 * .pi * self.frequency * Double(self.frames + Int64(i)) / rate) * 0.3)
            }
            self.frames += Int64(chunk)
            // Stamped like AVCapture stamps mic buffers: the host clock, now.
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
            guard let description else { return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: now, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                 formatDescription: description, sampleCount: chunk, sampleTimingEntryCount: 1,
                                 sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            guard let sample else { return }
            CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                           flags: 0, bufferList: buffer.audioBufferList)
            deliver(sample)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Reading a segment back

nonisolated struct MovieInfo {
    var size: CGSize = .zero
    var duration: Double = 0
    var videoSamples = 0
    var videoMonotonic = false
    var audioChannels: [Int] = []
    var audioRMS: [Double] = []
    var audioDurations: [Double] = []

    static func read(_ url: URL) async -> MovieInfo {
        var info = MovieInfo()
        let asset = AVURLAsset(url: url)
        info.duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            info.size = (try? await video.load(.naturalSize)) ?? .zero
            if let reader = try? AVAssetReader(asset: asset) {
                let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
                reader.add(output)
                reader.startReading()
                var last = CMTime.negativeInfinity
                var monotonic = true
                while let sample = output.copyNextSampleBuffer() {
                    guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if CMTimeCompare(pts, last) <= 0 { monotonic = false }
                    last = pts
                    info.videoSamples += 1
                }
                info.videoMonotonic = monotonic
            }
        }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        for track in audio {
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            let channels = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 0
            info.audioChannels.append(Int(channels))
            info.audioDurations.append((try? await track.load(.timeRange)).map { CMTimeGetSeconds($0.duration) } ?? 0)
            var sum = 0.0
            var count = 0
            if let reader = try? AVAssetReader(asset: asset) {
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                ])
                reader.add(output)
                reader.startReading()
                while let sample = output.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    var floats = [Float](repeating: 0, count: length / 4)
                    floats.withUnsafeMutableBytes { raw in
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                    }
                    for v in floats { sum += Double(v * v) }
                    count += floats.count
                }
            }
            info.audioRMS.append(count > 0 ? (sum / Double(count)).squareRoot() : 0)
        }
        return info
    }

    struct Frame {
        let image: CGImage
        let bytes: [UInt8]
        let width: Int
        let height: Int

        /// 0…1 luma at a normalized point (y down).
        func luma(x: Double, y: Double) -> Double {
            let px = min(width - 1, max(0, Int(x * Double(width))))
            let py = min(height - 1, max(0, Int(y * Double(height))))
            let i = (py * width + px) * 4
            return (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255
        }
    }

    static func frame(_ url: URL, at seconds: Double) async -> Frame? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Frame(image: image, bytes: bytes, width: width, height: height)
    }
}
