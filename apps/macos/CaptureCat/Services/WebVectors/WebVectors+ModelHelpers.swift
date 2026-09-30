import Foundation
import CoreGraphics
import AppKit

// Model helper units: Project computed properties, SubtitleSegment.groupWords,
// SubtitlePreset. TS: apps/web/src/editor/core/model/helpers.ts.
extension WebVectors {
    static var modelHelperUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "modelHelpers",
                notes: "Models/Project.swift isImageCapture, presentsTimelessTimeline, hidesTimelinePlayhead, hasTimedEffects; ProjectSourceSegment endTime / normalizedContentRect",
                build: modelHelperCases),
            WebVectorUnit(
                name: "subtitleGroupWords",
                notes: "Models/SubtitleSegment.swift groupWords(_:maxDuration:maxWords:) (ids stripped — Swift generates fresh UUIDs)",
                build: groupWordsCases),
            WebVectorUnit(
                name: "subtitlePresets",
                notes: "Models/SubtitlePreset.swift all (colours via CodableColor(NSColor)), apply(to:), matches(_:)",
                build: subtitlePresetCases),
        ]
    }

    private static func modelHelperCases() -> [WV] {
        var rng = WVRandom(seed: "modelHelpers")
        var cases: [WV] = []
        for _ in 0..<1500 {
            let kind: RecordingSourceKind = rng.pick([.display, .window, .area, .device])
            let duration = rng.edgy(0, 60, edges: [8, 8.005, 7.99, 8.0099, 8.01, 0])
            let p = Project(id: rng.uuid(), name: "h",
                            cursorDataURL: rng.bool(0.5) ? URL(fileURLWithPath: "/tmp/cursor.json") : nil,
                            duration: duration, recordingSourceKind: kind)
            p.isStillCapture = rng.bool(0.3)
            p.stillTreatment = rng.bool() ? .image : .video
            if rng.bool(0.2) { p.zoomRegions = [ZoomRegion(id: rng.uuid(), startTime: 0, endTime: 1)] }
            if rng.bool(0.1) { p.tiltRegions = [TiltRegion(id: rng.uuid(), startTime: 0, endTime: 1)] }
            if rng.bool(0.1) { p.speedRegions = [VideoSpeedRegion(id: rng.uuid(), startTime: 0, endTime: 1)] }
            if rng.bool(0.1) { p.cameraLayoutRegions = [CameraLayoutRegion(id: rng.uuid(), startTime: 0, endTime: 1)] }
            if rng.bool(0.1) { p.voiceOverClips = [VoiceOverClip(id: rng.uuid(), fileName: "v.m4a", startTime: 0, duration: 1)] }
            if rng.bool(0.1) { p.settings.introSlideStyle = .left }
            if rng.bool(0.1) { p.settings.curtainUnveilCorner = .topLeft }
            if rng.bool(0.3) {
                p.annotations = [Annotation(id: rng.uuid(), type: rng.pick(AnnotationType.allCases), startTime: 0, endTime: 1)]
            }
            let seg = ProjectSourceSegment(startTime: rng.double(0, 10), duration: rng.double(0, 10),
                                           kind: rng.pick([.display, .device]), contentX: rng.double(0, 1),
                                           contentY: rng.double(0, 1), contentWidth: rng.double(0, 1),
                                           contentHeight: rng.double(0, 1))
            let input: WV = [
                "project": [
                    "isStillCapture": p.isStillCapture.wv,
                    "cursorDataURL": p.cursorDataURL.map { WV.str($0.absoluteString) } ?? .null,
                    "recordingSourceKind": .str(p.recordingSourceKind.rawValue),
                    "duration": p.duration.wv,
                    "stillTreatment": .str(p.stillTreatment.rawValue),
                    "zoomRegions": .arr(p.zoomRegions.map(WVModel.zoomRegion)),
                    "tiltRegions": .arr(p.tiltRegions.map(WVModel.tiltRegion)),
                    "speedRegions": .arr(p.speedRegions.map(WVModel.speedRegion)),
                    "cameraLayoutRegions": .arr(p.cameraLayoutRegions.map(WVModel.cameraLayoutRegion)),
                    "voiceOverClips": .arr(p.voiceOverClips.map { WV.encoded($0) }),
                    "annotations": .arr(p.annotations.map(WVModel.annotation)),
                    "settings": [
                        "introSlideStyle": .str(p.settings.introSlideStyle.rawValue),
                        "curtainUnveilCorner": .str(p.settings.curtainUnveilCorner.rawValue),
                    ],
                ],
                "segment": WV.encoded(seg),
            ]
            cases.append(vcase(input, [
                "isImageCapture": p.isImageCapture.wv,
                "presentsTimelessTimeline": p.presentsTimelessTimeline.wv,
                "hidesTimelinePlayhead": p.hidesTimelinePlayhead.wv,
                "hasTimedEffects": p.hasTimedEffects.wv,
                "segmentEnd": seg.endTime.wv,
                "segmentRect": seg.normalizedContentRect.wv,
            ]))
        }
        return cases
    }

    private static func groupWordsCases() -> [WV] {
        var rng = WVRandom(seed: "subtitleGroupWords")
        let vocabulary = ["hello", "world.", "is", " this ", "on?", "\tthe\t", "product!", "Parity", "a", "x.y", "",
                          "\u{00A0}nbsp\u{00A0}", "\u{2003}em\u{2003}", "line\n", "end."]
        var cases: [WV] = []
        for i in 0..<1200 {
            var t = rng.double(0, 5)
            let count = i % 40 == 0 ? 0 : rng.int(1, 30)
            let words: [SubtitleSegment] = (0..<count).map { _ in
                let start = t
                t += rng.edgy(0.05, 1.2, edges: [0, 3, 3.0000001])
                return SubtitleSegment(id: rng.uuid(), startTime: start, endTime: t, text: rng.pick(vocabulary))
            }
            let maxDuration = rng.bool(0.5) ? 3.0 : rng.edgy(0, 6, edges: [0, 1, 3])
            let maxWords = rng.bool(0.5) ? 8 : rng.int(0, 10)
            let groups = SubtitleSegment.groupWords(words, maxDuration: maxDuration, maxWords: maxWords)
            cases.append(vcase(
                ["words": .arr(words.map { ["startTime": $0.startTime.wv, "endTime": $0.endTime.wv, "text": .str($0.text)] }),
                 "maxDuration": maxDuration.wv, "maxWords": .int(maxWords)],
                ["groups": .arr(groups.map { g in
                    ["startTime": g.startTime.wv, "endTime": g.endTime.wv, "text": .str(g.text),
                     "words": .arr(g.words.map { ["startTime": $0.startTime.wv, "endTime": $0.endTime.wv, "text": .str($0.text)] })]
                })]
            ))
        }
        return cases
    }

    private static func subtitlePresetCases() -> [WV] {
        var rng = WVRandom(seed: "subtitlePresets")
        var cases: [WV] = []
        func presetWV(_ p: SubtitlePreset) -> WV {
            [
                "id": .str(p.id), "name": .str(p.name), "style": .str(p.style.rawValue), "weight": .str(p.weight.rawValue),
                "uppercase": p.uppercase.wv, "color": WVModel.color(CodableColor(p.color)),
                "background": p.background.map { WVModel.color(CodableColor($0)) } ?? .null,
                "karaoke": p.karaoke.wv,
                "highlight": p.highlight.map { WVModel.color(CodableColor($0)) } ?? .null,
            ]
        }
        cases.append(vcase(["kind": "all"], .arr(SubtitlePreset.all.map(presetWV))))
        for _ in 0..<300 {
            let s = ProjectSettings()
            s.subtitleStyle = rng.pick(ProjectSettings.SubtitleStyle.allCases)
            s.subtitleWeight = rng.pick(ProjectSettings.SubtitleWeight.allCases)
            s.subtitleUppercase = rng.bool()
            s.highlightWords = rng.bool()
            s.subtitleColor = CodableColor(red: rng.double(0, 1), green: rng.double(0, 1), blue: rng.double(0, 1))
            s.subtitleBackgroundColor = CodableColor(red: rng.double(0, 1), green: 0, blue: 0)
            s.subtitleHighlightColor = CodableColor(red: 0, green: rng.double(0, 1), blue: 0)
            let preset = rng.pick(SubtitlePreset.all)
            let before: WV = subtitleFieldsWV(s)
            let matchesBefore = SubtitlePreset.all.map { $0.matches(s).wv }
            preset.apply(to: s)
            cases.append(vcase(
                ["kind": "apply", "presetID": .str(preset.id), "settings": before],
                ["matchesBefore": .arr(matchesBefore), "applied": subtitleFieldsWV(s),
                 "matchesAfter": .arr(SubtitlePreset.all.map { $0.matches(s).wv })]
            ))
        }
        return cases
    }

    private static func subtitleFieldsWV(_ s: ProjectSettings) -> WV {
        [
            "subtitleStyle": .str(s.subtitleStyle.rawValue), "subtitleWeight": .str(s.subtitleWeight.rawValue),
            "subtitleUppercase": s.subtitleUppercase.wv, "subtitleColor": WVModel.color(s.subtitleColor),
            "subtitleBackgroundColor": WVModel.color(s.subtitleBackgroundColor),
            "highlightWords": s.highlightWords.wv, "subtitleHighlightColor": WVModel.color(s.subtitleHighlightColor),
        ]
    }
}
