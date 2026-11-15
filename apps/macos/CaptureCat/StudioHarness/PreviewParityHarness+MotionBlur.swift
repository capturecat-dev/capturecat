#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreImage
import Foundation
import QuartzCore

/// `--preview-parity`, motion blur in PIXELS (Studio 2d).
///
/// MotionBlurMath decides radius and angle for both sides; this checks that
/// the preview then DRAWS that blur the way the exporter does: CIMotionBlur
/// over the zoomed card, radius × canvas width in output (screen) space,
/// along the motion, on gamma-encoded values (the exporter's working space is
/// the source's, non-linear).
///
/// Mid-pan with blur on, the preview's frame is captured; the same tick is
/// captured again with blur off (springs untouched) and blurred by Core Image
/// in the exporter's convention. Inside the card — farther from its edges
/// than the blur reaches, so the backdrop never enters — the two must agree.
/// Before 2d the preview differed in all three respects (local-space radius,
/// vertically mirrored angle, linear light — PreviewCompositorCore
/// .renderMotionBlur); each is re-injected and must fail the same bars.
///
/// iOS runs the same script: its CoreAnimation ignores layer filters, so the
/// iOS stage applies the blur itself (paused/scrubbing — the owner-approved
/// playback exception) and must pass the same comparison.
extension PreviewParityHarness {
    @MainActor
    static func motionBlurPixelChecks(
        fixture: Fixture,
        compositor: PreviewCompositorView,
        container: HarnessView,
        t0: TimeInterval,
        artifacts: URL,
        reset: ((ProjectSettings) -> Void) -> Void
    ) async -> Int {
        var failures = 0
        func expect(_ name: String, _ ok: Bool, _ detail: String) {
            print("MOTIONBLUR-PIXELS \(name) \(detail) \(ok ? "PASS" : "FAIL")")
            if !ok { failures += 1 }
        }
        let seqStart = t0 + 0.4

        func capture(_ name: String) async -> CGImage? {
            compositor.schedule(compositorInput(fixture))
            await settle(0.35)
            compositor.schedule(compositorInput(fixture))
            await settle(0.35)
            guard let layer = container.harnessLayer,
                  let image = CARendererSnapshot.render(layer: layer, size: container.bounds.size, scale: 1)
            else { return nil }
            savePNG(image, artifacts.appendingPathComponent("\(name)-ca.png"))
            return image
        }

        struct Score { var mean: Double; var over8: Double; var zoom: Double; var radiusPx: Double; var angle: Double }

        /// Blur on at full strength, the 2× pan starting at `seqStart`,
        /// ticked at 30 Hz (checkSequence's cadence) to +`offset`.
        func measure(_ label: String, offset: TimeInterval) async -> Score? {
            reset { s in
                s.motionBlur = true
                s.motionBlurStrength = 1
                s.animationSpeed = .rapid
                fixture.project.zoomRegions = motionBlurPanRegions(at: seqStart)
            }
            fixture.currentTime = seqStart - 0.8
            await settle(0.4)
            compositor.schedule(compositorInput(fixture))
            await settle(0.2)
            var t = seqStart - 0.8
            let step = 1.0 / 30.0
            while t + step / 2 < seqStart + offset {
                t += step
                fixture.currentTime = t
                compositor.schedule(compositorInput(fixture))
                await settle(0.05)
            }
            let zoom = compositor.motion.zoom
            guard let blurred = await capture("motionblur-\(label)-blurred") else { return nil }
            let blur = compositor.core.appliedMotionBlur
            // Same tick, blur off: the crisp frame the exporter would blur.
            fixture.project.settings.motionBlur = false
            guard let crisp = await capture("motionblur-\(label)-crisp") else { return nil }
            let radiusPx = blur.radius * Double(container.bounds.width)
            guard blur.active,
                  let reference = exporterMotionBlur(crisp, radiusPx: radiusPx, angle: blur.angle)
            else { return Score(mean: -1, over8: -1, zoom: zoom, radiusPx: radiusPx, angle: blur.angle) }
            savePNG(reference, artifacts.appendingPathComponent("motionblur-\(label)-reference-ca.png"))
            guard let (mean, over8) = interiorDelta(blurred, reference) else { return nil }
            return Score(mean: mean, over8: over8, zoom: zoom, radiusPx: radiusPx, angle: blur.angle)
        }

        func line(_ s: Score) -> String {
            String(format: "zoom=%.3f r=%.2fpx angle=%.3f · interior vs exporter blur: mean %.3f/255, %.2f%% px>8",
                   s.zoom, s.radiusPx, s.angle, s.mean, s.over8 * 100)
        }

        func passes(_ s: Score) -> Bool {
            s.mean >= 0 && s.mean <= motionBlurMeanBar && s.over8 <= motionBlurOver8Bar
        }
        // The gate: mid-pan, zoomed — where every pre-2d defect shows.
        if let s = await measure("mid", offset: 0.15) {
            expect("preview-equals-exporter-blur", s.zoom > 1.3 && s.radiusPx > 4 && passes(s), line(s))
        } else {
            expect("preview-equals-exporter-blur", false, "capture failed")
        }

        // Self-tests: each pre-2d defect must fail the same bars.
        let defects: [(String, PreviewCompositorCore.MotionBlurDefect)] = [
            ("localspace", .localSpace), ("mirrored-angle", .mirroredAngle), ("linear-light", .linearLight),
        ]
        for (label, defect) in defects {
            PreviewCompositorCore.debugMotionBlurDefect = defect
            if let s = await measure("selftest-\(label)", offset: 0.15) {
                expect("selftest-\(label)-defect-fails", !passes(s), line(s))
            } else {
                expect("selftest-\(label)-defect-fails", false, "capture failed")
            }
            PreviewCompositorCore.debugMotionBlurDefect = nil
        }
        fixture.project.settings.motionBlur = false
        return failures
    }

    /// Two adjacent 2× zooms, focal (0.3, 0.4) then (0.7, 0.6): at Rapid
    /// speed the zoom has settled at 2× before `t` (checkSequence rewinds to
    /// t − 0.8), then the camera pans fast across the card — strong
    /// translational blur at a zoom where a local-space radius doubles it.
    static func motionBlurPanRegions(at t: TimeInterval) -> [ZoomRegion] {
        [ZoomRegion(startTime: t - 3, endTime: t, zoomLevel: 2.0, focalPoint: CGPoint(x: 0.3, y: 0.4)),
         ZoomRegion(startTime: t, endTime: t + 4, zoomLevel: 2.0, focalPoint: CGPoint(x: 0.7, y: 0.6))]
    }

    /// Bars for the interior comparison (2d, measured on the Mac): with the
    /// conventions right, CA's blur and Core Image's agree to resampling
    /// noise (CA blurs the zoom group before its transform); every injected
    /// defect lands far outside.
    static let motionBlurMeanBar = 1.0
    static let motionBlurOver8Bar = 0.01

    /// VideoExporter's motion blur, verbatim in convention: clamp to extent,
    /// CIMotionBlur(radius px), crop back, on gamma-encoded values (no
    /// working space — the capture's encoded values are blurred directly, as
    /// in the exporter's non-linear working space).
    ///
    /// Angle: the exporter passes `−angle` because its CIImage is upright
    /// (Y-up). Harness captures are in CARenderer's row order — Y-FLIPPED
    /// relative to the screen (iOS captures are flipped into it too) — so
    /// CI's up axis is the screen's DOWN axis and the Y-down angle goes in
    /// as is.
    static func exporterMotionBlur(_ image: CGImage, radiusPx: Double, angle: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let blurred = CIFilter(name: "CIMotionBlur", parameters: [
            kCIInputImageKey: input.clampedToExtent(),
            kCIInputRadiusKey: radiusPx,
            kCIInputAngleKey: angle,
        ])?.outputImage?.cropped(to: input.extent) else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        return context.createCGImage(blurred, from: input.extent, format: .RGBA8,
                                     colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Mean |Δ| and the fraction of pixels over 8/255 in the central 40 % ×
    /// 40 % of the frame — inside the card at any zoom ≥ 1, and more than a
    /// full blur ramp from its edges.
    static func interiorDelta(_ a: CGImage, _ b: CGImage) -> (Double, Double)? {
        guard let pa = HarnessPixels.rgba(a), let pb = HarnessPixels.rgba(b),
              pa.width == pb.width, pa.height == pb.height else { return nil }
        defer { pa.deallocate(); pb.deallocate() }
        let x0 = pa.width * 3 / 10, x1 = pa.width * 7 / 10
        let y0 = pa.height * 3 / 10, y1 = pa.height * 7 / 10
        var sum = 0, over = 0, n = 0
        for y in y0..<y1 {
            let ra = pa.bytes + y * pa.bytesPerRow, rb = pb.bytes + y * pb.bytesPerRow
            for x in x0..<x1 {
                let i = x * 4
                let d = max(abs(Int(ra[i]) - Int(rb[i])), abs(Int(ra[i + 1]) - Int(rb[i + 1])),
                            abs(Int(ra[i + 2]) - Int(rb[i + 2])))
                sum += d; n += 1
                if d > 8 { over += 1 }
            }
        }
        return n == 0 ? nil : (Double(sum) / Double(n), Double(over) / Double(n))
    }
}
