import Compression
import CoreGraphics
import Foundation

/// The camera person-mask track: `camera-mask.ccmask` beside `camera.mov` in
/// the project folder (docs/camera-cutout.md §2).
///
/// The cutout and pop-out card looks draw the webcam through this alpha mask.
/// It is the SHARED SOURCE OF TRUTH between the Mac app and the web editor:
/// whichever side segmented the camera (Vision here, MODNet in the browser)
/// writes this file, and both renderers read the identical decoded bytes. The
/// format is lossless, so decoded masks are bit-identical no matter which
/// encoder produced the compressed bytes.
///
/// Twin of apps/web/src/editor/core/mask/cameraMaskCodec.ts — keep the two
/// byte-for-byte compatible (`--web-vectors` writes a fixture made by THIS
/// encoder that the vitest suite decodes; `cameraMaskCodec` unit).
///
/// Layout (all integers little-endian):
///
///     offset size  field
///     0      4     magic "CCMK"
///     4      2     version (1)
///     6      2     width   (mask pixels)
///     8      2     height
///     10     2     keyframeInterval (a full frame at least this often)
///     12     4     frameCount
///     16     8     sourceDuration (f64 seconds of the camera video it was made from)
///     24     8     sourceByteSize (f64; the camera file's size, a staleness check)
///     32     16×N  index: per frame { time f64 (camera-source seconds), offset u32,
///                  lengthAndKind u32 } — the low 31 bits are the payload length,
///                  the high bit set means the payload is a DELTA.
///     …            payloads: raw DEFLATE (RFC 1951) of width×height bytes. A key
///                  frame holds alpha (0 = background, 255 = person); a delta holds
///                  alpha XOR the previous frame's alpha. The encoder stores
///                  whichever is smaller, but frame 0 is always a key and no frame
///                  is more than keyframeInterval − 1 deltas from its key.
///
/// Raw DEFLATE here is Apple's Compression framework `COMPRESSION_ZLIB`, which
/// is RFC 1951 with no zlib header — exactly the browser's `deflate-raw`.
nonisolated struct CameraMaskTrack: Sendable {
    static let magic: [UInt8] = Array("CCMK".utf8)
    static let version: UInt16 = 1
    static let headerBytes = 32
    static let indexEntryBytes = 16
    /// The file name inside a project folder.
    static let fileName = "camera-mask.ccmask"

    /// Mask resolution (contract §2): 192 rows; width follows the camera
    /// aspect, capped at 341 (16:9 → 341×192). Sized for the bubble, not the
    /// frame — measured on real Vision mattes, 192 rows show no edge loss at
    /// bubble sizes, and with producer alpha conditioning
    /// (`CameraMaskConditioning`) the track costs ≈ 1.5 MB per minute.
    static let maskHeight = 192
    static let maxMaskWidth = 341
    /// What both producers write. Conditioned mattes repeat most pixels, so
    /// deltas win almost every frame; a seek inflates at most this many
    /// (small) payloads.
    static let defaultKeyframeInterval = 30
    /// `|sourceDuration − camera duration|` a usable mask may differ by.
    static let durationTolerance: Double = 0.05

    private static let deltaBit: UInt32 = 0x8000_0000

    struct Header: Equatable, Sendable {
        var width: Int
        var height: Int
        var keyframeInterval: Int
        var frameCount: Int
        var sourceDuration: Double
        var sourceByteSize: Double
    }

    struct IndexEntry: Equatable, Sendable {
        var time: Double
        var offset: Int
        var length: Int
        /// XOR against the previous frame rather than a full alpha frame.
        var delta: Bool
    }

    struct CodecError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { "camera mask: \(message)" }
    }

    let header: Header
    let index: [IndexEntry]
    let bytes: Data
    /// Identity of this loaded instance — the preview's caches key on it.
    let token: UUID

    var pixelCount: Int { header.width * header.height }

    // MARK: - Parse

    init(data: Data) throws {
        let bytes = data.startIndex == 0 ? data : Data(data)
        guard bytes.count >= Self.headerBytes else { throw CodecError(message: "truncated header") }
        guard Array(bytes[0..<4]) == Self.magic else { throw CodecError(message: "bad magic") }
        let version = Self.u16(bytes, 4)
        guard version == Self.version else { throw CodecError(message: "unsupported version \(version)") }
        let header = Header(
            width: Int(Self.u16(bytes, 6)),
            height: Int(Self.u16(bytes, 8)),
            keyframeInterval: Int(Self.u16(bytes, 10)),
            frameCount: Int(Self.u32(bytes, 12)),
            sourceDuration: Self.f64(bytes, 16),
            sourceByteSize: Self.f64(bytes, 24)
        )
        guard header.width > 0, header.height > 0, header.keyframeInterval > 0 else {
            throw CodecError(message: "zero dimension or keyframe interval")
        }
        let indexEnd = Self.headerBytes + header.frameCount * Self.indexEntryBytes
        guard bytes.count >= indexEnd else { throw CodecError(message: "truncated index") }
        var index: [IndexEntry] = []
        index.reserveCapacity(header.frameCount)
        var lastTime = -Double.infinity
        for i in 0..<header.frameCount {
            let at = Self.headerBytes + i * Self.indexEntryBytes
            let lengthAndKind = Self.u32(bytes, at + 12)
            let entry = IndexEntry(
                time: Self.f64(bytes, at),
                offset: Int(Self.u32(bytes, at + 8)),
                length: Int(lengthAndKind & ~Self.deltaBit),
                delta: lengthAndKind & Self.deltaBit != 0
            )
            guard entry.time > lastTime else { throw CodecError(message: "frame times must increase") }
            if i == 0, entry.delta { throw CodecError(message: "the first frame must be a key frame") }
            guard entry.offset >= indexEnd, entry.offset + entry.length <= bytes.count else {
                throw CodecError(message: "payload out of range")
            }
            lastTime = entry.time
            index.append(entry)
        }
        self.header = header
        self.index = index
        self.bytes = bytes
        self.token = UUID()
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        d.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }

    private static func f64(_ d: Data, _ o: Int) -> Double {
        d.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self))) }
    }

    // MARK: - Lookup

    /// The frame showing at camera-source time t: the last frame with time
    /// ≤ t, clamped to the first frame before it. −1 for an empty track.
    /// (Line-for-line twin of the TS `frameIndexAt`, NaN included: NaN is not
    /// `< first`, and the bisection keeps `lo` = 0.)
    static func frameIndexAt(_ index: [IndexEntry], _ t: Double) -> Int {
        guard !index.isEmpty else { return -1 }
        if t < index[0].time { return 0 }
        var lo = 0
        var hi = index.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if index[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func frameIndex(at t: Double) -> Int { Self.frameIndexAt(index, t) }

    // MARK: - Size + staleness (contract §2)

    /// `height = 192`, `width = round(192 × aspect)` capped at 341 (16:9 →
    /// 341×192). The aspect is the camera image as decoded (pixel buffer
    /// width ÷ height). Never below 1×1.
    static func maskSize(cameraAspect: Double) -> (width: Int, height: Int) {
        let aspect = cameraAspect.isFinite && cameraAspect > 0 ? cameraAspect : 1
        let width = Int((Double(maskHeight) * aspect).rounded())
        return (max(1, min(maxMaskWidth, width)), maskHeight)
    }

    /// Usable only for the camera file it was made from: identical byte size
    /// and a duration within `durationTolerance`. A stale or missing mask
    /// renders every look as the plain bubble (both platforms, same rule).
    static func isFresh(_ header: Header, cameraByteSize: Int64, cameraDuration: Double) -> Bool {
        header.sourceByteSize == Double(cameraByteSize)
            && abs(header.sourceDuration - cameraDuration) <= durationTolerance
    }

    /// Where the mask of a camera file lives: beside it (the project folder).
    static func url(besideCamera cameraURL: URL) -> URL {
        cameraURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    // MARK: - Raw DEFLATE

    /// Inflates one payload, which must decode to exactly `expected` bytes.
    static func inflateRaw(_ src: Data, expected: Int) throws -> [UInt8] {
        guard expected > 0 else { return [] }
        // One spare byte: a payload that inflates LONGER than expected would
        // otherwise be silently truncated to exactly `expected`.
        var out = [UInt8](repeating: 0, count: expected + 1)
        let written = src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, base, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else {
            throw CodecError(message: "payload inflates to \(written) bytes, expected \(expected)")
        }
        out.removeLast()
        return out
    }

    static func deflateRaw(_ src: [UInt8]) throws -> Data {
        // Stored blocks cost 5 bytes per 64 KiB; the generous cap never binds.
        let capacity = src.count + src.count / 8 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let written = src.withUnsafeBufferPointer { s -> Int in
            out.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, d.count, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw CodecError(message: "deflate failed") }
        return Data(out[0..<written])
    }

    // MARK: - Decode

    /// Decodes frames with a one-frame cursor, so sequential playback inflates
    /// one payload per frame and a seek replays at most keyframeInterval
    /// frames. Not thread-safe: one owner per decoder.
    nonisolated final class Decoder {
        let track: CameraMaskTrack
        private var current = -1
        private(set) var alpha: [UInt8]

        init(track: CameraMaskTrack) {
            self.track = track
            self.alpha = [UInt8](repeating: 0, count: track.pixelCount)
        }

        var currentIndex: Int { current }

        private func payload(_ i: Int) throws -> [UInt8] {
            let entry = track.index[i]
            let slice = track.bytes.subdata(in: entry.offset..<(entry.offset + entry.length))
            return try CameraMaskTrack.inflateRaw(slice, expected: alpha.count)
        }

        /// The key frame frame i is built from (itself when it is a key).
        private func keyFor(_ i: Int) -> Int {
            var k = i
            while k > 0, track.index[k].delta { k -= 1 }
            return k
        }

        /// The alpha of frame i (width×height bytes, row 0 = top of the camera
        /// image as decoded, before any mirroring).
        @discardableResult
        func frame(_ i: Int) throws -> [UInt8] {
            guard i >= 0, i < track.header.frameCount else { throw CodecError(message: "no frame \(i)") }
            if i == current { return alpha }
            let key = keyFor(i)
            // Moving forward inside the same key's run: apply only the new deltas.
            let next = current >= key && current < i ? current + 1 : key
            current = -1
            for f in next...i {
                let body = try payload(f)
                if !track.index[f].delta {
                    alpha = body
                } else {
                    alpha.withUnsafeMutableBufferPointer { a in
                        body.withUnsafeBufferPointer { b in
                            for p in 0..<a.count { a[p] ^= b[p] }
                        }
                    }
                }
            }
            current = i
            return alpha
        }

        /// The alpha showing at camera-source time t.
        func alpha(at t: Double) throws -> (index: Int, alpha: [UInt8]) {
            let i = track.frameIndex(at: t)
            return (i, try frame(i))
        }
    }

    // MARK: - Encode

    /// Streaming encoder (the segmentation job appends one frame at a time and
    /// never holds the raw track). Same key/delta rule as the TS
    /// `encodeCameraMask`: frame 0 is a key; a delta is tried only while the
    /// run since the last key is shorter than keyframeInterval − 1, and kept
    /// only when its compressed payload is strictly smaller.
    nonisolated final class Encoder {
        let width: Int
        let height: Int
        let keyframeInterval: Int
        private var times: [Double] = []
        private var payloads: [Data] = []
        private var deltas: [Bool] = []
        private var previous: [UInt8]?
        private var sinceKey = 0

        init(width: Int, height: Int, keyframeInterval: Int = CameraMaskTrack.defaultKeyframeInterval) {
            self.width = width
            self.height = height
            self.keyframeInterval = max(1, keyframeInterval)
        }

        var frameCount: Int { times.count }
        var lastTime: Double? { times.last }

        func append(time: Double, alpha: [UInt8]) throws {
            let size = width * height
            guard alpha.count == size else {
                throw CodecError(message: "frame \(times.count) has \(alpha.count) bytes, expected \(size)")
            }
            if let last = times.last, !(time > last) { throw CodecError(message: "frame times must increase") }
            let key = try CameraMaskTrack.deflateRaw(alpha)
            var chosen = key
            var isDelta = false
            if let previous, sinceKey + 1 < keyframeInterval {
                var xor = [UInt8](repeating: 0, count: size)
                xor.withUnsafeMutableBufferPointer { x in
                    alpha.withUnsafeBufferPointer { a in
                        previous.withUnsafeBufferPointer { p in
                            for i in 0..<size { x[i] = a[i] ^ p[i] }
                        }
                    }
                }
                let delta = try CameraMaskTrack.deflateRaw(xor)
                if delta.count < key.count {
                    chosen = delta
                    isDelta = true
                }
            }
            sinceKey = isDelta ? sinceKey + 1 : 0
            times.append(time)
            payloads.append(chosen)
            deltas.append(isDelta)
            previous = alpha
        }

        func finish(sourceDuration: Double, sourceByteSize: Double) -> Data {
            let count = times.count
            let indexEnd = CameraMaskTrack.headerBytes + count * CameraMaskTrack.indexEntryBytes
            var out = Data(capacity: indexEnd + payloads.reduce(0) { $0 + $1.count })
            func put16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { out.append(contentsOf: $0) } }
            func put32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { out.append(contentsOf: $0) } }
            func putU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
            func putF64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) } }
            out.append(contentsOf: CameraMaskTrack.magic)
            put16(Int(CameraMaskTrack.version))
            put16(width)
            put16(height)
            put16(keyframeInterval)
            put32(count)
            putF64(sourceDuration)
            putF64(sourceByteSize)
            var offset = indexEnd
            for i in 0..<count {
                putF64(times[i])
                put32(offset)
                putU32(UInt32(payloads[i].count) | (deltas[i] ? CameraMaskTrack.deltaBit : 0))
                offset += payloads[i].count
            }
            for payload in payloads { out.append(payload) }
            return out
        }
    }

    /// Builds a whole track from full alpha frames (fixtures, vectors).
    static func encode(
        width: Int, height: Int, keyframeInterval: Int,
        sourceDuration: Double, sourceByteSize: Double,
        frames: [(time: Double, alpha: [UInt8])]
    ) throws -> Data {
        let encoder = Encoder(width: width, height: height, keyframeInterval: keyframeInterval)
        for frame in frames { try encoder.append(time: frame.time, alpha: frame.alpha) }
        return encoder.finish(sourceDuration: sourceDuration, sourceByteSize: sourceByteSize)
    }
}
