import CoreGraphics
import Foundation

// On-frame comment drawings and the owner's timeline markers for a share —
// a port of the web's ONE source of truth, apps/web/src/lib/share/
// annotation.ts (model, geometry, canonical serializer, the renderer's draw
// plan), so a drawing made on an iPhone posts the exact bytes the web would
// post and every viewer sees the same marks on the same pixels of the frame.
//
// Every coordinate is normalized 0–1 to the VIDEO FRAME (the picture, not the
// player box: letterbox bars and a fill crop are outside it). Stroke widths
// and font sizes are fractions of the frame's shorter side.
//
// Kept honest by the web's own serializer and renderer: apps/web/src/lib/
// share/annotation.fixtures.json is WRITTEN by the web (annotation.fixtures.
// test.ts, which fails if the web drifts from it) and READ by
// Tests/CoreSelfTest.swift, which must reproduce every byte and every draw
// call; scripts/ios-share-viewer.sh also runs the web serializer over what
// the in-app gate drew and compares it with what the app posted.
//
// Pure Foundation + CoreGraphics: compiled into the app and into the macOS
// core self-test.

/// One shape on the frame (the web's `AnnotationShape`).
nonisolated enum ShareAnnotationShape: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case pen, highlight, arrow, rect, ellipse, text
    }

    case stroke(kind: Kind, color: String, size: Int, points: [CGPoint])
    case box(kind: Kind, color: String, size: Int, from: CGPoint, to: CGPoint)
    case text(color: String, size: Int, at: CGPoint, text: String)

    var kind: Kind {
        switch self {
        case let .stroke(kind, _, _, _), let .box(kind, _, _, _, _): return kind
        case .text: return .text
        }
    }

    var color: String {
        switch self {
        case let .stroke(_, color, _, _), let .box(_, color, _, _, _), let .text(color, _, _, _): return color
        }
    }

    var size: Int {
        switch self {
        case let .stroke(_, _, size, _), let .box(_, _, size, _, _), let .text(_, size, _, _): return size
        }
    }
}

/// `{ v: 1, shapes }` — a comment's drawing.
nonisolated struct ShareAnnotation: Equatable, Hashable, Sendable, Decodable {
    var shapes: [ShareAnnotationShape]

    init(shapes: [ShareAnnotationShape]) { self.shapes = shapes }

    /// The web's tolerant reader (`readAnnotation`): never throws — a
    /// malformed drawing reads as no shapes, a malformed shape is dropped.
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(ShareJSONValue.self))?.object
        shapes = ShareAnnotationMath.read(raw)?.shapes ?? []
    }
}

/// An owner's annotation marker from the share's meta (output seconds), the
/// web's `AnnotationMarker` (validated server-side, apps/api upload-schemas.ts).
nonisolated struct ShareAnnotationMarker: Equatable, Hashable, Sendable, Decodable {
    var start: Double
    var end: Double
    var label: String?
    var autoPause: Bool?
    var pauseDuration: Double?

    init(start: Double, end: Double, label: String? = nil) {
        self.start = start
        self.end = end
        self.label = label
    }

    /// Never throws: one odd marker can't cost the share its meta.
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: Keys.self)
        start = max(0, (try? c?.decode(Double.self, forKey: .start)) ?? 0)
        end = max(start, (try? c?.decode(Double.self, forKey: .end)) ?? start)
        label = (try? c?.decodeIfPresent(String.self, forKey: .label)) ?? nil
        autoPause = (try? c?.decodeIfPresent(Bool.self, forKey: .autoPause)) ?? nil
        pauseDuration = (try? c?.decodeIfPresent(Double.self, forKey: .pauseDuration)) ?? nil
    }

    enum Keys: String, CodingKey { case start, end, label, autoPause, pauseDuration }

    /// The web shows a pill / Summary row for a marker with a label, or one
    /// that isn't pinned at the very start.
    var hasPill: Bool { (label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) || start >= 1 }
}

/// A minimal JSON value, so the tolerant reader can look at whatever arrived.
nonisolated enum ShareJSONValue: Decodable, Sendable {
    case number(Double), string(String), bool(Bool), array([ShareJSONValue]), object([String: ShareJSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([ShareJSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: ShareJSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    /// As a JSONSerialization-style object.
    var object: Any {
        switch self {
        case let .number(n): return NSNumber(value: n)
        case let .string(s): return s
        case let .bool(b): return NSNumber(value: b)
        case let .array(a): return a.map(\.object)
        case let .object(o): return o.mapValues(\.object)
        case .null: return NSNull()
        }
    }
}

nonisolated enum ShareAnnotationMath {
    // MARK: Limits (the API's, apps/api/src/lib/comments.ts)

    static let maxShapes = 100
    static let maxTotalPoints = 5000
    static let maxPointsPerStroke = 2000
    static let maxTextLength = 140
    static let maxBytes = 32 * 1024
    /// The share page's default accent (brandAccent ?? this).
    static let defaultAccent = "#fbbf24"
    /// Swatches after the accent (web annotationPalette).
    static let basePalette = ["#ef4444", "#3b82f6", "#22c55e", "#ffffff", "#111111"]
    /// How close the playhead must stay to a drawing's moment (web DRAWING_SNAP_S).
    static let drawingSnap: Double = 0.35

    static func palette(accent: String) -> [String] {
        let a = accent.lowercased()
        return [a] + basePalette.filter { $0 != a }
    }

    // MARK: Geometry

    /// Where the picture sits inside an aspect-FIT box (object-fit: contain,
    /// AVLayerVideoGravity.resizeAspect). No media size → the box.
    static func containRect(box: CGSize, media: CGSize?) -> CGRect {
        guard let media, media.width > 0, media.height > 0, box.width > 0, box.height > 0 else {
            return CGRect(x: 0, y: 0, width: max(0, box.width), height: max(0, box.height))
        }
        let scale = min(box.width / media.width, box.height / media.height)
        let w = media.width * scale, h = media.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// The picture in an aspect-FILL box (resizeAspectFill — the landscape
    /// player's pinch-to-fill): larger than the box, centred, cropped.
    static func coverRect(box: CGSize, media: CGSize?) -> CGRect {
        guard let media, media.width > 0, media.height > 0, box.width > 0, box.height > 0 else {
            return CGRect(x: 0, y: 0, width: max(0, box.width), height: max(0, box.height))
        }
        let scale = max(box.width / media.width, box.height / media.height)
        let w = media.width * scale, h = media.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// 4 decimals — 1/10 000 of the frame, what the API stores. (JS
    /// Math.round: half up; every value here is ≥ 0, where that equals
    /// Swift's schoolbook rounding.)
    static func roundCoord(_ v: Double) -> Double { (clamp01(v) * 10_000).rounded() / 10_000 }

    /// Box point → normalized frame coordinates (clamped to the frame).
    static func toFrame(_ p: CGPoint, rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x: clamp01((p.x - rect.minX) / rect.width), y: clamp01((p.y - rect.minY) / rect.height))
    }

    /// Normalized frame coordinates → box point.
    static func toBox(_ p: CGPoint, rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    /// The frame's shorter side — every size is a fraction of it.
    static func frameUnit(_ rect: CGRect) -> CGFloat { max(0, min(rect.width, rect.height)) }

    private static let strokeFraction: [Int: CGFloat] = [1: 0.0055, 2: 0.0095, 3: 0.016]
    private static let fontFraction: [Int: CGFloat] = [1: 0.036, 2: 0.05, 3: 0.07]
    static let highlightWidth: CGFloat = 3.4
    static let highlightAlpha: CGFloat = 0.42

    static func strokeWidth(_ kind: ShareAnnotationShape.Kind, size: Int, rect: CGRect) -> CGFloat {
        let base = (strokeFraction[size] ?? strokeFraction[2]!) * frameUnit(rect)
        return kind == .highlight ? base * highlightWidth : base
    }

    static func fontSize(_ size: Int, rect: CGRect) -> CGFloat { (fontFraction[size] ?? fontFraction[2]!) * frameUnit(rect) }

    struct LabelMetrics: Equatable {
        var px, padX, padY, lineHeight, radius: CGFloat
    }

    static func labelMetrics(size: Int, rect: CGRect) -> LabelMetrics {
        let px = fontSize(size, rect: rect)
        return LabelMetrics(px: px, padX: px * 0.42, padY: px * 0.24, lineHeight: px * 1.22, radius: px * 0.34)
    }

    // MARK: Stroke simplification (Ramer–Douglas–Peucker, iterative)

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func simplifyStroke(_ points: [CGPoint], epsilon: Double = 0.0007) -> [CGPoint] {
        if points.count <= 2 { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            var maxD = -1.0
            var index = -1
            if start + 1 < end {
                for i in (start + 1)..<end {
                    let d = segmentDistance(points[i], points[start], points[end])
                    if d > maxD { maxD = d; index = i }
                }
            }
            if index != -1, maxD > epsilon {
                keep[index] = true
                stack.append((start, index))
                stack.append((index, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    // MARK: Serialization

    /// JS `\s` — what the web's whitespace collapse and trim() treat as space.
    private static func isJSSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// Controls and bidi overrides (web cleanLabel's class).
    private static func isStripped(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// Label text as the API stores it: controls stripped, whitespace collapsed.
    static func cleanLabel(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            let s = isStripped(scalar) ? Unicode.Scalar(0x20)! : scalar
            if isJSSpace(s) {
                pendingSpace = true
            } else {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(s)
            }
        }
        return String(out)
    }

    /// Shorter than this (normalized) and an arrow / box is an accidental tap.
    static let minBoxSpan = 0.004

    private static func roundPoint(_ p: CGPoint) -> CGPoint {
        #if DEBUG
        if probeDrift { return p }
        #endif
        return CGPoint(x: roundCoord(p.x), y: roundCoord(p.y))
    }

    /// `/^#[0-9a-f]{6}$/i` (no ICU `$`-before-newline leniency).
    static func isColor(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        return u.count == 7 && u[0] == "#" && u.dropFirst().allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
    }

    /// One shape in canonical form, or nil when it has nothing to draw.
    static func canonicalShape(_ shape: ShareAnnotationShape) -> ShareAnnotationShape? {
        var color = isColor(shape.color) ? shape.color.lowercased() : "#ffffff"
        #if DEBUG
        if probeDrift { color = shape.color }
        #endif
        let size = shape.size == 1 || shape.size == 3 ? shape.size : 2
        switch shape {
        case let .stroke(kind, _, _, raw):
            var points = simplifyStroke(raw.map(roundPoint))
            var epsilon = 0.0015
            while points.count > maxPointsPerStroke && epsilon < 0.05 {
                points = simplifyStroke(points, epsilon: epsilon)
                epsilon *= 2
            }
            let simplified = points
            points = simplified.enumerated().filter { i, p in i == 0 || p != simplified[i - 1] }.map(\.element)
            if points.isEmpty { return nil }
            return .stroke(kind: kind, color: color, size: size, points: Array(points.prefix(maxPointsPerStroke)))
        case let .box(kind, _, _, rawFrom, rawTo):
            let from = roundPoint(rawFrom), to = roundPoint(rawTo)
            let tooSmall = kind == .arrow
                ? dist(from, to) < minBoxSpan
                : abs(from.x - to.x) < minBoxSpan || abs(from.y - to.y) < minBoxSpan
            if tooSmall { return nil }
            return .box(kind: kind, color: color, size: size, from: from, to: to)
        case let .text(_, _, at, raw):
            let text = String(String.UnicodeScalarView(cleanLabel(raw).unicodeScalars.prefix(maxTextLength)))
            if text.isEmpty { return nil }
            return .text(color: color, size: size, at: roundPoint(at), text: text)
        }
    }

    private static func pointCount(_ shape: ShareAnnotationShape) -> Int {
        switch shape {
        case let .stroke(_, _, _, points): return points.count
        case .box: return 2
        case .text: return 1
        }
    }

    struct Serialized: Equatable {
        /// nil = nothing worth sending.
        var annotation: ShareAnnotation?
        var json: String?
        var bytes: Int
        var tooLarge: Bool
    }

    #if DEBUG
    /// INJECTED DEFECT (`serializer-drift`, ShareViewerGate): canonical
    /// shapes keep their colour's case and skip coordinate rounding — the
    /// bytes the app posts stop matching the web's serializer.
    nonisolated(unsafe) static var probeDrift = false
    #endif

    /// Shapes → the exact payload the API accepts (and stores), byte for byte
    /// what the web's `serializeAnnotation` produces for the same shapes.
    static func serialize(_ shapes: [ShareAnnotationShape]) -> Serialized {
        let clean = shapes.compactMap(canonicalShape)
        if clean.isEmpty { return Serialized(annotation: nil, json: nil, bytes: 0, tooLarge: false) }
        let json = jsonString(clean)
        let bytes = json.utf8.count
        let total = clean.reduce(0) { $0 + pointCount($1) }
        let tooLarge = clean.count > maxShapes || total > maxTotalPoints || bytes > maxBytes
        return Serialized(annotation: ShareAnnotation(shapes: clean), json: json, bytes: bytes, tooLarge: tooLarge)
    }

    /// JSON.stringify's output for `{v: 1, shapes}` (key order, number text,
    /// string escapes).
    static func jsonString(_ shapes: [ShareAnnotationShape]) -> String {
        func num(_ v: CGFloat) -> String {
            let d = Double(v)
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return "\(d)"
        }
        func pt(_ p: CGPoint) -> String { "[\(num(p.x)),\(num(p.y))]" }
        let items = shapes.map { shape -> String in
            switch shape {
            case let .stroke(kind, color, size, points):
                return "{\"kind\":\"\(kind.rawValue)\",\"color\":\(jsonQuote(color)),\"size\":\(size),\"points\":[\(points.map(pt).joined(separator: ","))]}"
            case let .box(kind, color, size, from, to):
                return "{\"kind\":\"\(kind.rawValue)\",\"color\":\(jsonQuote(color)),\"size\":\(size),\"from\":\(pt(from)),\"to\":\(pt(to))}"
            case let .text(color, size, at, text):
                return "{\"kind\":\"text\",\"color\":\(jsonQuote(color)),\"size\":\(size),\"at\":\(pt(at)),\"text\":\(jsonQuote(text))}"
            }
        }
        return "{\"v\":1,\"shapes\":[\(items.joined(separator: ","))]}"
    }

    /// JSON.stringify's string quoting (well-formed: lone surrogates can't
    /// occur in a Swift String).
    static func jsonQuote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    // MARK: Reading (the web's second fence)

    private static func readPoint(_ raw: Any?) -> CGPoint? {
        guard let a = raw as? [Any], a.count == 2,
              let x = number(a[0]), let y = number(a[1]), x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: clamp01(x), y: clamp01(y))
    }

    private static func number(_ raw: Any) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// The API's annotation JSON (a JSONSerialization object) → a model the
    /// renderer can trust; malformed shapes are dropped one by one.
    static func read(_ raw: Any?) -> ShareAnnotation? {
        guard let object = raw as? [String: Any], let v = object["v"].flatMap(number), v == 1,
              let shapes = object["shapes"] as? [Any] else { return nil }
        var out: [ShareAnnotationShape] = []
        for item in shapes.prefix(maxShapes) {
            guard let s = item as? [String: Any] else { continue }
            guard let color = s["color"] as? String, isColor(color),
                  let size = s["size"].flatMap(number), [1, 2, 3].contains(size) else { continue }
            let kind = (s["kind"] as? String).flatMap(ShareAnnotationShape.Kind.init(rawValue:))
            switch kind {
            case .pen?, .highlight?:
                guard let raw = s["points"] as? [Any] else { continue }
                let points = raw.compactMap(readPoint)
                if !points.isEmpty { out.append(.stroke(kind: kind!, color: color, size: Int(size), points: points)) }
            case .arrow?, .rect?, .ellipse?:
                if let from = readPoint(s["from"]), let to = readPoint(s["to"]) {
                    out.append(.box(kind: kind!, color: color, size: Int(size), from: from, to: to))
                }
            case .text?:
                guard let text = s["text"] as? String, let at = readPoint(s["at"]) else { continue }
                let clean = String(cleanLabel(text).utf16.prefix(maxTextLength * 2)) ?? cleanLabel(text)
                if !clean.isEmpty { out.append(.text(color: color, size: Int(size), at: at, text: clean)) }
            case nil:
                continue
            }
        }
        return out.isEmpty ? nil : ShareAnnotation(shapes: out)
    }

    /// The JSONSerialization object for a request body.
    static func jsonObject(_ annotation: ShareAnnotation) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(jsonString(annotation.shapes).utf8))
    }

    // MARK: Rendering plan — the web renderer's draw calls, in order

    /// One canvas call of the web's `drawAnnotation`, in box points.
    enum Op: Equatable {
        case moveTo(CGPoint)
        case lineTo(CGPoint)
        case quad(control: CGPoint, to: CGPoint)
        case arc(center: CGPoint, radius: CGFloat)
        case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat)
        case rect(CGRect)
        case roundRect(CGRect, radius: CGFloat)
        /// Stroke the path so far at this width (then a new path begins).
        case stroke(width: CGFloat)
        /// Fill the path so far with `color` (#rrggbb or rgba()).
        case fill(color: String)
        case fillText(String, at: CGPoint)
    }

    struct PlannedShape: Equatable {
        var shape: ShareAnnotationShape
        var alpha: CGFloat
        /// The legibility shadow (not for the highlighter).
        var shadow: Bool
        var shadowBlur: CGFloat
        var shadowOffsetY: CGFloat
        /// Label font size (text shapes).
        var fontPx: CGFloat
        var ops: [Op]
    }

    /// Light ink → dark plate, dark ink → light plate.
    static func luminance(_ hex: String) -> Double {
        guard hex.count == 7, let n = Int(hex.dropFirst(), radix: 16) else { return 1 }
        let r = Double((n >> 16) & 255), g = Double((n >> 8) & 255), b = Double(n & 255)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    }

    /// Split a label into lines that fit (words first, then characters).
    static func wrapLabel(_ text: String, maxWidth: CGFloat, measure: (String) -> CGFloat) -> [String] {
        let words = text.components(separatedBy: " ")
        var lines: [String] = []
        var line = ""
        func pushLong(_ word: String) -> String {
            var chunk = ""
            for ch in word.unicodeScalars {
                let next = chunk + String(ch)
                if !chunk.isEmpty, measure(next) > maxWidth {
                    lines.append(chunk)
                    chunk = String(ch)
                } else {
                    chunk = next
                }
            }
            return chunk
        }
        for word in words {
            let candidate = line.isEmpty ? word : line + " " + word
            if measure(candidate) <= maxWidth {
                line = candidate
            } else if line.isEmpty {
                line = pushLong(word)
            } else {
                lines.append(line)
                line = measure(word) > maxWidth ? pushLong(word) : word
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// The web renderer's calls for `shapes` over `rect` (the video frame in
    /// box points). `measure(text, fontPx)` = the label font's advance.
    static func plan(_ shapes: [ShareAnnotationShape], rect: CGRect, minStrokePx: CGFloat = 0, shadows: Bool = true,
                     measure: (String, CGFloat) -> CGFloat) -> [PlannedShape] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let unit = frameUnit(rect)
        return shapes.map { shape in
            let lw = max(minStrokePx, strokeWidth(shape.kind, size: shape.size, rect: rect))
            var ops: [Op] = []
            var fontPx: CGFloat = 0
            switch shape {
            case let .stroke(_, color, _, points):
                let pts = points.map { toBox($0, rect: rect) }
                if pts.count == 1 {
                    ops = [.arc(center: pts[0], radius: lw / 2), .fill(color: color)]
                } else {
                    ops.append(.moveTo(pts[0]))
                    if pts.count > 2 {
                        for i in 1..<(pts.count - 1) {
                            ops.append(.quad(control: pts[i], to: CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)))
                        }
                    }
                    ops.append(.lineTo(pts[pts.count - 1]))
                    ops.append(.stroke(width: lw))
                }
            case let .box(kind, color, _, from, to):
                let a = toBox(from, rect: rect), b = toBox(to, rect: rect)
                switch kind {
                case .arrow:
                    let len = hypot(b.x - a.x, b.y - a.y)
                    guard len > 0 else { break }
                    let angle = atan2(b.y - a.y, b.x - a.x)
                    let head = min(max(lw * 3.6, unit * 0.024), len * 0.6)
                    let spread = 27 * CGFloat.pi / 180
                    let shaft = len - head * 0.7
                    ops = [
                        .moveTo(a), .lineTo(CGPoint(x: a.x + cos(angle) * shaft, y: a.y + sin(angle) * shaft)), .stroke(width: lw),
                        .moveTo(b),
                        .lineTo(CGPoint(x: b.x - head * cos(angle - spread), y: b.y - head * sin(angle - spread))),
                        .lineTo(CGPoint(x: b.x - head * cos(angle + spread), y: b.y - head * sin(angle + spread))),
                        .fill(color: color), .stroke(width: max(1, lw * 0.5)),
                    ]
                case .rect:
                    ops = [.rect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))), .stroke(width: lw)]
                default:
                    ops = [.ellipse(center: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), rx: abs(b.x - a.x) / 2, ry: abs(b.y - a.y) / 2), .stroke(width: lw)]
                }
            case let .text(color, size, at, text):
                let m = labelMetrics(size: size, rect: rect)
                fontPx = m.px
                let p = toBox(at, rect: rect)
                let room = max(rect.width / 3, rect.maxX - p.x - m.padX * 2 - rect.width * 0.01)
                let lines = wrapLabel(text, maxWidth: room) { measure($0, m.px) }
                let width = (lines.map { measure($0, m.px) }.max() ?? 0) + m.padX * 2
                let height = CGFloat(lines.count) * m.lineHeight + m.padY * 2
                let bx = min(max(rect.minX, p.x), rect.maxX - width)
                let by = min(max(rect.minY, p.y), rect.maxY - height)
                ops.append(.roundRect(CGRect(x: bx, y: by, width: width, height: height), radius: m.radius))
                ops.append(.fill(color: luminance(color) > 0.45 ? "rgba(10,11,16,0.72)" : "rgba(255,255,255,0.88)"))
                for (i, line) in lines.enumerated() {
                    ops.append(.fillText(line, at: CGPoint(x: bx + m.padX, y: by + m.padY + CGFloat(i) * m.lineHeight + (m.lineHeight - m.px) / 2)))
                }
            }
            let shadow = shadows && shape.kind != .highlight
            return PlannedShape(shape: shape, alpha: shape.kind == .highlight ? highlightAlpha : 1, shadow: shadow,
                                shadowBlur: unit * 0.008, shadowOffsetY: unit * 0.0016, fontPx: fontPx, ops: ops)
        }
    }

    /// The plan as the web fixture's recorded calls (annotation.fixtures.json
    /// `render[].calls`): `[name, numbers…]`.
    static func recordedCalls(_ plan: [PlannedShape]) -> [[Any]] {
        var calls: [[Any]] = []
        for shape in plan {
            for op in shape.ops {
                switch op {
                case let .moveTo(p): calls.append(["moveTo", p.x, p.y])
                case let .lineTo(p): calls.append(["lineTo", p.x, p.y])
                case let .quad(c, p): calls.append(["quad", c.x, c.y, p.x, p.y])
                case let .arc(c, r): calls.append(["arc", c.x, c.y, r])
                case let .ellipse(c, rx, ry): calls.append(["ellipse", c.x, c.y, rx, ry])
                case let .rect(r): calls.append(["rect", r.minX, r.minY, r.width, r.height])
                case let .roundRect(r, radius): calls.append(["roundRect", r.minX, r.minY, r.width, r.height, radius])
                case let .stroke(w): calls.append(["stroke", w])
                case let .fill(color): calls.append(["fill", color])
                case let .fillText(text, at): calls.append(["fillText", text, at.x, at.y])
                }
            }
        }
        return calls
    }

    // MARK: Timeline markers (web share-player `markers`)

    /// A marker's range on the track, as fractions of its width: the web's
    /// left %, and a width of at least 0.8 % so a zero-length marker shows.
    static func markerSpan(_ marker: ShareAnnotationMarker, duration: Double) -> (left: Double, width: Double)? {
        guard duration > 0 else { return nil }
        let start = min(max(marker.start, 0), duration)
        let end = min(max(max(marker.end, marker.start), 0), duration)
        return (start / duration, max((end - start) / duration, 0.008))
    }

    /// The marker covering `time` (the web's markerAt), for snapping a tap
    /// inside a range to its start.
    static func marker(at time: Double, in markers: [ShareAnnotationMarker]) -> Int? {
        markers.firstIndex { time >= $0.start && time <= $0.end }
    }
}

extension ShareAnnotationShape {
    /// A box shape's copy with a new end point (drawing in progress).
    nonisolated func with(to point: CGPoint) -> ShareAnnotationShape {
        if case let .box(kind, color, size, from, _) = self { return .box(kind: kind, color: color, size: size, from: from, to: point) }
        return self
    }

    /// A stroke's copy with one more sample.
    nonisolated func appending(_ point: CGPoint) -> ShareAnnotationShape {
        if case let .stroke(kind, color, size, points) = self { return .stroke(kind: kind, color: color, size: size, points: points + [point]) }
        return self
    }
}
