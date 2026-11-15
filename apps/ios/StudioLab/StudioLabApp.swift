import UIKit

/// StudioLab — the studio's harness app (never shipped). It hosts the SAME
/// StudioUI views the CaptureCat app ships (PreviewStageView) in a real
/// UIWindow, so a gate exercises the real view and window chain, not a bare
/// layer (CLAUDE.md §3, "wrong topology").
///
/// Driven by launch arguments (apps/ios/scripts/ios-preview-parity.sh):
///
///   --smoke <fixtureDir>    render the Mac-dumped parity fixture once and
///                           write what the window shows to <fixtureDir>/ios-smoke.png
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
        if let i = arguments.firstIndex(of: "--smoke"), arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            Task { @MainActor in await LabSmoke.run(stage: stage, fixtureDir: dir) }
        }
    }
}

/// Renders the Mac-dumped parity fixture once and captures the window.
@MainActor
enum LabSmoke {
    static func run(stage: PreviewStageView, fixtureDir: URL) async {
        print("LAB SMOKE fixture=\(fixtureDir.path)")
        do {
            let fixture = try LabFixture.load(from: fixtureDir)
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
