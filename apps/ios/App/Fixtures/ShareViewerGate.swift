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
///    the default and the largest text size;
///  • the owner's annotation markers (ranges at the right x, pills, Summary
///    rows, a tap snapping to a range's start); a seeded comment drawing on
///    the picture's REAL pixels (captures diffed along a row and a column)
///    in portrait, landscape fit and landscape fill, plus the finger's mapping
///    in the cropped picture; drawing → post (the body carries the
///    serializer's exact bytes; the script runs the WEB serializer over the
///    raw marks and compares); the share-detail "Allow comments" switch
///    (optimistic, PATCH with the bearer, rolled back + toast on a 500,
///    disabled with the reason on a plan without comments).
///
/// `-shareViewerInject marker-offset|no-rollback|seek-ignored|drop-token|snap|no-landscape|
/// annotation-marker-offset|drawing-box-rect|drawing-ignores-fill|serializer-drift|toggle-no-rollback`
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
        if ShareViewerModel.probeInject == "serializer-drift" { ShareAnnotationMath.probeDrift = true }
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

        // 3b. Phone landscape: the video spans the full width (and height) of
        // the screen over the page, controls float; portrait puts it back.
        // A REAL rotation of the window scene, not a trait override.
        if let scene = window.windowScene, UIDevice.current.userInterfaceIdiom == .phone {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
            _ = await waitFor(4000) { scene.effectiveGeometry.interfaceOrientation.isLandscape }
            await sleep(900)
            let bounds = window.bounds
            let frame = v.probeSurface.convert(v.probeSurface.bounds, to: window)
            let landscapeOK = bounds.width > bounds.height && v.isLandscapePlayer
                && abs(frame.minX) < 0.5 && abs(frame.width - bounds.width) < 0.5 && abs(frame.height - bounds.height) < 0.5
                && v.probeSurface.layer.cornerRadius == 0
            record("landscape-full-width", landscapeOK,
                   "window \(Int(bounds.width))×\(Int(bounds.height)) · video \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)) · radius \(v.probeSurface.layer.cornerRadius)")
            snapshot("viewer-landscape.png")
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            _ = await waitFor(4000) { !scene.effectiveGeometry.interfaceOrientation.isLandscape }
            await sleep(900)
            let back = v.probeSurface.convert(v.probeSurface.bounds, to: window)
            let portraitOK = !v.isLandscapePlayer && back.width < window.bounds.width && v.probeSurface.layer.cornerRadius > 0
            record("portrait-restores-page", portraitOK,
                   "video \(Int(back.width))×\(Int(back.height)) in the column, landscape=\(v.isLandscapePlayer)")
        }

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

        // 14b. Annotations: markers, drawings on the picture, drawing a
        // comment, and the share-detail comments switch.
        await annotations()
        await commentsSwitch()

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

    // MARK: - Annotations (markers, drawings, the comments switch)

    /// An RGBA8 bitmap of the window at the screen's scale.
    private struct Bitmap {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var scale: CGFloat

        func pixel(_ p: CGPoint) -> (Int, Int, Int)? {
            let x = Int(p.x * scale), y = Int(p.y * scale)
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
    }

    private func bitmap() -> Bitmap {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cg = image.cgImage!
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Bitmap(bytes: bytes, width: w, height: h, scale: CGFloat(w) / window.bounds.width)
    }

    /// Runs of pixels that differ between two captures along a segment
    /// (window points) → each run's centre, as a distance along the segment.
    private func diffRuns(_ a: Bitmap, _ b: Bitmap, from p0: CGPoint, to p1: CGPoint) -> [CGFloat] {
        let length = hypot(p1.x - p0.x, p1.y - p0.y)
        let step = 1 / a.scale
        var centres: [CGFloat] = []
        var runStart: CGFloat?
        var t: CGFloat = 0
        while t <= length {
            let p = CGPoint(x: p0.x + (p1.x - p0.x) * t / length, y: p0.y + (p1.y - p0.y) * t / length)
            var changed = false
            if let x = a.pixel(p), let y = b.pixel(p) {
                changed = max(abs(x.0 - y.0), abs(x.1 - y.1), abs(x.2 - y.2)) > 60
            }
            if changed, runStart == nil { runStart = t }
            if !changed, let start = runStart { centres.append((start + t - step) / 2); runStart = nil }
            t += step
        }
        if let start = runStart { centres.append((start + length) / 2) }
        return centres
    }

    /// Where the picture is, worked out HERE from the player layer's own
    /// gravity, bounds and the item's presentation size (not the app's maths).
    private func expectedVideoRect(_ s: ShareVideoSurface) -> CGRect {
        let layer = s.layer as! AVPlayerLayer
        let media = s.player.currentItem?.presentationSize ?? .zero
        let b = s.bounds
        guard media.width > 0, media.height > 0 else { return s.convert(b, to: window) }
        let k = layer.videoGravity == .resizeAspectFill ? max(b.width / media.width, b.height / media.height)
                                                         : min(b.width / media.width, b.height / media.height)
        let w = media.width * k, h = media.height * k
        return s.convert(CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h), to: window)
    }

    /// The seeded drawing (a box from 0.3,0.3 to 0.7,0.6 of the frame) must
    /// land on exactly those pixels of the picture: captures with and without
    /// it, diffed along a row and a column through the box.
    private func drawingLands(_ v: ShareViewerViewController, _ name: String) async {
        let s = v.probeSurface
        let r = expectedVideoRect(s)
        let canvas = s.annotationCanvas.convert(s.annotationCanvas.bounds, to: window)
        // Nothing else may change between the captures: the play key, the
        // pill and (landscape) the floating controls stay out of both.
        let pill = s.drawingPill
        s.playButton.isHidden = true
        pill?.isHidden = true
        let controls = v.probeLandscapeControls
        let controlsAlpha = controls.alpha
        controls.alpha = 0
        await sleep(350)
        let with = bitmap()
        s.annotationCanvas.isHidden = true
        await sleep(250)
        let without = bitmap()
        s.annotationCanvas.isHidden = false
        s.playButton.isHidden = false
        pill?.isHidden = false
        controls.alpha = controlsAlpha
        let visible = r.intersection(s.convert(s.bounds, to: window)).intersection(window.bounds)
        let rowY = r.minY + r.height * 0.45, colX = r.minX + r.width * 0.5
        let row = diffRuns(without, with, from: CGPoint(x: visible.minX + 1, y: rowY), to: CGPoint(x: visible.maxX - 1, y: rowY))
            .map { visible.minX + 1 + $0 }
        let col = diffRuns(without, with, from: CGPoint(x: colX, y: visible.minY + 1), to: CGPoint(x: colX, y: visible.maxY - 1))
            .map { visible.minY + 1 + $0 }
        let want = (x: [r.minX + r.width * 0.3, r.minX + r.width * 0.7], y: [r.minY + r.height * 0.3, r.minY + r.height * 0.6])
        let tol: CGFloat = 2.5
        let ok = row.count == 2 && col.count == 2
            && zip(row, want.x).allSatisfy { abs($0 - $1) <= tol } && zip(col, want.y).allSatisfy { abs($0 - $1) <= tol }
            && abs(canvas.minX - r.minX) < 0.75 && abs(canvas.width - r.width) < 0.75 && abs(canvas.minY - r.minY) < 0.75 && abs(canvas.height - r.height) < 0.75
        let f = { (xs: [CGFloat]) in xs.map { String(format: "%.1f", $0) }.joined(separator: ",") }
        let gravity = (s.layer as! AVPlayerLayer).videoGravity == .resizeAspectFill ? "fill" : "fit"
        record("drawing-\(name)", ok,
               String(format: "%@ · picture %.1f,%.1f %.1f×%.1f (AVPlayerLayer.videoRect %@) · box edges x [%@] want [%@], y [%@] want [%@] (±%.1f pt) · canvas %.1f,%.1f %.1f×%.1f",
                      gravity, r.minX, r.minY, r.width, r.height, NSCoder.string(for: (s.layer as! AVPlayerLayer).videoRect),
                      f(row), f(want.x), f(col), f(want.y), tol, canvas.minX, canvas.minY, canvas.width, canvas.height))
    }

    /// Ask the script for a REAL simulator screenshot (video pixels included).
    private func shot(_ name: String) async {
        print("SHAREVIEWER await-shot \(name)")
        fflush(stdout)
        await sleep(2200)
    }

    private func rotate(landscape: Bool) async {
        guard let scene = window.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
        _ = await waitFor(4000) { scene.effectiveGeometry.interfaceOrientation.isLandscape == landscape }
        await sleep(900)
    }

    /// A drawing as the WEB's serializer takes it (raw, un-canonicalised).
    private func webShapes(_ shapes: [ShareAnnotationShape]) -> [[String: Any]] {
        shapes.map { shape -> [String: Any] in
            switch shape {
            case let .stroke(kind, color, size, points):
                return ["kind": kind.rawValue, "color": color, "size": size, "points": points.map { [Double($0.x), Double($0.y)] }]
            case let .box(kind, color, size, from, to):
                return ["kind": kind.rawValue, "color": color, "size": size, "from": [Double(from.x), Double(from.y)], "to": [Double(to.x), Double(to.y)]]
            case let .text(color, size, at, text):
                return ["kind": "text", "color": color, "size": size, "at": [Double(at.x), Double(at.y)], "text": text]
            }
        }
    }

    private func annotations() async {
        guard let v = await open("capturecat://share/svDraw01", universal: false) else {
            record("annotation-markers-x", false, "no viewer for svDraw01")
            return
        }
        _ = await waitReady(v)
        _ = await waitFor(3000) { v.model.commentsLoaded }
        await sleep(500)

        // 1. The owner's markers: ranges at the right x on the track, labels
        //    as pills + Summary rows, a pill seeks and plays, a tap inside a
        //    range snaps to its start.
        let timeline = v.probeTimeline
        let scrub = timeline.scrubber
        let duration = timeline.duration
        let markers = v.model.markers
        var errors: [String] = []
        for (range, marker) in zip(scrub.ranges, markers) {
            let frame = range.convert(range.bounds, to: timeline)
            let usable = scrub.bounds.width - scrub.trackInset * 2
            let left = scrub.frame.minX + scrub.trackInset + CGFloat(marker.start / duration) * usable
            let width = max(CGFloat((min(marker.end, duration) - marker.start) / duration) * usable, usable * 0.008)
            if abs(frame.minX - left) > 1 || abs(frame.width - width) > 1 {
                errors.append(String(format: "%.1f–%.1f s at x=%.1f w=%.1f, want x=%.1f w=%.1f", marker.start, marker.end, frame.minX, frame.width, left, width))
            }
        }
        let pills = v.probeMarkerPills.map(\.title)
        v.probeSurface.seek(to: 0)
        scrub.onScrub?(CGFloat(3.0 / duration), true)  // a tap (no drag) inside "Intro" (2–4 s)
        await sleep(300)
        let snapped = v.probeSurface.currentTime
        v.probeMarkerPills.first { $0.title.contains("Settings") }?.sendActions(for: .touchUpInside)
        await sleep(600)
        let pillTime = v.probeSurface.currentTime, pillPlaying = v.probeSurface.isPlaying
        v.probeSurface.pause()
        v.select(tab: .summary, animated: false)
        await sleep(300)
        let summary = v.probeSummaryText
        v.select(tab: .comments, animated: false)
        record("annotation-markers-x", scrub.ranges.count == 3 && errors.isEmpty && pills.count == 2
                   && pills[0].hasSuffix("Intro") && pills[1].hasSuffix("Settings")
                   && summary.contains("Intro") && summary.contains("Settings")
                   && abs(snapped - 2) < 0.1 && abs(pillTime - 7.5) < 0.6 && pillPlaying,
               "\(scrub.ranges.count) ranges on a \(Int(scrub.bounds.width)) pt track (\(errors.isEmpty ? "each on its moment ±1 pt, 0.8 % minimum" : errors.joined(separator: "; "))) · pills \(pills) · Summary \(summary) · tap at 0:03 → \(String(format: "%.2f", snapped)) s (snaps to 0:02) · Settings pill → \(String(format: "%.2f", pillTime)) s playing=\(pillPlaying)")

        // 2. A seeded drawing on the frame, on the picture's real pixels —
        //    portrait, then the full-width landscape player fit AND fill.
        guard let row = v.commentRows().first(where: { $0.comment.commentId == "d1" }), let show = row.drawingButton else {
            record("drawing-portrait", false, "no Drawing key on d1")
            await closeViewer()
            return
        }
        show.sendActions(for: .touchUpInside)
        _ = await waitFor(2000) { v.probeSurface.isShowingDrawing }
        await sleep(500)
        let pillText = v.probeSurface.drawingPill?.label.text ?? ""
        record("drawing-shown", v.shownComment?.commentId == "d1" && !v.probeSurface.isPlaying && abs(v.probeSurface.currentTime - 5) < 0.1
                   && pillText == "Riley Chen drew at 0:05",
               "Drawing → paused at \(String(format: "%.2f", v.probeSurface.currentTime)) s, pill \"\(pillText)\"")
        await drawingLands(v, "portrait")
        await shot("viewer-drawing-portrait")
        if UIDevice.current.userInterfaceIdiom == .phone {
            await rotate(landscape: true)
            if !v.probeSurface.isShowingDrawing { v.showComment(row.comment); await sleep(500) }
            await drawingLands(v, "landscape-fit")
            await shot("viewer-drawing-landscape")
            v.probeSurface.fillsWidth = true
            await sleep(700)
            await drawingLands(v, "landscape-fill")
            await shot("viewer-drawing-landscape-fill")
            // The finger's mapping in the cropped picture: a point drawn at
            // 25 % / 50 % of the frame IS 25 % / 50 % of the frame.
            v.startDrawing()
            await sleep(500)
            if let drawing = v.probeSurface.drawingSurface {
                let r = expectedVideoRect(v.probeSurface)
                let target = window.convert(CGPoint(x: r.minX + r.width * 0.25, y: r.minY + r.height * 0.5), to: drawing)
                let n = drawing.probeNormalized(target)
                record("drawing-touch-maps-to-frame", abs(n.x - 0.25) < 0.002 && abs(n.y - 0.5) < 0.002 && v.drawingToolbar?.window != nil,
                       String(format: "fill-cropped landscape: a touch at the picture's 25%%,50%% → %.4f,%.4f; toolbar docked=%@",
                              n.x, n.y, v.drawingToolbar?.window != nil ? "yes" : "no"))
                v.cancelDrawing()
            } else {
                record("drawing-touch-maps-to-frame", false, "Draw didn't open the drawing surface in landscape")
            }
            v.probeSurface.fillsWidth = false
            await rotate(landscape: false)
        }

        // 3. Draw while writing a comment → post → the web's exact bytes.
        v.probeSurface.seek(to: 8)
        await sleep(300)
        v.probeComposer.drawButton.sendActions(for: .touchUpInside)
        _ = await waitFor(2000) { v.isDrawing && v.probeSurface.drawingSurface != nil }
        await sleep(400)
        guard let drawing = v.probeSurface.drawingSurface, let toolbar = v.drawingToolbar, let editor = v.drawingEditor else {
            record("drawing-post-payload", false, "Draw opened nothing")
            await closeViewer()
            return
        }
        toolbar.toolButtons.first { $0.0 == .arrow }?.1.sendActions(for: .touchUpInside)
        drawing.probeDraw([CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.41234567, y: 0.6), CGPoint(x: 0.6, y: 0.35)])
        toolbar.toolButtons.first { $0.0 == .pen }?.1.sendActions(for: .touchUpInside)
        toolbar.swatches.first { $0.preset.name == "Blue" }?.sendActions(for: .touchUpInside)
        toolbar.sizeButton.sendActions(for: .touchUpInside)  // M → L
        drawing.probeDraw((0..<120).map { i in
            let t = Double(i) / 119
            return CGPoint(x: 0.15 + 0.5 * t, y: 0.3 + 0.1 * sin(t * .pi * 3) + 0.00002 * Double(i % 7))
        })
        toolbar.toolButtons.first { $0.0 == .rect }?.1.sendActions(for: .touchUpInside)
        drawing.probeDraw([CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.7001, y: 0.7)])  // an accidental tap: dropped
        toolbar.toolButtons.first { $0.0 == .text }?.1.sendActions(for: .touchUpInside)
        drawing.openLabel(at: CGPoint(x: 0.55, y: 0.18))
        drawing.labelField?.text = "  Fix \"this\"\nhere "
        drawing.commitLabel()
        toolbar.undoButton.sendActions(for: .touchUpInside)
        toolbar.redoButton.sendActions(for: .touchUpInside)
        await sleep(300)
        let marks = editor.shapes.count
        await shot("drawing-composer")
        snapshot("drawing-composer-gate.png")
        toolbar.doneButton.sendActions(for: .touchUpInside)
        await sleep(500)
        let draftPill = v.probeSurface.drawingPill?.label.text ?? ""
        let raw = editor.probeRawCommits
        try? JSONSerialization.data(withJSONObject: webShapes(raw)).write(to: out.appendingPathComponent("drawn-raw.json"))
        let composer = v.probeComposer
        _ = composer.field.becomeFirstResponder()
        composer.field.insertText("Look at this")
        composer.sendButton.sendActions(for: .touchUpInside)
        _ = await waitFor(4000) { v.model.comments.contains { $0.body == "Look at this" } }
        await sleep(600)
        let state = await viewerState()
        let post = state.log.last { ($0["route"] as? String) == "comments" && ($0["method"] as? String) == "POST" && ($0["videoId"] as? String) == "svDraw01" }
        let rawBody = post?["raw"] as? String ?? ""
        let expected = ShareAnnotationMath.serialize(raw).json ?? "-"
        let posted = v.model.comments.first { $0.body == "Look at this" }
        let bodyTime = (post?["body"] as? [String: Any])?["videoTime"] as? Double ?? -1
        record("drawing-post-payload", marks == 3 && raw.count == 3 && draftPill == "Your drawing · not posted yet"
                   && rawBody.hasPrefix("{\"annotation\":" + expected + ",") && abs(bodyTime - 8) < 0.3
                   && posted?.drawing?.count == 3 && v.shownComment?.commentId == posted?.commentId && v.draftShapes.isEmpty,
               "3 marks drawn (arrow, pen stroke, label; a stray tap dropped; undo + redo) at 0:08 · draft pill \"\(draftPill)\" · body starts with the serializer's bytes=\(rawBody.hasPrefix("{\"annotation\":" + expected + ",")) · posted drawing \(posted?.drawing?.count ?? 0) shapes, shown after posting=\(v.shownComment?.commentId == posted?.commentId) (the web serializer is compared by the script)")
        await shot("viewer-posted-drawing")
        await closeViewer()
    }

    /// The share-detail "Allow comments" switch: flips at once, lands, rolls
    /// back (with a toast) on a 500, and is disabled with the reason on a
    /// plan without comments.
    private func commentsSwitch() async {
        await LibraryStore.shared.refresh().value
        guard LibraryStore.shared.share("svToggle01") != nil, let root else {
            record("toggle-flips-and-rolls-back", false, "svToggle01 isn't in the library (signed in=\(SessionStore.load() != nil))")
            return
        }
        func present() async -> (UINavigationController, ShareDetailViewController) {
            let detail = ShareDetailViewController(videoID: "svToggle01", coordinator: nil)
            let nav = UINavigationController(rootViewController: detail)
            nav.setNavigationBarHidden(true, animated: false)
            nav.modalPresentationStyle = .fullScreen
            root.present(nav, animated: false)
            AppToaster.shared.attach(to: nav.view)
            _ = await waitFor(3000) { detail.planAllowsComments != nil }
            await sleep(500)
            return (nav, detail)
        }
        var (nav, detail) = await present()
        let toggle = detail.probeCommentsToggle
        let startOff = !toggle.isOn && !detail.probeOffNote.isHidden && detail.probeComposer.isHidden && toggle.isEnabled
        AppToaster.probeShown = []
        toggle.sendActions(for: .touchUpInside)
        let optimisticOn = toggle.isOn && LibraryStore.shared.share("svToggle01")?.commentsEnabled == true && !detail.probeComposer.isHidden
        _ = await waitFor(3000) { AppToaster.probeShown.contains("Comments on") }
        await sleep(300)
        let state = await viewerState()
        let landed = state.log.last { ($0["route"] as? String) == "comments-enabled" }
        let landedOK = (landed?["body"] as? [String: Any])?["commentsEnabled"] as? Bool == true
            && (landed?["authorization"] as? String)?.hasPrefix("Bearer ") == true && toggle.isOn
        await shot("share-detail-toggle")
        snapshot("share-detail-toggle-gate.png")
        _ = await mock("POST", "/__viewer-control", json: ["failCommentsToggle": 1])
        AppToaster.probeShown = []
        toggle.sendActions(for: .touchUpInside)
        let optimisticOff = !toggle.isOn && LibraryStore.shared.share("svToggle01")?.commentsEnabled == false && detail.probeComposer.isHidden
        _ = await waitFor(3000) { !AppToaster.probeShown.isEmpty }
        await sleep(500)
        let rolledBack = toggle.isOn && LibraryStore.shared.share("svToggle01")?.commentsEnabled == true && !detail.probeComposer.isHidden
            && AppToaster.probeShown == ["Couldn't turn comments off"]
        await shot("share-detail-toggle-rollback")
        record("toggle-flips-and-rolls-back", startOff && optimisticOn && landedOK && optimisticOff && rolledBack,
               "off at first=\(startOff) · tap → on at once=\(optimisticOn), PATCH {commentsEnabled: true} with the bearer=\(landedOK) · tap → off at once=\(optimisticOff), 500 → back on with toast \(AppToaster.probeShown)=\(rolledBack)")
        // Off again, then a plan without comments: on is out of reach, with the reason.
        toggle.sendActions(for: .touchUpInside)
        _ = await waitFor(3000) { LibraryStore.shared.share("svToggle01")?.commentsEnabled == false && toggle.isEnabled }
        nav.dismiss(animated: false)
        await sleep(300)
        _ = await mock("POST", "/__viewer-control", json: ["noCommentsPlan": 1])
        (nav, detail) = await present()
        let gated = !detail.probeCommentsToggle.isEnabled && !detail.probeCommentsToggle.isOn
            && (detail.probeCommentsToggle.detailText ?? "").contains("doesn't include viewer comments")
        record("toggle-plan-gate", gated, "plan without comments: switch disabled=\(!detail.probeCommentsToggle.isEnabled), says \"\(detail.probeCommentsToggle.detailText ?? "")\"")
        snapshot("share-detail-toggle-plan.png")
        _ = await mock("POST", "/__viewer-control", json: ["noCommentsPlan": 0])
        nav.dismiss(animated: false)
        AppToaster.shared.attach(to: root.view)
        await sleep(300)
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
