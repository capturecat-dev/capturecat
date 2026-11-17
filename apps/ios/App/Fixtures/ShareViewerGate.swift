#if DEBUG
import AVFoundation
import UIKit

/// `-shareViewerGate` (with `-apiBaseURL http://127.0.0.1:<port>` pointing at
/// Tests/mock_api.py, shares seeded by scripts/ios-share-viewer.sh): the share
/// viewer end to end in the REAL app — the live stack, the real window and
/// root, links routed through the real SceneDelegate entry points:
///
///  • a universal link (the NSUserActivity iOS hands `scene(_:continue:)`;
///    injected here because the AASA isn't live for a Simulator build) and
///    the custom scheme (`handle(url:)`, plus a REAL `simctl openurl` the
///    script fires when the gate asks for it); non-share URLs go to the browser;
///  • playback, `?t=`, markers at the right x, reaction dots, timestamp chip
///    seeks, reactions (optimistic, rolled back on a 500, toggled off),
///    signed-out comment with a name, the sign-in prompt, a signed-in reply
///    carrying the bearer, Summary / Transcript / captions;
///  • password (wrong, then right — the token rides on the stream), expired,
///    view limit, paused, private, the owner's private, removed, comments off,
///    missing;
///  • motion sampled MID-FLIGHT (the reaction pop, the floater's rise) and
///    Reduce Motion (the floater fades in place);
///  • the accessibility audit (CCAccessibilityAudit) over the open viewer at
///    the default and the largest text size.
///
/// `-shareViewerInject marker-offset|no-rollback|seek-ignored|drop-token|snap`
/// puts a defect in the shipping path: the gate must FAIL.
/// Prints `SHAREVIEWER <check> PASS|FAIL …`, `SHAREVIEWER-GATE PASS|FAIL`,
/// writes Documents/share-viewer/{gate.txt,*.png}, exits.
@MainActor
final class ShareViewerGate {
    /// `-shareViewerColdLink <https URL>`: the NSUserActivity a tapped
    /// universal link hands a cold launch (scene connection options).
    static func coldLaunchActivity() -> NSUserActivity? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-shareViewerColdLink"), index + 1 < args.count,
              let url = URL(string: args[index + 1]) else { return nil }
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        return activity
    }

    static func startIfRequested(in window: UIWindow) {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-shareViewerInject"), index + 1 < args.count {
            ShareViewerModel.probeInject = args[index + 1]
        }
        guard args.contains("-shareViewerGate") else { return }
        let gate = ShareViewerGate(window: window)
        running = gate
        Task { await gate.run() }
    }

    private static var running: ShareViewerGate?
    private let window: UIWindow
    private var lines: [String] = []
    private var failures = 0
    private let out: URL

    private init(window: UIWindow) {
        self.window = window
        out = ShareLinkRouter.probeLogURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [] where name.hasSuffix(".png") || name == "gate.txt" {
            try? FileManager.default.removeItem(at: out.appendingPathComponent(name))
        }
    }

    private var scene: SceneDelegate? { window.windowScene?.delegate as? SceneDelegate }
    private var root: RootViewController? { window.rootViewController as? RootViewController }
    private var viewer: ShareViewerViewController? {
        sequence(first: root?.presentedViewController, next: { $0?.presentedViewController })
            .compactMap { $0 as? ShareViewerViewController }.last
    }

    // MARK: - Plumbing

    private func record(_ name: String, _ pass: Bool, _ detail: String) {
        if !pass { failures += 1 }
        let line = "SHAREVIEWER \(name) \(pass ? "PASS" : "FAIL") \(detail)"
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

    private func viewerState() async -> (log: [[String: Any]], shares: [String: Any]) {
        let state = (await mock("GET", "/__state"))?["viewer"] as? [String: Any]
        return (state?["log"] as? [[String: Any]] ?? [], state?["shares"] as? [String: Any] ?? [:])
    }

    private func snapshot(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: out.appendingPathComponent(name))
    }

    /// Open a link the way the system delivers it, and wait for its viewer.
    private func open(_ url: String, universal: Bool) async -> ShareViewerViewController? {
        let target = URL(string: url)!
        if universal {
            let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            activity.webpageURL = target
            scene?.scene(window.windowScene!, continue: activity)
        } else {
            scene?.handle(url: target, cold: false)
        }
        let id = ShareLink.parse(target)?.videoID
        _ = await waitFor(4000) { self.viewer?.videoID == id && self.viewer?.isBeingPresented == false }
        await sleep(300)
        return viewer
    }

    private func closeViewer() async {
        guard let viewer else { return }
        viewer.close()
        _ = await waitFor(3000) { self.viewer == nil }
        await sleep(300)
    }

    private func waitReady(_ v: ShareViewerViewController, _ ms: Int = 8000) async -> Bool {
        await waitFor(ms) { v.probeSurface.player.currentItem?.status == .readyToPlay && v.probeSurface.duration > 0 }
    }

    // MARK: - Run

    private func run() async {
        let host = URL(string: CaptureCatAPI.baseURL)?.host
        guard host == "127.0.0.1" || host == "localhost" else {
            record("setup", false, "API base \(CaptureCatAPI.baseURL) is not the local mock — launch with -apiBaseURL http://127.0.0.1:<port>")
            return finish()
        }
        if let inject = ShareViewerModel.probeInject { print("SHAREVIEWER inject \(inject)") }
        if ShareViewerModel.probeInject == "snap" { CCMotion.probeSnap = true }
        SessionStore.clear()
        try? FileManager.default.removeItem(at: ShareLinkRouter.probeLogURL)
        ShareLinkRouter.probeRoutes = []
        var browser: [URL] = []
        ShareLinkRouter.probeBrowser = { browser.append($0) }
        await sleep(1200)

        // 1. Link parsing: only share paths open the viewer.
        let parses: [(String, String?)] = [
            ("https://capturecat.so/share/svOpen01", "svOpen01"), ("https://www.capturecat.so/share/svOpen01?t=4", "svOpen01"),
            ("capturecat://share/svOpen01", "svOpen01"), ("capturecat://share?id=svOpen01&t=3", "svOpen01"),
            ("https://capturecat.so/share/svOpen01.md", nil), ("https://capturecat.so/pricing", nil),
            ("https://capturecat.so/embed/svOpen01", nil), ("https://evil.example/share/svOpen01", nil),
            ("capturecat://open-project?id=x", nil), ("https://capturecat.so/share/a/b", nil),
        ]
        let wrong = parses.filter { ShareLink.parse(URL(string: $0.0)!)?.videoID != $0.1 }
        record("link-parse", wrong.isEmpty, wrong.isEmpty ? "\(parses.count) URLs classified (share paths only; .md twin, embed, other hosts refused)"
               : "misclassified: \(wrong.map(\.0))")
        let other = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        other.webpageURL = URL(string: "https://capturecat.so/pricing")
        scene?.scene(window.windowScene!, continue: other)
        await sleep(300)
        record("non-share-universal-link-to-browser", browser.map(\.absoluteString) == ["https://capturecat.so/pricing"] && viewer == nil,
               "browser got \(browser.map(\.absoluteString)), viewer=\(viewer == nil ? "none" : "OPENED")")

        // 2. Universal link (warm), with ?t=.
        guard let v = await open("https://capturecat.so/share/svOpen01?t=2", universal: true) else {
            record("universal-link-warm", false, "no viewer")
            return finish()
        }
        let ready = await waitReady(v)
        record("universal-link-warm", ready && ShareLinkRouter.probeRoutes.last == "universal-link warm svOpen01 t=2.0",
               "route \(ShareLinkRouter.probeRoutes.last ?? "-"), presented fullscreen=\(v.modalPresentationStyle == .fullScreen), ready=\(ready)")
        let started = v.probeSurface.currentTime
        record("start-at-t", started >= 1.95 && started < 3.2 && v.probeSurface.isPlaying,
               String(format: "?t=2 → playback from %.2f s (playing=%@)", started, v.probeSurface.isPlaying ? "yes" : "no"))
        await sleep(600)
        snapshot("viewer-open-light.png")

        // 3. Plays.
        v.probeSurface.pause()
        v.probeSurface.seek(to: 0.5)
        await sleep(300)
        v.probeSurface.playButton.sendActions(for: .touchUpInside)
        await sleep(1600)
        let t1 = v.probeSurface.currentTime
        let playing = v.probeSurface.isPlaying
        v.probeSurface.pause()
        record("plays", playing && t1 > 1.2, String(format: "playing=%@, 0.5 → %.2f s after 1.6 s", playing ? "yes" : "no", t1))

        // 4. Title, byline, tabs, reactions seeded.
        let model = v.model
        _ = await waitFor(3000) { model.commentsLoaded }
        record("header", v.probeTitle == "Setting up the release pipeline" && v.probeByline.contains("0:12") && v.probeByline.hasSuffix("Shared via CaptureCat"),
               "title \"\(v.probeTitle)\" · byline \"\(v.probeByline)\"")
        record("tabs", v.tabOrder == [.comments, .summary, .transcript] && v.selectedTab == .comments,
               "tabs \(v.tabOrder.map(\.rawValue)), selected \(v.selectedTab.rawValue)")

        // 5. Markers at the right x (and reaction dots).
        await sleep(300)
        let timeline = v.probeTimeline
        let duration = timeline.duration
        var markerErrors: [String] = []
        let expectTimes: [Double] = [3, 9]
        let markers = timeline.markerViews
        for (marker, time) in zip(markers, expectTimes) {
            let foot = marker.convert(CGPoint(x: marker.bounds.midX - marker.stemOffset, y: 0), to: timeline).x
            let scrub = timeline.scrubber
            let expected = scrub.frame.minX + scrub.trackInset + CGFloat(time / duration) * (scrub.bounds.width - scrub.trackInset * 2)
            if abs(foot - expected) > 1 { markerErrors.append(String(format: "t=%.0f at x=%.1f, want %.1f", time, foot, expected)) }
        }
        let dotsOK = zip(timeline.scrubber.dotViews, model.reactions).allSatisfy { dot, r in
            abs(dot.center.x - timeline.scrubber.trackX(for: r.videoTime)) < 1
        }
        record("markers-x", markers.count == 2 && markerErrors.isEmpty && dotsOK,
               "\(markers.count) markers (Alex Kim + reply → one, Jo Park), track \(Int(timeline.scrubber.bounds.width)) pt, duration \(duration) s; \(markerErrors.isEmpty ? "each stem on its moment ±1 pt" : markerErrors.joined(separator: "; ")); reaction dots on their moments=\(dotsOK)")

        // 6. Timestamp chip seeks (and plays).
        if let row = v.commentRows().first(where: { $0.comment.commentId == "c3" }), let chip = row.timeChip {
            v.probeSurface.seek(to: 0)
            await sleep(200)
            chip.sendActions(for: .touchUpInside)
            await sleep(700)
            let t = v.probeSurface.currentTime
            record("timestamp-chip-seeks", t >= 8.9 && t < 10.5 && v.probeSurface.isPlaying, String(format: "chip 0:09 → playhead %.2f s, playing=%@", t, v.probeSurface.isPlaying ? "yes" : "no"))
            v.probeSurface.pause()
        } else {
            record("timestamp-chip-seeks", false, "no row for c3")
        }
        // Marker tap jumps too.
        markers.last?.sendActions(for: .touchUpInside)
        await sleep(400)
        record("marker-jumps", abs(v.probeSurface.currentTime - 9) < 0.3 && v.selectedTab == .comments,
               String(format: "marker → %.2f s", v.probeSurface.currentTime))

        // 7. Reactions: optimistic, landed, mid-flight, rolled back, toggled off.
        v.probeSurface.seek(to: 6)
        await sleep(300)
        let bar = v.probeReactionBar
        let party = bar.keys.first { $0.emoji == "🎉" }!
        party.sendActions(for: .touchUpInside)
        await sleep(30)
        let optimistic = model.myEmoji == "🎉" && party.isChosen
        // Mid-flight: the landing pop and the floater's rise, sampled.
        var pops: [CGFloat] = [], rises: [CGFloat] = []
        let floater = v.probeSurface.floaterViews.last
        let floaterStart = floater?.layer.presentation()?.position.y ?? 0
        for _ in 0..<30 {
            pops.append((party.layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1)
            if let floater { rises.append(floater.layer.presentation()?.position.y ?? floater.layer.position.y) }
            await sleep(16)
        }
        let popMid = pops.contains { $0 > 1.02 && $0 < 1.2 }
        let riseMid = rises.contains { $0 < floaterStart - 5 && $0 > (floater?.layer.position.y ?? 0) + 5 }
        record("reaction-motion-midflight", popMid && riseMid,
               String(format: "pop scale samples %.2f…%.2f (mid-flight=%@), floater y %.0f → model %.0f, mid-flight=%@",
                      pops.min() ?? 0, pops.max() ?? 0, popMid ? "yes" : "no", floaterStart, floater?.layer.position.y ?? 0, riseMid ? "yes" : "no"))
        _ = await waitFor(3000) { model.reactionCounts.contains { $0.emoji == "🎉" } }
        await sleep(500)
        var state = await viewerState()
        let mockReactions = ((state.shares["svOpen01"] as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []
        let mine = mockReactions.first { ($0["session"] as? String) == ShareViewerModel.reactionSession }
        record("reaction-posts", optimistic && (mine?["emoji"] as? String) == "🎉" && abs(((mine?["videoTime"] as? Double) ?? -1) - 6) < 0.3,
               "optimistic highlight=\(optimistic), mock stored \(mine.map { "\($0["emoji"] ?? "?") at \($0["videoTime"] ?? "?")" } ?? "nothing"), tallies \(model.reactionCounts.map { "\($0.emoji)\($0.count)" })")

        _ = await mock("POST", "/__viewer-control", json: ["failReactions": 1])
        let before = model.reactionCounts.map { "\($0.emoji)\($0.count)" }
        ShareViewerModel.probeOptimistic = []
        bar.keys.first { $0.emoji == "😮" }!.sendActions(for: .touchUpInside)
        _ = await waitFor(3000) { !ShareViewerModel.probeOptimistic.isEmpty }
        let wentOptimistic = ShareViewerModel.probeOptimistic.first == "😮"
        _ = await waitFor(3000) { model.myEmoji != "😮" }
        await sleep(300)
        let after = model.reactionCounts.map { "\($0.emoji)\($0.count)" }
        record("reaction-rollback", wentOptimistic && model.myEmoji == "🎉" && after == before && party.isChosen,
               "500 from the API: showed 😮 at once=\(wentOptimistic), back to \(model.myEmoji ?? "none"), tallies \(before) → \(after)")
        await sleep(400)
        party.sendActions(for: .touchUpInside)
        _ = await waitFor(3000) { model.myEmoji == nil }
        await sleep(500)
        state = await viewerState()
        let still = (((state.shares["svOpen01"] as? [String: Any])?["reactions"] as? [[String: Any]]) ?? [])
            .contains { ($0["session"] as? String) == ShareViewerModel.reactionSession }
        record("reaction-toggle-off", model.myEmoji == nil && !still && !party.isChosen, "same emoji again → none (mock holds ours=\(still))")

        // 8. Signed out: a comment with a name (no account needed — the web's rule).
        let composer = v.probeComposer
        record("signed-out-composer", composer.isSignedOutLayout && !composer.isHidden && composer.signInButton.window != nil,
               "name field + Sign in shown=\(composer.isSignedOutLayout)")
        v.probeSurface.seek(to: 4)
        await sleep(300)
        composer.nameField.text = "Guest Gina"
        _ = composer.field.becomeFirstResponder()
        await sleep(400)
        composer.field.insertText("Nice cut at the start")
        v.probeSurface.seek(to: 7)  // the chip keeps the moment writing began
        await sleep(200)
        let chipTitle = composer.timeChip.title
        composer.sendButton.sendActions(for: .touchUpInside)
        _ = await waitFor(4000) { model.comments.contains { $0.body == "Nice cut at the start" } }
        await sleep(500)
        state = await viewerState()
        let post = state.log.last { ($0["route"] as? String) == "comments" && ($0["method"] as? String) == "POST" }
        let body = post?["body"] as? [String: Any]
        let posted = model.comments.first { $0.body == "Nice cut at the start" }
        record("comment-signed-out", posted?.authorName == "Guest Gina" && post?["authorization"] is NSNull
                   && abs(((body?["videoTime"] as? Double) ?? -1) - 4) < 0.3 && chipTitle == "0:04"
                   && v.commentRows().contains { $0.comment.commentId == posted?.commentId },
               "posted as \(posted?.authorName ?? "-") at \(body?["videoTime"] ?? "-") (chip read \(chipTitle)), bearer=\(post?["authorization"] is NSNull ? "none" : "SENT"), row shown")
        await sleep(400)
        // 0:04 sits within one avatar of 0:03 on this track: it joins that
        // marker as a stack (the web's grouping) — 3 top-level comments in all.
        let grouped = timeline.markerViews.map(\.group.comments.count)
        record("comment-marker-added", grouped.reduce(0, +) == 3 && grouped.first == 2,
               "markers hold \(grouped) top-level comments after the post")
        snapshot("viewer-comments.png")

        // 9. The sign-in prompt → the app's sign-in (the browser leg stood in for).
        var prompted = false
        ShareViewerViewController.probeSignIn = { _ in
            prompted = true
            Task { @MainActor in
                guard let reply = await self.mock("GET", "/__session"), let token = reply["token"] as? String,
                      let user = reply["user"] as? [String: Any] else { return }
                SessionStore.save(AuthSession(token: token, expiresAt: Date().addingTimeInterval(86_400),
                                              user: AccountUser(id: user["id"] as? String ?? "", email: user["email"] as? String, name: user["name"] as? String, image: nil),
                                              apiBaseURL: CaptureCatAPI.baseURL))
            }
        }
        composer.signInButton.sendActions(for: .touchUpInside)
        _ = await waitFor(4000) { !composer.isSignedOutLayout }
        await sleep(600)
        record("sign-in-prompt", prompted && composer.identityLabel.text == "Commenting as Test User" && viewer === v,
               "prompt reached the sign-in flow=\(prompted), composer \"\(composer.identityLabel.text ?? "")\", viewer still up=\(viewer === v)")

        // 10. Signed in: a reply carries the bearer.
        if let row = v.commentRows().first(where: { $0.comment.commentId == "c1" }), let reply = row.replyButton {
            reply.sendActions(for: .touchUpInside)
            await sleep(400)
            composer.field.insertText("Thanks!")
            composer.sendButton.sendActions(for: .touchUpInside)
            _ = await waitFor(4000) { model.comments.contains { $0.body == "Thanks!" } }
            await sleep(400)
            state = await viewerState()
            let replyPost = state.log.last { ($0["route"] as? String) == "comments" && ($0["method"] as? String) == "POST" }
            let replyBody = replyPost?["body"] as? [String: Any]
            let replied = model.comments.first { $0.body == "Thanks!" }
            record("reply-signed-in", replied?.parentId == "c1" && replied?.authorName == "Test User"
                       && (replyPost?["authorization"] as? String)?.hasPrefix("Bearer ") == true && replyBody?["videoTime"] == nil,
                   "reply under c1 as \(replied?.authorName ?? "-"), bearer=\((replyPost?["authorization"] as? String)?.hasPrefix("Bearer ") == true)")
        } else {
            record("reply-signed-in", false, "no Reply on c1")
        }

        // 11. Summary, Transcript, captions.
        v.select(tab: .summary)
        await sleep(500)
        record("summary-tab", v.probeSummaryText.contains("A quick walk through the release checklist.") && v.probeSummaryText.contains("Checklist"),
               "\(v.probeSummaryText)")
        v.select(tab: .transcript)
        _ = await waitFor(3000) { v.probeTranscriptRows.count == 3 }
        v.probeTranscriptRows[1].sendActions(for: .touchUpInside)
        await sleep(500)
        let transcriptSeek = v.probeSurface.currentTime
        v.probeSurface.pause()
        record("transcript-tab", v.probeTranscriptRows.count == 3 && transcriptSeek >= 2.4 && transcriptSeek < 4,
               String(format: "%d lines; line 2 → %.2f s", v.probeTranscriptRows.count, transcriptSeek))
        snapshot("viewer-transcript.png")
        v.probeCaptionsKey.sendActions(for: .touchUpInside)
        v.seek(to: 7, play: false)
        await sleep(500)
        record("captions", v.captionsOn && v.probeSurface.captionText == "Then we cut the release build.",
               "captions on → \"\(v.probeSurface.captionText ?? "")\" at 7 s")

        // 12. Reduce Motion: the floater fades in place.
        CCAccessibility.forcedReduceMotion = true
        let floatersBefore = Set(v.probeSurface.floaterViews.map(ObjectIdentifier.init))
        bar.keys.first { $0.emoji == "👍" }!.sendActions(for: .touchUpInside)
        _ = await waitFor(2000) { v.probeSurface.floaterViews.contains { !floatersBefore.contains(ObjectIdentifier($0)) } }
        if let f = v.probeSurface.floaterViews.last(where: { !floatersBefore.contains(ObjectIdentifier($0)) }) {
            let y0 = f.layer.presentation()?.position.y ?? 0
            var ys: [CGFloat] = [], ops: [Float] = []
            for _ in 0..<50 {
                ys.append(f.layer.presentation()?.position.y ?? f.layer.position.y)
                ops.append(f.layer.presentation()?.opacity ?? f.layer.opacity)
                await sleep(25)
            }
            let still = ys.allSatisfy { abs($0 - y0) < 0.5 }
            let fading = ops.contains { $0 > 0.05 && $0 < 0.95 }
            record("reduce-motion-floater", still && fading, "travel \(Int((ys.max() ?? 0) - (ys.min() ?? 0))) pt, opacity mid-fade=\(fading)")
        } else {
            record("reduce-motion-floater", false, "no floater")
        }
        CCAccessibility.forcedReduceMotion = nil
        await sleep(600)

        // 13. Dark mode + the accessibility audit, in the real window.
        v.select(tab: .comments, animated: false)
        window.overrideUserInterfaceStyle = .dark
        await sleep(600)
        snapshot("viewer-open-dark.png")
        window.overrideUserInterfaceStyle = .unspecified
        await sleep(400)
        await audit(v)

        await closeViewer()

        // 14. The custom scheme (warm, the SceneDelegate path) → each state.
        await states()

        // 15. A REAL `simctl openurl` while running (the script fires it).
        await closeViewer()
        print("SHAREVIEWER await-openurl capturecat://share/svQuiet01?t=1")
        let arrived = await waitFor(30000) { ShareLinkRouter.probeRoutes.contains("custom-scheme warm svQuiet01 t=1.0") }
        _ = await waitFor(4000) { self.viewer?.videoID == "svQuiet01" }
        record("custom-scheme-openurl-warm", arrived && viewer?.videoID == "svQuiet01",
               "simctl openurl → \(ShareLinkRouter.probeRoutes.last ?? "-")")
        finish()
    }

    private func states() async {
        // Password: wrong, then right; the token rides on the stream.
        if let v = await open("capturecat://share/svLock01", universal: false) {
            _ = await waitFor(3000) { (v.probeStateHost.arrangedSubviews.first as? ShareStateCard)?.kind == "locked" }
            let card = v.probeStateHost.arrangedSubviews.first as? ShareStateCard
            snapshot("state-locked.png")
            card?.passwordField?.text = "nope"
            card?.watchButton?.sendActions(for: .touchUpInside)
            _ = await waitFor(3000) { card?.errorLabel?.isHidden == false }
            let wrong = card?.errorLabel?.text ?? ""
            card?.passwordField?.text = "opensesame"
            card?.watchButton?.sendActions(for: .touchUpInside)
            _ = await waitFor(4000) { v.model.phase == .open }
            let ready = await waitReady(v)
            let state = await viewerState()
            let stream = state.log.last { ($0["route"] as? String) == "stream" && ($0["videoId"] as? String) == "svLock01" }
            record("state-password", wrong == "Wrong password." && v.model.phase == .open && ready
                       && ((stream?["query"] as? String) ?? "").contains("token=unlock-svLock01"),
                   "wrong → \"\(wrong)\"; right → open, plays=\(ready), stream query \"\(stream?["query"] ?? "-")\"")
            await closeViewer()
        }
        let cases: [(String, String, String)] = [
            ("svExp01", "expired", "This share link has expired."),
            ("svView01", "view_limit", "This video has reached its view limit."),
            ("svPause01", "paused", "This share is paused — the owner’s plan no longer includes cloud sharing."),
            ("svPriv01", "private-signed-in", "Only its owner can watch it."),
            ("svGone01", "removed", "This video was removed for violating CaptureCat's terms."),
            ("svNope01", "not-found", "This link doesn't lead to a video anymore. It may have been deleted."),
        ]
        for (id, kind, message) in cases {
            guard let v = await open("capturecat://share/\(id)", universal: false) else {
                record("state-\(kind)", false, "no viewer")
                continue
            }
            _ = await waitFor(4000) { (v.probeStateHost.arrangedSubviews.first as? ShareStateCard)?.kind == kind }
            let card = v.probeStateHost.arrangedSubviews.first as? ShareStateCard
            record("state-\(kind)", card?.kind == kind && card?.messageText == message && v.probeSurface.isHidden && v.probeComposer.isHidden,
                   "card \(card?.kind ?? "none"): \"\(card?.messageText ?? "")\", player hidden=\(v.probeSurface.isHidden)")
            if kind == "removed" { snapshot("state-removed.png") }
            if kind == "private-signed-in" { snapshot("state-private.png") }
            await closeViewer()
        }
        // The owner's own private share: plays, no social.
        if let v = await open("capturecat://share/svMine01", universal: false) {
            let ready = await waitReady(v)
            record("state-owner-private", v.model.isOwnerPrivate && ready && v.probeByline.contains("only you can watch") && v.probeComposer.isHidden && v.tabOrder.isEmpty,
                   "owner bearer plays it=\(ready), byline \"\(v.probeByline)\", no comments/tabs")
            await closeViewer()
        }
        // Comments off (and no summary/transcript): no tabs, no composer.
        if let v = await open("capturecat://share/svQuiet01", universal: false) {
            let ready = await waitReady(v)
            await sleep(300)
            let state = await viewerState()
            let asked = state.log.contains { ($0["route"] as? String) == "comments" && ($0["videoId"] as? String) == "svQuiet01" }
            record("state-comments-off", ready && v.tabOrder.isEmpty && v.probeComposer.isHidden && !asked && v.probeTimeline.markerViews.isEmpty
                       && v.probeCaptionsKey.isHidden,
                   "plays=\(ready), tabs \(v.tabOrder.map(\.rawValue)), composer hidden=\(v.probeComposer.isHidden), comments fetched=\(asked), captions key hidden=\(v.probeCaptionsKey.isHidden)")
            snapshot("state-comments-off.png")
            // A second link replaces the open viewer.
            let next = await open("capturecat://share/svOpen01", universal: false)
            record("second-link-replaces", next?.videoID == "svOpen01" && next !== v, "svQuiet01 → \(next?.videoID ?? "-")")
            await closeViewer()
        }
    }

    private func audit(_ v: ShareViewerViewController) async {
        _ = CCAccessibilityAudit.runtimeLoaded(in: window)
        v.scrollView.setContentOffset(CGPoint(x: 0, y: -v.scrollView.adjustedContentInset.top), animated: false)
        _ = v.probeComposer.field.resignFirstResponder()
        await sleep(600)
        let base = CCAccessibilityAudit.fontSizes(in: window)
        let normal = CCAccessibilityAudit.screen(window)
        for line in normal.lines where line.hasPrefix("   ! ") { print("SHAREVIEWER audit \(line)") }
        record("a11y-default", normal.problems.isEmpty, normal.summary)
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        await sleep(900)
        let big = CCAccessibilityAudit.screen(window, baseFonts: base)
        for line in big.lines where line.hasPrefix("   ! ") { print("SHAREVIEWER audit-xxxl \(line)") }
        record("a11y-xxxl", big.problems.isEmpty, big.summary)
        snapshot("viewer-xxxl.png")
        window.traitOverrides.preferredContentSizeCategory = .large
        await sleep(500)
    }

    private func finish() {
        CCMotion.probeSnap = false
        let verdict = "SHAREVIEWER-GATE \(failures == 0 && !lines.isEmpty ? "PASS" : "FAIL") (\(lines.count - failures)/\(lines.count) checks)"
        lines.append(verdict)
        print(verdict)
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("gate.txt"), atomically: true, encoding: .utf8)
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Darwin.exit(0) }
    }
}
#endif
