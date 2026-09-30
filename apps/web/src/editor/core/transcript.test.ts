import { describe, expect, it } from "vitest";

// The upload API's own validator for the body's `transcript` — the web's
// payload must pass it untouched (modulo its 2-decimal rounding).
import { TranscriptSchema } from "../../../../api/src/lib/upload-schemas";
import { newProject, type Project, type SubtitleSegment } from "./model";
import { transcriptForShare, transcriptPayload } from "./transcript";

const Z = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

function project(patch: Partial<Project> = {}): Project {
  return Object.assign(newProject({ id: Z(1), duration: 20, videoURL: "file:///tmp/r.mov" }), patch);
}

const seg = (id: number, startTime: number, endTime: number, text: string, words: [number, number, string][] = []): SubtitleSegment => ({
  id: Z(id),
  startTime,
  endTime,
  text,
  words: words.map(([s, e, t], i) => ({ id: Z(id * 100 + i), startTime: s, endTime: e, text: t })),
});

describe("transcriptForShare (ShareIntelligence.transcriptPayload(for:))", () => {
  const p = project({
    trimStart: 1,
    trimEnd: 12,
    // Source 2–4 s plays at 2× (1 s of output).
    speedRegions: [{ id: Z(2), startTime: 2, endTime: 4, speed: 2 }],
    subtitles: [
      seg(3, 5, 6, " Later cue ", [[5, 5.5, "Later"], [5.5, 6, "cue"]]),
      seg(4, 0.5, 3, "Hello there", [[0.5, 1.5, "Hello"], [2, 3, "there"]]),
      seg(5, 7, 8, " \n "), // blank → dropped
      seg(6, 11.5, 14, "Cut by the trim end", [[11.5, 12.5, "Cut"], [12.5, 14, "gone"]]),
      seg(7, 12.5, 13, "After the trim"), // outside → dropped
    ],
  });

  it("retimes into OUTPUT seconds, clips to the trim, sorts, trims text — no SOURCE keys", () => {
    expect(transcriptForShare(p)).toEqual([
      {
        start: 0,
        end: 1.5,
        text: "Hello there",
        words: [
          { start: 0, end: 0.5, text: "Hello" },
          { start: 1, end: 1.5, text: "there" },
        ],
      },
      {
        start: 3,
        end: 4,
        text: "Later cue",
        words: [
          { start: 3, end: 3.5, text: "Later" },
          { start: 3.5, end: 4, text: "cue" },
        ],
      },
      { start: 9.5, end: 10, text: "Cut by the trim end", words: [{ start: 9.5, end: 10, text: "Cut" }] },
    ]);
  });

  it("is the MCP get_transcript payload minus the SOURCE times", () => {
    const withSource = transcriptPayload(p, true);
    const stripped = withSource.map(({ sourceStart: _s, sourceEnd: _e, words, ...rest }) => ({
      ...rest,
      ...(words ? { words: words.map(({ sourceStart: _ws, sourceEnd: _we, ...w }) => w) } : {}),
    }));
    expect(stripped).toEqual(transcriptForShare(p));
    expect(withSource[0]).toMatchObject({ sourceStart: 1, sourceEnd: 3 });
  });

  it("caps text at 500 / 80 grapheme clusters (Swift String.prefix)", () => {
    const long = "👩‍💻".repeat(600);
    const out = transcriptForShare(project({ subtitles: [seg(8, 1, 2, long, [[1, 2, "🧑🏽‍🚀".repeat(100)]])] }));
    expect(Array.from(new Intl.Segmenter().segment(out[0].text))).toHaveLength(500);
    expect(Array.from(new Intl.Segmenter().segment(out[0].words![0].text))).toHaveLength(80);
  });

  it("is empty with no subtitles or an empty trim (the upload then omits the key)", () => {
    expect(transcriptForShare(project())).toEqual([]);
    expect(transcriptForShare(project({ trimStart: 5, trimEnd: 5, subtitles: [seg(9, 5, 6, "x")] }))).toEqual([]);
  });

  it("passes the upload API's TranscriptSchema unchanged", () => {
    const payload = transcriptForShare(p);
    expect(TranscriptSchema.parse(JSON.parse(JSON.stringify(payload)))).toEqual(payload);
  });
});
