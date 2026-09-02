import AppKit

/// The shared "one wash that glides between rows" behavior (macOS Sonoma
/// menu feel). Host it in any container of row views: rows report
/// hover/selection intent and the wash springs between their frames,
/// appearing in place on first entry and fading out when nothing is active.
@MainActor
final class CCGlideHighlight {
    let layer = CALayer()
    /// The wash rides its OWN subview, never the host's backing layer:
    /// AppKit owns view backing layers and rebuilds their sublayer arrays on
    /// relayout — a foreign sublayer silently vanished from busy hosts (the
    /// timeline toolbar refreshes at playback rate), which shipped as "the
    /// toolbar never glides". Subviews are ours; AppKit leaves them alone.
    private let washHost = NSView()
    private weak var host: NSView?
    private weak var current: NSView?
    private var themeObservation: CCThemeObservation?

    init(host: NSView, radius: CCRadius = .md, color: NSColor? = nil) {
        self.host = host
        host.wantsLayer = true
        washHost.wantsLayer = true
        washHost.frame = host.bounds
        washHost.autoresizingMask = [.width, .height]
        host.addSubview(washHost, positioned: .below, relativeTo: nil)
        layer.cornerRadius = CCTheme.radius(radius)
        layer.cornerCurve = .continuous
        layer.opacity = 0
        washHost.layer?.addSublayer(layer)
        themeObservation = CCThemeObservation { [weak self] in
            self?.layer.backgroundColor = (color ?? CCTheme.color.active).cgColor
        }
    }

    func update(row: NSView, active: Bool) {
        guard let host else {
            if CCHoverPoller.debug { NSLog("CCGlide update DROPPED — host deallocated") }
            return
        }
        if CCHoverPoller.debug {
            NSLog("CCGlide update active=%d row=%@ hostLayer=%d washOpacity=%.2f",
                  active ? 1 : 0, String(describing: type(of: row)),
                  host.layer != nil ? 1 : 0, layer.opacity)
        }
        if active {
            host.layoutSubtreeIfNeeded()
            let target = row.convert(row.bounds, to: host)
            // `current` deliberately survives the exit fade. Opacity is NOT
            // a reliable test here: when the pointer pauses between chips the
            // 0.16s fade completes, making the next chip look like a first
            // landing despite there being a perfectly good previous frame.
            // That was exactly the recording-toolbar failure in the live log:
            // every new target reported washOpacity=0.00 and snapped in place.
            // A real first entry has no current row; every later entry glides
            // from the persistent layer frame, regardless of its opacity.
            let appearing = current == nil
            if CCHoverPoller.debug {
                NSLog("CCGlide target=%@ frame=%@ prior=%@ appearing=%d",
                      String(describing: type(of: row)),
                      NSStringFromRect(target),
                      current.map { String(describing: type(of: $0)) } ?? "none",
                      appearing ? 1 : 0)
            }
            current = row
            if appearing {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.frame = target
                CATransaction.commit()
            } else {
                CCMotion.spring(layer, keyPath: "position",
                                 to: NSValue(point: CGPoint(x: target.midX, y: target.midY)), .snappy)
                CCMotion.spring(layer, keyPath: "bounds",
                                 to: NSValue(rect: CGRect(origin: .zero, size: target.size)), .snappy)
            }
            CCMotion.fade(layer, keyPath: "opacity", to: 1, duration: 0.1)
        } else if current === row {
            // Fade but KEEP `current`: an immediate hop to the next row must
            // glide from here. Once the fade completes, `appearing` above
            // covers the true fresh-landing case via the opacity check.
            CCMotion.fade(layer, keyPath: "opacity", to: 0, duration: 0.16)
        }
    }

    /// Presentation geometry for animation probes. The model layer is already
    /// at its target while a spring is moving, so callers must inspect this
    /// value to prove the wash genuinely glides.
    var debugPresentationFrame: CGRect {
        (layer.presentation() ?? layer).frame
    }
}
