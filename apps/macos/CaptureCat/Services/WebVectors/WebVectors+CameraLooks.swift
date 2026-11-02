import CoreGraphics
import CryptoKit
import Foundation

// Golden-vector units for the camera LOOKS (docs/camera-cutout.md §10):
//   cameraLookWeights    — CameraLayoutMath.lookWeights(at:regions:defaultLook:)
//   cameraStackRows / cameraStackZoom — the vertical stack's rows and its zoom (§12.12/§12.13)
//   cameraCutoutGeometry — CameraCutoutMath.geometry(look:bubbleRect:cameraAspect:) (Y-down)
//   cameraMaskCodec      — a `.ccmask` written by THIS app's encoder
//                          (CameraMaskTrack.Encoder), which the TS codec must
//                          parse and decode to the same bytes (SHA-256 per frame).
// TS ports: apps/web/src/editor/core/math/ + core/mask/cameraMaskCodec.ts.
extension WebVectors {
    static var cameraLookUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "cameraLookWeights",
                notes: "Services/CameraLayoutMath.swift — lookWeights(at:regions:defaultLook:) (look(at:): outside every region the defaultLook; inside, a bubble region's look or else the defaultLook, nothing on other modes — except Side by Side while `stacking`, which wears the defaultLook (§12.12); ease; transitionDuration; edges ≤ 0.05 s never morph). Regions as project.json (look optional, also on non-bubble modes where it is ignored); defaultLook = settings.cameraLook, absent = null; queries cluster on edges, mid-fade and settled",
                build: cameraLookWeightsCases),
            WebVectorUnit(
                name: "cameraCutoutGeometry",
                notes: "Services/CameraCutoutMath.swift — geometry(look:bubbleRect:cameraAspect:popOutAmount:cardBorderWidth:) in Y-down: personRect = aspectFill(cameraAspect, B), clipRect = B, pop-out card = B minus a headroom of 0.44 × clamp(popOutAmount ?? 0.5) × B.h off its top (0.22 at the default), radius 16% of the card's short side (clip bottom corners only); cardBorderWidth (output) = clamp(input thickness) × 0.08 × min(card) for pop-out with a thickness, else 0. Inputs popOutAmount / cardBorderWidth are optional (absent = default / no border)",
                build: cameraCutoutGeometryCases),
            WebVectorUnit(
                name: "cameraMaskEdge",
                notes: "Services/CameraMaskEdge.swift — process(alpha, width, height, softness, inset) (docs/camera-cutout.md §12.4): k = height / 192; i = round(clamp(inset) × 6 × k), s = round(clamp(softness) × 6 × k) (evaluate (clamp × 6) × k in that order; round half up); erode rows then columns (min over ±i, clamp-to-edge), then box-blur rows, columns, rows, columns ((Σ over ±s + s) ÷ (2s + 1), integer); i = s = 0 → unchanged. base64 = raw 8-bit alpha, row 0 = top",
                build: cameraMaskEdgeCases),
            WebVectorUnit(
                name: "cameraStackRows",
                notes: "Services/CameraLayoutMath.swift — stackRows(area:ratio:yAxisIsUp:yield:) (docs/camera-cutout.md §12.12): gap = 0.02 × area.h, h = (area.h − gap) × clamp(ratio, 0.25, 0.7) × yield (input `yield` optional, absent = 1, §12.13); gap = area.h × clamp(input `gap` ?? 0.02, 0, 0.08) (§12.14); camera row on top (Y-down minY, Y-up maxY − h), screen row the rest at the bottom",
                build: cameraStackRowsCases),
            WebVectorUnit(
                name: "cameraStackZoom",
                notes: "Services/CameraLayoutMath.swift (docs/camera-cutout.md §12.13) — kind `yield`: stackYield(zoom:) = ReactiveCameraLayout.sizeFactor(forZoom:) = 1 − 0.25 × smoothstep((zoom − 1) / 0.5); kind `outer`: outerZoom(_:stacking:) = stacking && zoom > 1 ? 1 : zoom (the layout owns every zoom-in while the stack is on)",
                build: cameraStackZoomCases),
            WebVectorUnit(
                name: "cameraMaskCodec",
                notes: "Services/CameraMaskTrack.swift — a .ccmask written by the Swift encoder (base64): parsed header, per-frame time / delta flag / SHA-256 (hex) of the decoded alpha, and frameIndexAt per query. Case 0 is the contract fixture: 48 frames at 64×36, a moving soft silhouette then a still stretch, keyframeInterval 8",
                build: cameraMaskCodecCases),
        ]
    }

    // MARK: - lookWeights

    private static func cameraLookWeightsCases() -> [WV] {
        var rng = WVRandom(seed: "cameraLookWeights")
        var cases: [WV] = []
        for i in 0..<900 {
            var regions: [CameraLayoutRegion]
            switch i % 9 {
            case 0:
                // Hand-shaped: bubble → cutout → pop-out → cameraOnly(look) → gap.
                let a = rng.edgy(0, 3, edges: [0, 0.04, 0.05, 0.0501])
                let b = a + rng.edgy(0.2, 4, edges: [0.45, 0.3, 0.04])
                let c = b + rng.edgy(0.2, 4, edges: [0.45, 0.02])
                regions = [
                    CameraLayoutRegion(id: rng.uuid(), startTime: a, endTime: b, mode: .bubble, look: .cutout),
                    CameraLayoutRegion(id: rng.uuid(), startTime: b, endTime: c, mode: .bubble, look: .popOut),
                    CameraLayoutRegion(id: rng.uuid(), startTime: c, endTime: c + 2, mode: rng.pick(styleLayoutModes),
                                       look: rng.pick([CameraBubbleLook.cutout, .popOut])),
                ]
            case 1:
                regions = []
            default:
                regions = randomLayoutRegions(&rng, duration: 20)
            }
            var queries: [Double] = [0, -0.5]
            let edges = regions.flatMap { [$0.startTime, $0.endTime] }
            for e in edges.prefix(10) {
                queries.append(e)
                queries.append(rng.pick([e - 0.001, e - 1e-7, e + 1e-7, e + 0.0009]))
                queries.append(e + rng.double(0, 0.45))
                queries.append(e + rng.pick([0.1, 0.225, 0.3, 0.449999, 0.45, 0.4500001, 1.2]))
            }
            for _ in 0..<4 { queries.append(rng.edgy(-1, 22, edges: [0, 0.05, 0.0501, 0.04])) }
            // The whole-video look (Camera panel), from its own stream so
            // every region and query above is unchanged.
            var lookRng = WVRandom(seed: "cameraLookWeights-default-\(i)")
            let defaultLook = lookRng.pick([nil, CameraBubbleLook.cutout, .popOut])
            var input: WV = ["regions": .arr(regions.map(styleRegionWV)), "queries": queries.wv]
            if let defaultLook { input = input.setting("defaultLook", .str(defaultLook.rawValue)) }
            cases.append(vcase(
                input,
                ["results": .arr(queries.map { t in
                    let w = CameraLayoutMath.lookWeights(at: t, regions: regions, defaultLook: defaultLook)
                    return ["cutout": w.cutout.wv, "popOut": w.popOut.wv]
                })]
            ))
        }
        // The vertical stack (§12.12), appended from its own stream so the
        // cases above are unchanged: the stacked row wears the whole-video
        // look outside regions and on Side by Side.
        var stackRng = WVRandom(seed: "cameraLookWeights-stacking")
        for _ in 0..<300 {
            let regions = randomLayoutRegions(&stackRng, duration: 20)
            var queries: [Double] = [0, -0.5]
            for e in regions.flatMap({ [$0.startTime, $0.endTime] }).prefix(10) {
                queries.append(e)
                queries.append(stackRng.pick([e - 0.001, e + 1e-7]))
                queries.append(e + stackRng.double(0, 0.45))
                queries.append(e + stackRng.pick([0.1, 0.225, 0.449999, 0.45, 1.2]))
            }
            for _ in 0..<4 { queries.append(stackRng.edgy(-1, 22, edges: [0, 0.05, 0.0501])) }
            let defaultLook = stackRng.pick([nil, CameraBubbleLook.cutout, .popOut])
            var input: WV = ["regions": .arr(regions.map(styleRegionWV)), "queries": queries.wv, "stacking": .bool(true)]
            if let defaultLook { input = input.setting("defaultLook", .str(defaultLook.rawValue)) }
            cases.append(vcase(
                input,
                ["results": .arr(queries.map { t in
                    let w = CameraLayoutMath.lookWeights(at: t, regions: regions, defaultLook: defaultLook, stacking: true)
                    return ["cutout": w.cutout.wv, "popOut": w.popOut.wv]
                })]
            ))
        }
        return cases
    }

    // MARK: - geometry

    private static func rectOrNull(_ r: CGRect?) -> WV { r.map { $0.wv } ?? .null }

    private static func cameraCutoutGeometryCases() -> [WV] {
        var rng = WVRandom(seed: "cameraCutoutGeometry")
        let aspectEdges: [Double] = [16.0 / 9, 4.0 / 3, 1, 9.0 / 16, 3.0 / 4, 0, -1, 1e-6, 100]
        var cases: [WV] = []
        for i in 0..<1200 {
            let look: CameraBubbleLook = i % 2 == 0 ? .cutout : .popOut
            let rect: CGRect
            switch i % 23 {
            case 0: rect = CGRect(x: rng.double(-20, 20), y: rng.double(-20, 20), width: 0, height: rng.double(0, 50))
            case 1: rect = CGRect(x: 0, y: 0, width: rng.double(0, 2), height: rng.double(0, 2))
            default: rect = rng.rect(origin: -100, 1800, size: 4, 900)
            }
            let aspect = rng.edgy(0.3, 3, edges: aspectEdges, edgeP: 0.25)
            let g = CameraCutoutMath.geometry(look: look, bubbleRect: rect, cameraAspect: aspect)
            cases.append(vcase(
                ["look": .str(look.rawValue), "bubbleRect": rect.wv, "cameraAspect": aspect.wv],
                [
                    "personRect": g.personRect.wv,
                    "clipRect": g.clipRect.wv,
                    "clipBottomCornerRadius": g.clipBottomCornerRadius.wv,
                    "cardRect": rectOrNull(g.cardRect),
                    "cardCornerRadius": g.cardCornerRadius.wv,
                    "cardBorderWidth": g.cardBorderWidth.wv,
                ]
            ))
        }
        // §12.2: pop-out amount + border thickness, from their own stream so
        // the cases above are unchanged.
        var styleRng = WVRandom(seed: "cameraCutoutGeometry-styles")
        for i in 0..<600 {
            let look: CameraBubbleLook = i % 4 == 0 ? .cutout : .popOut
            let rect = i % 17 == 0
                ? CGRect(x: 0, y: 0, width: styleRng.double(0, 3), height: styleRng.double(0, 3))
                : styleRng.rect(origin: -100, 1800, size: 4, 900)
            let aspect = styleRng.edgy(0.3, 3, edges: [16.0 / 9, 4.0 / 3, 1, 9.0 / 16], edgeP: 0.3)
            let amount: Double? = i % 5 == 0 ? nil : styleRng.edgy(-0.5, 1.5, edges: [0, 0.5, 1, 0.25, 0.75], edgeP: 0.3)
            let border: Double? = i % 3 == 0 ? nil : styleRng.edgy(-0.5, 1.5, edges: [0, 0.5, 1, 0.01], edgeP: 0.3)
            let g = CameraCutoutMath.geometry(look: look, bubbleRect: rect, cameraAspect: aspect,
                                              popOutAmount: amount, cardBorderWidth: border)
            var input: WV = ["look": .str(look.rawValue), "bubbleRect": rect.wv, "cameraAspect": aspect.wv]
            if let amount { input = input.setting("popOutAmount", amount.wv) }
            if let border { input = input.setting("cardBorderWidth", border.wv) }
            cases.append(vcase(input, [
                "personRect": g.personRect.wv,
                "clipRect": g.clipRect.wv,
                "clipBottomCornerRadius": g.clipBottomCornerRadius.wv,
                "cardRect": rectOrNull(g.cardRect),
                "cardCornerRadius": g.cardCornerRadius.wv,
                "cardBorderWidth": g.cardBorderWidth.wv,
            ]))
        }
        return cases
    }

    // MARK: - stack rows (§12.12)

    private static func cameraStackRowsCases() -> [WV] {
        var rng = WVRandom(seed: "cameraStackRows")
        return (0..<400).map { i in
            let area = i % 19 == 0
                ? CGRect(x: 0, y: 0, width: rng.double(0, 4), height: rng.double(0, 4))
                : rng.rect(origin: -100, 300, size: 1, 2400)
            let ratio = rng.edgy(-0.5, 1.5, edges: [0.25, 0.42, 0.7, 0, 1], edgeP: 0.3)
            let up = rng.bool()
            let rows = CameraLayoutMath.stackRows(area: area, ratio: ratio, yAxisIsUp: up)
            return vcase(["area": area.wv, "ratio": ratio.wv, "yAxisIsUp": up.wv],
                         ["camera": rows.camera.wv, "screen": rows.screen.wv])
        } + yieldedStackRowsCases()
    }

    /// §12.13: the camera row yielding to a zoom — its own stream, so the
    /// cases above are unchanged.
    private static func yieldedStackRowsCases() -> [WV] {
        var rng = WVRandom(seed: "cameraStackRows-yield")
        return (0..<200).map { _ in
            let area = rng.rect(origin: -100, 300, size: 1, 2400)
            let ratio = rng.edgy(0, 1, edges: [0.25, 0.42, 0.7], edgeP: 0.3)
            let up = rng.bool()
            let yield = rng.edgy(0.7, 1, edges: [0.75, 1], edgeP: 0.3)
            // §12.14: the stored gap (absent / clamped / joined at 0).
            let gap: Double? = rng.bool(0.25) ? nil : rng.edgy(-0.05, 0.12, edges: [0, 0.02, 0.08], edgeP: 0.4)
            let rows = CameraLayoutMath.stackRows(area: area, ratio: ratio, yAxisIsUp: up, yield: yield, gap: gap)
            var input: WV = ["area": area.wv, "ratio": ratio.wv, "yAxisIsUp": up.wv, "yield": yield.wv]
            if let gap { input = input.setting("gap", gap.wv) }
            return vcase(input, ["camera": rows.camera.wv, "screen": rows.screen.wv])
        }
    }

    // MARK: - zoom inside the stack (§12.13)

    private static func cameraStackZoomCases() -> [WV] {
        var rng = WVRandom(seed: "cameraStackZoom")
        var cases: [WV] = []
        for _ in 0..<120 {
            let zoom = rng.edgy(0.5, 3.5, edges: [1, 1.25, 1.5, 0.999, 1.0001], edgeP: 0.3)
            cases.append(vcase(["kind": .str("yield"), "zoom": zoom.wv],
                               ["yield": CameraLayoutMath.stackYield(zoom: zoom).wv]))
        }
        for i in 0..<120 {
            let zoom = rng.edgy(0.4, 3.5, edges: [1, 0.999, 1.0001, 2.4], edgeP: 0.3)
            let stacking = i % 3 != 0
            cases.append(vcase(["kind": .str("outer"), "zoom": zoom.wv, "stacking": stacking.wv],
                               ["zoom": CameraLayoutMath.outerZoom(zoom, stacking: stacking).wv]))
        }
        return cases
    }

    // MARK: - mask edge (§12.4)

    private static func cameraMaskEdgeCases() -> [WV] {
        var rng = WVRandom(seed: "cameraMaskEdge")
        // (width, height): small frames, producer-height frames (k = 1), and
        // one 288-row frame (k = 1.5) — radii only grow past 1 at tall masks.
        let sizes: [(Int, Int)] = [(16, 9), (33, 36), (64, 36), (12, 192), (24, 192), (40, 192), (8, 288), (17, 288)]
        let levels: [(Double, Double)] = [(0, 0), (0, 1), (1, 0), (1, 1), (0.5, 0.5), (1.0 / 12, 1.0 / 12), (0.25, 0.75), (2, -1)]
        var cases: [WV] = []
        for (n, size) in sizes.enumerated() {
            let (w, h) = size
            for (m, level) in levels.enumerated() where (n + m) % 2 == 0 || m < 4 {
                // A soft ellipse with jitter plus a hard bar — edges both ways.
                var alpha = [UInt8](repeating: 0, count: w * h)
                let cx = rng.double(0.3, 0.7), cy = rng.double(0.3, 0.7)
                let rx = rng.double(0.15, 0.45), ry = rng.double(0.15, 0.45)
                for y in 0..<h {
                    for x in 0..<w {
                        let dx = ((Double(x) + 0.5) / Double(w) - cx) / rx
                        let dy = ((Double(y) + 0.5) / Double(h) - cy) / ry
                        let d = (dx * dx + dy * dy).squareRoot()
                        var v = min(1, max(0, (1.05 - d) / 0.1)) * 255
                        if x == w / 5 { v = 255 }
                        v += rng.double(-6, 6)
                        alpha[y * w + x] = UInt8(min(255, max(0, v.rounded())))
                    }
                }
                let out = CameraMaskEdge.process(alpha, width: w, height: h, softness: level.0, inset: level.1)
                cases.append(vcase(
                    ["width": w.wv, "height": h.wv, "base64": .str(Data(alpha).base64EncodedString()),
                     "softness": level.0.wv, "inset": level.1.wv],
                    ["base64": .str(Data(out).base64EncodedString())]
                ))
            }
        }
        return cases
    }

    // MARK: - codec

    private static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// One codec case: encode `frames` with the Swift encoder, then describe
    /// what a correct decoder must produce.
    private static func codecCase(
        width: Int, height: Int, keyframeInterval: Int,
        sourceDuration: Double, sourceByteSize: Double,
        frames: [(time: Double, alpha: [UInt8])], queries: [Double]
    ) -> WV {
        guard let data = try? CameraMaskTrack.encode(
            width: width, height: height, keyframeInterval: keyframeInterval,
            sourceDuration: sourceDuration, sourceByteSize: sourceByteSize, frames: frames),
              let track = try? CameraMaskTrack(data: data) else { return .null }
        let decoder = CameraMaskTrack.Decoder(track: track)
        var frameRows: [WV] = []
        for (i, entry) in track.index.enumerated() {
            let alpha = (try? decoder.frame(i)) ?? []
            // The encoder is lossless by contract — never emit a vector that
            // contradicts its own input.
            precondition(alpha == frames[i].alpha, "cameraMaskCodec: frame \(i) did not round-trip")
            frameRows.append(["time": entry.time.wv, "delta": entry.delta.wv, "sha256": .str(sha256Hex(alpha))])
        }
        let h = track.header
        return vcase(
            ["base64": .str(data.base64EncodedString()), "queries": queries.wv],
            [
                "header": [
                    "width": .int(h.width), "height": .int(h.height),
                    "keyframeInterval": .int(h.keyframeInterval), "frameCount": .int(h.frameCount),
                    "sourceDuration": h.sourceDuration.wv, "sourceByteSize": h.sourceByteSize.wv,
                ],
                "frames": .arr(frameRows),
                "lookups": .arr(queries.map { .int(track.frameIndex(at: $0)) }),
            ]
        )
    }

    private static func cameraMaskCodecCases() -> [WV] {
        var rng = WVRandom(seed: "cameraMaskCodec")
        func queries(for frames: [(time: Double, alpha: [UInt8])]) -> [Double] {
            var q: [Double] = [-1, 0]
            for f in frames {
                q.append(f.time)
                q.append(f.time - 1e-6)
                q.append(f.time + rng.double(0, 0.03))
            }
            q.append((frames.last?.time ?? 0) + 5)
            return q
        }
        // 0 — THE contract fixture (≥ 40 frames, 64×36, moving then still, kfi 8).
        let fixture = CameraLayoutHarness.syntheticMaskFrames(width: 64, height: 36, count: 48)
        // 1 — every frame a key (keyframeInterval 1).
        let keysOnly = CameraLayoutHarness.syntheticMaskFrames(width: 32, height: 18, count: 12)
        // 2 — one frame, odd size; 3 — noise (deltas never win), uneven times.
        let single = CameraLayoutHarness.syntheticMaskFrames(width: 17, height: 9, count: 1)
        var noise: [(time: Double, alpha: [UInt8])] = []
        var t = 0.25
        for _ in 0..<10 {
            noise.append((t, (0..<(20 * 12)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }))
            t += rng.pick([1.0 / 30, 1.0 / 60, 0.5, 1e-4])
        }
        return [
            codecCase(width: 64, height: 36, keyframeInterval: 8, sourceDuration: 1.6, sourceByteSize: 1_234_567,
                      frames: fixture, queries: queries(for: fixture)),
            codecCase(width: 32, height: 18, keyframeInterval: 1, sourceDuration: 0.4, sourceByteSize: 99,
                      frames: keysOnly, queries: queries(for: keysOnly)),
            codecCase(width: 17, height: 9, keyframeInterval: 15, sourceDuration: 0.033, sourceByteSize: 1,
                      frames: single, queries: queries(for: single)),
            codecCase(width: 20, height: 12, keyframeInterval: 4, sourceDuration: 2, sourceByteSize: 4096,
                      frames: noise, queries: queries(for: noise)),
        ]
    }
}
