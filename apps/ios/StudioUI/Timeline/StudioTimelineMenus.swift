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
                sheet.addAction(String(localized: "Change Speed", comment: "Timeline long-press menu: change a speed region's speed"), symbol: "gauge.with.needle") {
                    present(speedSheet(title: String(localized: "Change Speed", comment: "Title of the sheet listing speed presets"), current: segment.speed) { video?.changeSpeed(regionID, $0) })
                }
                sheet.addAction(String(localized: "Remove Speed", comment: "Timeline long-press menu: remove a speed region"), symbol: "trash", destructive: true) { video?.deleteSpeed(regionID) }
            } else {
                sheet.addAction(String(localized: "Set Speed", comment: "Timeline long-press menu: add a speed change to this video segment"), symbol: "gauge.with.needle") {
                    present(speedSheet(title: String(localized: "Set Speed", comment: "Title of the sheet listing speed presets"), current: nil) {
                        video?.addSpeedRange(segment.sourceStart, segment.sourceEnd, $0)
                    })
                }
            }
            if segment.startsAtSplit {
                sheet.addAction(String(localized: "Remove Split at Start", comment: "Timeline long-press menu: remove the cut at the start of this segment"), symbol: "scissors", destructive: true) {
                    video?.deleteSplit(segment.outputStart)
                }
            }
            return sheet
        case .voiceClip(let item):
            let voice = canvas.voiceCallbacks
            let sheet = CCActionSheet(title: String(localized: "Voice Over", comment: "Timeline long-press menu title for a voice-over clip"))
            sheet.addAction(String(localized: "Delete Voice Over", comment: "Timeline long-press menu: delete the voice-over clip"), symbol: "trash", destructive: true) { voice?.deleteClip(item.id) }
            return sheet
        case .introChip:
            let sheet = CCActionSheet(title: String(localized: "Slide", comment: "Timeline long-press menu title for the intro slide chip"))
            sheet.addAction(String(localized: "Delete", comment: "Timeline long-press menu: delete the pressed item"), symbol: "trash", destructive: true) { callbacks.deleteIntro() }
            return sheet
        case .curtainChip:
            let sheet = CCActionSheet(title: String(localized: "Curtain Unveil", comment: "Timeline long-press menu title for the curtain-unveil chip"))
            sheet.addAction(String(localized: "Delete", comment: "Timeline long-press menu: delete the pressed item"), symbol: "trash", destructive: true) { callbacks.deleteCurtain() }
            return sheet
        case .effect(let item):
            let sheet = CCActionSheet(title: effectTitle(item))
            if item.hasZoom, let zoomID = item.zoomID {
                sheet.addAction(String(localized: "Zoom Level", comment: "Timeline long-press menu: open zoom magnification choices"), symbol: "plus.magnifyingglass") {
                    let levels = CCActionSheet(title: String(localized: "Zoom Level", comment: "Title of the sheet listing zoom magnifications"))
                    for level in [1.5, 2.0, 2.5, 3.0, 4.0, 5.0] {
                        levels.addAction(UnitText.multiplier(level),
                                         checked: abs((item.zoomLevel ?? 0) - level) < 0.01) {
                            callbacks.setZoomLevel(zoomID, level)
                        }
                    }
                    present(levels)
                }
            }
            if item.hasTilt, let tiltID = item.tiltID {
                sheet.addAction(String(localized: "Remove Tilt", comment: "Timeline long-press menu: remove the tilt from an effect block"), symbol: "rotate.3d") { callbacks.removeTilt(tiltID) }
            } else if let zoomID = item.zoomID {
                sheet.addAction(String(localized: "Add Tilt to Block", comment: "Timeline long-press menu: add a 3D tilt to this zoom block"), symbol: "rotate.3d") { callbacks.addTiltToBlock(zoomID) }
            }
            if item.hasZoom, let zoomID = item.zoomID {
                sheet.addAction(String(localized: "Remove Zoom", comment: "Timeline long-press menu: remove the zoom from an effect block"), symbol: "plus.magnifyingglass") { callbacks.removeZoom(zoomID) }
            } else if let tiltID = item.tiltID {
                sheet.addAction(String(localized: "Add Zoom to Block", comment: "Timeline long-press menu: add a zoom to this tilt block"), symbol: "plus.magnifyingglass") { callbacks.addZoomToBlock(tiltID) }
            }
            sheet.addAction(String(localized: "Delete", comment: "Timeline long-press menu: delete the pressed item"), symbol: "trash", destructive: true) {
                callbacks.deleteEffectBlock(item.zoomID, item.tiltID)
            }
            return sheet
        case .focus(let item):
            let sheet = CCActionSheet(title: item.label)
            for entry in callbacks.focusMenuExtras(item.id) {
                guard let action = entry.action, entry.isEnabled else { continue }
                sheet.addAction(entry.title, checked: entry.checked, handler: action)
            }
            sheet.addAction(String(localized: "Delete", comment: "Timeline long-press menu: delete the pressed item"), symbol: "trash", destructive: true) { callbacks.deleteFocus(item.id, item.isHighlight) }
            return sheet
        case .annotate(let item):
            let sheet = CCActionSheet(title: item.label)
            sheet.addAction(String(localized: "Delete", comment: "Timeline long-press menu: delete the pressed item"), symbol: "trash", destructive: true) { callbacks.deleteAnnotation(item.id) }
            return sheet
        case .emptyAnnotate(let time):
            let sheet = CCActionSheet(title: String(localized: "Annotate", comment: "Timeline long-press menu title on the empty annotation lane"))
            for (title, type) in addAnnotationRows {
                sheet.addAction(title, symbol: TimelineEdits.annotationLaneIcon(for: type)) {
                    callbacks.addAnnotationAt(type, time)
                }
            }
            return sheet
        case .emptyEffects(let time):
            let sheet = CCActionSheet(title: String(localized: "Effects", comment: "Timeline long-press menu title on the empty effects lane"))
            sheet.addAction(String(localized: "Add Zoom Region", comment: "Timeline long-press menu: add a zoom block here"), symbol: "plus.magnifyingglass") { callbacks.addZoomAt(time) }
            sheet.addAction(String(localized: "Add Tilt Region", comment: "Timeline long-press menu: add a 3D tilt block here"), symbol: "rotate.3d") { callbacks.addTiltAt(time) }
            return sheet
        case .emptyFocus(let time):
            let sheet = CCActionSheet(title: String(localized: "Focus", comment: "Timeline long-press menu title on the empty focus lane"))
            sheet.addAction(String(localized: "Add Highlight", comment: "Timeline long-press menu: add a highlight region here"), symbol: "highlighter") { callbacks.addHighlightAt(time) }
            sheet.addAction(String(localized: "Add Blur", comment: "Timeline long-press menu: add a blur region here"), symbol: "eye.slash") { callbacks.addBlurAt(time) }
            return sheet
        }
    }

    /// The ANNOTATE lane's add rows (the Mac's order and titles).
    static let addAnnotationRows: [(String, AnnotationType)] = [
        (String(localized: "Add Text Label", comment: "Timeline menu: add a text annotation"), .text),
        (String(localized: "Add Arrow", comment: "Timeline menu: add an arrow annotation"), .arrow),
        (String(localized: "Add Callout", comment: "Timeline menu: add a callout annotation"), .callout),
        (String(localized: "Add Drawing", comment: "Timeline menu: add a freehand drawing annotation"), .drawing),
        (String(localized: "Add Rectangle", comment: "Timeline menu: add a rectangle annotation"), .rectangle),
        (String(localized: "Add Ellipse", comment: "Timeline menu: add an ellipse annotation"), .ellipse),
        (String(localized: "Add Tap Indicator", comment: "Timeline menu: add a tap indicator annotation"), .tap),
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
        case (true, true): return String(localized: "Zoom + Tilt", comment: "Menu title for an effect block with both zoom and tilt")
        case (true, false): return String(localized: "Zoom", comment: "Menu title for a zoom effect block")
        case (false, true): return String(localized: "Tilt", comment: "Menu title for a 3D tilt effect block")
        case (false, false): return String(localized: "Effect", comment: "Menu title for an effect block")
        }
    }
}
