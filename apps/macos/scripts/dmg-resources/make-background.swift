// Renders the DMG installer window's background (720 × 460 pt) at 1x and 2x.
//
//   swift scripts/dmg-resources/make-background.swift <out-dir>
//
// writes background.png and background@2x.png; create_release_dmg.sh hands
// both to appdmg, which makes the HiDPI pair. Light like the 2026 site, and
// CaptureCat's own idea of "drag to install": the window IS a recording in
// progress — viewfinder corners, a REC timecode, a presenter's camera
// bubble — and the drag is drawn twice, the shaky raw cursor path under the
// smoothed glide CaptureCat would turn it into, ending in a click ripple on
// Applications. A mini editor timeline (a zoom block, the playhead) runs
// along the bottom.
//
// Icon centres are fixed by create_release_dmg.sh's appdmg spec: the app at
// (220, 226), Applications at (500, 226), icons 128 pt. Keep them in sync.

import AppKit
import CoreGraphics

let W: CGFloat = 720
let H: CGFloat = 460

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xff) / 255
        g = CGFloat((hex >> 8) & 0xff) / 255
        b = CGFloat(hex & 0xff) / 255
    }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

let ink = RGB(0x0B0B0F)
let faint = RGB(0x8A8A96)

/// Global multiplier for shadow geometry: CGContext shadows live in device
/// space and ignore the CTM, so they are scaled by hand per render.
var shadowScale: CGFloat = 1

func shadow(_ ctx: CGContext, y: CGFloat, blur: CGFloat, color: CGColor) {
    // Y-down CTM: a positive offset must be negated to fall downwards on screen.
    ctx.setShadow(offset: CGSize(width: 0, height: -y * shadowScale), blur: blur * shadowScale, color: color)
}

// ── Drawing helpers (Y-down, points) ─────────────────────────────────────────

/// The macOS arrow (the site's demo cursor, tip at the origin), 28 × 40 units.
func arrowPath(scale s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 28.2), (7.1, 21.7), (11.7, 32.6), (16.6, 30.5), (12, 19.9), (21.8, 19.9)]
    p.move(to: CGPoint(x: pts[0].0 * s, y: pts[0].1 * s))
    for (x, y) in pts.dropFirst() { p.addLine(to: CGPoint(x: x * s, y: y * s)) }
    p.closeSubpath()
    return p
}

func drawCursor(_ ctx: CGContext, tip: CGPoint, angle: CGFloat, fill: CGColor, scale: CGFloat = 0.78) {
    ctx.saveGState()
    ctx.translateBy(x: tip.x, y: tip.y)
    ctx.rotate(by: angle)
    let path = arrowPath(scale: scale)
    shadow(ctx, y: 2, blur: 5, color: CGColor(gray: 0, alpha: 0.22))
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(1.8)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

func drawText(_ text: String, at center: CGPoint, size: CGFloat, weight: NSFont.Weight, color: CGColor) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .black]
    let s = NSAttributedString(string: text, attributes: attrs)
    let b = s.size()
    s.draw(at: NSPoint(x: center.x - b.width / 2, y: center.y - b.height / 2))
}

/// A soft white pill with a hairline, the site's chip.
func drawChip(_ ctx: CGContext, rect: CGRect, fill: CGColor = CGColor(gray: 1, alpha: 1)) {
    let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
    ctx.saveGState()
    shadow(ctx, y: 4, blur: 12, color: CGColor(gray: 0, alpha: 0.12))
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.07))
    ctx.setLineWidth(1)
    ctx.strokePath()
}

// ── Composition ──────────────────────────────────────────────────────────────

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    // A rep whose `size` is in points can come with its backing scale
    // already on the CTM: add only what is missing, then flip to Y-down so
    // the layout reads like the window.
    let existing = ctx.ctm.a
    if abs(existing - scale) > 0.001 { ctx.scaleBy(x: scale / existing, y: scale / existing) }
    shadowScale = scale
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    // AppKit text draws upright in a Y-down CTM only through a context that
    // says it is flipped.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    // Paper, with a whisper of the site's dusk in two corners.
    ctx.setFillColor(RGB(0xFBFBFD).cg())
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func glow(_ c: CGPoint, _ radius: CGFloat, _ color: RGB, _ alpha: CGFloat) {
        let g = CGGradient(colorsSpace: space, colors: [color.cg(alpha), color.cg(0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }
    glow(CGPoint(x: 40, y: 20), 300, RGB(0x8B5CF6), 0.10)
    glow(CGPoint(x: 700, y: 450), 320, RGB(0xFF9A7A), 0.12)
    glow(CGPoint(x: 680, y: 40), 220, RGB(0x2F7BFF), 0.07)

    // Viewfinder corners: the window is being recorded.
    let inset: CGFloat = 18, arm: CGFloat = 24
    ctx.setStrokeColor(ink.cg(0.2))
    ctx.setLineWidth(2)
    ctx.setLineCap(.round)
    for (x, y, sx, sy) in [(inset, inset, 1.0, 1.0), (W - inset, inset, -1.0, 1.0),
                           (inset, H - inset, 1.0, -1.0), (W - inset, H - inset, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        ctx.move(to: CGPoint(x: x, y: y + sy * arm))
        ctx.addLine(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + sx * arm, y: y))
        ctx.strokePath()
    }

    // REC pill with a timecode, top centre.
    let rec = CGRect(x: W / 2 - 50, y: 30, width: 100, height: 26)
    drawChip(ctx, rect: rec)
    ctx.addEllipse(in: CGRect(x: rec.minX + 12, y: rec.midY - 4.5, width: 9, height: 9))
    ctx.setFillColor(RGB(0xFF3B30).cg())
    ctx.fillPath()
    drawText("REC", at: CGPoint(x: rec.minX + 38, y: rec.midY), size: 11, weight: .bold, color: ink.cg())
    drawText("00:07", at: CGPoint(x: rec.maxX - 26, y: rec.midY), size: 11.5, weight: .medium, color: ink.cg(0.55))

    // The presenter's camera bubble, top right, like a recording's webcam.
    let bubble = CGRect(x: W - 104, y: 44, width: 60, height: 60)
    ctx.saveGState()
    shadow(ctx, y: 4, blur: 12, color: CGColor(gray: 0, alpha: 0.22))
    ctx.addEllipse(in: bubble)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    let face = bubble.insetBy(dx: 3, dy: 3)
    ctx.addEllipse(in: face)
    ctx.clip()
    let room = CGGradient(colorsSpace: space, colors: [RGB(0x3A4A63).cg(), RGB(0x1F2636).cg()] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(room, start: CGPoint(x: face.midX, y: face.minY), end: CGPoint(x: face.midX, y: face.maxY), options: [])
    let u = face.width / 100
    ctx.addEllipse(in: CGRect(x: face.minX + 14 * u, y: face.minY + 68 * u, width: 72 * u, height: 70 * u))
    ctx.setFillColor(RGB(0x5B7CFA).cg())
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: face.minX + 33 * u, y: face.minY + 22 * u, width: 34 * u, height: 40 * u))
    ctx.setFillColor(RGB(0xE8B590).cg())
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: face.minX + 31 * u, y: face.minY + 16 * u, width: 38 * u, height: 22 * u))
    ctx.setFillColor(RGB(0x2B2320).cg())
    ctx.fillPath()
    ctx.restoreGState()

    // The drag, twice: the raw pointer (shaky, faint) under the smoothed
    // glide CaptureCat makes of it, from the app to Applications.
    let start = CGPoint(x: 288, y: 176)
    let end = CGPoint(x: 416, y: 154)
    let c1 = CGPoint(x: 320, y: 106), c2 = CGPoint(x: 384, y: 98)
    func bezier(_ t: CGFloat) -> CGPoint {
        let m = 1 - t
        return CGPoint(
            x: m * m * m * start.x + 3 * m * m * t * c1.x + 3 * m * t * t * c2.x + t * t * t * end.x,
            y: m * m * m * start.y + 3 * m * m * t * c1.y + 3 * m * t * t * c2.y + t * t * t * end.y)
    }
    let raw = CGMutablePath()
    raw.move(to: start)
    for i in 1...36 {
        let t = CGFloat(i) / 36
        let p = bezier(t)
        // Deterministic hand tremor, fading out at both ends.
        let env = sin(t * .pi)
        let jx = (sin(CGFloat(i) * 2.7) * 4.5 + sin(CGFloat(i) * 7.3) * 2) * env
        let jy = (cos(CGFloat(i) * 3.1) * 4.5 + sin(CGFloat(i) * 5.9) * 2.4) * env + 10 * env
        raw.addLine(to: CGPoint(x: p.x + jx, y: p.y + jy))
    }
    ctx.addPath(raw)
    ctx.setStrokeColor(ink.cg(0.18))
    ctx.setLineWidth(1.4)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    let smooth = CGMutablePath()
    smooth.move(to: start)
    smooth.addCurve(to: end, control1: c1, control2: c2)
    ctx.saveGState()
    ctx.addPath(smooth)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let glide = CGGradient(colorsSpace: space, colors: [RGB(0xB18CFF).cg(), RGB(0x7C5CF0).cg(), RGB(0x2F7BFF).cg()] as CFArray,
                           locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(glide, start: start, end: end, options: [])
    ctx.restoreGState()

    // Click ripple where it lands, and the cursor riding in.
    for (i, rad) in [CGFloat(9), 16, 23].enumerated() {
        ctx.addEllipse(in: CGRect(x: end.x - rad, y: end.y - rad, width: 2 * rad, height: 2 * rad))
        ctx.setStrokeColor(RGB(0x2F7BFF).cg(0.5 - CGFloat(i) * 0.14))
        ctx.setLineWidth(1.6)
        ctx.strokePath()
    }
    drawCursor(ctx, tip: CGPoint(x: end.x - 1, y: end.y - 1), angle: 0, fill: ink.cg(), scale: 0.86)

    // The instruction, quietly.
    drawText("Drag CaptureCat into Applications", at: CGPoint(x: W / 2, y: 350), size: 13, weight: .medium, color: faint.cg())

    // A mini editor timeline: video lane, a zoom block, the playhead.
    let track = CGRect(x: 170, y: 382, width: 380, height: 46)
    drawText("VIDEO", at: CGPoint(x: track.minX - 26, y: track.minY + 10), size: 8.5, weight: .semibold, color: faint.cg())
    drawText("EFFECTS", at: CGPoint(x: track.minX - 30, y: track.minY + 34), size: 8.5, weight: .semibold, color: faint.cg())
    let video = CGRect(x: track.minX, y: track.minY + 3, width: track.width, height: 14)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: video, cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.clip()
    let lane = CGGradient(colorsSpace: space, colors: [RGB(0x8B5CF6).cg(0.85), RGB(0x2F7BFF).cg(0.85)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(lane, start: CGPoint(x: video.minX, y: 0), end: CGPoint(x: video.maxX, y: 0), options: [])
    // Thumbnail seams.
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.28))
    var x = video.minX + 38
    while x < video.maxX { ctx.fill(CGRect(x: x, y: video.minY, width: 1, height: video.height)); x += 38 }
    ctx.restoreGState()
    let zoom = CGRect(x: track.minX + track.width * 0.5, y: track.minY + 26, width: track.width * 0.3, height: 16)
    ctx.saveGState()
    shadow(ctx, y: 3, blur: 8, color: RGB(0xFF8A2A).cg(0.3))
    ctx.addPath(CGPath(roundedRect: zoom, cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.setFillColor(RGB(0xFF9F2E).cg())
    ctx.fillPath()
    ctx.restoreGState()
    drawText("Zoom 1.9×", at: CGPoint(x: zoom.midX, y: zoom.midY), size: 9, weight: .semibold, color: RGB(0x4A2500).cg())
    // Playhead (the editor's cyan) at the zoom's start.
    let px = zoom.minX + 18
    ctx.setFillColor(RGB(0x22C3EE).cg())
    ctx.fill(CGRect(x: px - 0.75, y: track.minY - 4, width: 1.5, height: track.height + 4))
    ctx.addEllipse(in: CGRect(x: px - 4.5, y: track.minY - 9, width: 9, height: 9))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    let rep = render(scale: scale)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}
