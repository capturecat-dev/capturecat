import Foundation
import CoreGraphics
import AppKit

// Codable, Sendable wrapper for CGPoint stored in normalized video space (0–1)
struct CodablePoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    init(_ point: CGPoint) { x = point.x; y = point.y }
    init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Keynote-style build effects. Raw values are persistence identity.
enum AnnotationEffect: String, CaseIterable, Codable, Sendable {
    case none = "None"
    case fade = "Fade"
    case pop = "Pop"
    case scaleUp = "Scale"
    case slideUp = "Slide Up"
    case drop = "Drop"
    case explode = "Explode"
    /// Strokes reveal in drawing order, like being drawn live (drawings
    /// only; other types fall back to a fade). As an exit it un-draws.
    case drawOn = "Draw On"
}

/// Pure, deterministic effect math shared by preview and exporter — progress
/// derives only from the timeline clock, so scrub/playback/export agree.
enum AnnotationEffectMath {
    struct Phase {
        var alpha: Double = 1
        var scale: Double = 1
        /// Positive = downward, in canvas points at 1× (exporter scales it).
        var offsetY: Double = 0
        /// Fraction of the drawing's strokes revealed, in drawing order
        /// (Draw On only; every other effect shows the full drawing).
        var strokeProgress: Double = 1
    }

    static let duration: TimeInterval = 0.3
    /// Draw On sweeps the pen across the whole drawing — it needs real time.
    static let drawOnDuration: TimeInterval = 1.0

    static func effectDuration(_ effect: AnnotationEffect) -> TimeInterval {
        effect == .drawOn ? drawOnDuration : duration
    }

    /// `progress` 0→1 (0 = fully out, 1 = fully shown).
    static func phase(effect: AnnotationEffect, progress p: Double) -> Phase {
        let t = min(1, max(0, p))
        switch effect {
        case .none:
            return Phase()
        case .fade:
            return Phase(alpha: t)
        case .pop:
            // Ease-out-back overshoot, analytic.
            let c = 1.70158
            let u = t - 1
            let s = 1 + (c + 1) * u * u * u + c * u * u
            return Phase(alpha: min(1, t * 2), scale: max(0.001, 0.4 + 0.6 * s))
        case .scaleUp:
            return Phase(alpha: t, scale: max(0.001, t))
        case .slideUp:
            let e = 1 - pow(1 - t, 3)
            return Phase(alpha: t, offsetY: (1 - e) * 28)
        case .drop:
            let e = 1 - pow(1 - t, 3)
            return Phase(alpha: t, offsetY: -(1 - e) * 44)
        case .explode:
            return Phase(alpha: t, scale: 1 + (1 - t) * 0.9)
        case .drawOn:
            // The pen fades in fast, then strokes reveal across the full
            // progress. Non-drawing types read only `alpha` — a fade.
            return Phase(alpha: min(1, t * 5), strokeProgress: t)
        }
    }

    /// Combined in/out phase at `time` for an annotation's span.
    static func combined(
        enter: AnnotationEffect,
        exit: AnnotationEffect,
        start: TimeInterval,
        end: TimeInterval,
        at time: TimeInterval
    ) -> Phase {
        let inP = enter == .none ? 1 : min(1, max(0, (time - start) / effectDuration(enter)))
        let outP = exit == .none ? 1 : min(1, max(0, (end - time) / effectDuration(exit)))
        if inP < 1 {
            return phase(effect: enter, progress: inP)
        }
        if outP < 1 {
            return phase(effect: exit, progress: outP)
        }
        return Phase()
    }
}

enum AnnotationType: String, Codable, Sendable, CaseIterable {
    case text
    case arrow
    case callout
    case drawing
    case rectangle
    case ellipse
    /// Manual tap indicator — a looping click-ripple at a fixed point, for
    /// showing touches on iPhone/iPad recordings (no touch events come over
    /// wired capture, so the user places these by hand).
    case tap
}

struct Annotation: Identifiable, Codable, Sendable {
    let id: UUID
    var type: AnnotationType
    var startTime: TimeInterval
    var endTime: TimeInterval

    // Normalized (0–1) in video space.
    // Text: center of label. Arrow: tail (start) point.
    var x: Double
    var y: Double
    // Arrow head (end) point — ignored for text / drawing annotations
    var arrowEndX: Double
    var arrowEndY: Double

    // Text
    var text: String
    var fontSize: Double
    var showBackground: Bool

    // Shared styling
    var color: CodableColor          // text color / arrow color / drawing stroke color
    var backgroundColor: CodableColor // text pill background

    // Arrow / drawing
    var lineWidth: Double

    // Drawing strokes — each stroke is an ordered array of normalized points
    var drawingStrokes: [[CodablePoint]]

    // Extended styling (2026-08 annotation redesign) — all optional-with-
    // default in the decoder so existing projects load untouched.
    /// Text/callout font weight (subtitle weight scale).
    var fontWeight: ProjectSettings.SubtitleWeight
    /// Uppercase the rendered text — mirrors the Subtitles tab's control so
    /// both surfaces offer the identical font selection.
    var uppercase: Bool
    /// Typeface family; nil = system font (see FontCatalog).
    var fontName: String?
    /// Whole-annotation opacity 0.2…1.
    var opacity: Double
    /// Rectangle/ellipse/callout corner radius (rect + callout pill).
    var cornerRadius: Double
    /// Legacy toggle kept for decoding old projects; superseded by
    /// enterEffect/exitEffect.
    var animatesIn: Bool
    /// Soft drop shadow behind text/shapes.
    var showShadow: Bool
    /// Keynote-style build effects.
    var enterEffect: AnnotationEffect
    var exitEffect: AnnotationEffect
    /// Blackout everything around the annotation (spotlight). 0 = off; the
    /// value is the black overlay's opacity. Rectangle/ellipse cut their shape
    /// out of the dim; other types dim the whole frame behind themselves.
    var backdropOpacity: Double

    /// Normalized anchor the build effects scale about — the shape's visual
    /// center where two points define it, the placement point otherwise.
    var effectAnchor: CGPoint {
        switch type {
        case .arrow, .rectangle, .ellipse:
            return CGPoint(x: (x + arrowEndX) / 2, y: (y + arrowEndY) / 2)
        default:
            return CGPoint(x: x, y: y)
        }
    }

    /// The string both renderers draw — one place, so preview and export can
    /// never disagree about casing.
    var displayText: String {
        uppercase ? text.uppercased() : text
    }

    func effectPhase(at time: TimeInterval) -> AnnotationEffectMath.Phase {
        AnnotationEffectMath.combined(
            enter: enterEffect, exit: exitEffect,
            start: startTime, end: endTime, at: time
        )
    }

    var duration: TimeInterval { endTime - startTime }

    init(
        id: UUID = UUID(),
        type: AnnotationType,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.type = type
        self.startTime = startTime
        self.endTime = endTime
        self.x = 0.5
        self.y = 0.38
        self.arrowEndX = 0.65
        self.arrowEndY = 0.55
        self.text = "Label"
        self.fontSize = 18
        self.showBackground = true
        self.color = CodableColor(NSColor.white)
        self.backgroundColor = CodableColor(red: 0, green: 0, blue: 0, opacity: 0.55)
        self.lineWidth = 4
        self.drawingStrokes = []
        self.fontWeight = .semibold
        self.uppercase = false
        self.opacity = 1
        self.cornerRadius = 8
        self.animatesIn = true
        self.showShadow = true
        self.enterEffect = .pop
        self.exitEffect = .fade
        self.backdropOpacity = 0
    }

    enum CodingKeys: String, CodingKey {
        case id, type, startTime, endTime
        case x, y, arrowEndX, arrowEndY
        case text, fontSize, showBackground
        case color, backgroundColor, lineWidth
        case drawingStrokes
        case fontWeight, uppercase, fontName, opacity, cornerRadius, animatesIn, showShadow
        case enterEffect, exitEffect
        case backdropOpacity
    }

    // Custom decoder so existing saved annotations (without drawingStrokes) still load
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self, forKey: .id)
        type           = try c.decode(AnnotationType.self, forKey: .type)
        startTime      = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime        = try c.decode(TimeInterval.self, forKey: .endTime)
        x              = try c.decode(Double.self, forKey: .x)
        y              = try c.decode(Double.self, forKey: .y)
        arrowEndX      = try c.decode(Double.self, forKey: .arrowEndX)
        arrowEndY      = try c.decode(Double.self, forKey: .arrowEndY)
        text           = try c.decode(String.self, forKey: .text)
        fontSize       = try c.decode(Double.self, forKey: .fontSize)
        showBackground = try c.decode(Bool.self, forKey: .showBackground)
        color          = try c.decode(CodableColor.self, forKey: .color)
        backgroundColor = try c.decode(CodableColor.self, forKey: .backgroundColor)
        lineWidth      = try c.decode(Double.self, forKey: .lineWidth)
        drawingStrokes = (try? c.decode([[CodablePoint]].self, forKey: .drawingStrokes)) ?? []
        fontWeight     = ((try? c.decodeIfPresent(ProjectSettings.SubtitleWeight.self, forKey: .fontWeight)) ?? .semibold) ?? .semibold
        uppercase      = (try? c.decodeIfPresent(Bool.self, forKey: .uppercase)) ?? false ?? false
        fontName       = (try? c.decodeIfPresent(String.self, forKey: .fontName)) ?? nil
        opacity        = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? 1 ?? 1
        cornerRadius   = (try? c.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? 8 ?? 8
        animatesIn     = (try? c.decodeIfPresent(Bool.self, forKey: .animatesIn)) ?? true ?? true
        showShadow     = (try? c.decodeIfPresent(Bool.self, forKey: .showShadow)) ?? true ?? true
        // Effects default from the legacy toggle: fade preserved the old look.
        let legacyDefault: AnnotationEffect = animatesIn ? .fade : .none
        enterEffect    = ((try? c.decodeIfPresent(AnnotationEffect.self, forKey: .enterEffect)) ?? legacyDefault) ?? legacyDefault
        exitEffect     = ((try? c.decodeIfPresent(AnnotationEffect.self, forKey: .exitEffect)) ?? .none) ?? .none
        backdropOpacity = (try? c.decodeIfPresent(Double.self, forKey: .backdropOpacity)) ?? 0 ?? 0
        // (An auto-pause pair briefly lived here — projects that saved those
        // keys still decode fine; unknown keys are simply not read.)
    }
}
