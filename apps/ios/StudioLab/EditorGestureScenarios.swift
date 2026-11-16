import UIKit

/// The Mac `--preview-gesture-test` scenarios (PreviewGestureHarness), gesture
/// for gesture — same objects, ids, times, canvases and targets — run against
/// the iOS editor by `EditorRig`. Keep in step with the Mac file: the
/// transcripts are compared line for line.
@available(iOS 26, *)
@MainActor
struct EditorGestureScenarios {
    let name: String
    let canvas: CGSize
    /// The user's stage magnification for the run (pinch / zoom pill): the
    /// canvas gestures — and so the transcript — must not depend on it.
    var stageZoom: CGFloat = 1
    let run: (EditorRig, UIViewController) async -> Void

    init(name: String, canvas: CGSize, stageZoom: CGFloat = 1,
         run: @escaping (EditorRig, UIViewController) async -> Void) {
        self.name = name
        self.canvas = canvas
        self.stageZoom = stageZoom
        self.run = run
    }

    static let wide = CGSize(width: 960, height: 540)

    static let all: [EditorGestureScenarios] = [
        .init(name: "annotations", canvas: wide, run: annotations),
        .init(name: "regions", canvas: wide, run: regions),
        .init(name: "zoom", canvas: wide, run: zoom),
        .init(name: "tilt", canvas: wide, run: tilt),
        .init(name: "chrome", canvas: wide, run: chrome),
        .init(name: "stack", canvas: CGSize(width: 540, height: 960), run: stack),
        .init(name: "blurDraw", canvas: wide, run: blurDraw),
        // Again, on a stage magnified 2× through the stage card's zoom path.
        .init(name: "regions", canvas: wide, stageZoom: 2, run: regions),
    ]

    static func annotations(_ rig: EditorRig, _ host: UIViewController) async {
        let p = rig.template
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
        await rig.start(host: host)
        guard rig.editor != nil else { return }

        await rig.drag("rect body move", from: rig.v(0.20, 0.20), by: [(20, 12), (40, 25)])
        let r = { rig.ann("R") }
        await rig.drag("rect TL handle", from: rig.v(r().x, r().y), by: [(-15, -10)])
        await rig.drag("rect BR handle", from: rig.v(r().arrowEndX, r().arrowEndY), by: [(10, 20)])
        let e = { rig.ann("E") }
        await rig.drag("ellipse TR handle", from: rig.v(e().arrowEndX, e().y), by: [(12, -8)])
        await rig.drag("ellipse BL handle", from: rig.v(e().x, e().arrowEndY), by: [(-6, 9)])
        let a = { rig.ann("A") }
        await rig.drag("arrow head", from: rig.v(a().arrowEndX, a().arrowEndY), by: [(20, 10)])
        await rig.drag("arrow tail", from: rig.v(a().x, a().y), by: [(-10, 5)])
        await rig.drag("arrow body clamps at the video edge",
                       from: rig.v((a().x + a().arrowEndX) / 2, (a().y + a().arrowEndY) / 2), by: [(300, 0), (600, 0)])
        await rig.drag("text body", from: rig.v(0.50, 0.55), by: [(30, -20)])
        await rig.drag("tap body", from: rig.v(0.75, 0.72), by: [(-25, 15)])
        await rig.drag("callout body", from: rig.v(0.15, 0.70), by: [(15, 10)])
        await rig.click("click drawing ink selects it", at: rig.v(0.45, 0.85))
        await rig.drag("pen stroke on the selected drawing", from: rig.v(0.30, 0.40), by: [(10, 4), (24, 10)])
        let t = { rig.ann("T") }
        await rig.click("click text while the drawing is selected adds a pen dot", at: rig.v(t().x, t().y))
        await rig.click("double-click text edits in place", at: rig.v(t().x, t().y), clickCount: 2)
        await rig.click("click-away commits the edit", at: rig.v(0.92, 0.55))
        await rig.drag("click empty card: below drag threshold", from: rig.v(0.92, 0.55), by: [(3, 2)])
        await rig.drag("card placement drag", from: rig.v(0.92, 0.55), by: [(30, 15), (60, 30)])
        await rig.drag("card back to centre (magnetism)", from: rig.v(0.92, 0.55), by: [(-30, -15), (-60, -30)])
        await rig.click("select rect", at: rig.v((r().x + r().arrowEndX) / 2, (r().y + r().arrowEndY) / 2))
        await rig.escape("esc deselects everything")
        await rig.setPlaying(true)
        await rig.drag("playing: annotations are not hit, the card drags",
                       from: rig.v((r().x + r().arrowEndX) / 2, (r().y + r().arrowEndY) / 2), by: [(40, 0), (120, 0)])
        await rig.setPlaying(false)
    }

    static func regions(_ rig: EditorRig, _ host: UIViewController) async {
        let p = rig.template
        p.blurRegions = [BlurRegion(id: rig.id("B", 11), startTime: 0, endTime: 10,
                                    rect: CGRect(x: 0.08, y: 0.08, width: 0.30, height: 0.20), intensity: 0.6)]
        p.highlightRegions = [HighlightRegion(id: rig.id("H", 12), startTime: 0, endTime: 10,
                                              rect: CGRect(x: 0.55, y: 0.10, width: 0.30, height: 0.25), opacity: 0.55)]
        p.focusRegions = [FocusRegion(id: rig.id("F", 13), startTime: 0, endTime: 10,
                                      rect: CGRect(x: 0.30, y: 0.55, width: 0.40, height: 0.30), intensity: 0.7)]
        await rig.start(host: host)
        guard rig.editor != nil else { return }

        let h = { rig.project.highlightRegions[0].rect }
        let b = { rig.project.blurRegions[0].rect }
        let f = { rig.project.focusRegions[0].rect }
        await rig.drag("blur body selects + moves", from: rig.v(b().midX, b().midY), by: [(10, 10)])
        await rig.drag("blur TL corner", from: rig.v(b().minX, b().minY), by: [(-10, -10)])
        await rig.drag("blur value pill", from: rig.pillCenter(b()), by: [(-30, 0)])
        await rig.drag("focus body selects + moves", from: rig.v(f().midX, f().midY), by: [(-20, 30)])
        await rig.drag("focus right edge", from: rig.v(f().maxX, f().midY), by: [(40, 0)])
        await rig.drag("focus value pill (tucked inside)", from: rig.pillCenter(f()), by: [(60, 0)])
        await rig.drag("highlight body selects + moves", from: rig.v(h().midX, h().midY), by: [(15, 10), (30, 20)])
        await rig.drag("highlight BR corner", from: rig.v(h().maxX, h().maxY), by: [(25, 15)])
        await rig.drag("highlight top edge", from: rig.v(h().midX, h().minY), by: [(0, -20)])
        await rig.drag("highlight value pill", from: rig.pillCenter(h()), by: [(40, 0), (-200, 0)])
        await rig.click("card click deselects every region", at: rig.v(0.15, 0.45))
        await rig.click("reselect highlight", at: rig.v(h().midX, h().midY))
        await rig.drag("highlight left edge clamps at 0", from: rig.v(h().minX, h().midY), by: [(-250, 0), (-500, 0)])
        await rig.drag("highlight right edge stops at the minimum size", from: rig.v(h().maxX, h().midY), by: [(-800, 0)])
    }

    static func zoom(_ rig: EditorRig, _ host: UIViewController) async {
        let p = rig.template
        p.zoomRegions = [ZoomRegion(id: rig.id("Z", 21), startTime: 0.5, endTime: 5, zoomLevel: 1.8,
                                    focalPoint: CGPoint(x: 0.35, y: 0.40), cardOffsetX: 0.05, cardOffsetY: -0.03)]
        p.annotations = [rig.annotation("R", .rectangle, 0.30, 0.30, 0.45, 0.45, id: 22)]
        rig.time = 2.0
        rig.sel.zoom = p.zoomRegions[0].id
        await rig.start(host: host)
        guard rig.editor != nil else { return }

        let z = { rig.project.zoomRegions[0] }
        await rig.drag("focal target drag", from: rig.v(z().focalPoint.x, z().focalPoint.y), by: [(15, 10), (30, 20)])
        await rig.drag("focal target clamps to the video", from: rig.v(z().focalPoint.x, z().focalPoint.y),
                       by: [(-2000, -2000)])
        rig.editor.selection.selectedZoomID = nil
        rig.render()
        let r = { rig.ann("R") }
        await rig.drag("rect body under zoom", from: rig.v((r().x + r().arrowEndX) / 2, (r().y + r().arrowEndY) / 2),
                       by: [(25, 10)])
        await rig.drag("block excursion drag", from: rig.v(0.15, 0.25), by: [(25, 10), (50, 20)])
        let ox = z().cardOffsetX ?? 0, oy = z().cardOffsetY ?? 0
        await rig.drag("block excursion back home (rest magnetism)", from: rig.v(0.15, 0.25),
                       by: [(-ox * 480, -oy * 270), (-ox * 960, -oy * 540)])
    }

    static func tilt(_ rig: EditorRig, _ host: UIViewController) async {
        let p = rig.template
        p.tiltRegions = [TiltRegion(startTime: 0, endTime: 10, pitch: 15, yaw: -12, roll: 4)]
        p.annotations = [
            rig.annotation("R", .rectangle, 0.35, 0.35, 0.60, 0.60, id: 31),
            rig.annotation("T", .text, 0.20, 0.80, 0.30, 0.80, id: 32, text: "Tilted"),
        ]
        rig.time = 2.0
        await rig.start(host: host)
        guard rig.editor != nil else { return }
        let r = { rig.ann("R") }
        await rig.drag("rect body under tilt", from: rig.v(0.475, 0.475), by: [(30, 15)])
        await rig.drag("rect BR under tilt", from: rig.v(r().arrowEndX, r().arrowEndY), by: [(-12, 8)])
        await rig.drag("text under tilt", from: rig.v(0.20, 0.80), by: [(20, -10)])
        await rig.drag("card drag under tilt", from: rig.v(0.85, 0.15), by: [(45, 20), (90, 40)])
    }

    static func chrome(_ rig: EditorRig, _ host: UIViewController) async {
        let s = rig.template.settings
        s.showCamera = true
        s.showSubtitles = true
        rig.template.subtitles = [SubtitleSegment(startTime: 0, endTime: 10, text: "Gesture freeze")]
        rig.usesWatermark = true
        rig.usesCamera = true
        await rig.start(host: host)
        guard rig.editor != nil else { return }

        func center(_ r: CGRect?) -> CGPoint { CGPoint(x: r?.midX ?? -100, y: r?.midY ?? -100) }
        await rig.drag("watermark drag", from: center(rig.ctx.watermarkRect), by: [(-100, -50), (-200, -100)])
        await rig.drag("camera drag", from: center(rig.ctx.cameraRect), by: [(-50, -30), (-100, -60)])
        await rig.drag("camera corner magnetism", from: center(rig.ctx.cameraRect), by: [(-2000, -2000)])
        await rig.drag("subtitle drag", from: center(rig.ctx.subtitleRect), by: [(0, -60), (0, -120)])
        await rig.drag("subtitle anchor magnetism", from: center(rig.ctx.subtitleRect), by: [(0, 2000)])
        await rig.drag("watermark edge magnetism", from: center(rig.ctx.watermarkRect), by: [(92, 46), (184, 93)])
    }

    static func stack(_ rig: EditorRig, _ host: UIViewController) async {
        let s = rig.template.settings
        s.aspectRatio = .vertical
        s.showCamera = true
        s.cameraPortraitStack = true
        rig.usesCamera = true
        await rig.start(host: host)
        guard rig.editor != nil else { return }
        if let stack = rig.ctx.stack {
            await rig.drag("stack seam drag", from: CGPoint(x: stack.cameraRow.midX, y: stack.seamY), by: [(0, 30), (0, 60)])
            await rig.click("stacked camera row is inert", at: CGPoint(x: stack.cameraRow.midX, y: stack.cameraRow.midY))
        } else {
            rig.note("no stack seam in the hit context")
        }
    }

    static func blurDraw(_ rig: EditorRig, _ host: UIViewController) async {
        await rig.start(host: host)
        guard rig.editor != nil else { return }
        // The Mac rig's onCreateBlurRegion only logs; the editor's real
        // creation (the shared timeline edit) is checked after.
        rig.logBlurCreationOnly()
        let canvas = rig.editor.canvas
        canvas.armBlurDraw(style: .pixelate)
        await rig.drag("armed draw: drag out a region", from: rig.v(0.20, 0.20),
                       to: [rig.v(0.35, 0.30), rig.v(0.50, 0.45)])
        canvas.armBlurDraw(style: .blur)
        await rig.click("armed draw: a click grows to the minimum", at: rig.v(0.60, 0.60))
        canvas.armBlurDraw(style: .blur)
        await rig.escape("armed draw: esc disarms")
        await rig.click("after disarm a click is an ordinary card click", at: rig.v(0.60, 0.60))
        canvas.armBlurDraw(style: .pixelate)
        await rig.drag("armed draw past the edge is clipped to the video", from: rig.v(0.90, 0.90),
                       to: [rig.v(1.10, 1.05), rig.v(1.30, 1.20)])
        await rig.checkRealBlurCreation()
    }
}

@available(iOS 26, *)
extension EditorRig {
    /// The Mac rig's creation callback: log `create=`, create nothing.
    func logBlurCreationOnly() {
        editor.canvas.gestures.onCreateBlurRegion = { [weak self] rect, style in
            self?.editor.canvasEventLog?("create=\(EditorEventFormat.rect(rect)) \(style.rawValue)")
        }
    }

    /// Off the transcript: an armed draw through the EDITOR's own wiring
    /// creates the region via the shared timeline edit, selects it and
    /// registers "Add Pixelate"; undo removes it.
    func checkRealBlurCreation() async {
        let editor = editor!
        // Re-wire as the editor does (viewDidLoad's closure was replaced).
        editor.canvas.gestures.onCreateBlurRegion = { [weak editor] rect, style in
            editor?.timelineEdits.createBlurRegion(rect: rect, style: style)
            editor?.renderStage()
        }
        let before = project.blurRegions.count
        editor.canvas.armBlurDraw(style: .pixelate)
        let start = v(0.20, 0.20), end = v(0.50, 0.45)
        let canvasView = editor.canvas
        let tp = { (p: CGPoint) in canvasView.convert(editor.stage.viewPoint(fromCanvas: p), from: editor.stage) }
        canvasView.touchDown(atView: tp(start), tapCount: 1)
        canvasView.touchMoved(toView: [tp(end)])
        canvasView.touchUp(atView: tp(end))
        render()
        await LabTime.settle(0.05)
        guard project.blurRegions.count == before + 1, let region = project.blurRegions.last else {
            failures.append("blurDraw: the editor's armed draw created no region")
            return
        }
        let r = region.rect
        let ok = abs(r.minX - 0.2) < 1e-6 && abs(r.minY - 0.2) < 1e-6
            && abs(r.width - 0.3) < 1e-6 && abs(r.height - 0.25) < 1e-6
            && region.style == .pixelate && editor.selection.selectedBlurID == region.id
            && editor.undoManager?.undoActionName == "Add Pixelate"
        print("   real creation: \(EditorEventFormat.rect(r)) \(region.style.rawValue) "
              + "selected=\(editor.selection.selectedBlurID == region.id) undo=\(editor.undoManager?.undoActionName ?? "-")")
        if !ok { failures.append("blurDraw: real creation wrote \(EditorEventFormat.rect(r)) \(region.style.rawValue)") }
    }
}
