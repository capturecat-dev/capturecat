import CoreGraphics
import Foundation

// `ios-vectors-bin --cursor-rasters <dir> --sizes <style>:<W>x<H>,…`
//
// The iOS half of ios-vectors.sh's cursor-raster check: every cursor style
// rasterized by the REAL `CursorStyleProvider.rasterizedCGImage(for:pixelSize:)`
// (the exporter's call) at 1×/2×/3× of its point size and at each listed grid,
// written as premultiplied RGBA8 (rows top-down) — the bytes the Mac's
// `--web-cursor-sprites [--verify-sizes …]` writes for the same grids, so the
// script compares them byte for byte. The Hand is the Mac's NSCursor bitmap
// bundled as resources (CursorArt); the arrows, dot and ring are vector art.
//
//   <dir>/<slug>@<k>x.rgba          (k = 1, 2, 3)
//   <dir>/verify/<slug>-<W>x<H>.rgba
//   <dir>/assets.json               point size + hotspot per style
enum CursorRasters {
    static func slug(_ style: ProjectSettings.CursorStyle) -> String {
        // WebCursorSprites.slug (Mac-only file) — the names the Mac writes.
        switch style {
        case .system: return "macos-arrow"
        case .inverted: return "white-arrow"
        case .hand: return "hand"
        case .dot: return "dot"
        case .ring: return "ring"
        }
    }

    static func run(arguments args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--cursor-rasters"), args.indices.contains(i + 1) else {
            print("CURSOR-RASTERS FAIL usage: --cursor-rasters <dir> [--sizes style:WxH,…]")
            exit(64)
        }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let vdir = dir.appendingPathComponent("verify", isDirectory: true)
        try? FileManager.default.createDirectory(at: vdir, withIntermediateDirectories: true)
        var failures = 0
        var assets: [[String: Any]] = []

        func write(_ style: ProjectSettings.CursorStyle, _ size: CGSize, _ name: URL) {
            guard let cg = CursorStyleProvider.rasterizedCGImage(for: style, pixelSize: size),
                  let bytes = premultipliedRGBA(cg) else {
                print("CURSOR-RASTERS FAIL \(style.rawValue) \(size): rasterization failed")
                failures += 1
                return
            }
            do { try Data(bytes).write(to: name) } catch {
                print("CURSOR-RASTERS FAIL \(name.lastPathComponent): \(error.localizedDescription)")
                failures += 1
            }
        }

        for style in ProjectSettings.CursorStyle.allCases {
            let asset = CursorStyleProvider.asset(for: style)
            let size = PlatformImageIO.pointSize(of: asset.image)
            assets.append([
                "style": style.rawValue, "pointWidth": size.width, "pointHeight": size.height,
                "hotSpotX": asset.hotSpot.x, "hotSpotY": asset.hotSpot.y,
            ])
            for k in 1...3 {
                write(style, CGSize(width: size.width * CGFloat(k), height: size.height * CGFloat(k)),
                      dir.appendingPathComponent("\(slug(style))@\(k)x.rgba"))
            }
        }
        if let j = args.firstIndex(of: "--sizes"), args.indices.contains(j + 1) {
            for item in args[j + 1].split(separator: ",") {
                let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                let wh = parts.count == 2 ? parts[1].split(separator: "x").compactMap { Int($0) } : []
                guard parts.count == 2, let style = ProjectSettings.CursorStyle(rawValue: parts[0]),
                      wh.count == 2 else {
                    print("CURSOR-RASTERS FAIL bad --sizes item \(item)")
                    exit(64)
                }
                write(style, CGSize(width: wh[0], height: wh[1]),
                      vdir.appendingPathComponent("\(slug(style))-\(wh[0])x\(wh[1]).rgba"))
            }
        }
        if let json = try? JSONSerialization.data(withJSONObject: assets, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: dir.appendingPathComponent("assets.json"))
        }
        print("CURSOR-RASTERS \(failures == 0 ? "OK" : "FAILED") dir=\(dir.path)")
        exit(failures == 0 ? 0 : 1)
    }

    /// WebCursorSprites.premultipliedRGBA: the raster's own bytes, redrawn
    /// with `.copy` into a context of the same colour space.
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
}
