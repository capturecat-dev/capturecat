import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// StudioLab — the studio's harness app (never shipped). It hosts the SAME
/// StudioUI views the CaptureCat app ships (PreviewStageView) in a real
/// UIWindow, so a gate exercises the real view and window chain, not a bare
/// layer (CLAUDE.md §3, "wrong topology").
///
/// Driven by launch arguments (apps/ios/scripts/ios-preview-parity.sh):
///
///   --smoke <fixtureDir>    render the Mac-dumped parity fixture once and
///                           write what the window shows to <fixtureDir>/ios-smoke.png
///   --ios-preview-parity <fixtureDir>
///                           run the Mac's preview-parity matrix (the same script,
///                           StudioHarness/PreviewParityHarness) against the
///                           Mac's frozen goldens
///   --timeline-edits <outDir> [--inject accordion-snap|selection-snap|touch-offset]
///                           replay the Mac --timeline-edits-test through the touch
///                           timeline (TimelineEditsLab) against the Mac's frozen
///                           transcript, plus the lane / selection motion checks
///   --ios-export-parity <fixturesDir> [--out <dir>] [--only a,b] [--inject padding]
///                           re-export the Mac's render-parity fixtures with the
///                           iOS VideoExporter and score them against the Mac's
///                           taps (StudioHarness/ExportParityHarness;
///                           apps/ios/scripts/ios-export-parity.sh)
///   --inspector <outDir> [--inject snap]
///                           every inspector control of the nine panes through the
///                           real editor vs the Mac's frozen transcript, undo per
///                           edit, structure, Dynamic Type, re-theme, motion
///                           sequences (InspectorLab.swift; apps/ios/scripts/ios-inspector.sh)
///   --kit-gallery <outDir>  every house control in every state, both themes,
///                           with motion sequences (KitGalleryLab.swift;
///                           apps/ios/scripts/kit-gallery.sh)
@main
final class StudioLabAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = StudioLabSceneDelegate.self
        return config
    }
}

final class StudioLabSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        let lab = LabViewController()
        window.rootViewController = lab
        window.makeKeyAndVisible()
        self.window = window
        lab.start(arguments: ProcessInfo.processInfo.arguments)
    }
}

/// Hosts one PreviewStageView, full width, the way the studio screen will.
final class LabViewController: UIViewController {
    let stage = PreviewStageView(frame: .zero)

    override func loadView() {
        let root = UIView()
        root.backgroundColor = UIColor(white: 0.07, alpha: 1)
        stage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stage)
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            stage.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: 330.0 / 586.7),
        ])
        view = root
    }

    func start(arguments: [String]) {
        if KitGalleryLab.start(arguments, lab: self) { return }
        if InspectorLab.start(arguments, lab: self) { return }
        if TimelineEditsLab.start(arguments, in: self) { return }
        if #available(iOS 26, *), HistoryLab.start(arguments, lab: self) { return }
        if let i = arguments.firstIndex(of: "--decode-probe"), arguments.indices.contains(i + 1) {
            let video = URL(fileURLWithPath: arguments[i + 1])
            let index = arguments.firstIndex(of: "--index").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 0
            let out = arguments.firstIndex(of: "--out").map { URL(fileURLWithPath: arguments[$0 + 1]) }
                ?? video.deletingLastPathComponent().appendingPathComponent("decode-probe-ios")
            Task { @MainActor in
                await ExportParityHarness.decodeProbe(video: video, index: index, out: out) { print($0) }
                exit(0)
            }
            return
        }
        func argValue(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if let fixtures = argValue("--ios-export-formats") {
            let out = URL(fileURLWithPath: argValue("--out") ?? NSTemporaryDirectory() + "export-formats-ios", isDirectory: true)
            let reference = argValue("--reference").map { URL(fileURLWithPath: $0, isDirectory: true) }
            stage.isHidden = true
            Task { @MainActor in
                let pass = await ExportFormatsParityHarness.run(
                    fixtures: URL(fileURLWithPath: fixtures, isDirectory: true), out: out, reference: reference) { print($0) }
                exit(pass ? 0 : 1)
            }
            return
        }
        if let dir = argValue("--ios-delivery-test") {
            stage.isHidden = true
            let movie = argValue("--movie").map { URL(fileURLWithPath: $0) }
            Task { @MainActor in await DeliveryLab.run(presenter: self, dir: URL(fileURLWithPath: dir, isDirectory: true), movie: movie) }
            return
        }
        if EditorShellLab.handles(arguments, host: self) { return }
        if let i = arguments.firstIndex(of: "--ios-preview-export-parity"), arguments.indices.contains(i + 1) {
            let fixture = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            func value(_ name: String) -> String? {
                arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            }
            let out = value("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? fixture.deletingLastPathComponent().appendingPathComponent("preview-export-ios", isDirectory: true)
            let reference = value("--reference").map { URL(fileURLWithPath: $0) }
            PreviewExportParityHarness.injectExportDefect = arguments.contains("--inject")
            stage.isHidden = true
            Task { @MainActor in await PreviewExportLab.run(in: view, fixture: fixture, out: out, reference: reference) }
            return
        }
        if let options = ExportParityHarness.options(from: arguments, flag: "--ios-export-parity") {
            stage.isHidden = true
            Task { @MainActor in await ExportLab.run(options) }
            return
        }
        if let i = arguments.firstIndex(of: "--ios-preview-parity"), arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            stage.isHidden = true
            Task { @MainActor in await ParityLab.run(in: view, fixtureDir: dir) }
            return
        }
        if let i = arguments.firstIndex(of: "--renderin-probe"), arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            Task { @MainActor in await RenderInProbe.run(stage: stage, fixtureDir: dir) }
            return
        }
        if let i = arguments.firstIndex(of: "--smoke"), arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            Task { @MainActor in await LabSmoke.run(stage: stage, fixtureDir: dir) }
        }
    }
}

/// `--ios-preview-export-parity <fixtureDir> [--out <dir>] [--reference <mac results.json>]`
/// (Studio 3c): the iOS preview — a PreviewStageView at exactly the fixture
/// canvas (magnification 1) in this real window, captured through the render
/// server at 2× — against the iOS export of the same frame, through the shared
/// PreviewExportParityHarness; judged against the Mac control's results.
@MainActor
enum PreviewExportLab {
    final class Stage: PreviewExportStage {
        let view: PreviewStageView
        init(view: PreviewStageView) { self.view = view }
        func render(_ input: PreviewCompositorCore.FrameInput) { view.schedule(input) }
        func capture() async -> CGImage? { LabCapture.view(view, scale: PreviewExportParityHarness.scale) }
        var core: PreviewCompositorCore { view.core }
    }

    static func run(in root: UIView, fixture: URL, out: URL, reference: URL?) async {
        guard let data = try? Data(contentsOf: fixture.appendingPathComponent(ParityFixtureFile.fileName)),
              let file = try? JSONDecoder().decode(ParityFixtureFile.self, from: data) else {
            print("PREVIEW-EXPORT-PARITY FAIL fixture unreadable"); exit(1)
        }
        let stageView = PreviewStageView(frame: CGRect(origin: CGPoint(x: 0, y: 80), size: file.canvas))
        stageView.virtualCanvasSize = file.canvas
        stageView.rasterScaleOverride = PreviewExportParityHarness.scale
        root.addSubview(stageView)
        await LabTime.settle(0.3)
        let results = await PreviewExportParityHarness.run(
            fixtureDir: fixture, out: out, stage: Stage(view: stageView), reference: reference) { print($0) }
        let refs = reference.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([PreviewExportParityHarness.CaseResult].self, from: $0) } ?? []
        let pass = !results.isEmpty && results.allSatisfy { r in
            PreviewExportParityHarness.judge(r, reference: refs.first { $0.name == r.name }).pass
        }
        exit(pass ? 0 : 1)
    }
}

/// `--ios-export-parity <fixturesDir> [--out <dir>] [--only a,b] [--inject padding]`
/// (Studio 3a): the Mac's render-parity fixtures re-exported by the iOS
/// VideoExporter through the shared ExportParityHarness, scored against the
/// Mac's lossless taps and camera path. Exits 0 when every fixture passes.
@MainActor
enum ExportLab {
    static func run(_ options: ExportParityHarness.Options) async {
        print("EXPORT-PARITY fixtures=\(options.fixtures.path) out=\(options.out.path)"
              + (options.inject.map { " inject=\($0.rawValue)" } ?? "")
              + (options.sourceYUV ? " source=yuv" : "")
              + (options.reference.map { " reference=\($0.path)" } ?? ""))
        let results = await ExportParityHarness.run(options) { print($0) }
        exit(!results.isEmpty && results.allSatisfy(\.pass) ? 0 : 1)
    }
}

/// `--ios-delivery-test <dir> [--movie <file>]` (Studio 3d): the shipping
/// ExportDelivery against the real system — saves `<dir>/export.gif`,
/// `<dir>/still.png` and the movie into the Simulator's photo library and reads
/// each asset back (type, pixel size, GIF kept as GIF, movie duration), then
/// presents the Files export picker and the share sheet in this window. The
/// script grants StudioLab photo access first (`simctl privacy`).
@MainActor
enum DeliveryLab {
    static func run(presenter: UIViewController, dir: URL, movie: URL?) async {
        var failures = 0
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            if !pass { failures += 1 }
            print("DELIVERY \(pass ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        // Read access to fetch the saved assets back (the test only — the app
        // itself asks for add-only access).
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        var files = [dir.appendingPathComponent("export.gif"), dir.appendingPathComponent("still.png")]
        if let movie { files.append(movie) }
        for url in files {
            let kind = ExportDelivery.kind(for: url)
            do {
                let id = try await ExportDelivery.saveToPhotos(url)
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                    check("photos: \(url.lastPathComponent) saved and found", false, "no asset for \(id)"); continue
                }
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                let resource = PHAssetResource.assetResources(for: asset).first
                switch kind {
                case .movie:
                    check("photos: \(url.lastPathComponent) is a video", asset.mediaType == .video && asset.duration > 0,
                          "type \(asset.mediaType.rawValue), \(String(format: "%.2f", asset.duration)) s")
                case .gif:
                    check("photos: \(url.lastPathComponent) is an image kept as GIF",
                          asset.mediaType == .image && resource?.uniformTypeIdentifier == UTType.gif.identifier
                            && asset.pixelWidth == image?.width && asset.pixelHeight == image?.height,
                          "type \(asset.mediaType.rawValue), \(resource?.uniformTypeIdentifier ?? "–"), \(asset.pixelWidth)×\(asset.pixelHeight)")
                case .png:
                    check("photos: \(url.lastPathComponent) is a PNG image at full size",
                          asset.mediaType == .image && resource?.uniformTypeIdentifier == UTType.png.identifier
                            && asset.pixelWidth == image?.width && asset.pixelHeight == image?.height,
                          "type \(asset.mediaType.rawValue), \(resource?.uniformTypeIdentifier ?? "–"), \(asset.pixelWidth)×\(asset.pixelHeight)")
                }
            } catch {
                check("photos: \(url.lastPathComponent) saved", false, error.localizedDescription)
            }
        }
        // System UI in this real window: each controller presents, then goes.
        let file = files[0]
        for (name, controller) in [("files export picker", ExportDelivery.filesPicker(for: file) as UIViewController),
                                   ("share sheet", ExportDelivery.shareSheet(for: file, from: presenter.view))] {
            presenter.present(controller, animated: false)
            await LabTime.settle(1.0)
            check("\(name) presents", presenter.presentedViewController === controller,
                  "\(type(of: presenter.presentedViewController as Any))")
            presenter.dismiss(animated: false)
            await LabTime.settle(0.5)
        }
        print("DELIVERY-TEST \(failures == 0 ? "PASS" : "FAIL") failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Renders the Mac-dumped parity fixture once and captures the window.
@MainActor
enum LabSmoke {
    static func run(stage: PreviewStageView, fixtureDir: URL) async {
        print("LAB SMOKE fixture=\(fixtureDir.path)")
        do {
            let fixture = try ParityLabFixture.load(from: fixtureDir)
            stage.virtualCanvasSize = fixture.canvas
            stage.rasterScaleOverride = 2
            await LabTime.settle(0.3)
            stage.schedule(fixture.input())
            await LabTime.settle(0.4)
            stage.schedule(fixture.input())
            await LabTime.settle(0.4)
            guard let image = LabCapture.view(stage) else {
                print("LAB SMOKE FAIL capture"); exit(1)
            }
            try LabCapture.png(image).write(to: fixtureDir.appendingPathComponent("ios-smoke.png"))
            let frame = stage.core.lastVideoRect
            print("LAB SMOKE OK canvas=\(fixture.canvas) videoRect=\(frame) image=\(image.width)x\(image.height)")
            exit(0)
        } catch {
            print("LAB SMOKE FAIL \(error)")
            exit(1)
        }
    }
}

enum LabTime {
    /// Lets UIKit commit and CoreAnimation render.
    @MainActor static func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

enum LabCapture {
    /// What the window shows for `view`, at the screen's scale — through the
    /// real render server (`drawHierarchy`), so 3D transforms, masks and
    /// layer contents are composited exactly as on screen.
    @MainActor static func view(_ view: UIView, scale: CGFloat? = nil) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale ?? view.window?.screen.scale ?? 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        let image = renderer.image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return image.cgImage
    }

    static func png(_ image: CGImage) -> Data {
        UIImage(cgImage: image).pngData() ?? Data()
    }
}
