// Headless checks for the iOS sync core, compiled for macOS from the SAME
// sources the app uses (apps/ios/scripts/core-selftest.sh). No simulator.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS  \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let templateData = try! Data(contentsOf: root.appendingPathComponent("Core/ProjectTemplate.json"))

// 1. Lossless round trip: parse → serialize reproduces the web serializer's bytes.
let parsed = try! LosslessJSON.parse(templateData)
check(parsed.serialized() + Data("\n".utf8) == templateData, "template round-trips byte-for-byte")

// 2. Number text and unknown keys survive.
let tricky = Data(#"{"b":1.0,"a":0.1,"z":{"unknownFutureKey":[1e-7,-0.0,12345678901234567890]},"s":"é\n\"\u0001"}"#.utf8)
let trickyOut = try! LosslessJSON.parse(tricky)
let reparsed = try! LosslessJSON.parse(trickyOut.serialized())
check(trickyOut == reparsed, "re-parse is identical")
let text = String(decoding: trickyOut.serialized(), as: UTF8.self)
check(text.contains("\"b\": 1.0") && text.contains("1e-7") && text.contains("12345678901234567890") && text.contains("-0.0"), "number literals preserved verbatim")
check(text.firstRange(of: "\"b\"")!.lowerBound < text.firstRange(of: "\"a\"")!.lowerBound, "key order preserved")
check(text.contains("\\u0001") && text.contains("é"), "string escapes valid, non-ASCII kept")

// 3. Rename touches only the name.
let renamed = try! ProjectDocument.renamed(templateData, to: "Demo — “quotes” & ünïcode")
var a = try! LosslessJSON.parse(renamed), b = parsed
a["name"] = nil; b["name"] = nil
check(a == b, "rename changes nothing but name")
check(try! LosslessJSON.parse(renamed)["name"]?.stringValue == "Demo — “quotes” & ünïcode", "rename stored")

// 4. New iPhone project: required keys the API checks + Mac-shaped refs.
let id = "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"
let doc = try! ProjectDocument.make(.init(id: id, name: "Screen Recording", createdAt: Date(timeIntervalSinceReferenceDate: 784_000_000.25),
                                          videoFileName: "recording.mp4", duration: 12.5, sourceKind: "device",
                                          isStillCapture: false, showDeviceFrame: true))
let made = try! LosslessJSON.parse(doc)
check(made["id"]?.stringValue == id, "id set (uppercase)")
check(made["videoURL"]?.stringValue == "file:///CaptureCat/Projects/\(id)/recording.mp4", "Mac-shaped media ref")
check(made["createdAt"]?.doubleValue == 784_000_000.25, "createdAt = Swift reference-date seconds")
check(made["duration"]?.doubleValue == 12.5 && made["recordingSourceKind"]?.stringValue == "device", "duration + device kind")
check(made["settings"]?["showDeviceFrame"]?.boolValue == true && made["settings"]?["showCamera"]?.boolValue == false, "settings patched")
check(made["zoomRegions"] != nil && made["settings"] != nil && made["name"] != nil, "API-required keys present")
let facts = ProjectDocument.facts(doc)!
check(facts.sourceKind == "device" && facts.duration == 12.5 && facts.videoFileName == "recording.mp4" && !facts.isStillCapture, "facts read back")
// Deterministic fixtures for the Mac's real-Codable gate:
//   CaptureCat --web-roundtrip-check apps/ios/Tests/Fixtures
let fixtures = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try! FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
try! doc.write(to: fixtures.appendingPathComponent("iphone-screen-recording.json"))
let shotID = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9"
let shot = try! ProjectDocument.make(.init(id: shotID, name: "Screenshot Nov 13 at 9.41.00 PM", createdAt: Date(timeIntervalSinceReferenceDate: 784_000_100),
                                           videoFileName: "recording.mp4", duration: StillMovieWriter.defaultDuration, sourceKind: "device",
                                           isStillCapture: true, showDeviceFrame: true))
try! shot.write(to: fixtures.appendingPathComponent("iphone-screenshot.json"))
let renamedFixture = try! ProjectDocument.renamed(shot, to: "Renamed on iPhone")
try! renamedFixture.write(to: fixtures.appendingPathComponent("iphone-renamed.json"))
check(ProjectDocument.facts(shot)?.isStillCapture == true, "screenshot project is a still capture")

// 5. Device-shape classification.
check(PendingTake.sourceKind(width: 1206, height: 2622) == "device", "iPhone portrait = device")
check(PendingTake.sourceKind(width: 2622, height: 1206) == "device", "iPhone landscape = device")
check(PendingTake.sourceKind(width: 1668, height: 2420) == "display", "iPad = display")

// 6. Link-key fingerprint vector (the API must print the same keyId).
let key = Data((0..<32).map { UInt8($0) })
let link = WirelessLink(key: key)!
print("keyID(0x00…0x1f) = \(link.keyID)")
check(link.keyID == "8f40509a77686376", "keyID matches the API's vector (apps/api devices.test.ts)")
check(WirelessLink(base64URLKey: WirelessLink.base64URL(key))?.keyID == link.keyID, "base64url key round-trips")

// 7. Comment drawings: the web's serializer and renderer, reproduced
//    (apps/web/src/lib/share/annotation.fixtures.json, written by the web's
//    annotation.fixtures.test.ts from annotation.ts itself).
let fixtureURL = root.appendingPathComponent("../web/src/lib/share/annotation.fixtures.json")
let annotationFixtures = (try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))) as? [String: Any] ?? [:]
check(!annotationFixtures.isEmpty, "web annotation fixtures found at \(fixtureURL.standardized.path)")
/// A fixture's RAW input shape (before canonicalising: any colour, size, range).
func rawShape(_ s: [String: Any]) -> ShareAnnotationShape? {
    func p(_ v: Any?) -> CGPoint? {
        guard let a = v as? [NSNumber], a.count == 2 else { return nil }
        return CGPoint(x: a[0].doubleValue, y: a[1].doubleValue)
    }
    let color = s["color"] as? String ?? "", size = (s["size"] as? NSNumber)?.intValue ?? 0
    guard let kind = (s["kind"] as? String).flatMap(ShareAnnotationShape.Kind.init(rawValue:)) else { return nil }
    switch kind {
    case .pen, .highlight: return .stroke(kind: kind, color: color, size: size, points: ((s["points"] as? [Any]) ?? []).compactMap(p))
    case .arrow, .rect, .ellipse: return .box(kind: kind, color: color, size: size, from: p(s["from"])!, to: p(s["to"])!)
    case .text: return .text(color: color, size: size, at: p(s["at"])!, text: s["text"] as? String ?? "")
    }
}
func rawShapes(_ v: Any?) -> [ShareAnnotationShape] { ((v as? [[String: Any]]) ?? []).compactMap(rawShape) }
func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }

for case let item as [String: Any] in (annotationFixtures["serialize"] as? [Any]) ?? [] {
    let name = item["name"] as? String ?? "?"
    let out = ShareAnnotationMath.serialize(rawShapes(item["shapes"]))
    let want = item["json"] as? String
    check(out.json == want && out.bytes == (item["bytes"] as? Int) && out.tooLarge == (item["tooLarge"] as? Bool),
          "serializer byte-identical to the web: \(name)" + (out.json == want ? "" : "\n      web:   \(want ?? "null")\n      swift: \(out.json ?? "null")"))
    if let json = out.json, !out.tooLarge {
        let reread = ShareAnnotationMath.read(try? JSONSerialization.jsonObject(with: Data(json.utf8)))
        check(reread?.shapes == out.annotation?.shapes, "posted drawing reads back unchanged: \(name)")
    }
}
for case let item as [String: Any] in (annotationFixtures["read"] as? [Any]) ?? [] {
    let got = ShareAnnotationMath.read(item["input"])?.shapes
    let want = rawShapes((item["output"] as? [String: Any])?["shapes"])
    check(got == want, "reader matches the web's readAnnotation: \(item["name"] as? String ?? "?")")
}
check(ShareAnnotationMath.read(["v": 2, "shapes": [Any]()]) == nil && ShareAnnotationMath.read(nil) == nil
      && ShareAnnotationMath.read(["v": 1, "shapes": [["kind": "pen", "color": "red", "size": 2, "points": [[0, 0]]],
                                                     ["kind": "zap", "color": "#ffffff", "size": 2]]]) == nil,
      "reader drops what the web drops")
for case let item as [String: Any] in (annotationFixtures["geometry"] as? [Any]) ?? [] {
    let box = (item["box"] as? [Double]) ?? [0, 0]
    let media = (item["media"] as? [Double]).map { CGSize(width: $0[0], height: $0[1]) }
    let rect = ShareAnnotationMath.containRect(box: CGSize(width: box[0], height: box[1]), media: media)
    let w = item["rect"] as? [String: Double] ?? [:]
    let stroke = item["stroke"] as? [String: Any] ?? [:]
    let label = (item["label"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    let m = ShareAnnotationMath.labelMetrics(size: 2, rect: rect)
    let tb = ShareAnnotationMath.toBox(CGPoint(x: 0.3, y: 0.7), rect: rect)
    let tf = ShareAnnotationMath.toFrame(CGPoint(x: box[0] * 0.25, y: box[1] * 0.9), rect: rect)
    let wantTB = item["toBox"] as? [Double] ?? [], wantTF = item["toFrame"] as? [Double] ?? []
    var ok = near(rect.minX, w["x"] ?? -1) && near(rect.minY, w["y"] ?? -1) && near(rect.width, w["w"] ?? -1) && near(rect.height, w["h"] ?? -1)
    ok = ok && zip([1, 2, 3], (stroke["pen"] as? [Double]) ?? []).allSatisfy { near(ShareAnnotationMath.strokeWidth(.pen, size: $0, rect: rect), $1) }
    ok = ok && near(ShareAnnotationMath.strokeWidth(.highlight, size: 2, rect: rect), (stroke["highlight"] as? Double) ?? -1)
    ok = ok && zip([1, 2, 3], (item["font"] as? [Double]) ?? []).allSatisfy { near(ShareAnnotationMath.fontSize($0, rect: rect), $1) }
    ok = ok && near(m.px, label["px"] ?? -1) && near(m.padX, label["padX"] ?? -1) && near(m.padY, label["padY"] ?? -1)
    ok = ok && near(m.lineHeight, label["lineHeight"] ?? -1) && near(m.radius, label["radius"] ?? -1)
    ok = ok && near(tb.x, wantTB.first ?? -1) && near(tb.y, wantTB.last ?? -1) && near(tf.x, wantTF.first ?? -1) && near(tf.y, wantTF.last ?? -1)
    check(ok, "geometry matches the web: box \(box) media \(media.map { "\($0)" } ?? "none") → \(rect)")
}
for case let item as [String: Any] in (annotationFixtures["render"] as? [Any]) ?? [] {
    let r = item["rect"] as? [String: Double] ?? [:]
    let rect = CGRect(x: r["x"] ?? 0, y: r["y"] ?? 0, width: r["w"] ?? 0, height: r["h"] ?? 0)
    let plan = ShareAnnotationMath.plan(rawShapes(item["shapes"]), rect: rect, minStrokePx: (item["minStrokePx"] as? Double) ?? 0) { text, px in
        CGFloat(text.unicodeScalars.count) * px * 0.56
    }
    let got = ShareAnnotationMath.recordedCalls(plan)
    let want = (item["calls"] as? [[Any]]) ?? []
    var mismatch: String?
    if got.count != want.count { mismatch = "\(got.count) calls, web made \(want.count)" }
    for (i, (g, w)) in zip(got, want).enumerated() where mismatch == nil {
        let same = g.count == w.count && zip(g, w).allSatisfy { a, b in
            if let s = a as? String { return s == (b as? String) }
            if let x = a as? CGFloat, let y = (b as? NSNumber)?.doubleValue { return near(Double(x), y) }
            return false
        }
        if !same { mismatch = "call \(i): swift \(g) vs web \(w)" }
    }
    check(mismatch == nil, "renderer makes the web's draw calls: \(item["name"] as? String ?? "?")" + (mismatch.map { " — \($0)" } ?? ""))
}
// Timeline markers: the web's geometry (left %, a 0.8 % minimum width).
let span = ShareAnnotationMath.markerSpan(ShareAnnotationMarker(start: 3, end: 3), duration: 12)!
check(near(span.left, 0.25) && near(span.width, 0.008), "zero-length marker keeps a 0.8 % sliver at its moment")
let late = ShareAnnotationMath.markerSpan(ShareAnnotationMarker(start: 8, end: 30), duration: 12)!
check(near(late.left, 8.0 / 12) && near(late.width, 4.0 / 12), "marker clamps to the duration")
check(ShareAnnotationMath.marker(at: 5, in: [ShareAnnotationMarker(start: 1, end: 2), ShareAnnotationMarker(start: 4, end: 6)]) == 1,
      "a time inside a range finds that marker")

print(failures == 0 ? "CORE SELFTEST: ALL PASS" : "CORE SELFTEST: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
