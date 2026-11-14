// The REAL iOS sender (Core/WirelessMacClient + Broadcast/StreamEncoder) ↔ the
// REAL Mac receiver (apps/macos/.../Wireless/WirelessServer + WirelessVideoDecoder),
// over Bonjour + TLS-PSK on this Mac. Two independent implementations of the
// shared contract talking to each other. Run by apps/ios/scripts/mac-interop.sh.
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Network

nonisolated(unsafe) var failures = 0
nonisolated func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS  \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

/// Stands in for the recorder: what the Mac would write.
nonisolated final class Sink: WirelessMediaSink, @unchecked Sendable {
    let lock = NSLock()
    var frames: [(CMTime, Int, Int, Bool)] = []
    func wirelessDidDecode(_ pixelBuffer: CVPixelBuffer, hostTime: CMTime, isKeyframe: Bool) {
        lock.lock(); frames.append((hostTime, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), isKeyframe)); lock.unlock()
    }
    func wirelessDidReceiveAudio(_ chunk: WirelessAudioChunk, format: WirelessAudioFormat, hostTime: CMTime) {}
}

nonisolated func frame(_ w: Int, _ h: Int, _ shade: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!)!, Int32(shade), CVPixelBufferGetDataSize(pb!))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

nonisolated func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

nonisolated func run() async {
    let link = WirelessLink(key: Data((0..<32).map { UInt8(($0 * 7) & 0xff) }))!
    let macID = UUID().uuidString.lowercased()
    let server = WirelessServer(link: link, macID: macID, macName: "Interop Mac")
    do { try server.start(advertise: true) } catch { check(false, "Mac WirelessServer started: \(error)"); return }
    let listening = await waitUntil(5) { server.port != nil }
    check(listening, "Mac WirelessServer listening + advertising (port \(server.port ?? 0))")

    let deviceID = UUID().uuidString // UPPERCASE, as the phone sends it
    func hello(_ role: String) -> WirelessHello {
        WirelessHello(role: role, deviceID: deviceID, deviceName: "Interop iPhone", model: "iPhone18,1", systemVersion: "27.0",
                      appVersion: "1.0 (1)", screenWidth: 390, screenHeight: 844, screenScale: 3)
    }

    // ── 1. The app is open: presence connection.
    let app = WirelessMacClient(role: WirelessDevice.roleApp, hello: { hello(WirelessDevice.roleApp) })
    nonisolated(unsafe) var gotRequest = false
    app.onControl = { if $0.command == WirelessControl.requestBroadcast.command { gotRequest = true } }
    app.start(link: link, preferredMacID: macID)
    check(await waitUntil(15) { server.snapshots().first?.hasApp == true }, "Mac lists the phone as soon as the app is open (role app)")
    let snap = server.snapshots().first
    check(snap?.key == deviceID.lowercased() && snap?.name == "Interop iPhone", "Mac keys the phone by lowercase deviceID")

    // ── 2. The Mac user picks it → requestBroadcast reaches the app.
    check(server.requestBroadcast(from: deviceID), "Mac sends requestBroadcast on the app connection")
    check(await waitUntil(5) { gotRequest }, "iPhone app receives requestBroadcast")

    // ── 3. The broadcast extension connects: same phone, now streaming.
    let encoder = StreamEncoder()
    let broadcast = WirelessMacClient(role: WirelessDevice.roleBroadcast, hello: { hello(WirelessDevice.roleBroadcast) })
    encoder.onFormat = { broadcast.send(.videoFormat, WirelessJSON.encode($0)) }
    encoder.onFrame = { broadcast.send(.videoFrame, $0.encoded()) }
    nonisolated(unsafe) var keyframeAsks = 0
    nonisolated(unsafe) var recordingState: Bool?
    broadcast.onControl = { control in
        if control.command == WirelessControl.keyframe.command { keyframeAsks += 1; encoder.requestKeyframe() }
        if control.command == "state" { recordingState = control.recording }
    }
    broadcast.onStateChange = { if case .connected = $0 { encoder.restartStream() } }
    broadcast.start(link: link, preferredMacID: macID)
    check(await waitUntil(15) { broadcast.isConnected }, "broadcast extension connected to the real Mac receiver")

    let start = WirelessDevice.hostTimeNanos()
    var i = 0
    func pump(_ count: Int, _ orientation: CGImagePropertyOrientation) async {
        for _ in 0..<count {
            encoder.encode(frame(390, 844, UInt8(i % 255)), pts: CMTime(value: start + Int64(i) * 33_333_333, timescale: 1_000_000_000), orientation: orientation)
            i += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }
    await pump(20, .up)
    let phones = server.snapshots()
    check(phones.count == 1 && phones[0].hasApp && phones[0].hasBroadcast, "app + broadcast with the same id = ONE phone on the Mac")
    check(await waitUntil(3) { server.snapshots().first?.isStreaming == true }, "Mac decoded a keyframe → phone is recordable")
    check(server.latestFrame(for: deviceID) != nil, "live-monitor frame available on the Mac")

    // ── 4. The Mac starts recording it: keyframe + state(recording) → media to the recorder.
    let sink = Sink()
    server.attach(sink: sink, to: deviceID)
    await pump(40, .up)
    await pump(30, .right)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    sink.lock.lock(); let got = sink.frames; sink.lock.unlock()
    // The recorder receives DECODED pictures (complete images whatever the
    // frame type); what matters is that the keyframe the Mac asks for at
    // segment start is honoured promptly.
    let firstKey = got.firstIndex { $0.3 }
    check(keyframeAsks >= 1 && firstKey.map { $0 <= 3 } == true, "keyframe the Mac asked for at segment start arrives promptly (frame #\(firstKey ?? -1), \(keyframeAsks) ask(s))")
    check(recordingState == true, "phone told it is being recorded (state)")
    check(got.count >= 65, "recorder received \(got.count) of 70 frames")
    let times = got.map { $0.0.seconds }
    check(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "host timestamps strictly increase on the Mac clock")
    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    check(times.last.map { abs(now - $0) < 3 } == true, "timestamps mapped onto the Mac host clock (Δ \(String(format: "%.2f", now - (times.last ?? 0))) s)")
    check(got.contains { $0.1 == 390 && $0.2 == 844 } && got.contains { $0.1 == 844 && $0.2 == 390 }, "rotation reaches the Mac as upright 844×390 frames")

    let stats = server.snapshotStats()
    check(stats.decodeErrors == 0, "Mac decode errors: \(stats.decodeErrors)")

    // ── 5. The broadcast stops: the phone stays listed via the app connection.
    broadcast.stop(reason: "broadcastFinished")
    encoder.invalidate()
    check(await waitUntil(5) { server.snapshots().first.map { !$0.hasBroadcast && $0.hasApp } == true }, "broadcast end → phone still listed through the app")
    app.stop()
    check(await waitUntil(5) { server.snapshots().first?.hasApp != true }, "app closed → presence gone")
    server.stop()
}

await run()
print(failures == 0 ? "MAC INTEROP: ALL PASS" : "MAC INTEROP: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
