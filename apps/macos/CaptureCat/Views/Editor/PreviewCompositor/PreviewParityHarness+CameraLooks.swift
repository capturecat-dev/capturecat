import AppKit
import QuartzCore

/// `--preview-parity` section 10c — camera LOOKS on the real compositor, in
/// the same flipped hosting chain the editor uses (docs/camera-cutout.md §8).
///
/// Structural, never fingerprinted: a whole unmasked camera over the bubble
/// rect moves a mean or a coarse fingerprint by a few levels and passes, so
/// every assertion here is per-pixel against the silhouette the synthetic
/// mask defines analytically:
///   • settled cutout — opaque person INSIDE the silhouette (== the plain
///     bubble's pixels), TRANSPARENT outside it (== the camera-less frame);
///   • pop-out — person inside, card colour below the headroom, transparent
///     headroom beside the head, and the head itself above the card's top;
///   • a bubble → cutout cross-fade sampled tick by tick (mid-flight weights
///     on the rendered stacks, and a mid-fade pixel between both ends);
///   • a SELF-TEST that injects an unmasked look and requires the cutout
///     check to fail (CLAUDE.md §3: prove the gate can fail).
extension PreviewParityHarness {
    /// Normalized ellipse distance of the synthetic silhouette at a point in
    /// camera-image unit space (0…1, Y-down): < 1 inside.
    private static func silhouetteDistance(u: Double, v: Double) -> Double {
        let dx = (u - 0.5) / 0.28, dy = (v - 0.5) / 0.45
        return (dx * dx + dy * dy).squareRoot()
    }

    static func syntheticSilhouetteMask(aspect: Double) -> CameraMaskTrack? {
        let size = CameraMaskTrack.maskSize(cameraAspect: aspect)
        var alpha = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let d = silhouetteDistance(u: (Double(x) + 0.5) / Double(size.width),
                                           v: (Double(y) + 0.5) / Double(size.height))
                alpha[y * size.width + x] = UInt8((min(1, max(0, (1.04 - d) / 0.08)) * 255).rounded())
            }
        }
        guard let data = try? CameraMaskTrack.encode(
            width: size.width, height: size.height, keyframeInterval: 8,
            sourceDuration: 1, sourceByteSize: 1, frames: [(0, alpha)]) else { return nil }
        return try? CameraMaskTrack(data: data)
    }

    private struct Frame {
        let pixels: HarnessPixels.Pixels
        let image: CGImage
        /// Canvas (Y-down) → capture row.
        let flipped: Bool
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let row = flipped ? pixels.height - 1 - y : y
            guard x >= 0, x < pixels.width, row >= 0, row < pixels.height else { return nil }
            let p = pixels.bytes + row * pixels.bytesPerRow + x * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
    }

    private static func diff(_ a: (Int, Int, Int)?, _ b: (Int, Int, Int)?) -> Int {
        guard let a, let b else { return 255 }
        return max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    @MainActor
    static func cameraLookChecks(
        fixture: Fixture,
        compositor: PreviewCompositorView,
        container: NSView,
        t0: TimeInterval,
        artifacts: URL,
        reset: ((ProjectSettings) -> Void) -> Void
    ) async -> Int {
        var failures = 0
        func expect(_ name: String, _ ok: Bool, _ detail: String) {
            print("CAMERA-LOOK \(name) \(detail) \(ok ? "PASS" : "FAIL")")
            if !ok { failures += 1 }
        }
        guard let mask = syntheticSilhouetteMask(aspect: Double(fixture.cameraAspect)) else {
            expect("mask", false, "synthetic mask encode failed")
            return failures
        }
        let D = CameraLayoutMath.transitionDuration
        func cameraSettings(_ s: ProjectSettings) {
            s.showCamera = true
            s.cameraShape = .roundedRect
            s.cameraSize = 340
            s.cameraBorderWidth = 0
        }
        var flipped = true
        func capture(_ name: String, at time: TimeInterval = t0) async -> Frame? {
            fixture.currentTime = time
            compositor.schedule(compositorInput(fixture))
            await settle(0.3)
            compositor.schedule(compositorInput(fixture))
            await settle(0.3)
            guard let layer = container.layer,
                  let image = CARendererSnapshot.render(layer: layer, size: container.bounds.size, scale: 1),
                  let px = HarnessPixels.rgba(image) else { return nil }
            savePNG(image, artifacts.appendingPathComponent("look-\(name)-ca.png"))
            return Frame(pixels: px, image: image, flipped: flipped)
        }

        // ── Sequence FIRST (model values, before more captures) ──────────
        // bubble → cutout at `edge`, ticked at 30 Hz like playback.
        reset(cameraSettings)
        fixture.cameraMask = mask
        let edge = t0 + 0.2
        fixture.project.cameraLayoutRegions = [
            CameraLayoutRegion(startTime: edge, endTime: edge + 5, mode: .bubble, look: .cutout),
        ]
        var series: [(bubble: Float, cutout: Float, weight: Double)] = []
        var t = edge - 0.1
        while t < edge + D + 0.1 {
            fixture.currentTime = t
            compositor.schedule(compositorInput(fixture))
            await settle(0.02)
            let o = compositor.debugCameraStackOpacities()
            series.append((o.bubble, o.cutout, compositor.debugCameraLookWeights().cutout))
            t += 1.0 / 30
        }
        let midTicks = series.filter { $0.cutout > 0.02 && $0.cutout < 0.98 }.count
        let tracks = series.allSatisfy { abs(Double($0.cutout) - $0.weight) < 1e-4 && abs($0.bubble + $0.cutout - 1) < 1e-4 }
        let monotonic = zip(series, series.dropFirst()).allSatisfy { $0.cutout <= $1.cutout + 1e-6 }
        expect("crossfade-midflight",
               series.first.map { $0.bubble == 1 && $0.cutout == 0 } == true
                   && series.last.map { $0.cutout == 1 && $0.bubble == 0 } == true
                   && midTicks >= 6 && tracks && monotonic,
               "ticks=\(series.count) mid=\(midTicks) stacks track weights=\(tracks) monotonic=\(monotonic)")

        // ── Reference frames ─────────────────────────────────────────────
        fixture.project.cameraLayoutRegions = []
        reset { s in s.showCamera = false }
        guard let bare = await capture("bare") else {
            expect("capture", false, "bare frame capture failed")
            return failures
        }
        reset(cameraSettings)
        guard let bubble = await capture("bubble"), let rect = compositor.debugCameraRect() else {
            expect("capture", false, "bubble frame capture failed")
            return failures
        }
        // Which way up is the capture? Locate the bubble by diff and pick the
        // row mapping it agrees with (CARenderer reads Y-up; don't assume).
        var minRow = Int.max, maxRow = Int.min
        for row in 0..<bare.pixels.height {
            for x in stride(from: Int(rect.minX) + 4, to: Int(rect.maxX) - 4, by: 3) {
                let a = bare.pixels.bytes + row * bare.pixels.bytesPerRow + x * 4
                let b = bubble.pixels.bytes + row * bubble.pixels.bytesPerRow + x * 4
                if max(abs(Int(a[0]) - Int(b[0])), abs(Int(a[1]) - Int(b[1])), abs(Int(a[2]) - Int(b[2]))) > 40 {
                    minRow = min(minRow, row); maxRow = max(maxRow, row)
                }
            }
        }
        // The bubble's TOP edge is the reliable one (its lower rows can sit
        // on background that happens to match the poster's colours).
        let h = bare.pixels.height
        let flippedErr = abs((h - 1 - maxRow) - Int(rect.minY))
        let uprightErr = abs(minRow - Int(rect.minY))
        flipped = flippedErr <= uprightErr
        expect("capture-orientation", min(flippedErr, uprightErr) < 4,
               "bubble rows \(minRow)…\(maxRow) vs rect y \(Int(rect.minY))…\(Int(rect.maxY)) → flipped=\(flipped)")
        let bareF = Frame(pixels: bare.pixels, image: bare.image, flipped: flipped)
        let bubbleF = Frame(pixels: bubble.pixels, image: bubble.image, flipped: flipped)

        // Sample points inside B, classified by the ANALYTIC silhouette in
        // camera-image space (P = aspect-fill of the camera over B).
        let person = CameraCutoutMath.aspectFill(aspect: Double(fixture.cameraAspect), in: rect)
        struct Sample { let x: Int; let y: Int; let d: Double }
        var samples: [Sample] = []
        for y in stride(from: Int(rect.minY) + 3, to: Int(rect.maxY) - 3, by: 2) {
            for x in stride(from: Int(rect.minX) + 3, to: Int(rect.maxX) - 3, by: 2) {
                let u = (Double(x) + 0.5 - person.minX) / person.width
                let v = (Double(y) + 0.5 - person.minY) / person.height
                samples.append(Sample(x: x, y: y, d: silhouetteDistance(u: u, v: v)))
            }
        }
        let inside = samples.filter { $0.d < 0.85 }
        let outside = samples.filter { $0.d > 1.2 }

        /// Fraction of `points` where `frame` matches `reference` (≤ tol).
        func agreement(_ frame: Frame, _ reference: Frame, _ points: [Sample], tol: Int = 12) -> Double {
            guard !points.isEmpty else { return 0 }
            let ok = points.filter { diff(frame.rgb($0.x, $0.y), reference.rgb($0.x, $0.y)) <= tol }.count
            return Double(ok) / Double(points.count)
        }
        /// The settled-cutout structural predicate (also run on a defect).
        func cutoutHolds(_ frame: Frame) -> (ok: Bool, detail: String) {
            let opaque = agreement(frame, bubbleF, inside)
            let clear = agreement(frame, bareF, outside)
            let ok = inside.count >= 80 && outside.count >= 80 && opaque >= 0.97 && clear >= 0.97
            return (ok, String(format: "inside n=%d ==bubble %.3f · outside n=%d ==bare %.3f",
                               inside.count, opaque, outside.count, clear))
        }

        // ── Settled cutout ────────────────────────────────────────────────
        fixture.project.cameraLayoutRegions = [
            CameraLayoutRegion(startTime: t0 - 3, endTime: t0 + 3, mode: .bubble, look: .cutout),
        ]
        guard let cutoutRaw = await capture("cutout") else {
            expect("capture", false, "cutout capture failed")
            return failures
        }
        let cutout = Frame(pixels: cutoutRaw.pixels, image: cutoutRaw.image, flipped: flipped)
        expect("cutout-weights", compositor.debugCameraLookWeights() == .init(cutout: 1, popOut: 0)
                   && compositor.debugCameraStackOpacities() == (0, 1, 0),
               "settled cutout draws only the cutout stack")
        let held = cutoutHolds(cutout)
        expect("cutout-silhouette", held.ok, held.detail)

        // SELF-TEST: an unmasked look must trip the same predicate.
        PreviewCompositorView.debugUnmaskedLooks = true
        if let defectRaw = await capture("cutout-defect") {
            let tripped = cutoutHolds(Frame(pixels: defectRaw.pixels, image: defectRaw.image, flipped: flipped))
            expect("selftest-unmasked-defect-fails", !tripped.ok, "injected unmasked look → \(tripped.detail)")
        } else {
            expect("selftest-unmasked-defect-fails", false, "capture failed")
        }
        PreviewCompositorView.debugUnmaskedLooks = false

        // ── Mid-fade pixel: between the bubble and the cutout ─────────────
        fixture.project.cameraLayoutRegions = [
            CameraLayoutRegion(startTime: edge, endTime: edge + 5, mode: .bubble, look: .cutout),
        ]
        if let midRaw = await capture("crossfade-mid", at: edge + D / 2) {
            let mid = Frame(pixels: midRaw.pixels, image: midRaw.image, flipped: flipped)
            let w = compositor.debugCameraLookWeights().cutout
            // A TRUE cross-dissolve (contract §5) over the same screen is
            // exactly the per-pixel lerp of the two settled frames:
            // (1−w)·F_bubble + w·F_cutout. A source-over stack would let the
            // screen through where both stacks are opaque — measured too, so
            // the check provably discriminates.
            func lerp(_ a: (Int, Int, Int)?, _ b: (Int, Int, Int)?) -> (Int, Int, Int)? {
                guard let a, let b else { return nil }
                func l(_ x: Int, _ y: Int) -> Int { Int((Double(x) * (1 - w) + Double(y) * w).rounded()) }
                return (l(a.0, b.0), l(a.1, b.1), l(a.2, b.2))
            }
            let all = inside + outside
            let dissolve = all.filter {
                diff(mid.rgb($0.x, $0.y), lerp(bubbleF.rgb($0.x, $0.y), cutout.rgb($0.x, $0.y))) <= 6
            }.count
            let frac = all.isEmpty ? 0 : Double(dissolve) / Double(all.count)
            // What source-over would give inside (both opaque): the screen
            // shows through by w(1−w) — how far that sits from the dissolve.
            let overGap = inside.map { p -> Int in
                guard let s = bareF.rgb(p.x, p.y), let b = bubbleF.rgb(p.x, p.y) else { return 0 }
                return Int((w * (1 - w) * Double(max(abs(s.0 - b.0), abs(s.1 - b.1), abs(s.2 - b.2)))).rounded())
            }.filter { $0 > 6 }.count
            expect("crossfade-true-dissolve", w > 0.05 && w < 0.95 && frac >= 0.95,
                   String(format: "w=%.3f px == lerp(bubble, cutout): %.3f of %d (source-over would miss %d inside px)",
                          w, frac, all.count, overGap))
        } else {
            expect("crossfade-true-dissolve", false, "capture failed")
        }

        // ── Settled pop-out card ─────────────────────────────────────────
        fixture.project.cameraLayoutRegions = [
            CameraLayoutRegion(startTime: t0 - 3, endTime: t0 + 3, mode: .bubble, look: .popOut),
        ]
        if let popRaw = await capture("popout") {
            let pop = Frame(pixels: popRaw.pixels, image: popRaw.image, flipped: flipped)
            let g = CameraCutoutMath.geometry(look: .popOut, bubbleRect: rect, cameraAspect: Double(fixture.cameraAspect))
            let card = g.cardRect ?? rect
            let r = g.cardCornerRadius
            let personPts = inside
            // Beside the head, clear of the card's shadow (radius 6 × size
            // factor reaches ~2 radii above the card's top edge).
            let shadowReach = Double(CameraCutoutMath.cardShadowRadius) * 2.5 + 3
            let headroomClear = outside.filter { Double($0.y) < Double(card.minY) - shadowReach }
            let cardFill = outside.filter {
                card.insetBy(dx: r + 2, dy: 3).contains(CGPoint(x: CGFloat($0.x) + 0.5, y: CGFloat($0.y) + 0.5))
                    && CGFloat($0.y) > card.minY + r
            }
            let head = inside.filter { Double($0.y) < Double(card.minY) - 2 }
            let personOK = agreement(pop, bubbleF, personPts)
            let clearOK = agreement(pop, bareF, headroomClear)
            let cardOK = cardFill.isEmpty ? 0 : Double(cardFill.filter {
                diff(pop.rgb($0.x, $0.y), bareF.rgb($0.x, $0.y)) > 25
            }.count) / Double(cardFill.count)
            let headOK = agreement(pop, bubbleF, head)
            expect("popout-weights", compositor.debugCameraStackOpacities() == (0, 0, 1), "settled pop-out draws only the card stack")
            expect("popout-person", personOK >= 0.97, String(format: "person n=%d ==bubble %.3f", personPts.count, personOK))
            expect("popout-headroom-clear", headroomClear.count >= 20 && clearOK >= 0.97,
                   String(format: "headroom beside the head n=%d ==bare %.3f", headroomClear.count, clearOK))
            expect("popout-card-fill", cardFill.count >= 40 && cardOK >= 0.97,
                   String(format: "card behind the person n=%d covered %.3f", cardFill.count, cardOK))
            expect("popout-head-rises", head.count >= 10 && headOK >= 0.95,
                   String(format: "head above the card n=%d drawn %.3f", head.count, headOK))
            // Gradient orientation: warm at the card's TOP, violet at its
            // bottom (beside the person, clear of the corners).
            let gx = Int(card.minX + r + 2)
            if let topPx = pop.rgb(gx, Int(card.minY + r + 2)), let bottomPx = pop.rgb(gx, Int(card.maxY - r - 2)) {
                expect("popout-gradient-orientation", topPx.0 > topPx.2 + 60 && bottomPx.2 > bottomPx.0 + 60,
                       "top rgb \(topPx) bottom rgb \(bottomPx)")
            } else {
                expect("popout-gradient-orientation", false, "sample out of frame")
            }
        } else {
            expect("popout", false, "capture failed")
        }

        fixture.project.cameraLayoutRegions = []
        fixture.cameraMask = nil
        reset { _ in }
        return failures
    }
}
