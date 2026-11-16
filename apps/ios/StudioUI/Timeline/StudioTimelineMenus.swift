import UIKit

/// Long-press menus for the touch timeline — the Mac canvas's right-click
/// menus (same rows, same order, same actions), as house `CCActionSheet`s
/// instead of system menus. Every row calls the shared callback tables the
/// lanes use, so a menu edit is the Mac's edit. A Mac submenu ("Zoom Level ▸",
/// "Set Speed ▸") becomes a row that opens a second sheet; rows the Mac shows
/// disabled are left out (a sheet has no disabled state).
@MainActor
enum StudioTimelineMenus {
    /// The sheet for a long-press target, or nil when nothing is there.
    static func sheet(
        for hit: StudioTimelineHit,
        canvas: StudioTimelineCanvasView,
        present: @escaping (CCActionSheet) -> Void
    ) -> CCActionSheet? {
        guard let callbacks = canvas.callbacks else { return nil }
        switch hit {
        case .none:
            return nil
        case .videoSegment(let segment):
            let video = canvas.videoCallbacks
            let sheet = CCActionSheet(title: segment.label)
            if let regionID = segment.regionID {
                sheet.addAction("Change Speed", symbol: "gauge.with.needle") {
                    present(speedSheet(title: "Change Speed", current: segment.speed) { video?.changeSpeed(regionID, $0) })
                }
                sheet.addAction("Remove Speed", symbol: "trash", destructive: true) { video?.deleteSpeed(regionID) }
            } else {
                sheet.addAction("Set Speed", symbol: "gauge.with.needle") {
                    present(speedSheet(title: "Set Speed", current: nil) {
                        video?.addSpeedRange(segment.sourceStart, segment.sourceEnd, $0)
                    })
                }
            }
            if segment.startsAtSplit {
                sheet.addAction("Remove Split at Start", symbol: "scissors", destructive: true) {
                    video?.deleteSplit(segment.outputStart)
                }
            }
            return sheet
        case .voiceClip(let item):
            let voice = canvas.voiceCallbacks
            let sheet = CCActionSheet(title: "Voice Over")
            sheet.addAction("Delete Voice Over", symbol: "trash", destructive: true) { voice?.deleteClip(item.id) }
            return sheet
        case .introChip:
            let sheet = CCActionSheet(title: "Slide")
            sheet.addAction("Delete", symbol: "trash", destructive: true) { callbacks.deleteIntro() }
            return sheet
        case .curtainChip:
            let sheet = CCActionSheet(title: "Curtain Unveil")
            sheet.addAction("Delete", symbol: "trash", destructive: true) { callbacks.deleteCurtain() }
            return sheet
        case .effect(let item):
            let sheet = CCActionSheet(title: effectTitle(item))
            if item.hasZoom, let zoomID = item.zoomID {
                sheet.addAction("Zoom Level", symbol: "plus.magnifyingglass") {
                    let levels = CCActionSheet(title: "Zoom Level")
                    for level in [1.5, 2.0, 2.5, 3.0, 4.0, 5.0] {
                        levels.addAction(String(format: "%.1fx", level),
                                         checked: abs((item.zoomLevel ?? 0) - level) < 0.01) {
                            callbacks.setZoomLevel(zoomID, level)
                        }
                    }
                    present(levels)
                }
            }
            if item.hasTilt, let tiltID = item.tiltID {
                sheet.addAction("Remove Tilt", symbol: "rotate.3d") { callbacks.removeTilt(tiltID) }
            } else if let zoomID = item.zoomID {
                sheet.addAction("Add Tilt to Block", symbol: "rotate.3d") { callbacks.addTiltToBlock(zoomID) }
            }
            if item.hasZoom, let zoomID = item.zoomID {
                sheet.addAction("Remove Zoom", symbol: "plus.magnifyingglass") { callbacks.removeZoom(zoomID) }
            } else if let tiltID = item.tiltID {
                sheet.addAction("Add Zoom to Block", symbol: "plus.magnifyingglass") { callbacks.addZoomToBlock(tiltID) }
            }
            sheet.addAction("Delete", symbol: "trash", destructive: true) {
                callbacks.deleteEffectBlock(item.zoomID, item.tiltID)
            }
            return sheet
        case .focus(let item):
            let sheet = CCActionSheet(title: item.label)
            for entry in callbacks.focusMenuExtras(item.id) {
                guard let action = entry.action, entry.isEnabled else { continue }
                sheet.addAction(entry.title, checked: entry.checked, handler: action)
            }
            sheet.addAction("Delete", symbol: "trash", destructive: true) { callbacks.deleteFocus(item.id, item.isHighlight) }
            return sheet
        case .annotate(let item):
            let sheet = CCActionSheet(title: item.label)
            sheet.addAction("Delete", symbol: "trash", destructive: true) { callbacks.deleteAnnotation(item.id) }
            return sheet
        case .emptyAnnotate(let time):
            let sheet = CCActionSheet(title: "Annotate")
            for (title, type) in addAnnotationRows {
                sheet.addAction(title, symbol: TimelineEdits.annotationLaneIcon(for: type)) {
                    callbacks.addAnnotationAt(type, time)
                }
            }
            return sheet
        case .emptyEffects(let time):
            let sheet = CCActionSheet(title: "Effects")
            sheet.addAction("Add Zoom Region", symbol: "plus.magnifyingglass") { callbacks.addZoomAt(time) }
            sheet.addAction("Add Tilt Region", symbol: "rotate.3d") { callbacks.addTiltAt(time) }
            return sheet
        case .emptyFocus(let time):
            let sheet = CCActionSheet(title: "Focus")
            sheet.addAction("Add Highlight", symbol: "highlighter") { callbacks.addHighlightAt(time) }
            sheet.addAction("Add Blur", symbol: "eye.slash") { callbacks.addBlurAt(time) }
            return sheet
        }
    }

    /// The ANNOTATE lane's add rows (the Mac's order and titles).
    static let addAnnotationRows: [(String, AnnotationType)] = [
        ("Add Text Label", .text),
        ("Add Arrow", .arrow),
        ("Add Callout", .callout),
        ("Add Drawing", .drawing),
        ("Add Rectangle", .rectangle),
        ("Add Ellipse", .ellipse),
        ("Add Tap Indicator", .tap),
    ]

    private static func speedSheet(title: String, current: Double?, pick: @escaping (Double) -> Void) -> CCActionSheet {
        let sheet = CCActionSheet(title: title)
        for level in TimelineVideoRowModel.speedPresets {
            sheet.addAction(TimelineVideoRowModel.formatSpeedLabel(level),
                            checked: current.map { abs($0 - level) < 0.01 } ?? false) { pick(level) }
        }
        return sheet
    }

    private static func effectTitle(_ item: EffectBlockItem) -> String {
        switch (item.hasZoom, item.hasTilt) {
        case (true, true): return "Zoom + Tilt"
        case (true, false): return "Zoom"
        case (false, true): return "Tilt"
        case (false, false): return "Effect"
        }
    }
}
