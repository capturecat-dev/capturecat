import { describe, expect, it } from "vitest";

import { newProject, type CursorEvent, type Project } from "../../core/model";
import { analyzeSilence, cursorActivity, describeProject, getTranscript, pacingDigest, timelineCounts } from "./describe";
import { HISTORY_LIMIT, commitExtras, planUndo, undoResult } from "./history";

const Z = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

function project(overrides: Partial<Project> = {}): Project {
  return { ...newProject({ id: Z(1), name: "Demo", duration: 20 }), ...overrides };
}

/** 20 Hz stream: moves for 1 s, parks until 6 s, double click at 6.0/6.5,
 * parks again to 12 s, then a 0.4 s drag. */
function cursor(): CursorEvent[] {
  const events: CursorEvent[] = [];
  let x = 100;
  for (let i = 0; i <= 12 * 20; i++) {
    const t = i / 20;
    if (t < 1) x += 20;
    const drag = t >= 11 && t < 11.4;
    if (drag) x += 40;
    events.push({ timestamp: t, x, y: 200, isClick: drag || t === 6 || t === 6.5 });
  }
  return events;
}

describe("describe_project", () => {
  it("reports SOURCE-time lanes, key settings and the output clock", () => {
    const p = project({
      trimStart: 2,
      zoomRegions: [
        { id: Z(3), startTime: 5, endTime: 6, zoomLevel: 2, focalPoint: { x: 0.5, y: 0.5 }, isAuto: true },
        { id: Z(2), startTime: 1, endTime: 2, zoomLevel: 1.23456, focalPoint: { x: 0.1, y: 0.2 }, followsCursor: false },
      ],
      speedRegions: [{ id: Z(4), startTime: 10, endTime: 12, speed: 2 }],
    });
    const d = describeProject(p, { cursor: null, screenSize: null, keystrokes: [], silence: null });
    expect(d).toMatchObject({
      id: Z(1),
      name: "Demo",
      duration: 20,
      trim: { start: 2, end: 20 },
      outputDuration: 17,
      isImageCapture: false,
      effects: {
        zoomRegions: [
          { id: Z(2), start: 1, end: 2, zoomLevel: 1.235, focalPoint: { x: 0.1, y: 0.2 }, followsCursor: false },
          { id: Z(3), auto: true },
        ],
      },
      speedRegions: [{ id: Z(4), start: 10, end: 12, speed: 2 }],
      settings: { backgroundPadding: 48, cursorStyle: "macOS Arrow" },
    });
    expect(d).not.toHaveProperty("interactionDigest");
    expect(d.pacing).toEqual({ hint: expect.stringContaining("quietSpans = no cursor movement") });
  });

  it("digests clicks (drags dropped) and idle spans, and intersects them with silence", () => {
    const activity = cursorActivity(cursor(), { width: 1920, height: 1080 })!;
    expect(activity.clicks.map((c) => c.timestamp)).toEqual([6, 6.5]);
    expect(activity.idleSpans).toEqual([
      { start: 0.95, end: 6 },
      { start: 6.5, end: 11 },
    ]);
    const p = project();
    const pacing = pacingDigest(p, activity, { kind: "noAudio" }, [{ timestamp: 3, category: "key" }]);
    expect(pacing).toMatchObject({
      audio: { tracks: 0, note: "no audio track — the whole recording is silent" },
      quietSpans: [
        { start: 0.95, end: 2.5, seconds: 1.55 },
        { start: 3.5, end: 6, seconds: 2.5 },
        { start: 6.5, end: 11, seconds: 4.5 },
      ].filter((s) => s.seconds >= 2),
      quietSeconds: 7,
    });
    const d = describeProject(p, { cursor: cursor(), screenSize: { width: 1920, height: 1080 }, keystrokes: [] });
    expect(d.interactionDigest).toMatchObject({
      totalEvents: 241,
      clickClusters: [{ start: 6, end: 6.5, clickCount: 2 }],
    });
    expect((d.pacing as object)).not.toHaveProperty("audio");
  });
});

describe("analyzeSilence", () => {
  it("finds ≥1 s silent runs at an adaptive threshold; a single loud window doesn't break one", () => {
    const rate = 8000;
    const samples = new Float32Array(rate * 10);
    for (let i = 0; i < samples.length; i++) {
      const t = i / rate;
      const loud = t < 1 || (t >= 5 && t < 5.05) || t >= 8;
      samples[i] = loud ? 0.5 * Math.sin(2 * Math.PI * 440 * t) : 0;
    }
    const outcome = analyzeSilence(samples, 1);
    expect(outcome.kind).toBe("analyzed");
    if (outcome.kind !== "analyzed") return;
    expect(outcome.analysis.thresholdDb).toBe(-55);
    expect(outcome.analysis.noiseFloorDb).toBe(-180);
    // The last loud window before the gap counts as quiet: its NEXT window is.
    expect(outcome.analysis.spans).toEqual([{ start: 19 * 0.05, end: 160 * 0.05 }]);
    expect(analyzeSilence(new Float32Array(10), 1)).toEqual({ kind: "noAudio" });
    expect(analyzeSilence(samples, 0)).toEqual({ kind: "noAudio" });
  });
});

describe("get_transcript", () => {
  it("retimes subtitles into OUTPUT seconds and keeps SOURCE times for edits", () => {
    const p = project({
      trimStart: 1,
      speedRegions: [{ id: Z(5), startTime: 2, endTime: 4, speed: 2 }],
      subtitles: [
        { id: Z(6), startTime: 5, endTime: 6, text: " Later ", words: [] },
        {
          id: Z(7),
          startTime: 0.5,
          endTime: 3,
          text: "Hello there",
          words: [
            { id: Z(8), startTime: 0.5, endTime: 1.5, text: "Hello" },
            { id: Z(9), startTime: 2, endTime: 3, text: "there" },
          ],
        },
        { id: Z(10), startTime: 7, endTime: 8, text: " \n ", words: [] },
      ],
    });
    const t = getTranscript(p);
    expect(t.count).toBe(2);
    expect(t.segments).toEqual([
      {
        start: 0,
        end: 1.5,
        text: "Hello there",
        sourceStart: 1,
        sourceEnd: 3,
        words: [
          { start: 0, end: 0.5, text: "Hello", sourceStart: 1, sourceEnd: 1.5 },
          { start: 1, end: 1.5, text: "there", sourceStart: 2, sourceEnd: 3 },
        ],
      },
      { start: 3, end: 4, text: "Later", sourceStart: 5, sourceEnd: 6 },
    ]);
    expect(getTranscript(project()).note).toContain("No transcript — the project has no subtitles yet.");
  });
});

describe("undo contract", () => {
  const entries = [
    { tool: "apply_edits", summary: "apply_edits: add_effect", at: "2026-09-30T10:00:01Z" },
    { tool: "set_trim", summary: "set_trim", at: "2026-09-30T10:00:00Z" },
  ];

  it("validates steps like the Mac", () => {
    expect(planUndo({}, entries)).toBe(1);
    expect(planUndo({ steps: 2 }, entries)).toBe(2);
    expect(() => planUndo({ steps: 1.5 }, entries)).toThrow("steps must be a whole number >= 1");
    expect(() => planUndo({ steps: "2" }, entries)).toThrow("steps must be a whole number >= 1");
    expect(() => planUndo({ steps: 3 }, entries)).toThrow("only 2 MCP edit(s) can be undone (asked for 3)");
    expect(() => planUndo({}, [])).toThrow("nothing to undo — no MCP edits are recorded for this project");
    expect(() => planUndo({}, entries, true)).toThrow(
      "project.json changed outside MCP after the last MCP edit (apply_edits: add_effect at 2026-09-30T10:00:01Z)",
    );
    expect(planUndo({ force: true }, entries, true)).toBe(1);
  });

  it("builds the undo payload and commit extras", () => {
    const restored = project();
    const result = undoResult(entries.slice(0, 1), 1, restored, null);
    expect(result).toEqual({
      undone: [entries[0]],
      remainingUndoSteps: 1,
      restored: timelineCounts(restored),
      note: "project.json.bak holds the state just before this undo.",
    });
    expect(commitExtras(HISTORY_LIMIT + 1)).toEqual({ undoSteps: 30 });
  });
});
