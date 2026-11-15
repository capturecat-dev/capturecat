import CoreGraphics
import Foundation

// Reference canvas (Studio 2e) for the web ports:
//
//   referenceCanvas        — Studio/Models/ReferenceCanvas.swift: the new-
//                            project box, the box → canvas letterbox, the
//                            sanitizer, and Project.exportReferenceCanvas
//                            (the exporter's canvas, incl. the pre-2e rule).
//   referenceCanvasDecode  — Project.referenceCanvasSize's Codable: a fixed
//                            project with the key set to every shape a file
//                            can hold, decoded + re-encoded by the REAL
//                            JSONDecoder/JSONEncoder (or {error:true}), so the
//                            web codec throws exactly where Swift's CGSize
//                            decode does and writes the key back exactly.
extension WebVectors {
    static var referenceCanvasUnits: [WebVectorUnit] {
        [
            WebVectorUnit(
                name: "referenceCanvas",
                notes: "Studio/Models/ReferenceCanvas.swift — newProjectBox, canvas(box:aspect:), sanitized(_:), Project.exportReferenceCanvas(outputSize:) (box, previewCanvasSize, output). Sizes are {width,height}; null = nil",
                build: referenceCanvasCases),
            WebVectorUnit(
                name: "referenceCanvasDecode",
                notes: "Models/Project.swift referenceCanvasSize (CGSize Codable = [w, h]): JSONEncoder().encode(JSONDecoder().decode(Project.self, from: input)) or {error:true}",
                build: referenceCanvasDecodeCases),
        ]
    }

    private static func referenceCanvasCases() -> [WV] {
        var cases: [WV] = [vcase(["kind": "newProjectBox"], ReferenceCanvas.newProjectBox.wv)]

        let boxes: [CGSize] = [
            ReferenceCanvas.newProjectBox, CGSize(width: 1000, height: 500), CGSize(width: 300, height: 700),
            CGSize(width: 330, height: 330), CGSize(width: 330.0 * 16 / 9, height: 330), CGSize(width: 1, height: 1),
        ]
        let aspects: [Double] = [16.0 / 9, 9.0 / 16, 1, 4.0 / 3, 3.0 / 4, 21.0 / 9, 4.0 / 5, 1.6,
                                 32.0 / 9, 1920.0 / 3413, 1000.0 / 820, 2.4, 0, -1]
        for box in boxes {
            for aspect in aspects {
                cases.append(vcase(["kind": "canvas", "box": box.wv, "aspect": aspect.wv],
                                   ReferenceCanvas.canvas(box: box, aspect: aspect).wv))
            }
        }

        let candidates: [CGSize] = [
            ReferenceCanvas.newProjectBox, CGSize(width: 0, height: 330), CGSize(width: 803, height: 0),
            CGSize(width: -1, height: 330), CGSize(width: CGFloat.infinity, height: 330),
            CGSize(width: CGFloat.nan, height: 330), CGSize(width: 0.001, height: 0.001),
        ]
        for box in candidates {
            cases.append(vcase(["kind": "sanitized", "box": box.wv], ReferenceCanvas.sanitized(box).wv))
        }

        let refBoxes: [CGSize?] = [nil, ReferenceCanvas.newProjectBox, CGSize(width: 300, height: 700),
                                   CGSize(width: 0, height: 330)]
        let previews: [CGSize] = [.zero, CGSize(width: 330.0 * 16 / 9, height: 330),
                                  CGSize(width: 764.4, height: 430), CGSize(width: 1029.3, height: 579)]
        let outputs: [CGSize] = [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720),
                                 CGSize(width: 3840, height: 2160), CGSize(width: 1080, height: 1920),
                                 CGSize(width: 1920, height: 3414), CGSize(width: 1000, height: 820),
                                 CGSize(width: 2, height: 2), CGSize(width: 640, height: 360)]
        for box in refBoxes {
            for preview in previews {
                for output in outputs {
                    let project = Project(name: "vector", duration: 1)
                    project.referenceCanvasSize = box
                    project.previewCanvasSize = preview
                    cases.append(vcase(
                        ["kind": "exportReference", "box": box.wv, "preview": preview.wv, "output": output.wv],
                        project.exportReferenceCanvas(outputSize: output).wv))
                }
            }
        }
        return cases
    }

    private static func referenceCanvasDecodeCases() -> [WV] {
        let fixed = Project(id: UUID(uuidString: "00000000-0000-4000-8000-0000000002E0")!,
                            name: "Reference canvas", duration: 3)
        fixed.createdAt = Date(timeIntervalSinceReferenceDate: 0)
        let base = WV.encoded(fixed)
        let values: [(String, WV?)] = [
            ("absent", nil),
            ("null", .null),
            ("new-project box", [803, 330]),
            ("fractional", [.num(330.0 * 16 / 9), 330]),
            ("integers as doubles", [.num(803.0), .num(330.0)]),
            ("zero width (decodes; sanitized later)", [0, 330]),
            ("negative", [-5, 10]),
            ("three elements", [1, 2, 3]),
            ("one element", [803]),
            ("empty array", []),
            ("string", "803x330"),
            ("object", ["width": 803, "height": 330]),
            ("bool", true),
            ("string element", [803, "330"]),
            ("null element", [803, .null]),
        ]
        var cases: [WV] = []
        for (label, value) in values {
            let input = value.map { base.setting("referenceCanvasSize", $0) } ?? base.removing("referenceCanvasSize")
            let text = input.serialized()
            let output: WV
            if let project = try? JSONDecoder().decode(Project.self, from: Data(text.utf8)) {
                output = WV.encoded(project)
            } else {
                output = ["error": true]
            }
            cases.append(vcase(["label": .str(label), "json": input], output))
        }
        return cases
    }
}
