import AppKit
import QuartzCore

// The onboarding's right-hand stage: a living wallpaper (the "image") with a
// choreographed product scene per wizard step on top of it.
//
// Architecture:
//  • LAYER-HOSTING view — the whole stage is a pure CALayer tree we own, so
//    AppKit can never rebuild sublayer arrays or clobber transforms mid-loop
//    (the backing-layer lessons from CCKit).
//  • `camera` holds the wallpaper AND the scene layers; the welcome scene
//    drives its transform to demo CaptureCat's auto-zoom — a real camera
//    push, background included, exactly like an exported frame.
//  • `overlayHost` sits above the camera for captions that must not zoom.
//  • Every loop is a set of CAKeyframeAnimations sharing ONE period and ONE
//    begin time, so cursor, clicks, ripples and camera stay frame-locked
//    and loop seamlessly (GPU-driven, no timers).
//
// Chrome only — nothing here touches preview/export math (CLAUDE.md §2).

@MainActor
final class OnboardingStageView: NSView {
    enum SceneID: Int, CaseIterable {
        case welcome, permissions, account, shortcut, finish
    }

    struct Permissions: Equatable {
        var screen = false
        var notifications = false
        var microphone = false
        var camera = false
    }

    private let root = CALayer()
    let camera = CALayer()
    private let wallpaper = OnboardingWallpaper()
    private let sceneHost = CALayer()
    private let overlayHost = CALayer()
    /// A soft shade along the stage's leading edge — the seam against the
    /// content panel reads as depth, not as a hard cut.
    private let edgeShade = CAGradientLayer()
    private var scenes: [SceneID: OnboardingScene] = [:]
    private(set) var currentID: SceneID?
    private var themeObservation: CCThemeObservation?
    private var displayOptionsObserver: NSObjectProtocol?

    // Latest state, replayed into scenes built later.
    private var permissions = Permissions()
    private var accountEmail: String?

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        // Layer-HOSTING: assign the layer before wantsLayer.
        layer = root
        wantsLayer = true
        root.masksToBounds = true
        root.addSublayer(camera)
        camera.addSublayer(wallpaper.layer)
        camera.addSublayer(sceneHost)
        root.addSublayer(overlayHost)
        root.addSublayer(edgeShade)
        edgeShade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeShade.endPoint = CGPoint(x: 1, y: 0.5)
        themeObservation = CCThemeObservation { [weak self] in self?.applyTheme() }
        displayOptionsObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartCurrentScene() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let displayOptionsObserver {
            NotificationCenter.default.removeObserver(displayOptionsObserver)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        for layer in [sceneHost, overlayHost] {
            layer.frame = b
        }
        // The camera pivots around the stage centre; its transform is owned
        // by the welcome loop, so only bounds/position are set here.
        camera.bounds = CGRect(origin: .zero, size: b.size)
        camera.position = CGPoint(x: b.midX, y: b.midY)
        wallpaper.layout(in: CGRect(origin: .zero, size: b.size))
        edgeShade.frame = CGRect(x: 0, y: 0, width: 28, height: b.height)
        CATransaction.commit()

        let sizeChanged = lastLaidOutSize != b.size
        lastLaidOutSize = b.size
        for scene in scenes.values {
            scene.layout(in: CGRect(origin: .zero, size: b.size))
        }
        // Loops bake stage-relative coordinates into their keyframes — a
        // real resize (the editor-window host) re-arms the live scene.
        if sizeChanged, let currentID, let scene = scenes[currentID], scene.isRunning {
            scene.stop()
            scene.start(camera: camera, delay: 0)
        }
    }

    private var lastLaidOutSize: CGSize = .zero

    private func applyTheme() {
        wallpaper.applyTheme()
        edgeShade.colors = [
            NSColor.black.withAlphaComponent(CCTheme.isDark ? 0.28 : 0.10).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for scene in scenes.values { scene.applyTheme() }
        CATransaction.commit()
        // Loops bake theme colours into their keyframes — re-arm the live one.
        if let currentID, let scene = scenes[currentID], scene.isRunning {
            scene.stop()
            scene.start(camera: camera, delay: 0)
        }
    }

    // MARK: - Scene switching

    /// Bring `id` on stage. The wallpaper MORPHS to the step's palette (the
    /// stage itself never moves — sliding a full-height panel reads as the
    /// window lurching); the outgoing scene sinks and dissolves while the
    /// incoming one settles in from a hair larger, then runs its entrance.
    func show(_ id: SceneID, animated: Bool) {
        guard id != currentID else { return }
        let outgoing = currentID.flatMap { scenes[$0] }
        currentID = id
        let incoming = scene(for: id)
        wallpaper.setPalette(for: id, animated: animated)

        if let outgoing {
            outgoing.stop()
            let outLayers = [outgoing.layer, outgoing.overlay]
            if animated && !RecordingMotion.reduceMotion {
                for layer in outLayers {
                    CCMotion.fade(layer, keyPath: "opacity", to: 0, duration: 0.26)
                    CCMotion.spring(layer, keyPath: "transform.scale", to: 0.97, .snappy)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                    guard let self, self.currentID != outgoing.id else { return }
                    outLayers.forEach { $0.removeFromSuperlayer() }
                }
            } else {
                outLayers.forEach { $0.removeFromSuperlayer() }
            }
        }
        // Hand the camera back to rest from wherever the welcome loop left it.
        settleCamera(animated: animated)

        sceneHost.addSublayer(incoming.layer)
        overlayHost.addSublayer(incoming.overlay)
        incoming.layout(in: CGRect(origin: .zero, size: bounds.size))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.applyTheme()
        CATransaction.commit()
        replayState(into: incoming)
        for layer in [incoming.layer, incoming.overlay] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        if animated && !RecordingMotion.reduceMotion {
            // Explicit from-values: a freshly attached layer has no (or a
            // stale) presentation copy, so a from-presentation fade ran 1→1
            // and the scene popped in (caught by --onboarding-shot).
            for layer in [incoming.layer, incoming.overlay] {
                Stage.oneShot(layer, "opacity", from: 0, to: 1, duration: 0.42, curve: CCMotion.glide)
                Stage.spring(layer, "transform.scale", from: 1.035, to: 1.0, .smooth)
            }
        }
        incoming.enter(animated: animated)
        incoming.start(camera: camera, delay: animated ? 0.35 : 0)
    }

    private func settleCamera(animated: Bool) {
        let presented = camera.presentation()?.transform ?? camera.transform
        camera.removeAnimation(forKey: "welcome.camera")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        camera.transform = CATransform3DIdentity
        CATransaction.commit()
        guard animated, !CATransform3DIsIdentity(presented) else { return }
        let back = CABasicAnimation(keyPath: "transform")
        back.fromValue = NSValue(caTransform3D: presented)
        back.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        back.duration = CCMotion.paced(0.55)
        back.timingFunction = CCMotion.settle
        camera.add(back, forKey: "stage.cameraSettle")
    }

    private func restartCurrentScene() {
        guard let currentID, let scene = scenes[currentID] else { return }
        scene.stop()
        settleCamera(animated: false)
        scene.start(camera: camera, delay: 0)
    }

    private func scene(for id: SceneID) -> OnboardingScene {
        if let existing = scenes[id] { return existing }
        let made: OnboardingScene
        switch id {
        case .welcome: made = WelcomeScene()
        case .permissions: made = PermissionsScene()
        case .account: made = AccountScene()
        case .shortcut: made = ShortcutScene()
        case .finish: made = FinishScene()
        }
        made.id = id
        scenes[id] = made
        return made
    }

    private func replayState(into scene: OnboardingScene) {
        (scene as? PermissionsScene)?.update(permissions, animated: false)
        (scene as? AccountScene)?.update(email: accountEmail, animated: false)
    }

    // MARK: - Live state mirrors

    /// The permissions scene mirrors the REAL grant state — flip a toggle in
    /// the wizard and the mock panel's switch springs over with it.
    func update(permissions new: Permissions) {
        guard new != permissions else { return }
        permissions = new
        (scenes[.permissions] as? PermissionsScene)?.update(new, animated: currentID == .permissions)
    }

    func update(accountEmail email: String?) {
        guard email != accountEmail else { return }
        accountEmail = email
        (scenes[.account] as? AccountScene)?.update(email: email, animated: currentID == .account)
    }

    /// One-shot celebration on the finish scene.
    func celebrate() {
        (scenes[.finish] as? FinishScene)?.celebrate()
    }

    // MARK: - Harness seams

    var probeCamera: CALayer { camera }
    func probeScene(_ id: SceneID) -> OnboardingScene? { scenes[id] }
    var probeWallpaper: OnboardingWallpaper { wallpaper }
}

// MARK: - Wallpaper

/// The stage's "image": a vivid mesh-style gradient — a deep two-tone base,
/// four large soft colour fields drifting and breathing on long, co-prime
/// loops (so the composition never visibly repeats), a vignette for depth,
/// and fine film grain so it reads as a photograph rather than a CSS
/// gradient. Palettes morph per step instead of cutting.
@MainActor
final class OnboardingWallpaper {
    struct Palette {
        var base: [NSColor]
        var fields: [NSColor]
    }

    let layer = CALayer()
    private let base = CAGradientLayer()
    private let fields: [CAGradientLayer] = (0..<4).map { _ in CAGradientLayer() }
    private let vignette = CAGradientLayer()
    private let grain = CALayer()
    private var paletteID: OnboardingStageView.SceneID = .welcome

    /// Field placement as fractions of the stage — centre x/y + diameter
    /// relative to the longer side. Asymmetric on purpose.
    private let spots: [(x: CGFloat, y: CGFloat, d: CGFloat)] = [
        (0.10, 0.86, 1.10), (0.92, 0.70, 0.95), (0.70, 0.06, 1.15), (0.18, 0.16, 0.85),
    ]
    private let drifts: [(dx: CGFloat, dy: CGFloat, period: Double)] = [
        (0.10, -0.07, 17), (-0.09, -0.06, 13), (-0.08, 0.09, 19), (0.09, 0.07, 11),
    ]

    init() {
        layer.addSublayer(base)
        for field in fields {
            field.type = .radial
            field.startPoint = CGPoint(x: 0.5, y: 0.5)
            field.endPoint = CGPoint(x: 1, y: 1)
            field.locations = [0, 0.42, 1]
            layer.addSublayer(field)
        }
        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1, y: 1)
        vignette.locations = [0, 0.58, 1]
        layer.addSublayer(vignette)
        grain.backgroundColor = Self.grainPattern
        layer.addSublayer(grain)
        base.startPoint = CGPoint(x: 0.2, y: 1)
        base.endPoint = CGPoint(x: 0.8, y: 0)
    }

    func layout(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        base.frame = bounds
        grain.frame = bounds
        // Oversized so the corners fall INSIDE the vignette ellipse.
        vignette.frame = bounds.insetBy(dx: -bounds.width * 0.25, dy: -bounds.height * 0.25)
        let side = max(bounds.width, bounds.height)
        for (field, spot) in zip(fields, spots) {
            let d = side * spot.d
            field.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            field.position = CGPoint(x: bounds.width * spot.x, y: bounds.height * spot.y)
        }
        CATransaction.commit()
        restartDrift(side: side)
    }

    private var driftSide: CGFloat = 0

    private func restartDrift(side: CGFloat) {
        guard side > 0, abs(side - driftSide) > 1 else { return }
        driftSide = side
        for (index, (field, drift)) in zip(fields, drifts).enumerated() {
            field.removeAnimation(forKey: "wallpaper.drift")
            field.removeAnimation(forKey: "wallpaper.breathe")
            guard !RecordingMotion.reduceMotion else { continue }
            let move = CABasicAnimation(keyPath: "transform.translation")
            move.fromValue = NSValue(size: .zero)
            move.toValue = NSValue(size: NSSize(width: side * drift.dx, height: side * drift.dy))
            move.duration = drift.period
            move.autoreverses = true
            move.repeatCount = .infinity
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Offset phases so the fields never breathe in unison.
            move.timeOffset = drift.period * Double(index) * 0.37
            field.add(move, forKey: "wallpaper.drift")

            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1.0
            breathe.toValue = 1.14
            breathe.duration = drift.period * 0.77
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.timeOffset = breathe.duration * Double(index) * 0.5
            field.add(breathe, forKey: "wallpaper.breathe")
        }
    }

    func applyTheme() {
        setPalette(for: paletteID, animated: false)
        let dark = CCTheme.isDark
        vignette.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(dark ? 0.42 : 0.16).cgColor,
        ]
        grain.opacity = dark ? 0.55 : 0.4
    }

    func setPalette(for id: OnboardingStageView.SceneID, animated: Bool) {
        paletteID = id
        let palette = Self.palette(for: id, dark: CCTheme.isDark)
        let baseColors = palette.base.map(\.cgColor)
        if animated {
            CCMotion.fade(base, keyPath: "colors", to: baseColors, duration: 0.9)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            base.colors = baseColors
            CATransaction.commit()
        }
        for (field, color) in zip(fields, palette.fields) {
            let colors = [
                color.withAlphaComponent(0.92).cgColor,
                color.withAlphaComponent(0.46).cgColor,
                color.withAlphaComponent(0).cgColor,
            ]
            if animated {
                CCMotion.fade(field, keyPath: "colors", to: colors, duration: 0.9)
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                field.colors = colors
                CATransaction.commit()
            }
        }
    }

    // MARK: Palettes

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func palette(for id: OnboardingStageView.SceneID, dark: Bool) -> Palette {
        let dark_: Palette
        switch id {
        case .welcome:
            dark_ = Palette(base: [hex(0x1A1045), hex(0x0B0A22)],
                            fields: [hex(0x7B5CFF), hex(0xFF5FA8), hex(0x3C8BFF), hex(0x22D3EE)])
        case .permissions:
            dark_ = Palette(base: [hex(0x06303A), hex(0x07141F)],
                            fields: [hex(0x14B8A6), hex(0x3B82F6), hex(0x5EEAD4), hex(0x818CF8)])
        case .account:
            dark_ = Palette(base: [hex(0x34112A), hex(0x150A18)],
                            fields: [hex(0xFF7A59), hex(0xF43F5E), hex(0xFBBF24), hex(0xC084FC)])
        case .shortcut:
            dark_ = Palette(base: [hex(0x07301F), hex(0x06140F)],
                            fields: [hex(0x34D399), hex(0x0EA5E9), hex(0xA3E635), hex(0x2DD4BF)])
        case .finish:
            dark_ = Palette(base: [hex(0x1E1150), hex(0x0B0820)],
                            fields: [hex(0x8B5CF6), hex(0xEC4899), hex(0xF59E0B), hex(0x38BDF8)])
        }
        guard !dark else { return dark_ }
        // Light theme: the same hues, lifted into a luminous pastel.
        func lift(_ c: NSColor, _ amount: CGFloat) -> NSColor { c.blended(withFraction: amount, of: .white) ?? c }
        return Palette(base: dark_.base.map { lift($0, 0.80) },
                       fields: dark_.fields.map { lift($0, 0.18) })
    }

    /// 96×96 tile of monochrome speckle, drawn once and tiled as a pattern
    /// colour — resolution-independent film grain, no full-size bitmap.
    private static let grainPattern: CGColor = {
        let side = 96
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)
        if let rep, let data = rep.bitmapData {
            var seed: UInt32 = 0x9E3779B9
            for i in 0..<(side * side) {
                // xorshift — deterministic grain, identical every launch.
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let bright = seed & 1 == 0
                let alpha = UInt8((seed >> 8) % 26)            // 0…25 of 255
                let v: UInt8 = bright ? alpha : 0              // premultiplied
                data[i * 4] = v
                data[i * 4 + 1] = v
                data[i * 4 + 2] = v
                data[i * 4 + 3] = alpha
            }
        }
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        if let rep { image.addRepresentation(rep) }
        return NSColor(patternImage: image).cgColor
    }()

    // MARK: Harness seams

    var probeFields: [CAGradientLayer] { fields }
    var probeBase: CAGradientLayer { base }
}

// MARK: - Scene base + drawing kit

/// One stage scene. `layer` rides inside the camera (zooms with it);
/// `overlay` floats above (captions). `start` arms the frame-locked loops,
/// `stop` removes them; `enter` plays the one-shot arrival choreography.
@MainActor
class OnboardingScene {
    var id: OnboardingStageView.SceneID = .welcome
    let layer = CALayer()
    let overlay = CALayer()
    private(set) var isRunning = false

    func layout(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        overlay.frame = bounds
        layoutContent(in: bounds)
        CATransaction.commit()
    }

    /// Subclasses place their layers (stage coords, Y-up).
    func layoutContent(in bounds: CGRect) {}
    func applyTheme() {}
    func enter(animated: Bool) {}

    /// Arm the loops. `t0` is shared by every animation of the scene so
    /// they stay frame-locked; the camera is handed in for the welcome demo.
    final func start(camera: CALayer, delay: TimeInterval) {
        isRunning = true
        guard !RecordingMotion.reduceMotion else {
            showStaticFrame()
            return
        }
        let t0 = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        startLoops(t0: t0, camera: camera)
    }

    final func stop() {
        isRunning = false
        stopLoops()
    }

    func startLoops(t0: CFTimeInterval, camera: CALayer) {}
    /// Reduce Motion: a representative still, no loops.
    func showStaticFrame() {}

    /// Every loop is registered here so `stop` can remove exactly what
    /// `start` added — including the camera track the welcome scene owns.
    private var loops: [(layer: CALayer, key: String)] = []

    final func addLoop(_ animation: CAAnimation, to target: CALayer, key: String) {
        target.add(animation, forKey: key)
        loops.append((target, key))
    }

    func stopLoops() {
        for loop in loops { loop.layer.removeAnimation(forKey: loop.key) }
        loops.removeAll()
    }
}

/// Frame-locked keyframe loops and the stage's small drawing vocabulary.
@MainActor
enum Stage {
    /// A looping keyframe track: `frames` are (seconds, value); the track is
    /// padded to [0, period]. `curves` (one per segment AFTER padding, or a
    /// single curve for all) shapes each hop — holds are unaffected.
    static func track(
        _ keyPath: String,
        _ frames: [(Double, Any)],
        period: Double,
        curve: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut),
        t0: CFTimeInterval
    ) -> CAKeyframeAnimation {
        var frames = frames
        if let first = frames.first, first.0 > 0 { frames.insert((0, first.1), at: 0) }
        if let last = frames.last, last.0 < period { frames.append((period, last.1)) }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = frames.map(\.1)
        animation.keyTimes = frames.map { NSNumber(value: min(1, max(0, $0.0 / period))) }
        animation.timingFunctions = Array(repeating: curve, count: max(frames.count - 1, 1))
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = t0
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Segment-precise variant: `curves` has one entry per hop between the
    /// GIVEN frames (padding hops at either end run linear).
    static func track(
        _ keyPath: String,
        _ frames: [(Double, Any)],
        period: Double,
        curves: [CAMediaTimingFunction],
        t0: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = track(keyPath, frames, period: period, t0: t0)
        var timing = curves
        let linear = CAMediaTimingFunction(name: .linear)
        if let first = frames.first, first.0 > 0 { timing.insert(linear, at: 0) }
        if let last = frames.last, last.0 < period { timing.append(linear) }
        let needed = max((animation.values?.count ?? 1) - 1, 1)
        while timing.count < needed { timing.append(linear) }
        animation.timingFunctions = Array(timing.prefix(needed))
        return animation
    }

    /// One-shot arrival: animates `keyPath` from → to after `delay`, holding
    /// the `from` value until it starts (fill backwards). Sets the model to
    /// `to` so the layer rests there afterwards. `additive` animates an
    /// offset on top of the model value instead (model untouched).
    static func oneShot(
        _ layer: CALayer, _ keyPath: String, from: Any?, to: Any?,
        duration: Double, delay: Double = 0,
        curve: CAMediaTimingFunction = CCMotion.settle, additive: Bool = false
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = CCMotion.paced(duration)
        animation.timingFunction = curve
        animation.isAdditive = additive
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
        if !additive {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(to, forKeyPath: keyPath)
            CATransaction.commit()
        }
        layer.add(animation, forKey: "stage.oneShot.\(keyPath)")
    }

    /// Delayed spring arrival (CCMotion's spring constants + a start delay).
    static func spring(
        _ layer: CALayer, _ keyPath: String, from: Any?, to: Any?,
        _ spring: CCMotion.Spring = .smooth, delay: Double = 0
    ) {
        let animation = CCMotion.springAnimation(keyPath: keyPath, spring)
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(to, forKeyPath: keyPath)
        CATransaction.commit()
        layer.add(animation, forKey: "stage.spring.\(keyPath)")
    }

    /// Gentle idle float: an ADDITIVE ±`amount` bob on position.y, so it
    /// composes with any transform or arrival animation on the same layer.
    static func bob(amount: CGFloat, period: Double, phase: Double = 0, t0: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "position.y")
        animation.fromValue = -amount
        animation.toValue = amount
        animation.isAdditive = true
        animation.duration = period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = t0
        animation.timeOffset = period * phase
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    static func rect(_ frame: CGRect, radius: CGFloat, color: NSColor? = nil) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.backgroundColor = color?.cgColor
        return layer
    }

    static func text(
        _ string: String, size: CGFloat, weight: NSFont.Weight = .medium,
        color: NSColor = .white, alignment: CATextLayerAlignmentMode = .left,
        monospacedDigits: Bool = false
    ) -> CATextLayer {
        let layer = CATextLayer()
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        layer.font = font
        layer.fontSize = size
        layer.string = string
        layer.foregroundColor = color.cgColor
        layer.alignmentMode = alignment
        // Oversampled: the welcome camera zooms these ~1.9×.
        layer.contentsScale = 4
        layer.truncationMode = .end
        let width = ceil((string as NSString).size(withAttributes: [.font: font]).width) + 2
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: ceil(font.ascender - font.descender))
        return layer
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold,
                       color: NSColor) -> CALayer {
        let layer = CALayer()
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            layer.contents = image
            layer.bounds = CGRect(origin: .zero, size: image.size)
        }
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = 4
        return layer
    }

    /// A drop shadow that follows a rounded rect cheaply (explicit path).
    static func castShadow(_ layer: CALayer, radius: CGFloat, blur: CGFloat = 22,
                           opacity: Float = 0.45, dy: CGFloat = -12) {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = blur
        layer.shadowOffset = CGSize(width: 0, height: dy)
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: radius,
                                  cornerHeight: radius, transform: nil)
    }

    /// The macOS arrow cursor as a vector (tip at the layer's anchor point),
    /// black body with a white keyline — cursor is CONTENT, never themed.
    static func cursor(height: CGFloat = 20) -> CAShapeLayer {
        let s = height / 20
        let w = 14 * s
        // Designed Y-down with the tip at (1,1); flipped into Y-up here.
        let points: [CGPoint] = [
            CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 17), CGPoint(x: 5.1, y: 13.4),
            CGPoint(x: 7.7, y: 19.2), CGPoint(x: 10.3, y: 18.1), CGPoint(x: 7.7, y: 12.4),
            CGPoint(x: 12.9, y: 12.4),
        ].map { CGPoint(x: $0.x * s, y: (20 - $0.y) * s) }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: height)
        layer.path = path
        layer.fillColor = NSColor.black.cgColor
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = 1.3 * s
        layer.lineJoin = .round
        layer.contentsScale = 4
        // Anchor ON the tip so position == hotspot.
        layer.anchorPoint = CGPoint(x: 1 * s / w, y: (19 * s) / height)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: -1)
        return layer
    }

    /// Click ripple ring centred on its position.
    static func ripple(diameter: CGFloat = 34, color: NSColor = .white) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.path = CGPath(ellipseIn: layer.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        layer.fillColor = color.withAlphaComponent(0.18).cgColor
        layer.strokeColor = color.withAlphaComponent(0.9).cgColor
        layer.lineWidth = 2
        layer.opacity = 0
        layer.contentsScale = 4
        return layer
    }

    /// The CaptureCat mark from the traced vector regions (same geometry as
    /// CaptureCatMarkView), as a plain layer tree sized to `height`.
    static func mark(height: CGFloat) -> CALayer {
        let art = CaptureCatMarkView.artSize
        let holder = CALayer()
        holder.bounds = CGRect(x: 0, y: 0, width: height * art.width / art.height, height: height)
        let container = CALayer()
        var toLocal = CGAffineTransform(a: 0.1, b: 0, c: 0, d: 0.1, tx: -148, ty: -102)
        for region in CaptureCatMarkPaths.regions {
            let shape = CAShapeLayer()
            shape.path = SVGPathParser.path(from: region.data)?.copy(using: &toLocal)
            shape.fillColor = region.color.cgColor
            shape.fillRule = .nonZero
            container.addSublayer(shape)
        }
        let scale = height / art.height
        container.bounds = CGRect(origin: .zero, size: art)
        container.anchorPoint = .zero
        container.position = .zero
        container.transform = CATransform3DMakeScale(scale, scale, 1)
        holder.addSublayer(container)
        return holder
    }

    static func setFrame(_ layer: CALayer, _ frame: CGRect) {
        // Frame via bounds + position so transforms never skew placement.
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(
            x: frame.minX + frame.width * layer.anchorPoint.x,
            y: frame.minY + frame.height * layer.anchorPoint.y)
    }

    /// Scale by `s` about stage point `p`, for a layer anchored at `center`.
    static func zoom(_ s: CGFloat, about p: CGPoint, center c: CGPoint) -> CATransform3D {
        let t = CGPoint(x: (p.x - c.x) * (1 - s), y: (p.y - c.y) * (1 - s))
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                   CATransform3DMakeTranslation(t.x, t.y, 0))
    }
}

/// A theme-following mock app window (the "recording" in the demos): title
/// bar with traffic lights, a sidebar, a heading, a primary button and a
/// grid of cards. Pure CALayers — rectangles stay razor sharp under the
/// camera's zoom.
@MainActor
final class MockAppWindow {
    let layer = CALayer()           // shadow host (explicit shadowPath)
    private let body = CALayer()    // clips the chrome to the rounded shape
    private let titlebar = CALayer()
    private let lights: [CALayer] = (0..<3).map { _ in CALayer() }
    private let titleBar = CALayer()
    private let sidebar = CALayer()
    private var sidebarRows: [CALayer] = []
    private let sidebarSelection = CALayer()
    private let heading = CALayer()
    private let subheading = CALayer()
    let button = CALayer()
    private let buttonLabel = Stage.text("Publish", size: 9.5, weight: .semibold, alignment: .center)
    private(set) var cards: [CALayer] = []
    private var cardDots: [CALayer] = []
    private var cardLines: [CALayer] = []
    private var bars: [CALayer] = []
    /// Accent ring shown on a card when the demo "selects" it.
    let cardHighlight = CALayer()

    private(set) var size: CGSize = .zero

    init() {
        body.masksToBounds = true
        body.cornerCurve = .continuous
        layer.addSublayer(body)
        body.addSublayer(sidebar)
        body.addSublayer(titlebar)
        for light in lights { titlebar.addSublayer(light) }
        titlebar.addSublayer(titleBar)
        sidebar.addSublayer(sidebarSelection)
        for _ in 0..<5 {
            let row = CALayer()
            row.cornerCurve = .continuous
            sidebar.addSublayer(row)
            sidebarRows.append(row)
        }
        body.addSublayer(heading)
        body.addSublayer(subheading)
        body.addSublayer(button)
        button.addSublayer(buttonLabel)
        for _ in 0..<4 {
            let card = CALayer()
            card.cornerCurve = .continuous
            body.addSublayer(card)
            cards.append(card)
            let dot = CALayer()
            card.addSublayer(dot)
            cardDots.append(dot)
            for _ in 0..<2 {
                let line = CALayer()
                card.addSublayer(line)
                cardLines.append(line)
            }
        }
        for _ in 0..<6 {
            let bar = CALayer()
            bar.cornerCurve = .continuous
            cards[0].addSublayer(bar)
            bars.append(bar)
        }
        cardHighlight.borderWidth = 1.5
        cardHighlight.cornerCurve = .continuous
        cardHighlight.opacity = 0
        body.addSublayer(cardHighlight)
    }

    /// Lay the window out at `frame` (stage coords, Y-up).
    func layout(frame: CGRect) {
        size = frame.size
        Stage.setFrame(layer, frame)
        let w = frame.width, h = frame.height
        let radius = min(12, w * 0.03)
        body.frame = CGRect(origin: .zero, size: frame.size)
        body.cornerRadius = radius
        Stage.castShadow(layer, radius: radius, blur: max(14, w * 0.05), opacity: 0.5, dy: -w * 0.03)

        let tb = max(18, h * 0.095)
        titlebar.frame = CGRect(x: 0, y: h - tb, width: w, height: tb)
        let lightD = tb * 0.36
        for (i, light) in lights.enumerated() {
            light.frame = CGRect(x: tb * 0.5 + CGFloat(i) * lightD * 1.55,
                                 y: (tb - lightD) / 2, width: lightD, height: lightD)
            light.cornerRadius = lightD / 2
        }
        titleBar.frame = CGRect(x: w / 2 - w * 0.09, y: tb / 2 - 2.5, width: w * 0.18, height: 5)
        titleBar.cornerRadius = 2.5

        let sw = w * 0.26
        sidebar.frame = CGRect(x: 0, y: 0, width: sw, height: h - tb)
        let rowH = max(5, h * 0.026)
        let rowWidths: [CGFloat] = [0.58, 0.72, 0.5, 0.64, 0.46]
        var y = h - tb - rowH - h * 0.08
        for (i, row) in sidebarRows.enumerated() {
            row.frame = CGRect(x: sw * 0.14, y: y, width: sw * rowWidths[i] * 0.86, height: rowH)
            row.cornerRadius = rowH / 2
            if i == 1 {
                sidebarSelection.frame = CGRect(x: sw * 0.07, y: y - rowH * 0.9,
                                                width: sw * 0.86, height: rowH * 2.8)
                sidebarSelection.cornerRadius = rowH * 0.9
            }
            y -= rowH * 3.2
        }

        let mx = sw + w * 0.045
        let mw = w - mx - w * 0.045
        let headH = max(7, h * 0.042)
        let headY = h - tb - h * 0.11
        heading.frame = CGRect(x: mx, y: headY, width: mw * 0.36, height: headH)
        heading.cornerRadius = headH / 2
        subheading.frame = CGRect(x: mx, y: headY - headH * 1.35, width: mw * 0.52, height: headH * 0.62)
        subheading.cornerRadius = headH * 0.31
        let bw = max(46, w * 0.15), bh = max(16, h * 0.085)
        button.frame = CGRect(x: w - w * 0.045 - bw, y: headY + headH / 2 - bh / 2 - headH * 0.2,
                              width: bw, height: bh)
        button.cornerRadius = bh * 0.3
        button.cornerCurve = .continuous
        buttonLabel.fontSize = bh * 0.5
        buttonLabel.font = NSFont.systemFont(ofSize: bh * 0.5, weight: .semibold)
        buttonLabel.bounds = CGRect(x: 0, y: 0, width: bw, height: ceil(bh * 0.62))
        buttonLabel.position = CGPoint(x: bw / 2, y: bh / 2 - 0.5)

        let gap = w * 0.03
        let gridTop = headY - headH * 2.4
        let cw = (mw - gap) / 2
        let ch = (gridTop - h * 0.06 - gap) / 2
        for (i, card) in cards.enumerated() {
            let col = CGFloat(i % 2), row = CGFloat(i / 2)
            card.frame = CGRect(x: mx + col * (cw + gap), y: gridTop - (row + 1) * ch - row * gap,
                                width: cw, height: ch)
            card.cornerRadius = min(8, ch * 0.16)
            let dotD = max(8, ch * 0.2)
            cardDots[i].frame = CGRect(x: cw * 0.08, y: ch - dotD - ch * 0.14, width: dotD, height: dotD)
            cardDots[i].cornerRadius = dotD / 2
            cardLines[i * 2].frame = CGRect(x: cw * 0.08 + dotD + cw * 0.05, y: ch - ch * 0.14 - dotD * 0.62,
                                            width: cw * 0.44, height: max(4, ch * 0.08))
            cardLines[i * 2 + 1].frame = CGRect(x: cw * 0.08, y: ch * 0.2, width: cw * 0.66,
                                                height: max(3.5, ch * 0.065))
            for line in [cardLines[i * 2], cardLines[i * 2 + 1]] { line.cornerRadius = line.frame.height / 2 }
            cardDots[i].isHidden = i == 0
            cardLines[i * 2].isHidden = i == 0
            cardLines[i * 2 + 1].isHidden = i == 0
        }
        // Card 0 is a little bar chart.
        let chart = cards[0].frame
        let heights: [CGFloat] = [0.34, 0.52, 0.42, 0.7, 0.58, 0.82]
        let barW = chart.width * 0.08
        for (i, bar) in bars.enumerated() {
            let bhh = chart.height * 0.72 * heights[i]
            bar.frame = CGRect(x: chart.width * 0.1 + CGFloat(i) * barW * 1.75, y: chart.height * 0.14,
                               width: barW, height: bhh)
            bar.cornerRadius = min(barW / 2, 3)
        }
        cardHighlight.frame = cards[2].frame.insetBy(dx: -2, dy: -2)
        cardHighlight.cornerRadius = cards[2].cornerRadius + 2
    }

    func applyTheme() {
        let colors = CCTheme.color
        let dark = CCTheme.isDark
        let ink: NSColor = dark ? .white : .black
        body.backgroundColor = colors.card.cgColor
        body.borderWidth = 0.5
        body.borderColor = ink.withAlphaComponent(dark ? 0.10 : 0.12).cgColor
        titlebar.backgroundColor = colors.elevated.cgColor
        let lightColors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        for (light, color) in zip(lights, lightColors) { light.backgroundColor = color.cgColor }
        titleBar.backgroundColor = ink.withAlphaComponent(0.14).cgColor
        sidebar.backgroundColor = colors.background.cgColor
        sidebarSelection.backgroundColor = colors.primary.withAlphaComponent(0.22).cgColor
        for (i, row) in sidebarRows.enumerated() {
            row.backgroundColor = (i == 1 ? colors.primary : ink.withAlphaComponent(0.16)).cgColor
        }
        heading.backgroundColor = ink.withAlphaComponent(0.72).cgColor
        subheading.backgroundColor = ink.withAlphaComponent(0.22).cgColor
        button.backgroundColor = colors.primary.cgColor
        buttonLabel.foregroundColor = colors.primaryForeground.cgColor
        let dotColors: [NSColor] = [.clear, .systemPink, .systemOrange, .systemTeal]
        for (i, card) in cards.enumerated() {
            card.backgroundColor = colors.elevated.cgColor
            cardDots[i].backgroundColor = dotColors[i].cgColor
        }
        for line in cardLines { line.backgroundColor = ink.withAlphaComponent(0.2).cgColor }
        for (i, bar) in bars.enumerated() {
            bar.backgroundColor = colors.primary.withAlphaComponent(i == bars.count - 1 ? 1 : 0.55).cgColor
        }
        cardHighlight.borderColor = colors.primary.cgColor
    }

    /// Centre of a sublayer in STAGE coordinates.
    func stagePoint(of sub: CALayer) -> CGPoint {
        let f = layer.frame
        let local = sub.superlayer === body ? sub.frame
            : sub.superlayer.map { body.convert(sub.frame, from: $0) } ?? sub.frame
        return CGPoint(x: f.minX + local.midX, y: f.minY + local.midY)
    }
}
