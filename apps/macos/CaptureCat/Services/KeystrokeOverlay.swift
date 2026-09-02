import AppKit
import CoreText

/// Where the shortcut pill sits on the canvas.
enum KeystrokeOverlayPosition: String, CaseIterable, Codable, Sendable {
    case bottomCenter
    case bottomLeft
    case bottomRight
    case topCenter

    var label: String {
        switch self {
        case .bottomCenter: return "Bottom Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topCenter: return "Top Center"
        }
    }
}

/// How the pill enters. Raw values are persistence identity — never rename.
enum KeystrokeOverlayAnimation: String, CaseIterable, Codable, Sendable {
    case slideUp
    case fade
    case pop

    var label: String {
        switch self {
        case .slideUp: return "Slide Up"
        case .fade: return "Fade"
        case .pop: return "Pop"
        }
    }
}

/// Timing + phrasing for the on-screen keyboard-shortcut pill ("⌘⇧S",
/// subtitle-style). Pure functions of the timeline clock — never a wall
/// clock — so scrubbing, playback and export all agree (CLAUDE.md §2).
///
/// Consumed by BOTH renderers via `KeystrokeOverlayRenderer`; nothing here
/// may fork between preview and export.
enum KeystrokeOverlayMath {
    static let fadeIn: TimeInterval = 0.12
    static let hold: TimeInterval = 1.1
    static let fadeOut: TimeInterval = 0.3
    /// A same-combo re-press inside this window collapses into "⌘Z ×2"
    /// instead of restarting the pill from scratch.
    static let repeatWindow: TimeInterval = 0.8

    struct DisplayEvent: Equatable, Sendable {
        var time: TimeInterval
        var text: String
    }

    /// The pill's presentation at one instant: text, opacity, and a 0→1 entry
    /// progress (drives the small slide-up, shared so export animates too).
    struct Pill: Equatable, Sendable {
        var text: String
        var alpha: Double
        var entry: Double
    }

    /// Render-time app scoping for window recordings: keeps only events whose
    /// shortcut was delivered to the recorded app, dropping mid-recording
    /// shortcuts typed into OTHER apps (Slack etc. — noise and a context
    /// leak). Events with nil `frontmostBundleID` (older recordings) always
    /// pass. Inert unless the recording is window-scoped, the toggle is on
    /// and the recorded app's bundle id is known.
    static func scopedEvents(
        _ events: [KeystrokeEvent],
        recordedAppBundleID: String?,
        scopeToRecordedApp: Bool,
        sourceKind: RecordingSourceKind
    ) -> [KeystrokeEvent] {
        guard scopeToRecordedApp, sourceKind == .window,
              let target = recordedAppBundleID else { return events }
        return events.filter { $0.frontmostBundleID == nil || $0.frontmostBundleID == target }
    }

    /// The ONE derivation both renderers use: scope filter, then collapse.
    /// Preview and export must call this (not the raw overload below) so the
    /// filtering can never fork between the two paths (CLAUDE.md §2).
    static func displayEvents(
        from events: [KeystrokeEvent], scopedTo project: Project
    ) -> [DisplayEvent] {
        displayEvents(from: scopedEvents(
            events,
            recordedAppBundleID: project.recordedAppBundleID,
            scopeToRecordedApp: project.settings.keystrokeOverlayScopeToRecordedApp,
            sourceKind: project.recordingSourceKind
        ))
    }

    /// Collapses raw shortcut events into display entries, merging rapid
    /// repeats of the same combo into a counted one ("⌘Z ×3").
    static func displayEvents(from events: [KeystrokeEvent]) -> [DisplayEvent] {
        var out: [DisplayEvent] = []
        var lastBase: String? = nil
        var lastTime: TimeInterval = -.infinity
        var count = 0
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let shortcut = event.shortcut else { continue }
            if shortcut == lastBase, event.timestamp - lastTime <= repeatWindow {
                count += 1
                out.append(DisplayEvent(time: event.timestamp, text: "\(shortcut) ×\(count)"))
            } else {
                count = 1
                out.append(DisplayEvent(time: event.timestamp, text: shortcut))
            }
            lastBase = shortcut
            lastTime = event.timestamp
        }
        return out
    }

    /// The pill visible at `currentTime`, or nil. Phases derive from
    /// `currentTime - event.time` only.
    static func activePill(displayEvents: [DisplayEvent], currentTime: TimeInterval) -> Pill? {
        guard let latest = displayEvents.last(where: { $0.time <= currentTime }) else { return nil }
        let elapsed = currentTime - latest.time
        let total = fadeIn + hold + fadeOut
        guard elapsed >= 0, elapsed < total else { return nil }
        let alpha: Double
        if elapsed < fadeIn {
            alpha = elapsed / fadeIn
        } else if elapsed < fadeIn + hold {
            alpha = 1
        } else {
            alpha = 1 - (elapsed - fadeIn - hold) / fadeOut
        }
        let entry = min(1, elapsed / (fadeIn * 2))
        return Pill(text: latest.text, alpha: max(0, min(1, alpha)), entry: entry)
    }

    /// Entry offset for `.slideUp` (starts 8pt low, settles); zero for the
    /// other styles. Pure function of entry so both renderers agree.
    static func slideOffset(
        animation: KeystrokeOverlayAnimation, entry: Double, scale: CGFloat
    ) -> CGFloat {
        guard animation == .slideUp else { return 0 }
        return CGFloat(1 - entry) * 8 * scale
    }

    /// Entry scale for `.pop`: grows from 85% with a small overshoot
    /// (ease-out-back), settling at exactly 1. Identity for other styles.
    static func popScale(animation: KeystrokeOverlayAnimation, entry: Double) -> CGFloat {
        guard animation == .pop, entry < 1 else { return 1 }
        let c1 = 1.70158, c3 = c1 + 1
        let t = entry - 1
        let eased = 1 + c3 * t * t * t + c1 * t * t
        return CGFloat(0.85 + 0.15 * eased)
    }

    /// Pill center in a Y-DOWN canvas of `canvasSize`, including the entry
    /// slide (starts 8pt low, settles). `scale` is the export pt multiplier.
    static func pillCenter(
        position: KeystrokeOverlayPosition,
        canvasSize: CGSize,
        pillSize: CGSize,
        entry: Double,
        scale: CGFloat,
        animation: KeystrokeOverlayAnimation = .slideUp
    ) -> CGPoint {
        let edge: CGFloat = 28 * scale
        let x: CGFloat
        switch position {
        case .bottomCenter, .topCenter: x = canvasSize.width / 2
        case .bottomLeft: x = edge + pillSize.width / 2
        case .bottomRight: x = canvasSize.width - edge - pillSize.width / 2
        }
        let slide = slideOffset(animation: animation, entry: entry, scale: scale)
        let y: CGFloat
        switch position {
        case .topCenter:
            y = edge + pillSize.height / 2 - slide
        default:
            // Sits above the subtitle band (subtitles hug the 20pt inset).
            y = canvasSize.height - 72 * scale - pillSize.height / 2 + slide
        }
        return CGPoint(x: x, y: y)
    }

    /// The pill's frame, ORIGIN-SNAPPED to the pixel grid. Both renderers
    /// must place the pill with this: a fractional origin antialiases the
    /// exporter's in-place draw differently from the preview's cached raster,
    /// and the parity gate catches the drift.
    static func pillRect(
        position: KeystrokeOverlayPosition,
        canvasSize: CGSize,
        pillSize: CGSize,
        entry: Double,
        scale: CGFloat,
        animation: KeystrokeOverlayAnimation = .slideUp
    ) -> CGRect {
        let center = pillCenter(
            position: position, canvasSize: canvasSize,
            pillSize: pillSize, entry: entry, scale: scale, animation: animation
        )
        return CGRect(
            x: (center.x - pillSize.width / 2).rounded(),
            y: (center.y - pillSize.height / 2).rounded(),
            width: pillSize.width, height: pillSize.height
        )
    }
}

/// Rasterizes the shortcut pill. One CG drawing function shared verbatim by
/// the CoreAnimation preview and the CoreImage exporter (the AnnotationRenderer
/// model): the context is ALREADY y-down; `image(...)` wraps it with the flip.
enum KeystrokeOverlayRenderer {
    /// All pt values below multiply by `scale` (preview canvas: 1; export:
    /// output-width / reference-canvas-width) and by the user size knob.
    static func pillSize(text: String, size: Double, scale: CGFloat) -> CGSize {
        let line = makeLine(text: text, size: size, scale: scale, color: .white)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let padH = 14 * CGFloat(size) * scale
        let padV = 8 * CGFloat(size) * scale
        return CGSize(width: ceil(width) + padH * 2, height: ceil(ascent + descent) + padV * 2)
    }

    /// Draws `pill` into an already y-down context covering `canvasSize`.
    static func draw(
        in ctx: CGContext,
        pill: KeystrokeOverlayMath.Pill,
        canvasSize: CGSize,
        position: KeystrokeOverlayPosition,
        size: Double,
        scale: CGFloat,
        animation: KeystrokeOverlayAnimation = .slideUp
    ) {
        let box = pillSize(text: pill.text, size: size, scale: scale)
        let rect = KeystrokeOverlayMath.pillRect(
            position: position, canvasSize: canvasSize,
            pillSize: box, entry: pill.entry, scale: scale, animation: animation
        )
        ctx.saveGState()
        ctx.setAlpha(CGFloat(pill.alpha))
        // Pop entry: scale about the pill's center — the same values the
        // preview feeds into its layer transform.
        let pop = KeystrokeOverlayMath.popScale(animation: animation, entry: pill.entry)
        if pop != 1 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: pop, y: pop)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawPill(in: ctx, text: pill.text, rect: rect, size: size, scale: scale)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The pill's pixels — one function, so the preview's cached raster and
    /// the exporter's full-canvas burn cannot drift. `rect` in the ctx's
    /// (y-down) space.
    static func drawPill(
        in ctx: CGContext,
        text: String,
        rect: CGRect,
        size: Double,
        scale: CGFloat
    ) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.82))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(1 * scale)
        ctx.strokePath()

        // CTLine draws in y-up text space: flip locally around the text rect.
        let line = makeLine(text: text, size: size, scale: scale, color: .white)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: rect.midX - width / 2, y: rect.midY + (ascent - descent) / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Standalone raster of the pill at full opacity — the preview caches
    /// this per text and animates opacity/position from the SAME math values
    /// the exporter feeds into `draw`.
    static func pillImage(
        text: String,
        size: Double,
        scale: CGFloat,
        rasterScale: CGFloat
    ) -> (image: CGImage, size: CGSize)? {
        let box = pillSize(text: text, size: size, scale: scale)
        let w = Int((box.width * rasterScale).rounded(.up))
        let h = Int((box.height * rasterScale).rounded(.up))
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: rasterScale, y: rasterScale)
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: 1, y: -1)
        drawPill(in: ctx, text: text, rect: CGRect(origin: .zero, size: box), size: size, scale: scale)
        guard let img = ctx.makeImage() else { return nil }
        return (img, box)
    }

    /// Full-canvas transparent raster of the overlay at `currentTime`, drawn
    /// y-down then flipped into a CGImage — identical composition on both
    /// sides. Returns nil when no pill is active (both callers skip work).
    static func image(
        canvasSize: CGSize,
        displayEvents: [KeystrokeOverlayMath.DisplayEvent],
        currentTime: TimeInterval,
        position: KeystrokeOverlayPosition,
        size: Double,
        scale: CGFloat,
        rasterScale: CGFloat,
        animation: KeystrokeOverlayAnimation = .slideUp
    ) -> CGImage? {
        guard let pill = KeystrokeOverlayMath.activePill(
            displayEvents: displayEvents, currentTime: currentTime
        ) else { return nil }
        let w = Int((canvasSize.width * rasterScale).rounded())
        let h = Int((canvasSize.height * rasterScale).rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.scaleBy(x: rasterScale, y: rasterScale)
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, pill: pill, canvasSize: canvasSize,
             position: position, size: size, scale: scale, animation: animation)
        return ctx.makeImage()
    }

    private static func makeLine(text: String, size: Double, scale: CGFloat, color: NSColor) -> CTLine {
        let font = NSFont.systemFont(ofSize: 17 * CGFloat(size) * scale, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: 1.2 * CGFloat(size) * scale,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }
}
