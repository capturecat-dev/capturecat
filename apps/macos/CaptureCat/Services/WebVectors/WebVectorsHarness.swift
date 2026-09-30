import Foundation
import CoreGraphics

/// `CaptureCat --web-vectors <dir> [--only unitA,unitB]` — golden vectors for
/// the web editor's TypeScript ports (apps/web/src/editor/core).
///
/// Every unit calls the REAL Swift function (never a copy, unless a unit's
/// notes say it is a verbatim oracle of math that only exists inline inside a
/// larger function) over deterministic pseudo-random inputs plus edge cases,
/// and writes `<dir>/<unit>.json`:
///
///     { "unit": "...", "notes": "...", "count": N,
///       "cases": [ { "input": {...}, "output": {...} }, ... ] }
///
/// Doubles are written with full round-trip precision (Swift's shortest
/// representation); NaN/±Infinity as the strings "NaN" / "Infinity" /
/// "-Infinity". The vitest suites under apps/web/src/editor/core/vectors
/// assert the TS port reproduces every output within 1e-9 (exact for ints,
/// strings, bools). `apps/web/scripts/sync-vectors.sh` copies the files into
/// the gitignored `apps/web/.fixtures/vectors/`.
///
/// The app is sandboxed: when `<dir>` is not writable the files land in
/// `NSTemporaryDirectory()/capturecat-web-vectors` — the path is printed.
/// Never reached in a normal launch.
enum WebVectorsHarness {
    static func run() -> Never {
        let args = CommandLine.arguments
        var requested: String?
        if let i = args.firstIndex(of: "--web-vectors"), args.indices.contains(i + 1),
           !args[i + 1].hasPrefix("--") {
            requested = (args[i + 1] as NSString).expandingTildeInPath
        }
        var only: Set<String>?
        if let i = args.firstIndex(of: "--only"), args.indices.contains(i + 1) {
            only = Set(args[i + 1].split(separator: ",").map { String($0) })
        }

        let dir = resolveOutputDirectory(requested)
        print("WEB-VECTORS dir=\(dir.path)")

        var failures = 0
        var written = 0
        var seen = Set<String>()
        for unit in WebVectors.all {
            if seen.contains(unit.name) {
                print("WEB-VECTORS FAIL duplicate unit name \(unit.name)")
                failures += 1
                continue
            }
            seen.insert(unit.name)
            if let only, !only.contains(unit.name) { continue }
            let cases = unit.build()
            guard !cases.isEmpty else {
                print("WEB-VECTORS FAIL \(unit.name): produced no cases")
                failures += 1
                continue
            }
            let file: WV = [
                "unit": .str(unit.name),
                "notes": .str(unit.notes),
                "count": .int(cases.count),
                "cases": .arr(cases),
            ]
            let url = dir.appendingPathComponent("\(unit.name).json")
            do {
                try Data(file.serialized().utf8).write(to: url, options: .atomic)
                written += 1
                print("WEB-VECTORS unit=\(unit.name) cases=\(cases.count)")
            } catch {
                print("WEB-VECTORS FAIL \(unit.name): \(error.localizedDescription)")
                failures += 1
            }
        }
        print("WEB-VECTORS \(failures == 0 ? "OK" : "FAILED") units=\(written) dir=\(dir.path)")
        exit(failures == 0 ? 0 : 1)
    }

    /// `<dir>` when writable; otherwise the container tmp:
    /// `capturecat-web-vectors` (no dir given) or
    /// `capturecat-web-vectors-<basename of dir>` — so concurrent generators
    /// with different names never overwrite each other.
    static func resolveOutputDirectory(_ requested: String?, prefix: String = "capturecat-web-vectors") -> URL {
        let fm = FileManager.default
        var fallbackName = prefix
        if let requested {
            // A bare/relative name lands in the container tmp (the sandboxed
            // process's cwd is the container root, which must stay clean).
            let url = requested.hasPrefix("/")
                ? URL(fileURLWithPath: requested, isDirectory: true)
                : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent(requested, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".web-vectors-probe-\(getpid())")
            if fm.createFile(atPath: probe.path, contents: Data()) {
                try? fm.removeItem(at: probe)
                return url
            }
            print("WEB-VECTORS note: \(url.path) not writable from the sandbox; using the container tmp")
            fallbackName += "-\(url.lastPathComponent)"
        }
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(fallbackName, isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}

// MARK: - Unit registry

/// One golden-vector unit: a name (the JSON file name and the TS suite key),
/// notes (which Swift source it locks), and a case builder.
struct WebVectorUnit {
    let name: String
    let notes: String
    let build: () -> [WV]
}

/// Units are grouped by cluster; each cluster lives in its own
/// `WebVectors+<Cluster>.swift` file so they can be developed independently.
enum WebVectors {
    static var all: [WebVectorUnit] {
        timeUnits
            + modelUnits
            + layoutUnits
            + cameraMotionUnits
            + cursorUnits
            + overlayUnits
            + regionUnits
            + styleUnits
    }

    /// One `{input, output}` case.
    static func vcase(_ input: WV, _ output: WV) -> WV {
        ["input": input, "output": output]
    }
}

// MARK: - JSON value

/// Ordered JSON value with full-precision doubles.
indirect enum WV {
    case num(Double)
    case int(Int)
    case str(String)
    case bool(Bool)
    case null
    case arr([WV])
    case obj([(String, WV)])

    func serialized() -> String {
        var out = ""
        out.reserveCapacity(1 << 16)
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .num(let d):
            if d.isNaN {
                out += "\"NaN\""
            } else if d.isInfinite {
                out += d > 0 ? "\"Infinity\"" : "\"-Infinity\""
            } else {
                // Swift's description is the shortest string that round-trips.
                out += "\(d)"
            }
        case .int(let i):
            out += "\(i)"
        case .str(let s):
            WV.writeString(s, into: &out)
        case .bool(let b):
            out += b ? "true" : "false"
        case .null:
            out += "null"
        case .arr(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .obj(let pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                WV.writeString(pair.0, into: &out)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Object field lookup (for fix-ups of encoded models).
    subscript(key: String) -> WV? {
        guard case .obj(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    /// Returns a copy with `key` replaced (or appended).
    func setting(_ key: String, _ value: WV) -> WV {
        guard case .obj(var pairs) = self else { return self }
        if let i = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[i].1 = value
        } else {
            pairs.append((key, value))
        }
        return .obj(pairs)
    }

    /// Returns a copy without `keys`.
    func removing(_ keys: String...) -> WV {
        guard case .obj(let pairs) = self else { return self }
        return .obj(pairs.filter { !keys.contains($0.0) })
    }

    /// Any Encodable, through the app's own JSONEncoder (so the shape is
    /// exactly what project.json stores), read back with JSONDecoder's
    /// number parser. (NSJSONSerialization mis-rounds some long decimal
    /// literals, e.g. "0.000006466452074693763", by an ulp — never use it to
    /// read numbers whose exact value matters.)
    static func encoded<T: Encodable>(_ value: T) -> WV {
        guard let data = try? JSONEncoder().encode(value),
              let json = try? JSONDecoder().decode(PreciseJSON.self, from: data) else {
            return .null
        }
        return json.wv
    }
}

/// A JSON value decoded with JSONDecoder (correctly-rounded doubles).
indirect enum PreciseJSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PreciseJSON])
    case object([String: PreciseJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([PreciseJSON].self) { self = .array(a); return }
        self = .object(try c.decode([String: PreciseJSON].self))
    }

    static func parse(_ data: Data) -> PreciseJSON? {
        try? JSONDecoder().decode(PreciseJSON.self, from: data)
    }

    var wv: WV {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let d): return .num(d)
        case .string(let s): return .str(s)
        case .array(let a): return .arr(a.map(\.wv))
        case .object(let o): return .obj(o.keys.sorted().map { ($0, o[$0]!.wv) })
        }
    }
}

extension WV {

    static func fromJSONObject(_ object: Any) -> WV {
        switch object {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .num(n.doubleValue) }
            return .int(n.intValue)
        case let s as String:
            return .str(s)
        case let a as [Any]:
            return .arr(a.map(fromJSONObject))
        case let d as [String: Any]:
            return .obj(d.keys.sorted().map { ($0, fromJSONObject(d[$0]!)) })
        default:
            return .null
        }
    }
}

extension WV: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    init(floatLiteral value: Double) { self = .num(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(stringLiteral value: String) { self = .str(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
    init(arrayLiteral elements: WV...) { self = .arr(elements) }
    init(dictionaryLiteral elements: (String, WV)...) { self = .obj(elements) }
}

/// Values that know their golden-vector JSON form. CoreGraphics types use the
/// TS model's plain-object shapes (`Point`, `Size`, `Rect` in core/model/types.ts).
protocol WVEncodable {
    var wv: WV { get }
}

extension Double: WVEncodable { var wv: WV { .num(self) } }
extension CGFloat: WVEncodable { var wv: WV { .num(Double(self)) } }
extension Int: WVEncodable { var wv: WV { .int(self) } }
extension Bool: WVEncodable { var wv: WV { .bool(self) } }
extension String: WVEncodable { var wv: WV { .str(self) } }
extension CGPoint: WVEncodable { var wv: WV { ["x": x.wv, "y": y.wv] } }
extension CGSize: WVEncodable { var wv: WV { ["width": width.wv, "height": height.wv] } }
extension CGRect: WVEncodable {
    var wv: WV { ["x": origin.x.wv, "y": origin.y.wv, "width": size.width.wv, "height": size.height.wv] }
}
extension CGAffineTransform: WVEncodable {
    var wv: WV { ["a": a.wv, "b": b.wv, "c": c.wv, "d": d.wv, "tx": tx.wv, "ty": ty.wv] }
}
extension Optional: WVEncodable where Wrapped: WVEncodable {
    var wv: WV { self.map { $0.wv } ?? .null }
}
extension Array: WVEncodable where Element: WVEncodable {
    var wv: WV { .arr(map { $0.wv }) }
}

// MARK: - Model → TS in-memory shape

/// The TS model mirrors project.json except for a few on-disk encodings
/// (ZoomRegion.focalPoint `[x,y]` → `{x,y}`; region `rectX…` → `rect`).
/// These helpers emit the TS IN-MEMORY shape so math suites can feed inputs
/// straight to the ports.
enum WVModel {
    static func zoomRegion(_ r: ZoomRegion) -> WV {
        WV.encoded(r).setting("focalPoint", r.focalPoint.wv)
    }

    static func tiltRegion(_ r: TiltRegion) -> WV { WV.encoded(r) }
    static func speedRegion(_ r: VideoSpeedRegion) -> WV { WV.encoded(r) }
    static func clip(_ c: VideoClipSegment) -> WV { WV.encoded(c) }
    static func cameraLayoutRegion(_ r: CameraLayoutRegion) -> WV { WV.encoded(r) }
    static func annotation(_ a: Annotation) -> WV { WV.encoded(a) }
    static func color(_ c: CodableColor) -> WV { WV.encoded(c) }
    static func settings(_ s: ProjectSettings) -> WV { WV.encoded(s) }

    static func cursorEvent(_ e: CursorEvent) -> WV {
        ["timestamp": e.timestamp.wv, "x": e.x.wv, "y": e.y.wv, "isClick": e.isClick.wv]
    }

    static func blurRegion(_ r: BlurRegion) -> WV {
        WV.encoded(r).removing("rectX", "rectY", "rectW", "rectH").setting("rect", r.rect.wv)
    }

    static func highlightRegion(_ r: HighlightRegion) -> WV {
        WV.encoded(r).removing("rectX", "rectY", "rectW", "rectH").setting("rect", r.rect.wv)
    }

    static func focusRegion(_ r: FocusRegion) -> WV {
        WV.encoded(r).removing("rectX", "rectY", "rectW", "rectH").setting("rect", r.rect.wv)
    }
}

// MARK: - Deterministic PRNG

/// SplitMix64 seeded from the unit name — the same seed always produces the
/// same cases, so regenerated vectors diff cleanly.
struct WVRandom {
    private var state: UInt64

    init(seed: String) {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        state = hash
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    mutating func double(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }

    mutating func cg(_ lo: Double, _ hi: Double) -> CGFloat { CGFloat(double(lo, hi)) }

    /// Inclusive.
    mutating func int(_ lo: Int, _ hi: Int) -> Int {
        guard hi > lo else { return lo }
        return lo + Int(next() % UInt64(hi - lo + 1))
    }

    mutating func bool(_ p: Double = 0.5) -> Bool { unit() < p }

    mutating func pick<T>(_ items: [T]) -> T { items[int(0, items.count - 1)] }

    /// With probability `edgeP` returns one of `edges`, else uniform [lo, hi).
    mutating func edgy(_ lo: Double, _ hi: Double, edges: [Double], edgeP: Double = 0.2) -> Double {
        if !edges.isEmpty, bool(edgeP) { return pick(edges) }
        return double(lo, hi)
    }

    /// A deterministic UUID (version-4 shaped).
    mutating func uuid() -> UUID {
        let a = next(), b = next()
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { buf in
            for i in 0..<8 {
                buf[i] = UInt8((a >> UInt64((7 - i) * 8)) & 0xff)
                buf[i + 8] = UInt8((b >> UInt64((7 - i) * 8)) & 0xff)
            }
            buf[6] = (buf[6] & 0x0f) | 0x40
            buf[8] = (buf[8] & 0x3f) | 0x80
        }
        return UUID(uuid: bytes)
    }

    mutating func point(_ lo: Double = 0, _ hi: Double = 1) -> CGPoint {
        CGPoint(x: double(lo, hi), y: double(lo, hi))
    }

    mutating func size(_ lo: Double, _ hi: Double) -> CGSize {
        CGSize(width: double(lo, hi), height: double(lo, hi))
    }

    mutating func rect(origin lo: Double, _ hi: Double, size slo: Double, _ shi: Double) -> CGRect {
        CGRect(x: double(lo, hi), y: double(lo, hi), width: double(slo, shi), height: double(slo, shi))
    }
}
