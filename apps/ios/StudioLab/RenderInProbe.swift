import UIKit

/// `--renderin-probe <fixtureDir>` — how faithfully iOS's CPU `CALayer.render(in:)`
/// draws the compositor's layer trees, against the render server
/// (`drawHierarchy`). Studio 2d measurement: decides whether the iOS CI passes
/// (camera-look dissolve, paused motion blur) can rasterize the core's own
/// layers instead of re-deriving them.
@MainActor
enum RenderInProbe {
    static func run(stage: PreviewStageView, fixtureDir: URL) async {
        print("RENDERIN fixture=\(fixtureDir.path)")
        guard let fixture = try? ParityLabFixture.load(from: fixtureDir) else {
            print("RENDERIN FAIL fixture"); exit(1)
        }
        stage.virtualCanvasSize = fixture.canvas
        stage.rasterScaleOverride = 2
        await LabTime.settle(0.3)
        let t0 = fixture.currentTime
        let project = fixture.project
        let original = try! JSONEncoder().encode(project)
        func reset() {
            let fresh = try! JSONDecoder().decode(Project.self, from: original)
            project.settings = fresh.settings
            project.zoomRegions = []
            project.tiltRegions = []
            project.cameraLayoutRegions = []
        }
        let mask = PreviewParityHarness.syntheticSilhouetteMask(aspect: Double(fixture.cameraAspect))
        func camera(_ s: ProjectSettings) {
            s.showCamera = true
            s.cameraShape = .roundedRect
            s.cameraSize = 340
            s.cameraBorderWidth = 0
        }
        let states: [(String, () -> Void, Bool)] = [
            ("flat", {}, false),
            ("zoom-2", {
                project.zoomRegions = [ZoomRegion(startTime: t0 - 1.5, endTime: t0 + 2, zoomLevel: 2.0,
                                                  focalPoint: CGPoint(x: 0.5, y: 0.5))]
            }, false),
            ("tilt-20", {
                project.tiltRegions = [TiltRegion(startTime: t0 - 1, endTime: t0 + 2, pitch: 20, yaw: 0, roll: 0)]
            }, false),
            ("bubble", { camera(project.settings) }, false),
            ("cutout", {
                camera(project.settings)
                project.cameraLayoutRegions = [CameraLayoutRegion(startTime: t0 - 3, endTime: t0 + 3,
                                                                  mode: .bubble, look: .cutout)]
            }, true),
            ("popout", {
                camera(project.settings)
                project.cameraLayoutRegions = [CameraLayoutRegion(startTime: t0 - 3, endTime: t0 + 3,
                                                                  mode: .bubble, look: .popOut)]
            }, true),
        ]
        for (name, apply, needsMask) in states {
            reset()
            apply()
            var input = fixture.input()
            input.cameraPosterImage = project.settings.showCamera ? fixture.cameraPoster : nil
            if needsMask { input.cameraMask = mask }
            stage.schedule(input)
            await LabTime.settle(0.4)
            stage.schedule(input)
            await LabTime.settle(0.4)
            guard let server = serverCapture(stage), let cpu = renderIn(stage) else {
                print("RENDERIN \(name) FAIL capture"); continue
            }
            try? LabCapture.png(server).write(to: fixtureDir.appendingPathComponent("rin-\(name)-server.png"))
            try? LabCapture.png(cpu).write(to: fixtureDir.appendingPathComponent("rin-\(name)-cpu.png"))
            print("RENDERIN \(name) \(compare(server, cpu))")
        }
        print("RENDERIN DONE")
        exit(0)
    }

    /// 8-bit sRGB — both captures in the same format, so the diff is the
    /// renderer's, not a colour conversion.
    static func format(_ view: UIView) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? 2
        format.opaque = false
        format.preferredRange = .standard
        return format
    }

    /// The render server's composite (what the screen shows).
    static func serverCapture(_ view: UIView) -> CGImage? {
        UIGraphicsImageRenderer(bounds: view.bounds, format: format(view)).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.cgImage
    }

    /// The stage's layer tree through the CPU renderer, same scale and bounds.
    static func renderIn(_ view: UIView) -> CGImage? {
        UIGraphicsImageRenderer(bounds: view.bounds, format: format(view)).image { ctx in
            view.layer.render(in: ctx.cgContext)
        }.cgImage
    }

    static func compare(_ a: CGImage, _ b: CGImage) -> String {
        guard let pa = rgba(a), let pb = rgba(b), pa.count == pb.count else { return "size mismatch" }
        var worst = 0, over8 = 0, total = 0
        var sum = 0
        var i = 0
        while i < pa.count {
            let d = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i + 1]) - Int(pb[i + 1])),
                        abs(Int(pa[i + 2]) - Int(pb[i + 2])))
            worst = max(worst, d); sum += d; total += 1
            if d > 8 { over8 += 1 }
            i += 4
        }
        return String(format: "worst=%d mean=%.3f px>8=%.3f%% (%dx%d)", worst, Double(sum) / Double(total),
                      100 * Double(over8) / Double(total), a.width, a.height)
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }
}
