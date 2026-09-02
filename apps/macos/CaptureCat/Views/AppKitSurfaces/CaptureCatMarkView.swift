import AppKit
import QuartzCore

// The CaptureCat mark, drawn as vectors — the native sibling of the web's
// CaptureCatMark.tsx. Each colour region of the traced artwork is one
// CAShapeLayer; the path data lives in CaptureCatMarkPaths.swift (generated
// from the TSX so both platforms render the identical geometry).
//
// Signature idle motion, mirroring the web mark:
//   * blink — eyelid ellipses flash opaque for a beat, with a double-blink,
//     about every 4.5 s (opacity only, the traced geometry is untouched)
//   * float — the whole mark drifts ±7 px vertically with a slight rotate on
//     a ~5.5 s ease-in-out loop
// Both are plain repeating CAAnimations and are removed entirely while
// Reduce Motion is on (re-checked when the accessibility setting changes).
//
// Chrome only — nothing here touches preview/export math (CLAUDE.md §2 does
// not apply).
@MainActor
final class CaptureCatMarkView: NSView {
    /// Artwork box after the viewBox crop (148 88 728 834).
    static let artSize = NSSize(width: 728, height: 834)

    private let container = CALayer()
    private let eyelids = CALayer()
    private var displayOptionsObserver: NSObjectProtocol?
    private let animated: Bool

    init(height: CGFloat, animated: Bool = true) {
        self.animated = animated
        let width = height * Self.artSize.width / Self.artSize.height
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Potrace space → local y-up space: the source transform is
        // translate(0,1024) scale(0.1,-0.1) with viewBox origin (148, 88).
        // y_up = 834 − ((1024 − 0.1y) − 88) = 0.1y − 102; x = 0.1x − 148.
        var toLocal = CGAffineTransform(a: 0.1, b: 0, c: 0, d: 0.1, tx: -148, ty: -102)

        for region in CaptureCatMarkPaths.regions {
            let shape = CAShapeLayer()
            shape.path = SVGPathParser.path(from: region.data)?.copy(using: &toLocal)
            shape.fillColor = region.color.cgColor
            shape.fillRule = .nonZero // SVG default; potrace winds holes opposite
            container.addSublayer(shape)
        }

        // Eyelids: body-black ellipses over the eyes, revealed by the blink
        // animation only. ViewBox centres (332, 552) and (662, 552), r 72×60
        // → local (184, 370) and (514, 370) after crop + flip.
        for cx in [CGFloat(184), 514] {
            let lid = CAShapeLayer()
            lid.path = CGPath(ellipseIn: CGRect(x: cx - 72, y: 370 - 60, width: 144, height: 120), transform: nil)
            lid.fillColor = NSColor.black.cgColor
            eyelids.addSublayer(lid)
        }
        eyelids.opacity = 0
        container.addSublayer(eyelids)

        let scale = height / Self.artSize.height
        container.frame = CGRect(origin: .zero, size: Self.artSize)
        container.anchorPoint = .zero
        container.position = .zero
        container.transform = CATransform3DMakeScale(scale, scale, 1)
        layer?.addSublayer(container)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])

        syncIdleAnimations()
        displayOptionsObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncIdleAnimations() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let displayOptionsObserver {
            NotificationCenter.default.removeObserver(displayOptionsObserver)
        }
    }

    private func syncIdleAnimations() {
        layer?.removeAnimation(forKey: "float")
        layer?.removeAnimation(forKey: "sway")
        eyelids.removeAnimation(forKey: "blink")
        guard animated, !RecordingMotion.reduceMotion else { return }

        // Gentle float: translateY ±7 px on a slow ease-in-out loop.
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = -7
        float.toValue = 7
        float.duration = 5.5 / 2 // autoreversed half-cycle → full loop ≈ 5.5 s
        float.autoreverses = true
        float.repeatCount = .infinity
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(float, forKey: "float")

        // A whisper of rotation on the same clock family.
        let sway = CABasicAnimation(keyPath: "transform.rotation.z")
        sway.fromValue = -1.2 * CGFloat.pi / 180
        sway.toValue = 1.2 * CGFloat.pi / 180
        sway.duration = 5.5 / 2
        sway.autoreverses = true
        sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(sway, forKey: "sway")

        // Blink: closed for a beat then a quick double-blink, every ~4.5 s.
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0, 0, 1, 1, 0, 0, 1, 1, 0]
        blink.keyTimes = [0, 0.855, 0.87, 0.895, 0.91, 0.925, 0.94, 0.965, 0.98]
        blink.duration = 4.5
        blink.repeatCount = .infinity
        eyelids.add(blink, forKey: "blink")
    }
}

/// Minimal SVG path-data parser — handles the command set potrace emits
/// (M/m, L/l, H/h, V/v, C/c, S/s, Z/z, with implicit command repetition),
/// which covers the generated mark paths exactly.
enum SVGPathParser {
    static func path(from data: String) -> CGPath? {
        let path = CGMutablePath()
        var numbers: [CGFloat] = []
        var command: Character = " "
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?

        var index = data.startIndex
        func parseNumber() -> CGFloat? {
            while index < data.endIndex, data[index] == " " || data[index] == "," || data[index] == "\n" {
                index = data.index(after: index)
            }
            var text = ""
            while index < data.endIndex {
                let ch = data[index]
                if ch.isNumber || ch == "." || (ch == "-" && text.isEmpty) {
                    text.append(ch)
                    index = data.index(after: index)
                } else { break }
            }
            return text.isEmpty ? nil : Double(text).map { CGFloat($0) }
        }

        func run(_ cmd: Character, _ nums: [CGFloat]) {
            let relative = cmd.isLowercase
            switch Character(cmd.lowercased()) {
            case "m":
                var origin = CGPoint(x: nums[0], y: nums[1])
                if relative { origin.x += current.x; origin.y += current.y }
                path.move(to: origin)
                current = origin
                subpathStart = origin
                // Extra pairs after a moveto are implicit linetos.
                var i = 2
                while i + 1 < nums.count {
                    var pt = CGPoint(x: nums[i], y: nums[i + 1])
                    if relative { pt.x += current.x; pt.y += current.y }
                    path.addLine(to: pt)
                    current = pt
                    i += 2
                }
                lastControl = nil
            case "l":
                var i = 0
                while i + 1 < nums.count {
                    var pt = CGPoint(x: nums[i], y: nums[i + 1])
                    if relative { pt.x += current.x; pt.y += current.y }
                    path.addLine(to: pt)
                    current = pt
                    i += 2
                }
                lastControl = nil
            case "h":
                for n in nums {
                    current.x = relative ? current.x + n : n
                    path.addLine(to: current)
                }
                lastControl = nil
            case "v":
                for n in nums {
                    current.y = relative ? current.y + n : n
                    path.addLine(to: current)
                }
                lastControl = nil
            case "c":
                var i = 0
                while i + 5 < nums.count {
                    var c1 = CGPoint(x: nums[i], y: nums[i + 1])
                    var c2 = CGPoint(x: nums[i + 2], y: nums[i + 3])
                    var end = CGPoint(x: nums[i + 4], y: nums[i + 5])
                    if relative {
                        c1.x += current.x; c1.y += current.y
                        c2.x += current.x; c2.y += current.y
                        end.x += current.x; end.y += current.y
                    }
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    current = end
                    i += 6
                }
            case "s":
                var i = 0
                while i + 3 < nums.count {
                    let c1 = lastControl.map {
                        CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                    } ?? current
                    var c2 = CGPoint(x: nums[i], y: nums[i + 1])
                    var end = CGPoint(x: nums[i + 2], y: nums[i + 3])
                    if relative {
                        c2.x += current.x; c2.y += current.y
                        end.x += current.x; end.y += current.y
                    }
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    current = end
                    i += 4
                }
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
            default:
                break
            }
        }

        while index < data.endIndex {
            let ch = data[index]
            if ch == " " || ch == "," || ch == "\n" {
                index = data.index(after: index)
            } else if ch.isLetter {
                if command != " ", !numbers.isEmpty { run(command, numbers) }
                if ch == "z" || ch == "Z" { run(ch, []) }
                command = ch
                numbers = []
                index = data.index(after: index)
            } else if let number = parseNumber() {
                numbers.append(number)
            } else {
                index = data.index(after: index)
            }
        }
        if command != " ", !numbers.isEmpty { run(command, numbers) }
        return path.isEmpty ? nil : path
    }
}
