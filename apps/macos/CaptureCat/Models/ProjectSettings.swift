import AppKit

@Observable
final class ProjectSettings: Codable {
    // Background
    var backgroundType: BackgroundType = .gradient
    var gradientStartColor: CodableColor = CodableColor(NSColor.systemPurple)
    var gradientEndColor: CodableColor = CodableColor(NSColor.systemBlue)
    var solidColor: CodableColor = CodableColor(NSColor.black)
    var backgroundImagePath: String?
    var backgroundPadding: Double = 48
    var videoPlacement: VideoPlacement = .center
    /// Freeform card position — normalized alignment fractions (0…1, Y-DOWN,
    /// preview convention). When set they override `videoPlacement`; dropping
    /// the card near a grid anchor collapses back to the enum and nils these
    /// (same pattern as `cameraCustomX/Y`).
    var videoCustomX: Double?
    var videoCustomY: Double?
    var cornerRadius: Double = 12
    var windowCornerRadius: Double = 8
    var frameShape: FrameShape = .roundedRect
    var shadowRadius: Double = 20
    var shadowOpacity: Double = 0.5

    // Background look — see BackgroundLook (shared by preview + export).
    /// Gradient direction in degrees (CSS convention, 90° = left→right).
    /// nil keeps the legacy corner-to-corner diagonal of older projects.
    var gradientAngle: Double?
    /// Frosted-backdrop blur strength, 0…1.
    var backgroundBlur: Double = 0
    /// -1…1, 0 = unchanged.
    var backgroundBrightness: Double = 0
    /// 0…2, 1 = unchanged.
    var backgroundSaturation: Double = 1
    /// Overlay colour blended on top at `backgroundTintOpacity` (0 = off).
    var backgroundTintColor: CodableColor = CodableColor(red: 0, green: 0, blue: 0)
    var backgroundTintOpacity: Double = 0
    /// Edge darkening, 0…1.
    var backgroundVignette: Double = 0
    /// Mosaic block size, 0…1 (0 = off).
    var backgroundPixelate: Double = 0
    /// Halftone dot screen, 0…1 (0 = off).
    var backgroundHalftone: Double = 0
    /// Film-grain noise, 0…1.
    var backgroundNoise: Double = 0
    /// 0.5…1.5, 1 = unchanged.
    var backgroundContrast: Double = 1
    /// Hue rotation in degrees, 0 = unchanged.
    var backgroundHue: Double = 0

    // Cursor
    var showCursor: Bool = true
    /// Which pointer artwork is drawn over the recording.
    var cursorStyle: CursorStyle = .system
    var cursorScale: Double = 1.5
    /// OFF by default.
    ///
    /// This hides the cursor whenever it moves less than 5pt across the delay
    /// window. It used to fire rarely — not by design, but because the cursor
    /// path was smoothed by a filter that was still converging, so consecutive
    /// positions always differed slightly. With positions now recorded and
    /// drawn exactly, a genuinely still mouse measures 0 movement and the
    /// cursor vanishes: most often right after a click, which is exactly when
    /// the viewer is looking for it.
    var autoHideCursor: Bool = false
    var autoHideDelay: Double = 3.0
    /// OFF by default: the drawn cursor must sit exactly where the user's
    /// cursor was.
    ///
    /// Any smoothing moves the pointer off the thing it clicked, and a pointer
    /// that is near the button rather than on it is worse than a slightly
    /// jittery one — it makes the viewer doubt what they just watched. The
    /// filter is still available for anyone who wants it, and it is now
    /// zero-lag (see CursorSmoother), but the default is exact.
    ///
    /// Existing projects keep whatever they stored; this only changes new ones.
    var smoothCursor: Bool = false
    var smoothingFactor: Double = 0.15
    /// Cursor motion physics — all OFF by default (identity pose), so existing
    /// projects render exactly as before. The pose is a pure function of the
    /// timeline clock and the recorded path (CursorPhysicsMath), and it NEVER
    /// moves the hotspot: the tip stays on the recorded point; the sprite's
    /// body leans, squashes, and trails around it.
    /// 0…1 — how far the sprite leans into horizontal motion.
    var cursorTilt: Double = 0
    /// 0…1 — squash-and-stretch along the motion direction.
    var cursorStretch: Double = 0
    /// 0…1 — how far the body trails behind the (pinned) tip while moving.
    var cursorDrag: Double = 0
    /// 0.5…3 — inertia multiplier applied to tilt/stretch/drag response.
    var cursorWeight: Double = 1.0
    /// Fluid movement — a damped spring chases the recorded path
    /// (CursorSpringMath). ON by default; clicks stay pinned regardless.
    var cursorFluidEnabled: Bool = true
    /// Pull toward the recorded position (acceleration).
    var cursorTension: Double = 220
    /// Velocity damping (how quickly motion settles).
    var cursorFriction: Double = 24
    /// Inertia — momentum, overshoot, wiggle.
    var cursorMass: Double = 1.0
    /// End-of-clip behaviors: glide back to the start position for seamless
    /// loops, or freeze in the final half second.
    var cursorLoopToStart: Bool = false
    var cursorStopAtEnd: Bool = false
    var showClickRipple: Bool = true
    /// Synthesized click tick played at recorded clicks (preview + export).
    var clickSoundEnabled: Bool = false
    var clickSoundVolume: Double = 0.7
    var clickSoundStyle: ClickSoundStyle = .softTick
    /// Synthesized keystroke sounds at recorded typing moments.
    var keySoundEnabled: Bool = false
    var keySoundVolume: Double = 0.6
    var keySoundStyle: KeySoundStyle = .thock
    /// On-screen shortcut pill ("⌘⇧S") at recorded shortcut moments. Only
    /// renders when the recording captured shortcut identity (opt-in at
    /// record time); this switch hides/shows what was captured.
    var showKeystrokes: Bool = true
    var keystrokeOverlaySize: Double = 1.0
    var keystrokeOverlayPosition: KeystrokeOverlayPosition = .bottomCenter
    var keystrokeOverlayAnimation: KeystrokeOverlayAnimation = .slideUp
    /// Window/app recordings only: show just the shortcuts delivered to the
    /// RECORDED app, hiding ones typed into other apps mid-recording. Applied
    /// at render time (KeystrokeOverlayMath.scopedEvents) so it's reversible.
    var keystrokeOverlayScopeToRecordedApp: Bool = true
    var clickRippleColor: CodableColor = CodableColor(NSColor.white)
    var clickRippleSize: Double = 40

    // Camera
    var showCamera: Bool = false
    var cameraPosition: CameraPosition = .bottomRight
    /// Free camera placement (normalized 0…1 across the usable content area,
    /// Y-down). nil = snap to `cameraPosition`'s corner. Set by dragging the
    /// bubble on the preview or the pad; the corner menu clears it.
    var cameraCustomX: Double?
    var cameraCustomY: Double?
    var cameraSize: Double = 120
    /// Renderer-facing size: projects saved when the slider allowed 60pt come
    /// back up to the current 120pt floor — below it the bubble is a dot.
    var effectiveCameraSize: Double { max(120, cameraSize) }
    var cameraShape: CameraShape = .circle
    /// Bubble orientation for the aspect-following shapes (squircle and
    /// rounded rect): Auto = per-shape logic, Vertical = portrait 4:5 tile,
    /// Wide = landscape cap. Circle/square are always 1:1 regardless.
    var cameraOrientation: CameraOrientation = .auto
    var cameraMirrored: Bool = false
    // Camera color adjustments — all defaults are IDENTITY so existing
    // projects render exactly as before. Mapping to CIFilter inputs lives
    // ONLY in CameraStyleMath (shared by preview + exporter).
    var cameraBrightness: Double = 0        // −1…1
    var cameraContrast: Double = 1          // 0.5…1.5
    var cameraSaturation: Double = 1        // 0…2
    var cameraHue: Double = 0               // −180…180 degrees
    var cameraFilter: CameraFilterStyle = .none
    /// Soft warm inner glow just inside the bubble edge (0 = off).
    var cameraRingLight: Double = 0
    /// Corner radius used by the rounded-rect camera shape (points on the
    /// nominal canvas). 12 was the historical hardcoded value.
    var cameraCornerRadius: Double = 12
    /// Bubble border width (0…8). 2 was the historical hardcoded value.
    var cameraBorderWidth: Double = 2
    /// nil = the historical white 30% stroke.
    var cameraBorderColor: CodableColor?
    /// Whole-bubble opacity (0.2…1) — camera, border, shadow and tag together.
    var cameraOpacity: Double = 1
    /// 3D perspective tilt of the whole bubble (video + border + ring + tag),
    /// degrees, ±25. Same TiltMath homography as the screen tilt — preview
    /// CATransform3D and export CIPerspectiveTransform share the projection.
    var cameraTiltPitch: Double = 0
    var cameraTiltYaw: Double = 0
    // Name tag — a rounded pill riding the camera bubble. Hidden while
    // `cameraTagText` is empty.
    var cameraTagText: String = ""
    var cameraTagSubtext: String = ""
    /// nil = system semibold (see CameraStyleMath.tagFont).
    var cameraTagFontName: String?
    var cameraTagTextColor: CodableColor = CodableColor(NSColor.white)
    var cameraTagBackgroundColor: CodableColor = CodableColor(red: 0, green: 0, blue: 0, opacity: 0.55)
    var cameraTagPosition: CameraTagPosition = .below
    /// Draw the recording inside a realistic device bezel (iPhone/iPad takes).
    var showDeviceFrame: Bool = true

    // Brand watermark — a user logo burned into preview and export.
    var showWatermark: Bool = false
    /// File name inside the project folder (image copied there on pick, so
    /// projects stay self-contained).
    var watermarkFileName: String?
    /// Normalized placement (0…1 origin-interpolation over canvas minus 20pt
    /// edge inset, Y-down). Defaults to bottom-right — the classic spot.
    var watermarkX: Double = 1.0
    var watermarkY: Double = 1.0
    /// Rendered width in canvas points.
    var watermarkSize: Double = 120
    var watermarkOpacity: Double = 0.9
    // Menu bar replacement (display recordings): covers the recorded macOS
    // menu bar with a clean customizable one.
    var menuBarReplacement: MenuBarReplacement = .off
    var menuBarTitle: String = "CaptureCat"
    var menuBarTitleAlignment: MenuBarTitleAlignment = .left
    var menuBarShowStatusIcons: Bool = true
    var menuBarClock: String = "9:41"
    /// Bar height as % of the video height (notch Macs ≈ 3.8, older ≈ 2.6).
    var menuBarHeight: Double = 3.8

    // Audio
    var systemAudioVolume: Double = 1.0
    var microphoneVolume: Double = 1.0
    var voiceOverVolume: Double = 1.0

    // Motion
    var animationSpeed: AnimationSpeed = .mellow
    var motionBlur: Bool = false
    /// Motion blur intensity 0…1 — scales MotionBlurMath's radius cap.
    var motionBlurStrength: Double = 0.5
    /// Background parallax during zooms (0 = off, 1 = full drift) — the
    /// backdrop scales gently with the zoom for depth.
    var parallaxStrength: Double = 0
    var autoZoomLevel: Double = 2.0
    /// How quickly the zoomed camera chases the cursor (0 = weighted and
    /// slow, 1 = tight tracking). 0.5 keeps the historical response.
    var cameraFollowSpeed: Double = 0.5
    /// Card entrance: slides in from an edge with an eased overshoot.
    var introSlideStyle: IntroSlideStyle = .off
    var introSlideDuration: Double = 0.9
    /// Where the slide sits on the timeline (output seconds). 0 = the clip's
    /// entrance; anywhere else = slide-away-and-back at that moment.
    var introSlideStart: Double = 0
    /// Arrival overshoot 0…1 (see IntroSlideMath.easeOutBack).
    var introSlideBounce: Double = 0.5
    /// Slide pace multiplier: 1 = the animation spans the whole block; higher
    /// finishes the slide early and holds settled for the remainder.
    var introSlideSpeed: Double = 1.0
    /// Adds a 3D back-to-front pull to the slide: the card starts small, deep,
    /// and tipped, then dollies toward the viewer as it lands (IntroSlideMath).
    var introSlideDepth: Bool = false
    /// Curtain Unveil: a curtain covers the card and peels away from this
    /// corner, revealing the video (CurtainUnveilMath). `.off` disables it.
    var curtainUnveilCorner: CurtainUnveilCorner = .off
    var curtainUnveilDuration: Double = 1.6
    /// Where the unveil begins on the timeline (output seconds).
    var curtainUnveilStart: Double = 0
    /// Brand logo shown centered on the curtain (peels away with it). Stored
    /// like the watermark: a file name inside the project folder.
    var curtainLogoFileName: String?
    var curtainLogoOpacity: Double = 1.0
    /// Logo width as a fraction of the card width.
    var curtainLogoScale: Double = 0.25
    /// nil = the logo's original colors; non-nil = tint its alpha silhouette.
    var curtainLogoTint: CodableColor?
    /// nil = the default charcoal curtain; non-nil = gradient derived from
    /// this base color (see CurtainUnveilMath.coverStops).
    var curtainColor: CodableColor?
    /// 3D perspective skew of the screen card that settles flat.
    var screenTiltMode: ScreenTiltMode = .off
    /// Vertical tilt (pitch): positive tips the top edge back.
    var screenTiltAngle: Double = 20
    /// Horizontal tilt (yaw): positive tips the left edge back.
    var screenTiltYaw: Double = 0
    /// In-plane rotation: positive rotates clockwise.
    var screenTiltRoll: Double = 0

    // Subtitles
    var showSubtitles: Bool = true
    var subtitleFontSize: Double = 32
    var subtitlePosition: SubtitlePosition = .bottom
    var subtitleStyle: SubtitleStyle = .outline
    /// Free subtitle placement (normalized 0…1 across the canvas' usable
    /// area minus the 20pt edge inset, Y-down, origin-interpolated like the
    /// camera). nil = the `subtitlePosition` anchor (centered horizontally).
    var subtitleCustomX: Double?
    var subtitleCustomY: Double?
    var subtitleWeight: SubtitleWeight = .bold
    /// Typeface family; nil = system font (see FontCatalog).
    var subtitleFontName: String?
    var subtitleUppercase: Bool = false
    var subtitleColor: CodableColor = CodableColor(NSColor.white)
    var subtitleBackgroundColor: CodableColor = CodableColor(NSColor.black)
    var highlightWords: Bool = false
    var subtitleHighlightColor: CodableColor = CodableColor(NSColor.systemYellow)

    // Aspect Ratio
    var aspectRatio: AspectRatio = .widescreen

    // Audio
    var muteRecordedAudio: Bool = false

    // Export
    var exportSettings: ExportSettings = ExportSettings()

    enum BackgroundType: String, CaseIterable, Codable, Sendable {
        case gradient = "Gradient"
        case mesh = "Mesh"
        case solid = "Solid Color"
        case image = "Image"
        case wallpaper = "Wallpaper"
        case transparent = "Transparent"
    }

    enum MenuBarTitleAlignment: String, CaseIterable, Codable, Sendable {
        case left = "Left"
        case center = "Center"
        case right = "Right"
    }

    enum MenuBarReplacement: String, CaseIterable, Codable, Sendable {
        case off = "Original"
        case hidden = "Hidden"
        case dark = "Clean Dark"
        case light = "Clean Light"
    }

    enum CursorStyle: String, CaseIterable, Codable, Sendable {
        case system = "macOS Arrow"
        case inverted = "White Arrow"
        case hand = "Hand"
        case dot = "Dot"
        case ring = "Ring"
    }

    enum CameraPosition: String, CaseIterable, Codable, Sendable {
        case topLeft = "Top Left"
        case topRight = "Top Right"
        case bottomLeft = "Bottom Left"
        case bottomRight = "Bottom Right"
    }

    enum CameraShape: String, CaseIterable, Codable, Sendable {
        case circle = "Circle"
        case squircle = "Squircle"
        case roundedRect = "Rounded Rectangle"
        case square = "Square"
    }

    /// Camera color-look presets. RAW VALUES ARE PERSISTENCE IDENTITY —
    /// never rename one; old projects must always still load.
    enum CameraFilterStyle: String, CaseIterable, Codable, Sendable {
        case none = "None"
        case mono = "Mono"
        case noir = "Noir"
        case warm = "Warm"
        case cool = "Cool"
        case fade = "Fade"
    }

    /// Camera bubble orientation. RAW VALUES ARE PERSISTENCE IDENTITY —
    /// never rename one; old projects must always still load.
    enum CameraOrientation: String, CaseIterable, Codable, Sendable {
        case auto = "Auto"
        case vertical = "Vertical"
        case wide = "Wide"
    }

    /// Name-tag placement relative to the camera bubble. RAW VALUES ARE
    /// PERSISTENCE IDENTITY — never rename one.
    enum CameraTagPosition: String, CaseIterable, Codable, Sendable {
        case below = "Below"
        case above = "Above"
        case overlapBottom = "Overlap Bottom"
    }

    enum SubtitlePosition: String, CaseIterable, Codable, Sendable {
        case top = "Top"
        case center = "Center"
        case bottom = "Bottom"
    }

    enum SubtitleStyle: String, CaseIterable, Codable, Sendable {
        case outline = "Outline"
        case background = "Background"
        case glow = "Glow"
        case plain = "Plain"
    }

    enum SubtitleWeight: String, CaseIterable, Codable, Sendable {
        case regular = "Regular"
        case medium = "Medium"
        case semibold = "Semibold"
        case bold = "Bold"
        case heavy = "Heavy"

        var nsWeight: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            }
        }
    }

    enum VideoPlacement: String, CaseIterable, Codable, Sendable {
        case center = "Center"
        case topLeft = "Top Left"
        case top = "Top"
        case topRight = "Top Right"
        case left = "Left"
        case right = "Right"
        case bottomLeft = "Bottom Left"
        case bottom = "Bottom"
        case bottomRight = "Bottom Right"

    }

    enum FrameShape: String, CaseIterable, Codable, Sendable {
        case roundedRect = "Rounded Rectangle"
        case squircle = "Squircle"
        case rectangle = "Rectangle"
    }

    enum ScreenTiltMode: String, CaseIterable, Codable, Sendable {
        case off = "Off"
        case intro = "Intro"
        case zoomedOut = "Zoomed Out"
        case both = "Both"
    }

    enum AnimationSpeed: String, CaseIterable, Codable, Sendable {
        case slow = "Slow"
        case mellow = "Mellow"
        case quick = "Quick"
        case rapid = "Rapid"

        var duration: Double {
            switch self {
            case .slow: return 1.2
            case .mellow: return 0.8
            case .quick: return 0.5
            case .rapid: return 0.3
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case backgroundType, gradientStartColor, gradientEndColor, solidColor
        case backgroundImagePath, backgroundPadding, videoPlacement, videoCustomX, videoCustomY, cornerRadius, windowCornerRadius, frameShape, shadowRadius, shadowOpacity
        case gradientAngle, backgroundBlur, backgroundBrightness, backgroundSaturation, backgroundTintColor, backgroundTintOpacity, backgroundVignette
        case backgroundPixelate, backgroundHalftone, backgroundNoise, backgroundContrast, backgroundHue
        case showCursor, cursorStyle, cursorScale, autoHideCursor, autoHideDelay, smoothCursor, smoothingFactor
        case cursorTilt, cursorStretch, cursorDrag, cursorWeight
        case cursorFluidEnabled, cursorTension, cursorFriction, cursorMass
        case showClickRipple, clickRippleColor, clickRippleSize
        case cursorLoopToStart, cursorStopAtEnd
        case clickSoundEnabled, clickSoundVolume, clickSoundStyle
        case keySoundEnabled, keySoundVolume, keySoundStyle
        case showKeystrokes, keystrokeOverlaySize, keystrokeOverlayPosition
        case keystrokeOverlayAnimation
        case keystrokeOverlayScopeToRecordedApp
        case showCamera, cameraPosition, cameraCustomX, cameraCustomY, cameraSize, cameraShape, cameraOrientation, cameraMirrored, showDeviceFrame
        case cameraBrightness, cameraContrast, cameraSaturation, cameraHue, cameraFilter, cameraRingLight
        case cameraCornerRadius, cameraBorderWidth, cameraBorderColor, cameraOpacity, cameraTiltPitch, cameraTiltYaw
        case cameraTagText, cameraTagSubtext, cameraTagFontName, cameraTagTextColor, cameraTagBackgroundColor, cameraTagPosition
        case showWatermark, watermarkFileName, watermarkX, watermarkY, watermarkSize, watermarkOpacity
        case menuBarReplacement, menuBarTitle, menuBarTitleAlignment, menuBarShowStatusIcons, menuBarClock, menuBarHeight
        case systemAudioVolume, microphoneVolume, voiceOverVolume
        case animationSpeed, motionBlur, motionBlurStrength, parallaxStrength, autoZoomLevel, screenTiltMode, screenTiltAngle, screenTiltYaw, screenTiltRoll
        case introSlideStyle, introSlideDuration, introSlideStart, introSlideBounce, introSlideSpeed, introSlideDepth, cameraFollowSpeed
        case curtainUnveilCorner, curtainUnveilDuration, curtainUnveilStart
        case curtainLogoFileName, curtainLogoOpacity, curtainLogoScale, curtainLogoTint, curtainColor
        case showSubtitles, subtitleFontSize, subtitlePosition, subtitleStyle
        case subtitleWeight, subtitleUppercase, subtitleCustomX, subtitleCustomY, subtitleFontName
        case subtitleColor, subtitleBackgroundColor, highlightWords, subtitleHighlightColor
        case aspectRatio, muteRecordedAudio, exportSettings
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backgroundType = try c.decode(BackgroundType.self, forKey: .backgroundType)
        gradientStartColor = try c.decode(CodableColor.self, forKey: .gradientStartColor)
        gradientEndColor = try c.decode(CodableColor.self, forKey: .gradientEndColor)
        solidColor = try c.decode(CodableColor.self, forKey: .solidColor)
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        backgroundPadding = try c.decode(Double.self, forKey: .backgroundPadding)
        videoPlacement = try c.decodeIfPresent(VideoPlacement.self, forKey: .videoPlacement) ?? .center
        videoCustomX = try c.decodeIfPresent(Double.self, forKey: .videoCustomX)
        videoCustomY = try c.decodeIfPresent(Double.self, forKey: .videoCustomY)
        cornerRadius = try c.decode(Double.self, forKey: .cornerRadius)
        windowCornerRadius = try c.decodeIfPresent(Double.self, forKey: .windowCornerRadius) ?? 8
        frameShape = try c.decodeIfPresent(FrameShape.self, forKey: .frameShape) ?? .roundedRect
        shadowRadius = try c.decode(Double.self, forKey: .shadowRadius)
        shadowOpacity = try c.decode(Double.self, forKey: .shadowOpacity)
        gradientAngle = try c.decodeIfPresent(Double.self, forKey: .gradientAngle)
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0
        backgroundBrightness = try c.decodeIfPresent(Double.self, forKey: .backgroundBrightness) ?? 0
        backgroundSaturation = try c.decodeIfPresent(Double.self, forKey: .backgroundSaturation) ?? 1
        backgroundTintColor = try c.decodeIfPresent(CodableColor.self, forKey: .backgroundTintColor) ?? CodableColor(red: 0, green: 0, blue: 0)
        backgroundTintOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundTintOpacity) ?? 0
        backgroundVignette = try c.decodeIfPresent(Double.self, forKey: .backgroundVignette) ?? 0
        backgroundPixelate = try c.decodeIfPresent(Double.self, forKey: .backgroundPixelate) ?? 0
        backgroundHalftone = try c.decodeIfPresent(Double.self, forKey: .backgroundHalftone) ?? 0
        backgroundNoise = try c.decodeIfPresent(Double.self, forKey: .backgroundNoise) ?? 0
        backgroundContrast = try c.decodeIfPresent(Double.self, forKey: .backgroundContrast) ?? 1
        backgroundHue = try c.decodeIfPresent(Double.self, forKey: .backgroundHue) ?? 0
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? true
        // Lenient: a project saved with a since-removed style falls back to
        // the system arrow instead of failing the whole project decode.
        cursorStyle = ((try? c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle)) ?? .system) ?? .system
        cursorScale = try c.decode(Double.self, forKey: .cursorScale)
        // Forced off for existing projects too, for the same reason as
        // `smoothCursor` above: the stored `true` came from a default, and it
        // only appeared harmless because the smoothing filter's noise kept the
        // hide condition from ever being met.
        autoHideCursor = false
        _ = try c.decodeIfPresent(Bool.self, forKey: .autoHideCursor)
        autoHideDelay = try c.decode(Double.self, forKey: .autoHideDelay)
        // One-time correction, deliberately ignoring the stored value.
        //
        // `smoothCursor` defaulted to true, so every project ever created has
        // it on — not because anyone chose it, but because that was the
        // default. And it was actively wrong: the filter was causal, so the
        // drawn cursor trailed the real one by up to 564px on a 1492px frame,
        // landing beside the thing it had just clicked.
        //
        // Honouring the stored `true` would leave every existing recording
        // mis-drawn, and the setting is cheap to turn back on, so this forces
        // the accurate default and lets anyone who genuinely wants smoothing
        // re-enable it (it is zero-lag now).
        smoothCursor = false
        _ = try c.decodeIfPresent(Bool.self, forKey: .smoothCursor)
        smoothingFactor = try c.decode(Double.self, forKey: .smoothingFactor)
        cursorTilt = try c.decodeIfPresent(Double.self, forKey: .cursorTilt) ?? 0
        cursorStretch = try c.decodeIfPresent(Double.self, forKey: .cursorStretch) ?? 0
        cursorDrag = try c.decodeIfPresent(Double.self, forKey: .cursorDrag) ?? 0
        cursorWeight = try c.decodeIfPresent(Double.self, forKey: .cursorWeight) ?? 1.0
        cursorFluidEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorFluidEnabled) ?? true
        cursorTension = try c.decodeIfPresent(Double.self, forKey: .cursorTension) ?? 220
        cursorFriction = try c.decodeIfPresent(Double.self, forKey: .cursorFriction) ?? 24
        cursorMass = try c.decodeIfPresent(Double.self, forKey: .cursorMass) ?? 1.0
        showClickRipple = try c.decodeIfPresent(Bool.self, forKey: .showClickRipple) ?? true
        cursorLoopToStart = try c.decodeIfPresent(Bool.self, forKey: .cursorLoopToStart) ?? false
        cursorStopAtEnd = try c.decodeIfPresent(Bool.self, forKey: .cursorStopAtEnd) ?? false
        clickSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .clickSoundEnabled) ?? false
        clickSoundVolume = try c.decodeIfPresent(Double.self, forKey: .clickSoundVolume) ?? 0.7
        clickSoundStyle = ((try? c.decodeIfPresent(ClickSoundStyle.self, forKey: .clickSoundStyle)) ?? .softTick) ?? .softTick
        keySoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .keySoundEnabled) ?? false
        keySoundVolume = try c.decodeIfPresent(Double.self, forKey: .keySoundVolume) ?? 0.6
        keySoundStyle = ((try? c.decodeIfPresent(KeySoundStyle.self, forKey: .keySoundStyle)) ?? .thock) ?? .thock
        showKeystrokes = try c.decodeIfPresent(Bool.self, forKey: .showKeystrokes) ?? true
        keystrokeOverlaySize = try c.decodeIfPresent(Double.self, forKey: .keystrokeOverlaySize) ?? 1.0
        keystrokeOverlayPosition = ((try? c.decodeIfPresent(KeystrokeOverlayPosition.self, forKey: .keystrokeOverlayPosition)) ?? .bottomCenter) ?? .bottomCenter
        keystrokeOverlayAnimation = ((try? c.decodeIfPresent(KeystrokeOverlayAnimation.self, forKey: .keystrokeOverlayAnimation)) ?? .slideUp) ?? .slideUp
        keystrokeOverlayScopeToRecordedApp = try c.decodeIfPresent(Bool.self, forKey: .keystrokeOverlayScopeToRecordedApp) ?? true
        clickRippleColor = try c.decodeIfPresent(CodableColor.self, forKey: .clickRippleColor) ?? CodableColor(NSColor.white)
        clickRippleSize = try c.decodeIfPresent(Double.self, forKey: .clickRippleSize) ?? 40
        showCamera = try c.decode(Bool.self, forKey: .showCamera)
        cameraPosition = try c.decode(CameraPosition.self, forKey: .cameraPosition)
        cameraCustomX = try c.decodeIfPresent(Double.self, forKey: .cameraCustomX)
        cameraCustomY = try c.decodeIfPresent(Double.self, forKey: .cameraCustomY)
        cameraSize = try c.decode(Double.self, forKey: .cameraSize)
        cameraShape = try c.decode(CameraShape.self, forKey: .cameraShape)
        // Lenient like cameraFilter: an unknown stored orientation falls back
        // to Auto instead of failing the whole project decode.
        cameraOrientation = ((try? c.decodeIfPresent(CameraOrientation.self, forKey: .cameraOrientation)) ?? .some(.auto)) ?? .auto
        cameraMirrored = try c.decodeIfPresent(Bool.self, forKey: .cameraMirrored) ?? false
        cameraBrightness = try c.decodeIfPresent(Double.self, forKey: .cameraBrightness) ?? 0
        cameraContrast = try c.decodeIfPresent(Double.self, forKey: .cameraContrast) ?? 1
        cameraSaturation = try c.decodeIfPresent(Double.self, forKey: .cameraSaturation) ?? 1
        cameraHue = try c.decodeIfPresent(Double.self, forKey: .cameraHue) ?? 0
        // Lenient like cursorStyle: an unknown stored filter falls back to
        // None instead of failing the whole project decode.
        cameraFilter = ((try? c.decodeIfPresent(CameraFilterStyle.self, forKey: .cameraFilter)) ?? .some(.none)) ?? .none
        cameraRingLight = try c.decodeIfPresent(Double.self, forKey: .cameraRingLight) ?? 0
        cameraCornerRadius = try c.decodeIfPresent(Double.self, forKey: .cameraCornerRadius) ?? 12
        cameraBorderWidth = try c.decodeIfPresent(Double.self, forKey: .cameraBorderWidth) ?? 2
        cameraBorderColor = try c.decodeIfPresent(CodableColor.self, forKey: .cameraBorderColor)
        cameraOpacity = try c.decodeIfPresent(Double.self, forKey: .cameraOpacity) ?? 1
        cameraTiltPitch = try c.decodeIfPresent(Double.self, forKey: .cameraTiltPitch) ?? 0
        cameraTiltYaw = try c.decodeIfPresent(Double.self, forKey: .cameraTiltYaw) ?? 0
        cameraTagText = try c.decodeIfPresent(String.self, forKey: .cameraTagText) ?? ""
        cameraTagSubtext = try c.decodeIfPresent(String.self, forKey: .cameraTagSubtext) ?? ""
        cameraTagFontName = try c.decodeIfPresent(String.self, forKey: .cameraTagFontName)
        cameraTagTextColor = try c.decodeIfPresent(CodableColor.self, forKey: .cameraTagTextColor) ?? CodableColor(NSColor.white)
        cameraTagBackgroundColor = try c.decodeIfPresent(CodableColor.self, forKey: .cameraTagBackgroundColor) ?? CodableColor(red: 0, green: 0, blue: 0, opacity: 0.55)
        cameraTagPosition = ((try? c.decodeIfPresent(CameraTagPosition.self, forKey: .cameraTagPosition)) ?? .some(.below)) ?? .below
        showDeviceFrame = try c.decodeIfPresent(Bool.self, forKey: .showDeviceFrame) ?? true
        showWatermark = try c.decodeIfPresent(Bool.self, forKey: .showWatermark) ?? false
        watermarkFileName = try c.decodeIfPresent(String.self, forKey: .watermarkFileName)
        watermarkX = try c.decodeIfPresent(Double.self, forKey: .watermarkX) ?? 1.0
        watermarkY = try c.decodeIfPresent(Double.self, forKey: .watermarkY) ?? 1.0
        watermarkSize = try c.decodeIfPresent(Double.self, forKey: .watermarkSize) ?? 120
        watermarkOpacity = try c.decodeIfPresent(Double.self, forKey: .watermarkOpacity) ?? 0.9
        menuBarReplacement = try c.decodeIfPresent(MenuBarReplacement.self, forKey: .menuBarReplacement) ?? .off
        menuBarTitle = try c.decodeIfPresent(String.self, forKey: .menuBarTitle) ?? "CaptureCat"
        menuBarTitleAlignment = try c.decodeIfPresent(MenuBarTitleAlignment.self, forKey: .menuBarTitleAlignment) ?? .left
        menuBarShowStatusIcons = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowStatusIcons) ?? true
        menuBarClock = try c.decodeIfPresent(String.self, forKey: .menuBarClock) ?? "9:41"
        menuBarHeight = try c.decodeIfPresent(Double.self, forKey: .menuBarHeight) ?? 3.8
        systemAudioVolume = try c.decode(Double.self, forKey: .systemAudioVolume)
        microphoneVolume = try c.decode(Double.self, forKey: .microphoneVolume)
        voiceOverVolume = try c.decodeIfPresent(Double.self, forKey: .voiceOverVolume) ?? 1.0
        animationSpeed = try c.decode(AnimationSpeed.self, forKey: .animationSpeed)
        motionBlur = try c.decode(Bool.self, forKey: .motionBlur)
        motionBlurStrength = try c.decodeIfPresent(Double.self, forKey: .motionBlurStrength) ?? 0.5
        parallaxStrength = try c.decodeIfPresent(Double.self, forKey: .parallaxStrength) ?? 0
        autoZoomLevel = try c.decodeIfPresent(Double.self, forKey: .autoZoomLevel) ?? 2.0
        introSlideStyle = try c.decodeIfPresent(IntroSlideStyle.self, forKey: .introSlideStyle) ?? .off
        introSlideDuration = try c.decodeIfPresent(Double.self, forKey: .introSlideDuration) ?? 0.9
        introSlideStart = try c.decodeIfPresent(Double.self, forKey: .introSlideStart) ?? 0
        introSlideBounce = try c.decodeIfPresent(Double.self, forKey: .introSlideBounce) ?? 0.5
        introSlideSpeed = try c.decodeIfPresent(Double.self, forKey: .introSlideSpeed) ?? 1.0
        introSlideDepth = try c.decodeIfPresent(Bool.self, forKey: .introSlideDepth) ?? false
        curtainUnveilCorner = try c.decodeIfPresent(CurtainUnveilCorner.self, forKey: .curtainUnveilCorner) ?? .off
        curtainUnveilDuration = try c.decodeIfPresent(Double.self, forKey: .curtainUnveilDuration) ?? 1.6
        curtainUnveilStart = try c.decodeIfPresent(Double.self, forKey: .curtainUnveilStart) ?? 0
        curtainLogoFileName = try c.decodeIfPresent(String.self, forKey: .curtainLogoFileName)
        curtainLogoOpacity = try c.decodeIfPresent(Double.self, forKey: .curtainLogoOpacity) ?? 1.0
        curtainLogoScale = try c.decodeIfPresent(Double.self, forKey: .curtainLogoScale) ?? 0.25
        curtainLogoTint = try c.decodeIfPresent(CodableColor.self, forKey: .curtainLogoTint)
        curtainColor = try c.decodeIfPresent(CodableColor.self, forKey: .curtainColor)
        cameraFollowSpeed = try c.decodeIfPresent(Double.self, forKey: .cameraFollowSpeed) ?? 0.5
        screenTiltMode = try c.decodeIfPresent(ScreenTiltMode.self, forKey: .screenTiltMode) ?? .off
        screenTiltAngle = try c.decodeIfPresent(Double.self, forKey: .screenTiltAngle) ?? 20
        screenTiltYaw = try c.decodeIfPresent(Double.self, forKey: .screenTiltYaw) ?? 0
        screenTiltRoll = try c.decodeIfPresent(Double.self, forKey: .screenTiltRoll) ?? 0
        showSubtitles = try c.decodeIfPresent(Bool.self, forKey: .showSubtitles) ?? true
        subtitleFontSize = try c.decodeIfPresent(Double.self, forKey: .subtitleFontSize) ?? 32
        subtitlePosition = try c.decodeIfPresent(SubtitlePosition.self, forKey: .subtitlePosition) ?? .bottom
        subtitleStyle = try c.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? .outline
        subtitleCustomX = try c.decodeIfPresent(Double.self, forKey: .subtitleCustomX)
        subtitleCustomY = try c.decodeIfPresent(Double.self, forKey: .subtitleCustomY)
        subtitleWeight = ((try? c.decodeIfPresent(SubtitleWeight.self, forKey: .subtitleWeight)) ?? .bold) ?? .bold
        subtitleUppercase = try c.decodeIfPresent(Bool.self, forKey: .subtitleUppercase) ?? false
        subtitleFontName = try c.decodeIfPresent(String.self, forKey: .subtitleFontName)
        subtitleColor = try c.decodeIfPresent(CodableColor.self, forKey: .subtitleColor) ?? CodableColor(NSColor.white)
        subtitleBackgroundColor = try c.decodeIfPresent(CodableColor.self, forKey: .subtitleBackgroundColor) ?? CodableColor(NSColor.black)
        highlightWords = try c.decodeIfPresent(Bool.self, forKey: .highlightWords) ?? false
        subtitleHighlightColor = try c.decodeIfPresent(CodableColor.self, forKey: .subtitleHighlightColor) ?? CodableColor(NSColor.systemYellow)
        aspectRatio = try c.decode(AspectRatio.self, forKey: .aspectRatio)
        muteRecordedAudio = try c.decodeIfPresent(Bool.self, forKey: .muteRecordedAudio) ?? false
        exportSettings = try c.decode(ExportSettings.self, forKey: .exportSettings)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backgroundType, forKey: .backgroundType)
        try c.encode(gradientStartColor, forKey: .gradientStartColor)
        try c.encode(gradientEndColor, forKey: .gradientEndColor)
        try c.encode(solidColor, forKey: .solidColor)
        try c.encode(backgroundImagePath, forKey: .backgroundImagePath)
        try c.encode(backgroundPadding, forKey: .backgroundPadding)
        try c.encode(videoPlacement, forKey: .videoPlacement)
        try c.encodeIfPresent(videoCustomX, forKey: .videoCustomX)
        try c.encodeIfPresent(videoCustomY, forKey: .videoCustomY)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(windowCornerRadius, forKey: .windowCornerRadius)
        try c.encode(frameShape, forKey: .frameShape)
        try c.encode(shadowRadius, forKey: .shadowRadius)
        try c.encode(shadowOpacity, forKey: .shadowOpacity)
        try c.encodeIfPresent(gradientAngle, forKey: .gradientAngle)
        try c.encode(backgroundBlur, forKey: .backgroundBlur)
        try c.encode(backgroundBrightness, forKey: .backgroundBrightness)
        try c.encode(backgroundSaturation, forKey: .backgroundSaturation)
        try c.encode(backgroundTintColor, forKey: .backgroundTintColor)
        try c.encode(backgroundTintOpacity, forKey: .backgroundTintOpacity)
        try c.encode(backgroundVignette, forKey: .backgroundVignette)
        try c.encode(backgroundPixelate, forKey: .backgroundPixelate)
        try c.encode(backgroundHalftone, forKey: .backgroundHalftone)
        try c.encode(backgroundNoise, forKey: .backgroundNoise)
        try c.encode(backgroundContrast, forKey: .backgroundContrast)
        try c.encode(backgroundHue, forKey: .backgroundHue)
        try c.encode(showCursor, forKey: .showCursor)
        try c.encode(cursorStyle, forKey: .cursorStyle)
        try c.encode(cursorScale, forKey: .cursorScale)
        try c.encode(autoHideCursor, forKey: .autoHideCursor)
        try c.encode(autoHideDelay, forKey: .autoHideDelay)
        try c.encode(smoothCursor, forKey: .smoothCursor)
        try c.encode(smoothingFactor, forKey: .smoothingFactor)
        try c.encode(cursorTilt, forKey: .cursorTilt)
        try c.encode(cursorStretch, forKey: .cursorStretch)
        try c.encode(cursorDrag, forKey: .cursorDrag)
        try c.encode(cursorWeight, forKey: .cursorWeight)
        try c.encode(cursorFluidEnabled, forKey: .cursorFluidEnabled)
        try c.encode(cursorTension, forKey: .cursorTension)
        try c.encode(cursorFriction, forKey: .cursorFriction)
        try c.encode(cursorMass, forKey: .cursorMass)
        try c.encode(showClickRipple, forKey: .showClickRipple)
        try c.encode(cursorLoopToStart, forKey: .cursorLoopToStart)
        try c.encode(cursorStopAtEnd, forKey: .cursorStopAtEnd)
        try c.encode(clickSoundEnabled, forKey: .clickSoundEnabled)
        try c.encode(clickSoundVolume, forKey: .clickSoundVolume)
        try c.encode(clickSoundStyle, forKey: .clickSoundStyle)
        try c.encode(keySoundEnabled, forKey: .keySoundEnabled)
        try c.encode(keySoundVolume, forKey: .keySoundVolume)
        try c.encode(keySoundStyle, forKey: .keySoundStyle)
        try c.encode(showKeystrokes, forKey: .showKeystrokes)
        try c.encode(keystrokeOverlaySize, forKey: .keystrokeOverlaySize)
        try c.encode(keystrokeOverlayPosition, forKey: .keystrokeOverlayPosition)
        try c.encode(keystrokeOverlayAnimation, forKey: .keystrokeOverlayAnimation)
        try c.encode(keystrokeOverlayScopeToRecordedApp, forKey: .keystrokeOverlayScopeToRecordedApp)
        try c.encode(clickRippleColor, forKey: .clickRippleColor)
        try c.encode(clickRippleSize, forKey: .clickRippleSize)
        try c.encode(showCamera, forKey: .showCamera)
        try c.encode(cameraPosition, forKey: .cameraPosition)
        try c.encodeIfPresent(cameraCustomX, forKey: .cameraCustomX)
        try c.encodeIfPresent(cameraCustomY, forKey: .cameraCustomY)
        try c.encode(cameraSize, forKey: .cameraSize)
        try c.encode(cameraShape, forKey: .cameraShape)
        try c.encode(cameraOrientation, forKey: .cameraOrientation)
        try c.encode(cameraMirrored, forKey: .cameraMirrored)
        try c.encode(cameraBrightness, forKey: .cameraBrightness)
        try c.encode(cameraContrast, forKey: .cameraContrast)
        try c.encode(cameraSaturation, forKey: .cameraSaturation)
        try c.encode(cameraHue, forKey: .cameraHue)
        try c.encode(cameraFilter, forKey: .cameraFilter)
        try c.encode(cameraRingLight, forKey: .cameraRingLight)
        try c.encode(cameraCornerRadius, forKey: .cameraCornerRadius)
        try c.encode(cameraBorderWidth, forKey: .cameraBorderWidth)
        try c.encodeIfPresent(cameraBorderColor, forKey: .cameraBorderColor)
        try c.encode(cameraOpacity, forKey: .cameraOpacity)
        try c.encode(cameraTiltPitch, forKey: .cameraTiltPitch)
        try c.encode(cameraTiltYaw, forKey: .cameraTiltYaw)
        try c.encode(cameraTagText, forKey: .cameraTagText)
        try c.encode(cameraTagSubtext, forKey: .cameraTagSubtext)
        try c.encodeIfPresent(cameraTagFontName, forKey: .cameraTagFontName)
        try c.encode(cameraTagTextColor, forKey: .cameraTagTextColor)
        try c.encode(cameraTagBackgroundColor, forKey: .cameraTagBackgroundColor)
        try c.encode(cameraTagPosition, forKey: .cameraTagPosition)
        try c.encode(showDeviceFrame, forKey: .showDeviceFrame)
        try c.encode(showWatermark, forKey: .showWatermark)
        try c.encodeIfPresent(watermarkFileName, forKey: .watermarkFileName)
        try c.encode(watermarkX, forKey: .watermarkX)
        try c.encode(watermarkY, forKey: .watermarkY)
        try c.encode(watermarkSize, forKey: .watermarkSize)
        try c.encode(watermarkOpacity, forKey: .watermarkOpacity)
        try c.encode(menuBarReplacement, forKey: .menuBarReplacement)
        try c.encode(menuBarTitle, forKey: .menuBarTitle)
        try c.encode(menuBarTitleAlignment, forKey: .menuBarTitleAlignment)
        try c.encode(menuBarShowStatusIcons, forKey: .menuBarShowStatusIcons)
        try c.encode(menuBarClock, forKey: .menuBarClock)
        try c.encode(menuBarHeight, forKey: .menuBarHeight)
        try c.encode(systemAudioVolume, forKey: .systemAudioVolume)
        try c.encode(microphoneVolume, forKey: .microphoneVolume)
        try c.encode(voiceOverVolume, forKey: .voiceOverVolume)
        try c.encode(animationSpeed, forKey: .animationSpeed)
        try c.encode(motionBlur, forKey: .motionBlur)
        try c.encode(motionBlurStrength, forKey: .motionBlurStrength)
        try c.encode(parallaxStrength, forKey: .parallaxStrength)
        try c.encode(autoZoomLevel, forKey: .autoZoomLevel)
        try c.encode(introSlideStyle, forKey: .introSlideStyle)
        try c.encode(introSlideDuration, forKey: .introSlideDuration)
        try c.encode(introSlideStart, forKey: .introSlideStart)
        try c.encode(introSlideBounce, forKey: .introSlideBounce)
        try c.encode(introSlideSpeed, forKey: .introSlideSpeed)
        try c.encode(introSlideDepth, forKey: .introSlideDepth)
        try c.encode(curtainUnveilCorner, forKey: .curtainUnveilCorner)
        try c.encode(curtainUnveilDuration, forKey: .curtainUnveilDuration)
        try c.encode(curtainUnveilStart, forKey: .curtainUnveilStart)
        try c.encodeIfPresent(curtainLogoFileName, forKey: .curtainLogoFileName)
        try c.encode(curtainLogoOpacity, forKey: .curtainLogoOpacity)
        try c.encode(curtainLogoScale, forKey: .curtainLogoScale)
        try c.encodeIfPresent(curtainLogoTint, forKey: .curtainLogoTint)
        try c.encodeIfPresent(curtainColor, forKey: .curtainColor)
        try c.encode(cameraFollowSpeed, forKey: .cameraFollowSpeed)
        try c.encode(screenTiltMode, forKey: .screenTiltMode)
        try c.encode(screenTiltAngle, forKey: .screenTiltAngle)
        try c.encode(screenTiltYaw, forKey: .screenTiltYaw)
        try c.encode(screenTiltRoll, forKey: .screenTiltRoll)
        try c.encode(showSubtitles, forKey: .showSubtitles)
        try c.encode(subtitleFontSize, forKey: .subtitleFontSize)
        try c.encode(subtitlePosition, forKey: .subtitlePosition)
        try c.encode(subtitleStyle, forKey: .subtitleStyle)
        try c.encodeIfPresent(subtitleCustomX, forKey: .subtitleCustomX)
        try c.encodeIfPresent(subtitleCustomY, forKey: .subtitleCustomY)
        try c.encode(subtitleWeight, forKey: .subtitleWeight)
        try c.encode(subtitleUppercase, forKey: .subtitleUppercase)
        try c.encodeIfPresent(subtitleFontName, forKey: .subtitleFontName)
        try c.encode(subtitleColor, forKey: .subtitleColor)
        try c.encode(subtitleBackgroundColor, forKey: .subtitleBackgroundColor)
        try c.encode(highlightWords, forKey: .highlightWords)
        try c.encode(subtitleHighlightColor, forKey: .subtitleHighlightColor)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encode(muteRecordedAudio, forKey: .muteRecordedAudio)
        try c.encode(exportSettings, forKey: .exportSettings)
    }
}
