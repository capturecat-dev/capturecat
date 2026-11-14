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

print(failures == 0 ? "CORE SELFTEST: ALL PASS" : "CORE SELFTEST: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
