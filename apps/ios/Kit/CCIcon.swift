import UIKit

// CCIcon — CaptureCat's own icon kit, rendered for UIKit (port of the Mac's
// CCIcon.swift renderer). The glyph data is the Mac's GENERATED
// CCIconSet.swift (compiled into this target straight from the Mac tree):
// line drawings on a 24 × 24 grid, 1.75 stroke, round caps/joins, solid parts
// filled, stored as a small SVG subset — <path d> (M L H V C S Q T A Z, abs +
// rel), <circle>, <rect rx>, <line>.
//
// Chrome icons NEVER come from SF Symbols. Call sites ask by kit name or by
// the old SF name (the alias table maps it). An unknown name returns nil
// (and trips an assertion in Debug) — there is deliberately no SF fallback.
//
//     CCIcon.image("play-fill", pointSize: 17)                 // template
//     CCIcon.image("link", pointSize: 15, weight: .semibold, color: c)
//     CCIcon.draw("check", in: ctx, rect: r, color: c)          // Y-down ctx
enum CCIcon {
    static func kitName(for name: String) -> String? {
        if CCIconSet.icons[name] != nil { return name }
        return CCIconSet.aliases[name]
    }

    static func has(_ name: String) -> Bool { kitName(for: name) != nil }

    /// A TEMPLATE image (tint with `tintColor`) at an SF-Symbol-equivalent size.
    static func image(_ name: String, pointSize: CGFloat = 17, weight: UIFont.Weight = .regular) -> UIImage? {
        rendered(name, pointSize: pointSize, weight: weight, color: nil)?.withRenderingMode(.alwaysTemplate)
    }

    /// A painted (non-template) image, for layer contents and CG canvases.
    static func image(_ name: String, pointSize: CGFloat, weight: UIFont.Weight = .regular, color: UIColor) -> UIImage? {
        rendered(name, pointSize: pointSize, weight: weight, color: color)?.withRenderingMode(.alwaysOriginal)
    }

    /// Draw straight into a Y-down context.
    static func draw(_ name: String, in ctx: CGContext, rect: CGRect, color: UIColor, weight: UIFont.Weight = .regular) {
        guard let kit = kitName(for: name), let shapes = shapes(for: kit) else { return }
        draw(shapes, in: ctx, rect: rect, stroke: 1.75 * strokeScale(for: weight), color: color.cgColor)
    }

    /// The square box (pt) an icon occupies at an SF point size (calibrated
    /// against SF on the Mac: 1.32 × pt on the half-point grid).
    static func side(for pointSize: CGFloat) -> CGFloat {
        (pointSize * 1.32 * 2).rounded() / 2
    }

    /// Stroke multiplier per weight — SF's own weight steps.
    static func strokeScale(for weight: UIFont.Weight) -> CGFloat {
        let w = weight.rawValue
        if w < UIFont.Weight.regular.rawValue { return 0.9 }
        if w < UIFont.Weight.medium.rawValue { return 1.0 }
        if w < UIFont.Weight.semibold.rawValue { return 1.12 }
        if w < UIFont.Weight.bold.rawValue { return 1.25 }
        return 1.38
    }

    // MARK: - Rendering

    private static let imageCache = NSCache<NSString, UIImage>()

    private static func rendered(_ name: String, pointSize: CGFloat, weight: UIFont.Weight, color: UIColor?) -> UIImage? {
        guard let kit = kitName(for: name), let shapes = shapes(for: kit) else {
            assertionFailure("CCIcon: no kit glyph for \"\(name)\" — chrome never falls back to SF Symbols")
            return nil
        }
        let colorKey = color.map { c -> String in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return "\(r),\(g),\(b),\(a)"
        } ?? "template"
        let key = "\(kit)|\(pointSize)|\(weight.rawValue)|\(colorKey)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        let side = Self.side(for: pointSize)
        let stroke = 1.75 * strokeScale(for: weight)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            draw(shapes, in: context.cgContext, rect: CGRect(x: 0, y: 0, width: side, height: side),
                 stroke: stroke, color: (color ?? .black).cgColor)
        }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func draw(_ shapes: [Shape], in ctx: CGContext, rect: CGRect, stroke: CGFloat, color: CGColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let scale = min(rect.width, rect.height) / 24
        ctx.translateBy(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        for shape in shapes {
            ctx.addPath(shape.path)
            if shape.fill && shape.stroke {
                ctx.drawPath(using: .fillStroke)
            } else if shape.fill {
                ctx.fillPath()
            } else {
                ctx.strokePath()
            }
        }
    }

    // MARK: - Parsing (cached)

    struct Shape {
        let path: CGPath
        let fill: Bool
        let stroke: Bool
    }

    private static var cache: [String: [Shape]] = [:]

    static func shapes(for kit: String) -> [Shape]? {
        if let hit = cache[kit] { return hit }
        guard let markup = CCIconSet.icons[kit] else { return nil }
        let parsed = parseMarkup(markup)
        cache[kit] = parsed
        return parsed
    }

    static func parseMarkup(_ markup: String) -> [Shape] {
        var shapes: [Shape] = []
        let element = try! NSRegularExpression(pattern: #"<(path|circle|rect|line)\b([^>]*)/?>"#)
        let ns = markup as NSString
        for match in element.matches(in: markup, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1))
            let attrs = attributes(ns.substring(with: match.range(at: 2)))
            let fill = attrs["fill"].map { $0 != "none" } ?? false
            let stroke = attrs["stroke"].map { $0 != "none" } ?? true
            let path = CGMutablePath()
            func n(_ key: String) -> CGFloat { CGFloat(Double(attrs[key] ?? "") ?? 0) }
            switch tag {
            case "path":
                appendPathData(attrs["d"] ?? "", to: path)
            case "circle":
                path.addEllipse(in: CGRect(x: n("cx") - n("r"), y: n("cy") - n("r"), width: 2 * n("r"), height: 2 * n("r")))
            case "rect":
                let r = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
                let rx = min(n("rx"), r.width / 2, r.height / 2)
                if rx > 0 {
                    path.addRoundedRect(in: r, cornerWidth: rx, cornerHeight: rx)
                } else {
                    path.addRect(r)
                }
            case "line":
                path.move(to: CGPoint(x: n("x1"), y: n("y1")))
                path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
            default:
                continue
            }
            if !path.isEmpty { shapes.append(Shape(path: path, fill: fill, stroke: stroke)) }
        }
        return shapes
    }

    private static func attributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let attr = try! NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9-]*)\s*=\s*"([^"]*)""#)
        let ns = text as NSString
        for m in attr.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    /// SVG path data → CGPath. Returns false when the data stopped short.
    @discardableResult
    static func appendPathData(_ d: String, to path: CGMutablePath) -> Bool {
        var tokens = tokenize(d)
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = "M"
        func num() -> CGFloat? {
            guard i < tokens.count, case .number(let v, _) = tokens[i] else { return nil }
            i += 1
            return CGFloat(v)
        }
        func flag() -> Bool? {
            guard i < tokens.count, case .number(let v, _) = tokens[i] else { return nil }
            let text = tokens[i].raw
            if text.count > 1, let first = text.first, first == "0" || first == "1" {
                let rest = String(text.dropFirst())
                tokens[i] = .number(Double(rest) ?? 0, rest)
                return first == "1"
            }
            i += 1
            return v != 0
        }
        while i < tokens.count {
            if case .command(let c) = tokens[i] {
                cmd = c
                i += 1
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    cur = start
                    lastControl = nil
                    lastCommand = c
                    continue
                }
            }
            let rel = cmd.isLowercase
            let base = rel ? cur : .zero
            switch cmd.uppercased().first! {
            case "M":
                guard let x = num(), let y = num() else { return false }
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.move(to: cur)
                start = cur
                cmd = rel ? "l" : "L"
                lastControl = nil
            case "L":
                guard let x = num(), let y = num() else { return false }
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addLine(to: cur)
                lastControl = nil
            case "H":
                guard let x = num() else { return false }
                cur = CGPoint(x: (rel ? cur.x : 0) + x, y: cur.y)
                path.addLine(to: cur)
                lastControl = nil
            case "V":
                guard let y = num() else { return false }
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y)
                path.addLine(to: cur)
                lastControl = nil
            case "C":
                guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return false }
                let c1 = CGPoint(x: base.x + x1, y: base.y + y1)
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastControl = c2
            case "S":
                guard let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return false }
                let reflected = ("CcSs".contains(lastCommand) ? lastControl : nil).map {
                    CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y)
                } ?? cur
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: cur, control1: reflected, control2: c2)
                lastControl = c2
            case "Q":
                guard let x1 = num(), let y1 = num(), let x = num(), let y = num() else { return false }
                let c = CGPoint(x: base.x + x1, y: base.y + y1)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastControl = c
            case "T":
                guard let x = num(), let y = num() else { return false }
                let c = ("QqTt".contains(lastCommand) ? lastControl : nil).map {
                    CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y)
                } ?? cur
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastControl = c
            case "A":
                guard let rx = num(), let ry = num(), let rot = num(),
                      let large = flag(), let sweep = flag(), let x = num(), let y = num() else { return false }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                addArc(to: path, from: cur, to: end, rx: abs(rx), ry: abs(ry), rotationDegrees: rot, largeArc: large, sweep: sweep)
                cur = end
                lastControl = nil
            default:
                return false
            }
            lastCommand = cmd
        }
        return true
    }

    /// SVG endpoint arc (spec F.6.5) as a transformed unit-circle arc.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = rxIn, ry = ryIn
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotationDegrees * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let transform = CGAffineTransform(translationX: cx, y: cy).rotated(by: phi).scaledBy(x: rx, y: ry)
        path.addArc(center: .zero, radius: 1, startAngle: theta1, endAngle: theta1 + delta,
                    clockwise: delta < 0, transform: transform)
    }

    private enum Token {
        case command(Character)
        case number(Double, String)
        var raw: String {
            switch self {
            case .command(let c): return String(c)
            case .number(_, let s): return s
            }
        }
    }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var numberText = ""
        func flush() {
            if !numberText.isEmpty {
                tokens.append(.number(Double(numberText) ?? 0, numberText))
                numberText = ""
            }
        }
        for ch in d {
            if "MmLlHhVvCcSsQqTtAaZz".contains(ch) {
                flush()
                tokens.append(.command(ch))
            } else if ch == "-" {
                if let last = numberText.last, last == "e" || last == "E" {
                    numberText.append(ch)
                } else {
                    flush()
                    numberText.append(ch)
                }
            } else if ch == "." {
                if numberText.contains(".") { flush() }
                numberText.append(ch)
            } else if ch.isNumber || ch == "e" || ch == "E" {
                numberText.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}

/// An image view showing a kit icon, tinted by a (dynamic) color.
final class CCIconView: UIImageView {
    var iconName: String { didSet { refresh() } }
    var pointSize: CGFloat { didSet { refresh() } }
    var weight: UIFont.Weight { didSet { refresh() } }

    init(_ name: String, pointSize: CGFloat = 17, weight: UIFont.Weight = .regular, tint: UIColor = CCTheme.color.foreground) {
        self.iconName = name
        self.pointSize = pointSize
        self.weight = weight
        super.init(frame: .zero)
        tintColor = tint
        contentMode = .center
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false
        // A glyph is exactly its box: stack views never stretch it.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: axis)
            setContentCompressionResistancePriority(.required, for: axis)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        let side = CCIcon.side(for: pointSize)
        return CGSize(width: side, height: side)
    }

    private func refresh() {
        image = CCIcon.image(iconName, pointSize: pointSize, weight: weight)
        invalidateIntrinsicContentSize()
    }
}
