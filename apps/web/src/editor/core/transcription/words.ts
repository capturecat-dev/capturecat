/**
 * Recognized words → subtitle cues, the tail of the Mac's
 * `TranscriptionService.transcribe(videoURL:)`:
 *
 *   for word in result.allWords {
 *     words.append(SubtitleSegment(startTime: TimeInterval(word.start),
 *                                  endTime: TimeInterval(word.end),
 *                                  text: word.word.trimmingCharacters(in: .whitespaces)))
 *   }
 *   SubtitleSegment.groupWords(words)          // maxDuration 3.0, maxWords 8
 *
 * Times are RECORDING seconds (the recording's own audio timeline), which is
 * the project's SOURCE time — subtitles are stored in source time and the
 * exporter / timeline retime them through trim + speed like every other
 * region, so nothing is converted here.
 *
 * WhisperKit's word times are `Float`; `TimeInterval(word.start)` widens
 * them, so the stored doubles carry float32 precision (1.1 → 1.100000023841858).
 * `Math.fround` reproduces that, making the web's project.json values the
 * ones the Mac writes for the same timings.
 */
import { groupWords } from "../model/helpers";
import type { SubtitleSegment } from "../model/types";

/** One recognized word, in recording seconds (WhisperKit `WordTiming`). */
export interface TranscribedWord {
  startTime: number;
  endTime: number;
  text: string;
}

/** A transformers.js Whisper word chunk (`return_timestamps: "word"`):
 *  window-relative seconds; the end can be missing on the last word. */
export interface WhisperWordChunk {
  text: string;
  timestamp: readonly [number | null, number | null] | readonly number[];
}

/** `String.trimmingCharacters(in: .whitespaces)` — Unicode Zs + TAB (not newlines). */
export function trimWhitespaces(s: string): string {
  return s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");
}

const finite = (v: number | null | undefined): v is number => typeof v === "number" && Number.isFinite(v);

/** A word with no end time lasts until the next word, at most this long. */
const MISSING_END_SECONDS = 1;

/**
 * One window's word chunks → recording-time words. `windowStart` is the
 * window's first sample in seconds, `windowDuration` its length: word times
 * are clamped into the window. A missing end (transformers.js can leave the
 * last word open) runs to the next word's start, at most one second.
 */
export function wordsFromWhisperChunks(
  chunks: readonly WhisperWordChunk[],
  windowStart: number,
  windowDuration: number,
): TranscribedWord[] {
  const words: TranscribedWord[] = [];
  for (let i = 0; i < chunks.length; i++) {
    const chunk = chunks[i];
    const [s, e] = chunk.timestamp;
    if (!finite(s)) continue;
    const start = Math.min(Math.max(0, s), windowDuration);
    const next = chunks[i + 1]?.timestamp[0];
    const open = Math.min(start + MISSING_END_SECONDS, finite(next) ? next : Infinity);
    const end = Math.min(Math.max(start, finite(e) ? e : open), windowDuration);
    words.push({
      startTime: Math.fround(windowStart + start),
      endTime: Math.fround(windowStart + end),
      text: trimWhitespaces(chunk.text),
    });
  }
  return words;
}

/** `SubtitleSegment.groupWords(words)` with the Mac's defaults (3.0 s, 8 words). */
export function subtitlesFromWords(words: readonly TranscribedWord[]): SubtitleSegment[] {
  return groupWords(words);
}
