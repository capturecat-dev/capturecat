import AppKit
import CoreGraphics
import CoreText

// Draw-op recording + replay for the OVERLAY cluster's draw-recipe units.
//
// `WVRecCtx` mirrors the subset of the CGContext API the overlay renderers
// use. Every call is FORWARDED to a real CGContext (so the oracle really
// draws, and CTM-dependent logic reads the real `ctm`) AND recorded as a
// self-contained op (paint ops carry the resolved CG state: colour, line
// width, cap, join, dash). `WVReplay.render` draws a recorded op list back
// through CoreGraphics; the recipe units require
//   real renderer pixels == oracle pixels == replay(ops) pixels
// byte for byte, which proves the op list is a complete description of the
// real drawing. The TS ports (overlaySupport.ts RecordingContext) emit the
// same op vocabulary.

struct WVRGBA: Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ c: CGColor) {
        let comps = c.components ?? [0, 0, 0, 1]
        if comps.count == 2 {
            self.init(r: comps[0], g: comps[0], b: comps[0], a: comps[1])
        } else if comps.count >= 4 {
            self.init(r: comps[0], g: comps[1], b: comps[2], a: comps[3])
        } else {
            self.init(r: 0, g: 0, b: 0, a: 1)
        }
    }

    init(_ c: SRGBA) { self.init(r: c.red, g: c.green, b: c.blue, a: c.alpha) }

    var wv: WV { ["r": r.wv, "g": g.wv, "b": b.wv, "a": a.wv] }
    var srgba: SRGBA { SRGBA(red: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// A gradient the recorder can describe: either explicit stops (sRGB) or an
/// Oklab two-colour ramp (OklabGradient.gradient(from:to:)).
struct WVGradient {
    enum Kind { case stops(colors: [WVRGBA], locations: [CGFloat]), oklab(from: SRGBA, to: SRGBA) }
    let kind: Kind
    let cg: CGGradient

    var wv: WV {
        switch kind {
        case .stops(let colors, let locations):
            return ["kind": "stops", "colors": .arr(colors.map(\.wv)), "locations": locations.wv]
        case .oklab(let from, let to):
            return ["kind": "oklab", "from": WVRGBA(from).wv, "to": WVRGBA(to).wv]
        }
    }
}

final class WVRecCtx {
    let ctx: CGContext
    private(set) var ops: [WV] = []

    private struct GState {
        var fill = WVRGBA(r: 0, g: 0, b: 0, a: 1)
        var stroke = WVRGBA(r: 0, g: 0, b: 0, a: 1)
        var lineWidth: CGFloat = 1
        var cap = "butt"
        var join = "miter"
        var miterLimit: CGFloat = 10
        var dash: [CGFloat]? = nil
        var dashPhase: CGFloat = 0
    }
    private var gs = GState()
    private var stack: [GState] = []
    private var path: [WV] = []

    init(_ ctx: CGContext) { self.ctx = ctx }

    var ctm: CGAffineTransform { ctx.ctm }

    func record(_ op: WV) { ops.append(op) }

    // State
    func saveGState() { ctx.saveGState(); stack.append(gs); ops.append(["op": "save"]) }
    func restoreGState() { ctx.restoreGState(); gs = stack.removeLast(); ops.append(["op": "restore"]) }
    func translateBy(x: CGFloat, y: CGFloat) { ctx.translateBy(x: x, y: y); ops.append(["op": "translate", "x": x.wv, "y": y.wv]) }
    func scaleBy(x: CGFloat, y: CGFloat) { ctx.scaleBy(x: x, y: y); ops.append(["op": "scale", "x": x.wv, "y": y.wv]) }
    func setAlpha(_ a: CGFloat) { ctx.setAlpha(a); ops.append(["op": "alpha", "alpha": a.wv]) }
    func beginTransparencyLayer(auxiliaryInfo: CFDictionary?) {
        ctx.beginTransparencyLayer(auxiliaryInfo: auxiliaryInfo); ops.append(["op": "beginLayer"])
    }
    func endTransparencyLayer() { ctx.endTransparencyLayer(); ops.append(["op": "endLayer"]) }
    func setShadow(offset: CGSize, blur: CGFloat, color: CGColor?) {
        ctx.setShadow(offset: offset, blur: blur, color: color)
        ops.append(["op": "shadow", "offsetX": offset.width.wv, "offsetY": offset.height.wv, "blur": blur.wv,
                    "color": color.map { WVRGBA($0).wv } ?? .null])
    }
    func setFillColor(_ c: CGColor) { ctx.setFillColor(c); gs.fill = WVRGBA(c) }
    func setStrokeColor(_ c: CGColor) { ctx.setStrokeColor(c); gs.stroke = WVRGBA(c) }
    func setLineWidth(_ w: CGFloat) { ctx.setLineWidth(w); gs.lineWidth = w }
    func setLineCap(_ cap: CGLineCap) {
        ctx.setLineCap(cap)
        gs.cap = cap == .round ? "round" : cap == .square ? "square" : "butt"
    }
    func setLineJoin(_ join: CGLineJoin) {
        ctx.setLineJoin(join)
        gs.join = join == .round ? "round" : join == .bevel ? "bevel" : "miter"
    }
    func setLineDash(phase: CGFloat, lengths: [CGFloat]) {
        ctx.setLineDash(phase: phase, lengths: lengths)
        gs.dash = lengths.isEmpty ? nil : lengths
        gs.dashPhase = phase
    }

    // Path construction (recorded in user space; the CTM never changes
    // between building and painting a path in these renderers).
    func beginPath() { ctx.beginPath(); path = [] }
    func move(to p: CGPoint) { ctx.move(to: p); path.append(["M", p.x.wv, p.y.wv]) }
    func addLine(to p: CGPoint) { ctx.addLine(to: p); path.append(["L", p.x.wv, p.y.wv]) }
    func closePath() { ctx.closePath(); path.append(["Z"]) }
    func addPath(_ p: CGPath) { ctx.addPath(p); path += WebVectors.pathElements(p) }
    func addEllipse(in rect: CGRect) {
        ctx.addEllipse(in: rect)
        path += WebVectors.pathElements(CGPath(ellipseIn: rect, transform: nil))
    }

    // Painting
    private func strokeOp(_ p: [WV]) -> WV {
        [
            "op": "stroke", "path": .arr(p), "color": gs.stroke.wv, "lineWidth": gs.lineWidth.wv,
            "cap": .str(gs.cap), "join": .str(gs.join), "miterLimit": gs.miterLimit.wv,
            "dash": gs.dash.map { $0.wv } ?? .null, "dashPhase": gs.dashPhase.wv,
        ]
    }

    func fillPath(using rule: CGPathFillRule = .winding) {
        ctx.fillPath(using: rule)
        ops.append(["op": "fill", "path": .arr(path), "color": gs.fill.wv, "evenOdd": (rule == .evenOdd).wv])
        path = []
    }
    func strokePath() {
        ctx.strokePath()
        ops.append(strokeOp(path))
        path = []
    }
    func fillEllipse(in rect: CGRect) {
        ctx.fillEllipse(in: rect)
        ops.append(["op": "fill", "path": WebVectors.pathWV(CGPath(ellipseIn: rect, transform: nil)),
                    "color": gs.fill.wv, "evenOdd": false])
        path = []
    }
    func strokeEllipse(in rect: CGRect) {
        ctx.strokeEllipse(in: rect)
        ops.append(strokeOp(WebVectors.pathElements(CGPath(ellipseIn: rect, transform: nil))))
        path = []
    }
    func clip(using rule: CGPathFillRule = .winding) {
        ctx.clip(using: rule)
        ops.append(["op": "clip", "path": .arr(path), "evenOdd": (rule == .evenOdd).wv])
        path = []
    }
    func drawRadialGradient(
        _ g: WVGradient, startCenter: CGPoint, startRadius: CGFloat,
        endCenter: CGPoint, endRadius: CGFloat, options: CGGradientDrawingOptions
    ) {
        ctx.drawRadialGradient(g.cg, startCenter: startCenter, startRadius: startRadius,
                               endCenter: endCenter, endRadius: endRadius, options: options)
        ops.append([
            "op": "radialGradient", "gradient": g.wv,
            "startCenter": startCenter.wv, "startRadius": startRadius.wv,
            "endCenter": endCenter.wv, "endRadius": endRadius.wv,
            "before": options.contains(.drawsBeforeStartLocation).wv,
            "after": options.contains(.drawsAfterEndLocation).wv,
        ])
    }
}

// MARK: - Replay

enum WVReplay {
    static func num(_ v: WV?) -> CGFloat {
        switch v {
        case .num(let d)?: return CGFloat(d)
        case .int(let i)?: return CGFloat(i)
        default: return 0
        }
    }

    static func bool(_ v: WV?) -> Bool {
        if case .bool(let b)? = v { return b }
        return false
    }

    static func str(_ v: WV?) -> String? {
        if case .str(let s)? = v { return s }
        return nil
    }

    static func arr(_ v: WV?) -> [WV] {
        if case .arr(let a)? = v { return a }
        return []
    }

    static func point(_ v: WV?) -> CGPoint { CGPoint(x: num(v?["x"]), y: num(v?["y"])) }

    static func rect(_ v: WV?) -> CGRect {
        CGRect(x: num(v?["x"]), y: num(v?["y"]), width: num(v?["width"]), height: num(v?["height"]))
    }

    static func rgba(_ v: WV?) -> WVRGBA {
        WVRGBA(r: num(v?["r"]), g: num(v?["g"]), b: num(v?["b"]), a: num(v?["a"]))
    }

    static func path(_ v: WV?) -> CGPath {
        let p = CGMutablePath()
        for el in arr(v) {
            let parts = arr(el)
            guard let tag = str(parts.first) else { continue }
            let n = parts.dropFirst().map { num($0) }
            switch tag {
            case "M": p.move(to: CGPoint(x: n[0], y: n[1]))
            case "L": p.addLine(to: CGPoint(x: n[0], y: n[1]))
            case "Q": p.addQuadCurve(to: CGPoint(x: n[2], y: n[3]), control: CGPoint(x: n[0], y: n[1]))
            case "C": p.addCurve(to: CGPoint(x: n[4], y: n[5]), control1: CGPoint(x: n[0], y: n[1]),
                                 control2: CGPoint(x: n[2], y: n[3]))
            case "Z": p.closeSubpath()
            default: break
            }
        }
        return p
    }

    static func gradient(_ v: WV?) -> CGGradient? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if str(v?["kind"]) == "oklab" {
            return OklabGradient.gradient(from: rgba(v?["from"]).srgba, to: rgba(v?["to"]).srgba)
        }
        let colors = arr(v?["colors"]).map { rgba($0).cgColor }
        let locations = arr(v?["locations"]).map { num($0) }
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    }

    /// Replays an annotation/keystroke op list (canvas space; the caller set
    /// up the base transform). `text` ops are drawn by `drawText`.
    static func render(_ ops: [WV], in ctx: CGContext, drawText: (WV, CGContext) -> Void) {
        for op in ops {
            switch str(op["op"]) ?? "" {
            case "save": ctx.saveGState()
            case "restore": ctx.restoreGState()
            case "translate": ctx.translateBy(x: num(op["x"]), y: num(op["y"]))
            case "scale": ctx.scaleBy(x: num(op["x"]), y: num(op["y"]))
            case "alpha": ctx.setAlpha(num(op["alpha"]))
            case "beginLayer": ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            case "endLayer": ctx.endTransparencyLayer()
            case "shadow":
                let color: CGColor? = op["color"].flatMap { if case .null = $0 { return nil } else { return rgba($0).cgColor } }
                ctx.setShadow(offset: CGSize(width: num(op["offsetX"]), height: num(op["offsetY"])),
                              blur: num(op["blur"]), color: color)
            case "fill":
                ctx.saveGState()
                ctx.setFillColor(rgba(op["color"]).cgColor)
                ctx.addPath(path(op["path"]))
                ctx.fillPath(using: bool(op["evenOdd"]) ? .evenOdd : .winding)
                ctx.restoreGState()
            case "stroke":
                ctx.saveGState()
                ctx.setStrokeColor(rgba(op["color"]).cgColor)
                ctx.setLineWidth(num(op["lineWidth"]))
                switch str(op["cap"]) {
                case "round": ctx.setLineCap(.round)
                case "square": ctx.setLineCap(.square)
                default: ctx.setLineCap(.butt)
                }
                switch str(op["join"]) {
                case "round": ctx.setLineJoin(.round)
                case "bevel": ctx.setLineJoin(.bevel)
                default: ctx.setLineJoin(.miter)
                }
                ctx.setMiterLimit(num(op["miterLimit"]))
                let dash = arr(op["dash"]).map { num($0) }
                if !dash.isEmpty { ctx.setLineDash(phase: num(op["dashPhase"]), lengths: dash) }
                ctx.addPath(path(op["path"]))
                ctx.strokePath()
                ctx.restoreGState()
            case "clip":
                ctx.addPath(path(op["path"]))
                ctx.clip(using: bool(op["evenOdd"]) ? .evenOdd : .winding)
            case "radialGradient":
                guard let g = gradient(op["gradient"]) else { continue }
                var options: CGGradientDrawingOptions = []
                if bool(op["before"]) { options.insert(.drawsBeforeStartLocation) }
                if bool(op["after"]) { options.insert(.drawsAfterEndLocation) }
                ctx.drawRadialGradient(g, startCenter: point(op["startCenter"]), startRadius: num(op["startRadius"]),
                                       endCenter: point(op["endCenter"]), endRadius: num(op["endRadius"]),
                                       options: options)
            case "text", "ctText":
                drawText(op, ctx)
            default:
                print("WEB-VECTORS FAIL replay: unknown op \(op.serialized())")
            }
        }
    }

    /// Byte-compares two rasters; returns the number of differing bytes
    /// (-1 when sizes differ / either is missing).
    static func diff(_ a: CGImage?, _ b: CGImage?) -> Int {
        guard let a, let b, a.width == b.width, a.height == b.height else {
            return (a == nil && b == nil) ? 0 : -1
        }
        guard let da = bytes(a), let db = bytes(b), da.count == db.count else { return -1 }
        var n = 0
        for i in 0..<da.count where da[i] != db[i] { n += 1 }
        return n
    }

    /// RGBA8 premultiplied bytes of `img` (normalized through one context so
    /// differing bitmap layouts compare by pixel value).
    static func bytes(_ img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }

    /// Same-layout bitmap for oracle/replay rendering (premultipliedFirst +
    /// byteOrder32Little, sRGB) — what the real overlay renderers allocate.
    static func bitmap(width: Int, height: Int, premultipliedLast: Bool = false) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = premultipliedLast
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: info)
    }
}
