import UIKit

/// Signed out → the sign-in screen; signed in → the shell. Swaps on
/// `.ccSessionDidChange` (sign-in, sign-out, any 401) with the house settle:
/// the incoming screen fades up from 98% while the outgoing one fades away.
final class RootViewController: UIViewController {
    private(set) var current: UIViewController?
    var shell: ShellViewController? { current as? ShellViewController }
    private var pendingProjectID: String?
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CCTheme.color.background
        AppToaster.shared.attach(to: view)
        observer = NotificationCenter.default.addObserver(forName: .ccSessionDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithSession(animated: true) }
        }
        syncWithSession(animated: false)
    }

    var isSignedIn: Bool { AppEnvironment.shared.session.user != nil }

    func syncWithSession(animated: Bool) {
        if isSignedIn {
            guard !(current is ShellViewController) else { return }
            let shell = ShellViewController()
            transition(to: shell, animated: animated)
            LibraryStore.shared.refresh()
            if let id = pendingProjectID {
                pendingProjectID = nil
                DispatchQueue.main.async { shell.openProject(id) }
            }
        } else {
            guard !(current is SignInViewController) else { return }
            LibraryStore.shared.reset()
            transition(to: SignInViewController(), animated: animated)
        }
    }

    private func transition(to new: UIViewController, animated: Bool) {
        let old = current
        current = new
        addChild(new)
        new.view.frame = view.bounds
        new.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(new.view)
        new.didMove(toParent: self)
        AppToaster.shared.bringToFront()
        guard let old else { return }
        old.willMove(toParent: nil)
        if animated, view.window != nil {
            CCMotion.fadeAlpha(new.view, to: 1, duration: 0.32, from: 0)
            if !CCMotion.reduceMotion {
                CCMotion.spring(new.view.layer, keyPath: "transform.scale", from: 0.98, to: 1.0, .smooth)
            }
            CCMotion.fadeAlpha(old.view, to: 0, duration: 0.22)
            DispatchQueue.main.asyncAfter(deadline: .now() + CCMotion.paced(0.25)) {
                old.view.removeFromSuperview()
                old.removeFromParent()
            }
        } else {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// `capturecat://open-project?id=<UUID>`.
    func openProject(_ id: String) {
        if let shell {
            presentedViewController?.dismiss(animated: false)
            shell.openProject(id)
        } else {
            pendingProjectID = id
        }
    }
}
