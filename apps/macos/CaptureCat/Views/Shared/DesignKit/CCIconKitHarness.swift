import AppKit

/// Headless gate for the icon kit (CCIcon renderer + the generated CCIconSet).
///
///   CaptureCat --iconkit-test
///
/// Asserts, for EVERY kit icon and alias (no sampling):
///  • parse — each icon yields one shape per element, every `d` is consumed
///    to its end (a partial path still draws, so "non-empty" alone would
///    pass a truncated glyph), and all geometry stays on the 24-unit grid;
///  • aliases — every SF name resolves to a DRAWN kit icon and renders the
///    same pixels as asking for the kit name (i.e. never the SF fallback);
///  • render — template images at the SF-equivalent box, non-empty at 16 and
///    24 pt, nothing touching the outer pixel ring (clipping);
///  • weight — ink grows strictly light < regular < semibold < bold;
///  • parser unit cases — relative commands, implicit lineto, packed arc
///    flags (`a2 2 0 012 2`), `.5.5` numbers, exponents, elliptical and
///    rotated arcs, out-of-range and zero radii, S/T reflection, markup;
///  • structure — ring-vs-centre, knockout, orientation (a mean-ink check is
///    blind to an upside-down or hollow glyph).
/// Writes light + dark contact sheets of the Swift renderer's output beside
/// the report. DEBUG tooling; DesignKit-only (no app code).
@MainActor
enum CCIconKitHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        var checks = 0
        var failures = 0
        func expect(_ ok: Bool, _ label: @autoclosure () -> String) {
            checks += 1
            if !ok {
                failures += 1
                print("ICONKIT FAIL \(label())")
            }
        }

        let names = CCIconSet.icons.keys.sorted()
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capturecat-iconkit")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // MARK: Parse — every icon, every element, every path to its end.
        let element = try! NSRegularExpression(pattern: #"<(path|circle|rect|line)\b"#)
        let pathData = try! NSRegularExpression(pattern: #"\bd="([^"]*)""#)
        let grid = CGRect(x: 0, y: 0, width: 24, height: 24).insetBy(dx: -0.05, dy: -0.05)
        for name in names {
            let markup = CCIconSet.icons[name]!
            let ns = markup as NSString
            let range = NSRange(location: 0, length: ns.length)
            let shapes = CCIcon.parseMarkup(markup)
            let elements = element.numberOfMatches(in: markup, range: range)
            expect(!shapes.isEmpty, "\(name): parses to ≥1 shape")
            expect(shapes.count == elements, "\(name): \(shapes.count) shapes from \(elements) elements")
            for match in pathData.matches(in: markup, range: range) {
                let d = ns.substring(with: match.range(at: 1))
                expect(CCIcon.appendPathData(d, to: CGMutablePath()),
                       "\(name): path data parses to its end (\(d.prefix(40))…)")
            }
            for (i, shape) in shapes.enumerated() {
                let box = shape.path.boundingBoxOfPath
                expect(!box.isNull && box.minX.isFinite && box.minY.isFinite && grid.contains(box),
                       "\(name): shape \(i) on the 24 grid (box \(box))")
            }
        }

        // MARK: Aliases — every SF name draws its kit icon, never SF.
        for (sf, kit) in CCIconSet.aliases.sorted(by: { $0.key < $1.key }) {
            expect(CCIconSet.icons[kit] != nil, "alias \(sf) → \(kit): kit icon is drawn")
            expect(CCIcon.kitName(for: sf) == kit && CCIcon.has(sf), "alias \(sf) resolves to \(kit)")
            guard let viaAlias = CCIcon.image(sf, pointSize: 16), let viaKit = CCIcon.image(kit, pointSize: 16)
            else {
                expect(false, "alias \(sf): image renders")
                continue
            }
            expect(viaAlias.isTemplate, "alias \(sf): template image (SF fallback would be a symbol image)")
            let a = Raster(viaAlias), b = Raster(viaKit)
            expect(a.alpha == b.alpha, "alias \(sf): same pixels as kit \(kit)")
        }
        for kitOnly in ["cursorarrow.fill", "pencil.tip.fill", "wand.and.stars.fill", "figure.walk.motion.fill"] {
            expect(CCIcon.has(kitOnly), "kit-only alias \(kitOnly) resolves")
        }
        // Unknown names degrade to SF (or nil), never crash or draw a kit glyph.
        expect(!CCIcon.has("gearshape.2") && CCIcon.image("gearshape.2", pointSize: 13) != nil,
               "unknown kit name falls back to its SF Symbol")
        expect(CCIcon.image("no.such.icon.anywhere", pointSize: 13) == nil, "unknown everywhere → nil")

        // MARK: Render — box, template, non-empty, unclipped; weight → ink.
        var ink24: [String: Double] = [:]
        for name in names {
            for point: CGFloat in [16, 24] {
                guard let image = CCIcon.image(name, pointSize: point) else {
                    expect(false, "\(name)@\(Int(point)): renders")
                    continue
                }
                let side = CCIcon.side(for: point)
                expect(image.size == NSSize(width: side, height: side),
                       "\(name)@\(Int(point)): \(image.size) box (want \(side)²)")
                expect(image.isTemplate, "\(name)@\(Int(point)): template")
                let raster = Raster(image)
                expect(raster.ink > 20, "\(name)@\(Int(point)): non-empty (ink \(Int(raster.ink)) px)")
                expect(raster.edgeMax <= 8, "\(name)@\(Int(point)): unclipped (edge alpha \(raster.edgeMax))")
                if point == 24 { ink24[name] = raster.ink }
            }
            let weights: [(String, NSFont.Weight)] = [("light", .light), ("regular", .regular),
                                                      ("semibold", .semibold), ("bold", .bold)]
            let inks = weights.map { Raster(CCIcon.image(name, pointSize: 24, weight: $0.1)!).ink }
            for i in 1..<inks.count {
                expect(inks[i] > inks[i - 1] + 0.5,
                       "\(name): \(weights[i].0) ink \(Int(inks[i])) > \(weights[i - 1].0) \(Int(inks[i - 1]))")
            }
        }
        // The painted (non-template) variant carries its colour.
        if let red = CCIcon.image("record", pointSize: 24, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) {
            let raster = Raster(red)
            expect(!red.isTemplate, "painted variant is not a template")
            expect(raster.reddest > 200, "painted variant is red (max R-G \(raster.reddest))")
        } else {
            expect(false, "painted variant renders")
        }

        // MARK: Parser unit cases.
        func parse(_ d: String) -> (path: CGPath, ok: Bool) {
            let path = CGMutablePath()
            let ok = CCIcon.appendPathData(d, to: path)
            return (path, ok)
        }
        func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.02) -> Bool {
            abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol
                && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
        }
        func nearPoint(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }
        func onStroke(_ path: CGPath, _ p: CGPoint) -> Bool {
            path.copy(strokingWithWidth: 0.15, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
        }
        func box(_ d: String, _ want: CGRect, _ label: String) {
            let r = parse(d)
            expect(r.ok, "parser \(label): consumed \(d)")
            expect(near(r.path.boundingBoxOfPath, want), "parser \(label): box \(r.path.boundingBoxOfPath) want \(want)")
        }
        func end(_ d: String, _ want: CGPoint, _ label: String) {
            let r = parse(d)
            expect(r.ok, "parser \(label): consumed \(d)")
            expect(nearPoint(r.path.currentPoint, want), "parser \(label): ends \(r.path.currentPoint) want \(want)")
        }
        box("M2 2l4 0l0 4z", CGRect(x: 2, y: 2, width: 4, height: 4), "relative l")
        box("M1 1h3v3H1Z", CGRect(x: 1, y: 1, width: 3, height: 3), "h/v/H")
        box("m1 1 2 0 0 2", CGRect(x: 1, y: 1, width: 2, height: 2), "relative implicit lineto")
        end("M5 5l2 0z l0 2", CGPoint(x: 5, y: 7), "relative after Z restarts at the subpath start")
        box("M.5.5L1.5.5", CGRect(x: 0.5, y: 0.5, width: 1, height: 0), ".5.5 numbers")
        end("M1-1L-2-3", CGPoint(x: -2, y: -3), "minus as separator")
        end("M0 0L1e1 0", CGPoint(x: 10, y: 0), "exponent")
        end("M0 0L2e-1-1", CGPoint(x: 0.2, y: -1), "negative exponent then minus")
        do { // packed flags, small arc, sweep 1: centre (10, 12)
            let r = parse("M10 10a2 2 0 012 2")
            expect(r.ok && nearPoint(r.path.currentPoint, CGPoint(x: 12, y: 12)), "parser packed flags 012: ends at 12,12")
            expect(onStroke(r.path, CGPoint(x: 10 + sqrt(2), y: 12 - sqrt(2))), "parser packed flags 012: bulges up-right")
            expect(!onStroke(r.path, CGPoint(x: 12 - sqrt(2), y: 10 + sqrt(2))), "parser packed flags 012: not the other centre")
        }
        do { // packed "11": large arc, sweep 1 → centre (12, 10), 270°
            let r = parse("M10 10A2 2 0 1112 12")
            expect(r.ok && nearPoint(r.path.currentPoint, CGPoint(x: 12, y: 12)), "parser packed flags 11: ends at 12,12")
            expect(near(r.path.boundingBoxOfPath, CGRect(x: 10, y: 8, width: 4, height: 4)),
                   "parser packed flags 11: large arc box \(r.path.boundingBoxOfPath)")
        }
        box("M0 0A5,5,0,0,1,10,0", CGRect(x: 0, y: -5, width: 10, height: 5), "comma-separated arc")
        box("M0 10A10 5 0 0 1 20 10", CGRect(x: 0, y: 5, width: 20, height: 5), "elliptical arc")
        box("M0 0A10 5 90 0 1 0 20", CGRect(x: 0, y: 0, width: 5, height: 20), "rotated elliptical arc")
        box("M0 0A1 1 0 0 1 10 0", CGRect(x: 0, y: -5, width: 10, height: 5), "out-of-range radii scale up")
        box("M0 0A0 5 0 0 1 10 0", CGRect(x: 0, y: 0, width: 10, height: 0), "zero radius → line")
        box("M0 0C0 4 4 4 4 0S8 -4 8 0", CGRect(x: 0, y: -3, width: 8, height: 6), "S reflects the last control")
        box("M0 0Q2 4 4 0T8 0", CGRect(x: 0, y: -2, width: 8, height: 4), "T reflects the last control")
        expect(!parse("M0 0L5").ok, "parser: truncated data reports false")
        do {
            let shapes = CCIcon.parseMarkup(
                #"<rect x="2" y="3" width="10" height="6" rx="2"/><circle cx="12" cy="12" r="5" fill="currentColor"/><line x1="1" y1="2" x2="3" y2="4"/><polygon points="0,0 1,1"/>"#)
            expect(shapes.count == 3, "markup: rect + circle + line, unknown element ignored (\(shapes.count))")
            if shapes.count == 3 {
                expect(near(shapes[0].path.boundingBoxOfPath, CGRect(x: 2, y: 3, width: 10, height: 6)) && !shapes[0].fill,
                       "markup: rounded rect, stroked")
                expect(shapes[1].fill && shapes[1].stroke, "markup: fill=currentColor fills AND strokes")
                expect(near(shapes[2].path.boundingBoxOfPath, CGRect(x: 1, y: 2, width: 2, height: 2)), "markup: line")
            }
        }

        // MARK: Structure — where the ink is, not how much.
        func probe(_ name: String, ink: [(CGFloat, CGFloat)], clear: [(CGFloat, CGFloat)]) {
            guard let image = CCIcon.image(name, pointSize: 24) else {
                expect(false, "structure \(name): renders")
                return
            }
            let raster = Raster(image)
            for (x, y) in ink {
                expect(raster.alphaAt(gridX: x, gridY: y) > 128, "structure \(name): ink at (\(x), \(y))")
            }
            for (x, y) in clear {
                expect(raster.alphaAt(gridX: x, gridY: y) < 24, "structure \(name): clear at (\(x), \(y))")
            }
        }
        // "circle" (the Ellipse annotation) — a ring: ink on it, none inside.
        probe("circle", ink: [(3, 12), (21, 12), (12, 5), (12, 19)], clear: [(12, 12), (8, 12), (16, 12)])
        // record: ring + solid dot, empty between them.
        probe("record.circle", ink: [(12, 12), (12, 3), (21, 12)], clear: [(12, 5.4), (18.6, 12)])
        // check-circle-fill: a solid disc with the check KNOCKED OUT (reverse-wound).
        probe("checkmark.circle.fill", ink: [(12, 5), (6, 9), (18, 15)], clear: [(13.5, 12.25)])
        // Orientation: chevron-down's vertex sits LOW; an upside-down render fails.
        probe("chevron.down", ink: [(12, 14.6)], clear: [(12, 9)])
        probe("arrow.up.to.line", ink: [(12, 4.5), (6.5, 4.5)], clear: [(6.5, 19.5)])
        // X: crossing at the centre, empty mid-edges.
        probe("xmark", ink: [(12, 12), (7, 7), (17, 17)], clear: [(12, 6.5), (6.5, 12)])

        // MARK: Contact sheets (light + dark) of the Swift renderer.
        for dark in [false, true] {
            let url = outDir.appendingPathComponent("iconkit-\(dark ? "dark" : "light").png")
            if writeSheet(names: names, dark: dark, to: url) { print("ICONKIT sheet \(url.path)") }
        }

        print("ICONKIT \(names.count) icons, \(CCIconSet.aliases.count) aliases")
        print("ICONKIT outDir \(outDir.path)")
        if failures == 0 {
            print("ICONKIT PASS (\(checks) checks)")
            exit(0)
        }
        print("ICONKIT FAIL (\(failures)/\(checks))")
        exit(1)
    }

    // MARK: - Raster

    /// An image rasterised at 2x into straight RGBA; row 0 is the TOP row.
    struct Raster {
        let width: Int
        let height: Int
        let alpha: [UInt8]
        private let rgba: [UInt8]

        init(_ image: NSImage, scale: CGFloat = 2) {
            width = Int((image.size.width * scale).rounded())
            height = Int((image.size.height * scale).rounded())
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // The context's CTM is unscaled: draw straight into pixel space.
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.current?.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            let data = rep.bitmapData!
            let pixels = Array(UnsafeBufferPointer(start: data, count: width * height * 4))
            rgba = pixels
            alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        }

        /// Total coverage in pixel-equivalents.
        var ink: Double { alpha.reduce(0) { $0 + Double($1) } / 255 }

        /// Max alpha on the outermost pixel ring.
        var edgeMax: UInt8 {
            var m: UInt8 = 0
            for x in 0..<width { m = max(m, alpha[x], alpha[(height - 1) * width + x]) }
            for y in 0..<height { m = max(m, alpha[y * width], alpha[y * width + width - 1]) }
            return m
        }

        /// Largest (R − G) over inked pixels (un-premultiplied), for colour checks.
        var reddest: Int {
            var best = 0
            for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] > 200 {
                best = max(best, Int(rgba[i]) - Int(rgba[i + 1]))
            }
            return best
        }

        /// Max alpha in the 3×3 pixels around a point on the 24-unit grid.
        func alphaAt(gridX: CGFloat, gridY: CGFloat) -> UInt8 {
            let px = Int(gridX / 24 * CGFloat(width)), py = Int(gridY / 24 * CGFloat(height))
            var m: UInt8 = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = px + dx, y = py + dy
                    guard x >= 0, y >= 0, x < width, y < height else { continue }
                    m = max(m, alpha[y * width + x])
                }
            }
            return m
        }
    }

    // MARK: - Contact sheet

    private static func writeSheet(names: [String], dark: Bool, to url: URL) -> Bool {
        let columns = 12, cellW: CGFloat = 96, cellH: CGFloat = 64, scale: CGFloat = 2
        let rows = (names.count + columns - 1) / columns
        let size = CGSize(width: CGFloat(columns) * cellW, height: CGFloat(rows) * cellH)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return false }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.current = context
        let ctx = context.cgContext
        ctx.scaleBy(x: scale, y: scale)
        let background = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.98, alpha: 1)
        let ink = dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        background.setFill()
        CGRect(origin: .zero, size: size).fill()
        let label: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: ink.withAlphaComponent(0.6),
        ]
        for (i, name) in names.enumerated() {
            let col = i % columns, row = i / columns
            // y-up context: row 0 at the top.
            let origin = CGPoint(x: CGFloat(col) * cellW, y: size.height - CGFloat(row + 1) * cellH)
            var x = origin.x + 8
            for point: CGFloat in [13, 16, 24] {
                guard let image = CCIcon.image(name, pointSize: point, color: ink) else { continue }
                image.draw(in: CGRect(x: x, y: origin.y + 18, width: image.size.width, height: image.size.height))
                x += image.size.width + 6
            }
            (name as NSString).draw(at: CGPoint(x: origin.x + 8, y: origin.y + 5), withAttributes: label)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
