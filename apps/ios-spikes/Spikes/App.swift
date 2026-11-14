import UIKit

// CCSpikes — Phase 0 feasibility spikes for the iOS studio (throwaway).
//
// Driven by launch arguments so every run is scripted and reproducible:
//
//   xcrun devicectl device process launch --device <id> --console \
//       --terminate-existing so.capturecat.spikes --spike b --variant reader-nv12 --exit
//
// Each run writes Documents/results/<spike>-<variant>.json and prints one
// `SPIKE-RESULT {json}` line. One heavy configuration per launch: the
// process-lifetime peak footprint (task_vm_info.ledger_phys_footprint_peak)
// is only meaningful for a fresh process.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // BGContinuedProcessingTask handlers must be registered before launch
        // finishes (spike g).
        SpikeG.registerHandler()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = SpikeViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        Harness.shared.attach(root)
        Harness.shared.startFromLaunchArguments()
    }
}

/// A stage for layers under test plus a scrolling log.
final class SpikeViewController: UIViewController {
    let stage = UIView()
    private let log = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        stage.backgroundColor = UIColor(white: 0.08, alpha: 1)
        stage.clipsToBounds = true
        log.backgroundColor = .black
        log.textColor = UIColor(white: 0.85, alpha: 1)
        log.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        log.isEditable = false
        for v in [stage, log] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: g.topAnchor),
            stage.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: 9.0 / 16.0),
            log.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 8),
            log.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 8),
            log.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -8),
            log.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ])
    }

    func append(_ line: String) {
        log.text.append(line + "\n")
        let end = NSRange(location: (log.text as NSString).length - 1, length: 1)
        log.scrollRangeToVisible(end)
    }
}
