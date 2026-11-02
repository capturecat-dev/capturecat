import CoreGraphics
import Foundation

/// `--cameralayout-test`, camera STYLES half (docs/camera-cutout.md §12): the
/// new settings + region key (round trip, lenient decode, byte-identical when
/// unset), pop-out amount and border geometry, the `CameraMaskEdge` integer
/// algorithm against hand-computed bytes (the same numbers the TS twin's
/// tests use), Side by Side camera side + its morph, and the shrink toggle.
extension CameraLayoutHarness {
    static func cameraStyleChecks(expect: (Bool, String) -> Void) {
        styleModelChecks(expect: expect)
        styleGeometryChecks(expect: expect)
        maskEdgeChecks(expect: expect)
        sideChecks(expect: expect)
        let off = ReactiveCameraLayout.layoutZoom(2, shrinkOnZoom: false)
        let on = ReactiveCameraLayout.layoutZoom(2, shrinkOnZoom: true)
        expect(off == 1 && on == 2, "layoutZoom: shrink off → zoom 1, on → zoom passes through")
    }

    // MARK: - Model

    private static func settingsJSON(_ p: Project) -> [String: Any]? {
        (try? JSONEncoder().encode(p)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["settings"]
            as? [String: Any]
    }

    private static let styleKeys = [
        "cameraPopOutAmount", "cameraCardFill", "cameraCardGradientStart", "cameraCardGradientEnd",
        "cameraCardColor", "cameraCardImagePath", "cameraBackgroundBlur", "cameraEdgeSoftness",
        "cameraEdgeInset", "cameraCardBorder", "cameraCardBorderWidth", "cameraCardBorderColor", "cameraShrinkOnZoom",
    ]

    private static func same(_ a: CodableColor?, _ b: CodableColor?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.red == b.red && a.green == b.green && a.blue == b.blue && a.opacity == b.opacity
    }

    private static func styleModelChecks(expect: (Bool, String) -> Void) {
        let project = Project(id: UUID(), name: "styles", videoURL: URL(fileURLWithPath: "/tmp/none.mov"), duration: 10)
        let untouched = settingsJSON(project) ?? [:]
        expect(styleKeys.allSatisfy { untouched[$0] == nil }, "no style set → none of the §12 keys is written")
        let s = project.settings
        s.cameraPopOutAmount = 0.8
        s.cameraCardFill = .camera
        s.cameraCardGradientStart = CodableColor(red: 1, green: 0, blue: 0, opacity: 1)
        s.cameraCardGradientEnd = CodableColor(red: 0, green: 0, blue: 1, opacity: 1)
        s.cameraCardColor = CodableColor(red: 0.2, green: 0.3, blue: 0.4, opacity: 1)
        s.cameraCardImagePath = "/tmp/card.png"
        s.cameraBackgroundBlur = 0.6
        s.cameraEdgeSoftness = 0.4
        s.cameraEdgeInset = 0.3
        s.cameraCardBorder = .aurora
        s.cameraCardBorderWidth = 0.7
        s.cameraCardBorderColor = CodableColor(red: 1, green: 1, blue: 0, opacity: 1)
        s.cameraShrinkOnZoom = false
        let written = settingsJSON(project) ?? [:]
        expect(styleKeys.allSatisfy { written[$0] != nil }, "every §12 key is written once set")
        expect(written["cameraCardFill"] as? String == "camera" && written["cameraCardBorder"] as? String == "aurora",
               "enum keys encode their raw values")
        if let data = try? JSONEncoder().encode(project), let back = try? JSONDecoder().decode(Project.self, from: data) {
            let b = back.settings
            expect(b.cameraPopOutAmount == 0.8 && b.cameraCardFill == .camera && b.cameraCardImagePath == "/tmp/card.png"
                   && b.cameraBackgroundBlur == 0.6 && b.cameraEdgeSoftness == 0.4 && b.cameraEdgeInset == 0.3
                   && b.cameraCardBorder == .aurora && b.cameraCardBorderWidth == 0.7 && b.cameraShrinkOnZoom == false
                   && same(b.cameraCardColor, s.cameraCardColor) && same(b.cameraCardGradientStart, s.cameraCardGradientStart)
                   && same(b.cameraCardGradientEnd, s.cameraCardGradientEnd) && same(b.cameraCardBorderColor, s.cameraCardBorderColor),
                   "every §12 key round-trips")
        } else {
            expect(false, "§12 project round trip failed")
        }
        // Lenient: garbage in any key → nil, and the project still loads.
        let garbage: [String: Any] = [
            "cameraPopOutAmount": "lots", "cameraCardFill": "hologram", "cameraCardGradientStart": "red",
            "cameraCardGradientEnd": 4, "cameraCardColor": ["red": "x"], "cameraCardImagePath": 12,
            "cameraBackgroundBlur": [1], "cameraEdgeSoftness": NSNull(), "cameraEdgeInset": true,
            "cameraCardBorder": 1, "cameraCardBorderWidth": "thick", "cameraCardBorderColor": [:] as [String: Any],
            "cameraShrinkOnZoom": "no",
        ]
        if let data = try? JSONEncoder().encode(Project(id: UUID(), name: "garbage", videoURL: URL(fileURLWithPath: "/tmp/none.mov"), duration: 10)),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var settings = object["settings"] as? [String: Any] {
            for (k, v) in garbage { settings[k] = v }
            object["settings"] = settings
            let decoded = (try? JSONSerialization.data(withJSONObject: object))
                .flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
            let d = decoded?.settings
            expect(d != nil && d?.cameraPopOutAmount == nil && d?.cameraCardFill == nil && d?.cameraCardGradientStart == nil
                   && d?.cameraCardGradientEnd == nil && d?.cameraCardColor == nil && d?.cameraCardImagePath == nil
                   && d?.cameraBackgroundBlur == nil && d?.cameraEdgeSoftness == nil && d?.cameraEdgeInset == nil
                   && d?.cameraCardBorder == nil && d?.cameraCardBorderWidth == nil && d?.cameraCardBorderColor == nil
                   && d?.cameraShrinkOnZoom == nil,
                   "garbage in every §12 key → nil, and the project still loads")
        } else {
            expect(false, "garbage fixture failed to build")
        }
        // Region side.
        let leading = CameraLayoutRegion(startTime: 0, endTime: 2, mode: .sideBySide, cameraSide: .leading)
        let trailing = CameraLayoutRegion(startTime: 2, endTime: 4, mode: .sideBySide, cameraSide: .trailing)
        let none = CameraLayoutRegion(startTime: 4, endTime: 6, mode: .sideBySide)
        if let data = try? JSONEncoder().encode([leading, trailing, none]),
           let back = try? JSONDecoder().decode([CameraLayoutRegion].self, from: data),
           let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            expect(back == [leading, trailing, none], "cameraSide round-trips (leading, explicit trailing, absent)")
            expect(objects[0]["cameraSide"] as? String == "leading" && objects[1]["cameraSide"] as? String == "trailing"
                   && objects[2]["cameraSide"] == nil, "cameraSide encodes only when set")
        } else {
            expect(false, "cameraSide round trip failed")
        }
        let odd = try? JSONDecoder().decode(CameraLayoutRegion.self, from: Data(#"{"mode":"sideBySide","cameraSide":"up"}"#.utf8))
        expect(odd != nil && odd?.cameraSide == nil && odd?.effectiveSide == .trailing, "unknown cameraSide → nil (trailing)")

        let defaults = CameraCardStyle(ProjectSettings())
        let top = CameraCutoutMath.cardTopColor
        expect(defaults.fill == .gradient && defaults.popOutAmount == nil && defaults.border == nil
               && defaults.shrinkOnZoom && defaults.backgroundBlur == 0 && !defaults.processesMaskEdge
               && defaults.gradientTop == CameraCardStyle.RGB(top.r, top.g, top.b),
               "CameraCardStyle defaults = today's card")
        let blurOnGradient = ProjectSettings()
        blurOnGradient.cameraBackgroundBlur = 1
        expect(CameraCardStyle(blurOnGradient).backgroundBlur == 0, "background blur only applies to the camera fill")
        let clamped = ProjectSettings()
        clamped.cameraPopOutAmount = 3
        clamped.cameraEdgeInset = -2
        let c = CameraCardStyle(clamped)
        expect(c.popOutAmount == 1 && c.edgeInset == 0, "numbers clamp at use (amount 3 → 1, inset −2 → 0)")
    }

    // MARK: - Geometry

    private static func styleGeometryChecks(expect: (Bool, String) -> Void) {
        let b = CGRect(x: 100, y: 50, width: 300, height: 200)
        let base = CameraCutoutMath.geometry(look: .popOut, bubbleRect: b, cameraAspect: 4.0 / 3.0)
        let half = CameraCutoutMath.geometry(look: .popOut, bubbleRect: b, cameraAspect: 4.0 / 3.0, popOutAmount: 0.5)
        expect(base == half && CameraCutoutMath.headroom(forAmount: 0.5) == CameraCutoutMath.headroomFraction,
               "amount 0.5 is today's card exactly (0.44 × 0.5 == 0.22)")
        let zero = CameraCutoutMath.geometry(look: .popOut, bubbleRect: b, cameraAspect: 4.0 / 3.0, popOutAmount: 0)
        expect(zero.cardRect == b, "amount 0 → the card is B (no breakout)")
        let one = CameraCutoutMath.geometry(look: .popOut, bubbleRect: b, cameraAspect: 4.0 / 3.0, popOutAmount: 1)
        expect(abs((one.cardRect?.minY ?? 0) - (b.minY + 0.44 * b.height)) < 1e-9, "amount 1 → headroom 0.44 × B.h")
        let up = CameraCutoutMath.geometry(look: .popOut, bubbleRect: b, cameraAspect: 4.0 / 3.0, popOutAmount: 1, yAxisIsUp: true)
        expect(up.cardRect?.minY == b.minY && abs((up.cardRect?.height ?? 0) - b.height * 0.56) < 1e-9,
               "Y-up keeps B's bottom and gives up the top")
        expect(base.cardBorderWidth == 0 && CameraCutoutMath.cardBorderInner(base) == nil, "no border → no ring")
        let ring = CameraCutoutMath.geometry(look: .popOut, bubbleRect: b, cameraAspect: 4.0 / 3.0, cardBorderWidth: 0.5)
        let card = ring.cardRect ?? .zero
        let w = 0.5 * 0.08 * min(card.width, card.height)
        expect(abs(ring.cardBorderWidth - w) < 1e-9, "border w = thickness × 0.08 × min(C)")
        if let inner = CameraCutoutMath.cardBorderInner(ring) {
            expect(inner.rect == card.insetBy(dx: w, dy: w) && abs(inner.radius - max(0, ring.cardCornerRadius - w)) < 1e-9,
                   "inner ring rect = C inset by w, radius max(0, r − w)")
        } else {
            expect(false, "a 0.5 border has an inner rect")
        }
        let cutout = CameraCutoutMath.geometry(look: .cutout, bubbleRect: b, cameraAspect: 4.0 / 3.0, cardBorderWidth: 1)
        expect(cutout.cardBorderWidth == 0, "the cutout never draws a ring")
        let fill = CameraCardStyle.imageFillRect(imageSize: CGSize(width: 100, height: 100), card: CGRect(x: 0, y: 0, width: 200, height: 100))
        expect(fill == CGRect(x: 0, y: -50, width: 200, height: 200), "image aspect-fills the card, centred")
    }

    // MARK: - Mask edge (§12.4)

    private static func maskEdgeChecks(expect: (Bool, String) -> Void) {
        let r192 = CameraMaskEdge.radii(height: 192, softness: 0.5, inset: 1)
        let r288 = CameraMaskEdge.radii(height: 288, softness: 0.5, inset: 1)
        expect(r192 == (6, 3) && r288 == (9, 5), "radii: 192 rows → (6, 3); 288 rows → (9, 5) (k = h / 192, round half up)")

        let width = 32, height = 192
        // A vertical band, α 255 for x ∈ [8, 24), the same on every row.
        var band = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 8..<24 { band[y * width + x] = 255 } }
        expect(CameraMaskEdge.process(band, width: width, height: height, softness: 0, inset: 0) == band,
               "softness 0 + inset 0 → the frame unchanged")
        // inset 1/6 → radius round(1/6 × 6) = 1: the band loses one column per side.
        let eroded = CameraMaskEdge.process(band, width: width, height: height, softness: 0, inset: 1.0 / 6.0)
        let row = Array(eroded[0..<width])
        expect(row[8] == 0 && row[9] == 255 && row[22] == 255 && row[23] == 0 && eroded.count == band.count,
               "inset radius 1 erodes the band to [9, 23)")
        // A step (0 | 255 at x = 16) through softness radius 1: two box passes
        // each way → 28, 85, 170, 227 across the edge (hand-computed; the TS
        // twin asserts the same bytes).
        var step = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 16..<width { step[y * width + x] = 255 } }
        let soft = CameraMaskEdge.process(step, width: width, height: height, softness: 1.0 / 6.0, inset: 0)
        let s = Array(soft[(100 * width)..<(101 * width)])
        expect(Array(s[13...18]) == [0, 28, 85, 170, 227, 255], "softness radius 1: step → 0, 28, 85, 170, 227, 255")
        // Clamp-to-edge: a lone bright left column survives a blur at the edge.
        var edge = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { edge[y * width] = 255 }
        let edgeSoft = CameraMaskEdge.process(edge, width: width, height: height, softness: 1.0 / 6.0, inset: 0)
        // pass 1: x0 = (255+255+0+1)/3 = 170, x1 = (255+0+0+1)/3 = 85;
        // pass 2: x0 = (170+170+85+1)/3 = 142, x1 = (170+85+0+1)/3 = 85, x2 = (85+0+0+1)/3 = 28.
        expect(Array(edgeSoft[(50 * width)..<(50 * width + 4)]) == [142, 85, 28, 0], "clamp-to-edge at the frame border")
        let cache = CameraMaskEdge.Cache()
        let token = UUID()
        let first = cache.processed(step, token: token, index: 3, width: width, height: height, softness: 1.0 / 6.0, inset: 0)
        let again = cache.processed(step, token: token, index: 3, width: width, height: height, softness: 1.0 / 6.0, inset: 0)
        expect(first == soft && again == soft, "cache returns process()'s bytes")
    }

    // MARK: - Side by Side side (§12.6)

    private static func sideChecks(expect: (Bool, String) -> Void) {
        let card = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let trailing = CameraLayoutMath.columns(in: card)
        let leading = CameraLayoutMath.columns(in: card, side: .leading)
        expect(leading.camera.minX == card.minX && leading.screen.maxX == card.maxX
               && leading.camera.size == trailing.camera.size && leading.screen.size == trailing.screen.size,
               "leading mirrors the row: camera at the left edge, screen at the right, same sizes")
        let bubble = CGRect(x: 850, y: 450, width: 120, height: 120)
        func resolve(_ t: TimeInterval, _ regions: [CameraLayoutRegion]) -> CameraLayoutMath.Resolved {
            CameraLayoutMath.resolve(at: t, regions: regions, videoRect: card, bubbleRect: bubble,
                                     bubbleCornerRadius: 60, cardCornerRadius: 12, hasCamera: true)
        }
        let settledLeft = resolve(1, [CameraLayoutRegion(startTime: 0, endTime: 5, mode: .sideBySide, cameraSide: .leading)])
        expect(settledLeft.cameraRect == leading.camera && settledLeft.cardTranslationX > 0,
               "settled leading: camera tile on the left, screen pushed right")
        let regions = [
            CameraLayoutRegion(startTime: 0, endTime: 5, mode: .sideBySide),
            CameraLayoutRegion(startTime: 5, endTime: 10, mode: .sideBySide, cameraSide: .leading),
        ]
        let mid = resolve(5 + CameraLayoutMath.transitionDuration / 2, regions)
        let x = mid.cameraRect?.minX ?? -1
        expect(x > leading.camera.minX + 1 && x < trailing.camera.minX - 1 && !mid.isPlainBubble,
               String(format: "adjacent trailing → leading morph: camera x %.1f strictly between %.1f and %.1f",
                      x, leading.camera.minX, trailing.camera.minX))
        let same = [
            CameraLayoutRegion(startTime: 0, endTime: 5, mode: .sideBySide),
            CameraLayoutRegion(startTime: 5, endTime: 10, mode: .sideBySide, cameraSide: .trailing),
        ]
        expect(resolve(5.1, same).cameraRect == trailing.camera, "absent side == explicit trailing (no morph)")
        let ignored = [CameraLayoutRegion(startTime: 0, endTime: 5, mode: .cameraOnly, cameraSide: .leading)]
        expect(resolve(1, ignored).cameraRect == card, "side on a non-split mode is ignored")

        // Full-height split (§12.11).
        let full = CameraLayoutMath.columns(in: card, style: .full)
        let fullLeft = CameraLayoutMath.columns(in: card, side: .leading, style: .full)
        expect(full.screen.minY == card.minY && full.screen.height == card.height
               && full.camera.height == card.height && full.screen.width == trailing.screen.width
               && full.camera.maxX == card.maxX && fullLeft.camera.minX == card.minX && fullLeft.screen.maxX == card.maxX,
               "full columns: both tiles the card's full height, widths as tiles, sides mirrored")
        let settledFull = resolve(1, [CameraLayoutRegion(startTime: 0, endTime: 5, mode: .sideBySide, splitStyle: .full)])
        expect(settledFull.cardScale == 1 && settledFull.cardClip == full.screen && settledFull.cameraRect == full.camera
               && abs(settledFull.cardTranslationX - (full.screen.midX - card.midX)) < 1e-9
               && settledFull.cardClipCornerRadius == 12,
               "settled full split: card at scale 1 slid so its centre sits in the screen column, clipped to it")
        expect(settledLeft.cardClip == nil && resolve(1, []).cardClip == nil, "tiles and bubble never clip")
        let toFull = [
            CameraLayoutRegion(startTime: 0, endTime: 5, mode: .sideBySide),
            CameraLayoutRegion(startTime: 5, endTime: 10, mode: .sideBySide, splitStyle: .full),
        ]
        let morph = resolve(5 + CameraLayoutMath.transitionDuration / 2, toFull)
        let tilesCard = card.applying(CameraLayoutMath.cardTransform(resolve(1, toFull), videoRect: card))
        if let c = morph.cardClip {
            expect(c.height > tilesCard.height + 1 && c.height < card.height - 1
                   && morph.cardScale > CameraLayoutMath.sideBySideScreenFraction && morph.cardScale < 1,
                   String(format: "tiles → full morph: clip height %.1f strictly between %.1f and %.1f, scale %.3f",
                          c.height, tilesCard.height, card.height, morph.cardScale))
        } else {
            expect(false, "tiles → full morph has a clip")
        }
        let start = resolve(5.0001, toFull)
        if let c = start.cardClip {
            let startCard = card.applying(CameraLayoutMath.cardTransform(start, videoRect: card))
            expect(abs(c.minX - startCard.minX) < 0.5 && abs(c.height - startCard.height) < 0.5,
                   "the clip opens from the scaled card's own outline (no pop at the edge)")
        } else {
            expect(false, "tiles → full morph start has a clip")
        }
        let sides = [
            CameraLayoutRegion(startTime: 0, endTime: 5, mode: .sideBySide, splitStyle: .full),
            CameraLayoutRegion(startTime: 5, endTime: 10, mode: .sideBySide, cameraSide: .leading, splitStyle: .full),
        ]
        let across = resolve(5 + CameraLayoutMath.transitionDuration / 2, sides)
        expect(across.cardClip != nil && (across.cameraRect?.minX ?? 0) > fullLeft.camera.minX + 1
               && (across.cameraRect?.minX ?? 0) < full.camera.minX - 1,
               "full trailing → full leading morphs (camera slides across, still clipped)")
        let splitRegions = [
            CameraLayoutRegion(startTime: 0, endTime: 2, mode: .sideBySide, splitStyle: .full),
            CameraLayoutRegion(startTime: 2, endTime: 4, mode: .sideBySide, splitStyle: .tiles),
            CameraLayoutRegion(startTime: 4, endTime: 6, mode: .sideBySide),
        ]
        if let data = try? JSONEncoder().encode(splitRegions),
           let back = try? JSONDecoder().decode([CameraLayoutRegion].self, from: data),
           let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            expect(back == splitRegions && objects[0]["splitStyle"] as? String == "full"
                   && objects[1]["splitStyle"] as? String == "tiles" && objects[2]["splitStyle"] == nil,
                   "splitStyle round-trips and encodes only when set")
        } else {
            expect(false, "splitStyle round trip failed")
        }
        let oddSplit = try? JSONDecoder().decode(CameraLayoutRegion.self, from: Data(#"{"mode":"sideBySide","splitStyle":9}"#.utf8))
        expect(oddSplit != nil && oddSplit?.splitStyle == nil, "garbage splitStyle → nil (tiles)")
        let fullOnCameraOnly = [CameraLayoutRegion(startTime: 0, endTime: 5, mode: .cameraOnly, splitStyle: .full)]
        expect(resolve(1, fullOnCameraOnly).cardClip == nil, "splitStyle on a non-split mode is ignored")
        stackChecks(expect: expect)
        stackZoomChecks(expect: expect)
        stackGapChecks(expect: expect)
    }

    // MARK: - Vertical stack (§12.12)

    private static func stackChecks(expect: (Bool, String) -> Void) {
        // A 9:16 canvas (1080 × 1920) with 48 px padding; the landscape card
        // fitted to the width in the middle.
        let area = CGRect(x: 48, y: 48, width: 984, height: 1824)
        let card = CGRect(x: 48, y: 683.25, width: 984, height: 553.5)
        let down = CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: false)
        let up = CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: true)
        let gap = area.height * CameraLayoutMath.stackGapFraction
        let h = (area.height - gap) * 0.42
        expect(down.camera == CGRect(x: 48, y: 48, width: 984, height: h)
               && abs(down.screen.minY - (48 + h + gap)) < 1e-9 && abs(down.screen.maxY - area.maxY) < 1e-9,
               "stack rows, Y-down: camera on top, screen below, a 2% gap")
        expect(abs(up.camera.maxY - area.maxY) < 1e-9 && up.screen.minY == area.minY
               && up.camera.height == down.camera.height && up.screen.height == down.screen.height,
               "stack rows, Y-up: the same rows mirrored (camera at maxY)")
        expect(CameraLayoutMath.stackRatio(nil) == 0.42 && CameraLayoutMath.stackRatio(0.1) == 0.25
               && CameraLayoutMath.stackRatio(0.9) == 0.7, "ratio defaults to 0.42 and clamps to 0.25…0.7")
        let bubble = CGRect(x: 800, y: 1600, width: 200, height: 200)
        func resolve(_ t: TimeInterval, _ regions: [CameraLayoutRegion], stack: CameraLayoutMath.StackRows?) -> CameraLayoutMath.Resolved {
            CameraLayoutMath.resolve(at: t, regions: regions, videoRect: card, bubbleRect: bubble,
                                     bubbleCornerRadius: 100, cardCornerRadius: 12, hasCamera: true, stack: stack)
        }
        let settled = resolve(1, [], stack: down)
        let fill = max(down.screen.width / card.width, down.screen.height / card.height)
        expect(settled.cameraRect == down.camera && settled.cardClip == down.screen
               && abs(settled.cardScale - fill) < 1e-9
               && abs(settled.cardTranslationY - (down.screen.midY - card.midY)) < 1e-9
               && abs(settled.cardTranslationX - (down.screen.midX - card.midX)) < 1e-9 && !settled.isPlainBubble,
               "settled stack (no regions): camera row on top, card fills and is clipped to the screen row")
        let moved = card.applying(CameraLayoutMath.cardTransform(settled, videoRect: card))
        expect(abs(moved.midY - down.screen.midY) < 1e-6 && moved.height >= down.screen.height - 1e-6
               && moved.width >= down.screen.width - 1e-6, "the transformed card covers the screen row, centred on it")
        expect(resolve(1, [], stack: nil).isPlainBubble, "no stack → the plain bubble, as before")
        let withBubble = [CameraLayoutRegion(startTime: 4, endTime: 8, mode: .bubble)]
        let inBubble = resolve(6, withBubble, stack: down)
        expect(inBubble.isPlainBubble && inBubble.cardClip == nil, "a Bubble block inside a stacked video shows the bubble")
        let mid = resolve(4 + CameraLayoutMath.transitionDuration / 2, withBubble, stack: down)
        expect(mid.cardClip != nil && mid.cardScale > 1 && mid.cardScale < fill
               && abs(mid.cardTranslationY) > 1 && abs(mid.cardTranslationY) < abs(settled.cardTranslationY),
               "stack → Bubble block morphs: scale and Y move strictly between the ends")
        let split = [CameraLayoutRegion(startTime: 0, endTime: 8, mode: .sideBySide, cameraSide: .leading, splitStyle: .full)]
        expect(resolve(2, split, stack: down).cardClip == down.screen, "Side by Side stacks while the stack is active")
        let stackedSplit = [CameraLayoutRegion(startTime: 4, endTime: 8, mode: .sideBySide)]
        expect(CameraLayoutMath.lookWeights(at: 1, regions: [], defaultLook: .popOut, stacking: true)
                    == .init(cutout: 0, popOut: 1)
               && CameraLayoutMath.lookWeights(at: 6, regions: withBubble, defaultLook: .popOut, stacking: true)
                    == .init(cutout: 0, popOut: 1)
               && CameraLayoutMath.lookWeights(at: 6, regions: stackedSplit, defaultLook: .popOut, stacking: true)
                    == .init(cutout: 0, popOut: 1)
               && CameraLayoutMath.lookWeights(at: 6, regions: stackedSplit, defaultLook: .popOut, stacking: false) == .none,
               "the stacked camera row wears the whole-video look (outside regions and on Side by Side, which stacks)")
        let settings = ProjectSettings()
        settings.cameraPortraitStack = true
        expect(CameraLayoutMath.stackActive(settings: settings, canvas: CGSize(width: 1080, height: 1920))
               && !CameraLayoutMath.stackActive(settings: settings, canvas: CGSize(width: 1920, height: 1080))
               && !CameraLayoutMath.stackActive(settings: ProjectSettings(), canvas: CGSize(width: 1080, height: 1920)),
               "the stack needs the switch AND a portrait canvas")
        let project = Project(id: UUID(), name: "stack", videoURL: URL(fileURLWithPath: "/tmp/none.mov"), duration: 10)
        project.settings.cameraPortraitStack = true
        project.settings.cameraStackRatio = 0.55
        if let data = try? JSONEncoder().encode(project), let back = try? JSONDecoder().decode(Project.self, from: data) {
            expect(back.settings.cameraPortraitStack == true && back.settings.cameraStackRatio == 0.55,
                   "stack keys round-trip")
        } else {
            expect(false, "stack round trip failed")
        }
    }
    // MARK: - Zoom inside the vertical stack (§12.13)

    private static func stackZoomChecks(expect: (Bool, String) -> Void) {
        let area = CGRect(x: 48, y: 48, width: 984, height: 1824)
        let card = CGRect(x: 48, y: 683.25, width: 984, height: 553.5)
        let bubble = CGRect(x: 800, y: 1600, width: 200, height: 200)
        expect(CameraLayoutMath.stackYield(zoom: 1) == 1 && CameraLayoutMath.stackYield(zoom: 1.5) == 0.75
               && CameraLayoutMath.stackYield(zoom: 2.4) == 0.75
               && CameraLayoutMath.stackYield(zoom: 1.25) > 0.75 && CameraLayoutMath.stackYield(zoom: 1.25) < 1,
               "the camera row yields on the bubble's own curve: 1 at rest, 0.75 past 1.5x, between mid-zoom")
        for up in [false, true] {
            let full = CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: up)
            let yielded = CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: up, yield: 0.75)
            let gap = area.height * CameraLayoutMath.stackGapFraction
            expect(abs(yielded.camera.height - full.camera.height * 0.75) < 1e-9
                   && abs(yielded.screen.height + yielded.camera.height + gap - area.height) < 1e-9
                   && yielded.camera.width == area.width
                   && (up ? abs(yielded.camera.maxY - area.maxY) < 1e-9 && yielded.screen.minY == area.minY
                          : yielded.camera.minY == area.minY && abs(yielded.screen.maxY - area.maxY) < 1e-9),
                   "a yielded stack (\(up ? "Y-up" : "Y-down")): the camera row keeps its top and 75% of its height, the screen row takes the rest")
        }

        func resolve(
            _ t: TimeInterval, _ regions: [CameraLayoutRegion], stack: CameraLayoutMath.StackRows,
            zoom: CameraLayoutMath.StackZoom = .none
        ) -> CameraLayoutMath.Resolved {
            CameraLayoutMath.resolve(at: t, regions: regions, videoRect: card, bubbleRect: bubble,
                                     bubbleCornerRadius: 100, cardCornerRadius: 12, hasCamera: true,
                                     stack: stack, stackZoom: zoom)
        }
        let down = CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: false)
        expect(resolve(1, [], stack: down, zoom: .init(zoom: 1, focalX: 0.9, focalY: 0.2)) == resolve(1, [], stack: down),
               "zoom 1 leaves the stacked card exactly as before, whatever the focal")

        // The screen zooms INSIDE its row: the camera row is untouched, the
        // zoomed card still covers the row, and at full envelope the focal
        // sits at the same fraction of the row as of the card — including a
        // focal the aspect fill cropped away.
        for up in [false, true] {
            let rows = CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: up, yield: 0.75)
            for (fx, fy) in [(0.5, 0.5), (0.95, 0.1), (0.05, 0.9)] {
                for z in [1.2, 2.4] {
                    let r = resolve(1, [], stack: rows, zoom: .init(zoom: z, focalX: fx, focalY: fy))
                    let xf = CameraLayoutMath.cardTransform(r, videoRect: card)
                    let covered = card.applying(xf)
                    let tag = "\(up ? "Y-up" : "Y-down") z=\(z) focal=(\(fx), \(fy))"
                    expect(r.cameraRect == rows.camera && r.cardClip == rows.screen,
                           "stacked zoom \(tag): camera row and clip are the rows — the camera row never zooms")
                    expect(covered.minX <= rows.screen.minX + 1e-6 && covered.maxX >= rows.screen.maxX - 1e-6
                           && covered.minY <= rows.screen.minY + 1e-6 && covered.maxY >= rows.screen.maxY - 1e-6,
                           "stacked zoom \(tag): the zoomed card still covers the screen row")
                    let fill = max(rows.screen.width / card.width, rows.screen.height / card.height)
                    expect(abs(r.cardScale - fill * CGFloat(z)) < 1e-9, "stacked zoom \(tag): scale = fill × zoom")
                    if z >= 1.5 {
                        let focal = CGPoint(x: card.minX + fx * card.width,
                                            y: up ? card.maxY - fy * card.height : card.minY + fy * card.height)
                        let landed = focal.applying(xf)
                        let want = CGPoint(x: rows.screen.minX + fx * rows.screen.width,
                                           y: up ? rows.screen.maxY - fy * rows.screen.height
                                                 : rows.screen.minY + fy * rows.screen.height)
                        expect(hypot(landed.x - want.x, landed.y - want.y) < 1e-6,
                               "stacked zoom \(tag): the focal lands at its own fraction of the row (in view)")
                    }
                }
            }
        }

        // While the stack is on the layout owns every zoom-in; the card stage
        // after it keeps only a scale-down.
        expect(CameraLayoutMath.outerZoom(2.4, stacking: true) == 1 && CameraLayoutMath.outerZoom(2.4, stacking: false) == 2.4
               && CameraLayoutMath.outerZoom(0.8, stacking: true) == 0.8 && CameraLayoutMath.outerZoom(1, stacking: true) == 1,
               "outerZoom: none of a zoom-in while stacking, all of it otherwise, a scale-down always")
        // A Bubble block inside a stacked video: the plain zoom about the
        // focal, in the layout — the focal stays put, the bubble is untouched.
        let withBubble = [CameraLayoutRegion(startTime: 4, endTime: 8, mode: .bubble)]
        let zoom = CameraLayoutMath.StackZoom(zoom: 2.4, focalX: 0.7, focalY: 0.4)
        let inBubble = resolve(6, withBubble, stack: down, zoom: zoom)
        let focal = CGPoint(x: card.minX + 0.7 * card.width, y: card.minY + 0.4 * card.height)
        let held = focal.applying(CameraLayoutMath.cardTransform(inBubble, videoRect: card))
        expect(inBubble.isPlainBubble && inBubble.cameraRect == bubble && inBubble.cardClip == nil
               && abs(inBubble.cardScale - 2.4) < 1e-9 && hypot(held.x - focal.x, held.y - focal.y) < 1e-6
               && resolve(6, withBubble, stack: down) == resolve(6, withBubble, stack: down, zoom: .none),
               "a Bubble block while stacked zooms the card 2.4x about its focal, the bubble untouched")
        // Through the morph both ends are zoomed layouts, so nothing jumps:
        // just after the edge it is the stacked zoom, at the end the Bubble
        // block's, and the camera rect only ever blends row → bubble.
        let before = resolve(3.99, withBubble, stack: down, zoom: zoom)
        let start = resolve(4.0005, withBubble, stack: down, zoom: zoom)
        let end = resolve(4 + CameraLayoutMath.transitionDuration - 0.0005, withBubble, stack: down, zoom: zoom)
        let a0 = card.applying(CameraLayoutMath.cardTransform(before, videoRect: card))
        let a1 = card.applying(CameraLayoutMath.cardTransform(start, videoRect: card))
        let b0 = card.applying(CameraLayoutMath.cardTransform(end, videoRect: card))
        let b1 = card.applying(CameraLayoutMath.cardTransform(inBubble, videoRect: card))
        func near(_ p: CGRect, _ q: CGRect) -> Bool {
            abs(p.minX - q.minX) < 0.5 && abs(p.minY - q.minY) < 0.5 && abs(p.width - q.width) < 0.5 && abs(p.height - q.height) < 0.5
        }
        expect(near(a0, a1) && near(b0, b1) && end.cameraRect.map { near($0, bubble) } == true,
               "a morph into a Bubble block while zoomed starts on the stacked zoom and lands on the bubble's — no jump either end")
    }
    // MARK: - Gap between the stack's rows (§12.14)

    private static func stackGapChecks(expect: (Bool, String) -> Void) {
        let area = CGRect(x: 48, y: 48, width: 984, height: 1824)
        let card = CGRect(x: 48, y: 683.25, width: 984, height: 553.5)
        let bubble = CGRect(x: 800, y: 1600, width: 200, height: 200)
        expect(CameraLayoutMath.stackGap(nil) == 0.02 && CameraLayoutMath.stackGap(-1) == 0
               && CameraLayoutMath.stackGap(0.5) == 0.08 && CameraLayoutMath.stackGap(0.05) == 0.05,
               "gap defaults to 0.02 and clamps to 0…0.08")
        expect(CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: false)
                == CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: false, gap: 0.02),
               "no stored gap is exactly the old 2% rows")
        func resolve(_ t: TimeInterval, _ regions: [CameraLayoutRegion], stack: CameraLayoutMath.StackRows,
                     radius: CGFloat = 24) -> CameraLayoutMath.Resolved {
            CameraLayoutMath.resolve(at: t, regions: regions, videoRect: card, bubbleRect: bubble,
                                     bubbleCornerRadius: 100, cardCornerRadius: radius, hasCamera: true, stack: stack)
        }
        for up in [false, true] {
            let tag = up ? "Y-up" : "Y-down"
            let joined = CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: up, gap: 0)
            let touching = up ? joined.camera.minY == joined.screen.maxY : joined.screen.minY == joined.camera.maxY
            expect(touching && abs(joined.camera.height + joined.screen.height - area.height) < 1e-9,
                   "gap 0 (\(tag)): the rows touch and fill the area")
            let r = resolve(1, [], stack: joined)
            let cam = r.cameraShapeRect, clip = r.cardClipShapeRect
            let camReaches = cam.map {
                $0.minX == joined.camera.minX && $0.width == joined.camera.width
                    && abs($0.height - (joined.camera.height + 24)) < 1e-9
                    && (up ? abs($0.minY - (joined.camera.minY - 24)) < 1e-9 && $0.maxY == joined.camera.maxY
                           : $0.minY == joined.camera.minY)
            } == true
            let clipReaches = clip.map {
                abs($0.height - (joined.screen.height + 24)) < 1e-9
                    && (up ? $0.minY == joined.screen.minY : abs($0.minY - (joined.screen.minY - 24)) < 1e-9)
            } == true
            expect(camReaches && clipReaches && r.seamJoin == 1 && r.cameraRect == joined.camera && r.cardClip == joined.screen,
                   "gap 0 (\(tag)): each row's shape runs past the seam by the radius — square corners there; seamJoin 1")
            let spaced = resolve(1, [], stack: CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: up, gap: 0.01))
            expect(spaced.cameraShapeRect == nil && spaced.cardClipShapeRect == nil && spaced.seamJoin == 0,
                   "any gap (\(tag)): plain rounded rows, the camera casts its shadow")
            let square = resolve(1, [], stack: joined, radius: 0)
            expect(square.cameraShapeRect == nil && square.cardClipShapeRect == nil && square.seamJoin == 1,
                   "gap 0 with square corners (\(tag)): nothing to extend, still joined (no camera shadow)")
        }
        // Into a Bubble block, the join and the shapes ease out with the morph.
        let joined = CameraLayoutMath.stackRows(area: area, ratio: 0.42, yAxisIsUp: false, gap: 0)
        let withBubble = [CameraLayoutRegion(startTime: 4, endTime: 8, mode: .bubble)]
        let mid = resolve(4 + CameraLayoutMath.transitionDuration / 2, withBubble, stack: joined)
        let settledBubble = resolve(6, withBubble, stack: joined)
        expect(mid.seamJoin > 0.05 && mid.seamJoin < 0.95 && mid.cameraShapeRect != nil && mid.cardClipShapeRect != nil
               && settledBubble.seamJoin == 0 && settledBubble.cameraShapeRect == nil && settledBubble.isPlainBubble,
               "a morph out of a joined stack eases seamJoin and the shapes; the Bubble block has neither")
    }
}
