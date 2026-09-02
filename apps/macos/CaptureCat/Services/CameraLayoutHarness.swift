import Foundation
import CoreGraphics

/// `--cameralayout-test` — acceptance gate for CameraLayoutMath, the single
/// source of truth both render paths consume.
///
/// Asserts the failure modes that would ship as preview↔export drift, holes,
/// or a "transition" that is really a cut:
///   • mode resolution (inside/outside/edges, bubble default)
///   • cameraOnly covers the card EXACTLY once settled
///   • side-by-side columns: screen shrinks, camera fills the other column
///   • MID-FLIGHT assertions — the morph is sampled between its endpoints and
///     required to be strictly between them (CLAUDE.md §3: a settled-frame
///     matrix passes while every animation snaps)
///   • scale-invariance: the preview↔export contract
///   • camera-less degradation, Codable round-trip + legacy decode
/// Never reached in a normal launch.
enum CameraLayoutHarness {
    static func run() -> Never {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }

        // Card and bubble in a plausible 1920×1080 export space.
        let card = CGRect(x: 137, y: 82, width: 1646, height: 926)
        let bubble = CGRect(x: 1500, y: 120, width: 240, height: 240)
        let bubbleRadius: CGFloat = 120
        let cardRadius: CGFloat = 24

        func resolve(_ t: TimeInterval, _ regions: [CameraLayoutRegion],
                     hasCamera: Bool = true,
                     card: CGRect = card) -> CameraLayoutMath.Resolved {
            CameraLayoutMath.resolve(
                at: t, regions: regions, videoRect: card, bubbleRect: bubble,
                bubbleCornerRadius: bubbleRadius, cardCornerRadius: cardRadius,
                hasCamera: hasCamera
            )
        }

        let D = CameraLayoutMath.transitionDuration
        let regions = [
            CameraLayoutRegion(startTime: 2, endTime: 6, mode: .cameraOnly),
            CameraLayoutRegion(startTime: 9, endTime: 11, mode: .screenOnly),
        ]

        // ── Mode resolution ────────────────────────────────────────────────
        expect(CameraLayoutMath.mode(at: 0, regions: regions) == .bubble, "outside → bubble")
        expect(CameraLayoutMath.mode(at: 3, regions: regions) == .cameraOnly, "inside → cameraOnly")
        expect(CameraLayoutMath.mode(at: 2, regions: regions) == .cameraOnly, "start edge inclusive")
        expect(CameraLayoutMath.mode(at: 6, regions: regions) == .cameraOnly, "end edge inclusive")
        expect(CameraLayoutMath.mode(at: 7.5, regions: regions) == .bubble, "gap → bubble")

        // ── Settled endpoints ──────────────────────────────────────────────
        let atBubble = resolve(0, regions)
        expect(atBubble.isPlainBubble, "t=0 is the untouched bubble fast path")
        expect(atBubble.cameraRect == bubble, "bubble rect passes through")
        expect(atBubble.cardScale == 1 && atBubble.cardTranslationX == 0, "bubble leaves the card alone")

        // Settled cameraOnly: D after the start edge.
        let settledFull = resolve(2 + D + 0.01, regions)
        expect(settledFull.cameraRect == card, "settled cameraOnly covers the card exactly")
        expect(settledFull.chromeOpacity < 0.001, "settled cameraOnly drops bubble chrome")
        expect(abs(settledFull.cameraCornerRadius - cardRadius) < 0.001, "settled cameraOnly uses card radius")
        expect(settledFull.cardScale == 1, "cameraOnly does not squeeze the card")

        // Settled screenOnly.
        let settledHidden = resolve(9 + D + 0.01, regions)
        expect(settledHidden.cameraOpacity < 0.001, "settled screenOnly hides the camera")

        // ── MID-FLIGHT: the morph must actually be mid-morph ───────────────
        // A pure cut would sit on an endpoint at every sample.
        let mid = resolve(2 + D / 2, regions)
        if let r = mid.cameraRect {
            let grewFromBubble = r.width > bubble.width + 1 && r.width < card.width - 1
            expect(grewFromBubble, "mid-flight camera width is BETWEEN bubble and card (\(Int(r.width)))")
            expect(r.minX < bubble.minX - 1, "mid-flight camera has travelled toward the card")
            expect(mid.chromeOpacity > 0.01 && mid.chromeOpacity < 0.99,
                   "mid-flight chrome is partly faded (\(String(format: "%.2f", mid.chromeOpacity)))")
            expect(!mid.isPlainBubble, "mid-flight is never the bubble fast path")
            let radiusBetween = mid.cameraCornerRadius < bubbleRadius - 0.5
                && mid.cameraCornerRadius > cardRadius + 0.5
            expect(radiusBetween, "mid-flight corner radius is between bubble and card")
        } else {
            expect(false, "mid-flight resolved no rect")
        }

        // Monotonic growth across the morph — no stalls, no overshoot past the
        // endpoints, and the eased curve must move at every step.
        var widths: [CGFloat] = []
        for i in 0...10 {
            let t = 2 + D * Double(i) / 10
            widths.append(resolve(t, regions).cameraRect?.width ?? 0)
        }
        let monotonic = zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 + 0.001 }
        expect(monotonic, "camera width grows monotonically through the morph")
        expect(widths.first! < widths.last!, "morph makes net progress")
        expect(abs(widths.last! - card.width) < 1.0, "morph lands exactly on the card")
        // Smootherstep: the middle third must cover more ground than the first.
        let firstThird = widths[3] - widths[0]
        let middleThird = widths[7] - widths[4]
        expect(middleThird > firstThird, "eased (not linear) — middle moves fastest")

        // ── Region starting at t=0: NO intro morph ────────────────────────
        // "Open on this arrangement": the very first frame is the settled
        // state, never a bubble easing in. (Shipped bug: a talking-head
        // intro block at 0:00 showed a bubble on frame one.)
        let introRegions = [CameraLayoutRegion(startTime: 0, endTime: 3, mode: .cameraOnly)]
        let frameOne = resolve(0, introRegions)
        expect(frameOne.cameraRect == card, "block at t=0: frame one is already full-screen")
        expect(frameOne.chromeOpacity < 0.001, "block at t=0: frame one has no bubble chrome")
        // …but its EXIT still morphs.
        let exitMid = resolve(3 + D / 2, introRegions)
        if let r = exitMid.cameraRect {
            expect(r.width < card.width - 1 && r.width > bubble.width + 1,
                   "block at t=0: exit still morphs back to the bubble")
        } else {
            expect(false, "exit morph resolved no rect")
        }

        // ── Morph starts from the user's ACTUAL bubble shape ───────────────
        // A circle bubble must morph from a circle silhouette (radius = half
        // the short side), not from the rounded-rect custom radius.
        let circleRadius = CameraLayoutMath.bubbleApproxCornerRadius(
            shape: .circle, customRadius: 12, size: CGSize(width: 240, height: 240))
        expect(abs(circleRadius - 120) < 0.001, "circle bubble → radius is half the side (exact circle)")
        expect(CameraLayoutMath.bubbleApproxCornerRadius(
            shape: .square, customRadius: 12, size: CGSize(width: 240, height: 240)) == 0,
            "square bubble → hard corners")
        expect(CameraLayoutMath.bubbleApproxCornerRadius(
            shape: .roundedRect, customRadius: 12, size: CGSize(width: 240, height: 240)) == 12,
            "rounded-rect bubble → the user's own radius")

        // ── Side by side ───────────────────────────────────────────────────
        let sbs = [CameraLayoutRegion(startTime: 0, endTime: 10, mode: .sideBySide)]
        let split = resolve(5, sbs)
        let cols = CameraLayoutMath.columns(in: card)
        if let r = split.cameraRect {
            expect(abs(r.maxX - card.maxX) < 0.001, "side-by-side camera flush with trailing edge")
            expect(abs(r.width - cols.camera.width) < 0.001, "side-by-side camera fills its tile")
            // Two-tile row: EQUAL heights, both centred on the card's midline
            // — not a full-height camera tower next to a floating card (the
            // rejected first composition).
            expect(abs(r.height - cols.screen.height) < 0.001, "side-by-side tiles share one height")
            expect(abs(r.midY - card.midY) < 0.001, "side-by-side camera centred vertically")
            // The screen must SHRINK, not be covered — the bug in the first cut.
            expect(split.cardScale < 0.999, "side-by-side shrinks the card (\(String(format: "%.3f", split.cardScale)))")
            expect(split.cardTranslationX < -1, "side-by-side moves the card leading-ward")
            let squeezed = card.applying(
                CameraLayoutMath.cardTransform(split, videoRect: card))
            expect(abs(squeezed.width - cols.screen.width) < 0.5, "squeezed card == screen tile width")
            expect(abs(squeezed.height - cols.screen.height) < 0.5,
                   "squeezed card height == tile height (aspect preserved, no floating gap)")
            expect(squeezed.maxX <= r.minX + 0.5, "squeezed card does not overlap the camera tile")
            expect(abs(squeezed.midY - card.midY) < 0.001, "squeeze never moves the card vertically")
        } else {
            expect(false, "side-by-side resolved no rect")
        }

        // ── Scale invariance: THE preview↔export contract ──────────────────
        // Preview works in canvas points, the exporter in output pixels. The
        // same instant must resolve to the same arrangement up to scale.
        let k: CGFloat = 3.2
        func scaled(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
        }
        for (label, t, regs) in [("settled", 5.0, sbs), ("mid-morph", 2 + D / 2, regions)] {
            let a = resolve(t, regs)
            let b = CameraLayoutMath.resolve(
                at: t, regions: regs, videoRect: scaled(card), bubbleRect: scaled(bubble),
                bubbleCornerRadius: bubbleRadius * k, cardCornerRadius: cardRadius * k,
                hasCamera: true
            )
            guard let ra = a.cameraRect, let rb = b.cameraRect else {
                expect(false, "scale-invariance \(label): missing rect"); continue
            }
            let rectOK = abs(rb.minX - ra.minX * k) < 0.01 && abs(rb.width - ra.width * k) < 0.01
                && abs(rb.height - ra.height * k) < 0.01
            expect(rectOK, "scale-invariant camera rect (\(label))")
            expect(abs(b.cardScale - a.cardScale) < 0.0001, "scale-invariant card scale (\(label))")
            expect(abs(b.cardTranslationX - a.cardTranslationX * k) < 0.01,
                   "scale-invariant card translation (\(label))")
            expect(abs(b.cameraCornerRadius - a.cameraCornerRadius * k) < 0.01,
                   "scale-invariant corner radius (\(label))")
        }

        // ── Degradation + persistence ──────────────────────────────────────
        for t in [0.0, 3.0, 9.0] {
            let r = resolve(t, regions, hasCamera: false)
            expect(r.cameraRect == nil && r.cameraOpacity < 0.001, "no camera → nothing drawn at t=\(t)")
            expect(r.cardScale == 1, "no camera → card untouched at t=\(t)")
        }
        expect(resolve(0, []).isPlainBubble, "no regions → untouched bubble")

        expect(CameraLayoutMath.boundaries(
            [CameraLayoutRegion(startTime: 0, endTime: 3, mode: .cameraOnly)], duration: 10) == [3],
            "boundary at t=0 dropped, interior kept")

        do {
            let encoded = try JSONEncoder().encode(regions)
            expect(try JSONDecoder().decode([CameraLayoutRegion].self, from: encoded) == regions,
                   "codable round-trip")
            let legacy = try JSONDecoder().decode(CameraLayoutRegion.self, from: Data("{}".utf8))
            expect(legacy.mode == .cameraOnly, "legacy decode falls back to defaults")
        } catch {
            expect(false, "codable threw: \(error)")
        }

        print(failures == 0 ? "CAMERALAYOUT-TEST OK" : "CAMERALAYOUT-TEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
