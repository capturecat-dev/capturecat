import Foundation

/// `CaptureCat --web-roundtrip-check <file.json|dir> [--against <original.json|projectsRoot>] [--show-values]`
///
/// Proves a project.json written by the WEB editor is one the Mac loads and
/// re-saves unchanged. For every web-serialized file W:
///
/// 1. decode W with the REAL `Project` Codable (failure = FAIL, with the coding path);
/// 2. S = encode(decode(W)); compare W ↔ S semantically:
///    - a key Swift writes that W lacks, or any differing value → FAIL
///      (the web serializer disagrees with `encode(to:)`);
///    - keys in W that Swift does not know are reported as `unknownToSwift`
///      (the web preserves unknown keys; the Mac drops them on its next save);
/// 3. with `--against`: O = the original project.json the web parsed
///    (a file, or `<projectsRoot>/<W.id>/project.json`), and
///    encode(decode(O)) must equal S exactly — i.e. web parse+serialize ≡
///    Swift decode+encode for that project.
///
/// Only key PATHS are printed by default (never values), so it is safe to run
/// over real user projects; `--show-values` adds values for synthetic files.
/// Exits 0 when every file passes. Never reached in a normal launch.
enum WebRoundtripCheck {
    static func run() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--web-roundtrip-check"), args.indices.contains(i + 1) else {
            print("usage: CaptureCat --web-roundtrip-check <file.json|dir> [--against <original.json|projectsRoot>] [--show-values]")
            exit(64)
        }
        let target = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        var against: URL?
        if let j = args.firstIndex(of: "--against"), args.indices.contains(j + 1) {
            against = URL(fileURLWithPath: (args[j + 1] as NSString).expandingTildeInPath)
        }
        let showValues = args.contains("--show-values")

        var files: [URL] = []
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            files = ((try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            files = [target]
        }
        guard !files.isEmpty else {
            print("WEB-ROUNDTRIP FAIL no .json files at \(target.path)")
            exit(1)
        }

        var passed = 0
        var failed = 0
        var unknownTotal = 0
        var againstChecked = 0
        for file in files {
            let result = check(file: file, against: against, showValues: showValues)
            unknownTotal += result.unknownCount
            if result.againstChecked { againstChecked += 1 }
            if result.ok { passed += 1 } else { failed += 1 }
            print(result.line)
            for detail in result.details.prefix(12) { print("  \(detail)") }
        }
        print("WEB-ROUNDTRIP \(failed == 0 ? "OK" : "FAILED") files=\(files.count) passed=\(passed) failed=\(failed) againstChecked=\(againstChecked) unknownKeysPreservedByWeb=\(unknownTotal)")
        exit(failed == 0 ? 0 : 1)
    }

    private struct Result {
        var ok: Bool
        var line: String
        var details: [String]
        var unknownCount: Int
        var againstChecked: Bool
    }

    private static func check(file: URL, against: URL?, showValues: Bool) -> Result {
        let name = file.lastPathComponent
        guard let data = try? Data(contentsOf: file),
              let web = PreciseJSON.parse(data) else {
            return Result(ok: false, line: "WEB-ROUNDTRIP \(name) FAIL unreadable JSON", details: [], unknownCount: 0, againstChecked: false)
        }
        let project: Project
        do {
            project = try JSONDecoder().decode(Project.self, from: data)
        } catch {
            return Result(ok: false, line: "WEB-ROUNDTRIP \(name) FAIL decode: \(describe(error))",
                          details: [], unknownCount: 0, againstChecked: false)
        }
        guard let reencoded = try? JSONEncoder().encode(project),
              let swift = PreciseJSON.parse(reencoded) else {
            return Result(ok: false, line: "WEB-ROUNDTRIP \(name) FAIL re-encode", details: [], unknownCount: 0, againstChecked: false)
        }

        var diff = Diff(showValues: showValues)
        diff.compare(web: web, swift: swift, path: "")
        var details = diff.problems
        var ok = diff.problems.isEmpty
        var againstChecked = false
        var againstNote = ""

        if let against {
            var originalURL = against
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: against.path, isDirectory: &isDir), isDir.boolValue {
                originalURL = against.appendingPathComponent(project.id.uuidString).appendingPathComponent("project.json")
            }
            if let odata = try? Data(contentsOf: originalURL) {
                if let original = try? JSONDecoder().decode(Project.self, from: odata),
                   let oenc = try? JSONEncoder().encode(original),
                   let canonical = PreciseJSON.parse(oenc) {
                    var d2 = Diff(showValues: showValues)
                    d2.strict(canonical, swift, path: "")
                    againstChecked = true
                    if d2.problems.isEmpty {
                        againstNote = " against=ok"
                    } else {
                        ok = false
                        againstNote = " against=FAIL(\(d2.problems.count))"
                        details += d2.problems.map { "against: \($0)" }
                    }
                } else {
                    againstNote = " against=original-does-not-decode"
                }
            } else {
                againstNote = " against=missing"
            }
        }

        let line = "WEB-ROUNDTRIP \(name) \(ok ? "OK" : "FAIL") decode=ok fixpoint=\(diff.problems.isEmpty ? "ok" : "FAIL(\(diff.problems.count))") unknownToSwift=\(diff.unknown.count)\(againstNote)"
        if showValues || !diff.unknown.isEmpty {
            details += diff.unknown.prefix(6).map { "unknownToSwift \($0)" }
        }
        return Result(ok: ok, line: line, details: details, unknownCount: diff.unknown.count, againstChecked: againstChecked)
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ c: DecodingError.Context) -> String {
            c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch e {
        case .keyNotFound(let key, let c): return "keyNotFound \(path(c)).\(key.stringValue)"
        case .valueNotFound(_, let c): return "valueNotFound \(path(c))"
        case .typeMismatch(_, let c): return "typeMismatch \(path(c))"
        case .dataCorrupted(let c): return "dataCorrupted \(path(c))"
        @unknown default: return "\(e)"
        }
    }

    /// Semantic JSON diff between the web's file and Swift's re-encode.
    /// Values are parsed with JSONDecoder (PreciseJSON) — NSJSONSerialization
    /// mis-rounds some long decimal literals and would report false diffs.
    private struct Diff {
        let showValues: Bool
        var problems: [String] = []
        var unknown: [String] = []

        private func show(_ v: PreciseJSON) -> String {
            guard showValues else { return "" }
            switch v {
            case .null: return " null"
            case .bool(let b): return " \(b)"
            case .number(let d): return " \(d)"
            case .string(let s): return " \"\(s.prefix(80))\""
            case .array(let a): return " [\(a.count) items]"
            case .object(let o): return " {\(o.count) keys}"
            }
        }

        /// W ↔ S: unknown web keys are informational, everything else must match.
        mutating func compare(web: PreciseJSON, swift: PreciseJSON, path: String) {
            switch (web, swift) {
            case (.object(let w), .object(let s)):
                for key in s.keys.sorted() {
                    guard let wv = w[key] else {
                        problems.append("web missing key \(path).\(key)")
                        continue
                    }
                    compare(web: wv, swift: s[key]!, path: "\(path).\(key)")
                }
                for key in w.keys.sorted() where s[key] == nil {
                    unknown.append("\(path).\(key)")
                }
            case (.array(let w), .array(let s)):
                guard w.count == s.count else {
                    problems.append("array length \(path) web=\(w.count) swift=\(s.count)")
                    return
                }
                for i in 0..<w.count { compare(web: w[i], swift: s[i], path: "\(path)[\(i)]") }
            default:
                if web != swift { problems.append("value differs \(path)\(show(web)) ->\(show(swift))") }
            }
        }

        /// Exact structural equality (both sides from Swift).
        mutating func strict(_ a: PreciseJSON, _ b: PreciseJSON, path: String) {
            switch (a, b) {
            case (.object(let x), .object(let y)):
                for key in Set(x.keys).union(y.keys).sorted() {
                    guard let xv = x[key] else { problems.append("only in web-roundtrip \(path).\(key)"); continue }
                    guard let yv = y[key] else { problems.append("only in original-roundtrip \(path).\(key)"); continue }
                    strict(xv, yv, path: "\(path).\(key)")
                }
            case (.array(let x), .array(let y)):
                guard x.count == y.count else { problems.append("array length \(path)"); return }
                for i in 0..<x.count { strict(x[i], y[i], path: "\(path)[\(i)]") }
            default:
                if a != b { problems.append("value differs \(path)\(show(a)) vs\(show(b))") }
            }
        }
    }
}
