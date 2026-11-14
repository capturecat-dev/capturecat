//  WirelessDeviceProtocol.swift
//
//  "iPhone over Wi-Fi" — the wire contract between an iPhone running the
//  CaptureCat iOS app's broadcast extension (the SENDER) and CaptureCat for
//  Mac (the RECEIVER), which records the stream exactly like a cabled iPhone:
//  a `.device` source segment, stitched into the take, drawn with the bezel.
//
//  ONE SOURCE OF TRUTH, THREE TARGETS. This file lives in the Mac tree's
//  `CaptureCat/Shared/` folder: the Mac target compiles it through its
//  synchronized group, and apps/ios/CaptureCat.xcodeproj compiles the very
//  same file (iOS app = pairing, broadcast extension = sender). Everything in
//  `CaptureCat/Shared/` MUST build for iOS too — Foundation, Network,
//  CryptoKit, Security only; never AppKit/UIKit, never app types.
//
//  Transport
//  ---------
//  • Linking is by ACCOUNT, not by pairing: a Mac and an iPhone signed in to
//    the same CaptureCat account trust each other automatically. The API keeps
//    one random 256-bit "device link key" per account (`GET /api/wireless/link`,
//    native apps only — Bearer sessions, never cookies or agent tokens;
//    `POST /api/wireless/link/rotate` = "Forget my devices"). Both apps cache
//    it in the Keychain so the link keeps working offline.
//  • Discovery: the Mac advertises Bonjour `_ccwireless._tcp` (service name =
//    the Mac's name) with TXT `id=<macID>` `a=<keyID>` `v=<protocol version>`.
//    `keyID` is a one-way fingerprint of the account's key
//    (`WirelessLink.keyID(for:)`), so an iPhone only connects to Macs on its
//    own account and the key itself never appears on the network.
//  • Security: TLS with that pre-shared key (TLS_PSK_WITH_AES_128_GCM_SHA256),
//    identity `capturecat-wireless-v1:<keyID>`. A peer without the key cannot
//    complete the handshake, so nobody else on the Wi-Fi can watch a stream
//    or push one. After a rotation, a device holding the old key fails the
//    handshake, refetches the link once, and retries.
//  • Framing: `WirelessFramer` — 8-byte header (type UInt32 BE, length UInt32
//    BE) then `length` payload bytes. Max payload `WirelessDevice.maxMessageBytes`.
//
//  Conversation
//  ------------
//  Two kinds of connection, told apart by `WirelessHello.role`:
//  • "app" — the iOS app is OPEN on a phone of the account. A presence-only
//    connection (no media): the Mac lists the phone as available right away,
//    and if the user picks it the Mac sends control "requestBroadcast"; the
//    app then shows the system Start Broadcast sheet (iOS requires a tap on
//    the phone to start screen capture — there is no silent start).
//  • "broadcast" — the ReplayKit broadcast extension, streaming media.
//  Both carry the same deviceID, so the Mac shows one phone, not two.
//
//  iPhone → Mac   hello        JSON WirelessHello            (first message)
//  Mac → iPhone   macHello     JSON WirelessMacHello         (reply)
//  iPhone → Mac   videoFormat  JSON WirelessVideoFormat      (before the first
//                              frame and whenever dimensions change, e.g. the
//                              phone rotates; always followed by a keyframe)
//  iPhone → Mac   videoFrame   binary WirelessVideoFrame     (AVCC samples)
//  iPhone → Mac   audioFormat  JSON WirelessAudioFormat      (app audio, optional)
//  iPhone → Mac   audioPCM     binary WirelessAudioChunk
//  Mac → iPhone   control      JSON WirelessControl          ("keyframe" when the
//                              Mac starts recording a segment or lost sync;
//                              "state" tells the phone whether it is recording;
//                              "requestBroadcast" to an "app" connection asks
//                              the phone to offer the Start Broadcast sheet)
//  either way     bye          JSON WirelessBye              (orderly close)
//
//  Frames are UPRIGHT (the sender rotates ReplayKit buffers before encoding),
//  so the receiver never needs per-frame orientation. Timestamps are
//  nanoseconds on the SENDER's host clock; the receiver maps them onto its
//  own host clock with `WirelessClockMapper` (minimum observed offset).

import CryptoKit
import Foundation
import Network
import Security

// MARK: - Constants

nonisolated enum WirelessDevice {
    /// Bonjour service type. Must also be listed in NSBonjourServices (iOS app,
    /// iOS broadcast extension, Mac app) — iOS refuses to browse undeclared types.
    static let serviceType = "_ccwireless._tcp"
    static let protocolVersion: UInt32 = 1
    static let roleApp = "app"
    static let roleBroadcast = "broadcast"
    /// Upper bound for one framed message. A 4K keyframe at a high bitrate is
    /// well under this; anything larger is a broken or hostile peer.
    static let maxMessageBytes = 8 * 1024 * 1024
    static let pskIdentityPrefix = "capturecat-wireless-v1:"
    static let txtMacIDKey = "id"
    static let txtKeyIDKey = "a"
    static let txtVersionKey = "v"

    /// Nanoseconds on this machine's host clock (mach_absolute_time domain,
    /// the clock CMClockGetHostTimeClock and ReplayKit sample PTS use).
    static func hostTimeNanos() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    /// TXT record the Mac advertises.
    static func txtRecord(macID: String, link: WirelessLink) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[txtMacIDKey] = macID.lowercased()
        txt[txtKeyIDKey] = link.keyID
        txt[txtVersionKey] = String(protocolVersion)
        return txt
    }

    /// The Mac id advertised by a browse result (nil for a result without TXT).
    static func macID(of result: NWBrowser.Result) -> String? {
        if case let .bonjour(txt) = result.metadata { return txt[txtMacIDKey] }
        return nil
    }

    /// The account-key fingerprint advertised by a browse result.
    static func keyID(of result: NWBrowser.Result) -> String? {
        if case let .bonjour(txt) = result.metadata { return txt[txtKeyIDKey] }
        return nil
    }

    /// TLS-PSK + TCP + framer parameters. Both ends call this with the SAME
    /// account link; a different key fails the handshake.
    static func parameters(link: WirelessLink) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secret = link.key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data((pskIdentityPrefix + link.keyID).utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            secret as __DispatchData,
            identity as __DispatchData
        )
        // TLS_PSK_WITH_AES_128_GCM_SHA256 (RFC 5487, 0x00A8) — the suite
        // Apple's peer-to-peer Network.framework sample uses for PSK.
        if let suite = tls_ciphersuite_t(rawValue: 0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
        }

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.noDelay = true

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        let framer = NWProtocolFramer.Options(definition: WirelessFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        return params
    }
}

// MARK: - Account link

/// The account's device link key, as `GET /api/wireless/link` returns it
/// (`{ "key": "<base64url 32 bytes>", "keyId": "<16 hex>", "createdAt": … }`).
/// Every native app signed in to the account holds the same one.
nonisolated struct WirelessLink: Codable, Equatable, Sendable {
    var key: Data

    static let keyByteCount = 32

    init?(key: Data) {
        guard key.count == Self.keyByteCount else { return nil }
        self.key = key
    }

    /// Decode the API's base64url key (nil unless exactly 32 bytes).
    init?(base64URLKey: String) {
        guard let data = Self.data(base64URL: base64URLKey) else { return nil }
        self.init(key: data)
    }

    /// One-way fingerprint advertised in Bonjour TXT and used as the PSK
    /// identity: first 8 bytes of SHA-256("capturecat-wireless-link-v1" ‖ key),
    /// lowercase hex. The API computes the same value (`keyId`) — a mismatch
    /// means a client decoded the key wrong.
    var keyID: String { Self.keyID(for: key) }

    static func keyID(for key: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("capturecat-wireless-link-v1".utf8))
        hasher.update(data: key)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL value: String) -> Data? {
        var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

// MARK: - Framing

nonisolated enum WirelessMessageType: UInt32, Sendable {
    case hello = 1
    case macHello = 2
    case videoFormat = 3
    case videoFrame = 4
    case audioFormat = 5
    case audioPCM = 6
    case control = 7
    case bye = 8
}

/// Type + length framing over the TLS stream (the shape of Apple's
/// NWProtocolFramer sample). Unknown types are delivered as-is with a nil
/// `wirelessType`, so a newer peer's extra messages are skippable.
nonisolated final class WirelessFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: WirelessFramer.self)
    static var label: String { "CaptureCatWireless" }
    static let headerSize = 8

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        var header = Data(capacity: Self.headerSize)
        header.appendBigEndian(message.wirelessRawType)
        header.appendBigEndian(UInt32(messageLength))
        framer.writeOutput(data: header)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var type: UInt32 = 0
            var length: UInt32 = 0
            let parsed = framer.parseInput(
                minimumIncompleteLength: Self.headerSize,
                maximumLength: Self.headerSize
            ) { buffer, _ in
                guard let buffer, buffer.count >= Self.headerSize else { return 0 }
                type = buffer.loadBigEndianUInt32(at: 0)
                length = buffer.loadBigEndianUInt32(at: 4)
                return Self.headerSize
            }
            guard parsed else { return Self.headerSize }
            guard Int(length) <= WirelessDevice.maxMessageBytes else {
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
            }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            message["type"] = type
            if !framer.deliverInputNoCopy(length: Int(length), message: message, isComplete: true) {
                return 0
            }
        }
    }
}

nonisolated extension NWProtocolFramer.Message {
    convenience init(wirelessType: WirelessMessageType) {
        self.init(definition: WirelessFramer.definition)
        self["type"] = wirelessType.rawValue
    }

    var wirelessRawType: UInt32 { (self["type"] as? UInt32) ?? 0 }
    var wirelessType: WirelessMessageType? { WirelessMessageType(rawValue: wirelessRawType) }
}

nonisolated extension NWConnection {
    /// Send one framed message. `completion` fires once the bytes are handed to
    /// the stack (use it for backpressure: count bytes in flight).
    func sendWireless(
        _ type: WirelessMessageType,
        _ payload: Data,
        completion: (@Sendable (NWError?) -> Void)? = nil
    ) {
        let message = NWProtocolFramer.Message(wirelessType: type)
        let context = NWConnection.ContentContext(identifier: "cc.\(type.rawValue)", metadata: [message])
        send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    /// Receive framed messages until the connection fails or `handler`
    /// returns false. `type` is nil for an unknown (newer) message type.
    func receiveWireless(_ handler: @escaping @Sendable (WirelessMessageType?, Data) -> Bool, onEnd: @escaping @Sendable (NWError?) -> Void) {
        receiveMessage { [weak self] content, context, _, error in
            if let error { onEnd(error); return }
            let message = context?.protocolMetadata(definition: WirelessFramer.definition) as? NWProtocolFramer.Message
            guard let message else { onEnd(nil); return }
            guard handler(message.wirelessType, content ?? Data()) else { return }
            self?.receiveWireless(handler, onEnd: onEnd)
        }
    }
}

// MARK: - Payloads

/// iPhone → Mac, first message.
nonisolated struct WirelessHello: Codable, Equatable, Sendable {
    var protocolVersion: UInt32 = WirelessDevice.protocolVersion
    /// "app" (presence only, the iOS app is open) or "broadcast" (media).
    var role: String
    /// Stable per phone install (the iOS app mints and keeps it; the
    /// broadcast extension reads the same value from the App Group).
    var deviceID: String
    /// User-facing name ("Mike's iPhone"; iOS may only reveal "iPhone").
    var deviceName: String
    /// Hardware identifier, e.g. "iPhone18,1".
    var model: String
    var systemVersion: String
    var appVersion: String
    /// Native screen size in PIXELS, portrait.
    var screenWidth: Int
    var screenHeight: Int
    var screenScale: Double
}

/// Mac → iPhone, reply to hello.
nonisolated struct WirelessMacHello: Codable, Equatable, Sendable {
    var protocolVersion: UInt32 = WirelessDevice.protocolVersion
    var macID: String
    var macName: String
    var appVersion: String
    /// Whether the Mac is recording this phone right now.
    var recording: Bool
}

/// iPhone → Mac: the encoder's configuration. Sent before the first frame and
/// again whenever it changes (rotation); the next frame is always a keyframe.
nonisolated struct WirelessVideoFormat: Codable, Equatable, Sendable {
    /// "avc1" (H.264) or "hvc1" (HEVC).
    var codec: String
    /// Encoded (upright) dimensions in pixels.
    var width: Int
    var height: Int
    /// Parameter sets without start codes: SPS, PPS for H.264; VPS, SPS, PPS for HEVC.
    var parameterSets: [Data]
    var frameRate: Double
}

/// iPhone → Mac: one compressed video sample.
/// Wire layout: pts Int64 BE | flags UInt32 BE (bit 0 = keyframe) | data.
nonisolated struct WirelessVideoFrame: Equatable, Sendable {
    /// Presentation time, ns on the sender's host clock.
    var pts: Int64
    var isKeyframe: Bool
    /// AVCC/HVCC sample: NAL units, each prefixed by a 4-byte big-endian length.
    var data: Data

    static let headerSize = 12

    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + data.count)
        out.appendBigEndian(UInt64(bitPattern: pts))
        out.appendBigEndian(UInt32(isKeyframe ? 1 : 0))
        out.append(data)
        return out
    }

    init(pts: Int64, isKeyframe: Bool, data: Data) {
        self.pts = pts
        self.isKeyframe = isKeyframe
        self.data = data
    }

    init?(decoding payload: Data) {
        guard payload.count > Self.headerSize else { return nil }
        let bytes = [UInt8](payload.prefix(Self.headerSize))
        pts = Int64(bitPattern: bytes.loadBigEndianUInt64(at: 0))
        isKeyframe = (bytes.loadBigEndianUInt32(at: 8) & 1) == 1
        data = payload.subdata(in: payload.startIndex + Self.headerSize ..< payload.endIndex)
    }
}

/// iPhone → Mac: app-audio format. Always interleaved signed 16-bit LPCM.
nonisolated struct WirelessAudioFormat: Codable, Equatable, Sendable {
    var sampleRate: Double
    var channels: Int
}

/// iPhone → Mac: one block of app audio.
/// Wire layout: pts Int64 BE | frameCount UInt32 BE | Int16 interleaved samples (little-endian).
nonisolated struct WirelessAudioChunk: Equatable, Sendable {
    var pts: Int64
    var frameCount: UInt32
    var samples: Data

    static let headerSize = 12

    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + samples.count)
        out.appendBigEndian(UInt64(bitPattern: pts))
        out.appendBigEndian(frameCount)
        out.append(samples)
        return out
    }

    init(pts: Int64, frameCount: UInt32, samples: Data) {
        self.pts = pts
        self.frameCount = frameCount
        self.samples = samples
    }

    init?(decoding payload: Data) {
        guard payload.count >= Self.headerSize else { return nil }
        let bytes = [UInt8](payload.prefix(Self.headerSize))
        pts = Int64(bitPattern: bytes.loadBigEndianUInt64(at: 0))
        frameCount = bytes.loadBigEndianUInt32(at: 8)
        samples = payload.subdata(in: payload.startIndex + Self.headerSize ..< payload.endIndex)
    }
}

/// Mac → iPhone.
nonisolated struct WirelessControl: Codable, Equatable, Sendable {
    /// "keyframe" (send an IDR now), "state" (see `recording`), or
    /// "requestBroadcast" (to an "app" connection: offer Start Broadcast).
    var command: String
    var recording: Bool?

    static let keyframe = WirelessControl(command: "keyframe", recording: nil)
    static let requestBroadcast = WirelessControl(command: "requestBroadcast", recording: nil)
    static func state(recording: Bool) -> WirelessControl { WirelessControl(command: "state", recording: recording) }
}

/// Either way, before closing.
nonisolated struct WirelessBye: Codable, Equatable, Sendable {
    var reason: String
}

nonisolated enum WirelessJSON {
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Clock mapping

/// Maps sender host-clock nanoseconds onto the receiver's host clock.
/// offset = local receipt − remote pts; the MINIMUM seen is the sample with
/// the least network/encode delay, so `remote + minOffset` is the earliest
/// local time consistent with every observation. Crystal drift between two
/// machines is a few ppm (≈ms per ten minutes) — below a frame for any take.
nonisolated struct WirelessClockMapper: Sendable {
    private(set) var minOffset: Int64?

    mutating func observe(remotePTS: Int64, localReceipt: Int64) {
        let offset = localReceipt - remotePTS
        if let current = minOffset { minOffset = min(current, offset) } else { minOffset = offset }
    }

    func localTime(forRemote pts: Int64) -> Int64? {
        minOffset.map { pts + $0 }
    }

    mutating func reset() { minOffset = nil }
}

// MARK: - Byte helpers

nonisolated extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

nonisolated extension UnsafeMutableRawBufferPointer {
    func loadBigEndianUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(self[offset + i]) }
        return value
    }
}

nonisolated extension Array where Element == UInt8 {
    func loadBigEndianUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(self[offset + i]) }
        return value
    }

    func loadBigEndianUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(self[offset + i]) }
        return value
    }
}
