import Foundation
import CoreGraphics
import AppKit

// Golden-vector units for the MODEL cluster: the REAL Swift Codable over
// synthetic project.json documents. TS: apps/web/src/editor/core/model/.
//
// - `modelDefaults`: what `ProjectSettings()`, `ExportSettings()`, a fresh
//   `Project(...)` and every region/annotation initializer encode — the web's
//   defaults for new objects AND for decode fallbacks that come from NSColor.
// - `projectDecode`: random full projects, then random MUTATIONS (removed
//   keys, nulls, invalid/lenient enums, wrong types, unknown keys, lowercase
//   UUIDs, legacy shapes). Output = Swift `encode(decode(input))`, or
//   `{"error": true}` when JSONDecoder throws. The TS parser must throw on
//   exactly the error cases and otherwise serialize to exactly Swift's JSON.
extension WebVectors {
    static var modelUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "modelDefaults",
                notes: "Models/*.swift initializers encoded with JSONEncoder (ProjectSettings(), ExportSettings(), Project(...), ZoomRegion/TiltRegion/BlurRegion/HighlightRegion/FocusRegion/CameraLayoutRegion/Annotation/VoiceOverClip/SubtitleSegment defaults) — NSColor system colours resolved in this headless process",
                build: modelDefaultCases),
            WebVectorUnit(
                name: "projectDecode",
                notes: "Models/Project.swift + every nested Codable: JSONEncoder().encode(JSONDecoder().decode(Project.self, from: input)) or {error:true}",
                build: projectDecodeCases),
        ] + modelHelperUnits
    }

    // MARK: Defaults

    private static func modelDefaultCases() -> [WV] {
        let fixedID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let project = Project(id: fixedID, name: "Untitled Recording", duration: 0)
        var cases: [WV] = [
            vcase(["kind": "ProjectSettings"], WV.encoded(ProjectSettings())),
            vcase(["kind": "ExportSettings"], WV.encoded(ExportSettings())),
            vcase(["kind": "Project"], WV.encoded(project).removing("createdAt")),
            vcase(["kind": "ProjectWithCamera"], WV.encoded(Project(
                id: fixedID, name: "Untitled Recording",
                cameraVideoURL: URL(fileURLWithPath: "/tmp/camera.mov"), duration: 0)).removing("createdAt")),
            vcase(["kind": "ZoomRegion"], WVModel.zoomRegion(ZoomRegion(id: fixedID, startTime: 0, endTime: 1))),
            vcase(["kind": "TiltRegion"], WV.encoded(TiltRegion(id: fixedID, startTime: 0, endTime: 1))),
            vcase(["kind": "BlurRegion"], WVModel.blurRegion(BlurRegion(id: fixedID, startTime: 0, endTime: 1))),
            vcase(["kind": "HighlightRegion"], WVModel.highlightRegion(HighlightRegion(id: fixedID, startTime: 0, endTime: 1))),
            vcase(["kind": "FocusRegion"], WVModel.focusRegion(FocusRegion(id: fixedID, startTime: 0, endTime: 1))),
            vcase(["kind": "CameraLayoutRegion"], WV.encoded(CameraLayoutRegion(id: fixedID, startTime: 0, endTime: 1))),
            vcase(["kind": "VideoSpeedRegion"], WV.encoded(VideoSpeedRegion(id: fixedID, startTime: 0, endTime: 1))),
            vcase(["kind": "VoiceOverClip"], WV.encoded(VoiceOverClip(id: fixedID, fileName: "vo.m4a", startTime: 0, duration: 1))),
            vcase(["kind": "SubtitleSegment"], WV.encoded(SubtitleSegment(id: fixedID, startTime: 0, endTime: 1, text: "Hi"))),
        ]
        for type in AnnotationType.allCases {
            cases.append(vcase(
                ["kind": "Annotation", "type": .str(type.rawValue)],
                WV.encoded(Annotation(id: fixedID, type: type, startTime: 0, endTime: 1))))
        }
        // NSColor-derived constants used as decode fallbacks / new defaults.
        let named: [(String, NSColor)] = [
            ("white", .white), ("black", .black), ("systemPurple", .systemPurple),
            ("systemBlue", .systemBlue), ("systemYellow", .systemYellow),
        ]
        for (name, color) in named {
            cases.append(vcase(["kind": "NSColor", "name": .str(name)], WV.encoded(CodableColor(color))))
        }
        return cases
    }

    // MARK: Random full project (JSON level)

    private static let settingsEnums: [String: [String]] = [
        "backgroundType": ProjectSettings.BackgroundType.allCases.map(\.rawValue),
        "videoPlacement": ProjectSettings.VideoPlacement.allCases.map(\.rawValue),
        "frameShape": ProjectSettings.FrameShape.allCases.map(\.rawValue),
        "cursorStyle": ProjectSettings.CursorStyle.allCases.map(\.rawValue),
        "clickSoundStyle": ClickSoundStyle.allCases.map(\.rawValue),
        "keySoundStyle": KeySoundStyle.allCases.map(\.rawValue),
        "keystrokeOverlayPosition": KeystrokeOverlayPosition.allCases.map(\.rawValue),
        "keystrokeOverlayAnimation": KeystrokeOverlayAnimation.allCases.map(\.rawValue),
        "cameraPosition": ProjectSettings.CameraPosition.allCases.map(\.rawValue),
        "cameraShape": ProjectSettings.CameraShape.allCases.map(\.rawValue),
        "cameraOrientation": ProjectSettings.CameraOrientation.allCases.map(\.rawValue),
        "cameraFilter": ProjectSettings.CameraFilterStyle.allCases.map(\.rawValue),
        "cameraTagPosition": ProjectSettings.CameraTagPosition.allCases.map(\.rawValue),
        "menuBarReplacement": ProjectSettings.MenuBarReplacement.allCases.map(\.rawValue),
        "menuBarTitleAlignment": ProjectSettings.MenuBarTitleAlignment.allCases.map(\.rawValue),
        "animationSpeed": ProjectSettings.AnimationSpeed.allCases.map(\.rawValue),
        "introSlideStyle": IntroSlideStyle.allCases.map(\.rawValue),
        "curtainUnveilCorner": CurtainUnveilCorner.allCases.map(\.rawValue),
        "screenTiltMode": ProjectSettings.ScreenTiltMode.allCases.map(\.rawValue),
        "subtitlePosition": ProjectSettings.SubtitlePosition.allCases.map(\.rawValue),
        "subtitleStyle": ProjectSettings.SubtitleStyle.allCases.map(\.rawValue),
        "subtitleWeight": ProjectSettings.SubtitleWeight.allCases.map(\.rawValue),
        "aspectRatio": AspectRatio.allCases.map(\.rawValue),
        "format": ExportSettings.Format.allCases.map(\.rawValue),
        "resolution": ExportSettings.Resolution.allCases.map(\.rawValue),
    ]
    private static let intKeys: Set<String> = ["fps", "customWidth", "customHeight"]
    private static let freeStringKeys: [String: [String]] = [
        "cameraTagText": ["", "Mike Garland", "Ünïcødé ✨"],
        "cameraTagSubtext": ["", "Founder"],
        "menuBarTitle": ["CaptureCat", "Finder", ""],
        "menuBarClock": ["9:41", "10:08 PM"],
        "backgroundImagePath": ["/Users/x/Pictures/bg.png"],
    ]

    private static func randomColorJSON(_ rng: inout WVRandom) -> [String: Any] {
        ["red": rng.double(0, 1), "green": rng.double(0, 1), "blue": rng.double(0, 1),
         "opacity": rng.edgy(0, 1, edges: [1, 0, 0.55])]
    }

    private static func randomizedSettingsJSON(_ rng: inout WVRandom) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(ProjectSettings()),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        for key in json.keys.sorted() {
            let value = json[key]!
            if rng.bool(0.4) { continue }  // keep the default sometimes
            if let cases = settingsEnums[key] {
                json[key] = rng.pick(cases)
            } else if let strings = freeStringKeys[key] {
                json[key] = rng.pick(strings)
            } else if key == "exportSettings", var nested = value as? [String: Any] {
                for nk in nested.keys.sorted() where rng.bool(0.6) {
                    if let cases = settingsEnums[nk] { nested[nk] = rng.pick(cases) }
                    else if intKeys.contains(nk) { nested[nk] = rng.int(1, 4000) }
                    else if nested[nk] is Double { nested[nk] = rng.double(0.3, 1.2) }
                }
                nested["collapseStaticSpans"] = rng.bool()
                json[key] = nested
            } else if value is [String: Any] {
                json[key] = randomColorJSON(&rng)
            } else if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                json[key] = rng.bool()
            } else if value is NSNumber {
                json[key] = rng.edgy(-5, 300, edges: [0, 1, 0.5, -1, 1e-9])
            } else if value is NSNull {
                json[key] = rng.bool() ? NSNull() : "/Users/x/bg.heic"
            }
        }
        // Optional (encodeIfPresent) keys.
        for key in ["videoCustomX", "videoCustomY", "gradientAngle", "cameraCustomX", "cameraCustomY",
                    "subtitleCustomX", "subtitleCustomY"] where rng.bool(0.4) {
            json[key] = rng.double(-0.2, 1.2)
        }
        for key in ["cameraBorderColor", "curtainLogoTint", "curtainColor"] where rng.bool(0.4) {
            json[key] = randomColorJSON(&rng)
        }
        for key in ["cameraTagFontName", "watermarkFileName", "curtainLogoFileName", "subtitleFontName"] where rng.bool(0.4) {
            json[key] = rng.pick(["Avenir Next", "logo.png", "SF Pro Rounded", "Helvetica Neue"])
        }
        return json
    }

    private static func randomProjectJSON(_ rng: inout WVRandom) -> [String: Any] {
        let duration = rng.edgy(0.5, 120, edges: [8, 30])
        let dir = "file:///Users/x/Library/Containers/so.capturecat.CaptureCat/Data/Library/Application%20Support/CaptureCat/Projects/\(rng.uuid().uuidString)/"
        func t() -> Double { rng.double(0, duration) }
        var p: [String: Any] = [
            "id": rng.uuid().uuidString,
            "name": rng.pick(["Take 1", "Démo ✨", "", "a\"b\\c\nd", "Untitled Recording"]),
            "createdAt": rng.double(7.0e8, 8.3e8),
            "videoURL": rng.bool(0.9) ? dir + "recording.mov" : NSNull(),
            "cursorDataURL": rng.bool(0.7) ? dir + "cursor.json" : NSNull(),
            "cameraVideoURL": rng.bool(0.4) ? dir + "camera.mov" : NSNull(),
            "cameraTimeOffset": rng.edgy(-1, 1, edges: [0]),
            "settings": randomizedSettingsJSON(&rng),
            "duration": duration,
            "trimStart": rng.edgy(0, duration / 3, edges: [0]),
            "trimEnd": rng.edgy(duration / 2, duration, edges: [0, duration]),
            "recordingSourceKind": rng.pick(["display", "window", "area", "device"]),
            "isStillCapture": rng.bool(0.2),
            "stillTreatment": rng.pick(["image", "video"]),
            "splitPoints": (0..<rng.int(0, 3)).map { _ in t() },
        ]
        if rng.bool(0.5) { p["keystrokeDataURL"] = dir + "keys.json" }
        if rng.bool(0.3) { p["recordedAppBundleID"] = rng.pick(["com.apple.Safari", "com.google.Chrome"]) }
        if rng.bool(0.3) { p["reminderDate"] = rng.double(8.0e8, 9.0e8) }

        func encodedArray<T: Encodable>(_ items: [T]) -> [Any] {
            guard let data = try? JSONEncoder().encode(items),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
            return arr
        }
        let styles = ZoomAnimationStyle.allCases
        p["zoomRegions"] = encodedArray((0..<rng.int(0, 4)).map { _ -> ZoomRegion in
            let s = t()
            return ZoomRegion(
                id: rng.uuid(), startTime: s, endTime: s + rng.double(0.3, 5), zoomLevel: rng.double(1, 3),
                focalPoint: rng.point(), animationStyle: rng.bool() ? rng.pick(styles) : nil,
                cardOffsetX: rng.bool(0.3) ? rng.double(-1, 1) : nil, cardOffsetY: rng.bool(0.3) ? rng.double(-1, 1) : nil,
                followsCursor: rng.bool(0.5) ? rng.bool() : nil, isAuto: rng.bool(0.5) ? rng.bool() : nil)
        })
        p["tiltRegions"] = encodedArray((0..<rng.int(0, 3)).map { _ -> TiltRegion in
            let s = t()
            return TiltRegion(id: rng.uuid(), startTime: s, endTime: s + rng.double(0.3, 4),
                              pitch: rng.double(-30, 30), yaw: rng.double(-30, 30), roll: rng.double(-10, 10),
                              animationStyle: rng.bool() ? rng.pick(styles) : nil)
        })
        p["blurRegions"] = encodedArray((0..<rng.int(0, 3)).map { _ -> BlurRegion in
            let s = t()
            return BlurRegion(id: rng.uuid(), startTime: s, endTime: s + 2, label: "Blur",
                              rect: rng.rect(origin: 0, 0.8, size: 0.05, 0.5), intensity: rng.double(0, 1),
                              style: rng.pick(BlurStyle.allCases), animated: rng.bool())
        })
        p["highlightRegions"] = encodedArray((0..<rng.int(0, 3)).map { _ -> HighlightRegion in
            let s = t()
            return HighlightRegion(id: rng.uuid(), startTime: s, endTime: s + 2,
                                   rect: rng.rect(origin: 0, 0.8, size: 0.05, 0.5), opacity: rng.double(0, 1))
        })
        p["focusRegions"] = encodedArray((0..<rng.int(0, 2)).map { _ -> FocusRegion in
            let s = t()
            return FocusRegion(id: rng.uuid(), startTime: s, endTime: s + 2, rect: rng.rect(origin: 0, 0.8, size: 0.05, 0.5),
                               intensity: rng.double(0, 1), falloff: rng.double(0, 1),
                               style: rng.pick(FocusRegionStyle.allCases), angle: rng.double(-90, 90),
                               cornerRadius: rng.double(0, 1))
        })
        p["cameraLayoutRegions"] = encodedArray((0..<rng.int(0, 2)).map { _ -> CameraLayoutRegion in
            let s = t()
            return CameraLayoutRegion(id: rng.uuid(), startTime: s, endTime: s + 2, mode: rng.pick(CameraLayoutMode.allCases))
        })
        p["annotations"] = encodedArray((0..<rng.int(0, 4)).map { _ -> Annotation in
            let s = t()
            var a = Annotation(id: rng.uuid(), type: rng.pick(AnnotationType.allCases), startTime: s, endTime: s + 3)
            a.x = rng.double(0, 1); a.y = rng.double(0, 1)
            a.text = rng.pick(["Label", "Click here →", ""])
            a.fontName = rng.bool(0.3) ? "Avenir Next" : nil
            a.enterEffect = rng.pick(AnnotationEffect.allCases)
            a.exitEffect = rng.pick(AnnotationEffect.allCases)
            if a.type == .drawing {
                a.drawingStrokes = (0..<rng.int(1, 3)).map { _ in
                    (0..<rng.int(1, 6)).map { _ in CodablePoint(x: rng.double(0, 1), y: rng.double(0, 1)) }
                }
            }
            return a
        })
        p["voiceOverClips"] = encodedArray((0..<rng.int(0, 2)).map { _ -> VoiceOverClip in
            VoiceOverClip(id: rng.uuid(), fileName: "voiceover-1.m4a", startTime: t(),
                          sourceStartTime: rng.double(0, 2), duration: rng.double(0.5, 5), gain: rng.double(0, 2))
        })
        p["subtitles"] = encodedArray((0..<rng.int(0, 3)).map { _ -> SubtitleSegment in
            let s = t()
            return SubtitleSegment(id: rng.uuid(), startTime: s, endTime: s + 1.5, text: "hello world",
                                   words: rng.bool() ? [WordTiming(id: rng.uuid(), startTime: s, endTime: s + 0.7, text: "hello"),
                                                        WordTiming(id: rng.uuid(), startTime: s + 0.7, endTime: s + 1.5, text: "world")] : [])
        })
        p["speedRegions"] = encodedArray((0..<rng.int(0, 2)).map { _ -> VideoSpeedRegion in
            let s = t()
            return VideoSpeedRegion(id: rng.uuid(), startTime: s, endTime: s + 2, speed: rng.pick([0.5, 2, 4]))
        })
        p["videoClipSegments"] = encodedArray((0..<rng.int(0, 2)).map { _ -> VideoClipSegment in
            let s = t()
            return VideoClipSegment(id: rng.uuid(), startTime: s, endTime: s + 3)
        })
        p["sourceSegments"] = rng.bool(0.2) ? [[
            "startTime": 0.0, "duration": duration / 2, "kind": "device",
            "contentX": 0.25, "contentY": 0.0, "contentWidth": 0.5, "contentHeight": 1.0,
        ] as [String: Any]] : []
        return p
    }

    // MARK: Mutations

    /// Paths to every object (for unknown keys) and every leaf key.
    private static func keyPaths(_ value: Any, prefix: [Any] = []) -> (objects: [[Any]], keys: [[Any]]) {
        var objects: [[Any]] = []
        var keys: [[Any]] = []
        if let dict = value as? [String: Any] {
            objects.append(prefix)
            for k in dict.keys.sorted() {
                keys.append(prefix + [k])
                let sub = keyPaths(dict[k]!, prefix: prefix + [k])
                objects += sub.objects
                keys += sub.keys
            }
        } else if let arr = value as? [Any] {
            for (i, item) in arr.enumerated() {
                let sub = keyPaths(item, prefix: prefix + [i])
                objects += sub.objects
                keys += sub.keys
            }
        }
        return (objects, keys)
    }

    private static func get(_ root: Any, _ path: [Any]) -> Any? {
        var cur: Any? = root
        for comp in path {
            if let k = comp as? String { cur = (cur as? [String: Any])?[k] }
            else if let i = comp as? Int { cur = (cur as? [Any]).flatMap { $0.indices.contains(i) ? $0[i] : nil } }
        }
        return cur
    }

    /// Returns `root` with `path` set to `value` (nil = remove the key).
    private static func set(_ root: Any, _ path: [Any], _ value: Any?) -> Any {
        guard let head = path.first else { return value ?? NSNull() }
        let rest = Array(path.dropFirst())
        if let k = head as? String, var dict = root as? [String: Any] {
            if rest.isEmpty {
                dict[k] = value
            } else if let child = dict[k] {
                dict[k] = set(child, rest, value)
            }
            return dict
        }
        if let i = head as? Int, var arr = root as? [Any], arr.indices.contains(i) {
            if rest.isEmpty {
                if let value { arr[i] = value } else { arr.remove(at: i) }
            } else {
                arr[i] = set(arr[i], rest, value)
            }
            return arr
        }
        return root
    }

    private static func mutate(_ json: Any, _ rng: inout WVRandom) -> (Any, String) {
        let paths = keyPaths(json)
        let kind = rng.int(0, 12)
        switch kind {
        case 0, 1:
            let path = rng.pick(paths.keys)
            return (set(json, path, nil), "remove \(path)")
        case 2:
            let path = rng.pick(paths.keys)
            return (set(json, path, NSNull()), "null \(path)")
        case 3:
            // Invalid enum raw value on a string leaf.
            let strings = paths.keys.filter { get(json, $0) is String }
            guard let path = strings.isEmpty ? nil : rng.pick(strings) else { return (json, "noop") }
            return (set(json, path, "Bogus Future Value"), "badEnum \(path)")
        case 4:
            let path = rng.pick(paths.keys)
            let current = get(json, path)
            let wrong: Any
            if current is String { wrong = 5 }
            else if let n = current as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { wrong = 1 }
            else if current is NSNumber { wrong = "12" }
            else if current is [Any] { wrong = ["k": 1] }
            else if current is [String: Any] { wrong = [1, 2] }
            else { wrong = true }
            return (set(json, path, wrong), "wrongType \(path)")
        case 5, 6:
            let obj = rng.pick(paths.objects)
            let key = rng.pick(["futureKey", "autoPauseEnabled", "x_web_note"])
            let value: Any = rng.pick([["nested": [1, 2, ["deep": true]]] as Any, "text", 3.25, NSNull()])
            return (set(json, obj + [key], value), "unknownKey \(obj)")
        case 7:
            let uuids = paths.keys.filter { ($0.last as? String) == "id" && get(json, $0) is String }
            guard !uuids.isEmpty else { return (json, "noop") }
            let path = rng.pick(uuids)
            return (set(json, path, (get(json, path) as! String).lowercased()), "lowerUUID \(path)")
        case 8:
            // Legacy annotation: no effect keys, animatesIn decides the enter default.
            guard let anns = (json as? [String: Any])?["annotations"] as? [Any], !anns.isEmpty else { return (json, "noop") }
            let i = rng.int(0, anns.count - 1)
            var j = set(json, ["annotations", i, "enterEffect"], nil)
            j = set(j, ["annotations", i, "exitEffect"], nil)
            j = set(j, ["annotations", i, "animatesIn"], rng.bool())
            if rng.bool() { j = set(j, ["annotations", i, "drawingStrokes"], "garbage") }
            return (j, "legacyAnnotation \(i)")
        case 9:
            // Camera/visibility normalisations.
            var j = set(json, ["settings", "showCamera"], true)
            j = set(j, ["settings", "smoothCursor"], true)
            j = set(j, ["settings", "autoHideCursor"], true)
            if rng.bool() { j = set(j, ["cameraVideoURL"], NSNull()) }
            return (j, "normalisations")
        case 10:
            guard let clips = (json as? [String: Any])?["voiceOverClips"] as? [Any], !clips.isEmpty else { return (json, "noop") }
            var j = set(json, ["voiceOverClips", 0, "sourceStartTime"], -3.5)
            j = set(j, ["voiceOverClips", 0, "sourceDuration"], 0.01)
            return (j, "voiceClamp")
        case 12:
            // URL(string:) canonicalisation (macOS 14+ percent-encodes invalid characters).
            let key = rng.pick(["videoURL", "cursorDataURL", "cameraVideoURL", "keystrokeDataURL"])
            let weird = rng.pick([
                "file:///Users/x/My Movies/rec ording.mov", "file:///tmp/%C3%BCn.mov", "file:///tmp/ünï.mov",
                "100%", "a#b#c", "http://example.com/a b?c d#e f", "file:///tmp/[x].mov", "file:///tmp/%zz.mov",
                "relative/path.mov", "file:///tmp/emoji-😀.mov", "file:///tmp/a|b.mov",
            ])
            return (set(json, [key], weird), "weirdURL \(key)")
        default:
            guard let zooms = (json as? [String: Any])?["zoomRegions"] as? [Any], !zooms.isEmpty else { return (json, "noop") }
            let shape: Any = rng.pick([[0.25, 0.75, 9.0] as Any, [0.5] as Any, [0.1, 0.2] as Any])
            return (set(json, ["zoomRegions", 0, "focalPoint"], shape), "focalShape")
        }
    }

    private static func projectDecodeCases() -> [WV] {
        var rng = WVRandom(seed: "projectDecode")
        var cases: [WV] = []
        for i in 0..<1500 {
            var json: Any = randomProjectJSON(&rng)
            var applied: [String] = []
            let mutations = i < 60 ? 0 : rng.int(1, 3)
            for _ in 0..<mutations {
                let (next, label) = mutate(json, &rng)
                json = next
                applied.append(label)
            }
            // Decode the EXACT text the TS side will parse.
            let input = WV.fromJSONObject(json)
            let text = input.serialized()
            let output: WV
            if let project = try? JSONDecoder().decode(Project.self, from: Data(text.utf8)) {
                output = WV.encoded(project)
            } else {
                output = ["error": true]
            }
            cases.append(vcase(["json": input, "mutations": .arr(applied.map { .str($0) })], output))
        }
        return cases
    }
}
