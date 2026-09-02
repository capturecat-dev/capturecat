import CoreGraphics
import Foundation

/// Motion: one-click cinematic animation for still-image captures.
///
/// A static screenshot becomes a short animated clip via a FOUR-CORNER TOUR —
/// the signature look: the camera establishes wide over the padded canvas,
/// pushes into the first corner, glides clockwise through the remaining
/// corners (top-left → top-right → bottom-right → bottom-left) with a slight
/// 3D tilt leaning into each corner, then settles back wide for the tail.
/// Corner segments are CONTIGUOUS, so the camera glides laterally between
/// corners instead of dipping back out between stops.
///
/// The output is ordinary `ZoomRegion`s (+ gentle `TiltRegion`s) on the
/// timeline — the user drags/trims/deletes them like any other block, and the
/// existing preview/export paths render them; nothing new is drawn here.
///
/// Everything is DETERMINISTIC and synchronous: focal points are fixed
/// quadrant anchors inset from each corner; depth and tilt direction derive
/// from the corner index, never randomness or image analysis.
enum StillMotionComposer {

    // MARK: - Tuning

    enum Tuning {
        /// Fraction of the timeline held wide before the first push-in.
        static let wideHoldFraction = 0.12
        /// Fraction of the timeline held wide after the last pull-back.
        static let tailFraction = 0.18
        /// Focal inset from each corner (fraction of the frame).
        static let cornerInset = 0.23
        /// Depth alternates gently by corner index — a calm 1.8/2.0 pulse.
        static let zoomLevels: [Double] = [1.9, 2.0, 1.8, 2.0]
        /// Slight skew leaning into the corner; degrees.
        static let yawMagnitude = 2.5
        static let pitchMagnitude = 1.5
        /// A segment shorter than this reads as a glitch — tour fewer corners.
        static let minSegmentDuration: TimeInterval = 1.0
        /// Focal keeps this margin inside the visible-viewport clamp.
        static let edgeMargin = 0.02
    }

    struct Plan {
        var zoomRegions: [ZoomRegion]
        var tiltRegions: [TiltRegion]
    }

    /// The clockwise reading sweep: TL → TR → BR → BL, as normalized
    /// (Y-down) focal points inset from each corner.
    static var cornerTour: [CGPoint] {
        let lo = Tuning.cornerInset, hi = 1 - Tuning.cornerInset
        return [
            CGPoint(x: lo, y: lo),  // top-left
            CGPoint(x: hi, y: lo),  // top-right
            CGPoint(x: hi, y: hi),  // bottom-right
            CGPoint(x: lo, y: hi),  // bottom-left
        ]
    }

    // MARK: - Composition (pure)

    /// Lays the tour onto the timeline: wide hold → four contiguous corner
    /// segments (glide between adjacent corners, no dip out) → pull back wide.
    static func compose(duration: TimeInterval) -> Plan {
        guard duration > 1 else { return Plan(zoomRegions: [], tiltRegions: []) }

        let corners = cornerTour
        let journeyStart = duration * Tuning.wideHoldFraction
        let journeyEnd = duration * (1 - Tuning.tailFraction)

        // Four corners when the clip allows; deterministically drop trailing
        // corners on very short clips rather than composing glitch segments.
        var count = corners.count
        func segmentLength(for n: Int) -> TimeInterval {
            (journeyEnd - journeyStart) / Double(n)
        }
        while count > 1, segmentLength(for: count) < Tuning.minSegmentDuration {
            count -= 1
        }
        let segment = segmentLength(for: count)
        guard segment > 0.3 else { return Plan(zoomRegions: [], tiltRegions: []) }

        var zooms: [ZoomRegion] = []
        var tilts: [TiltRegion] = []
        for index in 0..<count {
            let corner = corners[index]
            let start = journeyStart + Double(index) * segment
            let end = start + segment
            let zoomLevel = Tuning.zoomLevels[index % Tuning.zoomLevels.count]
            zooms.append(ZoomRegion(
                startTime: start,
                endTime: end,
                zoomLevel: zoomLevel,
                focalPoint: clampFocal(corner, zoomLevel: zoomLevel),
                animationStyle: .cinematic,
                followsCursor: false,
                isAuto: true
            ))
            // Lean INTO the corner: yaw positive tips the left edge back,
            // pitch positive tips the top edge back — sign follows which
            // half of the frame the corner sits in.
            let yawSign: Double = corner.x < 0.5 ? 1 : -1
            let pitchSign: Double = corner.y < 0.5 ? 1 : -1
            tilts.append(TiltRegion(
                startTime: start,
                endTime: end,
                pitch: Tuning.pitchMagnitude * pitchSign,
                yaw: Tuning.yawMagnitude * yawSign,
                roll: 0,
                animationStyle: .cinematic
            ))
        }
        return Plan(zoomRegions: zooms, tiltRegions: tilts)
    }

    /// Same clamp rule as AutoZoomGenerator: the zoomed viewport must stay
    /// fully inside the frame (half-extent 0.5/z plus a margin).
    static func clampFocal(_ focal: CGPoint, zoomLevel: Double) -> CGPoint {
        let halfVisible = 0.5 / max(1.0, zoomLevel)
        let lower = halfVisible + Tuning.edgeMargin
        let upper = 1 - halfVisible - Tuning.edgeMargin
        guard lower < upper else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: max(lower, min(upper, focal.x)),
            y: max(lower, min(upper, focal.y)))
    }
}

/// Applies Motion to a still-capture project: composes the corner tour for
/// the project's duration and installs the regions. One implementation shared
/// by the editor's Motion entry and the MCP `auto_zoom` tool for image
/// projects — the same rule as AutoZoomApplier: call sites must not drift.
enum StillMotionApplier {

    /// Installs a plan: previously generated Motion/auto zoom regions are
    /// replaced (isAuto == true), along with the tilt spans that mirror them;
    /// the user's hand-placed blocks stay untouched. Returns the number of
    /// regions created (0 = empty plan, project untouched).
    @discardableResult
    static func install(_ plan: StillMotionComposer.Plan, into project: Project) -> Int {
        guard !plan.zoomRegions.isEmpty else { return 0 }
        let removedAuto = project.zoomRegions.filter { $0.isAuto == true }
        project.zoomRegions.removeAll { $0.isAuto == true }
        // Tilts have no isAuto flag (no model change): a tilt is ours iff its
        // span exactly mirrors a removed auto zoom — how Motion creates them.
        project.tiltRegions.removeAll { tilt in
            removedAuto.contains {
                abs($0.startTime - tilt.startTime) < 0.001
                    && abs($0.endTime - tilt.endTime) < 0.001
            }
        }
        project.zoomRegions.append(contentsOf: plan.zoomRegions)
        project.zoomRegions.sort { $0.startTime < $1.startTime }
        project.tiltRegions.append(contentsOf: plan.tiltRegions)
        project.tiltRegions.sort { $0.startTime < $1.startTime }
        return plan.zoomRegions.count
    }

    /// Compose + install in one synchronous call.
    @discardableResult
    static func apply(to project: Project) -> Int {
        install(StillMotionComposer.compose(duration: project.duration), into: project)
    }
}
