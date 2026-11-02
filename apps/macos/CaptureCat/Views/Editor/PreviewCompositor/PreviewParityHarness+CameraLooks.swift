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

        // ── Whole-video look (the Camera panel's Background) ──────────────
        // settings.cameraLook with NO timeline block at all must be the same
        // settled cutout, pixel for pixel — the panel never adds a region.
        fixture.project.cameraLayoutRegions = []
        fixture.project.settings.cameraLook = .cutout
        if let wholeRaw = await capture("whole-video-cutout") {
            let whole = Frame(pixels: wholeRaw.pixels, image: wholeRaw.image, flipped: flipped)
            let weights = compositor.debugCameraLookWeights()
            let holds = cutoutHolds(whole)
            let same = agreement(whole, cutout, inside + outside, tol: 2)
            expect("whole-video-cutout",
                   weights == .init(cutout: 1, popOut: 0) && holds.ok && same >= 0.99,
                   String(format: "no regions · weights (%.2f, %.2f) · %@ · == region cutout %.3f",
                          weights.cutout, weights.popOut, holds.detail, same))
        } else {
            expect("whole-video-cutout", false, "capture failed")
        }
        fixture.project.settings.cameraLook = nil

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

        // ── Camera styles (docs/camera-cutout.md §12.10) ─────────────────
        // Structural, each against the frame the defect would produce.
        let aspect = Double(fixture.cameraAspect)
        func styled(_ name: String, _ look: CameraBubbleLook, _ mutate: @escaping (ProjectSettings) -> Void) async -> Frame? {
            fixture.project.cameraLayoutRegions = [
                CameraLayoutRegion(startTime: t0 - 3, endTime: t0 + 3, mode: .bubble, look: look),
            ]
            reset { s in cameraSettings(s); mutate(s) }
            guard let raw = await capture(name) else { return nil }
            return Frame(pixels: raw.pixels, image: raw.image, flipped: flipped)
        }
        func covered(_ frame: Frame, _ points: [Sample], tol: Int = 25) -> Double {
            guard !points.isEmpty else { return 0 }
            return Double(points.filter { diff(frame.rgb($0.x, $0.y), bareF.rgb($0.x, $0.y)) > tol }.count)
                / Double(points.count)
        }
        func point(_ p: Sample) -> CGPoint { CGPoint(x: CGFloat(p.x) + 0.5, y: CGFloat(p.y) + 0.5) }
        let defaultCard = CameraCutoutMath.geometry(look: .popOut, bubbleRect: rect, cameraAspect: aspect).cardRect ?? rect
        let shadowReach = CGFloat(CameraCutoutMath.cardShadowRadius) * 2.5 + 3
        let cornerR = CameraCutoutMath.cardCornerFraction * min(rect.width, rect.height)

        // Pop-out amount: scan a column beside the head (u = 0.15, clear of
        // the silhouette and the card's top corners) for the card's top edge.
        // 0 → B's top, default → 0.22·h, 1 → 0.44·h. A dropped amount puts
        // all three on the same row.
        let defaultPop = await styled("style-amount-default", .popOut) { _ in }
        func cardTop(_ frame: Frame) -> CGFloat? {
            let x = Int(rect.minX + rect.width * 0.15)
            for y in Int(rect.minY)..<Int(rect.maxY) where diff(frame.rgb(x, y), bareF.rgb(x, y)) > 25 {
                return CGFloat(y)
            }
            return nil
        }
        if let defaultPop, let zero = await styled("style-amount-0", .popOut, { $0.cameraPopOutAmount = 0 }),
           let one = await styled("style-amount-1", .popOut, { $0.cameraPopOutAmount = 1 }),
           let y0 = cardTop(zero), let yd = cardTop(defaultPop), let y1 = cardTop(one) {
            func near(_ y: CGFloat, _ fraction: CGFloat) -> Bool {
                let want = rect.minY + fraction * rect.height
                return y >= want - 10 && y <= want + 3   // the card shadow reaches a few px above
            }
            expect("style-popout-amount", near(y0, 0) && near(yd, 0.22) && near(y1, 0.44) && y0 < yd && yd < y1,
                   String(format: "card top y: amount 0 → %.0f, default → %.0f, 1 → %.0f (B %.0f…%.0f)",
                          y0, yd, y1, rect.minY, rect.maxY))
        } else {
            expect("style-popout-amount", false, "capture failed or no card edge found")
        }

        // Camera fill: inside the card the camera's OWN background (== the
        // plain bubble), the head still alone above it. Defect: the gradient.
        let cardBehind = outside.filter {
            defaultCard.insetBy(dx: cornerR + 2, dy: 3).contains(point($0)) && CGFloat($0.y) > defaultCard.minY + cornerR
        }
        let headroomClear = outside.filter { CGFloat($0.y) < defaultCard.minY - shadowReach }
        if let cam = await styled("style-camera-fill", .popOut, { $0.cameraCardFill = .camera }), let defaultPop {
            let real = agreement(cam, bubbleF, cardBehind), defect = agreement(defaultPop, bubbleF, cardBehind)
            let clear = agreement(cam, bareF, headroomClear), personOK = agreement(cam, bubbleF, inside)
            expect("style-camera-fill", cardBehind.count >= 40 && real >= 0.95 && defect <= 0.2
                   && clear >= 0.97 && personOK >= 0.97,
                   String(format: "card == camera bg %.3f (gradient defect %.3f, n=%d) · headroom clear %.3f · person %.3f",
                          real, defect, cardBehind.count, clear, personOK))
        } else {
            expect("style-camera-fill", false, "capture failed")
        }

        // Background blur: a striped poster's edges inside the card wash out
        // at blur 1 (the person stays sharp). Defect: blur 0.
        let smoothPoster = fixture.cameraPoster
        fixture.cameraPoster = Self.stripedPoster(size: CGSize(width: 400, height: 300))
        func energy(_ frame: Frame) -> Double {
            var total = 0, n = 0
            for p in cardBehind {
                guard let a = frame.rgb(p.x, p.y), let b = frame.rgb(p.x + 1, p.y) else { continue }
                total += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2); n += 1
            }
            return n > 0 ? Double(total) / Double(n) : 0
        }
        if let sharp = await styled("style-blur-0", .popOut, { $0.cameraCardFill = .camera }),
           let soft = await styled("style-blur-1", .popOut, { $0.cameraCardFill = .camera; $0.cameraBackgroundBlur = 1 }) {
            let e0 = energy(sharp), e1 = energy(soft)
            expect("style-background-blur", e0 > 12 && e1 < e0 * 0.35,
                   String(format: "edge energy inside the card %.1f → %.1f at blur 1", e0, e1))
        } else {
            expect("style-background-blur", false, "capture failed")
        }
        fixture.cameraPoster = smoothPoster

        // Border ring: gold along the card's left edge at mid-height (the
        // gradient card there is a warm/violet mix). Defect: no border.
        let ringG = CameraCutoutMath.geometry(look: .popOut, bubbleRect: rect, cameraAspect: aspect, cardBorderWidth: 1)
        let ringW = ringG.cardBorderWidth
        let ringPts: [(Int, Int)] = stride(from: Int(defaultCard.midY) - 10, through: Int(defaultCard.midY) + 10, by: 4).map {
            (Int(defaultCard.minX + ringW / 2), $0)
        }
        func goldness(_ frame: Frame) -> Double {
            Double(ringPts.filter { p in
                guard let c = frame.rgb(p.0, p.1) else { return false }
                return c.0 > c.2 + 80 && c.1 > c.2 + 40
            }.count) / Double(max(1, ringPts.count))
        }
        if let gold = await styled("style-border-gold", .popOut, { $0.cameraCardBorder = .gold; $0.cameraCardBorderWidth = 1 }),
           let defaultPop {
            let g = goldness(gold), d = goldness(defaultPop)
            expect("style-border-ring", ringW >= 6 && g >= 0.9 && d <= 0.1,
                   String(format: "ring w=%.1f gold %.2f (no-border defect %.2f)", ringW, g, d))
        } else {
            expect("style-border-ring", false, "capture failed")
        }

        // Edge inset / softness on the cutout. The band just inside the
        // silhouette edge goes clear with inset 1; the band just outside
        // picks up coverage with softness 1. Defect: the plain cutout.
        let innerEdge = samples.filter { $0.d > 0.965 && $0.d < 0.995 }
        // Only where the camera contrasts with what is behind it — elsewhere
        // coverage is invisible whatever the mask says.
        let outerEdge = samples.filter {
            $0.d > 1.05 && $0.d < 1.08 && diff(bubbleF.rgb($0.x, $0.y), bareF.rgb($0.x, $0.y)) > 40
        }
        if let plain = await styled("style-edge-plain", .cutout, { _ in }),
           let inset = await styled("style-edge-inset", .cutout, { $0.cameraEdgeInset = 1 }),
           let soft = await styled("style-edge-soft", .cutout, { $0.cameraEdgeSoftness = 1 }) {
            let insetClear = agreement(inset, bareF, innerEdge, tol: 8)
            let plainClear = agreement(plain, bareF, innerEdge, tol: 8)
            /// Fraction of the band where the person shows at ≥ 5 % —
            /// (frame − bare) over (camera − bare), so weak contrast counts.
            func coverage(_ frame: Frame) -> Double {
                guard !outerEdge.isEmpty else { return 0 }
                return Double(outerEdge.filter {
                    Double(diff(frame.rgb($0.x, $0.y), bareF.rgb($0.x, $0.y)))
                        >= 0.05 * Double(diff(bubbleF.rgb($0.x, $0.y), bareF.rgb($0.x, $0.y)))
                }.count) / Double(outerEdge.count)
            }
            let softCover = coverage(soft)
            let plainCover = coverage(plain)
            expect("style-edge-inset", innerEdge.count >= 30 && insetClear >= 0.9 && plainClear <= 0.2,
                   String(format: "inner edge band clear %.3f (plain %.3f, n=%d)", insetClear, plainClear, innerEdge.count))
            expect("style-edge-softness", outerEdge.count >= 30 && softCover >= 0.8 && plainCover <= 0.05,
                   String(format: "outer edge band covered %.3f (plain %.3f, n=%d)", softCover, plainCover, outerEdge.count))
        } else {
            expect("style-edge", false, "capture failed")
        }

        // Side by Side, camera on the left: the camera tile lands left of the
        // card's centre (trailing, its defect, lands right).
        func sideRect(_ side: CameraSide?) async -> CGRect? {
            fixture.project.cameraLayoutRegions = [
                CameraLayoutRegion(startTime: t0 - 3, endTime: t0 + 3, mode: .sideBySide, cameraSide: side),
            ]
            reset(cameraSettings)
            _ = await capture("style-side-\(side?.rawValue ?? "default")")
            return compositor.debugCameraRect()
        }
        if let left = await sideRect(.leading), let right = await sideRect(nil) {
            let mid = container.bounds.midX
            expect("style-camera-side", left.midX < mid && right.midX > mid && abs(left.width - right.width) < 0.5,
                   String(format: "leading tile midX %.1f · trailing %.1f · canvas mid %.1f", left.midX, right.midX, mid))
        } else {
            expect("style-camera-side", false, "capture failed")
        }

        // ── Full-height split + riders (docs/camera-cutout.md §12.11) ─────
        // Reference: the tiles split, where the band above the tile row is
        // background. In the full split the screen and camera columns fill
        // that band and the gutter between them stays background — the
        // unclipped card (the defect) would cover the gutter.
        func splitFrame(_ name: String, _ style: CameraSplitStyle?) async -> Frame? {
            fixture.project.cameraLayoutRegions = [
                CameraLayoutRegion(startTime: t0 - 3, endTime: t0 + 3, mode: .sideBySide, splitStyle: style),
            ]
            reset(cameraSettings)
            guard let raw = await capture(name) else { return nil }
            return Frame(pixels: raw.pixels, image: raw.image, flipped: flipped)
        }
        let plainHotspot: CGPoint? = await {
            fixture.project.cameraLayoutRegions = []
            reset(cameraSettings)
            _ = await capture("split-riders-plain")
            return compositor.debugCursorHotspot()
        }()
        if let tiles = await splitFrame("split-tiles", nil) {
            let tilesLayout = compositor.debugCameraLayout()
            let tilesHotspot = compositor.debugCursorHotspot()
            if let full = await splitFrame("split-full", .full), let card = compositor.debugVideoRect(),
               let clip = compositor.debugCameraLayout().cardClip, let cam = compositor.debugCameraRect() {
                let bandTop = Int(card.minY + 4), bandBottom = Int(card.minY + card.height * 0.18)
                func band(_ x0: CGFloat, _ x1: CGFloat) -> [Sample] {
                    stride(from: bandTop, through: bandBottom, by: 2).flatMap { y in
                        stride(from: Int(x0), through: Int(x1), by: 2).map { Sample(x: $0, y: y, d: 0) }
                    }
                }
                let screenBand = band(clip.minX + clip.width * 0.3, clip.maxX - clip.width * 0.3)
                let cameraBand = band(cam.minX + cam.width * 0.3, cam.maxX - cam.width * 0.3)
                let gutterBand = band(clip.maxX + 1, cam.minX - 1)
                func differs(_ points: [Sample]) -> Double {
                    guard !points.isEmpty else { return 0 }
                    return Double(points.filter { diff(full.rgb($0.x, $0.y), tiles.rgb($0.x, $0.y)) > 25 }.count)
                        / Double(points.count)
                }
                let screenFill = differs(screenBand), cameraFill = differs(cameraBand)
                /// Gutter pixels showing screen content rather than background
                /// (the tiles' drop shadows only darken it a little).
                func leaked(_ frame: Frame) -> Double {
                    guard !gutterBand.isEmpty else { return 1 }
                    return Double(gutterBand.filter { diff(frame.rgb($0.x, $0.y), tiles.rgb($0.x, $0.y)) > 60 }.count)
                        / Double(gutterBand.count)
                }
                let gutterLeak = leaked(full)
                let maskOK = compositor.debugLayoutClipPath() != nil
                expect("split-full-columns", screenBand.count >= 20 && cameraBand.count >= 20 && gutterBand.count >= 4
                       && screenFill >= 0.97 && cameraFill >= 0.97 && gutterLeak <= 0.03 && maskOK
                       && abs(cam.height - card.height) < 1 && abs(clip.height - card.height) < 1,
                       String(format: "screen column fills the top band %.3f · camera %.3f · screen in the gutter %.3f (n=%d) · mask=%@ · heights %.0f/%.0f/%.0f",
                              screenFill, cameraFill, gutterLeak, gutterBand.count, maskOK ? "on" : "off",
                              clip.height, cam.height, card.height))
                // Self-test: with the clip skipped the card spills into the
                // gutter, and the predicate must say so.
                PreviewCompositorView.debugDisableLayoutClip = true
                if let raw = await capture("split-full-unclipped-defect") {
                    let leak = leaked(Frame(pixels: raw.pixels, image: raw.image, flipped: flipped))
                    expect("selftest-split-unclipped-defect-fails", leak >= 0.5,
                           String(format: "injected unclipped split → screen in the gutter %.3f", leak))
                } else {
                    expect("selftest-split-unclipped-defect-fails", false, "capture failed")
                }
                PreviewCompositorView.debugDisableLayoutClip = false
            } else {
                expect("split-full-columns", false, "capture failed")
            }
            // Riders ride the squeeze: the tiles split moves the cursor with
            // the card, exactly the exporter's transform. Defect: unmoved.
            if let h0 = plainHotspot, let h1 = tilesHotspot, let card = compositor.debugVideoRect() {
                let want = h0.applying(CameraLayoutMath.cardTransform(tilesLayout, videoRect: card))
                let err = hypot(h1.x - want.x, h1.y - want.y), moved = hypot(h1.x - h0.x, h1.y - h0.y)
                expect("split-riders-follow-card", err < 1 && moved > 10,
                       String(format: "cursor %@ → %@ (want %@, err %.2f px, moved %.1f px)",
                              NSStringFromPoint(h0), NSStringFromPoint(h1), NSStringFromPoint(want), err, moved))
            } else {
                expect("split-riders-follow-card", false, "no cursor hotspot")
            }
        } else {
            expect("split-full-columns", false, "tiles capture failed")
        }

        // ── Vertical stack (docs/camera-cutout.md §12.12) ───────────────
        // A portrait canvas, briefly: the window takes 9:16, captures, and
        // goes back to the pane size the rest of the gate expects.
        let paneSize = container.bounds.size
        func portrait(_ on: Bool) async {
            let size = on ? CGSize(width: 405, height: 720) : paneSize
            container.window?.setContentSize(size)
            compositor.frame = CGRect(origin: .zero, size: size)
            await settle(0.2)
        }
        await portrait(true)
        fixture.project.cameraLayoutRegions = []
        func stackFrame(_ name: String, _ on: Bool, camera: Bool = true, look: CameraBubbleLook? = nil) async -> Frame? {
            reset { s in
                cameraSettings(s)
                s.showCamera = camera
                s.cameraPortraitStack = on
                s.cameraStackRatio = 0.42
                s.cameraLook = look
            }
            guard let raw = await capture(name) else { return nil }
            return Frame(pixels: raw.pixels, image: raw.image, flipped: flipped)
        }
        if let bareP = await stackFrame("stack-bare", false, camera: false),
           let stacked = await stackFrame("stack-on", true),
           let rows = compositor.lastStackRows, let cam = compositor.debugCameraRect() {
            func band(_ r: CGRect, _ y0: CGFloat, _ y1: CGFloat) -> [Sample] {
                stride(from: Int(y0), through: Int(y1), by: 2).flatMap { y in
                    stride(from: Int(r.minX + r.width * 0.2), through: Int(r.maxX - r.width * 0.2), by: 3).map {
                        Sample(x: $0, y: y, d: 0)
                    }
                }
            }
            func covered(_ f: Frame, _ pts: [Sample], _ tol: Int) -> Double {
                guard !pts.isEmpty else { return 0 }
                return Double(pts.filter { diff(f.rgb($0.x, $0.y), bareP.rgb($0.x, $0.y)) > tol }.count) / Double(pts.count)
            }
            let cameraBand = band(rows.camera, rows.camera.midY - 20, rows.camera.midY + 20)
            let screenBottom = band(rows.screen, rows.screen.maxY - 24, rows.screen.maxY - 8)
            // The filled card is as tall as its row but far wider, so an
            // unclipped one spills SIDEWAYS into the frame padding (where the
            // plain frame shows background): sample both side margins.
            let ys = stride(from: Int(rows.screen.minY + rows.screen.height * 0.2),
                            through: Int(rows.screen.maxY - rows.screen.height * 0.2), by: 3)
            let sideBand = ys.flatMap { y in
                (stride(from: Int(rows.screen.minX) - 16, through: Int(rows.screen.minX) - 5, by: 2).map { Sample(x: $0, y: y, d: 0) }
                 + stride(from: Int(rows.screen.maxX) + 5, through: Int(rows.screen.maxX) + 16, by: 2).map { Sample(x: $0, y: y, d: 0) })
            }
            let camFill = covered(stacked, cameraBand, 25)
            let screenFill = covered(stacked, screenBottom, 25)
            let sideLeak = covered(stacked, sideBand, 60)
            expect("stack-rows", cam == rows.camera && rows.camera.minY < rows.screen.minY
                   && camFill >= 0.97 && screenFill >= 0.97 && sideLeak <= 0.03 && compositor.debugLayoutClipPath() != nil,
                   String(format: "camera row filled %.3f · screen row filled to its bottom %.3f · screen beside its row %.3f (n=%d) · camera %@",
                          camFill, screenFill, sideLeak, sideBand.count, NSStringFromRect(cam)))
            PreviewCompositorView.debugDisableLayoutClip = true
            if let defect = await stackFrame("stack-unclipped-defect", true) {
                let leak = covered(defect, sideBand, 60)
                expect("selftest-stack-unclipped-defect-fails", leak >= 0.5,
                       String(format: "injected unclipped stack → screen beside its row %.3f", leak))
            }
            PreviewCompositorView.debugDisableLayoutClip = false

            // The stacked row wears the whole-video look: a pop-out card is
            // the row below its headroom, the headroom beside the head shows
            // the background, and the head rises into it. The plain stacked
            // frame — what the row drew while looks were off when stacked —
            // must fail the same predicate.
            let row = rows.camera
            let g = CameraCutoutMath.geometry(look: .popOut, bubbleRect: row, cameraAspect: Double(fixture.cameraAspect))
            let card = g.cardRect ?? row
            let r = g.cardCornerRadius
            let person = CameraCutoutMath.aspectFill(aspect: Double(fixture.cameraAspect), in: row)
            var rowSamples: [Sample] = []
            for y in stride(from: Int(row.minY) + 3, to: Int(row.maxY) - 3, by: 2) {
                for x in stride(from: Int(row.minX) + 3, to: Int(row.maxX) - 3, by: 2) {
                    let u = (Double(x) + 0.5 - person.minX) / person.width
                    let v = (Double(y) + 0.5 - person.minY) / person.height
                    rowSamples.append(Sample(x: x, y: y, d: silhouetteDistance(u: u, v: v)))
                }
            }
            // Top third of the headroom only: the card's shadow scales with
            // the row and fades well before it.
            let headroomTop = card.minY - row.minY
            let clearPts = rowSamples.filter { $0.d > 1.2 && CGFloat($0.y) < row.minY + headroomTop * 0.35 }
            let fillPts = rowSamples.filter {
                $0.d > 1.2 && card.insetBy(dx: r + 2, dy: 3).contains(CGPoint(x: CGFloat($0.x) + 0.5, y: CGFloat($0.y) + 0.5))
                    && CGFloat($0.y) > card.minY + r
            }
            let headPts = rowSamples.filter { $0.d < 0.85 && CGFloat($0.y) < card.minY - 2 }
            func meanRGB(_ f: Frame, _ pts: [Sample]) -> (Double, Double, Double) {
                let px = pts.compactMap { f.rgb($0.x, $0.y) }
                guard !px.isEmpty else { return (0, 0, 0) }
                let n = Double(px.count)
                return (Double(px.map(\.0).reduce(0, +)) / n, Double(px.map(\.1).reduce(0, +)) / n,
                        Double(px.map(\.2).reduce(0, +)) / n)
            }
            // The default card gradient at a row, analytically — the
            // background behind the row is violet too, so "differs from the
            // bare frame" would be blind across the card's lower half.
            func cardGradient(_ y: Int) -> (Int, Int, Int) {
                let p = min(1, max(0, (CGFloat(y) + 0.5 - card.minY) / card.height))
                let a = CameraCutoutMath.cardTopColor, b = CameraCutoutMath.cardBottomColor
                func c(_ s: CGFloat, _ e: CGFloat) -> Int { Int(((s + (e - s) * p) * 255).rounded()) }
                return (c(a.r, b.r), c(a.g, b.g), c(a.b, b.b))
            }
            func stackedPopHolds(_ f: Frame) -> (ok: Bool, detail: String) {
                let clear = agreement(f, bareP, clearPts)
                let covered = fillPts.isEmpty ? 0 : Double(fillPts.filter {
                    diff(f.rgb($0.x, $0.y), cardGradient($0.y)) <= 24
                }.count) / Double(fillPts.count)
                let head = agreement(f, stacked, headPts)
                let top = meanRGB(f, fillPts.filter { CGFloat($0.y) < card.minY + card.height / 3 })
                let bottom = meanRGB(f, fillPts.filter { CGFloat($0.y) > card.maxY - card.height / 3 })
                let gradient = top.0 > top.2 + 60 && bottom.2 > bottom.0 + 60
                let ok = clearPts.count >= 20 && clear >= 0.97 && fillPts.count >= 40 && covered >= 0.97
                    && headPts.count >= 10 && head >= 0.95 && gradient
                return (ok, String(format: "headroom n=%d ==bare %.3f · card n=%d on the gradient %.3f · head n=%d drawn %.3f · card top rgb(%.0f,%.0f,%.0f) bottom rgb(%.0f,%.0f,%.0f)",
                                   clearPts.count, clear, fillPts.count, covered, headPts.count, head,
                                   top.0, top.1, top.2, bottom.0, bottom.1, bottom.2))
            }
            if let pop = await stackFrame("stack-popout", true, look: .popOut) {
                let holds = stackedPopHolds(pop)
                expect("stack-popout", compositor.debugCameraLookWeights() == .init(cutout: 0, popOut: 1)
                       && compositor.debugCameraStackOpacities() == (0, 0, 1)
                       && compositor.debugCameraRect() == row && holds.ok, holds.detail)
                let plain = stackedPopHolds(stacked)
                expect("selftest-stack-popout-off-fails", !plain.ok, "plain stacked row → \(plain.detail)")
            } else {
                expect("stack-popout", false, "capture failed")
            }

            // ── Zoom inside the stack (§12.13) ──────────────────────────
            // Settled at 2.4×: the camera row keeps its top and yields to 75%
            // of its height, stays filled and UNzoomed (the frame padding
            // around it is still bare background); the screen zooms inside
            // its own row and stays clipped to it. Defect: the pre-§12.13
            // stack, where the whole stack zoomed — it must fail.
            let fullHeight = rows.camera.height
            let area = compositor.lastStackArea
            func zoomedStack(_ name: String, regionStart: TimeInterval = t0 - 1.5) async -> Frame? {
                reset { s in
                    cameraSettings(s)
                    s.cameraPortraitStack = true
                    s.cameraStackRatio = 0.42
                    s.cameraLook = nil
                    fixture.project.zoomRegions = [ZoomRegion(
                        startTime: regionStart, endTime: t0 + 2, zoomLevel: 2.4,
                        focalPoint: CGPoint(x: 0.8, y: 0.3))]
                }
                guard let raw = await capture(name) else { return nil }
                return Frame(pixels: raw.pixels, image: raw.image, flipped: flipped)
            }
            func zoomedHolds(_ f: Frame) -> (ok: Bool, detail: String) {
                guard let r = compositor.lastStackRows, let cam = compositor.debugCameraRect() else {
                    return (false, "no stack rows")
                }
                let layout = compositor.debugCameraLayout()
                let xs = stride(from: Int(area.minX + area.width * 0.1), through: Int(area.maxX - area.width * 0.1), by: 3)
                let topPad = stride(from: Int(area.minY) - 12, through: Int(area.minY) - 4, by: 2).flatMap { y in
                    xs.map { Sample(x: $0, y: y, d: 0) }
                }
                let camSide = stride(from: Int(r.camera.minY + 6), through: Int(r.camera.maxY - 6), by: 3).flatMap { y in
                    stride(from: Int(area.minX) - 14, through: Int(area.minX) - 5, by: 2).map { Sample(x: $0, y: y, d: 0) }
                        + stride(from: Int(area.maxX) + 5, through: Int(area.maxX) + 14, by: 2).map { Sample(x: $0, y: y, d: 0) }
                }
                let screenSide = stride(from: Int(r.screen.minY + r.screen.height * 0.2),
                                        through: Int(r.screen.maxY - r.screen.height * 0.2), by: 3).flatMap { y in
                    stride(from: Int(r.screen.minX) - 14, through: Int(r.screen.minX) - 5, by: 2).map { Sample(x: $0, y: y, d: 0) }
                        + stride(from: Int(r.screen.maxX) + 5, through: Int(r.screen.maxX) + 14, by: 2).map { Sample(x: $0, y: y, d: 0) }
                }
                let padLeak = covered(f, topPad + camSide, 60)
                let screenLeak = covered(f, screenSide, 60)
                let camFill = covered(f, band(r.camera, r.camera.midY - 12, r.camera.midY + 12), 25)
                let screenFill = covered(f, band(r.screen, r.screen.maxY - 24, r.screen.maxY - 8), 25)
                let yielded = abs(r.camera.height - fullHeight * 0.75) < 1 && abs(r.camera.minY - rows.camera.minY) < 0.5
                let ok = abs(compositor.motion.zoom - 2.4) < 0.02 && yielded && cam == r.camera
                    && layout.cardClip == r.screen && padLeak <= 0.03 && screenLeak <= 0.03
                    && camFill >= 0.97 && screenFill >= 0.97
                return (ok, String(format: "zoom %.3f · camera row %.1f of %.1f (yield %.3f) · padding covered %.3f · screen beside its row %.3f · camera filled %.3f · screen filled %.3f",
                                   compositor.motion.zoom, r.camera.height, fullHeight, r.camera.height / fullHeight,
                                   padLeak, screenLeak, camFill, screenFill))
            }
            if let zoomed = await zoomedStack("stack-zoom") {
                let holds = zoomedHolds(zoomed)
                expect("stack-zoom", holds.ok, holds.detail)
                PreviewCompositorView.debugStackZoomOutside = true
                if let defect = await zoomedStack("stack-zoom-outside-defect") {
                    let bad = zoomedHolds(defect)
                    expect("selftest-stack-zoom-outside-fails", !bad.ok, "whole stack zoomed → \(bad.detail)")
                } else {
                    expect("selftest-stack-zoom-outside-fails", false, "capture failed")
                }
                PreviewCompositorView.debugStackZoomOutside = false
            } else {
                expect("stack-zoom", false, "capture failed")
            }

            // MOTION: a zoom entering at t0 + 0.4, ticked at 30 Hz like
            // playback — the seam must be caught gliding (the camera row
            // strictly between full and yielded height) in step with the
            // zoom spring, never snapping.
            _ = await zoomedStack("stack-zoom-seq-start", regionStart: t0 + 0.4)
            var glide: [(zoom: Double, height: CGFloat)] = []
            var tick = t0 + 0.3
            while tick < t0 + 1.9 {
                fixture.currentTime = tick
                compositor.schedule(compositorInput(fixture))
                await settle(0.02)
                if let r = compositor.lastStackRows { glide.append((compositor.motion.zoom, r.camera.height)) }
                tick += 1.0 / 30
            }
            let midGlide = glide.filter { $0.height < fullHeight - 0.5 && $0.height > fullHeight * 0.75 + 0.5 }
            let monotonic = zip(glide, glide.dropFirst()).allSatisfy { $1.height <= $0.height + 0.01 }
            let tracks = glide.allSatisfy {
                abs($0.height - fullHeight * CGFloat(CameraLayoutMath.stackYield(zoom: $0.zoom))) < 0.5
            }
            expect("stack-zoom-glide",
                   glide.first.map { abs($0.height - fullHeight) < 0.5 } == true
                       && glide.last.map { $0.height < fullHeight * 0.78 } == true
                       && midGlide.count >= 4 && monotonic && tracks,
                   String(format: "ticks=%d mid-glide=%d monotonic=%@ height tracks the zoom=%@ · first %.1f last %.1f (full %.1f)",
                          glide.count, midGlide.count, monotonic ? "yes" : "no", tracks ? "yes" : "no",
                          glide.first?.height ?? -1, glide.last?.height ?? -1, fullHeight))
            reset { _ in fixture.project.zoomRegions = [] }

            // ── Gap None: one card (§12.14) ─────────────────────────────
            // The band the 2% gap showed as background is covered; the real
            // mask paths are SQUARE at the seam (screen-row top corners,
            // camera-row bottom corners) and still rounded outside. Defect:
            // the seam shapes ignored — rounded seam corners must fail.
            func joinedStack(_ name: String) async -> Frame? {
                reset { s in
                    cameraSettings(s)
                    s.cameraPortraitStack = true
                    s.cameraStackRatio = 0.42
                    s.cameraStackGap = 0
                    s.cornerRadius = 20
                    s.cameraLook = nil
                }
                guard let raw = await capture(name) else { return nil }
                return Frame(pixels: raw.pixels, image: raw.image, flipped: flipped)
            }
            func joinedHolds(_ f: Frame) -> (ok: Bool, detail: String) {
                guard let r = compositor.lastStackRows, let cam = compositor.debugCameraRect(),
                      let clipPath = compositor.debugLayoutClipPath(), let camPath = compositor.debugCameraMaskPath() else {
                    return (false, "no stack rows / mask paths")
                }
                let gapBand = stride(from: Int(rows.camera.maxY) + 2, through: Int(rows.screen.minY) - 2, by: 1).flatMap { y in
                    stride(from: Int(area.minX + area.width * 0.2), through: Int(area.maxX - area.width * 0.2), by: 3).map {
                        Sample(x: $0, y: y, d: 0)
                    }
                }
                let closed = gapBand.isEmpty ? 0 : Double(gapBand.filter {
                    diff(f.rgb($0.x, $0.y), stacked.rgb($0.x, $0.y)) > 25
                }.count) / Double(gapBand.count)
                let o = area.origin
                let sc = r.screen.offsetBy(dx: -o.x, dy: -o.y)
                let screenSquare = clipPath.contains(CGPoint(x: sc.minX + 1.5, y: sc.minY + 1.5))
                    && clipPath.contains(CGPoint(x: sc.maxX - 1.5, y: sc.minY + 1.5))
                let screenRound = !clipPath.contains(CGPoint(x: sc.minX + 1.5, y: sc.maxY - 1.5))
                let (w, h) = (cam.width, cam.height)
                let camSquare = camPath.contains(CGPoint(x: 1.5, y: h - 1.5)) && camPath.contains(CGPoint(x: w - 1.5, y: h - 1.5))
                let camRound = !camPath.contains(CGPoint(x: 1.5, y: 1.5))
                let touching = abs(r.screen.minY - r.camera.maxY) < 1e-6
                let ok = touching && closed >= 0.9 && screenSquare && screenRound && camSquare && camRound
                    && compositor.debugCameraLayout().seamJoin == 1
                return (ok, String(format: "rows touch %@ · old gap band covered %.3f (n=%d) · seam corners square: screen %@ camera %@ · outer corners round: screen %@ camera %@",
                                   touching ? "yes" : "no", closed, gapBand.count, screenSquare ? "yes" : "no", camSquare ? "yes" : "no",
                                   screenRound ? "yes" : "no", camRound ? "yes" : "no"))
            }
            if let joined = await joinedStack("stack-joined") {
                let holds = joinedHolds(joined)
                expect("stack-joined", holds.ok, holds.detail)
                PreviewCompositorView.debugIgnoreSeamShapes = true
                if let defect = await joinedStack("stack-joined-round-defect") {
                    let bad = joinedHolds(defect)
                    expect("selftest-stack-joined-round-fails", !bad.ok, "seam shapes ignored → \(bad.detail)")
                } else {
                    expect("selftest-stack-joined-round-fails", false, "capture failed")
                }
                PreviewCompositorView.debugIgnoreSeamShapes = false
            } else {
                expect("stack-joined", false, "capture failed")
            }
        } else {
            expect("stack-rows", false, "capture failed or the stack did not engage")
        }
        await portrait(false)

        fixture.project.cameraLayoutRegions = []
        fixture.cameraMask = nil
        reset { _ in }
        return failures
    }

    /// 8-px black/white vertical stripes — high-frequency content for the
    /// background-blur check (the fixture's own poster is a smooth gradient).
    static func stripedPoster(size: CGSize) -> NSImage {
        let w = Int(size.width * 2), h = Int(size.height * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return NSImage(size: size) }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        for x in stride(from: 0, to: w, by: 16) { ctx.fill(CGRect(x: x, y: 0, width: 8, height: h)) }
        guard let cg = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cg, size: size)
    }
}
