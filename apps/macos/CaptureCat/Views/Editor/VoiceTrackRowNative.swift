import AppKit

// MARK: - Shared edit math (VOICE row)

/// The voice-over clip drag resolver, lifted verbatim out of
/// `VoiceOverClipBlockView.resolvedClip(from:delta:)` so the SwiftUI block and
/// the native canvas row cannot drift — the same pattern `VideoTrackEditMath`
/// applies to the VIDEO row. Every time here is OUTPUT time; the caller maps
/// back into source time at the commit boundary.
struct VoiceTrackEditMath {
    enum Mode {
        case none
        case move
        case resizeLeft
        case resizeRight
    }

    var totalDuration: TimeInterval
    var trackWidth: CGFloat
    var snapCandidates: [TimeInterval]
    var minDuration: TimeInterval = 0.25

    /// Output-time delta for a horizontal drag translation.
    func delta(forTranslation translationX: CGFloat) -> TimeInterval {
        guard trackWidth > 0 else { return 0 }
        return TimeInterval(translationX / trackWidth) * totalDuration
    }

    func resolvedClip(from initial: VoiceOverClip, mode: Mode, delta: TimeInterval) -> VoiceOverClip {
        let snapEdge: (TimeInterval, [TimeInterval]) -> TimeInterval? = { time, excludedEdges in
            let candidates = snapCandidates.filter { candidate in
                !excludedEdges.contains(where: { abs($0 - candidate) < 0.0001 })
            }
            return TimelineSnap.nearestCandidate(
                to: time,
                candidates: candidates,
                duration: totalDuration,
                trackWidth: trackWidth
            )
        }

        var next = initial

        switch mode {
        case .none:
            break
        case .move:
            let duration = initial.duration
            let proposedStart = initial.startTime + delta
            let proposedEnd = proposedStart + duration
            let candidates = snapCandidates.filter { candidate in
                abs(candidate - initial.startTime) >= 0.0001 && abs(candidate - initial.endTime) >= 0.0001
            }
            let snappedStartCandidate = TimelineSnap.nearestCandidate(
                to: proposedStart,
                candidates: candidates,
                duration: totalDuration,
                trackWidth: trackWidth
            )
            let snappedEndCandidate = TimelineSnap.nearestCandidate(
                to: proposedEnd,
                candidates: candidates,
                duration: totalDuration,
                trackWidth: trackWidth
            )

            let adjustedStart: TimeInterval
            switch (snappedStartCandidate, snappedEndCandidate) {
            case let (start?, end?):
                adjustedStart = abs(start - proposedStart) <= abs(end - proposedEnd) ? start : (end - duration)
            case let (start?, nil):
                adjustedStart = start
            case let (nil, end?):
                adjustedStart = end - duration
            case (nil, nil):
                adjustedStart = proposedStart
            }

            next.startTime = max(0, min(totalDuration - duration, adjustedStart))

        case .resizeLeft:
            let snappedStart = snapEdge(initial.startTime + delta, [initial.startTime, initial.endTime])
                ?? (initial.startTime + delta)
            let earliestStart = max(0, initial.startTime - initial.sourceStartTime)
            let latestStart = initial.endTime - minDuration
            let newStart = min(max(snappedStart, earliestStart), latestStart)
            let sourceDelta = newStart - initial.startTime
            next.startTime = newStart
            next.sourceStartTime = max(0, initial.sourceStartTime + sourceDelta)
            next.duration = max(minDuration, initial.endTime - newStart)

        case .resizeRight:
            let snappedEnd = snapEdge(initial.endTime + delta, [initial.startTime, initial.endTime])
                ?? (initial.endTime + delta)
            let maxEnd = min(
                totalDuration,
                initial.startTime + max(minDuration, initial.sourceDuration - initial.sourceStartTime)
            )
            let newEnd = max(initial.startTime + minDuration, min(maxEnd, snappedEnd))
            next.duration = max(minDuration, newEnd - initial.startTime)
        }

        next.clamp(to: totalDuration)
        return next
    }

}

// MARK: - Shared commit logic

/// The VOICE row's output→source mapping and model write, extracted from
/// `VoiceOverTrackContent.outputBinding(for:)` so the SwiftUI row and the
/// native canvas row commit IDENTICALLY.
///
/// Deliberately registers NO undo: the SwiftUI voice block never did (only
/// `deleteVoiceOverClip` registers, and that path is untouched). Preserving
/// that exactly is part of the port's contract.
@MainActor
struct VoiceTrackCommits {
    let project: Project
    let timeMap: SpeedTimeMap

    /// Port of the binding's getter — the stored clip remapped into output time.
    func outputClip(for stored: VoiceOverClip) -> VoiceOverClip {
        var copy = stored
        let outStart = timeMap.outputTime(forSource: stored.startTime)
        let outEnd = timeMap.outputTime(forSource: stored.startTime + stored.duration)
        copy.startTime = outStart
        copy.duration = max(0.01, outEnd - outStart)
        return copy
    }

    /// Port of the binding's setter — an output-time clip value written back
    /// into `project.voiceOverClips` as source time.
    func commit(id: UUID, outputValue: VoiceOverClip) {
        guard let idx = project.voiceOverClips.firstIndex(where: { $0.id == id }) else { return }
        var stored = project.voiceOverClips[idx]
        let newSourceStart = timeMap.sourceTime(forOutput: outputValue.startTime)
        let newSourceEnd = timeMap.sourceTime(forOutput: outputValue.startTime + outputValue.duration)
        stored.startTime = newSourceStart
        stored.duration = max(0.01, newSourceEnd - newSourceStart)
        stored.sourceStartTime = outputValue.sourceStartTime
        stored.gain = outputValue.gain
        stored.label = outputValue.label
        project.voiceOverClips[idx] = stored
    }
}

// MARK: - Snapshot model (VOICE row)

/// One voice-over clip slab. `clip` carries OUTPUT time (already remapped by
/// `VoiceTrackCommits.outputClip`), which is exactly the value the SwiftUI
/// block view sees through its binding.
struct TimelineVoiceClipItem: Equatable {
    var clip: VoiceOverClip
    var isSelected: Bool

    var id: UUID { clip.id }
}

/// The live recording block. Its samples ride inside the Equatable model on
/// purpose: they arrive per meter update and every arrival must repaint.
struct TimelineVoiceLiveItem: Equatable {
    var startTime: TimeInterval
    var currentTime: TimeInterval
    var samples: [Float]
}

/// Everything the canvas needs to draw and edit the VOICE row natively.
/// Waveform sample arrays for committed clips ride outside (see
/// `TimelineVoiceAssets`); only the live recording samples live here.
struct TimelineVoiceRowModel: Equatable {
    var clips: [TimelineVoiceClipItem] = []
    var live: TimelineVoiceLiveItem?
    /// Output-time snap candidates. The dragged clip's own edges are filtered
    /// out by VALUE inside `VoiceTrackEditMath`, which is what the SwiftUI
    /// per-clip list did too — so one shared list is equivalent.
    var snapCandidates: [TimeInterval] = []

    func item(withID id: UUID) -> TimelineVoiceClipItem? {
        clips.first { $0.id == id }
    }

    /// Derives the row snapshot from the project. Every step is a port of the
    /// matching `VoiceOverTrackContent` expression, so the hosted row and the
    /// native row describe the same geometry. Lives here (not in TimelineView)
    /// so the screenshot harness renders exactly what ships.
    @MainActor
    static func make(
        project: Project,
        timeMap: SpeedTimeMap,
        outputDuration: TimeInterval,
        playheadTime: TimeInterval,
        selectedVoiceOverID: UUID?,
        isRecordingVoiceOver: Bool,
        recordingStartTime: TimeInterval?,
        recordingCurrentTime: TimeInterval,
        liveSamples: [Float]
    ) -> TimelineVoiceRowModel {
        let commits = VoiceTrackCommits(project: project, timeMap: timeMap)

        let clips = project.voiceOverClips.map { stored in
            TimelineVoiceClipItem(
                clip: commits.outputClip(for: stored),
                isSelected: selectedVoiceOverID == stored.id
            )
        }

        // Port of the `if isRecordingVoiceOver, let recordingStartTime, …` gate.
        var live: TimelineVoiceLiveItem?
        if isRecordingVoiceOver,
           let recordingStartTime,
           recordingCurrentTime > recordingStartTime,
           project.duration > 0 {
            live = TimelineVoiceLiveItem(
                startTime: timeMap.outputTime(forSource: recordingStartTime),
                currentTime: timeMap.outputTime(forSource: recordingCurrentTime),
                samples: liveSamples
            )
        }

        // Port of `snapCandidates(for:)`, minus the per-clip self-exclusion
        // (see `snapCandidates` above).
        var sources: [TimeInterval] = [
            project.effectiveTrimStart,
            project.effectiveTrimEnd,
            playheadTime,
        ]
        sources += project.zoomRegions.flatMap { [$0.startTime, $0.endTime] }
        sources += project.blurRegions.flatMap { [$0.startTime, $0.endTime] }
        sources += project.highlightRegions.flatMap { [$0.startTime, $0.endTime] }
        sources += project.voiceOverClips.flatMap { [$0.startTime, $0.endTime] }

        return TimelineVoiceRowModel(
            clips: clips,
            live: live,
            snapCandidates: sources.map { timeMap.outputTime(forSource: $0) }
        )
    }
}

/// Heavy, non-Equatable render inputs for the VOICE row (kept out of the
/// diffed snapshot): the per-clip waveforms the SwiftUI block loaded itself in
/// `.task(id: blockSignature)`. TimelineView owns the loading now; `signature`
/// is the same identity string the task keyed on.
nonisolated struct TimelineVoiceAssets {
    var waveforms: [UUID: [Float]] = [:]
    var signature: String = ""

    var renderKey: String { signature }

    /// Port of `VoiceOverClipBlockView.blockSignature`, per clip.
    static func signature(for clip: VoiceOverClip) -> String {
        "\(clip.fileName):\(clip.sourceStartTime):\(clip.duration):\(clip.sourceDuration):\(clip.gain)"
    }
}

/// VOICE-row mutations out of the canvas. Scrub/seek reuse the generic
/// `TimelineCanvasCallbacks`, exactly as the hosted row reused TimelineView's
/// `onScrub` / `onSeek`.
struct TimelineVoiceCallbacks {
    var selectClip: (UUID?) -> Void = { _ in }
    /// (clip id, resolved OUTPUT-time clip value) — lands in `VoiceTrackCommits`.
    var commitClip: (UUID, VoiceOverClip) -> Void = { _, _ in }
    var deleteClip: (UUID) -> Void = { _ in }
}

// MARK: - Drag state

/// VOICE-row drag state — its own machine so the VIDEO lane and the generic
/// block lanes stay untouched.
struct VoiceRowDrag {
    /// The clip value captured at mouse-down, in OUTPUT time.
    var initial: VoiceOverClip
    var mode: VoiceTrackEditMath.Mode
    var startPoint: CGPoint
    var translationX: CGFloat = 0
    var didDrag = false

    /// `VoiceOverClipBlockView.dragThreshold` — a 2D distance, not |dx|.
    static let threshold: CGFloat = 3
}

// MARK: - Geometry, hit testing, drawing

extension TimelineCanvasView {
    private typealias VC = TimelineCanvasMetrics

    /// Resolved once — the exact colours the hosted row fills with.
    static let voiceOrange = NSColor.systemOrange

    /// `VoiceOverClipBlockView.handleWidth` (hit zone, not the drawn grip).
    static let voiceHandleWidth: CGFloat = 8
    /// `max(52, …)` floor on the drawn block width.
    static let voiceMinBlockWidth: CGFloat = 52
    static let voiceCornerRadius: CGFloat = 6
    static let voiceMinDuration: TimeInterval = 0.25
    /// `.font(.caption2.bold())`
    static let voiceTitleFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    static let voiceWaveHeight: CGFloat = 16
    static let voiceVerticalPadding: CGFloat = 8
    static let voiceHorizontalPadding: CGFloat = 10
    /// CoreGraphics blur for SwiftUI's `.shadow(radius: 6)` — SwiftUI's radius
    /// is roughly half the CG blur; 12 matched the hosted row's halo falloff.
    static let voiceSelectionShadowBlur: CGFloat = 12

    var voiceLaneRect: CGRect {
        CGRect(x: 0, y: VC.voiceLaneY, width: bounds.width, height: VC.trackHeight)
    }

    /// The math struct for the current model — identical inputs to the SwiftUI
    /// block's `resolvedClip`.
    func voiceEditMath(_ model: TimelineVoiceRowModel) -> VoiceTrackEditMath {
        VoiceTrackEditMath(
            totalDuration: snapshot.outputDuration,
            trackWidth: bounds.width,
            snapCandidates: model.snapCandidates,
            minDuration: Self.voiceMinDuration
        )
    }

    // MARK: Block geometry (port of blockWidth / blockOffsetX / displayOffsetX)

    /// The live drag for `clip`, if any.
    private func voiceActiveDrag(for id: UUID) -> VoiceRowDrag? {
        guard let drag = voiceDrag, drag.initial.id == id, drag.mode != .none else { return nil }
        return drag
    }

    /// Port of `previewClip` — the snapped resolve of the in-flight drag.
    func voicePreviewClip(_ item: TimelineVoiceClipItem, model: TimelineVoiceRowModel) -> VoiceOverClip {
        guard let drag = voiceActiveDrag(for: item.id), snapshot.outputDuration > 0 else {
            return item.clip
        }
        let math = voiceEditMath(model)
        return math.resolvedClip(
            from: drag.initial,
            mode: drag.mode,
            delta: math.delta(forTranslation: drag.translationX)
        )
    }

    /// Port of `blockWidth`.
    func voiceBlockWidth(_ item: TimelineVoiceClipItem, model: TimelineVoiceRowModel) -> CGFloat {
        let duration = snapshot.outputDuration
        guard duration > 0 else { return bounds.width }
        let preview = voicePreviewClip(item, model: model)
        return max(Self.voiceMinBlockWidth, bounds.width * CGFloat(preview.duration / duration))
    }

    /// Port of `committedBlockOffsetX`.
    func voiceCommittedOffsetX(_ item: TimelineVoiceClipItem) -> CGFloat {
        let duration = snapshot.outputDuration
        guard duration > 0 else { return 0 }
        return bounds.width * CGFloat(item.clip.startTime / duration)
    }

    /// Port of `blockOffsetX + displayOffsetX` — the drawn origin. Move mode
    /// deliberately follows the cursor with a pixel clamp and NO snap preview;
    /// the resize modes show the resolved (snapped) edge live.
    func voiceBlockOriginX(_ item: TimelineVoiceClipItem, model: TimelineVoiceRowModel) -> CGFloat {
        let duration = snapshot.outputDuration
        guard duration > 0 else { return 0 }
        let committed = voiceCommittedOffsetX(item)
        let drag = voiceActiveDrag(for: item.id)

        let baseX: CGFloat
        if drag?.mode == .move {
            baseX = committed
        } else {
            baseX = bounds.width * CGFloat(voicePreviewClip(item, model: model).startTime / duration)
        }

        guard let drag, drag.mode == .move else { return baseX }
        let width = voiceBlockWidth(item, model: model)
        let maxX = max(0, bounds.width - width)
        let proposedX = committed + drag.translationX
        return baseX + (min(max(proposedX, 0), maxX) - committed)
    }

    /// Drawn rect of a clip slab (full lane height — the SwiftUI block only
    /// constrains its width).
    func voiceClipRect(_ item: TimelineVoiceClipItem, model: TimelineVoiceRowModel) -> CGRect {
        CGRect(
            x: voiceBlockOriginX(item, model: model),
            y: VC.voiceLaneY,
            width: voiceBlockWidth(item, model: model),
            height: VC.trackHeight
        )
    }

    /// Committed (pre-drag) rect — the hit-test target, matching the SwiftUI
    /// block whose `contentShape` sits at the committed offset when a gesture
    /// begins.
    func voiceCommittedRect(_ item: TimelineVoiceClipItem, model: TimelineVoiceRowModel) -> CGRect {
        let duration = snapshot.outputDuration
        guard duration > 0 else { return .zero }
        return CGRect(
            x: voiceCommittedOffsetX(item),
            y: VC.voiceLaneY,
            width: max(Self.voiceMinBlockWidth, bounds.width * CGFloat(item.clip.duration / duration)),
            height: VC.trackHeight
        )
    }

    /// Port of the live recording block's `blockOffsetX` / `blockWidth`.
    func voiceLiveRect(_ live: TimelineVoiceLiveItem) -> CGRect {
        let duration = snapshot.outputDuration
        guard duration > 0 else {
            return CGRect(x: 0, y: VC.voiceLaneY, width: bounds.width, height: VC.trackHeight)
        }
        let visibleDuration = max(0.1, live.currentTime - live.startTime)
        return CGRect(
            x: bounds.width * CGFloat(live.startTime / duration),
            y: VC.voiceLaneY,
            width: max(Self.voiceMinBlockWidth, bounds.width * CGFloat(visibleDuration / duration)),
            height: VC.trackHeight
        )
    }

    // MARK: Hit testing

    /// Later clips draw on top (`ForEach` order), so hit test in reverse.
    /// The live recording block is `allowsHitTesting(false)` and is skipped.
    func voiceClipItem(at point: CGPoint, model: TimelineVoiceRowModel) -> TimelineVoiceClipItem? {
        for item in model.clips.reversed() where voiceCommittedRect(item, model: model).contains(point) {
            return item
        }
        return nil
    }

    /// Port of `dragStartX` + the handle test in the block's `onChanged`.
    func voiceDragMode(at point: CGPoint, item: TimelineVoiceClipItem, model: TimelineVoiceRowModel) -> VoiceTrackEditMath.Mode {
        let rect = voiceCommittedRect(item, model: model)
        let localX = min(max(point.x - rect.minX, 0), rect.width)
        if localX < Self.voiceHandleWidth { return .resizeLeft }
        if localX > rect.width - Self.voiceHandleWidth { return .resizeRight }
        return .move
    }

    // MARK: Drag lifecycle (driven by the canvas mouse state machine)

    /// Returns true when a clip drag started; false means the press landed on
    /// empty lane (the caller scrubs, as the SwiftUI `trackBackground` did).
    @discardableResult
    func voiceMouseDown(at point: CGPoint, model: TimelineVoiceRowModel) -> Bool {
        guard snapshot.outputDuration > 0 else { return false }
        guard let item = voiceClipItem(at: point, model: model) else {
            // `trackBackground` deselects then scrubs/seeks.
            voiceCallbacks?.selectClip(nil)
            return false
        }
        // DragGesture(minimumDistance: 0) fires onChanged at touch-down, which
        // is where the SwiftUI block selects itself.
        if !item.isSelected { voiceCallbacks?.selectClip(item.id) }
        voiceDrag = VoiceRowDrag(
            initial: item.clip,
            mode: voiceDragMode(at: point, item: item, model: model),
            startPoint: point
        )
        voiceHoveredClipID = nil
        return true
    }

    func voiceMouseDragged(to point: CGPoint) {
        guard var drag = voiceDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        let dy = point.y - drag.startPoint.y
        if !drag.didDrag,
           sqrt(drag.translationX * drag.translationX + dy * dy) >= VoiceRowDrag.threshold {
            drag.didDrag = true
        }
        voiceDrag = drag
        // Everything this row draws lives inside the lane rect.
        setNeedsDisplay(voiceLaneRect)
    }

    func voiceMouseUp(at point: CGPoint, model: TimelineVoiceRowModel) {
        guard var drag = voiceDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        let dy = point.y - drag.startPoint.y
        if !drag.didDrag,
           sqrt(drag.translationX * drag.translationX + dy * dy) >= VoiceRowDrag.threshold {
            drag.didDrag = true
        }
        defer {
            voiceDrag = nil
            setNeedsDisplay(voiceLaneRect)
        }

        // `guard didDrag … else { onSelect(); return }`
        guard drag.didDrag, snapshot.outputDuration > 0 else {
            voiceCallbacks?.selectClip(drag.initial.id)
            return
        }
        let math = voiceEditMath(model)
        let resolved = math.resolvedClip(
            from: drag.initial,
            mode: drag.mode,
            delta: math.delta(forTranslation: drag.translationX)
        )
        voiceCallbacks?.commitClip(drag.initial.id, resolved)
    }

    /// Hover cursor for the VOICE lane, or nil to leave the cursor alone —
    /// port of the block's `.onContinuousHover`, which pushes nothing over the
    /// lane background.
    func voiceHoverCursor(at point: CGPoint, model: TimelineVoiceRowModel) -> NSCursor? {
        guard voiceDrag == nil, let item = voiceClipItem(at: point, model: model) else { return nil }
        switch voiceDragMode(at: point, item: item, model: model) {
        case .resizeLeft, .resizeRight: return .resizeLeftRight
        case .move: return .openHand
        case .none: return nil
        }
    }

    // MARK: Context menu

    func voiceContextMenu(at point: CGPoint, model: TimelineVoiceRowModel) -> NSMenu? {
        guard let item = voiceClipItem(at: point, model: model) else { return nil }
        let menu = NSMenu()
        menu.addItem(VideoRowMenuItem(title: "Delete Voice Over", destructive: true) { [weak self] in
            self?.voiceCallbacks?.deleteClip(item.id)
        })
        return menu
    }

    // MARK: - Drawing

    /// SwiftUI's block is TALLER than the 48pt lane: the padded VStack's ideal
    /// height (row + 4 + 16 + 2x8 padding) wins over the proposal, and the
    /// hosting frame clips the overflow. Reproducing that is the difference
    /// between a 3px border and the 1px sliver the app actually shows.
    func voiceBlockRect(x: CGFloat, width: CGFloat, rowHeight: CGFloat) -> CGRect {
        let height = rowHeight + 4 + Self.voiceWaveHeight + Self.voiceVerticalPadding * 2
        return CGRect(
            x: x,
            y: VC.voiceLaneY + (VC.trackHeight - height) / 2,
            width: width,
            height: height
        )
    }

    /// Height of the block's first row: SwiftUI's HStack takes the tallest of
    /// the `.caption2` line box, the symbol and the recording dot.
    func voiceRowHeight(icon: NSImage?, dot: CGFloat?) -> CGFloat {
        // SwiftUI's Text line box rounds ascent and descent outward — this is
        // the metric that makes the block land at the 50pt the hosted row
        // measures (verified against the SwiftUI screenshot, both blocks).
        let font = Self.voiceTitleFont
        let line = ceil(font.ascender) - floor(font.descender) + ceil(font.leading)
        return max(line, max(icon?.size.height ?? 0, dot ?? 0))
    }

    func drawVoiceLane(in context: CGContext, model: TimelineVoiceRowModel) {
        guard snapshot.outputDuration > 0, bounds.width > 0 else { return }

        context.saveGState()
        // The hosted row lived in a 48pt NSHostingView, which clipped the
        // block's overflowing top/bottom edges. The canvas has no such frame.
        context.clip(to: voiceLaneRect)

        // ZStack order: the live recording block sits under the clips.
        if let live = model.live {
            drawVoiceLiveBlock(live, in: context)
        }
        for item in model.clips {
            drawVoiceClip(item, model: model, in: context)
        }
        context.restoreGState()
    }

    private func drawVoiceClip(
        _ item: TimelineVoiceClipItem,
        model: TimelineVoiceRowModel,
        in context: CGContext
    ) {
        let lane = voiceClipRect(item, model: model)
        guard lane.width > 0.5 else { return }

        let isSelected = item.isSelected
        let isHovering = voiceHoveredClipID == item.id && voiceDrag == nil
        let display = voicePreviewClip(item, model: model)

        // The slab fill is translucent orange over the PANEL background, so
        // the title/waveform ink follows the theme (the orange strokes/grips
        // are the lane's brand color and stay fixed).
        let ink: NSColor = CCTheme.isDark ? .white : .black
        let titleColor = ink.withAlphaComponent(0.92)
        let glyph = Self.tintedSymbol(
            "waveform.and.mic", pointSize: 10, weight: .semibold, color: titleColor
        )
        let rowHeight = voiceRowHeight(icon: glyph, dot: nil)
        let rect = voiceBlockRect(x: lane.minX, width: lane.width, rowHeight: rowHeight)

        context.saveGState()
        // `.opacity(dragMode != .none && didDrag ? 0.84 : 1)`
        if let drag = voiceActiveDrag(for: item.id), drag.didDrag { context.setAlpha(0.84) }
        // `.shadow(color: isSelected ? .orange.opacity(0.45) : .clear, radius: 6)`.
        // SwiftUI shadows the COMPOSITED block (slab + border + content), and
        // the translucent fill then reads over it — so the shadow must be set
        // on the transparency layer, not painted as a second fill pass.
        if isSelected {
            context.setShadow(
                offset: .zero,
                blur: Self.voiceSelectionShadowBlur,
                color: Self.voiceOrange.withAlphaComponent(0.45).cgColor
            )
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        let fill = Self.voiceOrange.withAlphaComponent(isSelected ? 0.38 : (isHovering ? 0.3 : 0.24))
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: min(Self.voiceCornerRadius, rect.width / 2),
            cornerHeight: Self.voiceCornerRadius,
            transform: nil
        )

        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()

        strokeVoiceRounded(
            rect,
            radius: Self.voiceCornerRadius,
            color: Self.voiceOrange.withAlphaComponent(isSelected ? 1.0 : 0.8),
            width: isSelected ? 2 : 1.5,
            in: context
        )

        drawVoiceContent(
            in: context,
            rect: rect,
            glyph: glyph,
            rowHeight: rowHeight,
            titleSpacing: 5,
            title: display.label,
            titleColor: titleColor,
            leadingDot: nil,
            waveform: { waveRect in
                self.drawVoiceClipWaveform(item, in: waveRect, context: context)
            }
        )

        // Resize grips: 3 x 18, inset 5pt at each end.
        let tint = Self.voiceOrange.withAlphaComponent(isSelected || isHovering ? 0.96 : 0.72)
        drawVoiceHandle(atX: rect.minX + 5, midY: rect.midY, color: tint, in: context)
        drawVoiceHandle(atX: rect.maxX - 5 - 3, midY: rect.midY, color: tint, in: context)

        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawVoiceClipWaveform(
        _ item: TimelineVoiceClipItem,
        in waveRect: CGRect,
        context: CGContext
    ) {
        let samples = voiceAssets.waveforms[item.id] ?? []
        guard !samples.isEmpty else {
            // `RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.14))`,
            // 10pt tall, centred in the 16pt strip.
            let bar = CGRect(
                x: waveRect.minX,
                y: waveRect.midY - 5,
                width: waveRect.width,
                height: 10
            )
            guard bar.width > 0 else { return }
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.setFillColor((CCTheme.isDark ? NSColor.white : NSColor.black)
                .withAlphaComponent(0.14).cgColor)
            context.fillPath()
            return
        }

        drawVoiceBars(
            samples,
            in: waveRect,
            maxBarHeight: waveRect.height,
            minAmplitude: 0,
            color: (CCTheme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.52),
            context: context
        )
    }

    private func drawVoiceLiveBlock(_ live: TimelineVoiceLiveItem, in context: CGContext) {
        let lane = voiceLiveRect(live)
        guard lane.width > 0.5 else { return }

        // Live block: same theme-ink rule as the committed clips.
        let titleColor = (CCTheme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.95)
        let dotSize: CGFloat = 8
        let rowHeight = voiceRowHeight(icon: nil, dot: dotSize)
        let rect = voiceBlockRect(x: lane.minX, width: lane.width, rowHeight: rowHeight)

        let path = CGPath(
            roundedRect: rect,
            cornerWidth: min(Self.voiceCornerRadius, rect.width / 2),
            cornerHeight: Self.voiceCornerRadius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(Self.voiceOrange.withAlphaComponent(0.24).cgColor)
        context.fillPath()
        strokeVoiceRounded(
            rect,
            radius: Self.voiceCornerRadius,
            color: Self.voiceOrange.withAlphaComponent(0.95),
            width: 1.75,
            in: context
        )

        drawVoiceContent(
            in: context,
            rect: rect,
            glyph: nil,
            rowHeight: rowHeight,
            titleSpacing: 6,
            title: "Recording Voice Over",
            titleColor: titleColor,
            leadingDot: dotSize,
            waveform: { waveRect in
                let waveform = live.samples.isEmpty
                    ? [Float](repeating: 0.08, count: 24)
                    : live.samples
                self.drawVoiceBars(
                    waveform,
                    in: waveRect,
                    maxBarHeight: max(6, waveRect.height - 4),
                    minAmplitude: 0.04,
                    color: (CCTheme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.56),
                    context: context
                )
            }
        )

        let handle = Self.voiceOrange.withAlphaComponent(0.92)
        drawVoiceHandle(atX: rect.minX + 5, midY: rect.midY, color: handle, in: context)
        drawVoiceHandle(atX: rect.maxX - 5 - 3, midY: rect.midY, color: handle, in: context)
    }

    /// Shared body layout for both blocks — a leading-aligned VStack
    /// (spacing 4) of [icon/dot + title] over a 16pt waveform strip, inset
    /// 10pt horizontally, vertically centred (the SwiftUI padding is
    /// symmetric, so centring the padded box centres the content box).
    private func drawVoiceContent(
        in context: CGContext,
        rect: CGRect,
        glyph: NSImage?,
        rowHeight: CGFloat,
        titleSpacing: CGFloat,
        title: String,
        titleColor: NSColor,
        leadingDot: CGFloat?,
        waveform: (CGRect) -> Void
    ) {
        let contentX = rect.minX + Self.voiceHorizontalPadding
        let contentWidth = rect.width - Self.voiceHorizontalPadding * 2
        guard contentWidth > 1 else { return }

        let top = rect.minY + Self.voiceVerticalPadding

        var x = contentX
        if let leadingDot {
            let dot = CGRect(
                x: x,
                y: top + (rowHeight - leadingDot) / 2,
                width: leadingDot,
                height: leadingDot
            )
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: dot)
            x += leadingDot + titleSpacing
        }
        if let glyph {
            glyph.draw(in: CGRect(
                x: x,
                y: top + (rowHeight - glyph.size.height) / 2,
                width: glyph.size.width,
                height: glyph.size.height
            ))
            x += glyph.size.width + titleSpacing
        }

        // `.lineLimit(1)` — truncate into whatever width is left.
        let available = max(0, contentX + contentWidth - x)
        if available > 1 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: title, attributes: [
                .font: Self.voiceTitleFont,
                .foregroundColor: titleColor,
                .paragraphStyle: paragraph,
            ])
            let textHeight = ceil(text.size().height)
            text.draw(in: CGRect(
                x: x,
                y: top + (rowHeight - textHeight) / 2,
                width: available,
                height: textHeight
            ))
        }

        waveform(CGRect(
            x: contentX,
            y: top + rowHeight + 4,
            width: contentWidth,
            height: Self.voiceWaveHeight
        ))
    }

    /// Port of both waveform Canvases — centred bars, `max(1, barWidth - 1)`
    /// wide, corner `min(2, width / 2)`.
    private func drawVoiceBars(
        _ samples: [Float],
        in rect: CGRect,
        maxBarHeight: CGFloat,
        minAmplitude: CGFloat,
        color: NSColor,
        context: CGContext
    ) {
        guard !samples.isEmpty, rect.width > 0 else { return }
        let centerY = rect.midY
        let barWidth = max(1, rect.width / CGFloat(max(samples.count, 1)))

        context.setFillColor(color.cgColor)
        for (index, sample) in samples.enumerated() {
            let amplitude = max(minAmplitude, min(1, CGFloat(sample)))
            let height = max(2, amplitude * maxBarHeight)
            let bar = CGRect(
                x: rect.minX + CGFloat(index) * barWidth,
                y: centerY - height / 2,
                width: max(1, barWidth - 1),
                height: height
            )
            let radius = min(2, bar.width / 2)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.fillPath()
    }

    /// Port of `resizeHandle` / `liveHandle` — a 3 × 18 rounded bar.
    private func drawVoiceHandle(atX x: CGFloat, midY: CGFloat, color: NSColor, in context: CGContext) {
        let bar = CGRect(x: x, y: midY - 9, width: 3, height: 18)
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 1, cornerHeight: 1, transform: nil))
        context.fillPath()
    }

    /// `strokeBorder` draws INSIDE the shape, and `RoundedRectangle.inset`
    /// shrinks the corner radius with it.
    private func strokeVoiceRounded(
        _ rect: CGRect,
        radius: CGFloat,
        color: NSColor,
        width: CGFloat,
        in context: CGContext
    ) {
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        guard inset.width > 0, inset.height > 0 else { return }
        context.addPath(CGPath(
            roundedRect: inset,
            cornerWidth: max(0, min(radius - width / 2, inset.width / 2)),
            cornerHeight: max(0, radius - width / 2),
            transform: nil
        ))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokePath()
    }
}
