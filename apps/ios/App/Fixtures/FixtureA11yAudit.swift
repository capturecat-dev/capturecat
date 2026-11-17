#if DEBUG
import UIKit

/// `-uiFixtures -uiA11yAudit` (Studio 6a, apps/ios/scripts/ios-a11y.sh) — the
/// companion app's screens with assistive technology, in the app's own window
/// chain (RootViewController → shell → library / capture / account, the
/// presented dialogs and sheets), over the deterministic fixture world. Each
/// screen is audited by the shared `CCAccessibilityAudit` (what VoiceOver
/// reaches, labels, traits, MEASURED 44 pt targets, no overlapping focusable
/// frames) at the default text size and at the largest accessibility size
/// (every visible text fits, grew, overlaps nothing). Ends the process with
/// `APPA11Y-GATE PASS|FAIL`.
@MainActor
enum FixtureA11yAudit {
    private static var failures = 0
    private static var lines: [String] = []

    private struct Screen {
        let name: String
        let open: (ShellViewController) async -> Void
        let close: (ShellViewController) async -> Void
    }

    static func run(window: UIWindow, root: RootViewController) async {
        setbuf(stdout, nil)
        log("APPA11Y window=\(Int(window.bounds.width))×\(Int(window.bounds.height)) \(UIDevice.current.model) \(UIDevice.current.systemVersion)")
        let loaded = CCAccessibilityAudit.runtimeLoaded(in: window)
        check("ax-runtime", loaded, loaded ? "UIKit accessibility runtime loaded" : "UIKit accessibility runtime NOT loaded (run through ios-a11y.sh)")
        guard let shell = root.shell else { check("shell", false, "not signed in"); finish(); }
        await settle(1.0)

        let project = FixtureDirector.projectID(1)
        let screens: [Screen] = [
            Screen(name: "library", open: { shell in shell.select(.library, animated: false) }, close: { _ in }),
            Screen(name: "library-screenshots", open: { shell in
                shell.library.split.list.probeFilter.setSelectedIndex(2)
                shell.library.split.list.probeFilter.onChange?(2)
            }, close: { shell in
                shell.library.split.list.probeFilter.setSelectedIndex(0)
                shell.library.split.list.probeFilter.onChange?(0)
            }),
            Screen(name: "library-shares", open: { shell in
                shell.library.split.list.probeFilter.setSelectedIndex(3)
                shell.library.split.list.probeFilter.onChange?(3)
            }, close: { shell in
                shell.library.split.list.probeFilter.setSelectedIndex(0)
                shell.library.split.list.probeFilter.onChange?(0)
            }),
            Screen(name: "project", open: { shell in shell.library.showProject(project) },
                   close: { shell in shell.library.nav.popToRootViewController(animated: false) }),
            Screen(name: "share", open: { shell in shell.library.showShare("fxShareOnboard") },
                   close: { shell in shell.library.nav.popToRootViewController(animated: false) }),
            Screen(name: "capture-inbox", open: { shell in shell.select(.capture, animated: false) }, close: { _ in }),
            Screen(name: "account", open: { shell in shell.select(.account, animated: false) }, close: { _ in }),
            Screen(name: "confirm-dialog", open: { shell in
                CCAlert.confirm(title: "Forget my devices?", message: "This unlinks every Mac and iPhone on your account from Wi-Fi streaming.",
                                confirmTitle: "Forget devices", destructive: true, from: shell)
            }, close: dismiss),
            Screen(name: "action-sheet", open: { shell in
                shell.select(.library, animated: false)
                await settle(0.4)
                let sheet = CCActionSheet(title: "Onboarding walkthrough")
                sheet.addAction("Open", symbol: "play-fill") {}
                sheet.addAction("Rename", symbol: "pencil") {}
                sheet.addAction("Copy share link", symbol: "link") {}
                sheet.addAction("Delete", symbol: "trash", destructive: true) {}
                sheet.present(from: shell, source: shell.view)
            }, close: dismiss),
            Screen(name: "toast", open: { _ in
                _ = AppToaster.shared.show(title: "Link copied", message: "capturecat.so/share/fxShareOnboard", variant: .success, symbol: "link")
            }, close: { _ in await settle(4.0) }),
        ]
        for screen in screens {
            await audit(screen, shell: shell, window: window)
        }
        // Spoken toasts reach VoiceOver through the kit's announcer.
        CCAccessibility.probeAnnouncements = []
        _ = AppToaster.shared.show(title: "Uploaded", message: nil, variant: .success, symbol: "check")
        check("toast-announced", CCAccessibility.probeAnnouncements.contains("Uploaded"),
              "VoiceOver hears “\(CCAccessibility.probeAnnouncements.last ?? "")”")
        await settle(4.0)

        // Signed out: the sign-in (onboarding) screen.
        await FixtureWorld.shared.session.signOut()
        await settle(1.2)
        await audit(Screen(name: "sign-in", open: { _ in }, close: { _ in }), shell: nil, window: window)
        finish()
    }

    private static func dismiss(_ shell: ShellViewController) async {
        guard let presented = shell.presentedViewController ?? shell.parent?.presentedViewController else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in presented.dismiss(animated: false) { c.resume() } }
        await settle(0.3)
    }

    private static func audit(_ screen: Screen, shell: ShellViewController?, window: UIWindow) async {
        if let shell { await screen.open(shell) }
        await settle(1.0)
        let base = CCAccessibilityAudit.fontSizes(in: window)
        let normal = CCAccessibilityAudit.screen(window)
        lines.append("== \(screen.name) [default]")
        lines += normal.lines
        check("\(screen.name)-voiceover", normal.problems.isEmpty, normal.summary)
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        await settle(0.8)
        let big = CCAccessibilityAudit.screen(window, baseFonts: base)
        lines.append("== \(screen.name) [xxxl]")
        lines += big.lines
        check("\(screen.name)-xxxl", big.problems.isEmpty, big.summary)
        window.traitOverrides.preferredContentSizeCategory = .large
        await settle(0.5)
        if let shell { await screen.close(shell) }
        await settle(0.3)
    }

    private static func finish() -> Never {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("a11y-audit.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        for line in lines where line.hasPrefix("   ! ") || line.hasPrefix("== ") { print("APPA11Y \(line)") }
        log(failures == 0 ? "APPA11Y-GATE PASS" : "APPA11Y-GATE FAIL (\(failures) check(s) failed)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func settle(_ s: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    private static func log(_ line: String) {
        print(line)
        lines.append(line)
    }

    private static func check(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        log("APPA11Y \(name) \(pass ? "PASS" : "FAIL") — \(detail)")
    }
}
#endif
