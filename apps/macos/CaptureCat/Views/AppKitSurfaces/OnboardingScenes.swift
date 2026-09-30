import AppKit
import QuartzCore

// The five onboarding stage scenes. Each is a pure CALayer composition
// (stage coords, Y-up) with frame-locked loops — see OnboardingStage.swift
// for the architecture and the drawing vocabulary (`Stage`).

// MARK: - Caption chip

/// A raised kit pill (the house key material) carrying an SF Symbol + a
/// short caption. Used for the welcome captions and the finish orbit.
@MainActor
final class StageChip {
    let layer = CALayer()
    private let glyph: CALayer
    private let symbolName: String
    private let label: CATextLayer
    static let height: CGFloat = 30

    init(symbol: String, text: String) {
        symbolName = symbol
        glyph = Stage.symbol(symbol, size: 12, color: .white)
        label = Stage.text(text, size: 12, weight: .semibold)
        layer.cornerCurve = .continuous
        layer.addSublayer(glyph)
        layer.addSublayer(label)
    }

    var width: CGFloat { 14 + glyph.bounds.width + 7 + label.bounds.width + 14 }

    /// Centre the chip on `center` (stage coords).
    func place(center: CGPoint) {
        let size = CGSize(width: width, height: Self.height)
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = center
        // A raw layer's own fill + shadow must follow the pill shape, or the
        // material sits in a hard rectangular box.
        layer.cornerRadius = size.height / 2
        glyph.position = CGPoint(x: 14 + glyph.bounds.width / 2, y: size.height / 2)
        label.position = CGPoint(x: 14 + glyph.bounds.width + 7 + label.bounds.width / 2,
                                 y: size.height / 2 - 0.5)
        CCMaterial.refit(layer, radius: size.height / 2)
    }

    func applyTheme() {
        let colors = CCTheme.color
        label.foregroundColor = colors.foreground.cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colors.primary]))
        glyph.contents = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        layer.backgroundColor = colors.elevated.cgColor
        CCMaterial.dress(layer, as: .raised(tint: colors.elevated), radius: Self.height / 2)
    }
}

// MARK: - Welcome: the auto-zoom demo

/// A mock app window on the wallpaper. The cursor glides to "Publish",
/// clicks (ripple), and the CAMERA pushes in on the click — wallpaper and
/// all, like an exported frame — then pans with the cursor to a card,
/// clicks again, and eases back out. Captions narrate each beat. One
/// period, one begin time: everything stays frame-locked and loops clean.
@MainActor
final class WelcomeScene: OnboardingScene {
    static let period: Double = 7.4
    static let zoomDepth: CGFloat = 1.85

    let window = MockAppWindow()
    let cursor = Stage.cursor(height: 21)
    private let rippleA = Stage.ripple()
    private let rippleB = Stage.ripple()
    private let chips = [
        StageChip(symbol: "sparkles", text: "Record once. Look polished."),
        StageChip(symbol: "plus.magnifyingglass", text: "Auto-zoom on every click"),
        StageChip(symbol: "scope", text: "The camera follows your cursor"),
        StageChip(symbol: "wand.and.stars", text: "Eases back out, zero editing"),
    ]
    private var rest = CGPoint.zero
    private var clickA = CGPoint.zero
    private var clickB = CGPoint.zero
    private var stageSize = CGSize.zero

    override init() {
        super.init()
        layer.addSublayer(window.layer)
        layer.addSublayer(rippleA)
        layer.addSublayer(rippleB)
        layer.addSublayer(cursor)
        for chip in chips {
            chip.layer.opacity = 0
            overlay.addSublayer(chip.layer)
        }
    }

    override func layoutContent(in b: CGRect) {
        stageSize = b.size
        let ww = min(b.width * 0.8, 460)
        let wh = ww * 0.64
        let frame = CGRect(x: (b.width - ww) / 2, y: b.height * 0.54 - wh / 2, width: ww, height: wh)
        window.layout(frame: frame)
        clickA = window.stagePoint(of: window.button)
        clickB = window.stagePoint(of: window.cards[2])
        rest = CGPoint(x: frame.minX + ww * 0.8, y: frame.minY + wh * 0.2)
        cursor.position = rest
        rippleA.position = clickA
        rippleB.position = clickB
        let chipY = max(34, frame.minY * 0.5)
        for chip in chips { chip.place(center: CGPoint(x: b.midX, y: chipY)) }
    }

    override func applyTheme() {
        window.applyTheme()
        for chip in chips { chip.applyTheme() }
        let primary = CCTheme.color.primary
        for ripple in [rippleA, rippleB] {
            ripple.strokeColor = primary.blended(withFraction: 0.35, of: .white)?.cgColor
            ripple.fillColor = primary.withAlphaComponent(0.18).cgColor
        }
    }

    override func enter(animated: Bool) {
        guard animated, !RecordingMotion.reduceMotion else { return }
        Stage.oneShot(window.layer, "position.y", from: -22, to: 0, duration: 0.7,
                      delay: 0.05, curve: CCMotion.settle, additive: true)
        Stage.oneShot(cursor, "opacity", from: 0, to: 1, duration: 0.3, delay: 0.3)
    }

    /// The camera transform that frames `p` at depth `s` — the focus point
    /// pulled toward centre (CaptureCat's framing), translation clamped so
    /// the zoomed wallpaper always covers the stage.
    private func cameraTransform(_ s: CGFloat, focus p: CGPoint) -> CATransform3D {
        let c = CGPoint(x: stageSize.width / 2, y: stageSize.height / 2)
        let pull: CGFloat = 0.35
        let limitX = stageSize.width / 2 * (s - 1)
        let limitY = stageSize.height / 2 * (s - 1)
        let tx = min(limitX, max(-limitX, (p.x - c.x) * (pull - s)))
        let ty = min(limitY, max(-limitY, (p.y - c.y) * (pull - s)))
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                   CATransform3DMakeTranslation(tx, ty, 0))
    }

    override func startLoops(t0: CFTimeInterval, camera: CALayer) {
        let T = Self.period
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let linear = CAMediaTimingFunction(name: .linear)

        // Cursor: curved glides with holds (path vertices = keyframes).
        let path = CGMutablePath()
        func arc(to end: CGPoint, from start: CGPoint, bow: CGFloat) {
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let normal = CGPoint(x: -(end.y - start.y), y: end.x - start.x)
            let control = CGPoint(x: mid.x + normal.x * bow, y: mid.y + normal.y * bow)
            path.addQuadCurve(to: end, control: control)
        }
        path.move(to: rest)
        path.addLine(to: rest)
        arc(to: clickA, from: rest, bow: 0.22)
        path.addLine(to: clickA)
        arc(to: clickB, from: clickA, bow: -0.18)
        path.addLine(to: clickB)
        arc(to: rest, from: clickB, bow: 0.2)
        path.addLine(to: rest)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.keyTimes = [0, 0.35, 1.45, 2.9, 3.55, 4.95, 6.6, T].map { NSNumber(value: $0 / T) }
        move.timingFunctions = [linear, ease, linear, ease, linear, ease, linear]
        move.duration = T
        move.repeatCount = .infinity
        move.beginTime = t0
        move.fillMode = .both
        move.isRemovedOnCompletion = false
        addLoop(move, to: cursor, key: "welcome.cursor")

        // Click dips on the cursor itself.
        addLoop(Stage.track("transform.scale", [
            (1.47, 1.0), (1.53, 0.84), (1.68, 1.0),
            (3.57, 1.0), (3.63, 0.84), (3.78, 1.0),
        ], period: T, t0: t0), to: cursor, key: "welcome.cursorDip")

        // Ripples.
        for (ripple, at, key) in [(rippleA, 1.52, "a"), (rippleB, 3.62, "b")] {
            addLoop(Stage.track("opacity", [(at - 0.01, 0.0), (at + 0.04, 0.95), (at + 0.7, 0.0)],
                                period: T, t0: t0), to: ripple, key: "welcome.ripple.\(key).o")
            addLoop(Stage.track("transform.scale", [(at - 0.01, 0.35), (at + 0.7, 1.9)],
                                period: T, curve: CCMotion.settle, t0: t0),
                    to: ripple, key: "welcome.ripple.\(key).s")
        }

        // The button acknowledges its click; the card lights up on its own.
        let primary = CCTheme.color.primary
        let pressed = primary.blended(withFraction: 0.22, of: .black) ?? primary
        addLoop(Stage.track("backgroundColor", [
            (1.5, primary.cgColor), (1.56, pressed.cgColor), (1.8, primary.cgColor),
        ], period: T, t0: t0), to: window.button, key: "welcome.button")
        addLoop(Stage.track("opacity", [(3.6, 0.0), (3.72, 1.0), (5.2, 1.0), (5.6, 0.0)],
                            period: T, t0: t0), to: window.cardHighlight, key: "welcome.card")

        // THE CAMERA: push in on the click, pan with the cursor, ease out.
        let rest3D = CATransform3DIdentity
        let onA = cameraTransform(Self.zoomDepth, focus: clickA)
        let onB = cameraTransform(Self.zoomDepth, focus: clickB)
        func v(_ t: CATransform3D) -> NSValue { NSValue(caTransform3D: t) }
        addLoop(Stage.track("transform", [
            (1.58, v(rest3D)), (2.5, v(onA)), (2.95, v(onA)), (3.62, v(onB)),
            (4.95, v(onB)), (6.0, v(rest3D)),
        ], period: T, curves: [
            CCMotion.settle, linear, CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1),
            linear, CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1),
        ], t0: t0), to: camera, key: "welcome.camera")

        // Captions narrate each beat, rising 5pt into place.
        let windows: [[(Double, Double)]] = [
            [(0, 1.4), (6.55, T + 1)], [(1.55, 2.9)], [(3.0, 4.85)], [(4.95, 6.45)],
        ]
        for (chip, spans) in zip(chips, windows) {
            var opacity: [(Double, Any)] = []
            var rise: [(Double, Any)] = []
            for (a, b) in spans {
                if a <= 0 {
                    opacity += [(0, 1.0)]
                    rise += [(0, 0.0)]
                } else {
                    opacity += [(a, 0.0), (a + 0.22, 1.0)]
                    rise += [(a, -5.0), (a + 0.3, 0.0)]
                }
                if b < T {
                    opacity += [(b - 0.12, 1.0), (b + 0.08, 0.0)]
                    rise += [(b + 0.08, 0.0)]
                }
            }
            addLoop(Stage.track("opacity", opacity, period: T, t0: t0), to: chip.layer, key: "welcome.chip.o")
            let riseTrack = Stage.track("position.y", rise, period: T, curve: CCMotion.settle, t0: t0)
            riseTrack.isAdditive = true
            addLoop(riseTrack, to: chip.layer, key: "welcome.chip.y")
        }
    }

    override func showStaticFrame() {
        cursor.position = clickA
        chips.first?.layer.opacity = 1
    }

    // MARK: Harness seams
    var probeClickA: CGPoint { clickA }
    var probeChips: [CALayer] { chips.map(\.layer) }
}

// MARK: - Permissions: the live mirror

/// A System-Settings-style privacy card whose switches mirror the REAL
/// grant state. Grant something in the wizard and its switch springs over,
/// the row flashes, the icon pops. The pending required row wears a
/// breathing halo; a REC tag bobs on the card's shoulder.
@MainActor
final class PermissionsScene: OnboardingScene {
    private struct Row {
        let container = CALayer()
        let tile = CALayer()
        let glyph: CALayer
        let title: CATextLayer
        let detail: CATextLayer
        let track = CALayer()
        let knob = CALayer()
        let flash = CALayer()
        let divider = CALayer()
        let tileColor: NSColor
    }

    private let card = CALayer()
    private let cardBody = CALayer()
    private let headerTile = CALayer()
    private let headerGlyph = Stage.symbol("hand.raised.fill", size: 13, color: .white)
    private let headerTitle = Stage.text("Privacy & Security", size: 13, weight: .semibold)
    private let headerDetail = Stage.text("CaptureCat", size: 10.5, weight: .regular)
    private var rows: [Row] = []
    private let halo = CALayer()
    private let recTag = CALayer()
    private let recDot = CALayer()
    private let recLabel = Stage.text("REC", size: 10.5, weight: .bold)
    private var state: [Bool] = [false, false, false, false]

    private static let rowSpecs: [(String, String, String, NSColor)] = [
        ("Screen Recording", "Required", "rectangle.inset.filled.badge.record", .systemIndigo),
        ("Notifications", "Reminders", "bell.badge.fill", .systemRed),
        ("Microphone", "Narration", "mic.fill", .systemOrange),
        ("Camera", "Webcam bubble", "video.fill", .systemGreen),
    ]

    override init() {
        super.init()
        card.addSublayer(cardBody)
        cardBody.masksToBounds = true
        cardBody.cornerCurve = .continuous
        cardBody.addSublayer(headerTile)
        headerTile.addSublayer(headerGlyph)
        cardBody.addSublayer(headerTitle)
        cardBody.addSublayer(headerDetail)
        for spec in Self.rowSpecs {
            let row = Row(
                glyph: Stage.symbol(spec.2, size: 12, color: .white),
                title: Stage.text(spec.0, size: 12.5, weight: .medium),
                detail: Stage.text(spec.1, size: 10.5, weight: .regular),
                tileColor: spec.3)
            row.container.addSublayer(row.flash)
            row.container.addSublayer(row.tile)
            row.tile.addSublayer(row.glyph)
            row.container.addSublayer(row.title)
            row.container.addSublayer(row.detail)
            row.container.addSublayer(row.track)
            row.track.addSublayer(row.knob)
            row.container.addSublayer(row.divider)
            row.flash.opacity = 0
            cardBody.addSublayer(row.container)
            rows.append(row)
        }
        layer.addSublayer(card)
        halo.borderWidth = 2
        halo.opacity = 0
        layer.addSublayer(halo)
        recTag.addSublayer(recDot)
        recTag.addSublayer(recLabel)
        layer.addSublayer(recTag)
    }

    private var trackSize: CGSize { CGSize(width: 36, height: 21) }

    override func layoutContent(in b: CGRect) {
        let cw = min(b.width * 0.76, 350)
        let headerH: CGFloat = 56, rowH: CGFloat = 50
        let ch = headerH + rowH * CGFloat(rows.count) + 8
        let frame = CGRect(x: (b.width - cw) / 2, y: b.height * 0.5 - ch / 2, width: cw, height: ch)
        Stage.setFrame(card, frame)
        cardBody.frame = CGRect(origin: .zero, size: frame.size)
        cardBody.cornerRadius = 16
        Stage.castShadow(card, radius: 16, blur: 26, opacity: 0.5, dy: -14)

        headerTile.frame = CGRect(x: 16, y: ch - headerH / 2 - 15, width: 30, height: 30)
        headerTile.cornerRadius = 8
        headerTile.cornerCurve = .continuous
        headerGlyph.position = CGPoint(x: 15, y: 15)
        headerTitle.position = CGPoint(x: 56 + headerTitle.bounds.width / 2, y: ch - headerH / 2 + 7)
        headerDetail.position = CGPoint(x: 56 + headerDetail.bounds.width / 2, y: ch - headerH / 2 - 9)

        for (i, row) in rows.enumerated() {
            let y = ch - headerH - rowH * CGFloat(i + 1)
            row.container.frame = CGRect(x: 0, y: y, width: cw, height: rowH)
            row.flash.frame = row.container.bounds
            row.tile.frame = CGRect(x: 16, y: rowH / 2 - 13, width: 26, height: 26)
            row.tile.cornerRadius = 7
            row.tile.cornerCurve = .continuous
            row.glyph.position = CGPoint(x: 13, y: 13)
            row.title.position = CGPoint(x: 54 + row.title.bounds.width / 2, y: rowH / 2 + 7)
            row.detail.position = CGPoint(x: 54 + row.detail.bounds.width / 2, y: rowH / 2 - 9)
            row.track.frame = CGRect(x: cw - 16 - trackSize.width, y: rowH / 2 - trackSize.height / 2,
                                     width: trackSize.width, height: trackSize.height)
            row.track.cornerRadius = trackSize.height / 2
            row.knob.bounds = CGRect(x: 0, y: 0, width: trackSize.height - 4, height: trackSize.height - 4)
            row.knob.cornerRadius = (trackSize.height - 4) / 2
            row.knob.position = knobCenter(on: state[i])
            row.divider.frame = CGRect(x: 54, y: rowH - 0.5, width: cw - 54, height: 0.5)
        }
        let screenTrack = rows[0].track
        let trackInStage = CGRect(x: frame.minX + screenTrack.frame.minX,
                                  y: frame.minY + rows[0].container.frame.minY + screenTrack.frame.minY,
                                  width: trackSize.width, height: trackSize.height)
        halo.frame = trackInStage.insetBy(dx: -3, dy: -3)
        halo.cornerRadius = halo.frame.height / 2

        let tagW = 20 + recLabel.bounds.width + 12
        recTag.bounds = CGRect(x: 0, y: 0, width: tagW, height: 26)
        recTag.cornerRadius = 13
        recTag.cornerCurve = .continuous
        recTag.position = CGPoint(x: frame.maxX - tagW / 2 - 6, y: frame.maxY + 4)
        recDot.frame = CGRect(x: 10, y: 9, width: 8, height: 8)
        recDot.cornerRadius = 4
        recLabel.position = CGPoint(x: 22 + recLabel.bounds.width / 2, y: 12.5)
        CCMaterial.refit(recTag, radius: 13)
    }

    private func knobCenter(on: Bool) -> CGPoint {
        let side = trackSize.height - 4
        return CGPoint(x: on ? trackSize.width - 2 - side / 2 : 2 + side / 2, y: trackSize.height / 2)
    }

    override func applyTheme() {
        let colors = CCTheme.color
        let dark = CCTheme.isDark
        let ink: NSColor = dark ? .white : .black
        cardBody.backgroundColor = colors.card.cgColor
        cardBody.borderWidth = 0.5
        cardBody.borderColor = ink.withAlphaComponent(dark ? 0.1 : 0.12).cgColor
        headerTile.backgroundColor = NSColor.systemBlue.cgColor
        headerTitle.foregroundColor = colors.foreground.cgColor
        headerDetail.foregroundColor = colors.mutedForeground.cgColor
        for (i, row) in rows.enumerated() {
            row.tile.backgroundColor = row.tileColor.cgColor
            row.title.foregroundColor = colors.foreground.cgColor
            row.detail.foregroundColor = colors.mutedForeground.cgColor
            row.divider.backgroundColor = ink.withAlphaComponent(0.08).cgColor
            row.flash.backgroundColor = colors.primary.withAlphaComponent(0.16).cgColor
            row.knob.backgroundColor = NSColor.white.cgColor
            row.knob.shadowColor = NSColor.black.cgColor
            row.knob.shadowOpacity = 0.3
            row.knob.shadowRadius = 1.5
            row.knob.shadowOffset = CGSize(width: 0, height: -0.5)
            row.track.backgroundColor = trackColor(on: state[i]).cgColor
        }
        halo.borderColor = colors.primary.cgColor
        recTag.backgroundColor = colors.elevated.cgColor
        CCMaterial.dress(recTag, as: .raised(tint: colors.elevated), radius: 13)
        recDot.backgroundColor = NSColor.systemRed.cgColor
        recLabel.foregroundColor = colors.foreground.cgColor
    }

    private func trackColor(on: Bool) -> NSColor {
        on ? CCTheme.color.primary : (CCTheme.isDark ? NSColor.white : .black).withAlphaComponent(0.16)
    }

    func update(_ permissions: OnboardingStageView.Permissions, animated: Bool) {
        let next = [permissions.screen, permissions.notifications, permissions.microphone, permissions.camera]
        for (i, row) in rows.enumerated() where next[i] != state[i] {
            let on = next[i]
            if animated && !RecordingMotion.reduceMotion {
                CCMotion.spring(row.knob, keyPath: "position", to: NSValue(point: knobCenter(on: on)), .bouncy)
                CCMotion.fade(row.track, keyPath: "backgroundColor", to: trackColor(on: on).cgColor, duration: 0.25)
                if on {
                    let flash = CAKeyframeAnimation(keyPath: "opacity")
                    flash.values = [0, 1, 0]
                    flash.keyTimes = [0, 0.2, 1]
                    flash.duration = 0.8
                    row.flash.add(flash, forKey: "flash")
                    let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                    pop.values = [1, 1.2, 0.96, 1]
                    pop.keyTimes = [0, 0.35, 0.7, 1]
                    pop.duration = 0.45
                    pop.timingFunction = CCMotion.settle
                    row.tile.add(pop, forKey: "pop")
                }
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                row.knob.position = knobCenter(on: on)
                row.track.backgroundColor = trackColor(on: on).cgColor
                CATransaction.commit()
            }
        }
        state = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.isHidden = state[0]
        CATransaction.commit()
    }

    override func enter(animated: Bool) {
        guard animated, !RecordingMotion.reduceMotion else { return }
        Stage.spring(card, "transform.scale", from: 0.93, to: 1.0, .smooth, delay: 0.02)
        for (i, row) in rows.enumerated() {
            let delay = 0.14 + Double(i) * 0.07
            Stage.oneShot(row.container, "position.x", from: 18, to: 0, duration: 0.55,
                          delay: delay, additive: true)
            Stage.oneShot(row.container, "opacity", from: 0, to: 1, duration: 0.35, delay: delay)
        }
        Stage.spring(recTag, "transform.scale", from: 0.4, to: 1.0, .bouncy, delay: 0.45)
    }

    override func startLoops(t0: CFTimeInterval, camera: CALayer) {
        addLoop(Stage.bob(amount: 4, period: 6, t0: t0), to: card, key: "perm.float")
        addLoop(Stage.bob(amount: 3, period: 4.4, phase: 0.3, t0: t0), to: recTag, key: "perm.tagFloat")
        addLoop(Stage.bob(amount: 4, period: 6, t0: t0), to: halo, key: "perm.haloFloat")
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.25
        blink.duration = 0.7
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.beginTime = t0
        addLoop(blink, to: recDot, key: "perm.recBlink")
        // The pending required row breathes a halo (hidden once granted).
        addLoop(Stage.track("opacity", [(0, 0.0), (0.2, 0.85), (1.3, 0.0)], period: 1.8, t0: t0),
                to: halo, key: "perm.halo.o")
        addLoop(Stage.track("transform.scale", [(0, 1.0), (1.3, 1.28)], period: 1.8,
                            curve: CCMotion.settle, t0: t0), to: halo, key: "perm.halo.s")
    }

    // MARK: Harness seams
    func probeKnob(_ index: Int) -> CALayer { rows[index].knob }
    var probeCardBody: CALayer { cardBody }
}

// MARK: - Account: cloud + share

/// Three recordings fanned like cards, an avatar badge that turns into YOUR
/// initial once signed in, and a share pill looping "uploading → link copied".
@MainActor
final class AccountScene: OnboardingScene {
    private final class Thumb {
        let layer = CALayer()
        let body = CALayer()
        let gradient = CAGradientLayer()
        let mini = CALayer()
        let lines: [CALayer] = (0..<3).map { _ in CALayer() }
        let badge = CALayer()
        let badgeText = Stage.text("0:42", size: 9.5, weight: .semibold, monospacedDigits: true)
        let play = CALayer()
        let playGlyph = Stage.symbol("play.fill", size: 14, color: .black)

        init(colors: [NSColor], showsPlay: Bool, duration: String) {
            badgeText.string = duration
            layer.addSublayer(body)
            body.masksToBounds = true
            body.cornerCurve = .continuous
            body.addSublayer(gradient)
            gradient.colors = colors.map(\.cgColor)
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            body.addSublayer(mini)
            for line in lines { mini.addSublayer(line) }
            body.addSublayer(badge)
            badge.addSublayer(badgeText)
            badge.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            if showsPlay {
                body.addSublayer(play)
                play.addSublayer(playGlyph)
                play.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            }
        }

        func layout(size: CGSize) {
            layer.bounds = CGRect(origin: .zero, size: size)
            body.frame = layer.bounds
            body.cornerRadius = 12
            gradient.frame = layer.bounds
            Stage.castShadow(layer, radius: 12, blur: 18, opacity: 0.45, dy: -10)
            let mw = size.width * 0.66, mh = size.height * 0.58
            mini.frame = CGRect(x: (size.width - mw) / 2, y: (size.height - mh) / 2 - 2, width: mw, height: mh)
            mini.cornerRadius = 6
            mini.cornerCurve = .continuous
            for (i, line) in lines.enumerated() {
                let w = mw * [0.5, 0.72, 0.38][i]
                line.frame = CGRect(x: mw * 0.1, y: mh * (0.7 - CGFloat(i) * 0.2), width: w, height: 4)
                line.cornerRadius = 2
            }
            badge.frame = CGRect(x: size.width - 38, y: 8, width: 30, height: 16)
            badge.cornerRadius = 8
            badgeText.position = CGPoint(x: 15, y: 8)
            play.bounds = CGRect(x: 0, y: 0, width: 38, height: 38)
            play.position = CGPoint(x: size.width / 2, y: size.height / 2 - 2)
            play.cornerRadius = 19
            playGlyph.position = CGPoint(x: 20.5, y: 19)
            badgeText.foregroundColor = NSColor.white.cgColor
        }

        func applyTheme() {
            mini.backgroundColor = CCTheme.color.card.withAlphaComponent(0.92).cgColor
            let ink: NSColor = CCTheme.isDark ? .white : .black
            for line in lines { line.backgroundColor = ink.withAlphaComponent(0.2).cgColor }
        }
    }

    private let thumbs = [
        Thumb(colors: [.systemTeal, .systemBlue], showsPlay: false, duration: "1:08"),
        Thumb(colors: [.systemOrange, .systemPink], showsPlay: false, duration: "0:27"),
        Thumb(colors: [.systemPurple, .systemIndigo], showsPlay: true, duration: "0:42"),
    ]
    private let avatar = CALayer()
    private let avatarInitial = Stage.text("", size: 15, weight: .bold, alignment: .center)
    private let avatarGlyph = Stage.symbol("person.fill", size: 14, color: .white)
    private let check = CALayer()
    private let checkGlyph = Stage.symbol("checkmark", size: 8, weight: .heavy, color: .white)
    private let pill = CALayer()
    private let linkGlyph = Stage.symbol("link", size: 12, color: .white)
    private let linkText = Stage.text("capturecat.so/s/7fK2p", size: 12, weight: .medium)
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private let copied = CALayer()
    /// Two-tone: a single palette colour paints the check AND the disc the
    /// same green, leaving a flat blob — white check on a green disc.
    private let copiedGlyph: CALayer = {
        let layer = CALayer()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        if let image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            layer.contents = image
            layer.bounds = CGRect(origin: .zero, size: image.size)
        }
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = 4
        return layer
    }()
    private let copiedText = Stage.text("Copied", size: 11.5, weight: .semibold)
    private var email: String?
    private var fan: [(offset: CGPoint, angle: CGFloat, scale: CGFloat)] = []
    private var frontCenter = CGPoint.zero

    override init() {
        super.init()
        for thumb in thumbs { layer.addSublayer(thumb.layer) }
        layer.addSublayer(avatar)
        avatar.addSublayer(avatarInitial)
        avatar.addSublayer(avatarGlyph)
        layer.addSublayer(check)
        check.addSublayer(checkGlyph)
        layer.addSublayer(pill)
        pill.addSublayer(linkGlyph)
        pill.addSublayer(linkText)
        pill.addSublayer(progressTrack)
        progressTrack.addSublayer(progressFill)
        pill.addSublayer(copied)
        copied.addSublayer(copiedGlyph)
        copied.addSublayer(copiedText)
        copied.opacity = 0
        progressFill.anchorPoint = CGPoint(x: 0, y: 0.5)
    }

    override func layoutContent(in b: CGRect) {
        let cw = min(b.width * 0.56, 260), ch = cw * 0.62
        frontCenter = CGPoint(x: b.midX, y: b.height * 0.58)
        fan = [
            (CGPoint(x: -cw * 0.2, y: ch * 0.12), -0.15, 0.9),
            (CGPoint(x: cw * 0.2, y: ch * 0.1), 0.12, 0.92),
            (.zero, 0, 1),
        ]
        for (thumb, pose) in zip(thumbs, fan) {
            thumb.layout(size: CGSize(width: cw, height: ch))
            thumb.layer.position = CGPoint(x: frontCenter.x + pose.offset.x, y: frontCenter.y + pose.offset.y)
            thumb.layer.transform = CATransform3DConcat(
                CATransform3DMakeScale(pose.scale, pose.scale, 1),
                CATransform3DMakeRotation(pose.angle, 0, 0, 1))
        }
        let front = CGRect(x: frontCenter.x - cw / 2, y: frontCenter.y - ch / 2, width: cw, height: ch)
        avatar.bounds = CGRect(x: 0, y: 0, width: 38, height: 38)
        avatar.position = CGPoint(x: front.maxX - 10, y: front.maxY - 8)
        avatar.cornerRadius = 19
        avatar.borderWidth = 2.5
        avatarInitial.bounds = CGRect(x: 0, y: 0, width: 38, height: 20)
        avatarInitial.position = CGPoint(x: 19, y: 18)
        avatarGlyph.position = CGPoint(x: 19, y: 19)
        check.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        check.position = CGPoint(x: avatar.position.x + 13, y: avatar.position.y - 13)
        check.cornerRadius = 8
        check.borderWidth = 2
        checkGlyph.position = CGPoint(x: 8, y: 8)

        let pw = min(b.width * 0.7, 300), ph: CGFloat = 40
        pill.bounds = CGRect(x: 0, y: 0, width: pw, height: ph)
        pill.cornerRadius = ph / 2
        pill.cornerCurve = .continuous
        pill.position = CGPoint(x: b.midX, y: front.minY - 50)
        linkGlyph.position = CGPoint(x: 18, y: ph / 2)
        linkText.position = CGPoint(x: 32 + linkText.bounds.width / 2, y: ph / 2 - 0.5)
        progressTrack.frame = CGRect(x: pw - 16 - 46, y: ph / 2 - 2.5, width: 46, height: 5)
        progressTrack.cornerRadius = 2.5
        progressFill.bounds = CGRect(x: 0, y: 0, width: 46, height: 5)
        progressFill.position = CGPoint(x: 0, y: 2.5)
        progressFill.cornerRadius = 2.5
        let copiedW = copiedGlyph.bounds.width + 5 + copiedText.bounds.width
        copied.frame = CGRect(x: pw - 16 - copiedW, y: 0, width: copiedW, height: ph)
        copiedGlyph.position = CGPoint(x: copiedGlyph.bounds.width / 2, y: ph / 2)
        copiedText.position = CGPoint(x: copiedGlyph.bounds.width + 5 + copiedText.bounds.width / 2,
                                      y: ph / 2 - 0.5)
        CCMaterial.refit(pill, radius: ph / 2)
    }

    override func applyTheme() {
        let colors = CCTheme.color
        for thumb in thumbs { thumb.applyTheme() }
        avatar.backgroundColor = colors.primary.cgColor
        avatar.borderColor = NSColor.white.cgColor
        avatarInitial.foregroundColor = NSColor.white.cgColor
        check.backgroundColor = NSColor.systemGreen.cgColor
        check.borderColor = NSColor.white.cgColor
        pill.backgroundColor = colors.elevated.cgColor
        CCMaterial.dress(pill, as: .raised(tint: colors.elevated), radius: 20)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colors.primary]))
        linkGlyph.contents = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        linkText.foregroundColor = colors.foreground.cgColor
        copiedText.foregroundColor = colors.foreground.cgColor
        progressTrack.backgroundColor = (CCTheme.isDark ? NSColor.white : .black).withAlphaComponent(0.12).cgColor
        progressFill.backgroundColor = colors.primary.cgColor
        update(email: email, animated: false)
    }

    func update(email: String?, animated: Bool) {
        self.email = email
        let signedIn = email != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatarInitial.string = email?.first.map { String($0).uppercased() } ?? ""
        avatarInitial.isHidden = !signedIn
        avatarGlyph.isHidden = signedIn
        check.isHidden = !signedIn
        CATransaction.commit()
        if animated, signedIn, !RecordingMotion.reduceMotion {
            Stage.spring(avatar, "transform.scale", from: 0.6, to: 1.0, .bouncy)
            Stage.spring(check, "transform.scale", from: 0.2, to: 1.0, .bouncy, delay: 0.12)
        }
    }

    override func enter(animated: Bool) {
        guard animated, !RecordingMotion.reduceMotion else { return }
        // The back cards fan out from behind the front one.
        for (thumb, pose) in zip(thumbs.prefix(2), fan.prefix(2)) {
            Stage.spring(thumb.layer, "position",
                         from: NSValue(point: frontCenter),
                         to: NSValue(point: CGPoint(x: frontCenter.x + pose.offset.x,
                                                    y: frontCenter.y + pose.offset.y)),
                         .bouncy, delay: 0.12)
            Stage.spring(thumb.layer, "transform.rotation.z", from: 0, to: pose.angle, .bouncy, delay: 0.12)
        }
        Stage.spring(avatar, "transform.scale", from: 0.3, to: 1.0, .bouncy, delay: 0.35)
        Stage.oneShot(pill, "position.y", from: -16, to: 0, duration: 0.6, delay: 0.25, additive: true)
        Stage.oneShot(pill, "opacity", from: 0, to: 1, duration: 0.35, delay: 0.25)
    }

    override func startLoops(t0: CFTimeInterval, camera: CALayer) {
        for (i, thumb) in thumbs.enumerated() {
            addLoop(Stage.bob(amount: 3.5, period: [5.3, 6.1, 4.6][i], phase: [0.2, 0.6, 0][i], t0: t0),
                    to: thumb.layer, key: "account.bob")
        }
        addLoop(Stage.bob(amount: 3.5, period: 4.6, t0: t0), to: avatar, key: "account.avatarBob")
        addLoop(Stage.bob(amount: 3.5, period: 4.6, t0: t0), to: check, key: "account.checkBob")
        let T = 5.0
        addLoop(Stage.track("transform.scale.x", [(0.2, 0.0), (1.6, 1.0), (4.5, 1.0), (4.55, 0.0)],
                            period: T, t0: t0), to: progressFill, key: "account.progress")
        addLoop(Stage.track("opacity", [(1.65, 1.0), (1.85, 0.0), (4.55, 0.0), (4.75, 1.0)],
                            period: T, t0: t0), to: progressTrack, key: "account.track")
        addLoop(Stage.track("opacity", [(1.85, 0.0), (2.05, 1.0), (4.25, 1.0), (4.5, 0.0)],
                            period: T, t0: t0), to: copied, key: "account.copied.o")
        addLoop(Stage.track("transform.scale", [(1.85, 0.8), (2.1, 1.08), (2.3, 1.0)],
                            period: T, t0: t0), to: copied, key: "account.copied.s")
    }

    override func showStaticFrame() {
        copied.opacity = 1
        progressTrack.opacity = 0
    }
}

// MARK: - Shortcut: ⇧⌘4 the CaptureCat way

/// Three big keycaps press in sequence (⇧ ⌘ 4 — tinted in place, glowing),
/// a crosshair drags a selection over the mock window, the shutter flashes,
/// and the capture flies into a floating thumbnail with the house bounce.
@MainActor
final class ShortcutScene: OnboardingScene {
    private struct Key {
        let glow = CALayer()
        let cap = CALayer()
        let shade = CALayer()
        let glyph: CATextLayer
        let width: CGFloat
    }

    let window = MockAppWindow()
    private var keys: [Key] = []
    private let marquee = CAShapeLayer()
    private let crosshair = CAShapeLayer()
    private let flash = CALayer()
    private let thumb = CALayer()
    private let thumbBody = CALayer()
    private let thumbGradient = CAGradientLayer()
    private let thumbMini = CALayer()
    private var selection = CGRect.zero
    private var thumbTarget = CGPoint.zero
    private var thumbScale: CGFloat = 1
    private static let keyHeight: CGFloat = 58

    override init() {
        super.init()
        layer.addSublayer(window.layer)
        for (glyph, width) in [("⇧", CGFloat(76)), ("⌘", CGFloat(58)), ("4", CGFloat(58))] {
            let key = Key(glyph: Stage.text(glyph, size: 24, weight: .medium, alignment: .center), width: width)
            key.cap.addSublayer(key.shade)
            key.cap.addSublayer(key.glyph)
            key.shade.opacity = 0
            // The accent glow rides its own layer under the cap: the key's
            // material re-asserts a black cast shadow on every refit.
            key.glow.shadowOpacity = 0
            key.glow.shadowOffset = .zero
            layer.addSublayer(key.glow)
            layer.addSublayer(key.cap)
            keys.append(key)
        }
        marquee.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
        marquee.strokeColor = NSColor.white.cgColor
        marquee.lineWidth = 1.5
        marquee.lineDashPattern = [5, 3]
        marquee.opacity = 0
        marquee.contentsScale = 4
        layer.addSublayer(marquee)
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: 0, y: 9)); cross.addLine(to: CGPoint(x: 7, y: 9))
        cross.move(to: CGPoint(x: 11, y: 9)); cross.addLine(to: CGPoint(x: 18, y: 9))
        cross.move(to: CGPoint(x: 9, y: 0)); cross.addLine(to: CGPoint(x: 9, y: 7))
        cross.move(to: CGPoint(x: 9, y: 11)); cross.addLine(to: CGPoint(x: 9, y: 18))
        crosshair.path = cross
        crosshair.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        crosshair.strokeColor = NSColor.white.cgColor
        crosshair.lineWidth = 1.6
        crosshair.lineCap = .round
        crosshair.shadowColor = NSColor.black.cgColor
        crosshair.shadowOpacity = 0.6
        crosshair.shadowRadius = 1.5
        crosshair.shadowOffset = .zero
        crosshair.opacity = 0
        crosshair.contentsScale = 4
        layer.addSublayer(crosshair)
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        layer.addSublayer(flash)
        thumb.addSublayer(thumbBody)
        thumbBody.masksToBounds = true
        thumbBody.cornerCurve = .continuous
        thumbBody.addSublayer(thumbGradient)
        thumbGradient.startPoint = CGPoint(x: 0, y: 1)
        thumbGradient.endPoint = CGPoint(x: 1, y: 0)
        thumbBody.addSublayer(thumbMini)
        thumb.opacity = 0
        layer.addSublayer(thumb)
    }

    override func layoutContent(in b: CGRect) {
        let ww = min(b.width * 0.74, 400), wh = ww * 0.62
        let frame = CGRect(x: (b.width - ww) / 2, y: b.height * 0.6 - wh / 2, width: ww, height: wh)
        window.layout(frame: frame)

        let gap: CGFloat = 12
        let total = keys.reduce(0) { $0 + $1.width } + gap * CGFloat(keys.count - 1)
        var x = (b.width - total) / 2
        let keyY = min(frame.minY - 34 - Self.keyHeight / 2, b.height * 0.19)
        for key in keys {
            key.cap.bounds = CGRect(x: 0, y: 0, width: key.width, height: Self.keyHeight)
            key.cap.position = CGPoint(x: x + key.width / 2, y: max(Self.keyHeight / 2 + 20, keyY))
            key.cap.cornerRadius = 13
            key.cap.cornerCurve = .continuous
            key.glow.bounds = key.cap.bounds
            key.glow.position = key.cap.position
            key.glow.shadowPath = CGPath(roundedRect: key.cap.bounds, cornerWidth: 13, cornerHeight: 13, transform: nil)
            key.shade.frame = key.cap.bounds
            key.shade.cornerRadius = 13
            key.glyph.bounds = CGRect(x: 0, y: 0, width: key.width, height: 30)
            key.glyph.position = CGPoint(x: key.width / 2, y: Self.keyHeight / 2 + 1)
            CCMaterial.refit(key.cap, radius: 13)
            x += key.width + gap
        }

        selection = CGRect(x: frame.minX + ww * 0.3, y: frame.minY + wh * 0.1,
                           width: ww * 0.62, height: wh * 0.52)
        marquee.frame = CGRect(origin: .zero, size: b.size)
        flash.frame = selection
        flash.cornerRadius = 2
        let tw = min(126, b.width * 0.3)
        thumbScale = selection.width / tw
        let th = tw * selection.height / selection.width
        thumb.bounds = CGRect(x: 0, y: 0, width: tw, height: th)
        thumbBody.frame = thumb.bounds
        thumbBody.cornerRadius = 7
        thumbGradient.frame = thumb.bounds
        thumbMini.frame = thumb.bounds.insetBy(dx: tw * 0.12, dy: th * 0.16)
        thumbMini.cornerRadius = 4
        Stage.castShadow(thumb, radius: 7, blur: 14, opacity: 0.5, dy: -6)
        thumbTarget = CGPoint(x: b.width - 22 - tw / 2, y: frame.minY + th / 2 - 6)
        thumb.position = thumbTarget
    }

    override func applyTheme() {
        let colors = CCTheme.color
        window.applyTheme()
        let ink: NSColor = CCTheme.isDark ? .white : .black
        for key in keys {
            key.cap.backgroundColor = colors.elevated.cgColor
            CCMaterial.dress(key.cap, as: .raised(tint: colors.elevated), radius: 13)
            key.glyph.foregroundColor = colors.foreground.cgColor
            key.shade.backgroundColor = ink.cgColor
            key.glow.shadowColor = colors.primary.cgColor
            // Keep the press shade above the material, below the glyph.
            key.cap.insertSublayer(key.shade, below: key.glyph)
        }
        thumbGradient.colors = [colors.primary.cgColor, NSColor.systemTeal.cgColor]
        thumbBody.borderWidth = 2.5
        thumbBody.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        thumbMini.backgroundColor = colors.card.withAlphaComponent(0.9).cgColor
    }

    private func rectPath(_ rect: CGRect) -> CGPath { CGPath(rect: rect, transform: nil) }

    override func startLoops(t0: CFTimeInterval, camera: CALayer) {
        let T = 5.8
        // ⇧ ⌘ 4 — each cap tints down in turn, all release together.
        for (i, key) in keys.enumerated() {
            let down = 0.35 + Double(i) * 0.17
            addLoop(Stage.track("opacity", [(down, 0.0), (down + 0.06, CCTheme.isDark ? 0.14 : 0.1),
                                            (1.15, CCTheme.isDark ? 0.14 : 0.1), (1.27, 0.0)],
                                period: T, t0: t0), to: key.shade, key: "shortcut.key.shade")
            addLoop(Stage.track("shadowOpacity", [(down, Float(0)), (down + 0.08, Float(0.95)),
                                                  (1.15, Float(0.95)), (1.45, Float(0))],
                                period: T, t0: t0), to: key.glow, key: "shortcut.key.glow")
            addLoop(Stage.track("shadowRadius", [(down, 4.0), (down + 0.08, 14.0), (1.15, 14.0), (1.45, 4.0)],
                                period: T, t0: t0), to: key.glow, key: "shortcut.key.glowR")
        }
        // Crosshair drags the selection out.
        let start = CGPoint(x: selection.minX, y: selection.maxY)
        let end = CGPoint(x: selection.maxX, y: selection.minY)
        let zero = CGRect(origin: start, size: .zero)
        addLoop(Stage.track("path", [
            (1.3, rectPath(zero)), (2.2, rectPath(selection)),
        ], period: T, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1), t0: t0),
                to: marquee, key: "shortcut.marquee.path")
        addLoop(Stage.track("opacity", [(1.2, 0.0), (1.3, 1.0), (2.35, 1.0), (2.5, 0.0)],
                            period: T, t0: t0), to: marquee, key: "shortcut.marquee.o")
        addLoop(Stage.track("position", [
            (1.3, NSValue(point: start)), (2.2, NSValue(point: end)),
        ], period: T, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1), t0: t0),
                to: crosshair, key: "shortcut.cross.p")
        addLoop(Stage.track("opacity", [(1.15, 0.0), (1.28, 1.0), (2.25, 1.0), (2.35, 0.0)],
                            period: T, t0: t0), to: crosshair, key: "shortcut.cross.o")
        // Shutter flash.
        addLoop(Stage.track("opacity", [(2.24, 0.0), (2.3, 0.75), (2.62, 0.0)],
                            period: T, t0: t0), to: flash, key: "shortcut.flash")
        // The capture flies to its floating thumbnail, bounces, rests, leaves.
        let from = CGPoint(x: selection.midX, y: selection.midY)
        let away = CGPoint(x: thumbTarget.x + 190, y: thumbTarget.y)
        addLoop(Stage.track("opacity", [(2.3, 0.0), (2.34, 1.0), (5.3, 1.0), (5.45, 0.0)],
                            period: T, t0: t0), to: thumb, key: "shortcut.thumb.o")
        addLoop(Stage.track("position", [
            (2.34, NSValue(point: from)), (3.05, NSValue(point: thumbTarget)),
            (4.85, NSValue(point: thumbTarget)), (5.4, NSValue(point: away)),
        ], period: T, curves: [CCMotion.bounce, CAMediaTimingFunction(name: .linear),
                              CAMediaTimingFunction(name: .easeIn)], t0: t0),
                to: thumb, key: "shortcut.thumb.p")
        addLoop(Stage.track("transform.scale", [(2.34, thumbScale), (3.05, 1.0)],
                            period: T, curve: CCMotion.bounce, t0: t0), to: thumb, key: "shortcut.thumb.s")
    }

    override func enter(animated: Bool) {
        guard animated, !RecordingMotion.reduceMotion else { return }
        Stage.oneShot(window.layer, "position.y", from: 18, to: 0, duration: 0.65, additive: true)
        for (i, key) in keys.enumerated() {
            Stage.spring(key.cap, "transform.scale", from: 0.7, to: 1.0, .bouncy, delay: 0.12 + Double(i) * 0.06)
            Stage.spring(key.glow, "transform.scale", from: 0.7, to: 1.0, .bouncy, delay: 0.12 + Double(i) * 0.06)
            Stage.oneShot(key.cap, "opacity", from: 0, to: 1, duration: 0.25, delay: 0.12 + Double(i) * 0.06)
        }
    }

    override func showStaticFrame() {
        marquee.path = rectPath(selection)
        marquee.opacity = 1
        thumb.opacity = 1
    }

    // MARK: Harness seams
    var probeThumb: CALayer { thumb }
    func probeKeyShade(_ i: Int) -> CALayer { keys[i].shade }
}

// MARK: - Finish: celebration

/// The CaptureCat mark floating over a breathing glow, four feature chips in
/// orbit, and the recording bar sliding up ready to go. First arrival
/// celebrates: shock rings + a burst of confetti chips in the palette.
@MainActor
final class FinishScene: OnboardingScene {
    private var mark = Stage.mark(height: 120)
    private let glow = CAGradientLayer()
    private let chips = [
        StageChip(symbol: "plus.magnifyingglass", text: "Auto-zoom"),
        StageChip(symbol: "cursorarrow.motionlines", text: "Smooth cursor"),
        StageChip(symbol: "captions.bubble", text: "Captions"),
        StageChip(symbol: "link", text: "Share links"),
    ]
    private let bar = CALayer()
    private let barDot = CALayer()
    private let barLabel = Stage.text("Recording", size: 12.5, weight: .semibold)
    private let barTimer = Stage.text("00:07", size: 12, weight: .medium, monospacedDigits: true)
    private let barDivider = CALayer()
    private let barStop = CALayer()
    private let barStopGlyph = CALayer()
    private var markCenter = CGPoint.zero
    private var markHeight: CGFloat = 120
    private var orbit: [CGPoint] = []

    override init() {
        super.init()
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(glow)
        layer.addSublayer(mark)
        for chip in chips { layer.addSublayer(chip.layer) }
        bar.addSublayer(barDot)
        bar.addSublayer(barLabel)
        bar.addSublayer(barTimer)
        bar.addSublayer(barDivider)
        bar.addSublayer(barStop)
        barStop.addSublayer(barStopGlyph)
        layer.addSublayer(bar)
    }

    override func layoutContent(in b: CGRect) {
        let h = min(b.height * 0.24, 132)
        if abs(h - markHeight) > 0.5 || mark.bounds.height == 0 {
            let fresh = Stage.mark(height: h)
            layer.replaceSublayer(mark, with: fresh)
            mark = fresh
            markHeight = h
        }
        markCenter = CGPoint(x: b.midX, y: b.height * 0.57)
        mark.position = markCenter
        let g = h * 2.6
        glow.bounds = CGRect(x: 0, y: 0, width: g, height: g)
        glow.position = markCenter
        let reach = h * 1.02
        let offsets: [CGPoint] = [
            CGPoint(x: -1.2, y: 0.62), CGPoint(x: 1.15, y: 0.78),
            CGPoint(x: -1.1, y: -0.6), CGPoint(x: 1.2, y: -0.5),
        ]
        orbit = offsets.map { CGPoint(x: markCenter.x + $0.x * reach, y: markCenter.y + $0.y * reach) }
        for (chip, point) in zip(chips, orbit) {
            // Keep every chip fully on stage whatever the width.
            let half = chip.width / 2 + 12
            chip.place(center: CGPoint(x: min(max(point.x, half), b.width - half), y: point.y))
        }
        orbit = chips.map(\.layer.position)

        let bw: CGFloat = 232, bh: CGFloat = 44
        bar.bounds = CGRect(x: 0, y: 0, width: bw, height: bh)
        bar.cornerRadius = bh / 2
        bar.cornerCurve = .continuous
        bar.position = CGPoint(x: b.midX, y: max(bh / 2 + 22, b.height * 0.14))
        barDot.frame = CGRect(x: 18, y: bh / 2 - 5, width: 10, height: 10)
        barDot.cornerRadius = 5
        barLabel.position = CGPoint(x: 38 + barLabel.bounds.width / 2, y: bh / 2 - 0.5)
        barTimer.position = CGPoint(x: 38 + barLabel.bounds.width + 10 + barTimer.bounds.width / 2, y: bh / 2 - 0.5)
        barDivider.frame = CGRect(x: bw - 54, y: 11, width: 1, height: bh - 22)
        barStop.frame = CGRect(x: bw - 42, y: bh / 2 - 13, width: 26, height: 26)
        barStop.cornerRadius = 8
        barStop.cornerCurve = .continuous
        barStopGlyph.frame = CGRect(x: 8, y: 8, width: 10, height: 10)
        barStopGlyph.cornerRadius = 2.5
        CCMaterial.refit(bar, radius: bh / 2)
        CCMaterial.refit(barStop, radius: 8)
    }

    override func applyTheme() {
        let colors = CCTheme.color
        glow.colors = [
            colors.primary.withAlphaComponent(0.55).cgColor,
            colors.primary.withAlphaComponent(0.18).cgColor,
            colors.primary.withAlphaComponent(0).cgColor,
        ]
        glow.locations = [0, 0.4, 1]
        for chip in chips { chip.applyTheme() }
        bar.backgroundColor = colors.elevated.cgColor
        CCMaterial.dress(bar, as: .raised(tint: colors.elevated), radius: 22)
        barDot.backgroundColor = NSColor.systemRed.cgColor
        barLabel.foregroundColor = colors.foreground.cgColor
        barTimer.foregroundColor = colors.mutedForeground.cgColor
        barDivider.backgroundColor = colors.border.cgColor
        let stopTint = CCTheme.isDark ? colors.card : colors.background
        barStop.backgroundColor = stopTint.cgColor
        CCMaterial.suppressShadow(barStop)
        CCMaterial.dress(barStop, as: .raised(tint: stopTint), radius: 8)
        barStopGlyph.backgroundColor = colors.foreground.cgColor
        barStop.insertSublayer(barStopGlyph, at: UInt32(barStop.sublayers?.count ?? 0))
    }

    override func enter(animated: Bool) {
        guard animated, !RecordingMotion.reduceMotion else { return }
        Stage.spring(mark, "transform.scale", from: 0.55, to: 1.0, .bouncy, delay: 0.05)
        Stage.oneShot(mark, "opacity", from: 0, to: 1, duration: 0.3, delay: 0.05)
        for (i, chip) in chips.enumerated() {
            let delay = 0.2 + Double(i) * 0.07
            Stage.spring(chip.layer, "position", from: NSValue(point: markCenter),
                         to: NSValue(point: orbit[i]), .bouncy, delay: delay)
            Stage.spring(chip.layer, "transform.scale", from: 0.4, to: 1.0, .bouncy, delay: delay)
            Stage.oneShot(chip.layer, "opacity", from: 0, to: 1, duration: 0.25, delay: delay)
        }
        Stage.oneShot(bar, "position.y", from: -26, to: 0, duration: 0.7, delay: 0.4, additive: true)
        Stage.oneShot(bar, "opacity", from: 0, to: 1, duration: 0.35, delay: 0.4)
    }

    override func startLoops(t0: CFTimeInterval, camera: CALayer) {
        addLoop(Stage.bob(amount: 6, period: 5.5, t0: t0), to: mark, key: "finish.float")
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.55
        breathe.toValue = 1.0
        breathe.duration = 2.75
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.beginTime = t0
        addLoop(breathe, to: glow, key: "finish.glow")
        for (i, chip) in chips.enumerated() {
            addLoop(Stage.bob(amount: 4, period: [4.2, 4.9, 5.4, 6.1][i], phase: [0, 0.4, 0.7, 0.2][i], t0: t0),
                    to: chip.layer, key: "finish.chipBob")
        }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0.3
        blink.duration = 0.75
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.beginTime = t0
        addLoop(blink, to: barDot, key: "finish.dot")
    }

    /// Shock rings + a palette confetti burst from the mark. One-shot.
    func celebrate() {
        guard !RecordingMotion.reduceMotion else { return }
        let palette = OnboardingWallpaper.palette(for: .finish, dark: true).fields + [CCTheme.color.primary]
        for i in 0..<3 {
            let ring = CAShapeLayer()
            let d = markHeight * 1.1
            ring.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            ring.position = markCenter
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = palette[i % palette.count].cgColor
            ring.lineWidth = 3
            ring.opacity = 0
            layer.insertSublayer(ring, below: mark)
            let delay = Double(i) * 0.14
            Stage.oneShot(ring, "transform.scale", from: 0.5, to: 2.9, duration: 1.1, delay: delay)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0]
            fade.keyTimes = [0, 0.12, 1]
            fade.duration = 1.1
            fade.beginTime = ring.convertTime(CACurrentMediaTime(), from: nil) + delay
            ring.add(fade, forKey: "fade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 + delay) { ring.removeFromSuperlayer() }
        }
        for i in 0..<18 {
            let bit = CALayer()
            let size = CGFloat([6, 8, 7, 9][i % 4])
            bit.bounds = CGRect(x: 0, y: 0, width: size, height: i % 3 == 0 ? size * 0.5 : size)
            bit.cornerRadius = i % 3 == 0 ? 1.5 : size / 2
            bit.backgroundColor = palette[i % palette.count].cgColor
            bit.position = markCenter
            bit.opacity = 0
            layer.addSublayer(bit)
            let angle = Double(i) / 18 * 2 * .pi + Double(i % 5) * 0.11
            let reach = markHeight * (0.95 + CGFloat(i % 4) * 0.22)
            let out = CGPoint(x: markCenter.x + CGFloat(cos(angle)) * reach,
                              y: markCenter.y + CGFloat(sin(angle)) * reach)
            let fallen = CGPoint(x: out.x, y: out.y - markHeight * 0.35)
            let path = CAKeyframeAnimation(keyPath: "position")
            path.values = [NSValue(point: markCenter), NSValue(point: out), NSValue(point: fallen)]
            path.keyTimes = [0, 0.45, 1]
            path.timingFunctions = [CCMotion.settle, CAMediaTimingFunction(name: .easeIn)]
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (i % 2 == 0 ? 1.0 : -1.0) * Double.pi * 2.5
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.08, 0.6, 1]
            let group = CAAnimationGroup()
            group.animations = [path, spin, fade]
            group.duration = 1.5 + Double(i % 3) * 0.15
            group.beginTime = bit.convertTime(CACurrentMediaTime(), from: nil) + 0.05
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            bit.add(group, forKey: "burst")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { bit.removeFromSuperlayer() }
        }
        Stage.spring(mark, "transform.scale", from: 1.12, to: 1.0, .bouncy)
    }

    // MARK: Harness seams
    var probeMark: CALayer { mark }
    var probeChips: [CALayer] { chips.map(\.layer) }
}
