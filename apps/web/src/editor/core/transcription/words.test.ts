/**
 * Words → cues, locked to the Swift pipeline in TranscriptionService.transcribe
 * (`TimeInterval(word.start)` of WhisperKit's Float times, `.whitespaces`
 * trim, `SubtitleSegment.groupWords(words)` with 3.0 s / 8 words). The
 * grouping itself is also locked by the Swift golden vectors
 * (core/vectors/modelHelpers.test.ts `subtitleGroupWords`); the expected cues
 * below are that Swift logic evaluated by hand on real Whisper output.
 */
import { describe, expect, it } from "vitest";

import { groupWords } from "../model/helpers";
import { subtitlesFromWords, trimWhitespaces, wordsFromWhisperChunks, type WhisperWordChunk } from "./words";

const f = Math.fround;
const strip = (segs: ReturnType<typeof subtitlesFromWords>) =>
  segs.map(({ startTime, endTime, text, words }) => ({
    startTime,
    endTime,
    text,
    words: words.map((w) => [w.startTime, w.endTime, w.text]),
  }));

/** transformers.js `whisper-base.en_timestamped` output for the synthetic
 *  demo recording's first window (return_timestamps: "word"), plus a tail
 *  that exercises the 8-word and 3-second breaks. */
const WINDOW_1: WhisperWordChunk[] = [
  { text: " Welcome", timestamp: [1.1, 1.5] },
  { text: " to", timestamp: [1.5, 1.78] },
  { text: " Capture", timestamp: [1.78, 2.12] },
  { text: " Cat.", timestamp: [2.12, 2.62] },
  { text: " In", timestamp: [2.74, 2.88] },
  { text: " this", timestamp: [2.88, 3.14] },
  { text: " short", timestamp: [3.14, 3.42] },
  { text: " demo,", timestamp: [3.42, 3.88] },
  { text: " I", timestamp: [4, 4.12] },
  { text: " will", timestamp: [4.12, 4.34] },
  { text: " show", timestamp: [4.34, 4.52] },
  { text: " you", timestamp: [4.52, 4.7] },
  { text: " how", timestamp: [4.7, 4.9] },
  { text: " to", timestamp: [4.9, 5.0] },
  { text: " record", timestamp: [7.9, 8.2] },
  { text: " it?", timestamp: [8.2, 8.5] },
  { text: " Yes!", timestamp: [8.6, 8.9] },
  { text: " Done", timestamp: [9.0, null] },
];

describe("Whisper words → recording-time words (TranscriptionService.transcribe)", () => {
  it("offsets by the window start, widens Float times, trims .whitespaces", () => {
    const words = wordsFromWhisperChunks(
      [
        { text: " Next,", timestamp: [0.3, 0.62] },
        { text: "\tthe ", timestamp: [0.62, 0.8] },
        { text: "line\n", timestamp: [0.8, 1] },
      ],
      25.5,
      30,
    );
    expect(words).toEqual([
      { startTime: f(25.8), endTime: f(26.12), text: "Next," },
      { startTime: f(26.12), endTime: f(26.3), text: "the" },
      // Newlines are not in CharacterSet.whitespaces.
      { startTime: f(26.3), endTime: f(26.5), text: "line\n" },
    ]);
    // Float32 widening, exactly what the Mac stores.
    expect(words[0].startTime).toBe(25.799999237060547);
  });

  it("clamps into the window; a missing end runs to the next word (≤ 1 s)", () => {
    const words = wordsFromWhisperChunks(
      [
        { text: " a", timestamp: [-0.02, 0.2] },
        { text: " b", timestamp: [0.5, 0.4] },
        { text: " open", timestamp: [1, null] },
        { text: " next", timestamp: [1.4, 1.6] },
        { text: " c", timestamp: [9.8, 10.4] },
        { text: " d", timestamp: [9.9, null] },
        { text: " e", timestamp: [null, 1] },
      ],
      10,
      10,
    );
    expect(words.map((w) => [w.startTime, w.endTime, w.text])).toEqual([
      [10, f(10.2), "a"],
      [f(10.5), f(10.5), "b"],
      [11, f(11.4), "open"],
      [f(11.4), f(11.6), "next"],
      [f(19.8), 20, "c"],
      [f(19.9), 20, "d"],
    ]);
  });

  it("matches the Swift trim", () => {
    expect(trimWhitespaces(" \t x y  ")).toBe("x y");
    expect(trimWhitespaces("\nx\n")).toBe("\nx\n");
  });
});

describe("words → cues (SubtitleSegment.groupWords, 3.0 s / 8 words)", () => {
  const words = wordsFromWhisperChunks(WINDOW_1, 0, 30);
  const cues = subtitlesFromWords(words);

  it("breaks after . ? !, at 8 words and past 3 s — the Mac's cues", () => {
    expect(strip(cues)).toEqual([
      {
        startTime: f(1.1),
        endTime: f(2.62),
        text: "Welcome to Capture Cat.",
        words: [
          [f(1.1), f(1.5), "Welcome"],
          [f(1.5), f(1.78), "to"],
          [f(1.78), f(2.12), "Capture"],
          [f(2.12), f(2.62), "Cat."],
        ],
      },
      {
        startTime: f(2.74),
        endTime: f(4.7),
        text: "In this short demo, I will show you",
        words: [
          [f(2.74), f(2.88), "In"],
          [f(2.88), f(3.14), "this"],
          [f(3.14), f(3.42), "short"],
          [f(3.42), f(3.88), "demo,"],
          [f(4), f(4.12), "I"],
          [f(4.12), f(4.34), "will"],
          [f(4.34), f(4.52), "show"],
          [f(4.52), f(4.7), "you"],
        ],
      },
      // "how" is the 9th word → new cue; "record" ends 3.5 s after "how" began.
      { startTime: f(4.7), endTime: f(5), text: "how to", words: [[f(4.7), f(4.9), "how"], [f(4.9), f(5), "to"]] },
      { startTime: f(7.9), endTime: f(8.5), text: "record it?", words: [[f(7.9), f(8.2), "record"], [f(8.2), f(8.5), "it?"]] },
      { startTime: f(8.6), endTime: f(8.9), text: "Yes!", words: [[f(8.6), f(8.9), "Yes!"]] },
      // Whisper left the last word open: one second.
      { startTime: f(9), endTime: f(10), text: "Done", words: [[f(9), f(10), "Done"]] },
    ]);
  });

  it("is the project's cue model: fresh uppercase UUIDs, word timings inside", () => {
    const uuid = /^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/;
    for (const cue of cues) {
      expect(cue.id).toMatch(uuid);
      for (const w of cue.words) expect(w.id).toMatch(uuid);
      expect(Object.keys(cue).sort()).toEqual(["endTime", "id", "startTime", "text", "words"]);
    }
    expect(new Set(cues.map((c) => c.id)).size).toBe(cues.length);
  });

  it("uses the Mac's defaults", () => {
    expect(strip(subtitlesFromWords(words))).toEqual(strip(groupWords(words, 3.0, 8)));
    expect(subtitlesFromWords([])).toEqual([]);
  });
});
