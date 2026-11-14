import Foundation

/// A JSON value that round-trips a CaptureCat project.json without loss.
///
/// The iOS app never decodes a project into a model: the Mac's `Project`
/// Codable and the web's core/model own that schema, and both preserve keys
/// the other does not know. A phone that parsed into its own struct and wrote
/// it back would silently drop everything it did not model. So edits here are
/// surgical: parse → change one key → serialize, with object key ORDER,
/// unknown keys, and number TEXT kept exactly (`1.0` stays `1.0`, `0.1` never
/// becomes `0.10000000000000001`). Output is 2-space pretty JSON, the shape
/// the web serializer writes.
nonisolated indirect enum LosslessJSON: Equatable, Sendable {
    case object([(String, LosslessJSON)])
    case array([LosslessJSON])
    case string(String)
    /// The literal number text from the source (or produced by `.number(_:)`).
    case number(String)
    case bool(Bool)
    case null

    static func == (lhs: LosslessJSON, rhs: LosslessJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    // MARK: Building

    /// A number literal for a Swift Double, formatted the way JSON.stringify
    /// and Swift's JSONEncoder agree on for the values we write (integers
    /// without a fraction, everything else via the shortest round-trip form).
    static func number(_ value: Double) -> LosslessJSON {
        guard value.isFinite else { return .null }
        if value == value.rounded(), abs(value) < 1e15 { return .number(String(Int64(value))) }
        return .number("\(value)")
    }

    static func number(_ value: Int) -> LosslessJSON { .number(String(value)) }

    // MARK: Access

    subscript(key: String) -> LosslessJSON? {
        get {
            guard case let .object(pairs) = self else { return nil }
            return pairs.first(where: { $0.0 == key })?.1
        }
        set {
            guard case var .object(pairs) = self else { return }
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                if let newValue { pairs[index].1 = newValue } else { pairs.remove(at: index) }
            } else if let newValue {
                pairs.append((key, newValue))
            }
            self = .object(pairs)
        }
    }

    var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    var doubleValue: Double? { if case let .number(n) = self { return Double(n) }; return nil }

    // MARK: Parse

    static func parse(_ data: Data) throws -> LosslessJSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError.trailingData(parser.index) }
        return value
    }

    enum ParseError: Error, Equatable {
        case unexpected(Int)
        case trailingData(Int)
        case tooDeep
        case badString(Int)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            let lit = Array(literal.utf8)
            guard index + lit.count <= bytes.count, Array(bytes[index..<index + lit.count]) == lit else {
                throw ParseError.unexpected(index)
            }
            index += lit.count
        }

        mutating func parseValue(depth: Int) throws -> LosslessJSON {
            guard depth < 512 else { throw ParseError.tooDeep }
            guard index < bytes.count else { throw ParseError.unexpected(index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        mutating func parseObject(depth: Int) throws -> LosslessJSON {
            index += 1
            var pairs: [(String, LosslessJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError.unexpected(index) }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError.unexpected(index) }
                index += 1
                skipWhitespace()
                pairs.append((key, try parseValue(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.unexpected(index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                throw ParseError.unexpected(index)
            }
        }

        mutating func parseArray(depth: Int) throws -> LosslessJSON {
            index += 1
            var items: [LosslessJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.unexpected(index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw ParseError.unexpected(index)
            }
        }

        mutating func parseNumber() throws -> String {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            let digitsStart = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            guard index > digitsStart else { throw ParseError.unexpected(start) }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                let fracStart = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                guard index > fracStart else { throw ParseError.unexpected(index) }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                let expStart = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                guard index > expStart else { throw ParseError.unexpected(index) }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func parseString() throws -> String {
            index += 1 // opening quote
            var out = [UInt8]()
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    guard let text = String(bytes: out, encoding: .utf8) else { throw ParseError.badString(index) }
                    return text
                }
                if byte < 0x20 { throw ParseError.badString(index) }
                if byte != UInt8(ascii: "\\") {
                    out.append(byte)
                    index += 1
                    continue
                }
                index += 1
                guard index < bytes.count else { throw ParseError.badString(index) }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // Surrogate pair.
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw ParseError.badString(index)
                        }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw ParseError.badString(index) }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let unicode = Unicode.Scalar(scalar) else { throw ParseError.badString(index) }
                    out.append(contentsOf: Array(String(Character(unicode)).utf8))
                default:
                    throw ParseError.badString(index)
                }
            }
            throw ParseError.badString(index)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw ParseError.badString(index) }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[index]
                index += 1
                value <<= 4
                switch c {
                case 0x30...0x39: value |= UInt32(c - 0x30)
                case 0x41...0x46: value |= UInt32(c - 0x41 + 10)
                case 0x61...0x66: value |= UInt32(c - 0x61 + 10)
                default: throw ParseError.badString(index)
                }
            }
            return value
        }
    }

    // MARK: Serialize

    /// 2-space pretty JSON (JSON.stringify(value, null, 2) layout).
    func serialized() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n): out += n
        case let .string(s): Self.writeString(s, into: &out)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                item.write(into: &out, indent: indent + 1)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, pair) in pairs.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                Self.writeString(pair.0, into: &out)
                out += ": "
                pair.1.write(into: &out, indent: indent + 1)
                out += i == pairs.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
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
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
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
}
