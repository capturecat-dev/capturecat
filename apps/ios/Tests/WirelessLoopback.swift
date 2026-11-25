// iPhone-over-Wi-Fi, end to end on one Mac: the REAL iOS sender code
// (Core/WirelessMacClient.swift + Broadcast/StreamEncoder.swift + the shared
// WirelessDeviceProtocol.swift) streams synthetic screen frames to a test
// listener that plays the Mac's side of the contract (TLS-PSK, Bonjour TXT,
// framing, hello/macHello, control keyframe) and DECODES what arrives with
// VideoToolbox. Run by apps/ios/scripts/wireless-loopback.sh.
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Network
import VideoToolbox

nonisolated(unsafe) var failures = 0
nonisolated func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS  \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

/// What the test "Mac" saw.
nonisolated final class Receiver: @unchecked Sendable {
    let lock = NSLock()
    var hello: WirelessHello?
    var formats: [WirelessVideoFormat] = []
    var frames = 0
    var keyframes = 0
    var decoded = 0
    var decodedSizes: [CGSize] = []
    var lastPTS: Int64 = .min
    var monotonic = true
    var keyframesAfterRequest = 0
    var requestedKeyframe = false
    var decompression: VTDecompressionSession?
    var formatDescription: CMVideoFormatDescription?
    var connections: [NWConnection] = []
    var helloCount = 0

    func makeDecoder(_ format: WirelessVideoFormat) {
        let sets = format.parameterSets
        var description: CMFormatDescription?
        let pointers = sets.map { ($0 as NSData).bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = sets.map(\.count)
        let status = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
                                                                    parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        if let old = decompression { VTDecompressionSessionInvalidate(old) }
        formatDescription = description
        var session: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                     imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        decompression = session
    }

    func decode(_ frame: WirelessVideoFrame) {
        guard let session = decompression, let description = formatDescription else { return }
        var block: CMBlockBuffer?
        let data = frame.data
        let length = data.count
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: frame.pts, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var size = length
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            lock.lock()
            decoded += 1
            decodedSizes.append(CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)))
            lock.unlock()
        }
    }
}

nonisolated func makeFrame(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<height {
        for x in 0..<width {
            let p = base + y * stride + x * 4
            p[0] = UInt8((x * 255) / width); p[1] = shade; p[2] = UInt8((y * 255) / height); p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

nonisolated func run() async {
    let link = WirelessLink(key: Data((0..<32).map { UInt8(255 - $0) }))!
    let macID = UUID().uuidString.lowercased()
    let receiver = Receiver()
    let queue = DispatchQueue(label: "test.mac")

    // ── the test "Mac": TLS-PSK listener advertising the account fingerprint
    let listener = try! NWListener(using: WirelessDevice.parameters(link: link))
    listener.service = NWListener.Service(name: "Test Mac \(macID.prefix(4))", type: WirelessDevice.serviceType, domain: nil,
                                          txtRecord: WirelessDevice.txtRecord(macID: macID, link: link))
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { connection in
        receiver.lock.lock(); receiver.connections.append(connection); receiver.lock.unlock()
        connection.start(queue: queue)
        connection.receiveWireless({ type, payload in
            switch type {
            case .hello:
                let hello = WirelessJSON.decode(WirelessHello.self, from: payload)
                receiver.lock.lock(); receiver.hello = hello; receiver.helloCount += 1; receiver.lock.unlock()
                connection.sendWireless(.macHello, WirelessJSON.encode(WirelessMacHello(macID: macID, macName: "Test Mac", appVersion: "test", recording: false)))
            case .videoFormat:
                if let format = WirelessJSON.decode(WirelessVideoFormat.self, from: payload) {
                    receiver.lock.lock(); receiver.formats.append(format); receiver.lock.unlock()
                    receiver.makeDecoder(format)
                }
            case .videoFrame:
                if let frame = WirelessVideoFrame(decoding: payload) {
                    receiver.lock.lock()
                    receiver.frames += 1
                    if frame.isKeyframe { receiver.keyframes += 1; if receiver.requestedKeyframe { receiver.keyframesAfterRequest += 1 } }
                    if frame.pts <= receiver.lastPTS { receiver.monotonic = false }
                    receiver.lastPTS = frame.pts
                    receiver.lock.unlock()
                    receiver.decode(frame)
                }
            default: break
            }
            return true
        }, onEnd: { _ in })
    }
    listener.start(queue: queue)
    check(ready.wait(timeout: .now() + 5) == .success, "TLS-PSK listener up + advertised (\(listener.port?.rawValue ?? 0))")

    // ── the REAL iOS sender: Bonjour browse by keyID → connect → hello
    let hello = WirelessHello(role: WirelessDevice.roleBroadcast, deviceID: UUID().uuidString, deviceName: "Test iPhone", model: "iPhone18,1",
                              systemVersion: "27.0", appVersion: "1.0 (1)", screenWidth: 390, screenHeight: 844, screenScale: 3)
    let client = WirelessMacClient(role: WirelessDevice.roleBroadcast, hello: { hello })
    let connected = DispatchSemaphore(value: 0)
    let found = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var macName = ""
    client.onMacsChanged = { macs in if macs.contains(where: { $0.id == macID }) { found.signal() } }
    client.onStateChange = { state in if case let .connected(_, h) = state { macName = h.macName; connected.signal() } }
    let encoder = StreamEncoder()
    encoder.onFormat = { client.send(.videoFormat, WirelessJSON.encode($0)) }
    encoder.onFrame = { client.send(.videoFrame, $0.encoded()) }
    client.onControl = { if $0.command == WirelessControl.keyframe.command { encoder.requestKeyframe() } }
    client.start(link: link, preferredMacID: macID)
    let browsed = found.wait(timeout: .now() + 15) == .success
    check(browsed, "Bonjour browse found the Mac by account fingerprint (TXT a=\(link.keyID))")
    let isConnected = connected.wait(timeout: .now() + 15) == .success
    check(isConnected, "TLS-PSK handshake + hello/macHello (connected to \"\(macName)\")")
    guard isConnected else { return }
    receiver.lock.lock(); let gotHello = receiver.hello; receiver.lock.unlock()
    check(gotHello?.role == "broadcast" && gotHello?.screenHeight == 844, "Mac received the phone's hello (role broadcast)")
    encoder.restartStream()

    // ── stream 2 s of portrait frames at 30 fps, then 1 s rotated (.right → landscape)
    let start = WirelessDevice.hostTimeNanos()
    for i in 0..<90 {
        let pts = CMTime(value: start + Int64(i) * 33_333_333, timescale: 1_000_000_000)
        let orientation: CGImagePropertyOrientation = i < 60 ? .up : .right
        encoder.encode(makeFrame(width: 390, height: 844, shade: UInt8(i * 2)), pts: pts, orientation: orientation)
        if i == 30 {
            // The Mac starts recording mid-stream → asks for a keyframe.
            receiver.lock.lock(); receiver.requestedKeyframe = true; let c = receiver.connections.last; receiver.lock.unlock()
            c?.sendWireless(.control, WirelessJSON.encode(WirelessControl.keyframe))
        }
        try? await Task.sleep(nanoseconds: 33_000_000)
    }
    try? await Task.sleep(nanoseconds: 1_500_000_000)

    receiver.lock.lock()
    let r = (frames: receiver.frames, keys: receiver.keyframes, decoded: receiver.decoded, formats: receiver.formats,
             sizes: receiver.decodedSizes, mono: receiver.monotonic, keysAfter: receiver.keyframesAfterRequest)
    receiver.lock.unlock()
    print("      frames sent→received \(r.frames)/90, decoded \(r.decoded), keyframes \(r.keys), formats \(r.formats.map { "\($0.width)x\($0.height)" })")
    check(r.frames >= 85, "≥85 of 90 frames arrived")
    check(r.decoded >= r.frames - 2 && r.decoded > 0, "VideoToolbox decoded what arrived (\(r.decoded))")
    check(r.formats.first.map { $0.width == 390 && $0.height == 844 && $0.codec == "avc1" && $0.parameterSets.count >= 2 } == true, "first format: upright 390×844 H.264 with SPS+PPS")
    check(r.formats.contains { $0.width == 844 && $0.height == 390 }, "rotation re-announced the format as 844×390 (upright landscape)")
    check(r.sizes.contains(CGSize(width: 390, height: 844)) && r.sizes.contains(CGSize(width: 844, height: 390)), "decoded frames in both orientations")
    check(r.keysAfter >= 1, "keyframe control honoured")
    check(r.mono, "frame timestamps strictly increase")

    // ── a peer with a different account key cannot complete the handshake
    let wrong = WirelessLink(key: Data(repeating: 7, count: 32))!
    let rejected = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var wrongReady = false
    let intruder = NWConnection(host: "127.0.0.1", port: listener.port!, using: WirelessDevice.parameters(link: wrong))
    intruder.stateUpdateHandler = { state in
        switch state {
        case .ready: wrongReady = true; rejected.signal()
        case .failed, .waiting: rejected.signal()
        default: break
        }
    }
    intruder.start(queue: DispatchQueue(label: "intruder"))
    _ = rejected.wait(timeout: .now() + 10)
    intruder.cancel()
    receiver.lock.lock(); let hellos = receiver.helloCount; receiver.lock.unlock()
    check(!wrongReady && hellos == 1, "wrong account key is refused at the TLS handshake")

    // ── a phone with an out-of-date account key: the Mac shows up as "other",
    // is never contacted, and matches as soon as the key is refetched
    let seenOther = DispatchSemaphore(value: 0)
    let relinked = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var contactedEarly = false
    nonisolated(unsafe) var refreshedKey = false
    nonisolated(unsafe) var othersAfter: [String] = []
    let testName = "Test Mac \(macID.prefix(4))"
    let stale = WirelessMacClient(role: WirelessDevice.roleApp, hello: { hello })
    stale.onOtherMacsChanged = { names in
        othersAfter = names
        if names.contains(testName), !refreshedKey { seenOther.signal() }
    }
    stale.onStateChange = { state in
        switch state {
        case .connecting: if !refreshedKey { contactedEarly = true }
        case .connected: relinked.signal()
        default: break
        }
    }
    stale.start(link: wrong, preferredMacID: macID)
    check(seenOther.wait(timeout: .now() + 15) == .success, "out-of-date key: the Mac is reported as another account's")
    check(!contactedEarly, "… and never contacted")
    refreshedKey = true
    stale.start(link: link, preferredMacID: macID)
    check(relinked.wait(timeout: .now() + 15) == .success, "refetched key: matched and connected without a new browse")
    check(!othersAfter.contains(testName), "… and no longer reported as another account's")
    stale.stop(reason: "test done")

    check(WirelessMacClient.isLocalNetworkDenied(.dns(-65570)), "Bonjour PolicyDenied reads as Local Network off")
    check(!WirelessMacClient.isLocalNetworkDenied(.dns(-65563)) && !WirelessMacClient.isLocalNetworkDenied(.posix(.ENETDOWN)), "other browse errors don't")

    client.stop(reason: "test done")
    encoder.invalidate()
    listener.cancel()
}

await run()
print(failures == 0 ? "WIRELESS LOOPBACK: ALL PASS" : "WIRELESS LOOPBACK: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
