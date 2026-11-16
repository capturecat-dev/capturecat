import AppKit

// MARK: - Geometry, hit testing, drawing

extension TimelineCanvasView {
    private typealias VM = TimelineCanvasMetrics

    /// The exact colours the hosted row fills with, resolved once. (Verified
    /// against a screenshot of both rows normalised to sRGB: flat slab fill
    /// matches within 10/255 on one channel, mean 2.6/255 over the whole row.)
    static let videoYellow = NSColor.systemYellow
    static let videoOrange = NSColor.systemOrange

    /// Outer hit zone of the whole-track resize handles (SwiftUI `handleWidth`).
    static let videoHandleWidth: CGFloat = 12
    /// SwiftUI `ClipEdgeHandle` frame width: hitWidth 18 + gripInset 5.
    static let videoClipHandleWidth: CGFloat = 23
    static let videoClipHandleHeight: CGFloat = 32
    static let videoBoundaryHitWidth: CGFloat = 30
    static let videoMuteTrailingInset: CGFloat = 18

    var videoLaneRect: CGRect {
        CGRect(x: 0, y: VM.videoLaneY, width: bounds.width, height: VM.trackHeight)
    }

    /// The math struct for the current model — identical inputs to the SwiftUI
    /// row's `editMath`.
    func videoEditMath(_ model: TimelineVideoRowModel) -> VideoTrackEditMath {
        VideoTrackEditMath(
            duration: snapshot.outputDuration,
            trackWidth: bounds.width,
            snapCandidates: model.snapCandidates,
            regionStart: model.regionStart,
            regionEnd: model.regionEnd,
            minDuration: VM.minDuration
        )
    }

    /// Output-time delta for the live drag translation.
    func videoDragDelta(_ translationX: CGFloat) -> TimeInterval {
        TimeInterval(translationX) * snapshot.outputDuration / TimeInterval(max(1, bounds.width))
    }

    // MARK: Block geometry (port of blockOffsetX / blockWidth)

    /// The yellow block's drawn origin+width. Mirrors `VideoTrackContent`'s
    /// `blockOffsetX` / `blockWidth` EXACTLY, including their deliberately
    /// unsnapped, clamped preview math (the committed edges get the snapped
    /// values from `VideoTrackEditMath` on mouse-up).
    func videoBlockGeometry(_ model: TimelineVideoRowModel, preview: Bool = true) -> (x: CGFloat, width: CGFloat) {
        let duration = snapshot.outputDuration
        let width = bounds.width
        guard duration > 0, width > 0 else { return (0, max(40, width)) }

        var mode = VideoTrackEditMath.DragMode.none
        var delta: TimeInterval = 0
        if preview, let drag = videoDrag, case .whole(let m) = drag.kind, m != .none {
            mode = m
            delta = videoDragDelta(drag.translationX)
        }

        let initialStart = model.regionStart
        let initialEnd = model.regionEnd
        let minDuration = VM.minDuration

        let start: TimeInterval
        let end: TimeInterval
        switch mode {
        case .resizeLeft:
            start = max(0, min(initialEnd - minDuration, initialStart + delta))
            end = initialEnd
        case .resizeRight:
            start = initialStart
            end = max(initialStart + minDuration, min(duration, initialEnd + delta))
        case .move:
            let clipDuration = initialEnd - initialStart
            let maxStart = max(0, duration - clipDuration)
            start = min(max(0, initialStart + delta), maxStart)
            end = min(duration, start + clipDuration)
        case .none:
            start = model.regionStart
            end = model.regionEnd
        }

        // blockOffsetX anchors at the initial start while resizing the right edge.
        let originTime = mode == .resizeRight ? initialStart : start
        return (
            x: width * CGFloat(originTime / duration),
            width: max(40, width * CGFloat((end - start) / duration))
        )
    }

    /// Rect of a clip inside the (possibly previewed) block — port of
    /// `clipOffset` / `clipWidth`.
    func videoClipRect(
        _ clip: VideoClipRef,
        model: TimelineVideoRowModel,
        block: (x: CGFloat, width: CGFloat)
    ) -> CGRect {
        let span = model.span
        let x = block.x + max(0, CGFloat((clip.outputStart - model.regionStart) / span) * block.width)
        let w = max(0, CGFloat(clip.outputDuration / span) * block.width)
        return CGRect(x: x, y: VM.videoLaneY, width: w, height: VM.trackHeight)
    }

    /// X of an output time inside the block — port of `outputOffset`.
    func videoOutputOffsetX(
        _ outputTime: TimeInterval,
        model: TimelineVideoRowModel,
        block: (x: CGFloat, width: CGFloat)
    ) -> CGFloat {
        block.x + max(0, CGFloat((outputTime - model.regionStart) / model.span) * block.width)
    }

    /// Live clip span during a per-clip drag — port of `displayClip(for:)`
    /// (`snapsToCandidates: false`, so the preview follows the cursor).
    func videoDisplayClip(_ clip: VideoClipRef, model: TimelineVideoRowModel) -> VideoClipRef {
        guard let drag = videoDrag, drag.didDrag, snapshot.outputDuration > 0 else { return clip }
        let math = videoEditMath(model)
        let spans = model.clipSpans
        let deltaOutput = videoDragDelta(drag.translationX)

        func edge(_ side: VideoTrackEditMath.Side) -> VideoClipRef {
            let original = side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(
                clip.span, in: spans, side: side,
                proposedOutput: original + deltaOutput,
                snapsToCandidates: false
            )
            var out = clip
            if side == .left { out.outputStart = resolved } else { out.outputEnd = resolved }
            return out
        }

        switch drag.kind {
        case .clipMove(let c) where c.id == clip.id:
            let start = math.resolvedClipMoveOutputStart(
                clip.span, in: spans,
                proposedOutputStart: clip.outputStart + deltaOutput,
                snapsToCandidates: false
            )
            var out = clip
            out.outputStart = start
            out.outputEnd = start + clip.outputDuration
            return out
        case .clipEdge(let c, let side) where c.id == clip.id:
            return edge(side)
        case .boundary:
            guard let target = drag.boundaryResolved, target.clip.id == clip.id else { return clip }
            return edge(target.side)
        default:
            return clip
        }
    }

    // MARK: Hit testing

    /// Mute button rect — top-trailing of the block, 18pt trailing inset.
    func videoMuteRect(_ model: TimelineVideoRowModel) -> CGRect? {
        guard model.hasAudio else { return nil }
        let block = videoBlockGeometry(model, preview: false)
        let size = Self.videoMuteSymbolSize(muted: model.isMuted)
        let w = size.width + 10
        let h = size.height + 10
        return CGRect(
            x: block.x + block.width - Self.videoMuteTrailingInset - w,
            y: VM.videoLaneY,
            width: w,
            height: h
        )
    }

    /// Clip whose committed body contains the point.
    func videoClip(at point: CGPoint, model: TimelineVideoRowModel) -> TimelineVideoClipItem? {
        let block = videoBlockGeometry(model, preview: false)
        return model.clips.first { clip in
            videoClipRect(clip.ref, model: model, block: block).contains(point)
        }
    }

    /// Mirrors the SwiftUI hit order: boundary hotspots (top of the ZStack and
    /// high-priority) → per-clip edge handles (high-priority overlays) → clip
    /// body → the whole-track block gesture.
    func videoDragKind(at point: CGPoint, model: TimelineVideoRowModel) -> VideoRowDrag.Kind? {
        guard videoLaneRect.contains(point) else { return nil }
        let block = videoBlockGeometry(model, preview: false)

        if model.usesWholeTrackDrag {
            // ≤1 clip: the block trims/slips as one. Per-clip gestures collapse
            // to no-ops here (move bounds are degenerate), so the whole-track
            // machine owns the lane — matching `guard usesWholeTrackDrag`.
            let rect = CGRect(x: block.x, y: VM.videoLaneY, width: block.width, height: VM.trackHeight)
            guard rect.contains(point) else { return nil }
            let localX = min(max(point.x - rect.minX, 0), rect.width)
            if localX < Self.videoHandleWidth { return .whole(.resizeLeft) }
            if localX > rect.width - Self.videoHandleWidth { return .whole(.resizeRight) }
            return .whole(.move)
        }

        // Joined-boundary hotspot: 30pt wide, full lane height.
        for boundary in model.boundaries {
            let bx = videoOutputOffsetX(boundary.outputTime, model: model, block: block)
            if abs(point.x - bx) <= Self.videoBoundaryHitWidth / 2 { return .boundary(boundary) }
        }

        // Per-clip edge handles: 23 × 32, vertically centred on the lane.
        let handleTop = VM.videoLaneY + (VM.trackHeight - Self.videoClipHandleHeight) / 2
        let handleBottom = handleTop + Self.videoClipHandleHeight
        for clip in model.clips {
            let rect = videoClipRect(clip.ref, model: model, block: block)
            guard point.x >= rect.minX, point.x <= rect.maxX else { continue }
            if point.y >= handleTop, point.y <= handleBottom {
                if point.x - rect.minX <= Self.videoClipHandleWidth { return .clipEdge(clip.ref, .left) }
                if rect.maxX - point.x <= Self.videoClipHandleWidth { return .clipEdge(clip.ref, .right) }
            }
            return .clipMove(clip.ref)
        }
        return nil
    }

    // MARK: Drag lifecycle (driven by the canvas mouse state machine)

    /// Returns true when the VIDEO lane consumed the event.
    @discardableResult
    func videoMouseDown(at point: CGPoint, model: TimelineVideoRowModel) -> Bool {
        guard videoLaneRect.contains(point), snapshot.outputDuration > 0 else { return false }

        if let mute = videoMuteRect(model), mute.contains(point) {
            videoCallbacks?.toggleMute()
            return true
        }

        guard let kind = videoDragKind(at: point, model: model) else {
            videoPendingDeselect = true
            return true
        }
        videoPendingDeselect = false
        videoDrag = VideoRowDrag(kind: kind, startPoint: point)
        return true
    }

    func videoMouseDragged(to point: CGPoint) {
        guard var drag = videoDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        if abs(drag.translationX) > drag.threshold { drag.didDrag = true }

        // Boundary: the first meaningful horizontal movement picks the side.
        if case .boundary(let boundary) = drag.kind,
           drag.boundaryResolved == nil,
           abs(drag.translationX) > 0.25,
           let model = videoModel {
            if drag.translationX < 0 {
                if let clip = model.clip(withID: boundary.leftClipID) {
                    drag.boundaryResolved = (clip.ref, .right)
                }
            } else if let clip = model.clip(withID: boundary.rightClipID) {
                drag.boundaryResolved = (clip.ref, .left)
            }
        }
        videoDrag = drag
        // Everything this row draws lives inside the lane rect, so a drag
        // repaint never has to touch the ruler or the other lanes.
        setNeedsDisplay(videoLaneRect)
    }

    func videoMouseUp(at point: CGPoint, model: TimelineVideoRowModel) {
        if videoPendingDeselect {
            videoPendingDeselect = false
            if videoDrag == nil {
                videoCallbacks?.selectClip(nil)
                return
            }
        }
        guard var drag = videoDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        if abs(drag.translationX) > drag.threshold { drag.didDrag = true }
        defer {
            videoDrag = nil
            setNeedsDisplay(videoLaneRect)
        }

        let delta = videoDragDelta(drag.translationX)
        let math = videoEditMath(model)
        let spans = model.clipSpans

        switch drag.kind {
        case .whole(let mode):
            guard drag.didDrag else {
                videoCallbacks?.selectClip(videoClip(at: point, model: model)?.id)
                return
            }
            let resolved = math.resolvedTimes(
                mode: mode,
                delta: delta,
                dragInitialStart: model.regionStart,
                dragInitialEnd: model.regionEnd
            )
            videoCallbacks?.commitWholeDrag(mode, delta, resolved.start, resolved.end)
        case .clipMove(let clip):
            guard drag.didDrag else {
                videoCallbacks?.selectClip(clip.id)
                return
            }
            let resolved = math.resolvedClipMoveOutputStart(
                clip.span, in: spans,
                proposedOutputStart: clip.outputStart + delta
            )
            videoCallbacks?.commitClipMove(clip, resolved)
        case .clipEdge(let clip, let side):
            guard drag.didDrag else {
                videoCallbacks?.selectClip(clip.id)
                return
            }
            let original = side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(
                clip.span, in: spans, side: side,
                proposedOutput: original + delta
            )
            videoCallbacks?.commitClipEdge(clip, side, resolved)
        case .boundary:
            guard drag.didDrag, let target = drag.boundaryResolved else { return }
            let clip = target.clip
            let original = target.side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(
                clip.span, in: spans, side: target.side,
                proposedOutput: original + delta
            )
            videoCallbacks?.commitClipEdge(clip, target.side, resolved)
        }
    }

    /// Hover cursor for the VIDEO lane, or nil to leave the cursor alone.
    func videoHoverCursor(at point: CGPoint, model: TimelineVideoRowModel) -> NSCursor? {
        guard videoLaneRect.contains(point) else { return nil }
        if let mute = videoMuteRect(model), mute.contains(point) { return .arrow }
        switch videoDragKind(at: point, model: model) {
        case .whole(.resizeLeft), .whole(.resizeRight), .clipEdge, .boundary:
            return .resizeLeftRight
        default:
            return .arrow
        }
    }

    // MARK: Context menu

    func videoSegment(at point: CGPoint, model: TimelineVideoRowModel) -> TimelineVideoSegmentItem? {
        guard let clip = videoClip(at: point, model: model) else { return nil }
        let block = videoBlockGeometry(model, preview: false)
        let rect = videoClipRect(clip.ref, model: model, block: block)
        guard rect.width > 0 else { return nil }
        let fraction = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let time = clip.outputStart + TimeInterval(fraction) * clip.outputDuration
        let inClip = model.segments.filter { $0.clipID == clip.id }
        return inClip.first { time >= $0.outputStart && time <= $0.outputEnd } ?? inClip.last
    }

    func videoContextMenu(at point: CGPoint, model: TimelineVideoRowModel) -> NSMenu? {
        guard videoLaneRect.contains(point), let segment = videoSegment(at: point, model: model) else { return nil }

        let menu = NSMenu()
        if let regionID = segment.regionID {
            let change = NSMenuItem(title: "Change Speed", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Change Speed")
            for level in TimelineVideoRowModel.speedPresets {
                sub.addItem(VideoRowMenuItem(title: TimelineVideoRowModel.formatSpeedLabel(level)) { [weak self] in
                    self?.videoCallbacks?.changeSpeed(regionID, level)
                })
            }
            change.submenu = sub
            menu.addItem(change)
            menu.addItem(.separator())
            menu.addItem(VideoRowMenuItem(title: "Remove Speed", destructive: true) { [weak self] in
                self?.videoCallbacks?.deleteSpeed(regionID)
            })
        } else {
            let set = NSMenuItem(title: "Set Speed", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Set Speed")
            for level in TimelineVideoRowModel.speedPresets {
                sub.addItem(VideoRowMenuItem(title: TimelineVideoRowModel.formatSpeedLabel(level)) { [weak self] in
                    self?.videoCallbacks?.addSpeedRange(segment.sourceStart, segment.sourceEnd, level)
                })
            }
            set.submenu = sub
            menu.addItem(set)
        }
        if segment.startsAtSplit {
            menu.addItem(.separator())
            menu.addItem(VideoRowMenuItem(title: "Remove Split at Start", destructive: true) { [weak self] in
                self?.videoCallbacks?.deleteSplit(segment.outputStart)
            })
        }
        return menu
    }

    // MARK: - Drawing

    func drawVideoLane(in context: CGContext, model: TimelineVideoRowModel) {
        guard snapshot.outputDuration > 0, bounds.width > 0 else { return }
        let block = videoBlockGeometry(model)

        context.saveGState()
        // `.opacity(dragMode != .none && didDrag ? 0.8 : 1)` — whole-track only.
        if let drag = videoDrag, case .whole = drag.kind, drag.didDrag {
            context.setAlpha(0.8)
        }

        for clip in model.clips {
            let display = videoDisplayClip(clip.ref, model: model)
            drawVideoClip(clip, display: display, model: model, block: block, in: context)
        }

        drawVideoMuteButton(model, in: context)
        context.restoreGState()
    }

    private func drawVideoClip(
        _ clip: TimelineVideoClipItem,
        display: VideoClipRef,
        model: TimelineVideoRowModel,
        block: (x: CGFloat, width: CGFloat),
        in context: CGContext
    ) {
        let rect = videoClipRect(display, model: model, block: block)
        guard rect.width > 0.5 else { return }

        let hasFilmstrip = model.hasThumbnails && !videoAssets.thumbnails.isEmpty
        let hover = videoIsHovering
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)

        context.saveGState()
        context.addPath(path)
        context.clip()

        // Base slab: black wash under the filmstrip, yellow otherwise.
        let base = hasFilmstrip
            ? NSColor.black.withAlphaComponent(0.4)
            : Self.videoYellow.withAlphaComponent(hover ? 0.45 : 0.35)
        context.setFillColor(base.cgColor)
        context.fill(rect)

        if hasFilmstrip {
            drawVideoFilmstrip(in: context, rect: rect, sourceStart: display.sourceStart, sourceEnd: display.sourceEnd)
        }

        for segment in videoDisplaySegments(for: clip, display: display, model: model) {
            drawVideoSegment(segment, clip: display, clipRect: rect, hasFilmstrip: hasFilmstrip, in: context)
        }

        if model.hasAudio {
            drawVideoWaveform(in: context, rect: rect, clip: display, isMuted: model.isMuted, hasFilmstrip: hasFilmstrip)
        }

        if rect.width > 80 {
            drawVideoInfoPill(clip: clip, display: display, rect: rect, in: context)
        }
        context.restoreGState()

        // Hairline + selection border (SwiftUI strokeBorder ⇒ inside the shape).
        // These strokes separate the clip from the PANEL background, so they
        // follow the theme ink; everything drawn over the filmstrip/slab
        // (waveform, pill, labels, grips) keeps its fixed contrast.
        let ink: NSColor = CCTheme.isDark ? .white : .black
        strokeVideoRounded(rect, radius: 8, color: ink.withAlphaComponent(0.10), width: 1, in: context)
        if clip.isSelected {
            strokeVideoRounded(rect, radius: 8, color: ink.withAlphaComponent(0.85), width: 2, in: context)
        }

        drawVideoEdgeGrips(rect: rect, in: context)
    }

    /// Port of `clipDisplaySegments(in:committedClip:)` — a clip fully covered
    /// by one speed region renders as a single retimed slab; otherwise the
    /// committed sub-segments are mapped into the (possibly resized) slab.
    private func videoDisplaySegments(
        for clip: TimelineVideoClipItem,
        display: VideoClipRef,
        model: TimelineVideoRowModel
    ) -> [TimelineVideoSegmentItem] {
        if let speed = clip.fillSpeed {
            return [TimelineVideoSegmentItem(
                id: "\(clip.id)-fill",
                clipID: clip.id,
                sourceStart: display.sourceStart,
                sourceEnd: display.sourceEnd,
                outputStart: display.outputStart,
                outputEnd: display.outputEnd,
                speed: speed,
                regionID: clip.fillRegionID,
                label: TimelineVideoRowModel.segmentLabel(outputSpan: display.outputDuration, speed: speed),
                showsLeadingDivider: false,
                startsAtSplit: false
            )]
        }
        return model.segments.filter { $0.clipID == clip.id }
    }

    private func drawVideoSegment(
        _ segment: TimelineVideoSegmentItem,
        clip: VideoClipRef,
        clipRect: CGRect,
        hasFilmstrip: Bool,
        in context: CGContext
    ) {
        // Committed segments are mapped proportionally into the drawn slab —
        // during a live resize the sub-segments stretch with the clip.
        let clipSpan = max(0.0001, clip.outputDuration)
        let f0 = min(max((segment.outputStart - clip.outputStart) / clipSpan, 0), 1)
        let f1 = min(max((segment.outputEnd - clip.outputStart) / clipSpan, 0), 1)
        let rect = CGRect(
            x: clipRect.minX + clipRect.width * CGFloat(f0),
            y: clipRect.minY,
            width: clipRect.width * CGFloat(max(0, f1 - f0)),
            height: clipRect.height
        )
        guard rect.width > 0.5 else { return }

        let hover = videoIsHovering
        let isSpeed = segment.speed != 1.0
        if isSpeed {
            context.setFillColor(Self.videoYellow.withAlphaComponent(hover ? 0.65 : 0.55).cgColor)
            context.fill(rect)
        } else if !hasFilmstrip {
            context.setFillColor(Self.videoYellow.withAlphaComponent(hover ? 0.45 : 0.35).cgColor)
            context.fill(rect)
        }

        if segment.showsLeadingDivider {
            context.setFillColor(Self.videoOrange.withAlphaComponent(0.6).cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))
        }

        guard isSpeed else { return }
        let color = NSColor.black.withAlphaComponent(0.85)
        let combined = NSMutableAttributedString()
        if let gauge = Self.tintedSymbol("gauge.with.needle", pointSize: 10, weight: .bold, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = gauge
            attachment.bounds = CGRect(x: 0, y: -2, width: gauge.size.width, height: gauge.size.height)
            combined.append(NSAttributedString(attachment: attachment))
            combined.append(NSAttributedString(string: " "))
        }
        combined.append(NSAttributedString(string: segment.label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color,
        ]))
        let size = combined.size()
        guard size.width <= rect.width - 12 else { return }
        combined.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// Port of `ClipFilmstripCanvas` — tiles cached CGImages across the clip.
    /// The thumbnails come straight from the existing timeline cache; nothing
    /// is decoded or regenerated here.
    private func drawVideoFilmstrip(
        in context: CGContext,
        rect: CGRect,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval
    ) {
        let thumbnails = videoAssets.thumbnails
        guard let first = thumbnails.first, rect.height > 0, rect.width > 0 else { return }
        let baseAspect = first.aspectRatio
        let span = max(0.0001, sourceEnd - sourceStart)

        var x: CGFloat = rect.minX
        while x < rect.maxX {
            let probeWidth = max(12, rect.height * baseAspect)
            let fraction = ((x - rect.minX) + probeWidth / 2) / rect.width
            let time = sourceStart + Double(fraction) * span

            guard let thumb = TimelineThumbnailer.thumbnail(at: time, in: thumbnails) else {
                x += probeWidth
                continue
            }

            var image = thumb.image
            var aspect = thumb.aspectRatio
            if let normalized = videoDeviceContentRect(at: time) {
                let pixelRect = CGRect(
                    x: normalized.minX * CGFloat(image.width),
                    y: normalized.minY * CGFloat(image.height),
                    width: normalized.width * CGFloat(image.width),
                    height: normalized.height * CGFloat(image.height)
                )
                if let cropped = image.cropping(to: pixelRect) {
                    image = cropped
                    aspect = pixelRect.height > 0 ? pixelRect.width / pixelRect.height : aspect
                }
            }

            let tileWidth = max(10, rect.height * aspect)
            // Flipped view: un-flip per tile so frames aren't upside down.
            context.saveGState()
            context.translateBy(x: x, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: tileWidth, height: rect.height))
            context.restoreGState()
            x += tileWidth
        }
    }

    private func videoDeviceContentRect(at time: TimeInterval) -> CGRect? {
        videoAssets.sourceSegments.first {
            $0.kind == .device && time >= $0.startTime && time <= $0.endTime
        }?.normalizedContentRect
    }

    /// Port of `ClipWaveformCanvas` + the padding its host applies.
    private func drawVideoWaveform(
        in context: CGContext,
        rect: CGRect,
        clip: VideoClipRef,
        isMuted: Bool,
        hasFilmstrip: Bool
    ) {
        let samples = videoClipAudioSamples(clip)
        guard !samples.isEmpty else { return }

        let waveHeight: CGFloat = hasFilmstrip ? 14 : 40
        let hPad: CGFloat = hasFilmstrip ? 4 : min(18, max(4, rect.width * 0.12))
        let bPad: CGFloat = hasFilmstrip ? 2 : 4
        let waveRect = CGRect(
            x: rect.minX + hPad,
            y: rect.maxY - bPad - waveHeight,
            width: rect.width - hPad * 2,
            height: waveHeight
        )
        guard waveRect.width > 1 else { return }

        let centerY = waveRect.midY
        let maxBarHeight = waveRect.height - 8
        let barWidth = max(1, waveRect.width / CGFloat(max(samples.count, 1)))
        context.setFillColor(NSColor.white.withAlphaComponent(isMuted ? 0.12 : 0.42).cgColor)

        for (index, sample) in samples.enumerated() {
            let amplitude = CGFloat(max(0, min(1, sample)))
            let height = amplitude * maxBarHeight
            guard height >= 1 else { continue }
            let bar = CGRect(
                x: waveRect.minX + CGFloat(index) * barWidth,
                y: centerY - height / 2,
                width: max(1, barWidth - 1),
                height: height
            )
            let radius = min(2, bar.width / 2)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.fillPath()

        if isMuted {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: waveRect.minX, y: centerY))
            context.addLine(to: CGPoint(x: waveRect.maxX, y: centerY))
            context.strokePath()
        }
    }

    /// Port of `clipAudioSamples(for:)` — the slice of the trim-window samples
    /// this clip covers.
    private func videoClipAudioSamples(_ clip: VideoClipRef) -> ArraySlice<Float> {
        let samples = videoAssets.audioSamples
        guard !samples.isEmpty else { return [] }
        let trimStart = videoAssets.trimSourceStart
        let trimDuration = videoAssets.trimSourceEnd - trimStart
        guard trimDuration > 0 else { return [] }

        let startFraction = max(0, min(1, (clip.sourceStart - trimStart) / trimDuration))
        let endFraction = max(0, min(1, (clip.sourceEnd - trimStart) / trimDuration))
        guard endFraction > startFraction else { return [] }

        let count = samples.count
        let startIndex = max(0, min(count - 1, Int((startFraction * Double(count)).rounded(.down))))
        let endIndex = max(startIndex + 1, min(count, Int((endFraction * Double(count)).rounded(.up))))
        return samples[startIndex..<endIndex]
    }

    /// Port of `clipInfoPill` — the live duration bubble (+ dominant speed).
    private func drawVideoInfoPill(
        clip: TimelineVideoClipItem,
        display: VideoClipRef,
        rect: CGRect,
        in context: CGContext
    ) {
        let seconds = max(0, display.outputDuration)
        let text = NSMutableAttributedString(
            string: String(format: "%.1fs", seconds),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
        )
        if let speed = clip.pillSpeedLabel {
            text.append(NSAttributedString(string: "  ×\(speed)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            ]))
        }
        let size = text.size()
        let pill = CGRect(
            x: rect.midX - size.width / 2 - 6,
            y: rect.midY - size.height / 2 - 2,
            width: size.width + 12,
            height: size.height + 4
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        context.addPath(CGPath(
            roundedRect: pill,
            cornerWidth: pill.height / 2, cornerHeight: pill.height / 2,
            transform: nil
        ))
        context.fillPath()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2))
    }

    /// Port of `ClipEdgeHandle` — two 2×13 grips inset 5pt at each end.
    private func drawVideoEdgeGrips(rect: CGRect, in context: CGContext) {
        let tint = Self.videoYellow.withAlphaComponent(videoIsHovering ? 0.95 : 0.7)
        let alphas: [CGFloat] = [0.78, 0.64]
        for baseX in [rect.minX + 5, rect.maxX - 5 - 6] {
            for i in 0..<2 {
                let grip = CGRect(x: baseX + CGFloat(i) * 4, y: rect.midY - 6.5, width: 2, height: 13)
                context.setFillColor(tint.withAlphaComponent(tint.alphaComponent * alphas[i]).cgColor)
                context.addPath(CGPath(roundedRect: grip, cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.fillPath()
            }
        }
    }

    private func drawVideoMuteButton(_ model: TimelineVideoRowModel, in context: CGContext) {
        guard let muteRect = videoMuteRect(model) else { return }
        let symbol = model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let color = NSColor.white.withAlphaComponent(model.isMuted ? 0.4 : 0.75)
        guard let image = Self.tintedSymbol(symbol, pointSize: 9, weight: .semibold, color: color) else { return }
        image.draw(in: CGRect(
            x: muteRect.midX - image.size.width / 2,
            y: muteRect.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        ))
    }

    static func videoMuteSymbolSize(muted: Bool) -> CGSize {
        let name = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        return tintedSymbol(name, pointSize: 9, weight: .semibold, color: .white)?.size
            ?? CGSize(width: 14, height: 11)
    }

    private func strokeVideoRounded(
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
            cornerWidth: max(0, radius - width / 2), cornerHeight: max(0, radius - width / 2),
            transform: nil
        ))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokePath()
    }
}

// MARK: - Closure-driven menu item

/// Retains its handler; `CanvasMenuItem` is private to TimelineCanvasView.swift.
final class VideoRowMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, destructive: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        if destructive {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.menuFont(ofSize: 0),
            ])
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invoke() { handler() }
}
