import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import QuartzCore
import UIKit

/// (d) Motion blur + camera-look dissolve without CA filters — the iOS half.
///
/// The Mac compositor puts CIMotionBlur in `zoomGroup.filters` and
/// CIAdditionCompositing in the look stacks' `compositingFilter`. This spike
/// records what iOS CoreAnimation actually does with those (rendered by the
/// render server, read back with drawHierarchy), and what the two CI
/// replacements cost per preview frame on this device. The visual deltas
/// against the Mac's own frames are measured on the Mac
/// (mac/d-motionblur-dissolve.patch), where the real compositor lives.
///
/// Variants: behaviour | cost
@MainActor
enum SpikeD {
    static func run(variant: String) async throws -> [String: Any] {
        switch variant {
        case "behaviour": return try await behaviour()
        case "cost": return try await cost()
        default: throw SpikeError("variant must be behaviour|cost")
        }
    }

    // MARK: Behaviour

    static func behaviour() async throws -> [String: Any] {
        let stage = Harness.shared.stage
        stage.layoutIfNeeded()
        let side: CGFloat = 120
        // 1) CIMotionBlur on a sharp stripe pattern.
        func stripes() -> CALayer {
            let l = CALayer()
            l.frame = CGRect(x: 0, y: 0, width: side, height: side)
            let img = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
                for i in 0..<12 {
                    (i % 2 == 0 ? UIColor.white : UIColor.black).setFill()
                    ctx.fill(CGRect(x: CGFloat(i) * side / 12, y: 0, width: side / 12, height: side))
                }
            }
            l.contents = img.cgImage
            return l
        }
        let plain = stripes()
        plain.frame.origin = CGPoint(x: 10, y: 10)
        let blurred = stripes()
        blurred.frame.origin = CGPoint(x: 20 + side, y: 10)
        if let f = CIFilter(name: "CIMotionBlur") {
            f.setValue(20, forKey: kCIInputRadiusKey)
            f.setValue(0, forKey: kCIInputAngleKey)
            blurred.filters = [f]
        }
        // 2) Additive compositing: red 50% over green 50% inside an isolated group.
        func pair(_ filter: Any?) -> CALayer {
            let group = CALayer()
            group.frame = CGRect(x: 0, y: 0, width: side, height: side)
            group.shouldRasterize = true // isolated, like cameraStacksGroup while dissolving
            group.rasterizationScale = UIScreen.main.scale
            let bottom = CALayer(); bottom.frame = group.bounds
            bottom.backgroundColor = UIColor(red: 0, green: 1, blue: 0, alpha: 1).cgColor
            bottom.opacity = 0.5
            let top = CALayer(); top.frame = group.bounds
            top.backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor
            top.opacity = 0.5
            top.compositingFilter = filter
            group.addSublayer(bottom); group.addSublayer(top)
            return group
        }
        let addCI = pair(CIFilter(name: "CIAdditionCompositing"))
        addCI.frame.origin = CGPoint(x: 10, y: 20 + side)
        let addPlusL = pair("plusL") // undocumented CAFilter name; App Store risk if relied on
        addPlusL.frame.origin = CGPoint(x: 20 + side, y: 20 + side)
        let over = pair(nil)
        over.frame.origin = CGPoint(x: 30 + 2 * side, y: 20 + side)
        let host = CALayer()
        host.frame = stage.bounds
        host.backgroundColor = UIColor.black.cgColor
        for l in [plain, blurred, addCI, addPlusL, over] { host.addSublayer(l) }
        stage.layer.addSublayer(host)
        defer { host.removeFromSuperlayer() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(bounds: stage.bounds)
        let image = renderer.image { _ in _ = stage.drawHierarchy(in: stage.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage, let px = Pixels(cg) else { throw SpikeError("snapshot failed") }
        func at(_ p: CGPoint) -> [Int] {
            let (r, g, b, _) = px[Int(p.x * scale), Int(p.y * scale)]
            return [r, g, b]
        }
        // Edge contrast across one stripe boundary: sharp = ~255, blurred = small.
        func edgeContrast(_ l: CALayer) -> Int {
            let y = l.frame.midY
            var values: [Int] = []
            for x in stride(from: l.frame.minX + 2, to: l.frame.maxX - 2, by: 1) { values.append(at(CGPoint(x: x, y: y))[0]) }
            return zip(values, values.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        }
        let centre = { (l: CALayer) in at(CGPoint(x: l.frame.midX, y: l.frame.midY)) }
        let plainEdge = edgeContrast(plain), blurEdge = edgeContrast(blurred)
        let ci = centre(addCI), plusL = centre(addPlusL), src = centre(over)
        // Additive: R≈G≈128. Source-over: R≈128, G≈64.
        func isAdditive(_ v: [Int]) -> Bool { abs(v[0] - v[1]) < 24 && v[1] > 96 }
        return [
            "motionBlurFilter": ["maxEdgeStepPlain": plainEdge, "maxEdgeStepWithCIMotionBlur": blurEdge,
                                 "applied": blurEdge < plainEdge / 2],
            "compositingFilter": [
                "CIAdditionCompositing": ["rgb": ci, "additive": isAdditive(ci)],
                "plusL(string, undocumented)": ["rgb": plusL, "additive": isAdditive(plusL)],
                "none(source-over)": ["rgb": src, "additive": isAdditive(src)],
            ],
            "expect": "additive red50%+green50% → ~(128,128,0); source-over → ~(128,64,0)",
        ]
    }

    // MARK: Cost

    /// Per-preview-frame cost of the two CI replacements at an iPad-ish stage
    /// (1194×834 pt @2x → card ≈ 2000×1250 px) and an iPhone stage
    /// (852×393 pt @3x → card ≈ 2200×1240 px).
    static func cost() async throws -> [String: Any] {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SpikeError("no Metal")
        }
        let context = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false,
        ])
        let card = CGSize(width: 2200, height: 1240)
        let source = CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: card))
            .applyingFilter("CICheckerboardGenerator", parameters: ["inputWidth": 40, "inputCenter": CIVector(x: 0, y: 0)])
            .cropped(to: CGRect(origin: .zero, size: card))
        let destBuffer = try makeBuffer(card)
        func time(_ n: Int, _ image: (Int) -> CIImage) -> [String: Any] {
            var ms: [Double] = []
            for i in 0..<n {
                let img = image(i)
                let t0 = CACurrentMediaTime()
                let dest = CIRenderDestination(pixelBuffer: destBuffer)
                if let task = try? context.startTask(toRender: img, to: dest) { _ = try? task.waitUntilCompleted() }
                ms.append((CACurrentMediaTime() - t0) * 1000)
            }
            return Metrics.stats(Array(ms.dropFirst(5)))
        }
        let baseline = time(65) { i in source.transformed(by: CGAffineTransform(translationX: CGFloat(i % 3), y: 0)).cropped(to: source.extent) }
        let blur = time(65) { i in
            source.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: 10.0 + Double(i % 20), kCIInputAngleKey: 0.4,
            ]).cropped(to: source.extent)
        }
        // Camera-look dissolve: two 640×640 stacks, additive with weights.
        let stackA = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        let stackB = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        let dissolve = time(65) { i in
            let w = Double(i % 30) / 30
            let a = stackA.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - w),
                                                                        "inputRVector": CIVector(x: 1 - w, y: 0, z: 0, w: 0),
                                                                        "inputGVector": CIVector(x: 0, y: 1 - w, z: 0, w: 0),
                                                                        "inputBVector": CIVector(x: 0, y: 0, z: 1 - w, w: 0)])
            let b = stackB.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: w),
                                                                        "inputRVector": CIVector(x: w, y: 0, z: 0, w: 0),
                                                                        "inputGVector": CIVector(x: 0, y: w, z: 0, w: 0),
                                                                        "inputBVector": CIVector(x: 0, y: 0, z: w, w: 0)])
            return b.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: a])
                .composited(over: source).cropped(to: source.extent)
        }
        return [
            "cardPixels": "\(Int(card.width))x\(Int(card.height))",
            "baselineCopyMs": baseline,
            "ciMotionBlurPassMs": blur,
            "ciAdditiveDissolvePassMs": dissolve,
            "budgetAt60fpsMs": 16.7,
        ]
    }

    static func makeBuffer(_ size: CGSize) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary, &pb)
        guard let pb else { throw SpikeError("buffer") }
        return pb
    }
}
