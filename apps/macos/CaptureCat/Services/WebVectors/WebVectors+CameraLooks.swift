import CoreGraphics
import CryptoKit
import Foundation

// Golden-vector units for the camera LOOKS (docs/camera-cutout.md §10):
//   cameraLookWeights    — CameraLayoutMath.lookWeights(at:regions:)
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
                notes: "Services/CameraLayoutMath.swift — lookWeights(at:regions:) (look(at:) via region(at:) + CameraLayoutRegion.effectiveLook; ease; transitionDuration; edges ≤ 0.05 s never morph). Regions as project.json (look optional, also on non-bubble modes where it is ignored); queries cluster on edges, mid-fade and settled",
                build: cameraLookWeightsCases),
            WebVectorUnit(
                name: "cameraCutoutGeometry",
                notes: "Services/CameraCutoutMath.swift — geometry(look:bubbleRect:cameraAspect:) in Y-down: personRect = aspectFill(cameraAspect, B), clipRect = B, pop-out card = B minus a 22% headroom off its top, radius 16% of the card's short side (clip bottom corners only)",
                build: cameraCutoutGeometryCases),
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
            cases.append(vcase(
                ["regions": .arr(regions.map(styleRegionWV)), "queries": queries.wv],
                ["results": .arr(queries.map { t in
                    let w = CameraLayoutMath.lookWeights(at: t, regions: regions)
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
                ]
            ))
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
