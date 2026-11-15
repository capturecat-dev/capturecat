import AppKit

/// `CaptureCat --preview-export-parity <fixtureDir> [--out <dir>]`
///
/// The Mac control of the Studio 3c preview↔export gate: the shared
/// `PreviewExportParityHarness` with the Mac's `PreviewCompositorView` in a
/// real NSWindow as the stage. Its results.json is the reference the iOS run
/// (`--ios-preview-export-parity`) must not be worse than. The fixture comes
/// from `--preview-parity-fixtures <dir>`. DEBUG tooling; never reached in a
/// normal launch.
@MainActor
enum PreviewExportParityRunner {
    static func run() -> Never {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview-export-parity"), args.indices.contains(i + 1) else {
            print("usage: CaptureCat --preview-export-parity <fixtureDir> [--out <dir>] [--reference <results.json>]")
            exit(2)
        }
        let fixture = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        func value(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let out = value("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fixture.deletingLastPathComponent().appendingPathComponent("preview-export-mac", isDirectory: true)
        PreviewExportParityHarness.injectExportDefect = args.contains("--inject")
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            guard let data = try? Data(contentsOf: fixture.appendingPathComponent(ParityFixtureFile.fileName)),
                  let file = try? JSONDecoder().decode(ParityFixtureFile.self, from: data) else {
                print("PREVIEW-EXPORT-PARITY FAIL fixture unreadable"); exit(1)
            }
            let stage = MacStage(canvas: file.canvas)
            let results = await PreviewExportParityHarness.run(
                fixtureDir: fixture, out: out, stage: stage, reference: value("--reference").map { URL(fileURLWithPath: $0) }
            ) { print($0) }
            exit(results.allSatisfy { PreviewExportParityHarness.judge($0, reference: nil).pass } && !results.isEmpty ? 0 : 1)
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    /// PreviewCompositorView at the fixture canvas in an off-screen window,
    /// rasters at 2×, captured through CARenderer (Y-flipped — undone here).
    final class MacStage: PreviewExportStage {
        private final class Flipped: NSView { override var isFlipped: Bool { true } }
        let window: NSWindow
        let container: NSView
        let compositor: PreviewCompositorView
        let canvas: CGSize

        init(canvas: CGSize) {
            self.canvas = canvas
            window = NSWindow(contentRect: NSRect(x: -20_000, y: 200, width: canvas.width, height: canvas.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            container = Flipped(frame: NSRect(origin: .zero, size: canvas))
            container.wantsLayer = true
            compositor = PreviewCompositorView(frame: NSRect(origin: .zero, size: canvas))
            compositor.core.suppressImplicitAnimation = true
            compositor.rasterScaleOverride = PreviewExportParityHarness.scale
            container.addSubview(compositor)
            window.contentView = container
            window.orderFrontRegardless()
        }

        func render(_ input: PreviewCompositorCore.FrameInput) { compositor.schedule(input) }
        var core: PreviewCompositorCore { compositor.core }

        func capture() async -> CGImage? {
            guard let layer = container.layer else { return nil }
            // CARendererSnapshot's `scale` sizes the texture only; the layer
            // tree itself must be scaled to fill it (rasters are already 2×).
            let prior = layer.sublayerTransform
            let s = PreviewExportParityHarness.scale
            // Scale about the origin, then lift the doubled (flipped) tree back
            // into the root's frame — CARenderer is y-up, so unlifted the top
            // half of the content lands in the bottom half of the texture.
            layer.sublayerTransform = CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                                          CATransform3DMakeTranslation(0, -canvas.height * (s - 1), 0))
            defer { layer.sublayerTransform = prior }
            guard let mirrored = CARendererSnapshot.render(layer: layer, size: canvas, scale: s) else { return nil }
            let w = mirrored.width, h = mirrored.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(mirrored, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
    }
}
