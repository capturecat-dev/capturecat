import Foundation

/// Raw project.json value for the project merge (docs/project-history.md).
///
/// The merge runs on RAW JSON, never on decoded models: `Project`'s Codable
/// drops unknown keys and `CameraLayoutRegion` invents a fresh `UUID()` for a
/// missing id on every decode — neither survives a three-way merge.
///
/// Twin of apps/web/src/editor/core/merge/jsonMerge.ts, locked by the
/// `projectMerge` / `mergePolicy` golden vectors (`--web-vectors`):
/// - objects keep their parse order (`JSONObject.keys`) but compare as maps;
/// - numbers are `Double` and compare with IEEE `==` (so -0 == 0);
/// - strings compare by UTF-16 code units (JavaScript `===`), NOT Swift's
///   canonical-equivalence `==`;
/// - canonical JSON sorts keys by UTF-16 code units, writes numbers in
///   ECMAScript `Number::toString` form (-0 → `0`) and escapes only `"`, `\`
///   and U+0000–U+001F.
nonisolated indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x.utf16.elementsEqual(y.utf16)
        case let (.array(x), .array(y)):
            guard x.count == y.count else { return false }
            for i in 0..<x.count where x[i] != y[i] { return false }
            return true
        case let (.object(x), .object(y)): return x == y
        default: return false
        }
    }

    var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }
}

/// Insertion-ordered JSON object. Equality ignores order.
nonisolated struct JSONObject: Equatable, Sendable {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}

    init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    /// Setting nil removes the key.
    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var count: Int { keys.count }

    func has(_ key: String) -> Bool { storage[key] != nil }

    static func == (a: JSONObject, b: JSONObject) -> Bool {
        guard a.keys.count == b.keys.count else { return false }
        for key in a.keys {
            guard let x = a.storage[key], let y = b.storage[key], x == y else { return false }
        }
        return true
    }
}

// MARK: - Helpers shared by the merge, diff and summary

nonisolated enum JSONKeys {
    /// UTF-16 code-unit order (JavaScript's default string sort).
    static func less(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }

    static func sorted<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted(by: less)
    }

    /// Sorted, de-duplicated union.
    static func sortedUnion(_ lists: [String]...) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for list in lists {
            for s in list where seen.insert(s).inserted { out.append(s) }
        }
        return sorted(out)
    }

    /// Sorted union of the keys of every object argument (others ignored).
    static func sortedUnionKeys(_ objects: JSONValue?...) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for o in objects {
            guard let obj = o?.objectValue else { continue }
            for k in obj.keys where seen.insert(k).inserted { out.append(k) }
        }
        return sorted(out)
    }

    static func sameSequence(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
    }
}

nonisolated extension JSONValue {
    /// Own-key read of an object value (nil for non-objects / absent keys).
    func get(_ key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: - Canonical JSON

nonisolated extension JSONValue {
    var canonical: String {
        var out = ""
        writeCanonical(into: &out)
        return out
    }

    private func writeCanonical(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d): out += JSONValue.canonicalNumber(d)
        case .string(let s): JSONValue.writeCanonicalString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.writeCanonical(into: &out)
            }
            out += "]"
        case .object(let obj):
            out += "{"
            for (i, key) in JSONKeys.sorted(obj.keys).enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeCanonicalString(key, into: &out)
                out += ":"
                obj[key]!.writeCanonical(into: &out)
            }
            out += "}"
        }
    }

    static func canonicalString(_ s: String) -> String {
        var out = ""
        writeCanonicalString(s, into: &out)
        return out
    }

    private static func writeCanonicalString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// ECMAScript Number::toString(d) (what `String(n)` / `JSON.stringify`
    /// print), built from Swift's shortest round-trip digits. -0 → "0".
    static func canonicalNumber(_ d: Double) -> String {
        precondition(d.isFinite, "canonicalJSON: non-finite number \(d)")
        if d == 0 { return "0" }
        var text = "\(d)" // shortest round-trip: "0.1", "100.0", "1e-07", "1.5e+300"
        var sign = ""
        if text.hasPrefix("-") {
            sign = "-"
            text.removeFirst()
        }
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = parts[0]
        let fracPart = parts.count > 1 ? parts[1] : ""
        var digits = Array(intPart + fracPart)
        // value = 0.d1d2…dk × 10^n
        var n = intPart.count + exponent
        while let first = digits.first, first == "0" {
            digits.removeFirst()
            n -= 1
        }
        while let last = digits.last, last == "0" { digits.removeLast() }
        let k = digits.count
        let s = String(digits)
        if k <= n && n <= 21 {
            return sign + s + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            return sign + String(digits[0..<n]) + "." + String(digits[n...])
        }
        if -6 < n && n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + s
        }
        let e = n - 1
        let expText = e < 0 ? "e-\(-e)" : "e+\(e)"
        if k == 1 { return sign + s + expText }
        return sign + String(digits[0]) + "." + String(digits[1...]) + expText
    }
}

// MARK: - Hashing

nonisolated enum JSONHash {
    /// FNV-1a 64 over the UTF-8 bytes of `text`, as 16 lowercase hex digits.
    static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Parser (order-preserving, correctly-rounded numbers)

nonisolated struct JSONParseError: Error, CustomStringConvertible {
    let message: String
    let offset: Int
    var description: String { "JSON parse error at byte \(offset): \(message)" }
}

nonisolated extension JSONValue {
    static func parse(_ text: String) throws -> JSONValue {
        try parse(bytes: Array(text.utf8))
    }

    static func parse(data: Data) throws -> JSONValue {
        try parse(bytes: [UInt8](data))
    }

    static func parse(bytes: [UInt8]) throws -> JSONValue {
        var parser = JSONParser(bytes: bytes)
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw parser.error("trailing characters") }
        return value
    }
}

nonisolated private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw error("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw error("invalid literal") }
            index += 1
        }
    }

    mutating func parseObject() throws -> JSONValue {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw error("expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw error("expected ',' or ']'")
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("short \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[index]
            v <<= 4
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): v |= UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): v |= UInt32(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): v |= UInt32(c - UInt8(ascii: "A") + 10)
            default: throw error("bad hex digit")
            }
            index += 1
        }
        return v
    }

    mutating func parseString() throws -> String {
        index += 1 // opening quote
        var buffer: [UInt8] = []
        while true {
            guard index < bytes.count else { throw error("unterminated string") }
            let c = bytes[index]
            index += 1
            if c == UInt8(ascii: "\"") { break }
            if c < 0x20 { throw error("control character in string") }
            if c != UInt8(ascii: "\\") {
                buffer.append(c)
                continue
            }
            guard index < bytes.count else { throw error("unterminated escape") }
            let e = bytes[index]
            index += 1
            switch e {
            case UInt8(ascii: "\""): buffer.append(0x22)
            case UInt8(ascii: "\\"): buffer.append(0x5C)
            case UInt8(ascii: "/"): buffer.append(0x2F)
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                if (0xD800...0xDBFF).contains(scalar), index + 6 <= bytes.count,
                   bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    let save = index
                    index += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = save
                    }
                }
                let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                buffer.append(contentsOf: Array(String(Character(u)).utf8))
            default: throw error("bad escape")
            }
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    mutating func parseNumber() throws -> Double {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        func digits(_ p: inout JSONParser) -> Int {
            let s = p.index
            while p.index < p.bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(p.bytes[p.index]) { p.index += 1 }
            return p.index - s
        }
        guard digits(&self) > 0 else { throw error("invalid number") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits(&self) > 0 else { throw error("invalid fraction") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits(&self) > 0 else { throw error("invalid exponent") }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(text) else { throw error("invalid number \(text)") }
        return value
    }
}
