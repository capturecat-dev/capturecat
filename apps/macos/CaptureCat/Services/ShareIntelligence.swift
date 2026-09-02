import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

private let intelLogger = Logger(subsystem: "so.capturecat.CaptureCat", category: "ShareIntelligence")

/// Share-time intelligence, all derived from the project's own data:
///
///  - `transcriptPayload` retimes the on-device subtitles into OUTPUT-time
///    seconds on the SAME SpeedTimeMap the exporter uses, so a transcript line
///    points at the exact moment in the uploaded file.
///  - `localSummary` runs Apple's on-device foundation model (macOS 26+,
///    Apple Intelligence enabled) over that transcript to produce the title /
///    summary / chapters the share page shows. Nothing leaves the Mac; when
///    the model is unavailable the hub's Gemini button is the fallback.
@MainActor
enum ShareIntelligence {
    struct LocalSummary {
        let title: String
        let summary: String
        let chapters: [[String: Any]]
    }

    /// Subtitle segments as share-page transcript JSON. Empty when the
    /// project has no subtitles.
    ///
    /// `includeSourceTimes` adds `sourceStart`/`sourceEnd` (original-recording
    /// seconds) per segment — the coordinates edit tools speak — for the MCP
    /// `get_transcript` payload. The share page never needs them.
    static func transcriptPayload(
        for project: Project,
        includeSourceTimes: Bool = false
    ) -> [[String: Any]] {
        let trimStart = project.effectiveTrimStart
        let trimEnd = max(trimStart, project.effectiveTrimEnd)
        guard trimEnd > trimStart, !project.subtitles.isEmpty else { return [] }
        let map = SpeedTimeMap(
            sourceStart: trimStart,
            sourceEnd: trimEnd,
            regions: project.speedRegions
        )
        return project.subtitles
            .filter { $0.endTime > trimStart && $0.startTime < trimEnd }
            .sorted { $0.startTime < $1.startTime }
            .compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                var payload: [String: Any] = [
                    "start": map.outputTime(forSource: max(segment.startTime, trimStart)),
                    "end": map.outputTime(forSource: min(segment.endTime, trimEnd)),
                    "text": String(text.prefix(500)),
                ]
                let words = segment.words
                    .filter { $0.endTime > trimStart && $0.startTime < trimEnd }
                    .map { word -> [String: Any] in
                        [
                            "start": map.outputTime(forSource: max(word.startTime, trimStart)),
                            "end": map.outputTime(forSource: min(word.endTime, trimEnd)),
                            "text": String(word.text.prefix(80)),
                        ]
                    }
                if !words.isEmpty { payload["words"] = words }
                if includeSourceTimes {
                    payload["sourceStart"] = max(segment.startTime, trimStart)
                    payload["sourceEnd"] = min(segment.endTime, trimEnd)
                }
                return payload
            }
    }

    /// On-device title/summary/chapters, or nil when the model is
    /// unavailable, the transcript is empty, or generation fails. Never
    /// throws into the share path — a summary is a nice-to-have.
    static func localSummary(transcript: [[String: Any]]) async -> LocalSummary? {
        guard !transcript.isEmpty else { return nil }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.availability == .available else {
            intelLogger.info("local model unavailable — leaving AI summary to the hub")
            return nil
        }
        let lines = transcript.prefix(400).compactMap { seg -> String? in
            guard let start = seg["start"] as? Double, let text = seg["text"] as? String else { return nil }
            return "[\(Int(start))s] \(text)"
        }
        let prompt = """
        You are titling a screen recording for its share page. Given the \
        timestamped transcript, respond with STRICT JSON only (no markdown \
        fence, no commentary) shaped: {"title": string (max 60 chars), \
        "summary": string (2-3 sentences), "chapters": [{"start": number \
        (seconds), "label": string (max 40 chars)}] (3-8 chapters at natural \
        topic changes)}.

        Transcript:
        \(lines.joined(separator: "\n"))
        """
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let raw = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
            guard let data = raw.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String,
                  let summary = json["summary"] as? String else {
                intelLogger.error("local model returned unparseable output")
                return nil
            }
            let chapters = (json["chapters"] as? [[String: Any]] ?? []).compactMap { ch -> [String: Any]? in
                guard let start = ch["start"] as? Double ?? (ch["start"] as? Int).map(Double.init),
                      let label = ch["label"] as? String else { return nil }
                return ["start": max(0, start), "label": String(label.prefix(60))]
            }
            intelLogger.info("local summary generated (\(chapters.count) chapters)")
            return LocalSummary(
                title: String(title.prefix(80)),
                summary: String(summary.prefix(600)),
                chapters: Array(chapters.prefix(12))
            )
        } catch {
            intelLogger.error("local summary failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }
}
