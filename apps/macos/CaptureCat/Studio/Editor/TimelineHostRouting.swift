import CoreGraphics
import Foundation

// The timeline host's routing, platform-neutral (Studio 4c): selection
// exclusivity, the lane snapshots the canvases draw from, and the callback
// tables that turn a lane's OUTPUT-time gesture into the shared
// `TimelineEditing` operation. Moved verbatim out of the Mac
// `TimelineViewController` so the iOS timeline routes every gesture exactly
// as the Mac does. Frozen by `--timeline-edits-test` (Mac) and
// `--timeline-edits` (StudioLab).

/// What the shared routing needs from a timeline host beyond `TimelineEditing`
/// — the platform's focus, playback and slice-tool effects.
protocol TimelineHosting: TimelineEditing {
    /// Hand keyboard focus to the timeline (Mac: the panel root becomes first
    /// responder). Called where the Mac's `focusTimeline()` was.
    func timelineRequestFocus()
    /// Move the playhead to a SOURCE time from a scrub (`exact: false`, while
    /// the finger/mouse moves) or a seek (`exact: true`, on release).
    func timelineScrub(toSource time: TimeInterval, exact: Bool)
    /// Stop playback (selecting an off-screen annotation pauses first).
    func timelinePause()
    /// Jump the playhead to a SOURCE time, frame-exact (`seekToSource`).
    func timelineSeek(toSource time: TimeInterval)
    func timelineTogglePlayback()
    /// A slice-tool cut landed — the tool disarms (Mac: `sliceMode = false`
    /// and the hover indicator clears).
    func timelineSliceCommitted()
}

/// Selection lanes for `clearSelections(exclusiveTo:)`.
enum TimelineSelectionLane { case zoom, tilt, blur, voiceOver, highlight, depthFocus, cameraLayout, speed, clip, annotation }

extension TimelineEdits {
    static func annotationLaneIcon(for type: AnnotationType) -> String {
        switch type {
        case .text: return "text.bubble"
        case .arrow: return "arrow.up.right"
        case .callout: return "pencil.tip"
        case .drawing: return "pencil.and.scribble"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .tap: return "hand.tap"
        }
    }

    /// FOCUS-lane caption of a camera-layout block, e.g. "Camera: Side by Side (Left)".
    static func cameraLayoutLaneLabel(_ region: CameraLayoutRegion) -> String {
        let name = region.effectiveLook?.displayName
            ?? (region.mode == .sideBySide ? region.effectiveSplitStyle.displayName : region.mode.displayName)
        return region.mode == .sideBySide && region.effectiveSide == .leading
            ? String(localized: "Camera: \(name) (Left)", comment: "Timeline FOCUS lane: camera layout block caption with the camera on the left; the argument is the layout name")
            : String(localized: "Camera: \(name)", comment: "Timeline FOCUS lane: camera layout block caption; the argument is the layout name")
    }

    /// Compact scrub readout, e.g. "0:02.4".
    static func scrubBubbleText(_ time: TimeInterval) -> String {
        let total = max(0, time)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }
}

// MARK: - Selection exclusivity

extension TimelineEditing {
    /// Port of `SelectionExclusivity`. ONE selected object at a time — the
    /// single deliberate exception is zoom/tilt not clearing each other (a
    /// linked EFFECTS block selects both halves), and blur/voice-over keeping
    /// `speed`. Annotations are fully exclusive both ways: a selected drawing
    /// annotation arms the canvas pen, so leaving it selected while a region
    /// is selected turned "move the blur" into ink strokes.
    ///
    /// The host's selection setters call this after storing a NON-nil value
    /// (guarding re-entry); the writes below go through the host's own shims.
    func clearSelections(exclusiveTo lane: TimelineSelectionLane) {
        if lane != .annotation { selection.selectedAnnotationID = nil }
        switch lane {
        case .zoom, .tilt:
            selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        case .blur:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
            selectedVoiceOverID = nil; selectedClipID = nil
        case .voiceOver:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedClipID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        case .highlight:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil
        case .depthFocus:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil
            selection.selectedHighlightID = nil; selectedCameraLayoutID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil

        // Same rules as Depth Focus — they share the FOCUS lane.
        case .cameraLayout:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil
            selection.selectedHighlightID = nil; selection.selectedDepthFocusID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil
        case .speed:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedClipID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        case .clip:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        case .annotation:
            selection.selectedZoomID = nil; selection.selectedTiltID = nil; selection.selectedHighlightID = nil
            selectedBlurID = nil; selectedVoiceOverID = nil; selectedSpeedID = nil; selectedClipID = nil
            selection.selectedDepthFocusID = nil; selectedCameraLayoutID = nil
        }
    }
}

// MARK: - Lane snapshots

extension TimelineEditing {
    /// Same pairing as EffectsTrackContent.items — each zoom claims the first
    /// unclaimed co-spanning tilt; unclaimed tilts append last for z-order.
    func timelineEffectItems() -> [EffectBlockItem] {
        let map = fullTimeMap
        let epsilon = EffectBlockItem.linkEpsilon
        var claimedTilts: Set<UUID> = []
        var result: [EffectBlockItem] = []

        for zoom in project.zoomRegions {
            let match = project.tiltRegions.first { tilt in
                !claimedTilts.contains(tilt.id)
                    && abs(tilt.startTime - zoom.startTime) <= epsilon
                    && abs(tilt.endTime - zoom.endTime) <= epsilon
            }
            if let match { claimedTilts.insert(match.id) }
            result.append(
                EffectBlockItem(
                    zoomID: zoom.id,
                    tiltID: match?.id,
                    startTime: map.outputTime(forSource: zoom.startTime),
                    endTime: map.outputTime(forSource: zoom.endTime),
                    zoomLevel: zoom.zoomLevel,
                    pitch: match?.pitch ?? 0,
                    yaw: match?.yaw ?? 0,
                    roll: match?.roll ?? 0
                )
            )
        }
        for tilt in project.tiltRegions where !claimedTilts.contains(tilt.id) {
            result.append(
                EffectBlockItem(
                    zoomID: nil,
                    tiltID: tilt.id,
                    startTime: map.outputTime(forSource: tilt.startTime),
                    endTime: map.outputTime(forSource: tilt.endTime),
                    zoomLevel: nil,
                    pitch: tilt.pitch,
                    yaw: tilt.yaw,
                    roll: tilt.roll
                )
            )
        }
        // The Slide joins a block whose output span it matches — one linked
        // block on the lane instead of two stacked chips.
        if project.settings.introSlideStyle != .off {
            let s0 = project.settings.introSlideStart
            let s1 = s0 + project.settings.introSlideDuration
            if let i = result.firstIndex(where: {
                abs($0.startTime - s0) < 0.05 && abs($0.endTime - s1) < 0.08
            }) {
                result[i].hasSlide = true
            }
        }
        return result
    }

    /// The value the lane canvas renders from. `sliceArmed` is the host's
    /// slice-tool state.
    func timelineCanvasSnapshot(sliceArmed sliceMode: Bool) -> TimelineCanvasSnapshot {
        let map = fullTimeMap
        let focus: [TimelineFocusItem] =
            project.blurRegions.map { region in
                TimelineFocusItem(
                    id: region.id,
                    isHighlight: false,
                    startTime: map.outputTime(forSource: region.startTime),
                    endTime: map.outputTime(forSource: region.endTime),
                    label: RegionLabel.display(region.label),
                    isSelected: selectedBlurID == region.id
                )
            }
            + project.focusRegions.map { region in
                TimelineFocusItem(
                    id: region.id,
                    isHighlight: false,
                    startTime: map.outputTime(forSource: region.startTime),
                    endTime: map.outputTime(forSource: region.endTime),
                    label: RegionLabel.display(region.label),
                    isSelected: selectedDepthFocusID == region.id
                )
            }
            + project.cameraLayoutRegions.map { region in
                TimelineFocusItem(
                    id: region.id,
                    isHighlight: false,
                    startTime: map.outputTime(forSource: region.startTime),
                    endTime: map.outputTime(forSource: region.endTime),
                    label: TimelineEdits.cameraLayoutLaneLabel(region),
                    isSelected: selectedCameraLayoutID == region.id
                )
            }
            + project.highlightRegions.map { region in
                TimelineFocusItem(
                    id: region.id,
                    isHighlight: true,
                    startTime: map.outputTime(forSource: region.startTime),
                    endTime: map.outputTime(forSource: region.endTime),
                    label: RegionLabel.display(region.label),
                    isSelected: selectedHighlightID == region.id
                )
            }

        let annotate: [TimelineAnnotateItem] = project.annotations.map { annotation in
            TimelineAnnotateItem(
                id: annotation.id,
                startTime: map.outputTime(forSource: annotation.startTime),
                endTime: map.outputTime(forSource: annotation.endTime),
                label: TimelineEdits.annotationLaneLabel(for: annotation),
                icon: TimelineEdits.annotationLaneIcon(for: annotation.type),
                isSelected: selectedAnnotationID == annotation.id
            )
        }

        return TimelineCanvasSnapshot(
            outputDuration: outputDuration,
            playheadOutputTime: map.outputTime(forSource: currentTime),
            // Permanently false: the red slice-snap playhead is drawn by the
            // canvas from its OWN hover state (`sliceSnapActive`), which is the
            // only place that knows where the cursor is.
            playheadIsRed: false,
            playheadHitTestEnabled: !sliceMode,
            scrubLabel: TimelineEdits.scrubBubbleText(visibleCurrentTime),
            effectItems: timelineEffectItems(),
            introChipStart: project.settings.introSlideStart,
            introChipEnd: (project.settings.introSlideStyle == .off || slideJoinsABlock) ? nil
                : min(project.settings.introSlideStart
                      + project.settings.introSlideDuration, outputDuration),
            introChipSelected: selection.introSelected,
            introChipLabel: project.settings.introSlideStart <= 0.01
                ? String(localized: "Slide In", comment: "Timeline EFFECTS lane: chip for a slide that plays as the intro")
                : String(localized: "Slide", comment: "Timeline EFFECTS lane: chip for the slide effect"),
            introChipIcon: {
                switch project.settings.introSlideStyle {
                case .top: "arrow.down.to.line"
                case .bottom: "arrow.up.to.line"
                case .left: "arrow.right.to.line"
                case .right: "arrow.left.to.line"
                case .off: "arrow.up.to.line"
                }
            }(),
            curtainChipStart: project.settings.curtainUnveilStart,
            curtainChipEnd: project.settings.curtainUnveilCorner == .off ? nil
                : min(project.settings.curtainUnveilStart
                      + project.settings.curtainUnveilDuration, outputDuration),
            curtainChipSelected: selection.curtainSelected,
            selectedZoomID: selectedZoomID,
            selectedTiltID: selectedTiltID,
            focusItems: focus,
            annotateItems: annotate,
            trimStartOutput: map.outputTime(forSource: project.effectiveTrimStart),
            trimEndOutput: map.outputTime(forSource: project.effectiveTrimEnd),
            sliceArmed: sliceMode,
            timelessVideo: project.hidesTimelinePlayhead,
            dimmedRuler: project.presentsTimelessTimeline && project.hasTimedEffects
        )
    }

    func timelineVideoRowModel(hasAudio: Bool, hasThumbnails: Bool) -> TimelineVideoRowModel {
        let map = fullTimeMap
        return TimelineVideoRowModel.make(
            project: project,
            timeMap: map,
            selectedClipID: selectedClipID,
            hasAudio: hasAudio,
            hasThumbnails: hasThumbnails,
            snapCandidates: videoTrackSnapCandidates(for: project).map { map.outputTime(forSource: $0) }
        )
    }

    /// Presentation-ready VOICE row snapshot (`TimelineVoiceRowModel.make`).
    func timelineVoiceRowModel(
        isRecordingVoiceOver: Bool, recordingStartTime: TimeInterval?, liveSamples: [Float]
    ) -> TimelineVoiceRowModel {
        TimelineVoiceRowModel.make(
            project: project,
            timeMap: fullTimeMap,
            outputDuration: outputDuration,
            playheadTime: currentTime,
            selectedVoiceOverID: selectedVoiceOverID,
            isRecordingVoiceOver: isRecordingVoiceOver,
            recordingStartTime: recordingStartTime,
            recordingCurrentTime: currentTime,
            liveSamples: liveSamples
        )
    }

    /// Context-menu rows for a camera-layout block: the Side by Side camera
    /// side, then Copy / Paste Layout. Other FOCUS blocks get none.
    func cameraLayoutMenuEntries(id: UUID) -> [TimelineMenuEntry] {
        guard let region = project.cameraLayoutRegions.first(where: { $0.id == id }) else { return [] }
        var entries: [TimelineMenuEntry] = []
        if region.mode == .sideBySide {
            for side in CameraSide.allCases {
                entries.append(TimelineMenuEntry(
                    title: side.displayName, checked: region.effectiveSide == side,
                    action: { [weak self] in self?.setCameraSide(side, regionID: id) }))
            }
            entries.append(.separator)
            for split in [CameraSplitStyle.full, .tiles] {
                entries.append(TimelineMenuEntry(
                    title: split == .full
                        ? String(localized: "Full Height", comment: "Camera layout block menu: split style, full-height columns")
                        : String(localized: "Tiles", comment: "Camera layout block menu: split style, equal tiles"),
                    checked: region.effectiveSplitStyle == split,
                    action: { [weak self] in self?.setSplitStyle(split, regionID: id) }))
            }
            entries.append(.separator)
        }
        entries.append(TimelineMenuEntry(title: String(localized: "Copy Layout", comment: "Camera layout block menu item"), action: {
            TimelineEdits.copiedCameraLayout = (region.mode, region.look, region.cameraSide, region.splitStyle)
        }))
        entries.append(TimelineMenuEntry(
            title: String(localized: "Paste Layout", comment: "Camera layout block menu item"), isEnabled: TimelineEdits.copiedCameraLayout != nil,
            action: { [weak self] in self?.pasteCameraLayout(regionID: id) }))
        return entries
    }
}

// MARK: - Callback tables

extension TimelineHosting {
    /// SOURCE time under a lane x (0…trackWidth), or nil for an empty project
    /// — the scrub / seek conversion.
    func timelineSourceTime(atX x: CGFloat, trackWidth width: CGFloat) -> TimeInterval? {
        guard project.duration > 0 else { return nil }
        let fraction = max(0, min(1, x / width))
        let outputSeekTime = fraction * outputDuration
        return fullTimeMap.sourceTime(forOutput: outputSeekTime)
    }

    /// Output-time callbacks from the canvas, converted to source time here
    /// and routed into the shared undo-registered operations (one step per
    /// edit, FOCUS drags and chip drags included). `trackWidth` is baked into
    /// the scrub/seek closures BY VALUE — rebuild the table when it changes.
    func timelineCanvasCallbacks(trackWidth scaledWidth: CGFloat) -> TimelineCanvasCallbacks {
        let map = fullTimeMap
        return TimelineCanvasCallbacks(
            scrub: { [self] x in
                timelineRequestFocus()
                if let time = timelineSourceTime(atX: x, trackWidth: scaledWidth) {
                    timelineScrub(toSource: time, exact: false)
                }
            },
            seek: { [self] x in
                if let time = timelineSourceTime(atX: x, trackWidth: scaledWidth) {
                    timelineScrub(toSource: time, exact: true)
                }
            },
            selectEffect: { [self] zoomID, tiltID in
                selectEffectBlock(zoomID: zoomID, tiltID: tiltID)
                // Clicking the canvas must not strand keyboard focus —
                // ⌫/space/arrows live on the focused timeline view.
                timelineRequestFocus()
            },
            openIntro: { [self] in openIntroSlide() },
            deleteIntro: { [self] in
                selection.introSelected = true
                _ = deleteSelectedRegion()
            },
            resizeIntro: { [self] end in resizeIntroSlide(end: end) },
            moveIntro: { [self] start in moveIntroSlide(start: start) },
            openCurtain: { [self] in openCurtainUnveil() },
            deleteCurtain: { [self] in
                selection.curtainSelected = true
                _ = deleteSelectedRegion()
            },
            resizeCurtain: { [self] end in resizeCurtainUnveil(end: end) },
            moveCurtain: { [self] start in moveCurtainUnveil(start: start) },
            chipSpans: { [self] in chipSpans },
            commitChipDrag: { [self] before in commitChipDrag(from: before) },
            commitEffectTimes: { [self] zoomID, tiltID, start, end in
                commitEffectBlockTimes(
                    zoomID: zoomID,
                    tiltID: tiltID,
                    start: map.sourceTime(forOutput: start),
                    end: map.sourceTime(forOutput: end)
                )
            },
            setZoomLevel: { [self] id, level in setZoomLevel(id: id, level: level) },
            addZoomToBlock: { [self] tiltID in addZoomToBlock(tiltID: tiltID) },
            addTiltToBlock: { [self] zoomID in addTiltToBlock(zoomID: zoomID) },
            removeZoom: { [self] id in deleteZoomRegion(id: id) },
            removeTilt: { [self] id in deleteTiltRegion(id: id) },
            deleteEffectBlock: { [self] zoomID, tiltID in deleteEffectBlock(zoomID: zoomID, tiltID: tiltID) },
            addZoomAt: { [self] time in addZoomRegion(at: map.sourceTime(forOutput: time)) },
            addTiltAt: { [self] time in addTiltRegion(at: map.sourceTime(forOutput: time)) },
            selectFocus: { [self] id, isHighlight in
                selection.introSelected = false
                selection.curtainSelected = false
                timelineRequestFocus()
                selectFocusItem(id: id, isHighlight: isHighlight)
            },
            commitFocusTimes: { [self] id, isHighlight, start, end in
                commitFocusTimes(
                    id: id, isHighlight: isHighlight,
                    sourceStart: map.sourceTime(forOutput: start),
                    sourceEnd: map.sourceTime(forOutput: end))
            },
            deleteFocus: { [self] id, isHighlight in deleteFocusItem(id: id, isHighlight: isHighlight) },
            focusMenuExtras: { [self] id in cameraLayoutMenuEntries(id: id) },
            addBlurAt: { [self] time in addBlurRegion(at: map.sourceTime(forOutput: time)) },
            addHighlightAt: { [self] time in addHighlightRegion(at: map.sourceTime(forOutput: time)) },
            selectAnnotation: { [self] id in
                selection.introSelected = false
                selection.curtainSelected = false
                selectedAnnotationID = id
                // Seek-if-not-visible (the usual video-editor overlay pattern):
                // when the playhead is outside the block's span, jump into it
                // so the selected annotation is actually ON SCREEN — which is
                // also what summons the contextual toolbar above it. Inside
                // the span, the playhead stays put (never yank the playhead needlessly).
                if let a = project.annotations.first(where: { $0.id == id }),
                   currentTime < a.startTime || currentTime > a.endTime {
                    timelinePause()
                    timelineSeek(toSource: min(a.startTime + 0.05, a.endTime))
                }
                timelineRequestFocus()
            },
            commitAnnotationTimes: { [self] id, start, end in
                commitAnnotationTimes(
                    id: id,
                    start: map.sourceTime(forOutput: start),
                    end: map.sourceTime(forOutput: end)
                )
            },
            deleteAnnotation: { [self] id in deleteAnnotation(id: id) },
            addAnnotationAt: { [self] type, time in
                addAnnotation(type: type, atSource: map.sourceTime(forOutput: time))
            },
            deleteSelection: { [self] in _ = deleteSelectedRegion() },
            togglePlayback: { [self] in timelineTogglePlayback() }
        )
    }

    /// VIDEO-row callbacks: clip/trim edits through `VideoTrackCommits`,
    /// speed and split through the shared operations.
    func timelineVideoCallbacks() -> TimelineVideoCallbacks {
        let commits = VideoTrackCommits(
            project: project,
            timeMap: fullTimeMap,
            undoManager: undoManager,
            outputDuration: outputDuration
        )
        return TimelineVideoCallbacks(
            selectClip: { [self] id in
                selectedClipID = id
                // Clicking the canvas must not strand keyboard focus.
                timelineRequestFocus()
            },
            commitWholeDrag: { mode, delta, start, end in
                commits.commitWholeDrag(mode: mode, delta: delta, resolvedStart: start, resolvedEnd: end)
            },
            commitClipMove: { clip, resolvedStart in
                commits.commitClipMove(clip, resolvedOutputStart: resolvedStart)
            },
            commitClipEdge: { clip, side, resolved in
                commits.commitClipEdge(clip, side: side, resolvedOutput: resolved)
            },
            toggleMute: { [self] in toggleRecordedAudioMute() },
            addSpeedRange: { [self] start, end, speed in addSpeedRegion(start: start, end: end, speed: speed) },
            changeSpeed: { [self] id, speed in changeSpeedRegion(id: id, speed: speed) },
            deleteSpeed: { [self] id in deleteSpeedRegion(id: id) },
            deleteSplit: { [self] outputTime in removeSplit(nearOutputTime: outputTime) },
            sliceAt: { [self] outputTime in
                let sourceTime = fullTimeMap.sourceTime(forOutput: outputTime)
                if splitVideoClip(at: sourceTime) {
                    timelineSliceCommitted()
                }
            }
        )
    }

    /// VOICE-row callbacks: clip moves/trims through `VoiceTrackCommits`.
    func timelineVoiceCallbacks() -> TimelineVoiceCallbacks {
        let map = fullTimeMap
        return TimelineVoiceCallbacks(
            selectClip: { [self] id in
                selectedVoiceOverID = id
                // Clicking the canvas must not strand keyboard focus.
                timelineRequestFocus()
            },
            commitClip: { [self] id, outputValue in
                commitVoiceClip(id: id, outputValue: outputValue, timeMap: map)
            },
            deleteClip: { [self] id in deleteVoiceOverClip(id: id) }
        )
    }
}
