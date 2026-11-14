import AppKit
import ImageIO

/// `--preview-gesture-test [--print]`
///
/// Behaviour freeze for the preview's on-canvas gestures. Drives the REAL
/// compositor + interaction stack in a window (the topology the editor uses)
/// with synthetic mouse events across every gesture family — annotation body
/// moves, corner/endpoint handles, the pen, double-click inline edit, region
/// move / resize / value-pill slider, card placement and zoom-block
/// excursion, the zoom focal target, hits under tilt, camera / watermark /
/// subtitle chrome with their magnetism, the vertical-stack seam, the armed
/// blur draw and Esc — and records every callback and model write as text.
///
/// The golden (`PreviewGestureGoldens`) was frozen from the pre-extraction
/// `PreviewInteractionView` (Studio 1c, 1f11826), BEFORE the hit math moved
/// into the shared `PreviewHitMath`, so any behaviour change in that math is
/// a line diff here. The harness is black-box on purpose: it only sends
/// events and reads the model, so it ran unchanged on both sides of the
/// extraction. `--print` writes the live transcript to stdout — refreezing is
/// for a change you MEANT; read the diff first.
@MainActor
enum PreviewGestureHarness {
    static func run() -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var lines: [String] = []
        lines += annotationsScenario()
        lines += regionsScenario()
        lines += zoomScenario()
        lines += tiltScenario()
        lines += chromeScenario()
        lines += stackScenario()
        lines += blurDrawScenario()

        if CommandLine.arguments.contains("--print") {
            print(lines.joined(separator: "\n"))
            exit(0)
        }

        var failures: [String] = []

        // Coverage: the freeze only proves something if the gestures really
        // landed on their targets. Each pair is (gesture label, a line that
        // gesture's block must contain) — a path the transcript exercised.
        let required: [(String, String)] = [
            ("rect body move", "selAnn=R"),
            ("rect TL handle", "ann.R:"),
            ("ellipse TR handle", "ann.E:"),
            ("arrow head", "ann.A:"),
            ("arrow body clamps", "→(1.000000,"),
            ("text body", "selAnn=T"),
            ("tap body", "ann.P:"),
            ("callout body", "ann.C:"),
            ("click drawing ink", "selAnn=D"),
            ("pen stroke", "strokes=2"),
            ("double-click text", "editing=T"),
            ("click-away commits", "editing=nil"),
            ("below drag threshold", "selAnn=nil"),
            ("card placement drag", "card=Center custom=0."),
            ("card back to centre", "card=Center custom=nil"),
            ("esc deselects", "selAnn=nil"),
            ("playing:", "card=Center custom=0."),
            ("blur body", "selBlur=B"),
            ("blur TL corner", "blur.B:"),
            ("blur value pill", "intensity="),
            ("focus body", "selDepth=F"),
            ("focus right edge", "focus.F:"),
            ("focus value pill", "intensity="),
            ("highlight body", "selHl=H"),
            ("highlight BR corner", "hl.H:"),
            ("highlight top edge", "hl.H:"),
            ("highlight value pill", "opacity="),
            ("card click deselects", "selHl=nil"),
            ("left edge clamps", "hl.H: [0.000000,"),
            ("minimum size", "0.040000x"),
            ("focal target drag", "focal="),
            ("focal target clamps", "focal=(0.000000,0.000000)"),
            ("rect body under zoom", "ann.R:"),
            ("block excursion drag", "zoom.Z:"),
            ("rest magnetism", "off=nil,nil"),
            ("rect body under tilt", "ann.R:"),
            ("text under tilt", "ann.T:"),
            ("card drag under tilt", "card=Center custom=0."),
            ("watermark drag", "wm=0.750000"),
            ("camera drag", "cam=Bottom Right custom=0."),
            ("camera corner magnetism", "cam=Top Left custom=nil"),
            ("subtitle drag", "sub=Bottom custom=0.500000"),
            ("subtitle anchor magnetism", "sub=Bottom custom=nil"),
            ("watermark edge magnetism", "wm=1.000000,1.000000"),
            ("stack seam drag", "undo=Camera Height"),
            ("armed draw: drag out", "create="),
            ("grows to the minimum", "0.080000x0.080000"),
            ("clipped to the video", "create="),
        ]
        for (label, marker) in required where !Self.block(lines, label).contains(where: { $0.contains(marker) }) {
            failures.append("coverage: gesture \"\(label)\" never shows \"\(marker)\"")
        }

        let golden = PreviewGestureGoldens.transcript
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if golden != lines {
            var shown = 0
            for i in 0..<max(golden.count, lines.count) where shown < 40 {
                let g = i < golden.count ? golden[i] : "<missing>"
                let l = i < lines.count ? lines[i] : "<missing>"
                if g != l {
                    failures.append("line \(i + 1):\n    - \(g)\n    + \(l)")
                    shown += 1
                }
            }
            if golden.count != lines.count {
                failures.append("golden has \(golden.count) lines, live has \(lines.count)")
            }
        }

        let gestures = lines.filter { !$0.hasPrefix(" ") && !$0.hasPrefix("=") }.count
        if failures.isEmpty {
            print("PREVIEW-GESTURE PASS (\(gestures) gestures, \(lines.count) lines identical to the frozen pre-extraction transcript)")
            exit(0)
        }
        for f in failures { print("FAIL " + f) }
        print("PREVIEW-GESTURE FAIL (\(failures.count) problem(s)) — behaviour changed; do not refreeze, find out why.")
        exit(1)
    }

    /// The lines recorded for the first gesture whose label contains `label`.
    private static func block(_ lines: [String], _ label: String) -> [String] {
        guard let start = lines.firstIndex(where: { !$0.hasPrefix(" ") && !$0.hasPrefix("=") && $0.contains(label) })
        else { return [] }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { !$0.hasPrefix(" ") }) ?? lines.endIndex
        return Array(lines[start..<end])
    }

    // MARK: - Scenarios

    private static func annotationsScenario() -> [String] {
        let rig = GestureRig(scenario: "annotations", canvas: CGSize(width: 960, height: 540))
        let p = rig.project
        p.annotations = [
            rig.annotation("R", .rectangle, 0.10, 0.10, 0.30, 0.30, id: 1),
            rig.annotation("E", .ellipse, 0.40, 0.10, 0.55, 0.30, id: 2),
            rig.annotation("A", .arrow, 0.65, 0.15, 0.85, 0.30, id: 3),
            rig.annotation("T", .text, 0.50, 0.55, 0.65, 0.55, id: 4, text: "Hello world"),
            rig.annotation("P", .tap, 0.75, 0.72, 0.75, 0.72, id: 5),
            rig.annotation("C", .callout, 0.08, 0.62, 0.22, 0.78, id: 6, text: "Note"),
            rig.annotation("D", .drawing, 0.45, 0.85, 0.45, 0.85, id: 7,
                           strokes: [[(0.40, 0.80), (0.45, 0.85), (0.50, 0.82)]]),
        ]
        rig.start()

        rig.drag("rect body move", from: rig.v(0.20, 0.20), by: [(20, 12), (40, 25)])
        let r = { rig.ann("R") }
        rig.drag("rect TL handle", from: rig.v(r().x, r().y), by: [(-15, -10)])
        rig.drag("rect BR handle", from: rig.v(r().arrowEndX, r().arrowEndY), by: [(10, 20)])
        let e = { rig.ann("E") }
        rig.drag("ellipse TR handle", from: rig.v(e().arrowEndX, e().y), by: [(12, -8)])
        rig.drag("ellipse BL handle", from: rig.v(e().x, e().arrowEndY), by: [(-6, 9)])
        let a = { rig.ann("A") }
        rig.drag("arrow head", from: rig.v(a().arrowEndX, a().arrowEndY), by: [(20, 10)])
        rig.drag("arrow tail", from: rig.v(a().x, a().y), by: [(-10, 5)])
        rig.drag("arrow body clamps at the video edge",
                 from: rig.v((a().x + a().arrowEndX) / 2, (a().y + a().arrowEndY) / 2), by: [(300, 0), (600, 0)])
        rig.drag("text body", from: rig.v(0.50, 0.55), by: [(30, -20)])
        rig.drag("tap body", from: rig.v(0.75, 0.72), by: [(-25, 15)])
        rig.drag("callout body", from: rig.v(0.15, 0.70), by: [(15, 10)])
        rig.click("click drawing ink selects it", at: rig.v(0.45, 0.85))
        rig.drag("pen stroke on the selected drawing", from: rig.v(0.30, 0.40), by: [(10, 4), (24, 10)])
        let t = { rig.ann("T") }
        rig.click("click text while the drawing is selected adds a pen dot", at: rig.v(t().x, t().y))
        rig.click("double-click text edits in place", at: rig.v(t().x, t().y), clickCount: 2)
        rig.click("click-away commits the edit", at: rig.v(0.92, 0.55))
        rig.drag("click empty card: below drag threshold", from: rig.v(0.92, 0.55), by: [(3, 2)])
        rig.drag("card placement drag", from: rig.v(0.92, 0.55), by: [(30, 15), (60, 30)])
        rig.drag("card back to centre (magnetism)", from: rig.v(0.92, 0.55), by: [(-30, -15), (-60, -30)])
        rig.click("select rect", at: rig.v((r().x + r().arrowEndX) / 2, (r().y + r().arrowEndY) / 2))
        rig.escape("esc deselects everything")
        rig.isPlaying = true
        rig.render()
        rig.drag("playing: annotations are not hit, the card drags",
                 from: rig.v((r().x + r().arrowEndX) / 2, (r().y + r().arrowEndY) / 2), by: [(40, 0), (120, 0)])
        rig.isPlaying = false
        rig.render()
        return rig.finish()
    }

    private static func regionsScenario() -> [String] {
        let rig = GestureRig(scenario: "regions", canvas: CGSize(width: 960, height: 540))
        let p = rig.project
        p.blurRegions = [BlurRegion(id: rig.id("B", 11), startTime: 0, endTime: 10,
                                    rect: CGRect(x: 0.08, y: 0.08, width: 0.30, height: 0.20), intensity: 0.6)]
        p.highlightRegions = [HighlightRegion(id: rig.id("H", 12), startTime: 0, endTime: 10,
                                              rect: CGRect(x: 0.55, y: 0.10, width: 0.30, height: 0.25), opacity: 0.55)]
        p.focusRegions = [FocusRegion(id: rig.id("F", 13), startTime: 0, endTime: 10,
                                      rect: CGRect(x: 0.30, y: 0.55, width: 0.40, height: 0.30), intensity: 0.7)]
        rig.start()

        let h = { rig.project.highlightRegions[0].rect }
        let b = { rig.project.blurRegions[0].rect }
        let f = { rig.project.focusRegions[0].rect }
        rig.drag("blur body selects + moves", from: rig.v(b().midX, b().midY), by: [(10, 10)])
        rig.drag("blur TL corner", from: rig.v(b().minX, b().minY), by: [(-10, -10)])
        rig.drag("blur value pill", from: rig.pillCenter(b()), by: [(-30, 0)])
        rig.drag("focus body selects + moves", from: rig.v(f().midX, f().midY), by: [(-20, 30)])
        rig.drag("focus right edge", from: rig.v(f().maxX, f().midY), by: [(40, 0)])
        rig.drag("focus value pill (tucked inside)", from: rig.pillCenter(f()), by: [(60, 0)])
        rig.drag("highlight body selects + moves", from: rig.v(h().midX, h().midY), by: [(15, 10), (30, 20)])
        rig.drag("highlight BR corner", from: rig.v(h().maxX, h().maxY), by: [(25, 15)])
        rig.drag("highlight top edge", from: rig.v(h().midX, h().minY), by: [(0, -20)])
        rig.drag("highlight value pill", from: rig.pillCenter(h()), by: [(40, 0), (-200, 0)])
        rig.click("card click deselects every region", at: rig.v(0.15, 0.45))
        rig.click("reselect highlight", at: rig.v(h().midX, h().midY))
        rig.drag("highlight left edge clamps at 0", from: rig.v(h().minX, h().midY), by: [(-250, 0), (-500, 0)])
        rig.drag("highlight right edge stops at the minimum size", from: rig.v(h().maxX, h().midY), by: [(-800, 0)])
        return rig.finish()
    }

    private static func zoomScenario() -> [String] {
        let rig = GestureRig(scenario: "zoom", canvas: CGSize(width: 960, height: 540))
        let p = rig.project
        p.zoomRegions = [ZoomRegion(id: rig.id("Z", 21), startTime: 0.5, endTime: 5, zoomLevel: 1.8,
                                    focalPoint: CGPoint(x: 0.35, y: 0.40), cardOffsetX: 0.05, cardOffsetY: -0.03)]
        p.annotations = [rig.annotation("R", .rectangle, 0.30, 0.30, 0.45, 0.45, id: 22)]
        rig.time = 2.0
        rig.sel.zoom = p.zoomRegions[0].id
        rig.start()

        let z = { rig.project.zoomRegions[0] }
        rig.drag("focal target drag", from: rig.v(z().focalPoint.x, z().focalPoint.y), by: [(15, 10), (30, 20)])
        rig.drag("focal target clamps to the video", from: rig.v(z().focalPoint.x, z().focalPoint.y),
                 by: [(-2000, -2000)])
        rig.sel.zoom = nil
        rig.render()
        let r = { rig.ann("R") }
        rig.drag("rect body under zoom", from: rig.v((r().x + r().arrowEndX) / 2, (r().y + r().arrowEndY) / 2),
                 by: [(25, 10)])
        rig.drag("block excursion drag", from: rig.v(0.15, 0.25), by: [(25, 10), (50, 20)])
        let ox = z().cardOffsetX ?? 0, oy = z().cardOffsetY ?? 0
        rig.drag("block excursion back home (rest magnetism)", from: rig.v(0.15, 0.25),
                 by: [(-ox * 480, -oy * 270), (-ox * 960, -oy * 540)])
        return rig.finish()
    }

    private static func tiltScenario() -> [String] {
        let rig = GestureRig(scenario: "tilt", canvas: CGSize(width: 960, height: 540))
        let p = rig.project
        p.tiltRegions = [TiltRegion(startTime: 0, endTime: 10, pitch: 15, yaw: -12, roll: 4)]
        p.annotations = [
            rig.annotation("R", .rectangle, 0.35, 0.35, 0.60, 0.60, id: 31),
            rig.annotation("T", .text, 0.20, 0.80, 0.30, 0.80, id: 32, text: "Tilted"),
        ]
        rig.time = 2.0
        rig.start()
        let r = { rig.ann("R") }
        rig.drag("rect body under tilt", from: rig.v(0.475, 0.475), by: [(30, 15)])
        rig.drag("rect BR under tilt", from: rig.v(r().arrowEndX, r().arrowEndY), by: [(-12, 8)])
        rig.drag("text under tilt", from: rig.v(0.20, 0.80), by: [(20, -10)])
        rig.drag("card drag under tilt", from: rig.v(0.85, 0.15), by: [(45, 20), (90, 40)])
        return rig.finish()
    }

    private static func chromeScenario() -> [String] {
        let rig = GestureRig(scenario: "chrome", canvas: CGSize(width: 960, height: 540))
        let s = rig.project.settings
        s.showCamera = true
        s.showSubtitles = true
        rig.project.subtitles = [SubtitleSegment(startTime: 0, endTime: 10, text: "Gesture freeze")]
        rig.installWatermark()
        rig.cameraPoster = PreviewParityHarness.syntheticVideoFrame(size: CGSize(width: 640, height: 360))
        rig.start()

        func center(_ r: CGRect?) -> CGPoint { CGPoint(x: r?.midX ?? -100, y: r?.midY ?? -100) }
        // The watermark sits over the camera's bottom-right corner and wins
        // the hit (z-order), so it moves out of the way first.
        rig.drag("watermark drag", from: center(rig.ctx.watermarkRect), by: [(-100, -50), (-200, -100)])
        rig.drag("camera drag", from: center(rig.ctx.cameraRect), by: [(-50, -30), (-100, -60)])
        rig.drag("camera corner magnetism", from: center(rig.ctx.cameraRect), by: [(-2000, -2000)])
        rig.drag("subtitle drag", from: center(rig.ctx.subtitleRect), by: [(0, -60), (0, -120)])
        rig.drag("subtitle anchor magnetism", from: center(rig.ctx.subtitleRect), by: [(0, 2000)])
        rig.drag("watermark edge magnetism", from: center(rig.ctx.watermarkRect), by: [(92, 46), (184, 93)])
        return rig.finish()
    }

    private static func stackScenario() -> [String] {
        let rig = GestureRig(scenario: "stack", canvas: CGSize(width: 540, height: 960))
        let s = rig.project.settings
        s.aspectRatio = .vertical
        s.showCamera = true
        s.cameraPortraitStack = true
        rig.cameraPoster = PreviewParityHarness.syntheticVideoFrame(size: CGSize(width: 640, height: 360))
        rig.start()
        if let stack = rig.ctx.stack {
            rig.drag("stack seam drag", from: CGPoint(x: stack.cameraRow.midX, y: stack.seamY), by: [(0, 30), (0, 60)])
            rig.click("stacked camera row is inert", at: CGPoint(x: stack.cameraRow.midX, y: stack.cameraRow.midY))
        } else {
            rig.note("no stack seam in the hit context")
        }
        return rig.finish()
    }

    private static func blurDrawScenario() -> [String] {
        let rig = GestureRig(scenario: "blurDraw", canvas: CGSize(width: 960, height: 540))
        rig.start()
        rig.interaction.armBlurDraw(style: .pixelate)
        rig.drag("armed draw: drag out a region", from: rig.v(0.20, 0.20),
                 to: [rig.v(0.35, 0.30), rig.v(0.50, 0.45)])
        rig.interaction.armBlurDraw(style: .blur)
        rig.click("armed draw: a click grows to the minimum", at: rig.v(0.60, 0.60))
        rig.interaction.armBlurDraw(style: .blur)
        rig.escape("armed draw: esc disarms")
        rig.click("after disarm a click is an ordinary card click", at: rig.v(0.60, 0.60))
        rig.interaction.armBlurDraw(style: .pixelate)
        rig.drag("armed draw past the edge is clipped to the video", from: rig.v(0.90, 0.90),
                 to: [rig.v(1.10, 1.05), rig.v(1.30, 1.20)])
        return rig.finish()
    }
}

// MARK: - Rig

@MainActor
private final class GestureRig {
    struct Selection {
        var annotation: UUID?
        var highlight: UUID?
        var blur: UUID?
        var depth: UUID?
        var zoom: UUID?
    }

    static let videoPoster = PreviewParityHarness.syntheticVideoFrame(size: CGSize(width: 1280, height: 800))

    let scenario: String
    let canvas: CGSize
    let window: NSWindow
    let compositor: PreviewCompositorView
    let project: Project
    var interaction: PreviewInteractionView!
    var time: TimeInterval = 1.0
    var isPlaying = false
    var sel = Selection()
    var cameraPoster: NSImage?
    private var names: [UUID: String] = [:]
    private var events: [String] = []
    private var out: [String] = []
    private var lastState: [(String, String)] = []
    private var step = 0

    init(scenario: String, canvas: CGSize) {
        self.scenario = scenario
        self.canvas = canvas
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: canvas),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        compositor = PreviewCompositorView(frame: NSRect(origin: .zero, size: canvas))
        compositor.rasterScaleOverride = 1
        window.contentView = compositor
        project = PreviewParityHarness.makeFixtureProject()
        project.previewCanvasSize = canvas
    }

    // MARK: Fixture helpers

    func id(_ name: String, _ n: Int) -> UUID {
        let u = UUID(uuidString: String(format: "00000000-0000-4000-A000-%012d", n))!
        names[u] = name
        return u
    }

    func annotation(
        _ name: String, _ type: AnnotationType,
        _ x: Double, _ y: Double, _ ex: Double, _ ey: Double,
        id n: Int, text: String? = nil, strokes: [[(Double, Double)]] = []
    ) -> Annotation {
        var a = Annotation(id: id(name, n), type: type, startTime: 0, endTime: 10)
        a.x = x; a.y = y; a.arrowEndX = ex; a.arrowEndY = ey
        if let text { a.text = text }
        if !strokes.isEmpty {
            a.drawingStrokes = strokes.map { $0.map { CodablePoint(x: $0.0, y: $0.1) } }
        }
        return a
    }

    func ann(_ name: String) -> Annotation {
        project.annotations.first { names[$0.id] == name }!
    }

    func installWatermark() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-preview-gesture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wm.png")
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if let ctx = CGContext(data: nil, width: 160, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                               space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 48))
            if let image = ctx.makeImage(),
               let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        project.videoURL = dir.appendingPathComponent("video.mov")
        project.settings.showWatermark = true
        project.settings.watermarkFileName = "wm.png"
    }

    // MARK: Lifecycle

    func start() {
        compositor.onSelectAnnotation = { [unowned self] id in
            events.append("selAnn=\(name(id))"); sel.annotation = id
        }
        compositor.onSelectHighlight = { [unowned self] id in
            events.append("selHl=\(name(id))"); sel.highlight = id
        }
        compositor.onSelectDepthFocus = { [unowned self] id in
            events.append("selDepth=\(name(id))"); sel.depth = id
        }
        compositor.onSelectBlurRegion = { [unowned self] id in
            events.append("selBlur=\(name(id))"); sel.blur = id
        }
        compositor.onSetZoomFocal = { [unowned self] p in
            events.append("focal=\(fmt(p))")
            if let z = sel.zoom, let i = project.zoomRegions.firstIndex(where: { $0.id == z }) {
                project.zoomRegions[i].focalPoint = p
            }
        }
        compositor.onCreateBlurRegion = { [unowned self] rect, style in
            events.append("create=\(fmt(rect)) \(style.rawValue)")
        }
        compositor.onCanvasDragEnded = { [unowned self] in events.append("dragEnded") }

        window.orderFrontRegardless()
        render()
        compositor.layoutSubtreeIfNeeded()
        render()
        interaction = Self.findInteraction(in: compositor)
        // Mouse-driven probe: the real pointer must not leak hover events in.
        for area in interaction.trackingAreas { interaction.removeTrackingArea(area) }
        out.append("== \(scenario) \(Int(canvas.width))x\(Int(canvas.height))")
        lastState = []
        out.append(contentsOf: diffState())
    }

    func finish() -> [String] {
        window.orderOut(nil)
        return out
    }

    func render() {
        compositor.render(PreviewCompositorView.FrameInput(
            project: project,
            currentTime: time,
            isPlaying: isPlaying,
            cursorEvents: [],
            cursorCoordinateSize: CGSize(width: 1280, height: 800),
            videoSize: CGSize(width: 1280, height: 800),
            player: nil,
            cameraPlayer: nil,
            cameraPosterImage: cameraPoster,
            cameraVideoAspect: 16.0 / 9,
            videoPosterImage: Self.videoPoster,
            selectedAnnotationID: sel.annotation,
            selectedHighlightID: sel.highlight,
            selectedBlurID: sel.blur,
            selectedDepthFocusID: sel.depth,
            selectedZoomID: sel.zoom
        ))
    }

    // MARK: Geometry (targeting only — the gesture math is what's under test)

    var ctx: PreviewInteractionView.HitContext { interaction.context! }

    /// Unit point in the video → canvas point, through the zoom/excursion
    /// forward transform (tilt ignored: targets are sized to absorb it).
    func v(_ ux: Double, _ uy: Double) -> CGPoint {
        let c = ctx
        let content = CGPoint(x: c.contentRect.minX + c.videoRect.minX + ux * c.videoRect.width,
                              y: c.contentRect.minY + c.videoRect.minY + uy * c.videoRect.height)
        return forward(content)
    }

    private func forward(_ q: CGPoint) -> CGPoint {
        let c = ctx
        return CGPoint(x: c.zoomAnchor.x + c.cardOffset.x * c.canvas.width + c.zoom * (q.x - c.zoomAnchor.x),
                       y: c.zoomAnchor.y + c.cardOffset.y * c.canvas.height + c.zoom * (q.y - c.zoomAnchor.y))
    }

    /// Centre of a selected region's value pill (RegionPillPlacement port).
    func pillCenter(_ norm: CGRect) -> CGPoint {
        let c = ctx, vr = c.videoRect
        let r = CGRect(x: vr.minX + norm.minX * vr.width, y: vr.minY + norm.minY * vr.height,
                       width: max(30, norm.width * vr.width), height: max(20, norm.height * vr.height))
        let pillWidth = min(max(90, r.width - 60), 150) + 54
        let h = RegionHandleChrome.pillHeight, gap = RegionHandleChrome.pillGap
        let y = r.maxY + gap + h <= vr.maxY ? r.maxY + gap : r.maxY - gap - h
        let lower = vr.minX + pillWidth / 2, upper = vr.maxX - pillWidth / 2
        let cx = upper >= lower ? min(max(r.midX, lower), upper) : vr.midX
        return forward(CGPoint(x: c.contentRect.minX + cx, y: c.contentRect.minY + y + h / 2))
    }

    // MARK: Gestures

    func drag(_ label: String, from start: CGPoint, by deltas: [(Double, Double)]) {
        drag(label, from: start, to: deltas.map { CGPoint(x: start.x + $0.0, y: start.y + $0.1) })
    }

    func drag(_ label: String, from start: CGPoint, to points: [CGPoint]) {
        send(.leftMouseDown, at: start)
        render()
        for p in points {
            send(.leftMouseDragged, at: p)
            render()
        }
        let dragging = interaction.isActivelyDragging
        send(.leftMouseUp, at: points.last ?? start)
        render()
        record(label, extra: "from \(fmt(start)) drag=\(dragging)")
    }

    func click(_ label: String, at p: CGPoint, clickCount: Int = 1) {
        send(.leftMouseDown, at: p, clickCount: clickCount)
        render()
        send(.leftMouseUp, at: p, clickCount: clickCount)
        render()
        record(label, extra: "at \(fmt(p))" + (clickCount > 1 ? " x\(clickCount)" : ""))
    }

    func escape(_ label: String) {
        interaction.cancelOperation(nil)
        render()
        record(label)
    }

    func note(_ text: String) { out.append("   note: \(text)") }

    private func send(_ type: NSEvent.EventType, at canvasPoint: CGPoint, clickCount: Int = 1) {
        let windowPoint = interaction.convert(canvasPoint, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: 1
        ) else { return }
        switch type {
        case .leftMouseDown: interaction.mouseDown(with: event)
        case .leftMouseDragged: interaction.mouseDragged(with: event)
        case .leftMouseUp: interaction.mouseUp(with: event)
        default: break
        }
    }

    // MARK: Transcript

    private func record(_ label: String, extra: String = "") {
        step += 1
        out.append(String(format: "%@.%02d %@", scenario, step, label) + (extra.isEmpty ? "" : "  (\(extra))"))
        out.append("   events: " + (events.isEmpty ? "-" : events.joined(separator: ", ")))
        events.removeAll()
        out.append(contentsOf: diffState())
    }

    /// State lines that changed since the last record (all of them the first time).
    private func diffState() -> [String] {
        let now = state()
        let before = Dictionary(lastState, uniquingKeysWith: { a, _ in a })
        lastState = now
        return now.compactMap { key, value in before[key] == value ? nil : "   \(key): \(value)" }
    }

    private func state() -> [(String, String)] {
        var s: [(String, String)] = []
        let c = ctx
        s.append(("ctx", "content=\(fmt(c.contentRect)) video=\(fmt(c.videoRect)) zoom=\(f(c.zoom)) "
                  + "anchor=\(fmt(c.zoomAnchor)) off=\(fmt(c.cardOffset))"))
        s.append(("chrome", "cam=\(fmt(c.cameraRect)) sub=\(fmt(c.subtitleRect)) wm=\(fmt(c.watermarkRect)) "
                  + "stack=\(c.stack.map { "\(fmt($0.cameraRow)) seam=\(f($0.seamY))" } ?? "nil")"))
        for a in project.annotations {
            var line = "\(fmt(CGPoint(x: a.x, y: a.y)))→\(fmt(CGPoint(x: a.arrowEndX, y: a.arrowEndY)))"
            if a.type == .drawing {
                let last = a.drawingStrokes.last?.last.map { fmt(CGPoint(x: $0.x, y: $0.y)) } ?? "-"
                line += " strokes=\(a.drawingStrokes.count) points=\(a.drawingStrokes.map(\.count)) last=\(last)"
            }
            if a.type == .text || a.type == .callout { line += " text=\"\(a.text)\"" }
            s.append(("ann.\(name(a.id))", line))
        }
        for r in project.blurRegions { s.append(("blur.\(name(r.id))", "\(fmt(r.rect)) intensity=\(f(r.intensity))")) }
        for r in project.highlightRegions { s.append(("hl.\(name(r.id))", "\(fmt(r.rect)) opacity=\(f(r.opacity))")) }
        for r in project.focusRegions { s.append(("focus.\(name(r.id))", "\(fmt(r.rect)) intensity=\(f(r.intensity))")) }
        for z in project.zoomRegions {
            s.append(("zoom.\(name(z.id))", "focal=\(fmt(z.focalPoint)) off=\(opt(z.cardOffsetX)),\(opt(z.cardOffsetY))"))
        }
        let st = project.settings
        s.append(("settings", "cam=\(st.cameraPosition.rawValue) custom=\(pair(st.cameraCustomX, st.cameraCustomY)) "
                  + "wm=\(f(st.watermarkX)),\(f(st.watermarkY)) "
                  + "sub=\(st.subtitlePosition.rawValue) custom=\(pair(st.subtitleCustomX, st.subtitleCustomY)) "
                  + "card=\(st.videoPlacement.rawValue) custom=\(pair(st.videoCustomX, st.videoCustomY)) "
                  + "stack=\(opt(st.cameraStackRatio))"))
        s.append(("selection", "ann=\(name(sel.annotation)) hl=\(name(sel.highlight)) blur=\(name(sel.blur)) "
                  + "depth=\(name(sel.depth)) zoom=\(name(sel.zoom))"))
        s.append(("ui", "editing=\(name(interaction.inlineEditingID)) dragging=\(interaction.isActivelyDragging) "
                  + "toolbarAnchor=\(fmt(interaction.selectedAnnotationViewRect())) "
                  + "undo=\(window.undoManager?.undoActionName ?? "-")"))
        return s
    }

    private func name(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return names[id] ?? "?"
    }

    private func f(_ v: Double) -> String { String(format: "%.6f", v) }
    private func f(_ v: CGFloat) -> String { String(format: "%.6f", Double(v)) }
    private func opt(_ v: Double?) -> String { v.map { f($0) } ?? "nil" }
    private func pair(_ x: Double?, _ y: Double?) -> String {
        x == nil && y == nil ? "nil" : "\(opt(x)),\(opt(y))"
    }
    private func fmt(_ p: CGPoint) -> String { "(\(f(p.x)),\(f(p.y)))" }
    private func fmt(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return "[\(f(r.minX)),\(f(r.minY)) \(f(r.width))x\(f(r.height))]"
    }

    private static func findInteraction(in root: NSView) -> PreviewInteractionView? {
        if let match = root as? PreviewInteractionView { return match }
        for sub in root.subviews {
            if let found = findInteraction(in: sub) { return found }
        }
        return nil
    }
}
