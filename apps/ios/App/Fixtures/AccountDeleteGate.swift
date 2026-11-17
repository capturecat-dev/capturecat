#if DEBUG
import UIKit

/// `-accountDeleteGate` (with `-apiBaseURL http://127.0.0.1:<port>` pointing at
/// Tests/mock_api.py): Delete Account end to end in the REAL app — the live
/// stack (APIClient, SessionStore, the shared keychain, RootViewController's
/// session swap), the real Account screen in the real shell and window — never
/// a bare view in a pre-sized window. Driven by scripts/ios-account-delete.sh.
///
///  1. Signs in with the mock's session (`/__session`, no browser leg), fetches
///     the Wi-Fi link key, seeds this device's account data (a studio project,
///     an inbox take, library caches, an export, the preferred Mac).
///  2. The Account screen's Delete Account entry: in the window, scrolled into
///     view, and the topmost view under its centre (a real tap lands on it).
///  3. The confirmation: the house sheet rising MID-FLIGHT (presentation
///     translation sampled between start and rest), then the same check
///     FAILING with an injected snap (CCMotion.probeSnap) — the check can see
///     a snap; the copy names what goes, the subscription and the bucket; the
///     destructive button disabled until DELETE is typed (any case).
///  4. 409 (a team with members): the server's words inline, still signed in,
///     nothing wiped. 502 (billing): same. Dropped connection: "couldn't reach".
///  5. Success: the DELETE reached the mock with the live bearer; the app is
///     on the sign-in screen; no session, no link key; every seeded file gone.
///  6. A retry with the old token (a lost response) gets 401 → counted done.
///
/// Prints `ACCOUNTDELETE <check> PASS|FAIL …` and `ACCOUNTDELETE-GATE PASS|FAIL`,
/// writes Documents/account-delete/{gate.txt,account.png,confirm.png}, exits.
/// `-accountDeleteInject skip-wipe|skip-signout` puts a defect in the shipping
/// path (AccountDeletion.probeInject): the gate must FAIL.
@MainActor
final class AccountDeleteGate {
    static func startIfRequested(in window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("-accountDeleteGate") else { return }
        let gate = AccountDeleteGate(window: window)
        Self.running = gate
        Task { await gate.run() }
    }

    private static var running: AccountDeleteGate?
    private let window: UIWindow
    private var lines: [String] = []
    private var failures = 0
    private let out: URL

    private init(window: UIWindow) {
        self.window = window
        out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("account-delete", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    private var root: RootViewController? { window.rootViewController as? RootViewController }

    private func record(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        let line = "ACCOUNTDELETE \(name) \(pass ? "PASS" : "FAIL") \(detail)"
        lines.append(line)
        print(line)
    }

    private func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private func waitFor(_ timeoutMs: Int, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < timeoutMs {
            if condition() { return true }
            await sleep(25)
            waited += 25
        }
        return condition()
    }

    // MARK: - Mock

    private func mock(_ method: String, _ path: String, json: [String: Any]? = nil) async -> [String: Any]? {
        guard let url = URL(string: CaptureCatAPI.baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func deleteCalls() async -> [[String: Any]] {
        ((await mock("GET", "/__state"))?["deleteMe"] as? [String: Any])?["calls"] as? [[String: Any]] ?? []
    }

    // MARK: - Run

    private func run() async {
        let host = URL(string: CaptureCatAPI.baseURL)?.host
        guard host == "127.0.0.1" || host == "localhost" else {
            record("setup", false, "API base \(CaptureCatAPI.baseURL) is not the local mock — launch with -apiBaseURL http://127.0.0.1:<port>")
            return finish()
        }
        if let inject = AccountDeletion.probeInject { print("ACCOUNTDELETE inject \(inject)") }
        await sleep(800)

        // 1. Sign in with the mock's session; fetch the link key; seed data.
        guard let reply = await mock("GET", "/__session"), let token = reply["token"] as? String,
              let userJSON = reply["user"] as? [String: Any], let uid = userJSON["id"] as? String else {
            record("setup", false, "mock /__session unreachable")
            return finish()
        }
        let user = AccountUser(id: uid, email: userJSON["email"] as? String, name: userJSON["name"] as? String, image: nil)
        SessionStore.save(AuthSession(token: token, expiresAt: Date().addingTimeInterval(86_400), user: user, apiBaseURL: CaptureCatAPI.baseURL))
        let signedIn = await waitFor(4000) { root?.shell != nil }
        try? await WirelessLinkStore.refresh()
        record("setup-signed-in", signedIn && SharedKeychain.get(account: SharedKeychain.Account.wirelessLink) != nil,
               "shell up=\(signedIn), link key stored=\(SharedKeychain.get(account: SharedKeychain.Account.wirelessLink) != nil)")
        seedLocalData()
        let seeded = AccountDeletion.leftovers()
        record("setup-seeded", seeded.count >= 4, "this device holds: \(seeded.joined(separator: "; "))")
        guard let shell = root?.shell else { return finish() }

        // 2. The entry.
        shell.select(.account, animated: false)
        await sleep(900)
        let account = shell.account
        let button = account.probeDeleteButton
        // Scroll the way a person does: until the entry clears the floating
        // tab bar (the scroll view's adjusted inset), never past the end.
        if let scroll = sequence(first: button.superview, next: { $0?.superview }).compactMap({ $0 as? UIScrollView }).first {
            let inset = scroll.adjustedContentInset
            let inContent = button.convert(button.bounds, to: scroll)
            let wanted = inContent.maxY + CCSpace.lg - (scroll.bounds.height - inset.bottom)
            let maxOffset = max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: min(max(-inset.top, wanted), maxOffset)), animated: false)
        }
        await sleep(300)
        let frame = button.convert(button.bounds, to: window)
        let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
        let reachable = button.window === window && !frame.isEmpty && window.bounds.contains(frame) && (hit?.isDescendant(of: button) ?? false)
        record("entry-reachable", reachable,
               String(format: "\"%@\" at (%.0f, %.0f, %.0f×%.0f) in a %.0f×%.0f window; hit-test → %@",
                      button.title, frame.minX, frame.minY, frame.width, frame.height, window.bounds.width, window.bounds.height,
                      hit.map { String(describing: type(of: $0)) } ?? "nil"))
        snapshot("account.png")

        // 3. The confirmation: motion, copy, the typed gate; then cancel.
        let rise = await openAndSampleRise(button)
        record("confirm-rises-midflight", rise.midflight, rise.detail)
        if let alert = AccountDeletion.probeAlert {
            let words = labels(in: alert.probeCard).joined(separator: " ")
            let copyOK = ["shared videos", "cloud projects", "comments", "subscription is cancelled immediately",
                          "never delete the files in your bucket", "can't be undone", "type DELETE"]
                .allSatisfy { words.localizedCaseInsensitiveContains($0) }
            record("confirm-copy", copyOK, "title=\(alert.title) · docked sheet=\(alert.probeIsDocked)")
            let destructive = alert.probeButtons.first
            record("confirm-disabled-until-typed", destructive?.isEnabled == false && alert.probeButtons.last?.isEnabled == true,
                   "Delete Account enabled=\(destructive?.isEnabled ?? true), Cancel enabled=\(alert.probeButtons.last?.isEnabled ?? false)")
            await typeText("dele")
            let partial = destructive?.isEnabled == false
            await typeText("te")
            record("confirm-enables-on-typed-word", partial && destructive?.isEnabled == true,
                   "after \"dele\" enabled=\(!partial), after \"delete\" enabled=\(destructive?.isEnabled ?? false)")
            await sleep(500)  // the keyboard is up: the tightest the sheet gets
            let clipped = truncatedLabels(in: alert.probeCard)
            record("confirm-copy-readable-with-keyboard", clipped.isEmpty,
                   clipped.isEmpty ? "every label in the sheet at full height (scrolling where the keyboard leaves too little room)"
                                   : "TRUNCATED: \(clipped.joined(separator: " | "))")
            snapshot("confirm.png")
            alert.dismiss()
            await sleep(500)
        } else {
            record("confirm-copy", false, "no confirmation on screen")
        }

        // 3b. Self-test: an injected snap must fail the same mid-flight check.
        CCMotion.probeSnap = true
        let snapped = await openAndSampleRise(button)
        CCMotion.probeSnap = false
        record("inject-snap-detected", !snapped.midflight, "with probeSnap: \(snapped.detail) — the mid-flight check \(snapped.midflight ? "PASSED A SNAP (gate is blind)" : "failed as it must")")
        AccountDeletion.probeAlert?.dismiss()
        await sleep(500)

        // 4. Refusals: nothing deleted, still signed in, nothing wiped.
        let teamText = "You own the team \u{201C}Acme\u{201D} with 2 other members. Make another member an owner, or remove them, on the Team page first."
        await refusal("409-team", control: ["status": 409], button: button) { $0 == teamText }
        await refusal("502-billing", control: ["status": 502], button: button) { $0.contains("couldn't cancel your subscription") }
        await refusal("dropped-connection", control: ["mode": "drop", "count": 3], button: button) { $0 == AccountDeletionError.unreachable.errorDescription }

        // 5. Success.
        let before = await deleteCalls().count
        let opened = await openConfirmation(button)
        await typeText("DELETE")
        AccountDeletion.probeAlert?.probeButtons.first?.sendActions(for: .touchUpInside)
        let signedOut = await waitFor(6000) { root?.current is SignInViewController }
        await sleep(600)
        let calls = await deleteCalls()
        let last = calls.last
        record("success-request", opened && calls.count == before + 1 && (last?["answer"] as? Int) == 200
                   && (last?["authorization"] as? String) == "Bearer \(token)",
               "DELETE /api/me calls \(before)→\(calls.count), answer=\(last?["answer"] ?? "none"), bearer=live session")
        let signInUp = (root?.current as? SignInViewController)?.view.window === window
        record("success-signed-out", signedOut && signInUp && SessionStore.load() == nil
                   && SharedKeychain.get(account: SharedKeychain.Account.session) == nil,
               "root=\(root?.current.map { String(describing: type(of: $0)) } ?? "nil"), session=\(SessionStore.load() == nil ? "gone" : "STILL STORED")")
        let linkGone = SharedKeychain.get(account: SharedKeychain.Account.wirelessLink) == nil
        let left = AccountDeletion.leftovers()
        record("success-local-data-wiped", left.isEmpty && linkGone,
               left.isEmpty ? "studio projects, inbox, library caches, exports, App Group keys: empty; link key gone=\(linkGone)" : "LEFT: \(left.joined(separator: "; ")); link key gone=\(linkGone)")
        snapshot("signed-out.png")

        // 6. A retry with the dead token (the response was lost): done, not an error.
        let stale = APIClient(baseURL: { CaptureCatAPI.baseURL }, token: { token })
        do {
            let result = try await stale.deleteAccount()
            record("retry-401-counts-as-deleted", result.alreadyGone, "alreadyGone=\(result.alreadyGone)")
        } catch {
            record("retry-401-counts-as-deleted", false, "threw \(error.localizedDescription)")
        }
        finish()
    }

    /// A refusal from the server: the reason inline, the user still signed in,
    /// nothing on the device touched; then Cancel.
    private func refusal(_ name: String, control: [String: Any], button: CCButton, expect: (String) -> Bool) async {
        _ = await mock("POST", "/__delete-me", json: control)
        let before = await deleteCalls().count
        guard await openConfirmation(button), let alert = AccountDeletion.probeAlert else {
            record(name, false, "confirmation did not open")
            return
        }
        await typeText("delete")
        alert.probeButtons.first?.sendActions(for: .touchUpInside)
        let shown = await waitFor(5000) { alert.probeErrorText != nil }
        let text = alert.probeErrorText ?? "(none)"
        let reached = await deleteCalls().count >= before + 1
        let left = AccountDeletion.leftovers()
        await sleep(500)  // the error's growth settles
        let clipped = truncatedLabels(in: alert.probeCard)
        snapshot("refusal-\(name).png")
        let pass = clipped.isEmpty && shown && expect(text) && reached && alert.probeIsPresented && SessionStore.load() != nil
            && root?.shell != nil && left.count >= 4 && alert.probeButtons.first?.isEnabled == true
        record(name, pass, "inline: \"\(text)\" · request reached=\(reached) · signed in=\(SessionStore.load() != nil) · device data kept=\(left.count >= 4) · retry enabled=\(alert.probeButtons.first?.isEnabled ?? false)\(clipped.isEmpty ? "" : " · TRUNCATED: " + clipped.joined(separator: " | "))")
        _ = await mock("POST", "/__delete-me", json: [:])  // back to 200 (drops the mock didn't use up)
        alert.dismiss()
        await sleep(500)
    }

    private func openConfirmation(_ button: CCButton) async -> Bool {
        button.sendActions(for: .touchUpInside)
        let opened = await waitFor(2000) { AccountDeletion.probeAlert?.probeCard?.window != nil }
        await sleep(600)
        return opened
    }

    /// Tap the entry and sample the sheet's rise from the first frame.
    private func openAndSampleRise(_ button: CCButton) async -> (midflight: Bool, detail: String) {
        button.sendActions(for: .touchUpInside)
        guard await waitFor(2000, { AccountDeletion.probeAlert?.probeCard?.window != nil }), let alert = AccountDeletion.probeAlert,
              let card = alert.probeCard else {
            return (false, "confirmation did not open")
        }
        var samples: [CGFloat] = []
        for _ in 0..<45 {
            let layer = card.layer.presentation() ?? card.layer
            let value = (layer.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
            samples.append(value)
            await sleep(16)
        }
        let travel = card.superview.map { $0.bounds.height - card.frame.minY } ?? 0
        let mid = samples.filter { $0 > 2 && $0 < travel - 2 }
        let settled = abs(samples.last ?? 99) < 1
        let detail = String(format: "travel=%.0f pt, %d/%d samples mid-flight (first %.1f, max %.1f), settled at %.1f",
                            travel, mid.count, samples.count, samples.first ?? -1, samples.max() ?? -1, samples.last ?? -1)
        return (alert.probeIsDocked && !mid.isEmpty && settled, detail)
    }

    /// Type through the text input system (fires editingChanged like a key press).
    private func typeText(_ text: String) async {
        guard let field = AccountDeletion.probeField else { return }
        if !field.isFirstResponder { _ = field.becomeFirstResponder() }
        await sleep(150)
        field.insertText(text)
        await sleep(150)
    }

    /// Labels drawn shorter than their text needs (a squeezed sheet). A label
    /// inside a scroll view counts as readable when the scroll's content holds
    /// it at full height.
    private func truncatedLabels(in view: UIView?) -> [String] {
        guard let view else { return [] }
        var out: [String] = []
        if let label = view as? UILabel, let text = label.text, !text.isEmpty, !label.isHidden, label.bounds.width > 0 {
            let need = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
            if label.bounds.height + 0.5 < need {
                out.append(String(format: "\"%@…\" %.0f of %.0f pt", String(text.prefix(28)), label.bounds.height, need))
            }
        }
        for sub in view.subviews { out += truncatedLabels(in: sub) }
        return out
    }

    private func labels(in view: UIView?) -> [String] {
        guard let view else { return [] }
        var out: [String] = []
        if let label = view as? UILabel, let text = label.text { out.append(text) }
        for sub in view.subviews { out += labels(in: sub) }
        return out
    }

    private func seedLocalData() {
        let fm = FileManager.default
        let projectID = UUID().uuidString
        let studio = StudioEditorEntry.directory(for: projectID)
        try? fm.createDirectory(at: studio, withIntermediateDirectories: true)
        try? Data(#"{"id":"\#(projectID)","name":"Gate project"}"#.utf8).write(to: studio.appendingPathComponent("project.json"))
        let takeID = UUID().uuidString
        let take = PendingTake(id: takeID, kind: .screenshot, name: "Gate take", createdAt: Date(), mediaFile: "shot.png",
                               contentType: "image/png", duration: 8, pixelWidth: 10, pixelHeight: 20, state: .failed,
                               error: "gate seed", openedInStudio: nil)
        try? TakeInbox.save(take)
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: TakeInbox.mediaURL(of: take))
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureCatLibrary", isDirectory: true)
        for (sub, file) in [("facts", "\(projectID)@1.json"), ("thumbs", "\(projectID)@1.jpg")] {
            let dir = caches.appendingPathComponent(sub)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: dir.appendingPathComponent(file))
        }
        if #available(iOS 26, *) {
            let exports = StudioExportJob.exportsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? fm.createDirectory(at: exports, withIntermediateDirectories: true)
            try? Data([0]).write(to: exports.appendingPathComponent("Gate project.mp4"))
        }
        AppGroup.defaults.set("gate-mac", forKey: AppGroup.Keys.preferredMacID)
        UploadCenter.shared.reload()
    }

    private func snapshot(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: out.appendingPathComponent(name))
    }

    private func finish() {
        let verdict = "ACCOUNTDELETE-GATE \(failures == 0 && !lines.isEmpty ? "PASS" : "FAIL") (\(lines.count - failures)/\(lines.count) checks)"
        lines.append(verdict)
        print(verdict)
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("gate.txt"), atomically: true, encoding: .utf8)
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Darwin.exit(0) }
    }
}
#endif
