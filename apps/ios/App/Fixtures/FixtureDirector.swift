#if DEBUG
import UIKit

/// Debug-only driver for fixture runs: jumps to a screen for screenshots,
/// forces size-class changes live, and runs the MOTION PROBE — which samples
/// layers' PRESENTATION values mid-animation (never only settled frames) and
/// proves itself by catching an injected snap.
///
///     -uiFixtures -uiFixtureScreen project|share|share-off|capture|account|alert|prompt|prompt-error|
///                 sheet|library-screenshots|library-shares|comment-typing|toast
///     -uiFixtureProject <1…8>     which fixture project `project` opens
///     -uiOrientation landscape    rotate the window scene (iPhone)
///     -uiForceCompactAfter <s>    override to compact width after s seconds (live size-class change)
///     -uiMotionProbe              write Documents/motion-probe.txt (lines start MOTIONPROBE)
final class FixtureDirector {
    static let shared = FixtureDirector()
    private weak var window: UIWindow?
    private var root: RootViewController? { window?.rootViewController as? RootViewController }

    static func projectID(_ n: Int) -> String { String(format: "0F1C5A7E-0000-4000-8000-%012d", n) }

    func start(in window: UIWindow) {
        guard AppEnvironment.shared.isFixture else { return }
        self.window = window
        if FixtureWorld.has("-uiSidebarFull") { ShellViewController.railBelowWidth = 0 }
        if FixtureWorld.value("-uiOrientation") == "landscape", let scene = window.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        if let screen = FixtureWorld.value("-uiFixtureScreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.go(to: screen) }
        }
        if let after = FixtureWorld.value("-uiForceCompactAfter").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                self?.root?.traitOverrides.horizontalSizeClass = .compact
                print("FIXTURE forced compact width")
            }
        }
        if let after = FixtureWorld.value("-uiForceRegularAfter").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                self?.root?.traitOverrides.remove(UITraitHorizontalSizeClass.self)
                print("FIXTURE removed width override")
            }
        }
        if FixtureWorld.has("-uiFixtureRenameTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                Task { @MainActor in await Self.runRenameTest() }
            }
        }
        if FixtureWorld.has("-uiMotionProbe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                Task { @MainActor in await self?.runMotionProbe() }
            }
        }
    }

    private func go(to screen: String) {
        guard let root else { return }
        if screen == "signin-error" { return }
        guard let shell = root.shell else { return }
        let project = Self.projectID(Int(FixtureWorld.value("-uiFixtureProject") ?? "1") ?? 1)
        switch screen {
        case "project":
            shell.library.showProject(project)
        case "share":
            shell.library.showShare("fxShareOnboard")
        case "share-off":
            shell.library.showShare("fxShareRoadmap")
        case "capture":
            shell.select(.capture, animated: false)
        case "account":
            shell.select(.account, animated: false)
        case "library-screenshots":
            shell.library.split.list.probeFilter.setSelectedIndex(2)
            shell.library.split.list.probeFilter.onChange?(2)


        case "library-shares":
            shell.library.split.list.probeFilter.setSelectedIndex(3)
            shell.library.split.list.probeFilter.onChange?(3)
        case "alert":
            shell.select(.account, animated: false)
            CCAlert.confirm(title: "Forget my devices?",
                            message: "This unlinks every Mac and iPhone on your account from Wi-Fi streaming. Each one reconnects by itself the next time CaptureCat opens on it while signed in.",
                            confirmTitle: "Forget devices", destructive: true, from: shell)
        case "prompt", "prompt-error":
            shell.library.showProject(project)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let name = LibraryStore.shared.project(project)?.name ?? "Recording"
                CCAlert.prompt(title: "Rename", message: "The new name shows everywhere — on your Mac, the web and here.",
                               placeholder: "Project name", initialValue: name, confirmTitle: "Rename", from: shell) { _ in
                    if screen == "prompt-error" { throw ProjectActions.RenameError.busy }
                }
                if screen == "prompt-error" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard let alert = (CCAlert.topmost(from: shell) as? CCAlertController) else { return }
                        alert.showError(ProjectActions.RenameError.busy.localizedDescription)
                    }
                }
            }
        case "sheet":
            let list = shell.library.split.list
            let collection = list.probeCollectionView
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let cell = collection.visibleCells.compactMap({ $0 as? LibraryCardCell }).sorted(by: { $0.frame.minY < $1.frame.minY || ($0.frame.minY == $1.frame.minY && $0.frame.minX < $1.frame.minX) }).first,
                      let p = LibraryStore.shared.project(Self.projectID(1)) else { return }
                let sheet = CCActionSheet(title: p.name)
                sheet.addAction("Open", symbol: "play-fill") {}
                sheet.addAction("Rename", symbol: "pencil") {}
                sheet.addAction("Open in web editor", symbol: "globe") {}
                sheet.addAction("Copy share link", symbol: "link") {}
                sheet.addAction("Delete", symbol: "trash", destructive: true) {}
                sheet.present(from: list, source: cell)
            }
        case "comment-typing":
            shell.library.showShare("fxShareOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let share = (shell.library.nav.topViewController as? ShareDetailViewController)
                    ?? (shell.library.split.detailNav.topViewController as? ShareDetailViewController)
                share?.probeComposerField.text = "Can we tighten the intro?"
                _ = share?.probeComposerField.becomeFirstResponder()
            }
        case "toast":
            AppToaster.shared.show(title: "Link copied", message: "https://capturecat.so/share/fxShareOnboard", variant: .success, symbol: "link")
        default:
            break
        }
    }

    // MARK: - Rename (If-Match + conflict rebase) end to end

    /// Project 4's fixture answers its NEXT save with 409 + a newer document
    /// (someone changed trimStart on the Mac). The rename must land on THAT
    /// document — name changed, their trimStart kept — at their revision + 1.
    static func runRenameTest() async {
        let id = projectID(4)
        var lines: [String] = []
        let before = LibraryStore.shared.project(id)?.revision ?? -1
        do {
            try await ProjectActions.rename(projectID: id, to: "Q4 roadmap demo (final)")
            let detail = try await AppEnvironment.shared.api.cloudProject(id)
            let facts = detail.document.flatMap { $0.data(using: .utf8) }.flatMap(ProjectDocument.facts)
            let pass = facts?.name == "Q4 roadmap demo (final)" && facts?.trimStart == 1.5 && detail.revision == before + 2
            lines.append("RENAMETEST \(pass ? "PASS" : "FAIL") revision \(before)→\(detail.revision) name=\(facts?.name ?? "nil") trimStart=\(facts?.trimStart ?? -1) (their edit kept)")
            lines.append("RENAMETEST store name=\(LibraryStore.shared.project(id)?.name ?? "nil")")
        } catch {
            lines.append("RENAMETEST FAIL \(error.localizedDescription)")
        }
        let text = lines.joined(separator: "\n")
        print(text)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("rename-test.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Motion probe

    private func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private func runMotionProbe() async {
        guard let root, let shell = root.shell else { return }
        var lines: [String] = []
        var failures = 0
        func record(_ name: String, _ pass: Bool, _ detail: String) {
            if !pass { failures += 1 }
            lines.append("MOTIONPROBE \(name) \(pass ? "PASS" : "FAIL") \(detail)")
        }

        // 1. Tab switch: the floating tab bar's chip springs between items.
        if shell.isRegular == false {
            shell.select(.library, animated: false)
            await sleep(700)
            let bar = shell.tabBar
            let start = bar.probeItemRect(0).midX, end = bar.probeItemRect(1).midX
            shell.select(.capture, animated: true)
            await sleep(45)
            let x = (bar.probeChipLayer.presentation() ?? bar.probeChipLayer).position.x
            let alpha = shell.probeTabView(.capture).layer.presentation()?.opacity ?? -1
            record("tab-chip-midflight", x > start + 1 && x < end - 1,
                   String(format: "start=%.1f sampled=%.1f end=%.1f (45 ms in)", start, x, end))
            record("tab-content-crossfade", alpha > 0.01 && alpha < 0.99, String(format: "incoming opacity=%.2f (0→1)", alpha))
            await sleep(700)

            // 1b. Self-test: inject a snap; the same assertion must now FAIL.
            CCMotion.probeSnap = true
            shell.select(.library, animated: true)
            await sleep(45)
            let snappedX = (bar.probeChipLayer.presentation() ?? bar.probeChipLayer).position.x
            let caught = !(snappedX > start + 1 && snappedX < end - 1)
            record("inject-snap-detected", caught, String(format: "with probeSnap the chip read %.1f (settled at %.1f) — the mid-flight check %@", snappedX, start, caught ? "failed as it must" : "PASSED A SNAP (gate is blind)"))
            CCMotion.probeSnap = false
            await sleep(500)
        } else {
            let sidebar = shell.sidebar
            shell.select(.library, animated: false)
            await sleep(600)
            let startY = sidebar.probeChip.frame.midY
            shell.select(.account, animated: true)
            await sleep(45)
            let ty = (sidebar.probeChip.layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
            let endY = sidebar.probeChip.frame.midY
            let visualY = endY + ty
            record("sidebar-chip-midflight", visualY > min(startY, endY) + 1 && visualY < max(startY, endY) - 1,
                   String(format: "start=%.1f visual=%.1f end=%.1f", startY, visualY, endY))
            await sleep(600)
            shell.select(.library, animated: false)
        }

        // 2. Dialog entrance: the card settles in from 96% — sample mid-flight.
        let alert = CCAlert(title: "Rename", message: "Probe dialog")
        let field = CCField(placeholder: "Name", value: "Probe")
        alert.accessoryView = field
        alert.addButton("Rename", role: .primary)
        alert.addButton("Cancel", role: .cancel)
        alert.present(from: root)
        var card: UIView?
        for _ in 0..<200 {
            if let c = alert.probeCard, c.layer.animation(forKey: "ccmotion.transform.scale") != nil { card = c; break }
            await sleep(4)
        }
        if let card {
            await sleep(40)
            let scale = (card.layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? -1
            let opacity = card.layer.presentation()?.opacity ?? -1
            record("dialog-entrance-midflight", scale > 0.96 && scale < 0.9995, String(format: "scale=%.4f (0.96→1.0) opacity=%.2f", scale, opacity))

            // 3. Growth bounce: the inline error grows the card's BOTTOM edge
            // with an overshoot; the top edge must not move.
            await sleep(600)
            let top0 = card.frame.minY
            let h0 = card.bounds.height
            alert.probeShowError("Someone else is editing this project right now. Try again in a moment.")
            var maxH = h0, topDrift: CGFloat = 0, samples = 0, midSamples = 0
            for _ in 0..<90 {
                await sleep(8)
                let h = card.bounds.height
                maxH = max(maxH, h)
                topDrift = max(topDrift, abs(card.frame.minY - top0))
                samples += 1
            }
            let final = card.bounds.height
            for _ in 0..<1 { midSamples = samples }
            record("growth-overshoot", maxH > final + 0.5 && final > h0 + 4,
                   String(format: "start=%.1f peak=%.1f settled=%.1f (%d samples @8 ms)", h0, maxH, final, midSamples))
            record("growth-top-pinned", topDrift < 0.5, String(format: "top edge drift=%.2f pt", topDrift))
        } else {
            record("dialog-entrance-midflight", false, "card never started its entrance")
        }
        alert.dismiss()
        await sleep(500)

        // 4. Library filter chip (CCSegmented) springs between segments.
        let filter = shell.library.split.list.probeFilter
        shell.select(.library, animated: false)
        await sleep(300)
        let from = filter.probeSegmentRect(0).midX, to = filter.probeSegmentRect(1).midX
        filter.setSelectedIndex(1)
        await sleep(40)
        let fx = (filter.probeSelectionLayer.presentation() ?? filter.probeSelectionLayer).position.x
        record("segmented-chip-midflight", fx > from + 1 && fx < to - 1, String(format: "start=%.1f sampled=%.1f end=%.1f", from, fx, to))
        filter.setSelectedIndex(0, animated: false)

        lines.append("MOTIONPROBE SUMMARY \(failures == 0 ? "PASS" : "FAIL") failures=\(failures)")
        let text = lines.joined(separator: "\n")
        print(text)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("motion-probe.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
