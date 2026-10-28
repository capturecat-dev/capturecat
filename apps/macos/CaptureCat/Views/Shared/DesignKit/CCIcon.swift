import AppKit

// CCIcon — CaptureCat's own icon kit (2026-10-27 restyle: "draw our own
// icon kit"), replacing SF Symbols in the app's CHROME.
//
// Icons are line drawings on a 24 × 24 grid (stroke 1.75, round caps and
// joins; solid parts fill), stored as a small SVG subset in
// CCIconSet.swift — <path d> (M L H V C Q A Z, absolute and relative),
// <circle>, <rect rx>, <line>. They render as TEMPLATE images, so every
// existing `contentTintColor` keeps working, in a square box calibrated to
// the SF Symbol of the same point size (`side(for:)`), with the stroke
// thickened for heavier weights on SF's own curve (`strokeScale`).
//
// Call sites ask by their old SF Symbol name (`CCIcon.image("sparkles",
// pointSize: 13, weight: .semibold)`); `CCIconSet.aliases` maps it to a kit
// icon. A name the kit does not draw falls back to the SF Symbol, so a
// missing icon degrades instead of vanishing.
//
// Adding an icon: draw it in apps/macos/IconKit/icons.json (+ an alias if a
// call site asks by SF name), run `python3 apps/macos/IconKit/gen-iconset.py`,
// build, and run `CaptureCat --iconkit-test` (CCIconKitHarness).
//
// CONTENT never uses this: glyphs drawn INTO recordings and exports
// (MenuBarRenderer's battery/wifi), the selection pill (SelectionChromeKit,
// frozen in --raster-golden) and the web oracles stay SF Symbols — the
// exporter, the preview and the web editor's parity all depend on them.
enum CCIcon {
    /// The kit icon a name resolves to (a kit name, or an SF alias), if any.
    static func kitName(for name: String) -> String? {
        if CCIconSet.icons[name] != nil { return name }
        return CCIconSet.aliases[name]
    }

    static func has(_ name: String) -> Bool { kitName(for: name) != nil }

    /// A template image for `name` at an SF-Symbol-equivalent `pointSize`.
    static func image(
        _ name: String,
        pointSize: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        guard let kit = kitName(for: name), let shapes = shapes(for: kit) else {
            return NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        }
        let side = Self.side(for: pointSize)
        let stroke = 1.75 * strokeScale(for: weight)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(shapes, in: ctx, rect: rect, stroke: stroke, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// A NON-template image painted in `color`, for places nothing tints:
    /// CALayer `contents`, CG-drawn canvases, two-tone compositions. Same box
    /// and stroke as the template variant. A name the kit does not draw falls
    /// back to the SF Symbol in a one-colour palette.
    static func image(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor
    ) -> NSImage? {
        guard let kit = kitName(for: name), let shapes = shapes(for: kit) else {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
        let side = Self.side(for: pointSize)
        let stroke = 1.75 * strokeScale(for: weight)
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(shapes, in: ctx, rect: rect, stroke: stroke, color: color)
            return true
        }
    }

    /// Draw a kit icon straight into a context (CALayer-based callers).
    /// `rect` is in the context's own space; Y-down is assumed.
    static func draw(_ name: String, in ctx: CGContext, rect: CGRect, color: NSColor, weight: NSFont.Weight = .regular) {
        guard let kit = kitName(for: name), let shapes = shapes(for: kit) else { return }
        draw(shapes, in: ctx, rect: rect, stroke: 1.75 * strokeScale(for: weight), color: color)
    }

    // MARK: - Rendering

    /// The square box (pt) a kit icon occupies at an SF point size.
    ///
    /// Calibrated against SF Symbols over every alias (2026-10-27): at 1.2·P
    /// the kit measured a median 0.82–0.93× the SF glyph's extent and
    /// 0.69–0.90× its ink, so swapped-in icons read small and faint (worst
    /// at 8–11pt semibold — the editor's 16:9 chevron). 1.32·P, on the
    /// half-point grid (pixel-exact at 2x), lands at 0.92–0.98× extent.
    static func side(for pointSize: CGFloat) -> CGFloat {
        (pointSize * 1.32 * 2).rounded() / 2
    }

    /// Stroke multiplier per weight — SF's weight steps, measured: its
    /// semibold carries ~1.3× regular's ink, so 1.16 read light (kit/SF ink
    /// 0.69–0.80 at semibold); this curve puts it at 0.92–1.0.
    static func strokeScale(for weight: NSFont.Weight) -> CGFloat {
        switch weight {
        case ..<NSFont.Weight.regular: return 0.9
        case ..<NSFont.Weight.medium: return 1.0
        case ..<NSFont.Weight.semibold: return 1.12
        case ..<NSFont.Weight.bold: return 1.25
        default: return 1.38
        }
    }

    private static func draw(_ shapes: [Shape], in ctx: CGContext, rect: CGRect, stroke: CGFloat, color: NSColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let scale = min(rect.width, rect.height) / 24
        ctx.translateBy(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
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

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Shape]] = [:]

    static func shapes(for kit: String) -> [Shape]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[kit] { return hit }
        guard let markup = CCIconSet.icons[kit] else { return nil }
        let parsed = parseMarkup(markup)
        cache[kit] = parsed
        return parsed
    }

    /// Parses the SVG subset. Unknown elements are ignored (and caught by
    /// the --iconkit-test gate, which requires every icon to yield shapes).
    static func parseMarkup(_ markup: String) -> [Shape] {
        var shapes: [Shape] = []
        let element = try! NSRegularExpression(pattern: #"<(path|circle|rect|line)\b([^>]*)/?>"#)
        let ns = markup as NSString
        for match in element.matches(in: markup, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1))
            let attrs = attributes(ns.substring(with: match.range(at: 2)))
            let fill = attrs["fill"].map { $0 != "none" } ?? false
            // The kit strokes EVERY element; fill="currentColor" adds a nonzero
            // fill on top (knockouts are reverse-wound subpaths).
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
        // Names carry digits (`x1`, `y2`) — a letters-only pattern silently
        // dropped every <line> to (0,0) (caught by --iconkit-test).
        let attr = try! NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9-]*)\s*=\s*"([^"]*)""#)
        let ns = text as NSString
        for m in attr.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    /// SVG path data → CGPath (M L H V C S Q T A Z, absolute and relative).
    /// Returns false when the data stopped short of its end (a malformed or
    /// unsupported command) — the --iconkit-test gate requires true for every
    /// kit path, since a partial path still draws and would pass unnoticed.
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
            // Arc flags may be packed ("011"): split a leading 0/1 off a number.
            // A flag is exactly one character, so "012" is 0, 1, then 2 and
            // "0.5" after a flag is 0 then .5.
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
                // Implicit lineto for extra coordinate pairs.
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
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
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
                // A minus starts a new number unless it follows an exponent.
                if let last = numberText.last, last == "e" || last == "E" {
                    numberText.append(ch)
                } else {
                    flush()
                    numberText.append(ch)
                }
            } else if ch == "." {
                // A second dot starts a new number (".5.5" → 0.5, 0.5).
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
