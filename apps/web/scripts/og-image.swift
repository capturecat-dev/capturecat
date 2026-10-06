// Renders the site-wide social card, public/og.png (1200 × 630).
//
//     swift scripts/og-image.swift
//
// Same look as the marketing pages: near-black background with the two
// radial glows from the page heroes, the app icon, and the tagline.
import AppKit

let width = 1200, height = 630
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
let W = CGFloat(width), H = CGFloat(height)

// Background: oklch(0.145 0 0) ≈ #0a0a0a.
cg.setFillColor(CGColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 1))
cg.fill(CGRect(x: 0, y: 0, width: W, height: H))

// The hero glows (CoreGraphics is Y-up: "top" is near H).
func glow(_ center: CGPoint, _ radius: CGFloat, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) {
    let colors = [CGColor(srgbRed: r, green: g, blue: b, alpha: a),
                  CGColor(srgbRed: r, green: g, blue: b, alpha: 0)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
glow(CGPoint(x: W * 0.5, y: H * 1.15), 760, 120 / 255, 140 / 255, 1, 0.30)
glow(CGPoint(x: W * 0.86, y: H * 0.78), 420, 80 / 255, 220 / 255, 1, 0.14)

// App icon.
let icon = NSImage(contentsOf: root.appendingPathComponent("public/icon.png"))!
let iconSize: CGFloat = 132
icon.draw(in: CGRect(x: 96, y: H - 96 - iconSize, width: iconSize, height: iconSize))

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at origin: CGPoint, tracking: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
    ]
    NSAttributedString(string: text, attributes: attrs).draw(at: origin)
}

draw("CaptureCat", size: 92, weight: .semibold, color: .white,
     at: CGPoint(x: 92, y: 248), tracking: -2.5)
draw("The Mac screen recorder that edits itself.", size: 42, weight: .regular,
     color: NSColor(white: 1, alpha: 0.72), at: CGPoint(x: 96, y: 186), tracking: -0.6)
draw("Auto zoom · cursor smoothing · on-device captions · free and open source",
     size: 26, weight: .medium, color: NSColor(white: 1, alpha: 0.45), at: CGPoint(x: 96, y: 96))

// Hairline along the top, like the glass cards.
cg.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
cg.fill(CGRect(x: 0, y: H - 1, width: W, height: 1))

NSGraphicsContext.restoreGraphicsState()
let out = root.appendingPathComponent("public/og.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
