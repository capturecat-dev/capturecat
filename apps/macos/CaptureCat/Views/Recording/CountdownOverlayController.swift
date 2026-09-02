import AppKit
import QuartzCore

/// 3-2-1 countdown shown centered on the screen that is about to be captured.
/// The panel is excluded from capture (`sharingType = .none`, plus the
/// recorder's per-app window exclusion) and ignores mouse events so the user
/// can position windows during the countdown.
@MainActor
enum CountdownOverlayController {
    static func run(on screen: NSScreen?, seconds: Int = 3) async {
        guard seconds > 0, let screen = screen ?? NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let badge = CountdownBadgeView()
        badge.frame = NSRect(origin: .zero, size: screen.frame.size)
        badge.autoresizingMask = [.width, .height]
        panel.contentView = badge
        badge.begin(total: seconds)

        for value in stride(from: seconds, through: 1, by: -1) {
            badge.show(value)
            if value == seconds {
                panel.orderFrontRegardless()
            }
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
        panel.close()
    }
}

/// A glossy circular dial centred on the screen, in the spirit of classic
/// Apple timer chrome (not a 1:1 copy): a soft white disc with a bevelled
/// rim, a red ring that depletes clockwise across the whole countdown, and
/// a red "3s"-style numeral in the middle. Each tick crossfades the numeral
/// with a small spring settle; reduce-motion collapses the crossfade to a
/// fast plain fade and steps the ring per-second instead of sweeping it
/// (`RecordingMotion`).
@MainActor
private final class CountdownBadgeView: NSView {
    private let badge = CALayer()
    private let ring = CAShapeLayer()
    private var currentDigit: CALayer?
    private var total = 3

    private static let diameter: CGFloat = 170
    private static let ringWidth: CGFloat = 11
    /// Ring centreline inset from the badge edge.
    private static let ringInset: CGFloat = 17
    private static let fontSize: CGFloat = 52
    /// How far the outgoing digit grows / the incoming digit starts below 1.0.
    private static let outScale: CGFloat = 1.12
    private static let inScale: CGFloat = 0.88
    private static let outDuration: TimeInterval = 0.3

    /// The dial keeps fixed colors — it floats over arbitrary screen content,
    /// so it never follows the app theme.
    private static let red = NSColor(srgbRed: 0.91, green: 0.12, blue: 0.14, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let d = Self.diameter
        badge.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        badge.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        badge.shadowOpacity = 1
        badge.shadowRadius = 22
        badge.shadowOffset = CGSize(width: 0, height: -6)
        layer?.addSublayer(badge)

        // Bevelled rim: a subtle vertical wash over white reads as the old
        // rounded-plastic edge without any literal gloss highlight.
        let rim = CAGradientLayer()
        rim.frame = badge.bounds
        rim.cornerRadius = d / 2
        rim.colors = [
            NSColor.white.cgColor,
            NSColor(srgbRed: 0.87, green: 0.87, blue: 0.89, alpha: 1).cgColor,
        ]
        rim.startPoint = CGPoint(x: 0.5, y: 1)
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        badge.addSublayer(rim)

        // Groove the ring sits in.
        let grooveRadius = d / 2 - Self.ringInset
        let center = CGPoint(x: d / 2, y: d / 2)
        let groovePath = CGPath(
            ellipseIn: CGRect(
                x: center.x - grooveRadius, y: center.y - grooveRadius,
                width: grooveRadius * 2, height: grooveRadius * 2
            ),
            transform: nil
        )
        let groove = CAShapeLayer()
        groove.path = groovePath
        groove.fillColor = nil
        groove.strokeColor = NSColor.black.withAlphaComponent(0.07).cgColor
        groove.lineWidth = Self.ringWidth
        badge.addSublayer(groove)

        // Red progress ring: starts at 12 o'clock, depletes clockwise.
        // (Layer space is y-up, so a decreasing-angle sweep from π/2 is
        // visually clockwise.)
        let ringPath = CGMutablePath()
        ringPath.addArc(
            center: center, radius: grooveRadius,
            startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi,
            clockwise: true
        )
        ring.path = ringPath
        ring.fillColor = nil
        ring.strokeColor = Self.red.cgColor
        ring.lineWidth = Self.ringWidth
        ring.lineCap = .round
        badge.addSublayer(ring)

        // Inner face the numeral sits on — a hair above the rim wash.
        let faceRadius = grooveRadius - Self.ringWidth / 2 - 5
        let face = CALayer()
        face.bounds = CGRect(x: 0, y: 0, width: faceRadius * 2, height: faceRadius * 2)
        face.position = center
        face.cornerRadius = faceRadius
        face.backgroundColor = NSColor.white.cgColor
        face.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
        face.shadowOpacity = 1
        face.shadowRadius = 4
        face.shadowOffset = CGSize(width: 0, height: -1)
        badge.addSublayer(face)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func begin(total: Int) {
        self.total = max(1, total)
    }

    func show(_ value: Int) {
        showDigit("\(value)s")
        // Sweep the ring down over this second; reduce-motion steps instead.
        let from = CGFloat(value) / CGFloat(total)
        let to = CGFloat(value - 1) / CGFloat(total)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if RecordingMotion.reduceMotion {
            ring.strokeEnd = from
        } else {
            ring.strokeEnd = to
            let sweep = CABasicAnimation(keyPath: "strokeEnd")
            sweep.fromValue = from
            sweep.toValue = to
            sweep.duration = 1
            sweep.timingFunction = CAMediaTimingFunction(name: .linear)
            ring.add(sweep, forKey: "countdown-ring")
        }
        CATransaction.commit()
    }

    private func showDigit(_ string: String) {
        let incoming = makeDigitLayer(string)
        badge.addSublayer(incoming)
        let reduceMotion = RecordingMotion.reduceMotion
        let outgoing = currentDigit
        currentDigit = incoming

        // Outgoing: fade out; unless reduce-motion, also grow slightly.
        if let outgoing {
            CATransaction.begin()
            CATransaction.setCompletionBlock { outgoing.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = reduceMotion ? RecordingMotion.reducedDuration : Self.outDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            outgoing.opacity = 0
            outgoing.add(fade, forKey: "countdown-out-fade")
            if !reduceMotion {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 1.0
                grow.toValue = Self.outScale
                grow.duration = Self.outDuration
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                grow.isRemovedOnCompletion = false
                grow.fillMode = .forwards
                outgoing.add(grow, forKey: "countdown-out-scale")
            }
            CATransaction.commit()
        }

        // Incoming: fade in; unless reduce-motion, spring-settle from 0.88.
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0.0
        fadeIn.toValue = 1.0
        fadeIn.duration = reduceMotion
            ? RecordingMotion.reducedDuration
            : Self.outDuration * 0.8
        fadeIn.timingFunction = RecordingMotion.settleCurve
        incoming.add(fadeIn, forKey: "countdown-in-fade")
        if !reduceMotion {
            let settle = RecordingMotion.positionSpring()
            settle.keyPath = "transform.scale"
            settle.fromValue = Self.inScale
            settle.toValue = 1.0
            incoming.add(settle, forKey: "countdown-in-scale")
        }
    }

    /// Pre-renders the numeral into a correctly scaled layer so it stays
    /// crisp under transform animations (CATextLayer blurs when scaled).
    private func makeDigitLayer(_ string: String) -> CALayer {
        var font = NSFont.systemFont(ofSize: Self.fontSize, weight: .bold)
        if let rounded = font.fontDescriptor.withDesign(.rounded),
           let roundedFont = NSFont(descriptor: rounded, size: Self.fontSize) {
            font = roundedFont
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.red,
        ]
        let text = NSAttributedString(string: string, attributes: attributes)
        let textSize = text.size()
        let pad: CGFloat = 8
        let size = NSSize(width: ceil(textSize.width) + pad * 2,
                          height: ceil(textSize.height) + pad * 2)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let image = NSImage(size: size, flipped: false) { _ in
            text.draw(at: NSPoint(x: pad, y: pad))
            return true
        }

        let digit = CALayer()
        digit.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        digit.contentsScale = scale
        digit.bounds = CGRect(origin: .zero, size: size)
        digit.position = CGPoint(x: Self.diameter / 2, y: Self.diameter / 2)
        digit.contentsGravity = .resizeAspect
        return digit
    }

    override func layout() {
        super.layout()
        // Keep the dial centred on resize without an implicit slide.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}
