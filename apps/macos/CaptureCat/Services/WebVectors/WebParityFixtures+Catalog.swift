import AppKit

// The parity fixture catalog: each exercises one feature family on the
// synthetic source, with frame indices chosen to land MID-ANIMATION (zoom
// ramps, effect builds, slide-ins) as well as on settled states — static
// frames alone have let broken animations pass before (CLAUDE.md §3).
extension WebParityFixtures {
    private static let screen = CGSize(width: 1920, height: 1080)
    private static let phone = CGSize(width: 590, height: 1278)

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static var fixtures: [Fixture] {
        [
            Fixture(
                name: "01-baseline-gradient",
                description: "Gradient background at 135°, padding/corner radius/shadow, centred card, default arrow cursor with click ripples.",
                features: ["background.gradient", "padding", "cornerRadius", "shadow", "cursor.arrow", "clickRipple"],
                duration: 4, sourceSize: screen, withCursor: true, withCamera: false,
                frames: [0, 27, 30, 45, 72, 110],
                configure: { p in
                    let s = p.settings
                    s.backgroundType = .gradient
                    s.gradientAngle = 135
                    s.backgroundPadding = 64
                    s.cornerRadius = 16
                    s.windowCornerRadius = 10
                    s.shadowRadius = 30
                    s.shadowOpacity = 0.6
                }),
            Fixture(
                name: "02-mesh-look-filters",
                description: "Mesh background with every look filter (blur, brightness, saturation, tint, vignette, noise, contrast, hue), squircle frame, freeform card placement.",
                features: ["background.mesh", "background.look", "frameShape.squircle", "placement.custom"],
                duration: 3, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [0, 45, 89],
                configure: { p in
                    let s = p.settings
                    s.backgroundType = .mesh
                    s.backgroundBlur = 0.4
                    s.backgroundBrightness = 0.08
                    s.backgroundSaturation = 1.3
                    s.backgroundTintColor = CodableColor(red: 1, green: 0.4, blue: 0.2)
                    s.backgroundTintOpacity = 0.2
                    s.backgroundVignette = 0.5
                    s.backgroundNoise = 0.3
                    s.backgroundContrast = 1.2
                    s.backgroundHue = 20
                    s.frameShape = .squircle
                    s.cornerRadius = 28
                    s.videoCustomX = 0.46
                    s.videoCustomY = 0.56
                    s.backgroundPadding = 90
                }),
            Fixture(
                name: "03-solid-square-rect",
                description: "Solid background, 1:1 output, rectangle frame, heavy padding and shadow, top-left placement, pixelate + halftone look.",
                features: ["background.solid", "aspect.1:1", "frameShape.rectangle", "placement.topLeft", "background.pixelate", "background.halftone"],
                duration: 3, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [0, 60],
                configure: { p in
                    let s = p.settings
                    s.backgroundType = .solid
                    s.aspectRatio = .square
                    s.frameShape = .rectangle
                    s.backgroundPadding = 120
                    s.shadowRadius = 60
                    s.shadowOpacity = 0.8
                    s.videoPlacement = .topLeft
                    s.backgroundPixelate = 0.4
                    s.backgroundHalftone = 0.3
                }),
            Fixture(
                name: "04-zoom-follow-motionblur",
                description: "Zoom regions: cursor-follow (Snappy) and fixed focus with card offset (Cinematic); parallax + motion blur; frames mid ramp-in, held, mid ramp-out.",
                features: ["zoom.followsCursor", "zoom.fixedFocus", "zoom.cardOffset", "zoom.styles", "parallax", "motionBlur", "cursor.arrow"],
                duration: 6, sourceSize: screen, withCursor: true, withCamera: false,
                frames: [0, 18, 24, 30, 45, 66, 75, 96, 105, 114, 132, 150, 179],
                configure: { p in
                    let s = p.settings
                    s.parallaxStrength = 0.5
                    s.motionBlur = true
                    s.motionBlurStrength = 0.6
                    s.cameraFollowSpeed = 0.6
                    p.zoomRegions = [
                        ZoomRegion(id: id(401), startTime: 0.5, endTime: 2.4, zoomLevel: 2.2,
                                   focalPoint: CGPoint(x: 0.4, y: 0.4), animationStyle: .snappy),
                        ZoomRegion(id: id(402), startTime: 3.0, endTime: 4.6, zoomLevel: 1.8,
                                   focalPoint: CGPoint(x: 0.7, y: 0.65), animationStyle: .cinematic,
                                   cardOffsetX: 0.05, cardOffsetY: 0.1, followsCursor: false),
                    ]
                }),
            Fixture(
                name: "05-tilt-regions",
                description: "Screen tilt mode Both (intro + zoomed-out) plus a timeline tilt region with Smooth style and a zoom block.",
                features: ["tilt.mode.both", "tilt.intro", "tilt.region", "zoom"],
                duration: 5, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [0, 6, 15, 30, 48, 60, 75, 90, 110, 135, 149],
                configure: { p in
                    let s = p.settings
                    s.screenTiltMode = .both
                    s.screenTiltAngle = 15
                    s.screenTiltYaw = 10
                    s.screenTiltRoll = 3
                    p.tiltRegions = [
                        TiltRegion(id: id(501), startTime: 1.8, endTime: 3.2, pitch: -18, yaw: 24, roll: -4,
                                   animationStyle: .smooth),
                    ]
                    p.zoomRegions = [
                        ZoomRegion(id: id(502), startTime: 3.4, endTime: 4.4, zoomLevel: 1.6,
                                   focalPoint: CGPoint(x: 0.5, y: 0.5)),
                    ]
                }),
            Fixture(
                name: "06-cursor-hand-physics",
                description: "Hand cursor at 2× with tilt/stretch/drag physics, custom ripple colour and size, fluid spring defaults.",
                features: ["cursor.hand", "cursor.scale", "cursor.physics", "cursor.spring", "clickRipple.custom"],
                duration: 5, sourceSize: screen, withCursor: true, withCamera: false,
                frames: [10, 30, 54, 57, 60, 75, 108, 146],
                configure: { p in
                    let s = p.settings
                    s.cursorStyle = .hand
                    s.cursorScale = 2
                    s.cursorTilt = 0.6
                    s.cursorStretch = 0.5
                    s.cursorDrag = 0.4
                    s.cursorWeight = 1.4
                    s.clickRippleColor = CodableColor(red: 1, green: 0.8, blue: 0.1)
                    s.clickRippleSize = 60
                }),
            Fixture(
                name: "07-intro-slide-curtain",
                description: "Intro slide from the bottom with 3D depth and bounce, and a Curtain Unveil from the top-right corner with a custom curtain colour.",
                features: ["introSlide.bottom", "introSlide.depth", "curtainUnveil"],
                duration: 4, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [0, 4, 9, 14, 20, 27, 36, 45, 54, 70, 100],
                configure: { p in
                    let s = p.settings
                    s.introSlideStyle = .bottom
                    s.introSlideDepth = true
                    s.introSlideBounce = 0.7
                    s.introSlideDuration = 1.0
                    s.curtainUnveilCorner = .topRight
                    s.curtainUnveilDuration = 1.6
                    s.curtainUnveilStart = 0.8
                    s.curtainColor = CodableColor(red: 0.12, green: 0.14, blue: 0.3)
                }),
            Fixture(
                name: "08-annotations",
                description: "One annotation of every type with different enter/exit build effects; frames mid-enter, settled and mid-exit.",
                features: ["annotation.text", "annotation.arrow", "annotation.callout", "annotation.drawing",
                           "annotation.rectangle", "annotation.ellipse", "annotation.tap", "annotation.effects", "annotation.backdrop"],
                duration: 6, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [5, 16, 20, 35, 45, 60, 75, 90, 118, 128, 150, 170],
                configure: { p in
                    var text = Annotation(id: id(801), type: .text, startTime: 0.1, endTime: 5.0)
                    text.text = "Parity check ✓"; text.x = 0.3; text.y = 0.2; text.fontSize = 28
                    text.enterEffect = .pop; text.exitEffect = .fade
                    var arrow = Annotation(id: id(802), type: .arrow, startTime: 0.5, endTime: 4.2)
                    arrow.x = 0.2; arrow.y = 0.6; arrow.arrowEndX = 0.45; arrow.arrowEndY = 0.45
                    arrow.color = CodableColor(red: 1, green: 0.3, blue: 0.3); arrow.lineWidth = 6
                    arrow.enterEffect = .scaleUp; arrow.exitEffect = .drop
                    var callout = Annotation(id: id(803), type: .callout, startTime: 1.0, endTime: 5.5)
                    callout.text = "Look here"; callout.x = 0.62; callout.y = 0.25
                    callout.arrowEndX = 0.75; callout.arrowEndY = 0.5
                    callout.enterEffect = .slideUp; callout.exitEffect = .explode
                    var drawing = Annotation(id: id(804), type: .drawing, startTime: 1.5, endTime: 5.8)
                    drawing.drawingStrokes = [
                        (0..<24).map { i in CodablePoint(x: 0.1 + Double(i) * 0.01, y: 0.8 - 0.1 * sin(Double(i) / 3)) },
                        (0..<10).map { i in CodablePoint(x: 0.12 + Double(i) * 0.02, y: 0.88) },
                    ]
                    drawing.color = CodableColor(red: 0.2, green: 1, blue: 0.6); drawing.lineWidth = 5
                    drawing.enterEffect = .drawOn; drawing.exitEffect = .drawOn
                    var rect = Annotation(id: id(805), type: .rectangle, startTime: 2.0, endTime: 5.2)
                    rect.x = 0.55; rect.y = 0.6; rect.arrowEndX = 0.8; rect.arrowEndY = 0.85
                    rect.showBackground = false; rect.cornerRadius = 12; rect.backdropOpacity = 0.35
                    rect.enterEffect = .fade; rect.exitEffect = .fade
                    var ellipse = Annotation(id: id(806), type: .ellipse, startTime: 2.5, endTime: 4.8)
                    ellipse.x = 0.05; ellipse.y = 0.05; ellipse.arrowEndX = 0.2; ellipse.arrowEndY = 0.3
                    ellipse.color = CodableColor(red: 0.3, green: 0.6, blue: 1)
                    ellipse.enterEffect = .pop; ellipse.exitEffect = .scaleUp
                    var tap = Annotation(id: id(807), type: .tap, startTime: 3.0, endTime: 5.9)
                    tap.x = 0.5; tap.y = 0.5; tap.fontSize = 60
                    p.annotations = [text, arrow, callout, drawing, rect, ellipse, tap]
                }),
            Fixture(
                name: "09-blur-highlight-focus",
                description: "Blur region (gaussian), animated pixelate region, highlight (outside dim) and Depth Focus (area + tilt-shift) regions over time.",
                features: ["region.blur", "region.pixelate.animated", "region.highlight", "region.focus.area", "region.focus.tiltShift"],
                duration: 6, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [15, 40, 45, 70, 95, 100, 130, 160],
                configure: { p in
                    p.blurRegions = [
                        BlurRegion(id: id(901), startTime: 0.2, endTime: 2.0, rect: CGRect(x: 0.1, y: 0.1, width: 0.35, height: 0.2),
                                   intensity: 0.8, style: .blur),
                        BlurRegion(id: id(902), startTime: 1.2, endTime: 3.0, rect: CGRect(x: 0.55, y: 0.55, width: 0.3, height: 0.3),
                                   intensity: 0.6, style: .pixelate, animated: true),
                    ]
                    p.highlightRegions = [
                        HighlightRegion(id: id(903), startTime: 2.2, endTime: 3.8,
                                        rect: CGRect(x: 0.3, y: 0.35, width: 0.4, height: 0.25), opacity: 0.6),
                    ]
                    p.focusRegions = [
                        FocusRegion(id: id(904), startTime: 3.0, endTime: 4.5, intensity: 0.8, falloff: 0.4, style: .area),
                        FocusRegion(id: id(905), startTime: 4.6, endTime: 5.9, intensity: 0.7, falloff: 0.5,
                                    style: .tiltShift, angle: 20),
                    ]
                }),
            Fixture(
                name: "10-device-frame",
                description: "iPhone-shaped portrait source recorded as a device take: bezel, island, squircle screen corners, shadow hugging the bezel.",
                features: ["deviceFrame", "recordingSourceKind.device", "portraitSource"],
                duration: 3, sourceSize: phone, withCursor: false, withCamera: false,
                frames: [0, 45, 89],
                configure: { p in
                    p.recordingSourceKind = .device
                    p.settings.showDeviceFrame = true
                    p.settings.backgroundPadding = 40
                }),
            Fixture(
                name: "11-subtitles-ring-cursor",
                description: "Subtitles with karaoke word highlight (Background style, uppercase, heavy) and a free-positioned segment; ring cursor.",
                features: ["subtitles.background", "subtitles.karaoke", "subtitles.customPosition", "cursor.ring"],
                duration: 5, sourceSize: screen, withCursor: true, withCamera: false,
                frames: [10, 25, 40, 55, 80, 100, 130],
                configure: { p in
                    let s = p.settings
                    s.cursorStyle = .ring
                    s.showSubtitles = true
                    s.subtitleStyle = .background
                    s.subtitleWeight = .heavy
                    s.subtitleUppercase = true
                    s.subtitleFontSize = 36
                    s.highlightWords = true
                    s.subtitleColor = CodableColor(red: 1, green: 1, blue: 1)
                    s.subtitleBackgroundColor = CodableColor(red: 0, green: 0, blue: 0, opacity: 0.7)
                    let w1 = [
                        WordTiming(id: id(1101), startTime: 0.2, endTime: 0.6, text: "Parity"),
                        WordTiming(id: id(1102), startTime: 0.6, endTime: 1.1, text: "is"),
                        WordTiming(id: id(1103), startTime: 1.1, endTime: 1.9, text: "the"),
                        WordTiming(id: id(1104), startTime: 1.9, endTime: 2.4, text: "product"),
                    ]
                    p.subtitles = [
                        SubtitleSegment(id: id(1110), startTime: 0.2, endTime: 2.4, text: "Parity is the product", words: w1),
                        SubtitleSegment(id: id(1111), startTime: 2.8, endTime: 4.6, text: "Preview must equal export"),
                    ]
                }),
            Fixture(
                name: "12-speed-trim-clips",
                description: "Trim in/out, a 2× and a 0.5× speed region, and split clips with a gap (BG-only output frames); the barcode proves which source frame is sampled.",
                features: ["trim", "speed.2x", "speed.0.5x", "clips.split", "clips.gap", "exportDurationCap"],
                duration: 6, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 140],
                configure: { p in
                    p.trimStart = 0.5
                    p.trimEnd = 5.6
                    p.speedRegions = [
                        VideoSpeedRegion(id: id(1201), startTime: 1.0, endTime: 2.0, speed: 2.0),
                        VideoSpeedRegion(id: id(1202), startTime: 3.0, endTime: 3.5, speed: 0.5),
                    ]
                    p.videoClipSegments = [
                        VideoClipSegment(id: id(1203), startTime: 0.5, endTime: 2.6),
                        VideoClipSegment(id: id(1204), startTime: 3.1, endTime: 5.2),
                    ]
                }),
            Fixture(
                name: "13-camera-bubble-layouts",
                description: "Webcam bubble (squircle, border, mirrored) with a Side-by-Side camera layout region and a Camera-Only span.",
                features: ["camera.bubble", "camera.squircle", "camera.border", "camera.mirrored", "cameraLayout.sideBySide", "cameraLayout.cameraOnly"],
                duration: 5, sourceSize: screen, withCursor: false, withCamera: true,
                frames: [0, 20, 35, 45, 60, 75, 90, 110, 140],
                configure: { p in
                    let s = p.settings
                    s.showCamera = true
                    s.cameraShape = .squircle
                    s.cameraSize = 180
                    s.cameraMirrored = true
                    s.cameraBorderWidth = 3
                    s.cameraBorderColor = CodableColor(red: 1, green: 1, blue: 1, opacity: 0.8)
                    s.cameraPosition = .bottomRight
                    p.cameraLayoutRegions = [
                        CameraLayoutRegion(id: id(1301), startTime: 1.0, endTime: 2.4, mode: .sideBySide),
                        CameraLayoutRegion(id: id(1302), startTime: 3.0, endTime: 4.0, mode: .cameraOnly),
                    ]
                }),
            Fixture(
                name: "14-source-segments-dip",
                description: "Stitched take screen → iPhone → screen: the device segment is cropped to its content rect and bezel-framed (screen mask, bezel with its own shadow, island; the card shadow dropped), a Keynote dip straddles each cut, and a tilt region spans the second cut (side slab + dip under the warp). Frames on, beside and around both cuts.",
                features: ["sourceSegments", "sourceSegments.deviceFraming", "deviceSegmentDip", "tilt.region", "deviceSide"],
                duration: 5, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [0, 40, 45, 47, 48, 49, 52, 60, 80, 99, 101, 102, 103, 106, 125, 149],
                configure: { p in
                    let s = p.settings
                    s.showDeviceFrame = true
                    s.backgroundPadding = 56
                    s.cornerRadius = 14
                    s.windowCornerRadius = 10
                    s.shadowRadius = 28
                    s.shadowOpacity = 0.55
                    p.sourceSegments = [
                        stitchedSegment(start: 0, duration: 1.6, kind: .display, natural: screen),
                        stitchedSegment(start: 1.6, duration: 1.8, kind: .device, natural: phone),
                        stitchedSegment(start: 3.4, duration: 1.6, kind: .display, natural: screen),
                    ]
                    p.tiltRegions = [
                        TiltRegion(id: id(1401), startTime: 2.9, endTime: 4.1, pitch: 12, yaw: -20, roll: 0,
                                   animationStyle: .smooth),
                    ]
                }),
            Fixture(
                name: "15-segment-first-curtain",
                description: "Stitched take that STARTS on the iPhone (a dip boundary at t = 0) with an off-grid cut, squircle frame, and a Curtain Unveil peeling across the cut — clipped to the phone screen, then to the card.",
                features: ["sourceSegments", "sourceSegments.deviceFirst", "deviceSegmentDip", "curtainUnveil.deviceScreen", "frameShape.squircle"],
                duration: 3, sourceSize: screen, withCursor: false, withCamera: false,
                frames: [0, 9, 20, 30, 42, 45, 46, 50, 56, 70, 89],
                configure: { p in
                    let s = p.settings
                    s.showDeviceFrame = true
                    s.frameShape = .squircle
                    s.cornerRadius = 26
                    s.backgroundPadding = 72
                    s.curtainUnveilCorner = .topLeft
                    s.curtainUnveilStart = 0.3
                    s.curtainUnveilDuration = 1.6
                    s.curtainColor = CodableColor(red: 0.16, green: 0.1, blue: 0.24)
                    p.sourceSegments = [
                        stitchedSegment(start: 0, duration: 1.507, kind: .device, natural: phone),
                        stitchedSegment(start: 1.507, duration: 1.493, kind: .display, natural: screen),
                    ]
                }),
        ]
    }

    /// A segment exactly as `RecordingStitcher.stitch` records it: `natural`
    /// aspect-fit into the (screen-sized) render size, normalized top-left.
    private static func stitchedSegment(start: TimeInterval, duration: TimeInterval,
                                        kind: RecordingSourceKind, natural: CGSize) -> ProjectSourceSegment {
        let render = screen
        let scale = min(render.width / max(1, natural.width), render.height / max(1, natural.height))
        let w = natural.width * scale
        let h = natural.height * scale
        return ProjectSourceSegment(
            startTime: start, duration: duration, kind: kind,
            contentX: Double((render.width - w) / 2 / render.width),
            contentY: Double((render.height - h) / 2 / render.height),
            contentWidth: Double(w / render.width),
            contentHeight: Double(h / render.height))
    }
}
