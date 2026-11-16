import CoreGraphics
import Foundation

// Moved verbatim from the Mac timeline canvas (TimelineCanvasView.swift,
// TimelineLaneAccordion.swift) in Studio 4c so the iOS timeline draws and
// hit-tests from the SAME lane model, metrics and geometry.

// MARK: - Snapshot (one-way data in)

/// One block on the FOCUS lane, already mapped into output time.
struct TimelineFocusItem: Equatable {
    var id: UUID
    var isHighlight: Bool
    var startTime: TimeInterval
    var endTime: TimeInterval
    var label: String
    var isSelected: Bool
}

/// One context-menu row a lane block contributes (title, checkmark,
/// enabled, action); a nil action is a separator.
struct TimelineMenuEntry {
    var title: String = ""
    var checked = false
    var isEnabled = true
    var action: (() -> Void)?

    static let separator = TimelineMenuEntry()
}

/// One block on the ANNOTATE lane, already mapped into output time.
struct TimelineAnnotateItem: Equatable {
    var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// Short type label ("Text", "Tap"…) — the block caption.
    var label: String
    /// SF Symbol name for the type glyph.
    var icon: String
    var isSelected: Bool
}

/// Immutable value the AppKit canvas renders from. All times are OUTPUT time
/// (post speed-map); the SwiftUI side converts to source time at every
/// callback boundary, so the canvas never touches the model or the time map.
struct TimelineCanvasSnapshot: Equatable {
    var outputDuration: TimeInterval
    var playheadOutputTime: TimeInterval
    /// Slice hover snapped onto the playhead — line turns red, same as SwiftUI.
    var playheadIsRed: Bool
    /// The playhead grab strip is disabled while the slice tool owns the lane.
    var playheadHitTestEnabled: Bool
    /// Pre-formatted scrub readout (e.g. "0:02.4"), computed by TimelineView.
    var scrubLabel: String
    var effectItems: [EffectBlockItem]
    /// Intro Slide chip pinned to the head of the EFFECTS lane — end time in
    /// output seconds (nil = intro off) and its label ("Intro · Bottom").
    var introChipStart: TimeInterval = 0
    var introChipEnd: TimeInterval? = nil
    var introChipSelected: Bool = false
    var introChipLabel: String = ""
    var introChipIcon: String = "arrow.up.to.line"
    /// Curtain Unveil chip on the EFFECTS lane — end time in output seconds
    /// (nil = curtain off). Label/icon are fixed ("Curtain" / book.pages).
    var curtainChipStart: TimeInterval = 0
    var curtainChipEnd: TimeInterval? = nil
    var curtainChipSelected: Bool = false
    var selectedZoomID: UUID?
    var selectedTiltID: UUID?
    var focusItems: [TimelineFocusItem]
    var annotateItems: [TimelineAnnotateItem]
    var trimStartOutput: TimeInterval
    var trimEndOutput: TimeInterval
    /// Slice tool armed — the VIDEO lane swaps its drag gestures for the
    /// crosshair cut indicator, exactly like the SwiftUI overlay did.
    var sliceArmed: Bool = false
    /// Still capture in Image treatment with NO timed effects — "there is no
    /// time". The video block reads as one full-width slab (scale is pinned to
    /// 1 by the controller), the ruler drops to a bare baseline and the
    /// playhead hides while idle — but scrubbing still works, and the line
    /// shows during the interaction. The underlying time mapping is UNCHANGED:
    /// effect blocks keep their exact positions and drag math. The moment a
    /// timed effect exists this goes false (playhead/scrub behave exactly as
    /// video; see `dimmedRuler`).
    var timelessVideo: Bool = false
    /// Still capture in Image treatment WITH timed effects: full video-style
    /// playhead and scrubbing, ruler ticks slightly dimmed (labels stay
    /// legible) as the one remaining hint of the Image treatment.
    var dimmedRuler: Bool = false
}

// MARK: - Callbacks (mutations out)

/// Every mutation routes through these closures into the SAME TimelineView
/// functions the SwiftUI lanes used, so undo registration and lane rules are
/// reused verbatim. Times passed here are OUTPUT time; the wrappers convert.
struct TimelineCanvasCallbacks {
    var scrub: (CGFloat) -> Void
    var seek: (CGFloat) -> Void
    var selectEffect: (UUID?, UUID?) -> Void
    /// Click on the Intro chip — opens the Motion pane where the entrance
    /// direction and length live.
    var openIntro: () -> Void = {}
    var deleteIntro: () -> Void = {}
    /// Live drag of the Intro chip's right edge — new END in output seconds.
    var resizeIntro: (TimeInterval) -> Void = { _ in }
    /// Live drag of the whole chip — new START in output seconds.
    var moveIntro: (TimeInterval) -> Void = { _ in }
    /// Click on the Curtain chip — opens the Effects pane.
    var openCurtain: () -> Void = {}
    var deleteCurtain: () -> Void = {}
    /// Live drag of the Curtain chip's right edge — new END in output seconds.
    var resizeCurtain: (TimeInterval) -> Void = { _ in }
    /// Live drag of the whole Curtain chip — new START in output seconds.
    var moveCurtain: (TimeInterval) -> Void = { _ in }
    var commitEffectTimes: (UUID?, UUID?, TimeInterval, TimeInterval) -> Void
    var setZoomLevel: (UUID, Double) -> Void
    var addZoomToBlock: (UUID) -> Void
    var addTiltToBlock: (UUID) -> Void
    var removeZoom: (UUID) -> Void
    var removeTilt: (UUID) -> Void
    var deleteEffectBlock: (UUID?, UUID?) -> Void
    var addZoomAt: (TimeInterval) -> Void
    var addTiltAt: (TimeInterval) -> Void
    var selectFocus: (UUID?, Bool) -> Void
    var commitFocusTimes: (UUID, Bool, TimeInterval, TimeInterval) -> Void
    var deleteFocus: (UUID, Bool) -> Void
    /// Extra entries for a FOCUS block's context menu, above Delete (camera
    /// layout blocks: side + Copy / Paste Layout). Empty = none.
    var focusMenuExtras: (UUID) -> [TimelineMenuEntry] = { _ in [] }
    var addBlurAt: (TimeInterval) -> Void
    var addHighlightAt: (TimeInterval) -> Void
    var selectAnnotation: (UUID?) -> Void
    var commitAnnotationTimes: (UUID, TimeInterval, TimeInterval) -> Void
    var deleteAnnotation: (UUID) -> Void
    var addAnnotationAt: (AnnotationType, TimeInterval) -> Void
    /// Keyboard, handled natively by the canvas (it becomes first responder
    /// on click, which starves SwiftUI's .onKeyPress chain).
    var deleteSelection: () -> Void = {}
    var togglePlayback: () -> Void = {}
}

// MARK: - Shared metrics

/// Mirrors TimelineView's layout constants exactly — one source of numbers for
/// both drawing and hit testing. Flipped coordinates: y grows downward.
enum TimelineCanvasMetrics {
    static let rulerHeight: CGFloat = 22
    static let rulerBottomSpacing: CGFloat = 6
    static let trackHeight: CGFloat = 48
    static let trackSpacing: CGFloat = 4
    static let bottomInset: CGFloat = 12

    static let videoLaneY: CGFloat = rulerHeight + rulerBottomSpacing               // 28
    static let voiceLaneY: CGFloat = videoLaneY + trackHeight + trackSpacing        // 80
    static let effectsLaneY: CGFloat = voiceLaneY + trackHeight + trackSpacing      // 132
    static let focusLaneY: CGFloat = effectsLaneY + trackHeight + trackSpacing      // 184
    static let annotateLaneY: CGFloat = focusLaneY + trackHeight + trackSpacing     // 236
    static let tracksBottom: CGFloat = annotateLaneY + trackHeight                  // 284

    /// Separators sit at the top of each inter-lane gap, like the SwiftUI
    /// `.overlay(alignment: .top)` on the padded rows.
    static let separatorYs: [CGFloat] = [
        voiceLaneY - trackSpacing,
        effectsLaneY - trackSpacing,
        focusLaneY - trackSpacing,
        annotateLaneY - trackSpacing,
    ]

    /// EFFECTS sub-rows: overlapping items stack instead of hiding each
    /// other. Each extra row adds one pitch to the lane; capped so a
    /// pathological pile-up cannot swallow the timeline.
    static let subRowGap: CGFloat = 4
    static let subRowPitch: CGFloat = trackHeight + subRowGap
    static let maxEffectsRows = 3

    static let blockInset: CGFloat = 3      // TimelineBlockSurface.inset
    static let blockCornerRadius: CGFloat = 10
    static let handleWidth: CGFloat = 8
    static let minBlockWidth: CGFloat = 20
    static let minDuration: TimeInterval = 0.5
    static let dragThreshold: CGFloat = 3
    static let playheadStripHalfWidth: CGFloat = 14
}

// MARK: - Lane accordion
//
// The three overlay lanes (EFFECTS, FOCUS, ANNOTATE) rest as slim colour
// strips. Hovering one opens it to full block height — it grows downward,
// pushing the lanes below it (a sibling that was open tucks back as it goes) —
// and moving off springs it shut again. VIDEO and VOICE never move.
//
// `TimelineLaneLayout` is the ONE source of lane geometry: the canvas draws and
// hit-tests from it, the playhead overlay reads its bottom from it, and the
// controller sizes the label column and the panel from it. Nothing keeps a
// second copy of a lane Y.

enum TimelineOverlayLane: Int, CaseIterable {
    case effects, focus, annotate
}

struct TimelineLaneLayout: Equatable {
    private typealias M = TimelineCanvasMetrics

    /// Row height of a closed lane — a slim strip (blocks ≈ 12pt bars).
    static let compactRowHeight: CGFloat = 18
    /// Sub-row gap of a closed lane (stacked strips sit tighter).
    static let compactRowGap: CGFloat = 2
    /// Floor for the bounce undershoot of a closing lane.
    static let minRowHeight: CGFloat = 12

    /// Per-lane openness, indexed by `TimelineOverlayLane.rawValue`:
    /// 0 = compact strip, 1 = full lane. Values briefly leave [0, 1] on the
    /// growth bounce. At most one lane targets 1, so while the hover moves
    /// between lanes the openness sums to 1 and the band holds its height.
    var openness: [CGFloat] = [0, 0, 0]
    var effectsRows = 1
    var annotateRows = 1

    /// Steady state with `lane` open — nil = every lane a strip (rest).
    static func settled(
        open lane: TimelineOverlayLane?, effectsRows: Int, annotateRows: Int
    ) -> TimelineLaneLayout {
        TimelineLaneLayout(
            openness: TimelineOverlayLane.allCases.map { $0 == lane ? 1 : 0 },
            effectsRows: effectsRows,
            annotateRows: annotateRows
        )
    }

    /// Tallest settled `tracksBottom` over every possible open lane. The panel
    /// and the scroll document are sized from this, so a hover never re-lays
    /// out the editor stage — the lanes animate inside a fixed frame, and at
    /// rest the room an opening lane grows into sits below ANNOTATE.
    static func maxTracksBottom(effectsRows: Int, annotateRows: Int) -> CGFloat {
        TimelineOverlayLane.allCases.map {
            settled(open: $0, effectsRows: effectsRows, annotateRows: annotateRows).tracksBottom
        }.max() ?? M.tracksBottom
    }

    func openness(_ lane: TimelineOverlayLane) -> CGFloat {
        openness.indices.contains(lane.rawValue) ? openness[lane.rawValue] : 0
    }

    func rows(_ lane: TimelineOverlayLane) -> Int {
        switch lane {
        case .effects: return max(1, effectsRows)
        case .focus: return 1
        case .annotate: return max(1, annotateRows)
        }
    }

    func rowHeight(_ lane: TimelineOverlayLane) -> CGFloat {
        let w = openness(lane)
        return max(Self.minRowHeight,
                   Self.compactRowHeight + (M.trackHeight - Self.compactRowHeight) * w)
    }

    func rowGap(_ lane: TimelineOverlayLane) -> CGFloat {
        let w = min(1, max(0, openness(lane)))
        return Self.compactRowGap + (M.subRowGap - Self.compactRowGap) * w
    }

    func rowPitch(_ lane: TimelineOverlayLane) -> CGFloat {
        rowHeight(lane) + rowGap(lane)
    }

    func laneHeight(_ lane: TimelineOverlayLane) -> CGFloat {
        let n = CGFloat(rows(lane))
        return n * rowHeight(lane) + (n - 1) * rowGap(lane)
    }

    func laneY(_ lane: TimelineOverlayLane) -> CGFloat {
        var y = M.effectsLaneY
        for other in TimelineOverlayLane.allCases {
            if other == lane { return y }
            y += laneHeight(other) + M.trackSpacing
        }
        return y
    }

    /// Top of a sub-row (clamped into the lane's committed row count).
    func rowY(_ lane: TimelineOverlayLane, row: Int) -> CGFloat {
        laneY(lane) + CGFloat(max(0, min(row, rows(lane) - 1))) * rowPitch(lane)
    }

    func laneRect(_ lane: TimelineOverlayLane, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: laneY(lane), width: width, height: laneHeight(lane))
    }

    var tracksBottom: CGFloat {
        laneY(.annotate) + laneHeight(.annotate)
    }

    /// Which overlay lane a canvas Y belongs to for HOVER. Bands are
    /// contiguous — each lane owns half of the gaps around it — so crossing a
    /// 4pt gap never drops the hover and flickers the accordion shut. Nil
    /// above the band (ruler, VIDEO, VOICE) and in the spare room below
    /// ANNOTATE. A lane only ever grows DOWN from its own top (or its top
    /// rises as a sibling above tucks away), so opening never slides the lane
    /// out from under the cursor.
    func hoverLane(atY y: CGFloat) -> TimelineOverlayLane? {
        guard y >= M.effectsLaneY - M.trackSpacing else { return nil }
        for lane in TimelineOverlayLane.allCases {
            if y < laneY(lane) + laneHeight(lane) + M.trackSpacing / 2 { return lane }
        }
        return nil
    }
}
