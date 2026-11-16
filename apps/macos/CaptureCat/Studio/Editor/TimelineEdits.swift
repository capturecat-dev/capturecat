import CoreGraphics
import Foundation

/// What the timeline's edit operations need from the timeline that hosts
/// them — the Mac `TimelineViewController` today, the iOS timeline next. The
/// selection properties are the host's own shims (selection exclusivity,
/// canvas refresh), so every write below lands with the host's side effects.
protocol TimelineEditing: AnyObject {
    var project: Project { get }
    /// The shell's shared selection + chrome state (inspector tab, chips).
    var selection: EditorShellSelection { get }
    /// Resolved lazily at every registration (see TimelineViewController).
    var undoManager: UndoManager? { get }
    /// The playhead, in SOURCE seconds.
    var currentTime: TimeInterval { get }
    var selectedHighlightID: UUID? { get set }
    var selectedDepthFocusID: UUID? { get set }
    var selectedTiltID: UUID? { get set }
    var selectedZoomID: UUID? { get set }
    var selectedAnnotationID: UUID? { get set }
    var selectedBlurID: UUID? { get set }
    var selectedCameraLayoutID: UUID? { get set }
    var selectedVoiceOverID: UUID? { get set }
    var selectedSpeedID: UUID? { get set }
    var selectedClipID: UUID? { get set }
    /// Color chosen on the floating pill's swatch. A selected annotation is
    /// recolored in place (undoable); with nothing selected it becomes the
    /// default for annotations the pill creates next.
    var toolbarAnnotationColor: PlatformColor? { get set }
    /// An add found no room on its lane — audible "can't" (NSSound.beep).
    func timelineEditRefused()
    /// A camera look was placed — start segmenting the person mask now
    /// rather than on the next preview render (idempotent).
    func timelineEditNeedsCameraMask()
}

/// Shared state + pure helpers of the timeline edits.
enum TimelineEdits {
    /// In-app clipboard for Copy / Paste Layout (docs/camera-cutout.md
    /// §12.7): a block's mode, look and camera side — never its times or id.
    static var copiedCameraLayout: (
        mode: CameraLayoutMode, look: CameraBubbleLook?, side: CameraSide?, split: CameraSplitStyle?
    )?

    /// Block caption on the ANNOTATE lane — the text/label for text-bearing
    /// types, the type name otherwise.
    static func annotationLaneLabel(for annotation: Annotation) -> String {
        switch annotation.type {
        case .text, .callout:
            let trimmed = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Text" : trimmed
        case .arrow: return "Arrow"
        case .drawing: return "Drawing"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .tap: return "Tap"
        }
    }
}

/// The timeline's edit operations, platform-neutral (docs/ios-studio-plan.md
/// Phase 1e): every add / delete / commit / split / speed / duplicate the
/// lanes, the keyboard and the menus perform, with its slot search, snapping
/// and undo registration. Moved verbatim from TimelineViewController (its
/// "ported edit logic"); the only seams are `timelineEditRefused()` (was
/// NSSound.beep) and `timelineEditNeedsCameraMask()` (was AppState's
/// segmentation). Frozen by `--timeline-edits-test`.
extension TimelineEditing {
    // MARK: - Canvas routing (selection + chip writes the lanes report)

    /// An EFFECTS block was clicked (either half may be nil).
    func selectEffectBlock(zoomID: UUID?, tiltID: UUID?) {
        selection.introSelected = false
        selection.curtainSelected = false
        selectedZoomID = zoomID
        selectedTiltID = tiltID
    }

    /// Click on the Intro chip — opens the Motion pane where the entrance
    /// direction and length live.
    func openIntroSlide() {
        selectedZoomID = nil
        selectedTiltID = nil
        selection.curtainSelected = false
        selection.introSelected = true
        selection.inspectorTab = .effects
        selection.showInspector = true
    }

    func openCurtainUnveil() {
        selectedZoomID = nil
        selectedTiltID = nil
        selection.introSelected = false
        selection.curtainSelected = true
        selection.inspectorTab = .effects
        selection.showInspector = true
    }

    /// Live drag of the Intro chip's right edge — new END in output seconds.
    func resizeIntroSlide(end: TimeInterval) {
        project.settings.introSlideDuration = max(0.3, end - project.settings.introSlideStart)
    }

    func moveIntroSlide(start: TimeInterval) {
        let outputDuration = fullTimeMap.outputTime(forSource: project.duration)
        project.settings.introSlideStart = min(
            max(0, start),
            max(0, outputDuration - project.settings.introSlideDuration))
    }

    func resizeCurtainUnveil(end: TimeInterval) {
        project.settings.curtainUnveilDuration = max(0.3, end - project.settings.curtainUnveilStart)
    }

    func moveCurtainUnveil(start: TimeInterval) {
        let outputDuration = fullTimeMap.outputTime(forSource: project.duration)
        project.settings.curtainUnveilStart = min(
            max(0, start),
            max(0, outputDuration - project.settings.curtainUnveilDuration))
    }

    /// A FOCUS-lane block was clicked (nil = empty lane). Depth Focus and
    /// camera layouts ride the lane as non-highlight items; the ID picks the
    /// array.
    func selectFocusItem(id: UUID?, isHighlight: Bool) {
        if let id {
            if isHighlight {
                selectedHighlightID = id
                selectedBlurID = nil
                selectedDepthFocusID = nil
            } else if project.focusRegions.contains(where: { $0.id == id }) {
                // Depth Focus rides the FOCUS lane as a non-highlight
                // item; the ID picks the array.
                selectedDepthFocusID = id
                selectedBlurID = nil
                selectedHighlightID = nil
                selectedCameraLayoutID = nil
            } else if project.cameraLayoutRegions.contains(where: { $0.id == id }) {
                selectedCameraLayoutID = id
                selectedBlurID = nil
                selectedHighlightID = nil
                selectedDepthFocusID = nil
            } else {
                selectedBlurID = id
                selectedHighlightID = nil
                selectedDepthFocusID = nil
                selectedCameraLayoutID = nil
            }
        } else {
            selectedBlurID = nil
            selectedHighlightID = nil
            selectedDepthFocusID = nil
            selectedCameraLayoutID = nil
        }
    }

    /// Move/resize commit for a FOCUS block, in SOURCE seconds. Mirrors the
    /// old direct binding write (not undo-registered).
    func commitFocusTimes(id: UUID, isHighlight: Bool, sourceStart: TimeInterval, sourceEnd: TimeInterval) {
        if isHighlight {
            guard let index = project.highlightRegions.firstIndex(where: { $0.id == id }) else { return }
            project.highlightRegions[index].startTime = sourceStart
            project.highlightRegions[index].endTime = sourceEnd
        } else if let index = project.focusRegions.firstIndex(where: { $0.id == id }) {
            project.focusRegions[index].startTime = sourceStart
            project.focusRegions[index].endTime = sourceEnd
        } else if let index = project.cameraLayoutRegions.firstIndex(where: { $0.id == id }) {
            project.cameraLayoutRegions[index].startTime = sourceStart
            project.cameraLayoutRegions[index].endTime = sourceEnd
        } else {
            guard let index = project.blurRegions.firstIndex(where: { $0.id == id }) else { return }
            project.blurRegions[index].startTime = sourceStart
            project.blurRegions[index].endTime = sourceEnd
        }
    }

    /// The FOCUS block's delete (context menu / canvas) — the ID picks the array.
    func deleteFocusItem(id: UUID, isHighlight: Bool) {
        if isHighlight {
            deleteHighlightRegion(id: id)
        } else if project.focusRegions.contains(where: { $0.id == id }) {
            deleteDepthFocusRegion(id: id)
        } else if project.cameraLayoutRegions.contains(where: { $0.id == id }) {
            deleteCameraLayoutRegion(id: id)
        } else {
            deleteBlurRegion(id: id)
        }
    }

    // MARK: - Time map

    var fullTimeMap: SpeedTimeMap {
        SpeedTimeMap(
            sourceStart: project.effectiveTrimStart,
            sourceEnd: max(project.effectiveTrimStart, project.effectiveTrimEnd),
            regions: project.speedRegions
        )
    }

    /// The Slide's span matches some effect block — it renders as part of
    /// that block, not as its own chip.
    var slideJoinsABlock: Bool {
        guard project.settings.introSlideStyle != .off else { return false }
        let map = fullTimeMap
        let s0 = project.settings.introSlideStart
        let s1 = s0 + project.settings.introSlideDuration
        let spans = project.zoomRegions.map { ($0.startTime, $0.endTime) }
            + project.tiltRegions.map { ($0.startTime, $0.endTime) }
        return spans.contains {
            abs(map.outputTime(forSource: $0.0) - s0) < 0.05
                && abs(map.outputTime(forSource: $0.1) - s1) < 0.08
        }
    }

    /// Output duration of the trimmed recording (scaled by speed regions).
    var outputDuration: TimeInterval {
        max(0.0001, fullTimeMap.outputDuration)
    }

    /// Trim start in output time — always 0 in the trim-based map.
    var outputTrimStart: TimeInterval { 0 }

    /// Trim end in output time — the end of the trim-based map.
    var outputTrimEnd: TimeInterval {
        fullTimeMap.outputDuration
    }

    var visibleDuration: TimeInterval {
        max(0, outputTrimEnd - outputTrimStart)
    }

    var visibleCurrentTime: TimeInterval {
        max(0, fullTimeMap.outputTime(forSource: currentTime) - outputTrimStart)
    }

    // MARK: - EFFECTS lane

    /// Showcase: the "reference look" as one click — modest push-in with a
    /// pitch-back skew, Slow Glide, eased back to a flat centred card.
    func addShowcaseBlock() {
        let desiredStart = max(0, min(currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        var (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: effectLaneSpans,
            duration: project.duration
        )
        // No free slot → keep the desired span; overlapping effects stack
        // into EFFECTS sub-rows instead of being refused.
        if start >= end { (start, end) = (desiredStart, desiredEnd) }
        guard start < end else { return } // zero-length timeline

        let zoom = ZoomRegion(
            startTime: start, endTime: end, zoomLevel: 1.35,
            focalPoint: CGPoint(x: 0.5, y: 0.45), animationStyle: .slowGlide)
        let tilt = TiltRegion(
            startTime: start, endTime: end, pitch: 10, yaw: -6, roll: -2)
        project.zoomRegions.append(zoom)
        project.tiltRegions.append(tilt)
        selectedTiltID = tilt.id
        selectedZoomID = zoom.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == zoom.id }
            project.tiltRegions.removeAll { $0.id == tilt.id }
        }
        undoManager?.setActionName("Add Showcase")
    }

    /// Scale Down: the card shrinks toward centre for the span, then eases
    /// back — zoom below 1 is a scale effect on the same lane.
    func addScaleDownBlock() {
        let desiredStart = max(0, min(currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        var (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: effectLaneSpans,
            duration: project.duration
        )
        // No free slot → keep the desired span; overlapping effects stack
        // into EFFECTS sub-rows instead of being refused.
        if start >= end { (start, end) = (desiredStart, desiredEnd) }
        guard start < end else { return } // zero-length timeline

        let region = ZoomRegion(
            startTime: start, endTime: end, zoomLevel: 0.85,
            animationStyle: .smooth)
        project.zoomRegions.append(region)
        selectedTiltID = nil
        selectedZoomID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Scale Down")
    }

    func autoZoom() {
        // Shared with the MCP tool and the record-stop hook (AutoZoomApplier):
        // regenerating replaces only earlier AUTO regions; the user's
        // hand-placed blocks stay and the generator routes around them.
        // The command itself (apply + undo) is shared with the iOS studio.
        AutoZoomApplier.applyAsEdit(to: project, undoManager: undoManager) {
            selectedZoomID = nil
        }
    }

    func runStillMotion() {
        let previousZooms = project.zoomRegions
        let previousTilts = project.tiltRegions
        guard StillMotionApplier.apply(to: project) > 0 else { return }
        selectedZoomID = nil
        selectedTiltID = nil
        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions = previousZooms
            project.tiltRegions = previousTilts
        }
        undoManager?.setActionName("Motion")
    }

    /// Adds a zoom region. `startTime` is a source time — defaults to the
    /// playhead, but right-clicking a track passes the clicked time instead.
    func addZoomRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)

        // Find a slot free of EVERY block on the lane — zoom, tilt and linked.
        var (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: effectLaneSpans,
            duration: project.duration
        )
        // No free slot → keep the desired span; overlapping effects stack
        // into EFFECTS sub-rows instead of being refused.
        if start >= end { (start, end) = (desiredStart, desiredEnd) }
        guard start < end else { return } // zero-length timeline

        let region = ZoomRegion(startTime: start, endTime: end)
        project.zoomRegions.append(region)
        // A standalone zoom is its own EFFECTS block — drop any tilt selection.
        selectedTiltID = nil
        selectedZoomID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Zoom")
    }

    func deleteZoomRegion(id: UUID) {
        guard let index = project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.zoomRegions[index]
        project.zoomRegions.remove(at: index)
        if selectedZoomID == id { selectedZoomID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.zoomRegions.count)
            project.zoomRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Zoom")
    }

    func addTiltRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)

        // Blocks share one lane, so a new tilt must clear zoom-only and linked
        // blocks too. ("Add Tilt to Block" is the exempt case — it deliberately
        // co-spans its own block and never routes through here.)
        var (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: effectLaneSpans,
            duration: project.duration
        )
        // No free slot → keep the desired span; overlapping effects stack
        // into EFFECTS sub-rows instead of being refused.
        if start >= end { (start, end) = (desiredStart, desiredEnd) }
        guard start < end else { return } // zero-length timeline

        // Seed with the Motion tab's skew angles so "make the tilt, then add
        // it to the timeline" carries the user's current look; fall back to a
        // visible default if the sliders are all flat.
        let s = project.settings
        let hasSkew = max(abs(s.screenTiltAngle), abs(s.screenTiltYaw), abs(s.screenTiltRoll)) > 0.01
        let region = TiltRegion(
            startTime: start,
            endTime: end,
            pitch: hasSkew ? s.screenTiltAngle : 20,
            yaw: hasSkew ? s.screenTiltYaw : 0,
            roll: hasSkew ? s.screenTiltRoll : 0
        )
        project.tiltRegions.append(region)
        // A standalone tilt is its own EFFECTS block — drop any zoom selection.
        selectedZoomID = nil
        selectedTiltID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.tiltRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Tilt")
    }

    func deleteTiltRegion(id: UUID) {
        guard let index = project.tiltRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.tiltRegions[index]
        project.tiltRegions.remove(at: index)
        if selectedTiltID == id { selectedTiltID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.tiltRegions.count)
            project.tiltRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Tilt")
    }

    /// Writes a dragged/resized block's span back into both halves. Linked
    /// blocks get *identical* times, which also snaps legacy pairs that were
    /// only co-spanning within the link epsilon to exact equality.
    func commitEffectBlockTimes(
        zoomID: UUID?,
        tiltID: UUID?,
        start: TimeInterval,
        end: TimeInterval
    ) {
        let previousZooms = project.zoomRegions
        let previousTilts = project.tiltRegions
        var changed = false

        if let zoomID, let index = project.zoomRegions.firstIndex(where: { $0.id == zoomID }) {
            project.zoomRegions[index].startTime = start
            project.zoomRegions[index].endTime = end
            changed = true
        }
        if let tiltID, let index = project.tiltRegions.firstIndex(where: { $0.id == tiltID }) {
            project.tiltRegions[index].startTime = start
            project.tiltRegions[index].endTime = end
            changed = true
        }
        guard changed else { return }

        // A joined Slide rides the block it matched before the edit.
        if project.settings.introSlideStyle != .off {
            let map = fullTimeMap
            let s0 = project.settings.introSlideStart
            let prevSpans = (previousZooms.filter { $0.id == zoomID }.map { ($0.startTime, $0.endTime) }
                + previousTilts.filter { $0.id == tiltID }.map { ($0.startTime, $0.endTime) })
            if prevSpans.contains(where: {
                abs(map.outputTime(forSource: $0.0) - s0) < 0.05
            }) {
                project.settings.introSlideStart = map.outputTime(forSource: start)
                project.settings.introSlideDuration = max(
                    0.3, map.outputTime(forSource: end) - map.outputTime(forSource: start))
            }
        }

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions = previousZooms
            project.tiltRegions = previousTilts
        }
        undoManager?.setActionName("Move Effect")
    }

    func setZoomLevel(id: UUID, level: Double) {
        guard let index = project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
        let previous = project.zoomRegions[index].zoomLevel
        guard abs(previous - level) > 0.0001 else { return }
        project.zoomRegions[index].zoomLevel = level

        undoManager?.registerUndo(withTarget: project) { project in
            guard let i = project.zoomRegions.firstIndex(where: { $0.id == id }) else { return }
            project.zoomRegions[i].zoomLevel = previous
        }
        undoManager?.setActionName("Zoom Level")
    }

    /// Adds a tilt that exactly co-spans an existing zoom — the block then
    /// carries both effects.
    func addTiltToBlock(zoomID: UUID) {
        guard let zoom = project.zoomRegions.first(where: { $0.id == zoomID }) else { return }

        let s = project.settings
        let hasSkew = max(abs(s.screenTiltAngle), abs(s.screenTiltYaw), abs(s.screenTiltRoll)) > 0.01
        let region = TiltRegion(
            startTime: zoom.startTime,
            endTime: zoom.endTime,
            pitch: hasSkew ? s.screenTiltAngle : 20,
            yaw: hasSkew ? s.screenTiltYaw : 0,
            roll: hasSkew ? s.screenTiltRoll : 0
        )
        project.tiltRegions.append(region)
        selectedZoomID = zoomID
        selectedTiltID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.tiltRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Tilt to Block")
    }

    /// Adds a zoom that exactly co-spans an existing tilt.
    func addZoomToBlock(tiltID: UUID) {
        guard let tilt = project.tiltRegions.first(where: { $0.id == tiltID }) else { return }

        let region = ZoomRegion(
            startTime: tilt.startTime,
            endTime: tilt.endTime,
            zoomLevel: project.settings.autoZoomLevel
        )
        project.zoomRegions.append(region)
        selectedZoomID = region.id
        selectedTiltID = tiltID

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Zoom to Block")
    }

    /// Deletes every half of a block as a single undoable action.
    func deleteEffectBlock(zoomID: UUID?, tiltID: UUID?) {
        guard zoomID != nil || tiltID != nil else { return }
        let previousZooms = project.zoomRegions
        let previousTilts = project.tiltRegions

        if let zoomID {
            project.zoomRegions.removeAll { $0.id == zoomID }
            if selectedZoomID == zoomID { selectedZoomID = nil }
        }
        if let tiltID {
            project.tiltRegions.removeAll { $0.id == tiltID }
            if selectedTiltID == tiltID { selectedTiltID = nil }
        }

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions = previousZooms
            project.tiltRegions = previousTilts
        }
        undoManager?.setActionName("Delete Effect")
    }

    /// Copies a linked zoom+tilt pair into the next free slot, keeping them
    /// co-spanning so the copy also presents as one block.
    func duplicateEffectPair(zoomID: UUID, tiltID: UUID) -> Bool {
        guard let zoom = project.zoomRegions.first(where: { $0.id == zoomID }),
              let tilt = project.tiltRegions.first(where: { $0.id == tiltID }),
              let slot = duplicateSlot(
                  source: (zoom.startTime, zoom.endTime),
                  existing: effectLaneSpans
              )
        else { return false }

        let zoomCopy = ZoomRegion(
            startTime: slot.start,
            endTime: slot.end,
            zoomLevel: zoom.zoomLevel,
            focalPoint: zoom.focalPoint
        )
        let tiltCopy = TiltRegion(
            startTime: slot.start,
            endTime: slot.end,
            pitch: tilt.pitch,
            yaw: tilt.yaw,
            roll: tilt.roll
        )
        project.zoomRegions.append(zoomCopy)
        project.tiltRegions.append(tiltCopy)
        selectedZoomID = zoomCopy.id
        selectedTiltID = tiltCopy.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.zoomRegions.removeAll { $0.id == zoomCopy.id }
            project.tiltRegions.removeAll { $0.id == tiltCopy.id }
        }
        undoManager?.setActionName("Duplicate Effect")
        return true
    }

    /// Find a non-overlapping time slot near the desired range.
    /// If the desired range overlaps, try placing it right after the overlapping region.
    /// Every span occupied on the EFFECTS lane, in SOURCE time.
    ///
    /// A linked block contributes its zoom and tilt spans, which are identical
    /// by construction, so the duplication is harmless for overlap tests; a
    /// zoom-only or tilt-only block contributes its own single span. Blocks on
    /// this lane may never overlap each other, exactly like the FOCUS lane.
    var effectLaneSpans: [(Double, Double)] {
        project.zoomRegions.map { ($0.startTime, $0.endTime) }
            + project.tiltRegions.map { ($0.startTime, $0.endTime) }
    }

    // MARK: - Intro slide + curtain chips

    /// Intro Slide entry point: turns the entrance on (Bottom by default) and
    /// opens the Motion pane where direction and length live.
    func enableIntroSlide() {
        if project.settings.introSlideStyle == .off {
            project.settings.introSlideStyle = .bottom
        }
        selection.selectedZoomID = nil
        selection.selectedTiltID = nil
        selection.curtainSelected = false
        selection.introSelected = true
        selection.inspectorTab = .effects
        selection.showInspector = true
    }

    /// Curtain Unveil entry point: turns the peel on (Top Left by default)
    /// and opens the Effects pane where corner and length live.
    func enableCurtainUnveil() {
        if project.settings.curtainUnveilCorner == .off {
            project.settings.curtainUnveilCorner = .topLeft
        }
        selection.selectedZoomID = nil
        selection.selectedTiltID = nil
        selection.introSelected = false
        selection.curtainSelected = true
        selection.inspectorTab = .effects
        selection.showInspector = true
    }

    func deleteIntroSlide() {
        let settings = project.settings
        let prevStyle = settings.introSlideStyle
        guard prevStyle != .off else { return }
        let prevStart = settings.introSlideStart
        let prevDuration = settings.introSlideDuration
        settings.introSlideStyle = .off
        selection.introSelected = false
        undoManager?.registerUndo(withTarget: project) { project in
            project.settings.introSlideStyle = prevStyle
            project.settings.introSlideStart = prevStart
            project.settings.introSlideDuration = prevDuration
        }
        undoManager?.setActionName("Delete Slide")
    }

    func deleteCurtainUnveil() {
        let settings = project.settings
        let prevCorner = settings.curtainUnveilCorner
        guard prevCorner != .off else { return }
        let prevStart = settings.curtainUnveilStart
        let prevDuration = settings.curtainUnveilDuration
        settings.curtainUnveilCorner = .off
        selection.curtainSelected = false
        undoManager?.registerUndo(withTarget: project) { project in
            project.settings.curtainUnveilCorner = prevCorner
            project.settings.curtainUnveilStart = prevStart
            project.settings.curtainUnveilDuration = prevDuration
        }
        undoManager?.setActionName("Delete Curtain Unveil")
    }

    // MARK: - FOCUS lane

    func addCameraLayoutRegion(
        mode: CameraLayoutMode, look: CameraBubbleLook? = nil, side: CameraSide? = nil, split: CameraSplitStyle? = nil
    ) {
        // Playhead near the start = "this is my intro": snap to 0 so the
        // video OPENS on the arrangement (CameraLayoutMath renders a block
        // at t=0 settled from frame one, no ease-in from the bubble).
        var desiredStart = max(0, min(currentTime, project.duration))
        if desiredStart < 0.75 { desiredStart = 0 }
        let desiredEnd = min(desiredStart + 4, project.duration)
        // Shares the FOCUS lane with blur + highlight + depth focus.
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) }
                + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { timelineEditRefused(); return } // lane full

        let region = CameraLayoutRegion(startTime: start, endTime: end, mode: mode, look: look,
                                        cameraSide: side, splitStyle: split)
        project.cameraLayoutRegions.append(region)
        selectedCameraLayoutID = region.id
        // A look needs the person mask — start segmenting now rather than on
        // the next preview render (CameraSegmentation is idempotent).
        if look != nil { timelineEditNeedsCameraMask() }

        undoManager?.registerUndo(withTarget: project) { project in
            project.cameraLayoutRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName(look.map { "Add \($0.displayName)" }
            ?? split.map { "Add \($0.displayName)" } ?? "Add Camera Layout")
    }

    func setCameraSide(_ side: CameraSide, regionID: UUID) {
        guard let index = project.cameraLayoutRegions.firstIndex(where: { $0.id == regionID }) else { return }
        let before = project.cameraLayoutRegions[index]
        // Trailing is the default: stored as nil so the block stays as written.
        project.cameraLayoutRegions[index].cameraSide = side == .trailing ? nil : side
        undoManager?.registerUndo(withTarget: project) { project in
            guard let i = project.cameraLayoutRegions.firstIndex(where: { $0.id == regionID }) else { return }
            project.cameraLayoutRegions[i] = before
        }
        undoManager?.setActionName(side.displayName)
    }

    func setSplitStyle(_ split: CameraSplitStyle, regionID: UUID) {
        guard let index = project.cameraLayoutRegions.firstIndex(where: { $0.id == regionID }) else { return }
        let before = project.cameraLayoutRegions[index]
        // Tiles is the default: stored as nil so the block stays as written.
        project.cameraLayoutRegions[index].splitStyle = split == .tiles ? nil : split
        undoManager?.registerUndo(withTarget: project) { project in
            guard let i = project.cameraLayoutRegions.firstIndex(where: { $0.id == regionID }) else { return }
            project.cameraLayoutRegions[i] = before
        }
        undoManager?.setActionName(split == .full ? "Full Height" : "Tiles")
    }

    func pasteCameraLayout(regionID: UUID) {
        guard let copied = TimelineEdits.copiedCameraLayout,
              let index = project.cameraLayoutRegions.firstIndex(where: { $0.id == regionID }) else { return }
        let before = project.cameraLayoutRegions[index]
        project.cameraLayoutRegions[index].mode = copied.mode
        project.cameraLayoutRegions[index].look = copied.look
        project.cameraLayoutRegions[index].cameraSide = copied.side
        project.cameraLayoutRegions[index].splitStyle = copied.split
        if copied.look != nil { timelineEditNeedsCameraMask() }
        undoManager?.registerUndo(withTarget: project) { project in
            guard let i = project.cameraLayoutRegions.firstIndex(where: { $0.id == regionID }) else { return }
            project.cameraLayoutRegions[i] = before
        }
        undoManager?.setActionName("Paste Layout")
    }

    func deleteCameraLayoutRegion(id: UUID) {
        guard let index = project.cameraLayoutRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.cameraLayoutRegions[index]
        project.cameraLayoutRegions.remove(at: index)
        if selectedCameraLayoutID == id { selectedCameraLayoutID = nil }
        undoManager?.registerUndo(withTarget: project) { project in
            project.cameraLayoutRegions.append(region)
        }
        undoManager?.setActionName("Delete Camera Layout")
    }

    func addBlurRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)

        // Check against both blur AND highlight — they share the FOCUS track
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) }
                + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { timelineEditRefused(); return } // lane full

        let region = BlurRegion(startTime: start, endTime: end, label: "Blur")
        project.blurRegions.append(region)
        selectedBlurID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.blurRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Blur")
    }

    /// Drag-to-draw entry (popover arms the preview, the preview reports the
    /// drawn rect): same lane-slot rules as addBlurRegion, but the region is
    /// born with the user's rect and the popover's style.
    func createBlurRegion(rect: CGRect, style: BlurStyle) {
        let desiredStart = max(0, min(currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) }
                + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { timelineEditRefused(); return } // lane full

        let label = style == .pixelate ? "Pixelate" : "Blur"
        let region = BlurRegion(startTime: start, endTime: end, label: label,
                                rect: rect, style: style)
        project.blurRegions.append(region)
        selectedBlurID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.blurRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add \(label)")
    }

    /// Depth Focus: sharp region, graduated blur outside (FocusMath).
    func addDepthFocusRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        // Shares the FOCUS lane with blur + highlight.
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) }
                + project.cameraLayoutRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { timelineEditRefused(); return } // lane full

        let region = FocusRegion(startTime: start, endTime: end)
        project.focusRegions.append(region)
        selectedDepthFocusID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.focusRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Depth Focus")
    }

    func deleteDepthFocusRegion(id: UUID) {
        guard let index = project.focusRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.focusRegions[index]
        project.focusRegions.remove(at: index)
        if selectedDepthFocusID == id { selectedDepthFocusID = nil }
        undoManager?.registerUndo(withTarget: project) { project in
            project.focusRegions.append(region)
        }
        undoManager?.setActionName("Delete Depth Focus")
    }

    func deleteBlurRegion(id: UUID) {
        guard let index = project.blurRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.blurRegions[index]
        project.blurRegions.remove(at: index)
        if selectedBlurID == id { selectedBlurID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.blurRegions.count)
            project.blurRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Blur")
    }

    func addHighlightRegion(at startTime: TimeInterval? = nil) {
        let desiredStart = max(0, min(startTime ?? currentTime, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)

        // Check against both highlight AND blur — they share the FOCUS track
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.highlightRegions.map { ($0.startTime, $0.endTime) }
                + project.blurRegions.map { ($0.startTime, $0.endTime) }
                + project.focusRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { timelineEditRefused(); return } // lane full

        let region = HighlightRegion(startTime: start, endTime: end, label: "Highlight")
        project.highlightRegions.append(region)
        selectedHighlightID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.highlightRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Highlight")
    }

    func deleteHighlightRegion(id: UUID) {
        guard let index = project.highlightRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.highlightRegions[index]
        project.highlightRegions.remove(at: index)
        if selectedHighlightID == id { selectedHighlightID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.highlightRegions.count)
            project.highlightRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Highlight")
    }

    // MARK: - ANNOTATE lane + the floating pill

    /// Move/resize commit for an ANNOTATE block, undo-registered like the
    /// other lanes.
    func commitAnnotationTimes(id: UUID, start: TimeInterval, end: TimeInterval) {
        guard let index = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        let previousStart = project.annotations[index].startTime
        let previousEnd = project.annotations[index].endTime
        guard abs(previousStart - start) > 0.0001 || abs(previousEnd - end) > 0.0001 else { return }
        project.annotations[index].startTime = start
        project.annotations[index].endTime = max(start + 0.25, end)

        undoManager?.registerUndo(withTarget: project) { p in
            guard let i = p.annotations.firstIndex(where: { $0.id == id }) else { return }
            p.annotations[i].startTime = previousStart
            p.annotations[i].endTime = previousEnd
        }
        undoManager?.setActionName("Edit Annotation Timing")
    }

    /// Undo-registered annotation delete — restores the full annotation.
    func deleteAnnotation(id: UUID) {
        guard let index = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.annotations[index]
        project.annotations.remove(at: index)
        if selectedAnnotationID == id { selectedAnnotationID = nil }

        undoManager?.registerUndo(withTarget: project) { p in
            p.annotations.append(removed)
        }
        undoManager?.setActionName("Delete Annotation")
    }

    func addAnnotation(type: AnnotationType, atSource requestedStart: TimeInterval? = nil) {
        let start = max(0, min(requestedStart ?? currentTime, max(0, project.duration - 0.5)))
        let defaultDuration: TimeInterval = type == .drawing ? 10 : 3
        let end = max(start + 0.5, min(project.duration, start + defaultDuration))
        var annotation = Annotation(type: type, startTime: start, endTime: end)
        // Per-type starting look — shared with the MCP add_annotation tool so
        // a scripted annotation is born exactly like a hand-placed one.
        annotation.applyNewAnnotationDefaults()

        // The pill's swatch color, when one was picked, wins over the
        // per-type defaults above — it is the user's explicit "draw in this".
        if let chosen = toolbarAnnotationColor {
            annotation.color = CodableColor(chosen)
        }

        project.annotations.append(annotation)
        selectedAnnotationID = annotation.id

        undoManager?.registerUndo(withTarget: project) { p in
            p.annotations.removeAll { $0.id == annotation.id }
        }
        undoManager?.setActionName("Add \(TimelineEdits.annotationLaneLabel(for: annotation))")
    }

    /// The pill's tool buttons land here — same path the popover rows used.
    /// Returns the new annotation's id so the shell can hand text/callout
    /// straight to the in-place editor.
    @discardableResult
    func addAnnotationFromToolbar(_ type: AnnotationType) -> UUID? {
        addAnnotation(type: type)
        return selectedAnnotationID
    }

    func applyToolbarColor(_ color: PlatformColor) {
        toolbarAnnotationColor = color
        guard let id = selectedAnnotationID,
              let idx = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        let previous = project.annotations[idx].color
        project.annotations[idx].color = CodableColor(color)
        undoManager?.registerUndo(withTarget: project) { p in
            if let i = p.annotations.firstIndex(where: { $0.id == id }) {
                p.annotations[i].color = previous
            }
        }
        undoManager?.setActionName("Recolor Annotation")
    }

    /// Text-mode pill writes (font / weight / background) — the selected
    /// annotation only; no-ops with nothing selected.
    func mutateSelectedAnnotation(_ change: (inout Annotation) -> Void) {
        guard let id = selectedAnnotationID,
              let idx = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        var annotation = project.annotations[idx]
        change(&annotation)
        project.annotations[idx] = annotation
    }

    func applyToolbarFont(_ name: String?) {
        mutateSelectedAnnotation { $0.fontName = name }
    }

    func applyToolbarWeight(_ weight: ProjectSettings.SubtitleWeight) {
        mutateSelectedAnnotation { $0.fontWeight = weight }
    }

    func toggleToolbarBackground() {
        mutateSelectedAnnotation { $0.showBackground.toggle() }
    }

    func applyToolbarBackgroundColor(_ color: PlatformColor) {
        mutateSelectedAnnotation {
            $0.backgroundColor = CodableColor(color)
            // Picking a background color IS turning the background on.
            $0.showBackground = true
        }
    }

    /// Pill size slider: ripple size for taps, border/line width otherwise.
    func applyToolbarSize(_ value: Double) {
        mutateSelectedAnnotation {
            if $0.type == .tap { $0.fontSize = value } else { $0.lineWidth = value }
        }
    }

    /// The selected annotation, for the pill's per-type configuration.
    func toolbarSelectedAnnotation() -> Annotation? {
        guard let id = selectedAnnotationID else { return nil }
        return project.annotations.first(where: { $0.id == id })
    }

    /// Typography of the selected annotation, for the pill's text controls.
    func toolbarSelectedTypography() -> (fontName: String?, weight: ProjectSettings.SubtitleWeight)? {
        guard let id = selectedAnnotationID,
              let a = project.annotations.first(where: { $0.id == id }),
              a.type == .text || a.type == .callout else { return nil }
        return (a.fontName, a.fontWeight)
    }

    // MARK: - VIDEO + VOICE lanes

    @discardableResult
    func splitVideoClip(at sourceTime: TimeInterval) -> Bool {
        var clips = project.effectiveVideoClipSegments
        guard let index = clips.firstIndex(where: {
            sourceTime > $0.startTime + 0.1 && sourceTime < $0.endTime - 0.1
        }) else { return false }

        let previousClips = project.videoClipSegments
        let previousSplits = project.splitPoints
        let clip = clips[index]
        clips.remove(at: index)
        clips.insert(VideoClipSegment(startTime: sourceTime, endTime: clip.endTime), at: index)
        clips.insert(VideoClipSegment(startTime: clip.startTime, endTime: sourceTime), at: index)
        project.videoClipSegments = clips

        if !project.splitPoints.contains(where: { abs($0 - sourceTime) < 0.1 }) {
            project.splitPoints.append(sourceTime)
            project.splitPoints.sort()
        }

        undoManager?.registerUndo(withTarget: project) { p in
            p.videoClipSegments = previousClips
            p.splitPoints = previousSplits
        }
        undoManager?.setActionName("Split Clip")
        return true
    }

    func splitAtPlayhead() {
        let outputCurrent = fullTimeMap.outputTime(forSource: currentTime)
        guard isSliceableOutputTime(outputCurrent) else { return }
        _ = splitVideoClip(at: currentTime)
    }

    /// Delegates to `VideoSliceMath` — same rule for both rows.
    func isSliceableOutputTime(_ outputTime: TimeInterval) -> Bool {
        let map = fullTimeMap
        let spans = project.effectiveVideoClipSegments.map { clip in
            VideoTrackEditMath.ClipSpan(
                id: UUID(),
                outputStart: map.outputTime(forSource: clip.startTime),
                outputEnd: map.outputTime(forSource: clip.endTime)
            )
        }
        return VideoSliceMath.isSliceable(
            outputTime,
            trimStartOutput: outputTrimStart,
            trimEndOutput: outputTrimEnd,
            clipSpans: spans
        )
    }

    func removeSplit(nearOutputTime outputTime: TimeInterval) {
        let sourceTime = fullTimeMap.sourceTime(forOutput: outputTime)
        let previousClips = project.videoClipSegments
        let previousSplits = project.splitPoints

        if !project.videoClipSegments.isEmpty {
            var clips = project.videoClipSegments.sorted { $0.startTime < $1.startTime }
            guard let idx = clips.firstIndex(where: { $0.startTime > project.effectiveTrimStart + 0.01 && abs($0.startTime - sourceTime) < 0.2 }),
                  idx > 0 else { return }

            clips[idx - 1].endTime = max(clips[idx - 1].endTime, clips[idx].endTime)
            clips.remove(at: idx)
            project.videoClipSegments = clips
            project.splitPoints = clips.dropFirst().map(\.startTime).sorted()
        } else {
            guard let idx = project.splitPoints.firstIndex(where: { abs($0 - sourceTime) < 0.2 }) else { return }
            project.splitPoints.remove(at: idx)
        }

        undoManager?.registerUndo(withTarget: project) { p in
            p.videoClipSegments = previousClips
            p.splitPoints = previousSplits
        }
        undoManager?.setActionName("Remove Split")
    }

    /// Lifts a clip out of the VIDEO lane, leaving a gap where it was.
    ///
    /// This is the removal the model already supports, not a new operation:
    /// `Project.effectiveVideoClipSegments` is just an array of source ranges,
    /// dragging a clip can already open a gap between two of them, and both
    /// renderers skip uncovered source time via `Project.hasVisibleVideo(at:)`
    /// (PreviewView + VideoExporter). The write mirrors `removeSplit` exactly:
    /// materialise the effective segments, drop one, re-derive `splitPoints`,
    /// register undo. Deliberately NOT a ripple delete — closing the gap would
    /// mean re-timing every clip, region, annotation and subtitle, and no
    /// existing operation does that.
    func deleteVideoClip(id: UUID) {
        let clips = project.effectiveVideoClipSegments
        // Never leave the timeline with no video at all.
        guard clips.count > 1, clips.contains(where: { $0.id == id }) else { return }

        let previousClips = project.videoClipSegments
        let previousSplits = project.splitPoints

        let remaining = clips.filter { $0.id != id }
        project.videoClipSegments = remaining
        project.splitPoints = remaining.dropFirst().map(\.startTime).sorted()
        selectedClipID = nil

        undoManager?.registerUndo(withTarget: project) { p in
            p.videoClipSegments = previousClips
            p.splitPoints = previousSplits
        }
        undoManager?.setActionName("Delete Clip")
    }

    func videoTrackSnapCandidates(for project: Project) -> [TimeInterval] {
        var out: [TimeInterval] = []
        out += project.zoomRegions.flatMap { [$0.startTime, $0.endTime] }
        out += project.blurRegions.flatMap { [$0.startTime, $0.endTime] }
        out += project.highlightRegions.flatMap { [$0.startTime, $0.endTime] }
        out += project.speedRegions.flatMap { [$0.startTime, $0.endTime] }
        out.append(currentTime) // playhead is a snap target, as in most video editors
        return out
    }

    func addSpeedRegion(at time: TimeInterval, speed: Double) {
        let desiredStart = max(0, min(time, project.duration))
        let desiredEnd = min(desiredStart + 3, project.duration)
        addSpeedRegion(start: desiredStart, end: desiredEnd, speed: speed)
    }

    /// Adds a speed region covering a full source-time range — used when the
    /// user picks a speed for a segment of the yellow clip. No hard-coded 3s.
    func addSpeedRegion(start rawStart: TimeInterval, end rawEnd: TimeInterval, speed: Double) {
        let desiredStart = max(0, min(rawStart, project.duration))
        let desiredEnd = max(desiredStart + 0.1, min(rawEnd, project.duration))
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, desiredEnd),
            existing: project.speedRegions.map { ($0.startTime, $0.endTime) },
            duration: project.duration
        )
        guard start < end else { timelineEditRefused(); return } // lane full

        let region = VideoSpeedRegion(startTime: start, endTime: end, speed: speed)
        project.speedRegions.append(region)
        selectedSpeedID = region.id

        undoManager?.registerUndo(withTarget: project) { project in
            project.speedRegions.removeAll { $0.id == region.id }
        }
        undoManager?.setActionName("Add Speed")
    }

    func changeSpeedRegion(id: UUID, speed: Double) {
        guard let idx = project.speedRegions.firstIndex(where: { $0.id == id }) else { return }
        let previous = project.speedRegions[idx].speed
        project.speedRegions[idx].speed = speed
        undoManager?.registerUndo(withTarget: project) { p in
            if let i = p.speedRegions.firstIndex(where: { $0.id == id }) {
                p.speedRegions[i].speed = previous
            }
        }
        undoManager?.setActionName("Change Speed")
    }

    func deleteSpeedRegion(id: UUID) {
        guard let index = project.speedRegions.firstIndex(where: { $0.id == id }) else { return }
        let region = project.speedRegions[index]
        project.speedRegions.remove(at: index)
        if selectedSpeedID == id { selectedSpeedID = nil }

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.speedRegions.count)
            project.speedRegions.insert(region, at: insertIndex)
        }
        undoManager?.setActionName("Delete Speed")
    }

    func deleteVoiceOverClip(id: UUID) {
        guard let index = project.voiceOverClips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.voiceOverClips[index]
        let clipURL = clip.resolvedURL(in: project.projectDirectory)
        let clipData = try? Data(contentsOf: clipURL)
        project.voiceOverClips.remove(at: index)
        if selectedVoiceOverID == id { selectedVoiceOverID = nil }
        try? FileManager.default.removeItem(at: clipURL)

        undoManager?.registerUndo(withTarget: project) { project in
            let insertIndex = min(index, project.voiceOverClips.count)
            project.voiceOverClips.insert(clip, at: insertIndex)
            if let clipData {
                try? FileManager.default.createDirectory(at: project.projectDirectory, withIntermediateDirectories: true)
                try? clipData.write(to: clipURL, options: .atomic)
            }
        }
        undoManager?.setActionName("Delete Voice Over")
    }

    // MARK: - Slots, duplicate, delete

    /// Gap-based placement: an add NEVER silently fails while any usable gap
    /// exists on the lane. The old shift-right-only search returned nothing
    /// whenever the playhead sat inside or after the existing blocks — the
    /// menu clicked, the timeline didn't change, no feedback.
    ///
    /// Prefers the gap containing the desired start, else the nearest gap
    /// (before or after), and shrinks the block to fit down to `minDuration`.
    /// Returns (0, 0) only when no gap of `minDuration` exists at all.
    func findNonOverlappingSlot(
        desired: (Double, Double),
        existing: [(Double, Double)],
        duration: Double,
        minDuration: Double = 0.8
    ) -> (Double, Double) {
        let want = max(minDuration, desired.1 - desired.0)

        // Merge spans → free gaps in [0, duration].
        let spans = existing.sorted { $0.0 < $1.0 }
        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for span in spans {
            if span.0 - cursor >= minDuration { gaps.append((cursor, span.0)) }
            cursor = max(cursor, span.1)
        }
        if duration - cursor >= minDuration { gaps.append((cursor, duration)) }
        guard !gaps.isEmpty else { return (0, 0) }

        // The gap holding the desired start wins; else the nearest gap.
        let gap = gaps.first { desired.0 >= $0.0 && desired.0 < $0.1 }
            ?? gaps.min {
                min(abs($0.0 - desired.0), abs($0.1 - desired.0))
                    < min(abs($1.0 - desired.0), abs($1.1 - desired.0))
            }!
        let length = min(want, gap.1 - gap.0)
        let start = min(max(desired.0, gap.0), gap.1 - length)
        return (start, start + length)
    }

    /// Places a copy of `source` immediately after itself, sliding right past
    /// anything in `existing` that would overlap. Returns nil when there's no room.
    func duplicateSlot(
        source: (start: TimeInterval, end: TimeInterval),
        existing: [(Double, Double)]
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let length = max(0.1, source.end - source.start)
        let desiredStart = min(source.end, max(0, project.duration - length))
        let (start, end) = findNonOverlappingSlot(
            desired: (desiredStart, min(desiredStart + length, project.duration)),
            existing: existing,
            duration: project.duration
        )
        guard start < end else { return nil }
        return (start, end)
    }

    func duplicateSelectedRegion() {
        // Duplicating a linked block yields a new linked pair.
        if let zoomID = selectedZoomID, let tiltID = selectedTiltID {
            _ = duplicateEffectPair(zoomID: zoomID, tiltID: tiltID)
            return
        }

        if let id = selectedZoomID, let source = project.zoomRegions.first(where: { $0.id == id }) {
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: effectLaneSpans
            ) else { return }
            let copy = ZoomRegion(
                startTime: slot.start,
                endTime: slot.end,
                zoomLevel: source.zoomLevel,
                focalPoint: source.focalPoint
            )
            project.zoomRegions.append(copy)
            selectedZoomID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.zoomRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Zoom")
            return
        }

        if let id = selectedTiltID, let source = project.tiltRegions.first(where: { $0.id == id }) {
            // One lane, so the copy must clear every other block on it.
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: effectLaneSpans
            ) else { return }
            let copy = TiltRegion(
                startTime: slot.start,
                endTime: slot.end,
                pitch: source.pitch,
                yaw: source.yaw,
                roll: source.roll
            )
            project.tiltRegions.append(copy)
            selectedTiltID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.tiltRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Tilt")
            return
        }

        if let id = selectedBlurID, let source = project.blurRegions.first(where: { $0.id == id }) {
            // Blur and highlight share the FOCUS track — avoid both.
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: project.blurRegions.map { ($0.startTime, $0.endTime) }
                    + project.highlightRegions.map { ($0.startTime, $0.endTime) }
            ) else { return }
            let copy = BlurRegion(
                startTime: slot.start,
                endTime: slot.end,
                label: source.label,
                rect: source.rect,
                intensity: source.intensity
            )
            project.blurRegions.append(copy)
            selectedBlurID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.blurRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Blur")
            return
        }

        if let id = selectedHighlightID, let source = project.highlightRegions.first(where: { $0.id == id }) {
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: project.highlightRegions.map { ($0.startTime, $0.endTime) }
                    + project.blurRegions.map { ($0.startTime, $0.endTime) }
            ) else { return }
            let copy = HighlightRegion(
                startTime: slot.start,
                endTime: slot.end,
                label: source.label,
                rect: source.rect,
                opacity: source.opacity
            )
            project.highlightRegions.append(copy)
            selectedHighlightID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.highlightRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Highlight")
            return
        }

        if let id = selectedSpeedID, let source = project.speedRegions.first(where: { $0.id == id }) {
            guard let slot = duplicateSlot(
                source: (source.startTime, source.endTime),
                existing: project.speedRegions.map { ($0.startTime, $0.endTime) }
            ) else { return }
            let copy = VideoSpeedRegion(startTime: slot.start, endTime: slot.end, speed: source.speed)
            project.speedRegions.append(copy)
            selectedSpeedID = copy.id
            undoManager?.registerUndo(withTarget: project) { p in
                p.speedRegions.removeAll { $0.id == copy.id }
            }
            undoManager?.setActionName("Duplicate Speed")
        }
    }

    /// Anything the trash button / Delete key can act on right now.
    var hasDeletableSelection: Bool {
        selection.introSelected
            || selection.curtainSelected
            || selection.selectedDepthFocusID != nil
            || selectedZoomID != nil
            || selectedBlurID != nil
            || selectedVoiceOverID != nil
            || selectedHighlightID != nil
            || selectedSpeedID != nil
            || selectedTiltID != nil
            || canDeleteSelectedClip
    }

    /// A clip can only be lifted while another one remains.
    var canDeleteSelectedClip: Bool {
        guard let id = selectedClipID else { return false }
        let clips = project.effectiveVideoClipSegments
        return clips.count > 1 && clips.contains { $0.id == id }
    }

    @discardableResult
    func deleteSelectedRegion() -> Bool {
        // The Slide chip lives in settings, not a region array — deleting it
        // turns the effect off (undo restores style, start and length).
        if selection.introSelected {
            deleteIntroSlide()
            return true
        }
        // The Curtain chip is settings too — deleting turns the effect off
        // (undo restores corner, start and length).
        if selection.curtainSelected {
            deleteCurtainUnveil()
            return true
        }
        // A linked EFFECTS block owns both halves — delete them together.
        if selectedZoomID != nil, selectedTiltID != nil {
            deleteEffectBlock(zoomID: selectedZoomID, tiltID: selectedTiltID)
            return true
        }
        if let id = selectedZoomID {
            deleteZoomRegion(id: id)
            return true
        }
        if let id = selectedBlurID {
            deleteBlurRegion(id: id)
            return true
        }
        if let id = selectedVoiceOverID {
            deleteVoiceOverClip(id: id)
            return true
        }
        if let id = selectedHighlightID {
            deleteHighlightRegion(id: id)
            return true
        }
        if let id = selectedDepthFocusID {
            deleteDepthFocusRegion(id: id)
            return true
        }
        if let id = selectedCameraLayoutID {
            deleteCameraLayoutRegion(id: id)
            return true
        }
        if let id = selectedSpeedID {
            deleteSpeedRegion(id: id)
            return true
        }
        if let id = selectedTiltID {
            deleteTiltRegion(id: id)
            return true
        }
        if let id = selectedClipID {
            deleteVideoClip(id: id)
            return true
        }
        if let id = selectedAnnotationID {
            deleteAnnotation(id: id)
            return true
        }
        return false
    }
}
