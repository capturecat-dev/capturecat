import CoreGraphics
import Foundation

/// Corner the curtain peels away from. Raw values are persistence identity —
/// never rename one (old projects must always still load).
enum CurtainUnveilCorner: String, CaseIterable, Codable, Sendable {
    case off = "Off"
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"

    /// The starting corner in UNIT card space (0…1, Y-DOWN).
    var point: CGPoint {
        switch self {
        case .off: return .zero
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }
}

/// Curtain Unveil — an iBooks-style page peel with a physical FLICK-OFF. At
/// the effect's start the card is covered by a curtain; a fold line
/// perpendicular to the corner→opposite-corner diagonal sweeps from the
/// chosen corner across the card. The corner side of the fold is revealed;
/// the peeled-back curtain shows as a lighter "page back" flap.
///
/// Motion shape: slow anticipation, then from `flickStart` the fold whips —
/// velocity peaks LATE — and in the release window the flap's over-fold ramps
/// up, the flap slides off along the diagonal with momentum, and it fades
/// out: the page leaves the surface rather than shrinking to nothing.
///
/// Deterministic from OUTPUT time only, like `IntroSlideMath` — no wall
/// clock, no stored state. SHARED by the preview compositor and the exporter:
/// both consume `state(...)` AND the one `renderImage` rasterizer below, so
/// the two paths cannot fork. All State geometry is in UNIT card space
/// (0…1, Y-DOWN); the single Y flip for CG/CI's Y-up raster space happens
/// exactly once, inside `draw`.
enum CurtainUnveilMath {
    /// Plain color components — NOT NSColor — so CoreImage and CoreAnimation
    /// consumers read the identical values.
    struct RGBA: Equatable, Sendable {
        var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

        func withAlpha(_ alpha: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: a * alpha) }
    }

    // ── Shared visual constants (both renderers go through `draw`) ─────────
    static let coverColorTop = RGBA(r: 0x1C / 255, g: 0x1C / 255, b: 0x1E / 255, a: 1)
    static let coverColorBottom = RGBA(r: 0x2C / 255, g: 0x2C / 255, b: 0x2E / 255, a: 1)
    /// Page back: cool paper, not plain grey (slight blue-ward drift far side).
    static let flapColorNear = RGBA(r: 0xF4 / 255, g: 0xF5 / 255, b: 0xF8 / 255, a: 1)
    static let flapColorFar = RGBA(r: 0xD6 / 255, g: 0xD9 / 255, b: 0xE0 / 255, a: 1)
    static let foldShadowMaxOpacity: CGFloat = 0.35
    /// Crease shadow band depth into the revealed side (diagonal fraction) at
    /// its mid-peel widest; `State.shadowWidth` carries the per-progress value.
    static let shadowBandFraction: CGFloat = 0.06
    /// A custom curtain color derives its gradient's second stop by darkening
    /// the base this much — computed HERE so both renderers agree.
    static let coverDarkenFraction: CGFloat = 0.12

    // Surface materiality (Keynote-restrained, single-digit opacities).
    /// Diagonal sheen band across the cover, drifting with progress.
    static let sheenOpacity: CGFloat = 0.06
    static let sheenHalfWidth: CGFloat = 0.22
    /// Vignette toward the cover's outer corner.
    static let vignetteOpacity: CGFloat = 0.10
    static let vignetteRadiusFraction: CGFloat = 0.95
    /// Wide soft ambient shadow the curtain casts AHEAD of the fold onto the
    /// revealed video — the "floats above the content" depth cue.
    static let ambientShadowWidthFraction: CGFloat = 0.16
    static let ambientShadowMaxOpacity: CGFloat = 0.18
    /// Bright crease highlight along the fold on the FLAP side.
    static let foldSpecularOpacity: CGFloat = 0.45
    static let foldSpecularWidthFactor: CGFloat = 0.35
    /// Soft sheen across the page back.
    static let flapSheenOpacity: CGFloat = 0.08

    // Flick-off motion (all functions of p only — deterministic).
    /// Progress where anticipation ends and the whip begins.
    static let flickStart = 0.6
    /// Ease value reached at `flickStart` (the whip covers the rest).
    static let flickJoin = 0.3
    /// Normalized terminal slope of the whip — the release keeps momentum.
    static let releaseSlope = 0.25
    /// Progress where the flap RELEASES: over-fold ramps up, the flap slides
    /// off along the diagonal and fades.
    static let releaseStart = 0.8
    /// The flap (and its shadows/highlights) fade over this final window.
    static let releaseFadeWindow = 0.12
    /// Flap lift during the peel / extra whip fold during the release.
    static let baseOverfoldDegrees: Double = 6
    static let whipOverfoldDegrees: Double = 18
    /// How far (unit diagonal fraction) the flap slides off in the release.
    static let releaseTravel: CGFloat = 0.18
    /// Crease shadow intensifies by up to this factor during the whip.
    static let whipShadowBoost: CGFloat = 0.6

    /// Card silhouette the curtain is confined to — the curtain must never
    /// poke square corners past a rounded or device-framed card. Geometry is
    /// stored as FRACTIONS of the card so preview points and export pixels
    /// reconstruct the IDENTICAL path (pass the radius in the same units as
    /// the card size you derive it from).
    struct CardClip: Equatable, Sendable {
        enum Shape: Sendable { case rectangle, rounded, squircle }
        var shape: Shape = .rectangle
        /// Corner radius ÷ min(card width, height).
        var cornerRadiusFraction: CGFloat = 0
        /// Device screen in UNIT card space (Y-DOWN); non-nil replaces the
        /// window shape — device cards clip the curtain to the screen.
        var screenRectUnit: CGRect? = nil
        var screenCornerRadiusFraction: CGFloat = 0
    }

    /// The one Settings → CardClip mapping BOTH renderers use. `cornerRadius`
    /// and `deviceScreen` must be in the SAME units as `cardSize` (preview
    /// passes points, export passes output pixels — the stored fractions are
    /// identical because export scales radius and rect together).
    static func cardClip(
        frameShape: ProjectSettings.FrameShape,
        cornerRadius: CGFloat,
        cardSize: CGSize,
        deviceScreen: (rect: CGRect, cornerRadius: CGFloat)?
    ) -> CardClip {
        let w = max(1, cardSize.width), h = max(1, cardSize.height)
        let minDim = min(w, h)
        if let deviceScreen {
            return CardClip(
                shape: .squircle,
                screenRectUnit: CGRect(
                    x: deviceScreen.rect.minX / w,
                    y: deviceScreen.rect.minY / h,
                    width: deviceScreen.rect.width / w,
                    height: deviceScreen.rect.height / h),
                screenCornerRadiusFraction: max(0, deviceScreen.cornerRadius) / minDim)
        }
        let r = min(max(0, cornerRadius), minDim / 2) / minDim
        switch frameShape {
        case .rectangle: return CardClip()
        case .roundedRect: return CardClip(shape: .rounded, cornerRadiusFraction: r)
        case .squircle: return CardClip(shape: .squircle, cornerRadiusFraction: r)
        }
    }

    /// The clip path in the rasterizer's Y-UP pixel space; nil = no clipping
    /// (rectangular card). The unit→raster Y flip happens HERE, once.
    static func cardClipPath(_ clip: CardClip, size: CGSize) -> CGPath? {
        let minDim = min(size.width, size.height)
        if let unit = clip.screenRectUnit {
            let rect = CGRect(
                x: unit.minX * size.width,
                y: (1 - unit.maxY) * size.height,
                width: unit.width * size.width,
                height: unit.height * size.height)
            return ContinuousRoundedRect.path(
                rect: rect, cornerRadius: clip.screenCornerRadiusFraction * minDim)
        }
        let r = clip.cornerRadiusFraction * minDim
        guard r > 0.01 else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        switch clip.shape {
        case .rectangle: return nil
        case .rounded:
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .squircle:
            return ContinuousRoundedRect.path(rect: rect, cornerRadius: r)
        }
    }

    /// Optional cover styling: brand color and centered logo. The logo is part
    /// of the curtain surface — drawn INSIDE the cover polygon so it peels
    /// away with the curtain.
    struct CoverStyle {
        /// nil → the default charcoal stops; non-nil → stops derived from it.
        var baseColor: RGBA? = nil
        var logo: CGImage? = nil
        var logoOpacity: CGFloat = 1
        /// Logo width as a fraction of the card width.
        var logoScale: CGFloat = 0.25
        /// nil → original colors; non-nil → tint the logo's alpha silhouette.
        var logoTint: RGBA? = nil
        /// Confines every curtain element to the card's silhouette.
        var cardClip: CardClip? = nil
    }

    /// The one Settings → CoverStyle mapping BOTH renderers use (colors pass
    /// through CodableColor's stored sRGB doubles — no NSColor round trip).
    static func coverStyle(
        settings: ProjectSettings, logo: CGImage?, cardClip: CardClip? = nil
    ) -> CoverStyle {
        func rgba(_ c: CodableColor) -> RGBA {
            RGBA(r: CGFloat(c.red), g: CGFloat(c.green), b: CGFloat(c.blue), a: CGFloat(c.opacity))
        }
        return CoverStyle(
            baseColor: settings.curtainColor.map(rgba),
            logo: logo,
            logoOpacity: CGFloat(settings.curtainLogoOpacity),
            logoScale: CGFloat(settings.curtainLogoScale),
            logoTint: settings.curtainLogoTint.map(rgba),
            cardClip: cardClip)
    }

    /// Cover gradient stops for an optional custom base — base, and base
    /// darkened by `coverDarkenFraction`. Both renderers derive from HERE.
    static func coverStops(base: RGBA?) -> (top: RGBA, bottom: RGBA) {
        guard let base else { return (coverColorTop, coverColorBottom) }
        let k = 1 - coverDarkenFraction
        return (base, RGBA(r: base.r * k, g: base.g * k, b: base.b * k, a: base.a))
    }

    struct State: Equatable {
        /// Still-covered region: unit square clipped to the far side of the fold.
        var coverPolygon: [CGPoint] = []
        /// Peeled-back page flap: revealed region reflected across the fold,
        /// over-folded/slid per the flick curves, clipped to the unit square.
        var flapPolygon: [CGPoint] = []
        var foldStart: CGPoint = .zero
        var foldEnd: CGPoint = .zero
        /// Shadow opacity factor: softens mid-peel, spikes during the whip,
        /// vanishes with the flap.
        var shadowStrength: CGFloat = 0
        /// Crease shadow band depth (unit fraction): widens mid-peel.
        var shadowWidth: CGFloat = 0
        /// 1 until the release window, then fades to 0 — the flap (and its
        /// highlights/shadows) leave the surface with it.
        var flapOpacity: CGFloat = 1
        /// Clamped sweep progress — the rasterizer's sheen drifts with it.
        var progress: CGFloat = 0
        var active = false
    }

    static let unitSquare = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ]

    // MARK: - Motion curves

    /// Flick sweep: cubic-in anticipation over [0, flickStart] reaching
    /// `flickJoin`, then a cubic-Hermite whip over [flickStart, 1] whose start
    /// slope matches the anticipation (C1) and whose end slope is
    /// `releaseSlope` — velocity peaks LATE (≈0.75–0.9), the last few percent
    /// snap off with momentum. Monotonic; lands at EXACTLY 1.
    static func sweepEase(_ p: Double) -> Double {
        let p = max(0, min(1, p))
        let a = flickStart, m = flickJoin
        if p <= a {
            let q = p / a
            return m * q * q * q
        }
        let u = (p - a) / (1 - a)
        // Normalized boundary slopes of the whip segment.
        let d0 = (3 * m / a) * (1 - a) / (1 - m)
        let d1 = releaseSlope
        let u2 = u * u, u3 = u2 * u
        let h = (u3 - 2 * u2 + u) * d0 + (-2 * u3 + 3 * u2) + (u3 - u2) * d1
        return m + (1 - m) * h
    }

    /// Flap fold beyond the exact mirror. Rises gently through the peel (the
    /// lift), then RAMPS UP through the release — the page whips off rather
    /// than settling back to the mirror.
    static func flapOverfoldRadians(_ p: Double) -> Double {
        let p = max(0, min(1, p))
        let base = baseOverfoldDegrees * .pi / 180
        if p <= releaseStart {
            return base * sin(.pi / 2 * p / releaseStart)
        }
        let r = (p - releaseStart) / (1 - releaseStart)
        return base + whipOverfoldDegrees * .pi / 180 * r * r
    }

    /// Flap slide off the corner direction (unit diagonal fraction) — zero
    /// until the release, then accelerating: momentum, not shrinkage.
    static func flapReleaseOffset(_ p: Double) -> CGFloat {
        let p = max(0, min(1, p))
        guard p > releaseStart else { return 0 }
        let r = CGFloat((p - releaseStart) / (1 - releaseStart))
        return releaseTravel * r * r
    }

    /// 1 until the final `releaseFadeWindow`, then linear to 0 at p = 1.
    static func flapOpacityValue(_ p: Double) -> CGFloat {
        let p = max(0, min(1, p))
        guard p > 1 - releaseFadeWindow else { return 1 }
        return CGFloat(max(0, (1 - p) / releaseFadeWindow))
    }

    /// Crease shadow band depth at `p`: widens mid-peel, tight at the ends.
    static func shadowWidthFraction(_ p: Double) -> CGFloat {
        let p = max(0, min(1, p))
        return shadowBandFraction * CGFloat(2).squareRoot()
            * (0.35 + 0.65 * CGFloat(sin(.pi * p)))
    }

    /// Shadow opacity factor at `p`: crisp near the ends, softened mid-peel,
    /// INTENSIFIED during the whip, and vanishing with the flap's fade.
    static func shadowStrengthValue(_ p: Double) -> CGFloat {
        let p = max(0, min(1, p))
        let base = 1 - 0.4 * CGFloat(sin(.pi * p))
        var whip: CGFloat = 1
        if p > releaseStart {
            whip += whipShadowBoost * CGFloat(sin(.pi * (p - releaseStart) / (1 - releaseStart)))
        }
        return base * whip * flapOpacityValue(p)
    }

    static func state(
        corner: CurtainUnveilCorner,
        at outputTime: TimeInterval,
        startTime: TimeInterval,
        duration: Double
    ) -> State {
        guard corner != .off, duration > 0.05 else { return State() }
        let rawP = (outputTime - startTime) / duration
        guard rawP < 1 else { return State() } // fully revealed → skip all work
        let p = max(0, min(1, rawP))
        let eased = sweepEase(p)

        let c = corner.point
        let opp = CGPoint(x: 1 - c.x, y: 1 - c.y)
        let diagonal = CGFloat(2).squareRoot()
        // Unit direction along the corner→opposite diagonal.
        let d = CGPoint(x: (opp.x - c.x) / diagonal, y: (opp.y - c.y) / diagonal)
        // Fold point: eased travel from the corner along the diagonal.
        let travel = CGFloat(eased) * diagonal
        let f = CGPoint(x: c.x + d.x * travel, y: c.y + d.y * travel)

        // Cover: far side of the fold. Revealed: corner side.
        let cover = clip(unitSquare) { dot($0 - f, d) }
        let revealed = clip(unitSquare) { -dot($0 - f, d) }
        // Flap: revealed region mirrored across the fold, over-folded about
        // the fold point (lift → whip), slid off along the diagonal during
        // the release, kept on the card.
        var flap = revealed.map { reflect($0, foldPoint: f, normal: d) }
        let overfold = flapOverfoldRadians(p)
        if abs(overfold) > 0.000001, flap.count >= 3 {
            let cosA = CGFloat(cos(overfold)), sinA = CGFloat(sin(overfold))
            flap = flap.map { q in
                let dx = q.x - f.x, dy = q.y - f.y
                return CGPoint(x: f.x + dx * cosA - dy * sinA,
                               y: f.y + dx * sinA + dy * cosA)
            }
        }
        let slide = flapReleaseOffset(p)
        if slide > 0.000001 {
            flap = flap.map { CGPoint(x: $0.x + d.x * slide, y: $0.y + d.y * slide) }
        }
        flap = clipToUnitSquare(flap)
        if polygonArea(flap) < 0.000001 { flap = [] }

        let (fs, fe) = foldEndpoints(foldPoint: f, normal: d)
        return State(
            coverPolygon: cover, flapPolygon: flap,
            foldStart: fs, foldEnd: fe,
            shadowStrength: shadowStrengthValue(p),
            shadowWidth: shadowWidthFraction(p),
            flapOpacity: flapOpacityValue(p),
            progress: CGFloat(p),
            active: true)
    }

    /// Thin band extruded from the fold line into the REVEALED half-plane —
    /// the peel's crease shadow. Same polygon for preview and export.
    static func shadowPolygon(state: State) -> [CGPoint] {
        bandPolygon(state: state, width: state.shadowWidth)
    }

    /// Wide soft band ahead of the fold — the curtain's AMBIENT cast shadow
    /// onto the revealed content (the floats-above-the-video depth cue).
    static func ambientShadowPolygon(state: State) -> [CGPoint] {
        bandPolygon(state: state,
                    width: ambientShadowWidthFraction * CGFloat(2).squareRoot())
    }

    private static func bandPolygon(state: State, width: CGFloat) -> [CGPoint] {
        guard state.active, width > 0.000001 else { return [] }
        let dir = revealedDirection(state: state)
        guard dir != .zero else { return [] }
        let poly = [
            state.foldStart, state.foldEnd,
            CGPoint(x: state.foldEnd.x + dir.x * width, y: state.foldEnd.y + dir.y * width),
            CGPoint(x: state.foldStart.x + dir.x * width, y: state.foldStart.y + dir.y * width),
        ]
        return clipToUnitSquare(poly)
    }

    // MARK: - Geometry helpers (harness-tested)

    /// Reflect a point across the line through `a` and `b`.
    static func reflect(_ p: CGPoint, acrossLineThrough a: CGPoint, _ b: CGPoint) -> CGPoint {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0.000001 else { return p }
        let n = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
        return reflect(p, foldPoint: a, normal: n)
    }

    /// Signed shoelace area, absolute value (unit-space fractions).
    static func polygonArea(_ poly: [CGPoint]) -> CGFloat {
        guard poly.count >= 3 else { return 0 }
        var s: CGFloat = 0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// Sutherland–Hodgman clip against ONE half-plane: keep `signed(q) >= 0`.
    static func clip(_ poly: [CGPoint], keepWhere signed: (CGPoint) -> CGFloat) -> [CGPoint] {
        guard poly.count >= 3 else { return [] }
        var out: [CGPoint] = []
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let sa = signed(a), sb = signed(b)
            if sa >= 0 { out.append(a) }
            if (sa >= 0) != (sb >= 0) {
                let t = sa / (sa - sb)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return out.count >= 3 ? out : []
    }

    static func clipToUnitSquare(_ poly: [CGPoint]) -> [CGPoint] {
        var out = poly
        out = clip(out) { $0.x }
        out = clip(out) { 1 - $0.x }
        out = clip(out) { $0.y }
        out = clip(out) { 1 - $0.y }
        return out
    }

    private static func reflect(_ q: CGPoint, foldPoint f: CGPoint, normal d: CGPoint) -> CGPoint {
        let s = dot(q - f, d)
        return CGPoint(x: q.x - 2 * s * d.x, y: q.y - 2 * s * d.y)
    }

    /// The fold line (through `f`, perpendicular to `d`) clipped to the unit
    /// square. Degenerate (corner touch) collapses both endpoints onto `f`.
    private static func foldEndpoints(foldPoint f: CGPoint, normal d: CGPoint) -> (CGPoint, CGPoint) {
        var hits: [CGPoint] = []
        for i in 0..<unitSquare.count {
            let a = unitSquare[i], b = unitSquare[(i + 1) % unitSquare.count]
            let da = dot(a - f, d), db = dot(b - f, d)
            if abs(da - db) < 0.0000001 { continue } // edge parallel to fold
            let t = da / (da - db)
            guard t >= -0.0000001, t <= 1.0000001 else { continue }
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            if !hits.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 0.000001 }) {
                hits.append(p)
            }
        }
        guard hits.count >= 2 else { return (f, f) }
        return (hits[0], hits[1])
    }

    private static func centroid(_ poly: [CGPoint]) -> CGPoint {
        guard !poly.isEmpty else { return .zero }
        var c = CGPoint.zero
        for p in poly { c.x += p.x; c.y += p.y }
        return CGPoint(x: c.x / CGFloat(poly.count), y: c.y / CGFloat(poly.count))
    }

    /// Unit direction across the fold pointing INTO the revealed half-plane
    /// (away from the cover polygon). Zero when indeterminate.
    private static func revealedDirection(state: State) -> CGPoint {
        let fd = CGPoint(x: state.foldEnd.x - state.foldStart.x,
                         y: state.foldEnd.y - state.foldStart.y)
        let len = hypot(fd.x, fd.y)
        guard len > 0.000001 else { return .zero }
        var n = CGPoint(x: -fd.y / len, y: fd.x / len)
        guard state.coverPolygon.count >= 3 else { return .zero }
        let mid = CGPoint(x: (state.foldStart.x + state.foldEnd.x) / 2,
                          y: (state.foldStart.y + state.foldEnd.y) / 2)
        let toCover = centroid(state.coverPolygon) - mid
        if dot(toCover, n) > 0 { n = CGPoint(x: -n.x, y: -n.y) }
        return n
    }

    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }

    // MARK: - Shared rasterizer (the ONE renderer both sides consume)

    /// Renders the curtain for `state` into a fresh sRGB bitmap of `size`
    /// pixels covering the card. The preview shows this image as layer
    /// contents; the exporter wraps the SAME image in a CIImage — preview and
    /// export cannot drift because there is exactly one drawing path.
    static func renderImage(state: State, size: CGSize, style: CoverStyle = CoverStyle()) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, state.active,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(state: state, in: ctx, size: CGSize(width: w, height: h), style: style)
        return ctx.makeImage()
    }

    /// Draws cover (gradient + sheen + vignette + optional logo), ambient cast
    /// shadow, flap (cool paper + sheen), crease shadow and fold specular into
    /// a Y-UP CGContext of `size`. The unit-space → raster mapping (including
    /// the single Y flip, y_raster = (1 − y_unit) · h) lives HERE and nowhere
    /// else.
    static func draw(state: State, in ctx: CGContext, size: CGSize, style: CoverStyle = CoverStyle()) {
        guard state.active, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        // Card silhouette clip FIRST — every curtain element (cover, logo,
        // flap, shadows, specular) stays inside the rounded/device card.
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let clip = style.cardClip, let clipPath = cardClipPath(clip, size: size) {
            ctx.addPath(clipPath)
            ctx.clip()
        }
        func map(_ u: CGPoint) -> CGPoint {
            CGPoint(x: u.x * size.width, y: (1 - u.y) * size.height)
        }
        func path(_ poly: [CGPoint]) -> CGPath? {
            guard poly.count >= 3 else { return nil }
            let p = CGMutablePath()
            p.addLines(between: poly.map(map))
            p.closeSubpath()
            return p
        }
        func color(_ c: RGBA) -> CGColor? {
            CGColor(colorSpace: space, components: [c.r, c.g, c.b, c.a])
        }
        func gradient(_ stops: [RGBA], locations: [CGFloat]) -> CGGradient? {
            let colors = stops.compactMap(color)
            guard colors.count == stops.count else { return nil }
            return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
        }
        func fill(
            _ poly: [CGPoint], _ g: CGGradient?, from a: CGPoint, to b: CGPoint,
            extend: Bool = true
        ) {
            guard let p = path(poly), let g else { return }
            ctx.saveGState()
            ctx.addPath(p)
            ctx.clip()
            ctx.drawLinearGradient(
                g, start: map(a), end: map(b),
                options: extend ? [.drawsBeforeStartLocation, .drawsAfterEndLocation] : [])
            ctx.restoreGState()
        }

        let fade = state.flapOpacity
        let mid = CGPoint(x: (state.foldStart.x + state.foldEnd.x) / 2,
                          y: (state.foldStart.y + state.foldEnd.y) / 2)
        let revealDir = revealedDirection(state: state)
        // Direction INTO the cover — falls back to fold-mid → cover centroid
        // when the fold is degenerate (p = 0, full cover).
        let coverDir: CGPoint = {
            if revealDir != .zero { return CGPoint(x: -revealDir.x, y: -revealDir.y) }
            guard state.coverPolygon.count >= 3 else { return .zero }
            let c = centroid(state.coverPolygon)
            let v = CGPoint(x: c.x - mid.x, y: c.y - mid.y)
            let len = hypot(v.x, v.y)
            guard len > 0.000001 else { return .zero }
            return CGPoint(x: v.x / len, y: v.y / len)
        }()

        // ── Cover: base gradient, sheen band, vignette, logo ──────────────
        let stops = coverStops(base: style.baseColor)
        fill(state.coverPolygon, gradient([stops.top, stops.bottom], locations: [0, 1]),
             from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1))

        if state.coverPolygon.count >= 3, coverDir != .zero {
            // Sheen: a soft white band angled with the fold direction that
            // drifts across the surface with progress — the lit-sheet read.
            let clear = RGBA(r: 1, g: 1, b: 1, a: 0)
            let lit = RGBA(r: 1, g: 1, b: 1, a: sheenOpacity)
            let drift = 0.3 + 0.4 * state.progress
            let center = CGPoint(x: mid.x + coverDir.x * drift, y: mid.y + coverDir.y * drift)
            fill(state.coverPolygon,
                 gradient([clear, lit, clear], locations: [0, 0.5, 1]),
                 from: CGPoint(x: center.x - coverDir.x * sheenHalfWidth,
                               y: center.y - coverDir.y * sheenHalfWidth),
                 to: CGPoint(x: center.x + coverDir.x * sheenHalfWidth,
                             y: center.y + coverDir.y * sheenHalfWidth),
                 extend: false)

            // Vignette: gentle darkening toward the cover's OUTER corner (its
            // vertex deepest into the covered side).
            let outer = state.coverPolygon.max {
                dot($0 - mid, coverDir) < dot($1 - mid, coverDir)
            } ?? mid
            if let g = gradient(
                [RGBA(r: 0, g: 0, b: 0, a: vignetteOpacity), RGBA(r: 0, g: 0, b: 0, a: 0)],
                locations: [0, 1]),
                let p = path(state.coverPolygon) {
                ctx.saveGState()
                ctx.addPath(p)
                ctx.clip()
                ctx.drawRadialGradient(
                    g, startCenter: map(outer), startRadius: 0,
                    endCenter: map(outer),
                    endRadius: vignetteRadiusFraction * max(size.width, size.height),
                    options: [.drawsAfterEndLocation])
                ctx.restoreGState()
            }
        }

        // Brand logo — part of the curtain surface: centered on the card,
        // clipped to the cover polygon so it peels away with the curtain.
        if let logo = style.logo, style.logoOpacity > 0.001, style.logoScale > 0.001,
           logo.width > 0, logo.height > 0,
           let coverPath = path(state.coverPolygon) {
            let lw = size.width * style.logoScale
            let lh = lw * CGFloat(logo.height) / CGFloat(logo.width)
            let rect = CGRect(x: (size.width - lw) / 2, y: (size.height - lh) / 2,
                              width: lw, height: lh)
            ctx.saveGState()
            ctx.addPath(coverPath)
            ctx.clip()
            ctx.setAlpha(max(0, min(1, style.logoOpacity)))
            if let tint = style.logoTint, let tc = color(tint) {
                // Tint the alpha silhouette: clip to the logo's alpha, fill.
                ctx.clip(to: rect, mask: logo)
                ctx.setFillColor(tc)
                ctx.fill(rect)
            } else {
                ctx.draw(logo, in: rect)
            }
            ctx.restoreGState()
        }

        // ── Ambient cast shadow on the revealed content — the curtain
        // visibly floats above the video. Fades out with the flap.
        let ambientPoly = ambientShadowPolygon(state: state)
        if ambientPoly.count >= 3, revealDir != .zero, state.shadowStrength > 0.001 {
            let a = ambientShadowMaxOpacity * min(1, state.shadowStrength)
            fill(ambientPoly,
                 gradient([RGBA(r: 0, g: 0, b: 0, a: a), RGBA(r: 0, g: 0, b: 0, a: 0)],
                          locations: [0, 1]),
                 from: mid,
                 to: CGPoint(
                     x: mid.x + revealDir.x * ambientShadowWidthFraction * CGFloat(2).squareRoot(),
                     y: mid.y + revealDir.y * ambientShadowWidthFraction * CGFloat(2).squareRoot()))
        }

        // ── Page-back flap: cool paper gradient + soft sheen, fading through
        // the release as the page leaves the surface.
        if state.flapPolygon.count >= 3, fade > 0.001 {
            let c = centroid(state.flapPolygon)
            let dir = CGPoint(x: c.x - mid.x, y: c.y - mid.y)
            let len = hypot(dir.x, dir.y)
            if len > 0.000001 {
                let n = CGPoint(x: dir.x / len, y: dir.y / len)
                var far: CGFloat = 0.001
                for p in state.flapPolygon {
                    far = max(far, (p.x - mid.x) * n.x + (p.y - mid.y) * n.y)
                }
                fill(state.flapPolygon,
                     gradient([flapColorNear.withAlpha(fade), flapColorFar.withAlpha(fade)],
                              locations: [0, 1]),
                     from: mid, to: CGPoint(x: mid.x + n.x * far, y: mid.y + n.y * far))
                // Sheen across the page back, along the fold direction.
                let foldDirLen = hypot(state.foldEnd.x - state.foldStart.x,
                                       state.foldEnd.y - state.foldStart.y)
                if foldDirLen > 0.000001 {
                    let fdir = CGPoint(x: (state.foldEnd.x - state.foldStart.x) / foldDirLen,
                                       y: (state.foldEnd.y - state.foldStart.y) / foldDirLen)
                    let clear = RGBA(r: 1, g: 1, b: 1, a: 0)
                    let lit = RGBA(r: 1, g: 1, b: 1, a: flapSheenOpacity * fade)
                    fill(state.flapPolygon,
                         gradient([clear, lit, clear], locations: [0, 0.5, 1]),
                         from: CGPoint(x: c.x - fdir.x * 0.25, y: c.y - fdir.y * 0.25),
                         to: CGPoint(x: c.x + fdir.x * 0.25, y: c.y + fdir.y * 0.25),
                         extend: false)
                }
            }
        }

        // ── Crease shadow: black → clear band cast onto the revealed side,
        // width and strength breathing with the peel (whip-boosted).
        let shadowPoly = shadowPolygon(state: state)
        if shadowPoly.count >= 3, revealDir != .zero, state.shadowStrength > 0.001 {
            let alpha = foldShadowMaxOpacity * state.shadowStrength
            fill(shadowPoly,
                 gradient([RGBA(r: 0, g: 0, b: 0, a: alpha), RGBA(r: 0, g: 0, b: 0, a: 0)],
                          locations: [0, 1]),
                 from: mid, to: CGPoint(x: mid.x + revealDir.x * state.shadowWidth,
                                        y: mid.y + revealDir.y * state.shadowWidth))
        }

        // ── Fold specular: paper catching light at the crease — a narrow
        // bright strip along the fold on the FLAP side, breathing with the
        // shadow curves and leaving with the flap.
        if state.flapPolygon.count >= 3, coverDir != .zero, fade > 0.001,
           state.shadowStrength > 0.001 {
            let w = state.shadowWidth * foldSpecularWidthFactor
            let alpha = foldSpecularOpacity * min(1, state.shadowStrength) * fade
            if let p = path(state.flapPolygon),
               let g = gradient(
                   [RGBA(r: 1, g: 1, b: 1, a: alpha), RGBA(r: 1, g: 1, b: 1, a: 0)],
                   locations: [0, 1]) {
                ctx.saveGState()
                ctx.addPath(p)
                ctx.clip()
                ctx.drawLinearGradient(
                    g, start: map(mid),
                    end: map(CGPoint(x: mid.x + coverDir.x * w, y: mid.y + coverDir.y * w)),
                    options: [.drawsAfterEndLocation])
                ctx.restoreGState()
            }
        }
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
