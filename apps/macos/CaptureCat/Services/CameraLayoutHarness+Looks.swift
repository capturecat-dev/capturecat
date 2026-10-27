import CoreGraphics
import CoreImage
import Foundation

/// `--cameralayout-test`, camera LOOKS half (docs/camera-cutout.md): the
/// `look` model + lenient decode, `lookWeights` (mid-flight, eased, no intro
/// morph), `CameraCutoutMath` geometry in both Y conventions, the `.ccmask`
/// codec twin, and the shared CI masking step's orientation (a mask applied
/// upside down or unmirrored passes every settled-number check and still
/// cuts the wrong half of the person out — so it is asserted on pixels).
extension CameraLayoutHarness {
    static func cameraLookChecks(expect: (Bool, String) -> Void) {
        modelChecks(expect: expect)
        weightChecks(expect: expect)
        geometryChecks(expect: expect)
        dissolveChecks(expect: expect)
        codecChecks(expect: expect)
        maskPixelChecks(expect: expect)
    }

    // MARK: - Model

    private static func decodeRegion(_ json: String) -> CameraLayoutRegion? {
        try? JSONDecoder().decode(CameraLayoutRegion.self, from: Data(json.utf8))
    }

    private static func modelChecks(expect: (Bool, String) -> Void) {
        let withLook = CameraLayoutRegion(startTime: 1, endTime: 5, mode: .bubble, look: .popOut)
        let plain = CameraLayoutRegion(startTime: 1, endTime: 5, mode: .sideBySide)
        do {
            let data = try JSONEncoder().encode([withLook, plain])
            let back = try JSONDecoder().decode([CameraLayoutRegion].self, from: data)
            expect(back == [withLook, plain], "look round-trips (popOut on bubble, none on sideBySide)")
            let objects = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            expect(objects.count == 2 && objects[0]["look"] as? String == "popOut",
                   "look encodes with its raw value \"popOut\"")
            expect(objects.count == 2 && objects[1]["look"] == nil,
                   "no look → no key at all (untouched projects stay byte-identical)")
        } catch {
            expect(false, "look codable threw: \(error)")
        }
        let legacy = decodeRegion("{}")
        expect(legacy?.mode == .cameraOnly && legacy?.look == nil, "legacy {} → cameraOnly, no look")
        expect(decodeRegion(#"{"mode":null}"#)?.mode == .cameraOnly, "mode null → cameraOnly (missing)")
        expect(decodeRegion(#"{"mode":"pictureInPicture"}"#)?.mode == .bubble,
               "unknown mode → bubble (never throws)")
        expect(decodeRegion(#"{"mode":7}"#) == nil, "non-string mode still throws (as before)")
        expect(decodeRegion(#"{"mode":"bubble","look":"hologram"}"#).map { $0.look == nil } == true,
               "unknown look → nil (plain bubble)")
        expect(decodeRegion(#"{"mode":"bubble","look":3}"#).map { $0.look == nil } == true,
               "non-string look → nil")
        if let kept = decodeRegion(#"{"mode":"cameraOnly","look":"cutout"}"#) {
            expect(kept.look == .cutout && kept.effectiveLook == nil,
                   "look on a non-bubble mode is kept but ignored")
            let again = (try? JSONEncoder().encode(kept)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            expect(again?["look"] as? String == "cutout", "an ignored look survives a re-save")
        } else {
            expect(false, "look on cameraOnly failed to decode")
        }
        expect(CameraBubbleLook.cutout.displayName == "Cutout"
                && CameraBubbleLook.popOut.displayName == "Pop-out card",
               "display names: Cutout / Pop-out card")
        expect(CameraBubbleLook.allCases.map(\.rawValue) == ["cutout", "popOut"], "raw values are persistence identity")

        // A WHOLE project carrying a future mode must still load — the bug
        // that made the looks a key instead of new modes.
        let project = Project(id: UUID(), name: "future", videoURL: URL(fileURLWithPath: "/tmp/none.mov"), duration: 10)
        project.cameraLayoutRegions = [CameraLayoutRegion(startTime: 1, endTime: 2, mode: .cameraOnly)]
        if let data = try? JSONEncoder().encode(project),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var regions = object["cameraLayoutRegions"] as? [[String: Any]], !regions.isEmpty {
            regions[0]["mode"] = "hologramStage"
            regions[0]["look"] = "sparkles"
            object["cameraLayoutRegions"] = regions
            let mutated = try? JSONSerialization.data(withJSONObject: object)
            let decoded = mutated.flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
            expect(decoded?.cameraLayoutRegions.first?.mode == .bubble
                    && decoded?.cameraLayoutRegions.first?.look == nil,
                   "a project with a future mode + unknown look still loads (region → plain bubble)")
        } else {
            expect(false, "project fixture encode failed")
        }
    }

    // MARK: - lookWeights

    private static func weightChecks(expect: (Bool, String) -> Void) {
        let D = CameraLayoutMath.transitionDuration
        let regions = [
            CameraLayoutRegion(startTime: 2, endTime: 6, mode: .bubble, look: .cutout),
            CameraLayoutRegion(startTime: 6, endTime: 10, mode: .bubble, look: .popOut),
            CameraLayoutRegion(startTime: 12, endTime: 14, mode: .cameraOnly, look: .cutout),
            CameraLayoutRegion(startTime: 16, endTime: 18, mode: .bubble),
        ]
        func w(_ t: Double, _ r: [CameraLayoutRegion] = regions) -> CameraLayoutMath.LookWeights {
            CameraLayoutMath.lookWeights(at: t, regions: r)
        }
        expect(w(1) == .none, "before any look → none")
        expect(CameraLayoutMath.lookWeights(at: 3, regions: []) == .none, "no regions → none")
        expect(w(2 + D + 0.01) == .init(cutout: 1, popOut: 0), "settled cutout draws only the cutout")
        expect(w(6 + D + 0.01) == .init(cutout: 0, popOut: 1), "settled pop-out draws only the card")
        expect(w(13) == .none, "a look on a cameraOnly block is ignored")
        expect(w(17) == .none, "a bubble block without a look → none")

        // MID-FLIGHT, bubble → cutout: strictly between, eased, monotonic.
        let mid = w(2 + D / 2)
        expect(mid.cutout > 0.01 && mid.cutout < 0.99 && mid.popOut == 0,
               "mid-morph bubble→cutout is strictly between (\(String(format: "%.3f", mid.cutout)))")
        expect(abs(mid.cutout - CameraLayoutMath.ease(0.5)) < 1e-12, "the fade rides the layout's smootherstep")
        var series: [Double] = []
        for i in 0...10 { series.append(w(2 + D * Double(i) / 10).cutout) }
        expect(zip(series, series.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 }, "cutout weight rises monotonically")
        expect(series[7] - series[4] > series[3] - series[0], "eased (not linear) — middle moves fastest")
        expect(series[0] == 0 && abs(series[10] - 1) < 1e-9, "fade starts at 0 and lands on 1")

        // Look → look across an adjacent edge: a true cross-fade.
        let swap = w(6 + D / 2)
        expect(swap.cutout > 0.01 && swap.cutout < 0.99 && swap.popOut > 0.01 && swap.popOut < 0.99,
               "mid cutout→pop-out both looks are mid-flight")
        expect(abs(swap.cutout + swap.popOut - 1) < 1e-12 && swap.bubble == 0,
               "look→look weights sum to 1 (no bubble flash between looks)")
        // Exit back to nothing.
        let exit = w(10 + D / 2)
        expect(exit.popOut > 0.01 && exit.popOut < 0.99 && exit.cutout == 0, "pop-out fades out after its block")
        expect(abs(exit.bubble + exit.popOut - 1) < 1e-12, "weights + bubble always sum to 1")

        // No intro morph: a look block at (or within 0.05 s of) t = 0 opens
        // settled; its EXIT still morphs.
        for start in [0.0, 0.04] {
            let intro = [CameraLayoutRegion(startTime: start, endTime: 3, mode: .bubble, look: .cutout)]
            expect(w(start, intro) == .init(cutout: 1, popOut: 0) && w(start + D / 2, intro).cutout == 1,
                   "look block at t=\(start): frame one is already the look (no intro morph)")
            let out = w(3 + D / 2, intro).cutout
            expect(out > 0.01 && out < 0.99, "look block at t=\(start): exit still fades")
        }
        // Edges closer than the transition: the most recent edge wins.
        let tight = [
            CameraLayoutRegion(startTime: 2, endTime: 2.04, mode: .bubble, look: .cutout),
            CameraLayoutRegion(startTime: 2.04, endTime: 5, mode: .bubble, look: .popOut),
        ]
        let t2 = w(2.04 + D / 2, tight)
        expect(t2.cutout > 0 && t2.popOut > 0 && abs(t2.cutout + t2.popOut - 1) < 1e-12,
               "edges 0.04 s apart: the later edge drives the fade")

        // Mode morph and look fade share one clock: cameraOnly → cutout.
        let modeMorph = [
            CameraLayoutRegion(startTime: 2, endTime: 6, mode: .cameraOnly),
            CameraLayoutRegion(startTime: 6, endTime: 9, mode: .bubble, look: .cutout),
        ]
        let p = CameraLayoutMath.ease(0.5)
        expect(abs(w(6 + D / 2, modeMorph).cutout - p) < 1e-12,
               "a mode morph into a look fades the look in lock-step with the geometry")
        let card = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let bubble = CGRect(x: 1300, y: 600, width: 240, height: 240)
        let layout = CameraLayoutMath.resolve(
            at: 6 + D / 2, regions: modeMorph, videoRect: card, bubbleRect: bubble,
            bubbleCornerRadius: 120, cardCornerRadius: 20, hasCamera: true)
        expect(!layout.isPlainBubble && (layout.cameraRect?.width ?? 0) > bubble.width + 1,
               "…drawn at resolve's mid-morph tile (the override path)")

        // Static-span key (§11): two fields appended, %.3f.
        let plainKey = StaticSpanCollapse.cameraLayoutKey(layout)
        let lookKey = StaticSpanCollapse.cameraLayoutKey(layout, looks: .init(cutout: 0.5, popOut: 0.25))
        expect(plainKey.hasSuffix(",0.000,0.000") && plainKey.split(separator: ",").count == 10,
               "span key without a look ends in ,0.000,0.000 (10 fields)")
        expect(lookKey.hasSuffix(",0.500,0.250") && lookKey != plainKey, "a fading look changes the span key")
    }

    // MARK: - Geometry

    private static func geometryChecks(expect: (Bool, String) -> Void) {
        let b = CGRect(x: 100, y: 200, width: 240, height: 180)
        let aspect = 16.0 / 9
        let cut = CameraCutoutMath.geometry(look: .cutout, bubbleRect: b, cameraAspect: aspect)
        expect(cut.clipRect == b && cut.cardRect == nil && cut.cardCornerRadius == 0 && cut.clipBottomCornerRadius == 0,
               "cutout: clip = B, no card, square corners")
        let p = cut.personRect
        expect(p.contains(b.insetBy(dx: 0.001, dy: 0.001)) && abs(p.midX - b.midX) < 1e-9 && abs(p.midY - b.midY) < 1e-9
                && abs(p.width / p.height - aspect) < 1e-9 && (abs(p.width - b.width) < 1e-9 || abs(p.height - b.height) < 1e-9),
               "person rect = aspect-fill of the camera over B, centred")
        let pop = CameraCutoutMath.geometry(look: .popOut, bubbleRect: b, cameraAspect: aspect)
        if let card = pop.cardRect {
            expect(abs(card.minY - (b.minY + 0.22 * b.height)) < 1e-9 && abs(card.maxY - b.maxY) < 1e-9
                    && card.minX == b.minX && card.width == b.width,
                   "pop-out card = B with its top moved down by 22% (Y-down)")
            expect(abs(pop.cardCornerRadius - 0.16 * min(card.width, card.height)) < 1e-9
                    && pop.clipBottomCornerRadius == pop.cardCornerRadius && pop.clipRect == b,
                   "card radius = 16% of its short side; person clip = B, bottom corners only")
        } else {
            expect(false, "pop-out has no card")
        }
        // Y-up is the same geometry flipped about the frame height.
        let H: CGFloat = 1080
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
        let up = CameraCutoutMath.geometry(look: .popOut, bubbleRect: flip(b), cameraAspect: aspect, yAxisIsUp: true)
        let same = up.cardRect.map { c in pop.cardRect.map { abs(flip($0).minY - c.minY) < 1e-9 && abs(flip($0).height - c.height) < 1e-9 } ?? false } ?? false
        expect(same && abs(flip(pop.personRect).minY - up.personRect.minY) < 1e-9 && up.cardCornerRadius == pop.cardCornerRadius,
               "Y-up geometry == Y-down geometry flipped by the frame height")
        // The person clip (generator over B extended up by r, cut to B)
        // rounds only the BOTTOM corners, in both conventions.
        let down = CameraCutoutMath.personClipPath(pop, yAxisIsUp: false)
        func inClip(_ path: CGPath, _ rect: CGRect, _ p: CGPoint) -> Bool { rect.contains(p) && path.contains(p) }
        expect(inClip(down, b, CGPoint(x: b.minX + 0.5, y: b.minY + 0.5))
                && !inClip(down, b, CGPoint(x: b.minX + 0.5, y: b.maxY - 0.5))
                && inClip(down, b, CGPoint(x: b.midX, y: b.maxY - 0.5)),
               "Y-down clip: top corners square, bottom corners rounded")
        let upPath = CameraCutoutMath.personClipPath(up, yAxisIsUp: true)
        let ub = flip(b)
        expect(inClip(upPath, ub, CGPoint(x: ub.minX + 0.5, y: ub.maxY - 0.5))
                && !inClip(upPath, ub, CGPoint(x: ub.minX + 0.5, y: ub.minY + 0.5)),
               "Y-up clip: square at maxY (top), rounded at minY (bottom)")
        let maskRect = CameraCutoutMath.personClipMaskRect(pop, yAxisIsUp: false)
        expect(maskRect.minY == b.minY - pop.clipBottomCornerRadius && maskRect.maxY == b.maxY,
               "person clip mask = B extended UP by r")
        // Degenerate aspects follow the exporter formula (no special case).
        let zero = CameraCutoutMath.aspectFill(aspect: 0, in: b)
        expect(!zero.width.isFinite || zero.width.isNaN, "aspect 0 → non-finite fill, as the formula gives")
    }

    // MARK: - Dissolve arithmetic

    /// `scale(x, w)` must be premultiplied RGBA × w (A-vector only), and the
    /// sum of two complementary scaled opaque stacks must stay opaque.
    static func dissolveChecks(expect: (Bool, String) -> Void) {
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: extent)
        let sum = VideoExporter.scaleStack(blue, by: 0.3)
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: VideoExporter.scaleStack(red, by: 0.7)])
        if let cg = ctx.createCGImage(sum, from: extent), let px = rgba(cg) {
            let p = px.row(1)
            expect(p[3] >= 254 && abs(Int(p[0]) - 179) <= 2 && abs(Int(p[2]) - 77) <= 2,
                   "dissolve 0.7 red + 0.3 blue stays opaque (rgba \(p[0]),\(p[1]),\(p[2]),\(p[3]))")
        } else {
            expect(false, "dissolve render failed")
        }
        expect(VideoExporter.scaleStack(red, by: 1) === red, "scale(x, 1) is the identity (no pass)")
    }

    // MARK: - Codec

    /// A soft ellipse "head and shoulders" that drifts, then holds still —
    /// both key and delta payloads occur. Deterministic.
    static func syntheticMaskFrames(width: Int, height: Int, count: Int, fps: Double = 30) -> [(time: Double, alpha: [UInt8])] {
        (0..<count).map { i in
            let still = i >= count * 2 / 3
            let u = still ? Double(count * 2 / 3) / Double(count) : Double(i) / Double(count)
            let cx = Double(width) * (0.35 + 0.3 * u)
            let cy = Double(height) * 0.62
            let rx = Double(width) * 0.24, ry = Double(height) * 0.5
            var alpha = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                    let d = (dx * dx + dy * dy).squareRoot()
                    // 1 inside, 0 outside, a soft ramp across the edge.
                    let v = min(1, max(0, (1.12 - d) / 0.24))
                    alpha[y * width + x] = UInt8((v * 255).rounded())
                }
            }
            return (Double(i) / fps + 0.0123, alpha)
        }
    }

    private static func codecChecks(expect: (Bool, String) -> Void) {
        let frames = syntheticMaskFrames(width: 64, height: 36, count: 48)
        guard let data = try? CameraMaskTrack.encode(
            width: 64, height: 36, keyframeInterval: 8, sourceDuration: 1.6, sourceByteSize: 123_456,
            frames: frames),
              let track = try? CameraMaskTrack(data: data) else {
            expect(false, "codec: encode/parse threw")
            return
        }
        expect(track.header == .init(width: 64, height: 36, keyframeInterval: 8, frameCount: 48,
                                     sourceDuration: 1.6, sourceByteSize: 123_456),
               "codec: header round-trips")
        expect(!track.index[0].delta, "codec: frame 0 is a key")
        var run = 0, maxRun = 0
        for e in track.index { run = e.delta ? run + 1 : 0; maxRun = max(maxRun, run) }
        expect(maxRun <= 7 && track.index.contains { $0.delta } && track.index.dropFirst().contains { !$0.delta },
               "codec: keys + deltas both occur, never more than keyframeInterval−1 deltas (max run \(maxRun))")
        let sequential = CameraMaskTrack.Decoder(track: track)
        var allEqual = true
        for i in 0..<frames.count where (try? sequential.frame(i)) != frames[i].alpha { allEqual = false }
        expect(allEqual, "codec: sequential decode is lossless")
        let seeker = CameraMaskTrack.Decoder(track: track)
        var seekEqual = true
        for i in [40, 3, 47, 0, 21, 22, 9, 8, 7, 33] where (try? seeker.frame(i)) != frames[i].alpha { seekEqual = false }
        expect(seekEqual, "codec: random seeks decode the same bytes")
        let times = track.index.map(\.time)
        expect(track.frameIndex(at: -5) == 0 && track.frameIndex(at: times[0]) == 0
                && track.frameIndex(at: times[5]) == 5 && track.frameIndex(at: times[5] - 1e-9) == 4
                && track.frameIndex(at: 99) == 47 && track.frameIndex(at: .nan) == 0
                && CameraMaskTrack.frameIndexAt([], 1) == -1,
               "codec: frameIndexAt = last frame ≤ t, clamped to frame 0 (NaN → 0, empty → −1)")
        var bad = data
        bad[0] = 0x58
        expect((try? CameraMaskTrack(data: bad)) == nil, "codec: bad magic rejected")
        expect((try? CameraMaskTrack(data: data.prefix(40))) == nil, "codec: truncated index rejected")
        var deltaFirst = data
        deltaFirst[CameraMaskTrack.headerBytes + 15] |= 0x80
        expect((try? CameraMaskTrack(data: deltaFirst)) == nil, "codec: a delta first frame is rejected")
        let s169 = CameraMaskTrack.maskSize(cameraAspect: 16.0 / 9)
        let s43 = CameraMaskTrack.maskSize(cameraAspect: 4.0 / 3)
        let s916 = CameraMaskTrack.maskSize(cameraAspect: 9.0 / 16)
        expect(s169 == (341, 192) && s43 == (256, 192) && s916 == (108, 192)
                && CameraMaskTrack.maskSize(cameraAspect: 3).width == 341,
               "mask size: 192 rows, width = round(192 × aspect) capped at 341")
        conditioningChecks(expect: expect)
        let h = track.header
        expect(CameraMaskTrack.isFresh(h, cameraByteSize: 123_456, cameraDuration: 1.65)
                && !CameraMaskTrack.isFresh(h, cameraByteSize: 123_457, cameraDuration: 1.6)
                && !CameraMaskTrack.isFresh(h, cameraByteSize: 123_456, cameraDuration: 1.66),
               "staleness: same byte size and |Δduration| ≤ 0.05 s")
    }

    // MARK: - Producer alpha conditioning (contract §6)

    /// The SAME three frames and expected outputs as the web twin's vitest
    /// (apps/web/src/editor/core/mask/conditionAlpha.test.ts) — computed from
    /// the contract's integer formulas, so the two producers write identical
    /// bytes for identical mattes.
    static let conditioningFixture: [(raw: [UInt8], expected: [UInt8])] = [
        ([0, 5, 15, 16, 17, 30, 60, 100, 128, 150, 200, 238, 239, 240, 250, 255],
         [0, 0, 0, 0, 0, 36, 73, 109, 146, 146, 182, 255, 255, 255, 255, 255]),
        ([3, 20, 40, 10, 50, 70, 64, 140, 120, 185, 230, 255, 220, 200, 255, 245],
         [0, 0, 36, 0, 36, 73, 73, 109, 146, 182, 219, 255, 219, 182, 255, 255]),
        ([60, 0, 0, 90, 18, 33, 100, 160, 200, 120, 170, 250, 200, 239, 100, 254],
         [73, 0, 0, 73, 36, 36, 73, 146, 182, 109, 182, 255, 219, 255, 109, 255]),
    ]

    private static func conditioningChecks(expect: (Bool, String) -> Void) {
        let rule = CameraMaskConditioning.producer
        expect(rule == .init(deadZone: 16, levels: 8, hold: 32), "producer rule = dead zone 16, 8 levels, hold 32")
        let levels = Set((0...255).map { CameraMaskConditioning.quantize($0, levels: 8) }).sorted()
        expect(levels == [0, 36, 73, 109, 146, 182, 219, 255], "8 levels: \(levels)")
        var previous: [UInt8]?
        var allMatch = true
        for (i, frame) in conditioningFixture.enumerated() {
            var alpha = frame.raw
            CameraMaskConditioning.condition(&alpha, previous: previous)
            if alpha != frame.expected {
                allMatch = false
                print("  conditioning frame \(i): got \(alpha)")
            }
            previous = alpha
        }
        expect(allMatch, "conditioning fixture: 3 frames match the contract's integer formulas (shared with the TS twin)")
        var none = conditioningFixture[0].raw
        CameraMaskConditioning.condition(&none, previous: nil, rule: .none)
        expect(none == conditioningFixture[0].raw, "Rule.none is the identity")
        // Still input → byte-identical output frames (what lets deltas win).
        var a = conditioningFixture[1].raw, b = conditioningFixture[1].raw.map { UInt8(min(255, Int($0) + 3)) }
        CameraMaskConditioning.condition(&a, previous: nil)
        CameraMaskConditioning.condition(&b, previous: a)
        expect(a == b, "±3-level flicker on a still frame repeats the previous output exactly")
    }

    // MARK: - Shared CI masking step, on pixels

    private struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]
        /// Row 0 = TOP of the image.
        func row(_ y: Int) -> [UInt8] { Array(bytes[(y * width * 4)..<((y + 1) * width * 4)]) }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
    }

    private static func rgba(_ image: CGImage) -> Pixels? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Pixels(width: w, height: h, bytes: bytes) : nil
    }

    private static func maskPixelChecks(expect: (Bool, String) -> Void) {
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let extent = CGRect(x: 0, y: 0, width: 40, height: 20)
        let solid = CIImage(color: CIColor(red: 0.9, green: 0.3, blue: 0.2)).cropped(to: extent)
        func render(_ image: CIImage) -> Pixels? {
            ctx.createCGImage(image, from: extent).flatMap(rgba)
        }
        // Row 0 of the mask is the TOP of the camera image.
        if let mask = CameraStyleMath.maskCIImage(alpha: [255, 255, 255, 255, 0, 0, 0, 0], width: 4, height: 2),
           let px = render(CameraStyleMath.maskedImage(solid, mask: mask, mirrored: false)) {
            expect(px.alpha(20, 1) == 255 && px.alpha(20, 18) == 0,
                   "mask row 0 lands on the image's TOP (top α=\(px.alpha(20, 1)), bottom α=\(px.alpha(20, 18)))")
        } else {
            expect(false, "mask orientation render failed")
        }
        // Mirrored frames mirror the mask with them.
        if let mask = CameraStyleMath.maskCIImage(alpha: [255, 0, 255, 0], width: 2, height: 2),
           let plain = render(CameraStyleMath.maskedImage(solid, mask: mask, mirrored: false)),
           let mirrored = render(CameraStyleMath.maskedImage(solid, mask: mask, mirrored: true)) {
            expect(plain.alpha(2, 10) == 255 && plain.alpha(37, 10) == 0
                    && mirrored.alpha(2, 10) == 0 && mirrored.alpha(37, 10) == 255,
                   "mirrored frame → mask mirrored with it")
        } else {
            expect(false, "mask mirror render failed")
        }
        // Mask values are alpha, never colour-managed: 128 stays ≈ 128.
        if let mask = CameraStyleMath.maskCIImage(alpha: [128], width: 1, height: 1),
           let px = render(CameraStyleMath.maskedImage(solid, mask: mask, mirrored: false)) {
            let a = Int(px.alpha(20, 10))
            expect(abs(a - 128) <= 1, "mask value 128 → α \(a) (linear, no gamma shift)")
        } else {
            expect(false, "mask linearity render failed")
        }
    }
}
