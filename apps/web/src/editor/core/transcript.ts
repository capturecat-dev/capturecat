/**
 * The transcript a share carries — port of
 * `ShareIntelligence.transcriptPayload(for:includeSourceTimes:)`
 * (apps/macos/CaptureCat/Services/ShareIntelligence.swift).
 *
 * The Mac sends `transcriptPayload(for: project)` as the upload body's
 * `transcript` (ExportSheetController / ProjectBrowserViewController →
 * POST /upload/video, validated by apps/api/src/lib/upload-schemas.ts
 * `TranscriptSchema`): the on-device subtitles clipped to the trim window
 * and retimed into OUTPUT seconds on `SpeedTimeMap(sourceStart: trimStart,
 * sourceEnd: trimEnd, regions: speedRegions)`, sorted by start, blank cues
 * dropped, text trimmed and capped (500 / 80 grapheme clusters). The MCP
 * `get_transcript` tool asks for the same payload with SOURCE times added.
 */
import { smax, smin } from "./math/swift";
import type { Project } from "./model/types";
import { effectiveTrimEnd, effectiveTrimStart } from "./time/clips";
import { SpeedTimeMap } from "./time/speedTimeMap";
// Swift String semantics (grapheme-cluster prefix, Foundation trimming) —
// one implementation, shared with the MCP payloads.
import { prefixChars, trimWhitespacesAndNewlines } from "../webmcp/ops/json";

/** One word of a shared transcript (OUTPUT seconds). */
export interface ShareTranscriptWord {
  start: number;
  end: number;
  text: string;
  /** SOURCE seconds — only with `includeSourceTimes` (MCP), never in a share. */
  sourceStart?: number;
  sourceEnd?: number;
}

/** One cue of a shared transcript (OUTPUT seconds) — the upload API's
 *  `TranscriptSegmentInput`. */
export interface ShareTranscriptSegment {
  start: number;
  end: number;
  text: string;
  words?: ShareTranscriptWord[];
  sourceStart?: number;
  sourceEnd?: number;
}

const byStart = <T extends { startTime: number }>(xs: readonly T[]): T[] =>
  [...xs].sort((a, b) => (a.startTime < b.startTime ? -1 : b.startTime < a.startTime ? 1 : 0));

/** `ShareIntelligence.transcriptPayload(for:includeSourceTimes:)` */
export function transcriptPayload(project: Project, includeSourceTimes = false): ShareTranscriptSegment[] {
  const trimStart = effectiveTrimStart(project);
  const trimEnd = smax(trimStart, effectiveTrimEnd(project));
  if (!(trimEnd > trimStart) || project.subtitles.length === 0) return [];
  const map = new SpeedTimeMap(trimStart, trimEnd, project.speedRegions);
  const out: ShareTranscriptSegment[] = [];
  for (const segment of byStart(project.subtitles.filter((s) => s.endTime > trimStart && s.startTime < trimEnd))) {
    const text = trimWhitespacesAndNewlines(segment.text);
    if (text.length === 0) continue;
    const payload: ShareTranscriptSegment = {
      start: map.outputTime(smax(segment.startTime, trimStart)),
      end: map.outputTime(smin(segment.endTime, trimEnd)),
      text: prefixChars(text, 500),
    };
    const words = segment.words
      .filter((w) => w.endTime > trimStart && w.startTime < trimEnd)
      .map((word) => {
        const entry: ShareTranscriptWord = {
          start: map.outputTime(smax(word.startTime, trimStart)),
          end: map.outputTime(smin(word.endTime, trimEnd)),
          text: prefixChars(word.text, 80),
        };
        // Word-exact edit coordinates (e.g. cutting one "um").
        if (includeSourceTimes) {
          entry.sourceStart = smax(word.startTime, trimStart);
          entry.sourceEnd = smin(word.endTime, trimEnd);
        }
        return entry;
      });
    if (words.length > 0) payload.words = words;
    if (includeSourceTimes) {
      payload.sourceStart = smax(segment.startTime, trimStart);
      payload.sourceEnd = smin(segment.endTime, trimEnd);
    }
    out.push(payload);
  }
  return out;
}

/**
 * The upload body's `transcript` for a share of `project` — exactly what the
 * Mac sends (`ShareIntelligence.transcriptPayload(for: project)`). Empty when
 * nothing survives the trim; like ShareJobCenter (`if !transcript.isEmpty {
 * body["transcript"] = transcript }`), leave the key OUT of the body then.
 */
export function transcriptForShare(project: Project): ShareTranscriptSegment[] {
  return transcriptPayload(project, false);
}
