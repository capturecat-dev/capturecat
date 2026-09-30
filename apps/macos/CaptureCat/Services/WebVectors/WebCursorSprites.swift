import AppKit

/// `CaptureCat --web-cursor-sprites <dir> [--verify-sizes <style>:<W>x<H>,…]`
///
/// Writes the cursor artwork the web editor composites, rasterized by the
/// REAL `CursorStyleProvider.rasterizedCGImage(for:pixelSize:)` — the same
/// call `VideoExporter.makeCursorAsset` makes — for every
/// `ProjectSettings.CursorStyle` at 1×/2×/3× of its point size:
///
///     <dir>/manifest.json        styles → point size, hotspot, rasters; each
///                                raster's PREMULTIPLIED RGBA8 bytes (rows
///                                top-down) inline as base64 — what the web
///                                uploads, byte-exact (a PNG round trip through
///                                a browser decoder may re-premultiply with
///                                different rounding), and text so it travels
///                                in a plain diff
///     <dir>/<slug>@<k>x.png      straight-alpha PNG (viewing / tooling)
///
/// `Hand` is `NSCursor.pointingHand.image` — Apple's SYSTEM cursor bitmap
/// (the manifest records its bitmap reps). Shipping it is the product
/// owner's call; the manifest flags it `system: true`.
///
/// `--verify-sizes Hand:107x107,macOS Arrow:50x70` additionally writes
/// `<dir>/verify/<slug>-<W>x<H>.{png,rgba}` at those exact pixel grids (the
/// grids the exporter asks for are `ceil(pointSize × cursorRasterScale)`),
/// for the web's rasterizer/resampler checks. Not shipped.
///
/// The app is sandboxed: when `<dir>` is not writable the files land in
/// `NSTemporaryDirectory()/capturecat-web-cursor-sprites` — the path is
/// printed. Never reached in a normal launch.
enum WebCursorSprites {
    static let scales: [Int] = [1, 2, 3]

    static func run() -> Never {
        let args = CommandLine.arguments
        var requested: String?
        if let i = args.firstIndex(of: "--web-cursor-sprites"), args.indices.contains(i + 1),
           !args[i + 1].hasPrefix("--") {
            requested = (args[i + 1] as NSString).expandingTildeInPath
        }
        var verify: [(ProjectSettings.CursorStyle, Int, Int)] = []
        if let i = args.firstIndex(of: "--verify-sizes"), args.indices.contains(i + 1) {
            for item in args[i + 1].split(separator: ",") {
                let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let style = ProjectSettings.CursorStyle(rawValue: parts[0]) else {
                    print("WEB-CURSOR-SPRITES FAIL bad --verify-sizes item \(item)")
                    exit(64)
                }
                let wh = parts[1].split(separator: "x").compactMap { Int($0) }
                guard wh.count == 2, wh[0] > 0, wh[1] > 0 else {
                    print("WEB-CURSOR-SPRITES FAIL bad size in \(item)")
                    exit(64)
                }
                verify.append((style, wh[0], wh[1]))
            }
        }

        let dir = resolveOutputDirectory(requested)
        print("WEB-CURSOR-SPRITES dir=\(dir.path)")

        var styles: [[String: Any]] = []
        var failures = 0
        for style in ProjectSettings.CursorStyle.allCases {
            let asset = CursorStyleProvider.asset(for: style)
            let size = asset.image.size
            var rasters: [[String: Any]] = []
            for k in scales {
                let pixelSize = CGSize(width: size.width * CGFloat(k), height: size.height * CGFloat(k))
                guard let cg = CursorStyleProvider.rasterizedCGImage(for: style, pixelSize: pixelSize),
                      let bytes = premultipliedRGBA(cg) else {
                    print("WEB-CURSOR-SPRITES FAIL \(style.rawValue) @\(k)x: rasterization failed")
                    failures += 1
                    continue
                }
                let file = "\(slug(style))@\(k)x.png"
                do {
                    try writePNG(bytes: bytes, width: cg.width, height: cg.height,
                                 to: dir.appendingPathComponent(file))
                } catch {
                    print("WEB-CURSOR-SPRITES FAIL \(file): \(error.localizedDescription)")
                    failures += 1
                    continue
                }
                rasters.append([
                    "scale": k,
                    "pixelWidth": cg.width,
                    "pixelHeight": cg.height,
                    "png": file,
                    "byteLength": bytes.count,
                    "fnv1a32": fnv1a32(bytes),
                    "rgbaBase64": Data(bytes).base64EncodedString(),
                ])
            }
            var entry: [String: Any] = [
                "style": style.rawValue,
                "slug": slug(style),
                "pointWidth": size.width,
                "pointHeight": size.height,
                "hotSpotX": asset.hotSpot.x,
                "hotSpotY": asset.hotSpot.y,
                "system": style == .hand,
                "rasters": rasters,
            ]
            if style == .hand {
                entry["systemReps"] = asset.image.representations.map {
                    ["pixelsWide": $0.pixelsWide, "pixelsHigh": $0.pixelsHigh,
                     "pointWidth": $0.size.width, "pointHeight": $0.size.height]
                }
                entry["source"] = "NSCursor.pointingHand.image (macOS system cursor bitmap)"
            } else {
                entry["source"] = "CursorStyleProvider vector artwork"
            }
            styles.append(entry)
            print("WEB-CURSOR-SPRITES style=\(style.rawValue) rasters=\(rasters.count) size=\(size) hotspot=\(asset.hotSpot)")
        }

        let manifest: [String: Any] = [
            "generator": "CaptureCat --web-cursor-sprites",
            "notes": "CursorStyleProvider.rasterizedCGImage(for:pixelSize:) at k× the style's point size "
                + "(the exact call VideoExporter.makeCursorAsset makes). rgbaBase64 = premultiplied RGBA8, "
                + "rows top-down. Hand is Apple's NSCursor.pointingHand bitmap.",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "styles": styles,
        ]
        do {
            let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            print("WEB-CURSOR-SPRITES FAIL manifest: \(error.localizedDescription)")
            failures += 1
        }

        if !verify.isEmpty {
            let vdir = dir.appendingPathComponent("verify")
            try? FileManager.default.createDirectory(at: vdir, withIntermediateDirectories: true)
            for (style, w, h) in verify {
                guard let cg = CursorStyleProvider.rasterizedCGImage(
                    for: style, pixelSize: CGSize(width: w, height: h)),
                    let bytes = premultipliedRGBA(cg) else {
                    print("WEB-CURSOR-SPRITES FAIL verify \(style.rawValue) \(w)x\(h)")
                    failures += 1
                    continue
                }
                let base = "\(slug(style))-\(cg.width)x\(cg.height)"
                try? Data(bytes).write(to: vdir.appendingPathComponent("\(base).rgba"))
                try? writePNG(bytes: bytes, width: cg.width, height: cg.height,
                              to: vdir.appendingPathComponent("\(base).png"))
                print("WEB-CURSOR-SPRITES verify=\(base)")
            }
        }

        print("WEB-CURSOR-SPRITES \(failures == 0 ? "OK" : "FAILED") dir=\(dir.path)")
        exit(failures == 0 ? 0 : 1)
    }

    static func slug(_ style: ProjectSettings.CursorStyle) -> String {
        switch style {
        case .system: return "macos-arrow"
        case .inverted: return "white-arrow"
        case .hand: return "hand"
        case .dot: return "dot"
        case .ring: return "ring"
        }
    }

    /// The raster's own bytes as premultiplied RGBA8, rows top-down: redrawn
    /// with `.copy` into a context of the SAME colour space, so no colour
    /// conversion and no re-premultiplication touches a byte.
    static func premultipliedRGBA(_ image: CGImage) -> [UInt8]? {
        let w = image.width
        let h = image.height
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? bytes : nil
    }

    /// Straight-alpha PNG whose values re-premultiply (c·a/255, rounded) to
    /// EXACTLY the given premultiplied bytes — the smallest straight value
    /// that lands on each premultiplied one.
    static func writePNG(bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        var straight = [UInt8](repeating: 0, count: bytes.count)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i + 3])
            straight[i + 3] = UInt8(a)
            guard a > 0 else { continue }
            for c in 0..<3 {
                let p = Int(bytes[i + c])
                var s = min(255, (p * 255 + a / 2) / a)
                while s > 0, (s * a + 127) / 255 > p { s -= 1 }
                while s < 255, (s * a + 127) / 255 < p { s += 1 }
                straight[i + c] = UInt8(s)
            }
        }
        let provider = CGDataProvider(data: Data(straight) as CFData)!
        guard let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "WebCursorSprites", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "WebCursorSprites", code: 2) }
    }

    static func fnv1a32(_ bytes: [UInt8]) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for b in bytes {
            h ^= UInt32(b)
            h = h &* 0x0100_0193
        }
        return h
    }

    static func resolveOutputDirectory(_ requested: String?) -> URL {
        let fm = FileManager.default
        if let requested {
            let url = URL(fileURLWithPath: requested, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".write-probe")
            if fm.createFile(atPath: probe.path, contents: Data()) {
                try? fm.removeItem(at: probe)
                return url
            }
        }
        let suffix = requested.map { "-" + URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("capturecat-web-cursor-sprites\(suffix)", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
