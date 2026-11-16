import UIKit

// The VIDEO and VOICE rows of the touch timeline: hit zones, drag lifecycle
// and drawing, ported from the Mac rows (VideoTrackRowNative.swift,
// VoiceTrackRowNative.swift). Every committed value comes from the shared
// math — `VideoTrackEditMath` (trim, clip move, clip edge) and
// `VoiceTrackEditMath` (voice clip move/trim) — through the shared callback
// tables (`TimelineHosting.timelineVideoCallbacks()` / `…VoiceCallbacks()`).

extension StudioTimelineCanvasView {
    // MARK: - VIDEO geometry

    static let videoHandleWidth: CGFloat = 12
    static let videoClipHandleWidth: CGFloat = 23
    static let videoClipHandleHeight: CGFloat = 32
    static let videoBoundaryHitWidth: CGFloat = 30
    static let videoMuteTrailingInset: CGFloat = 18

    var videoLaneRect: CGRect {
        CGRect(x: 0, y: M.videoLaneY, width: bounds.width, height: M.trackHeight)
    }

    func videoEditMath(_ model: TimelineVideoRowModel) -> VideoTrackEditMath {
        VideoTrackEditMath(
            duration: snapshot.outputDuration,
            trackWidth: bounds.width,
            snapCandidates: model.snapCandidates,
            regionStart: model.regionStart,
            regionEnd: model.regionEnd,
            minDuration: M.minDuration
        )
    }

    func videoDragDelta(_ translationX: CGFloat) -> TimeInterval {
        TimeInterval(translationX) * snapshot.outputDuration / TimeInterval(max(1, bounds.width))
    }

    /// The yellow block's drawn origin + width (the Mac's unsnapped, clamped
    /// preview math while a whole-track drag is live).
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
        let minDuration = M.minDuration
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
            start = min(max(0, initialStart + delta), max(0, duration - clipDuration))
            end = min(duration, start + clipDuration)
        case .none:
            start = model.regionStart
            end = model.regionEnd
        }
        let originTime = mode == .resizeRight ? initialStart : start
        return (x: width * CGFloat(originTime / duration), width: max(40, width * CGFloat((end - start) / duration)))
    }

    func videoClipRect(_ clip: VideoClipRef, model: TimelineVideoRowModel, block: (x: CGFloat, width: CGFloat)) -> CGRect {
        let span = model.span
        let x = block.x + max(0, CGFloat((clip.outputStart - model.regionStart) / span) * block.width)
        let w = max(0, CGFloat(clip.outputDuration / span) * block.width)
        return CGRect(x: x, y: M.videoLaneY, width: w, height: M.trackHeight)
    }

    func videoOutputOffsetX(_ outputTime: TimeInterval, model: TimelineVideoRowModel, block: (x: CGFloat, width: CGFloat)) -> CGFloat {
        block.x + max(0, CGFloat((outputTime - model.regionStart) / model.span) * block.width)
    }

    /// Live clip span during a per-clip drag (preview follows the finger —
    /// `snapsToCandidates: false`, as on the Mac).
    func videoDisplayClip(_ clip: VideoClipRef, model: TimelineVideoRowModel) -> VideoClipRef {
        guard let drag = videoDrag, drag.didDrag, snapshot.outputDuration > 0 else { return clip }
        let math = videoEditMath(model)
        let spans = model.clipSpans
        let deltaOutput = videoDragDelta(drag.translationX)
        func edge(_ side: VideoTrackEditMath.Side) -> VideoClipRef {
            let original = side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(clip.span, in: spans, side: side,
                                                       proposedOutput: original + deltaOutput, snapsToCandidates: false)
            var out = clip
            if side == .left { out.outputStart = resolved } else { out.outputEnd = resolved }
            return out
        }
        switch drag.kind {
        case .clipMove(let c) where c.id == clip.id:
            let start = math.resolvedClipMoveOutputStart(clip.span, in: spans,
                                                         proposedOutputStart: clip.outputStart + deltaOutput,
                                                         snapsToCandidates: false)
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

    /// Mute key: top-trailing of the block (a 9 pt glyph + 10 pt of air).
    func videoMuteRect(_ model: TimelineVideoRowModel) -> CGRect? {
        guard model.hasAudio else { return nil }
        let block = videoBlockGeometry(model, preview: false)
        let w: CGFloat = 24, h: CGFloat = 21
        return CGRect(x: block.x + block.width - Self.videoMuteTrailingInset - w, y: M.videoLaneY, width: w, height: h)
    }

    func videoClip(at point: CGPoint, model: TimelineVideoRowModel) -> TimelineVideoClipItem? {
        let block = videoBlockGeometry(model, preview: false)
        return model.clips.first { videoClipRect($0.ref, model: model, block: block).contains(point) }
    }

    /// The Mac's hit order: boundary hotspots → per-clip edge handles → clip
    /// body → the whole-track block gesture.
    func videoDragKind(at point: CGPoint, model: TimelineVideoRowModel) -> VideoRowDrag.Kind? {
        guard videoLaneRect.contains(point) else { return nil }
        let block = videoBlockGeometry(model, preview: false)
        if model.usesWholeTrackDrag {
            let rect = CGRect(x: block.x, y: M.videoLaneY, width: block.width, height: M.trackHeight)
            guard rect.contains(point) else { return nil }
            let localX = min(max(point.x - rect.minX, 0), rect.width)
            if localX < Self.videoHandleWidth { return .whole(.resizeLeft) }
            if localX > rect.width - Self.videoHandleWidth { return .whole(.resizeRight) }
            return .whole(.move)
        }
        for boundary in model.boundaries {
            let bx = videoOutputOffsetX(boundary.outputTime, model: model, block: block)
            if abs(point.x - bx) <= Self.videoBoundaryHitWidth / 2 { return .boundary(boundary) }
        }
        let handleTop = M.videoLaneY + (M.trackHeight - Self.videoClipHandleHeight) / 2
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

    /// The speed/split segment under a point (long-press menu target).
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

    // MARK: - VIDEO press lifecycle

    /// True when the VIDEO lane took the press.
    func videoPressBegan(at point: CGPoint, model: TimelineVideoRowModel) -> Bool {
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

    func videoPressMoved(to point: CGPoint) {
        guard var drag = videoDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        if abs(drag.translationX) > drag.threshold { drag.didDrag = true }
        if case .boundary(let boundary) = drag.kind, drag.boundaryResolved == nil,
           abs(drag.translationX) > 0.25, let model = videoModel {
            if drag.translationX < 0 {
                if let clip = model.clip(withID: boundary.leftClipID) { drag.boundaryResolved = (clip.ref, .right) }
            } else if let clip = model.clip(withID: boundary.rightClipID) {
                drag.boundaryResolved = (clip.ref, .left)
            }
        }
        videoDrag = drag
        setNeedsDisplay()
        refreshSelectionRing(animated: false)
    }

    func videoPressEnded(at point: CGPoint, model: TimelineVideoRowModel) {
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
            setNeedsDisplay()
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
            let resolved = math.resolvedTimes(mode: mode, delta: delta,
                                              dragInitialStart: model.regionStart, dragInitialEnd: model.regionEnd)
            videoCallbacks?.commitWholeDrag(mode, delta, resolved.start, resolved.end)
        case .clipMove(let clip):
            guard drag.didDrag else {
                videoCallbacks?.selectClip(clip.id)
                return
            }
            let resolved = math.resolvedClipMoveOutputStart(clip.span, in: spans,
                                                            proposedOutputStart: clip.outputStart + delta)
            videoCallbacks?.commitClipMove(clip, resolved)
        case .clipEdge(let clip, let side):
            guard drag.didDrag else {
                videoCallbacks?.selectClip(clip.id)
                return
            }
            let original = side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(clip.span, in: spans, side: side, proposedOutput: original + delta)
            videoCallbacks?.commitClipEdge(clip, side, resolved)
        case .boundary:
            guard drag.didDrag, let target = drag.boundaryResolved else { return }
            let clip = target.clip
            let original = target.side == .left ? clip.outputStart : clip.outputEnd
            let resolved = math.resolvedClipEdgeOutput(clip.span, in: spans, side: target.side,
                                                       proposedOutput: original + delta)
            videoCallbacks?.commitClipEdge(clip, target.side, resolved)
        }
    }

    // MARK: - VIDEO drawing

    func drawVideoLane(in context: CGContext, model: TimelineVideoRowModel) {
        guard snapshot.outputDuration > 0, bounds.width > 0 else { return }
        let block = videoBlockGeometry(model)
        context.saveGState()
        if let drag = videoDrag, case .whole = drag.kind, drag.didDrag { context.setAlpha(0.8) }
        for clip in model.clips {
            drawVideoClip(clip, display: videoDisplayClip(clip.ref, model: model), model: model, block: block, in: context)
        }
        if let mute = videoMuteRect(model) {
            let symbol = model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            let color = UIColor.white.withAlphaComponent(model.isMuted ? 0.4 : 0.75)
            if let image = StudioTimelineStyle.symbol(symbol, pointSize: 9, weight: .semibold, color: color) {
                image.draw(in: CGRect(x: mute.midX - image.size.width / 2, y: mute.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height))
            }
        }
        context.restoreGState()
    }

    private func drawVideoClip(
        _ clip: TimelineVideoClipItem, display: VideoClipRef, model: TimelineVideoRowModel,
        block: (x: CGFloat, width: CGFloat), in context: CGContext
    ) {
        let rect = videoClipRect(display, model: model, block: block)
        guard rect.width > 0.5 else { return }
        let hasFilmstrip = model.hasThumbnails && !videoAssets.thumbnails.isEmpty
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        let yellow = StudioTimelineStyle.videoYellow
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor((hasFilmstrip ? UIColor.black.withAlphaComponent(0.4) : yellow.withAlphaComponent(0.35)).cgColor)
        context.fill(rect)
        if hasFilmstrip { drawVideoFilmstrip(in: context, rect: rect, sourceStart: display.sourceStart, sourceEnd: display.sourceEnd) }
        let segments: [TimelineVideoSegmentItem]
        if let speed = clip.fillSpeed {
            segments = [TimelineVideoSegmentItem(
                id: "\(clip.id)-fill", clipID: clip.id, sourceStart: display.sourceStart, sourceEnd: display.sourceEnd,
                outputStart: display.outputStart, outputEnd: display.outputEnd, speed: speed, regionID: clip.fillRegionID,
                label: TimelineVideoRowModel.segmentLabel(outputSpan: display.outputDuration, speed: speed),
                showsLeadingDivider: false, startsAtSplit: false)]
        } else {
            segments = model.segments.filter { $0.clipID == clip.id }
        }
        for segment in segments {
            drawVideoSegment(segment, clip: display, clipRect: rect, hasFilmstrip: hasFilmstrip, in: context)
        }
        if model.hasAudio { drawVideoWaveform(in: context, rect: rect, clip: display, isMuted: model.isMuted, hasFilmstrip: hasFilmstrip) }
        if rect.width > 80 { drawVideoInfoPill(clip: clip, display: display, rect: rect) }
        context.restoreGState()
        let ink = StudioTimelineStyle.ink(traitCollection)
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        context.addPath(CGPath(roundedRect: inset, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
        context.setStrokeColor(ink.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        // Edge grips.
        let tint = yellow.withAlphaComponent(0.7)
        for baseX in [rect.minX + 5, rect.maxX - 5 - 6] {
            for (i, alpha) in [CGFloat(0.78), 0.64].enumerated() {
                let grip = CGRect(x: baseX + CGFloat(i) * 4, y: rect.midY - 6.5, width: 2, height: 13)
                context.setFillColor(tint.withAlphaComponent(0.7 * alpha).cgColor)
                context.addPath(CGPath(roundedRect: grip, cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.fillPath()
            }
        }
    }

    private func drawVideoSegment(
        _ segment: TimelineVideoSegmentItem, clip: VideoClipRef, clipRect: CGRect, hasFilmstrip: Bool, in context: CGContext
    ) {
        let clipSpan = max(0.0001, clip.outputDuration)
        let f0 = min(max((segment.outputStart - clip.outputStart) / clipSpan, 0), 1)
        let f1 = min(max((segment.outputEnd - clip.outputStart) / clipSpan, 0), 1)
        let rect = CGRect(x: clipRect.minX + clipRect.width * CGFloat(f0), y: clipRect.minY,
                          width: clipRect.width * CGFloat(max(0, f1 - f0)), height: clipRect.height)
        guard rect.width > 0.5 else { return }
        let yellow = StudioTimelineStyle.videoYellow
        let isSpeed = segment.speed != 1.0
        if isSpeed {
            context.setFillColor(yellow.withAlphaComponent(0.55).cgColor)
            context.fill(rect)
        } else if !hasFilmstrip {
            context.setFillColor(yellow.withAlphaComponent(0.35).cgColor)
            context.fill(rect)
        }
        if segment.showsLeadingDivider {
            context.setFillColor(StudioTimelineStyle.videoOrange.withAlphaComponent(0.6).cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))
        }
        guard isSpeed else { return }
        let color = UIColor.black.withAlphaComponent(0.85)
        let combined = NSMutableAttributedString()
        if let gauge = StudioTimelineStyle.symbol("gauge.with.needle", pointSize: 10, weight: .bold, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = gauge
            attachment.bounds = CGRect(x: 0, y: -2, width: gauge.size.width, height: gauge.size.height)
            combined.append(NSAttributedString(attachment: attachment))
            combined.append(NSAttributedString(string: " "))
        }
        combined.append(NSAttributedString(string: segment.label, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold), .foregroundColor: color,
        ]))
        let size = combined.size()
        guard size.width <= rect.width - 12 else { return }
        combined.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawVideoFilmstrip(in context: CGContext, rect: CGRect, sourceStart: TimeInterval, sourceEnd: TimeInterval) {
        let thumbnails = videoAssets.thumbnails
        guard let first = thumbnails.first, rect.height > 0, rect.width > 0 else { return }
        let span = max(0.0001, sourceEnd - sourceStart)
        var x = rect.minX
        while x < rect.maxX {
            let probeWidth = max(12, rect.height * first.aspectRatio)
            let time = sourceStart + Double(((x - rect.minX) + probeWidth / 2) / rect.width) * span
            guard let thumb = TimelineThumbnailer.thumbnail(at: time, in: thumbnails) else {
                x += probeWidth
                continue
            }
            var image = thumb.image
            var aspect = thumb.aspectRatio
            if let normalized = videoAssets.sourceSegments.first(where: {
                $0.kind == .device && time >= $0.startTime && time <= $0.endTime
            })?.normalizedContentRect {
                let pixelRect = CGRect(x: normalized.minX * CGFloat(image.width), y: normalized.minY * CGFloat(image.height),
                                       width: normalized.width * CGFloat(image.width), height: normalized.height * CGFloat(image.height))
                if let cropped = image.cropping(to: pixelRect) {
                    image = cropped
                    aspect = pixelRect.height > 0 ? pixelRect.width / pixelRect.height : aspect
                }
            }
            let tileWidth = max(10, rect.height * aspect)
            context.saveGState()
            context.translateBy(x: x, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: tileWidth, height: rect.height))
            context.restoreGState()
            x += tileWidth
        }
    }

    private func drawVideoWaveform(in context: CGContext, rect: CGRect, clip: VideoClipRef, isMuted: Bool, hasFilmstrip: Bool) {
        let samples = videoAssets.audioSamples
        let trimStart = videoAssets.trimSourceStart
        let trimDuration = videoAssets.trimSourceEnd - trimStart
        guard !samples.isEmpty, trimDuration > 0 else { return }
        let startFraction = max(0, min(1, (clip.sourceStart - trimStart) / trimDuration))
        let endFraction = max(0, min(1, (clip.sourceEnd - trimStart) / trimDuration))
        guard endFraction > startFraction else { return }
        let count = samples.count
        let startIndex = max(0, min(count - 1, Int((startFraction * Double(count)).rounded(.down))))
        let endIndex = max(startIndex + 1, min(count, Int((endFraction * Double(count)).rounded(.up))))
        let slice = samples[startIndex..<endIndex]
        let waveHeight: CGFloat = hasFilmstrip ? 14 : 40
        let hPad: CGFloat = hasFilmstrip ? 4 : min(18, max(4, rect.width * 0.12))
        let bPad: CGFloat = hasFilmstrip ? 2 : 4
        let wave = CGRect(x: rect.minX + hPad, y: rect.maxY - bPad - waveHeight, width: rect.width - hPad * 2, height: waveHeight)
        guard wave.width > 1 else { return }
        let barWidth = max(1, wave.width / CGFloat(max(slice.count, 1)))
        context.setFillColor(UIColor.white.withAlphaComponent(isMuted ? 0.12 : 0.42).cgColor)
        for (index, sample) in slice.enumerated() {
            let height = CGFloat(max(0, min(1, sample))) * (wave.height - 8)
            guard height >= 1 else { continue }
            let bar = CGRect(x: wave.minX + CGFloat(index) * barWidth, y: wave.midY - height / 2,
                             width: max(1, barWidth - 1), height: height)
            let radius = min(2, bar.width / 2)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.fillPath()
    }

    private func drawVideoInfoPill(clip: TimelineVideoClipItem, display: VideoClipRef, rect: CGRect) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let text = NSMutableAttributedString(string: String(format: "%.1fs", max(0, display.outputDuration)), attributes: [
            .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.85),
        ])
        if let speed = clip.pillSpeedLabel {
            text.append(NSAttributedString(string: "  ×\(speed)", attributes: [
                .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.7),
            ]))
        }
        let size = text.size()
        let pill = CGRect(x: rect.midX - size.width / 2 - 6, y: rect.midY - size.height / 2 - 2,
                          width: size.width + 12, height: size.height + 4)
        UIColor.black.withAlphaComponent(0.38).setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2))
    }

    // MARK: - VOICE geometry

    static let voiceHandleWidth: CGFloat = 8
    static let voiceMinBlockWidth: CGFloat = 52
    static let voiceCornerRadius: CGFloat = 6
    static let voiceMinDuration: TimeInterval = 0.25

    var voiceLaneRect: CGRect {
        CGRect(x: 0, y: M.voiceLaneY, width: bounds.width, height: M.trackHeight)
    }

    func voiceEditMath(_ model: TimelineVoiceRowModel) -> VoiceTrackEditMath {
        VoiceTrackEditMath(totalDuration: snapshot.outputDuration, trackWidth: bounds.width,
                           snapCandidates: model.snapCandidates, minDuration: Self.voiceMinDuration)
    }

    private func voiceActiveDrag(for id: UUID) -> VoiceRowDrag? {
        guard let drag = voiceDrag, drag.initial.id == id, drag.mode != .none else { return nil }
        return drag
    }

    func voicePreviewClip(_ item: TimelineVoiceClipItem, model: TimelineVoiceRowModel) -> VoiceOverClip {
        guard let drag = voiceActiveDrag(for: item.id), snapshot.outputDuration > 0 else { return item.clip }
        let math = voiceEditMath(model)
        return math.resolvedClip(from: drag.initial, mode: drag.mode, delta: math.delta(forTranslation: drag.translationX))
    }

    func voiceClipRect(_ item: TimelineVoiceClipItem, model: TimelineVoiceRowModel) -> CGRect {
        let duration = snapshot.outputDuration
        guard duration > 0 else { return .zero }
        let preview = voicePreviewClip(item, model: model)
        let width = max(Self.voiceMinBlockWidth, bounds.width * CGFloat(preview.duration / duration))
        let committed = bounds.width * CGFloat(item.clip.startTime / duration)
        var x = bounds.width * CGFloat(preview.startTime / duration)
        if let drag = voiceActiveDrag(for: item.id), drag.mode == .move {
            let maxX = max(0, bounds.width - width)
            x = committed + (min(max(committed + drag.translationX, 0), maxX) - committed)
        }
        return CGRect(x: x, y: M.voiceLaneY, width: width, height: M.trackHeight)
    }

    func voiceCommittedRect(_ item: TimelineVoiceClipItem) -> CGRect {
        let duration = snapshot.outputDuration
        guard duration > 0 else { return .zero }
        return CGRect(x: bounds.width * CGFloat(item.clip.startTime / duration), y: M.voiceLaneY,
                      width: max(Self.voiceMinBlockWidth, bounds.width * CGFloat(item.clip.duration / duration)),
                      height: M.trackHeight)
    }

    func voiceClipItem(at point: CGPoint, model: TimelineVoiceRowModel) -> TimelineVoiceClipItem? {
        model.clips.reversed().first { voiceCommittedRect($0).contains(point) }
    }

    private func voiceDragMode(at point: CGPoint, item: TimelineVoiceClipItem) -> VoiceTrackEditMath.Mode {
        let rect = voiceCommittedRect(item)
        let localX = min(max(point.x - rect.minX, 0), rect.width)
        if localX < Self.voiceHandleWidth { return .resizeLeft }
        if localX > rect.width - Self.voiceHandleWidth { return .resizeRight }
        return .move
    }

    // MARK: - VOICE press lifecycle

    /// True when a clip took the press; false = empty lane (deselect + scrub).
    func voicePressBegan(at point: CGPoint, model: TimelineVoiceRowModel) -> Bool {
        guard snapshot.outputDuration > 0 else { return false }
        guard let item = voiceClipItem(at: point, model: model) else {
            voiceCallbacks?.selectClip(nil)
            return false
        }
        if !item.isSelected { voiceCallbacks?.selectClip(item.id) }
        voiceDrag = VoiceRowDrag(initial: item.clip, mode: voiceDragMode(at: point, item: item), startPoint: point)
        return true
    }

    func voicePressMoved(to point: CGPoint) {
        guard var drag = voiceDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        let dy = point.y - drag.startPoint.y
        if !drag.didDrag, sqrt(drag.translationX * drag.translationX + dy * dy) >= VoiceRowDrag.threshold {
            drag.didDrag = true
        }
        voiceDrag = drag
        setNeedsDisplay()
        refreshSelectionRing(animated: false)
    }

    func voicePressEnded(at point: CGPoint, model: TimelineVoiceRowModel) {
        guard var drag = voiceDrag else { return }
        drag.translationX = point.x - drag.startPoint.x
        let dy = point.y - drag.startPoint.y
        if !drag.didDrag, sqrt(drag.translationX * drag.translationX + dy * dy) >= VoiceRowDrag.threshold {
            drag.didDrag = true
        }
        defer {
            voiceDrag = nil
            setNeedsDisplay()
        }
        guard drag.didDrag, snapshot.outputDuration > 0 else {
            voiceCallbacks?.selectClip(drag.initial.id)
            return
        }
        let math = voiceEditMath(model)
        voiceCallbacks?.commitClip(drag.initial.id, math.resolvedClip(
            from: drag.initial, mode: drag.mode, delta: math.delta(forTranslation: drag.translationX)))
    }

    // MARK: - VOICE drawing

    func drawVoiceLane(in context: CGContext, model: TimelineVoiceRowModel) {
        let orange = StudioTimelineStyle.voiceOrange
        let ink = StudioTimelineStyle.ink(traitCollection)
        for item in model.clips {
            let rect = voiceClipRect(item, model: model)
            guard rect.width > 0.5 else { continue }
            let radius = min(Self.voiceCornerRadius, rect.width / 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            orange.withAlphaComponent(item.isSelected ? 0.38 : 0.24).setFill()
            path.fill()
            orange.withAlphaComponent(item.isSelected ? 1.0 : 0.8).setStroke()
            let border = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, radius - 0.5))
            border.lineWidth = 1
            border.stroke()
            // Waveform (or a placeholder bar when it hasn't loaded / the file is gone).
            let wave = CGRect(x: rect.minX + 10, y: rect.maxY - 8 - 16, width: rect.width - 20, height: 16)
            if let samples = voiceAssets.waveforms[item.id], !samples.isEmpty, wave.width > 1 {
                let barWidth = max(1, wave.width / CGFloat(samples.count))
                ink.withAlphaComponent(0.52).setFill()
                for (index, sample) in samples.enumerated() {
                    let height = max(1, CGFloat(max(0, min(1, sample))) * wave.height)
                    UIBezierPath(roundedRect: CGRect(x: wave.minX + CGFloat(index) * barWidth, y: wave.midY - height / 2,
                                                     width: max(1, barWidth - 1), height: height), cornerRadius: 0.5).fill()
                }
            } else if wave.width > 1 {
                ink.withAlphaComponent(0.14).setFill()
                UIBezierPath(roundedRect: CGRect(x: wave.minX, y: wave.midY - 3, width: wave.width, height: 6), cornerRadius: 3).fill()
            }
            let title = NSAttributedString(string: "Voice Over", attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: ink.withAlphaComponent(0.92),
            ])
            if rect.width > title.size().width + 20 { title.draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 6)) }
            // Trim handles.
            orange.withAlphaComponent(item.isSelected ? 0.96 : 0.72).setFill()
            for x in [rect.minX + 3, rect.maxX - 5] {
                UIBezierPath(roundedRect: CGRect(x: x, y: rect.midY - 8, width: 2, height: 16), cornerRadius: 1).fill()
            }
        }
        if let live = model.live, snapshot.outputDuration > 0 {
            let duration = snapshot.outputDuration
            let rect = CGRect(x: bounds.width * CGFloat(live.startTime / duration), y: M.voiceLaneY,
                              width: max(Self.voiceMinBlockWidth, bounds.width * CGFloat(max(0.1, live.currentTime - live.startTime) / duration)),
                              height: M.trackHeight)
            orange.withAlphaComponent(0.24).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: Self.voiceCornerRadius).fill()
            UIColor.systemRed.setFill()
            UIBezierPath(ovalIn: CGRect(x: rect.minX + 8, y: rect.minY + 8, width: 7, height: 7)).fill()
        }
    }
}
