import { describe, expect, it } from "vitest";

import { newProject, type Project } from "../../core/model";
import { ToolError } from "./errors";
import { EDIT_OPS, EDIT_OP_NAMES, applyEditsBatch, editCore, editSummary, effectBlock, outputDuration } from "./edits";
import type { JSONObject, OpContext } from "./types";

const Z = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

function context(): OpContext & { ids: string[] } {
  let n = 0;
  const ids: string[] = [];
  return {
    ids,
    newId: () => {
      const id = `AAAAAAAA-0000-4000-8000-${String(++n).padStart(12, "0")}`;
      ids.push(id);
      return id;
    },
    autoZoom: () => 0,
    stillMotion: () => 0,
  };
}

function project(overrides: Partial<Project> = {}): Project {
  return { ...newProject({ id: Z(1), duration: 10, cursorDataURL: null }), ...overrides };
}

function run(name: string, p: Project, args: JSONObject, ctx: OpContext = context()): JSONObject {
  return editCore(name)!(p, args, ctx);
}

function fails(name: string, p: Project, args: JSONObject, ctx: OpContext = context()): string {
  try {
    run(name, p, args, ctx);
  } catch (error) {
    expect(error).toBeInstanceOf(ToolError);
    return (error as Error).message;
  }
  throw new Error(`${name} did not throw`);
}

describe("registry", () => {
  it("exposes the 14 batchable ops in schema order", () => {
    expect(EDIT_OP_NAMES).toEqual(Object.keys(EDIT_OPS));
    expect(EDIT_OP_NAMES).toHaveLength(14);
    expect(editCore("toString")).toBeNull();
    expect(editCore("describe_project")).toBeNull();
  });
});

describe("add_effect / update_effect / remove_effect", () => {
  it("clamps, links zoomtilt pairs and refuses EFFECTS-lane overlaps", () => {
    const p = project();
    const ctx = context(); // one id sequence for the whole test
    const created = run(
      "add_effect",
      p,
      {
        type: "zoomtilt",
        start: 1,
        end: 3,
        zoomLevel: 9,
        focalX: 1.5,
        offsetX: 0.004,
        offsetY: -2,
        followsCursor: false,
        pitch: 99,
        animationStyle: "Snappy",
      },
      ctx,
    );
    expect(created).toEqual({
      created: [
        { type: "zoom", id: "AAAAAAAA-0000-4000-8000-000000000001", zoomLevel: 6 },
        { type: "tilt", id: "AAAAAAAA-0000-4000-8000-000000000002" },
      ],
      span: { start: 1, end: 3 },
    });
    expect(p.zoomRegions[0]).toEqual({
      id: "AAAAAAAA-0000-4000-8000-000000000001",
      startTime: 1,
      endTime: 3,
      zoomLevel: 6,
      focalPoint: { x: 1, y: 0.5 },
      animationStyle: "Snappy",
      cardOffsetY: -1.5,
      followsCursor: false,
    });
    expect(p.tiltRegions[0].pitch).toBe(60);
    expect(fails("add_effect", p, { type: "zoom", start: 2.5, end: 4 }, ctx)).toBe(
      "span 2.5–4 overlaps existing zoom region AAAAAAAA-0000-4000-8000-000000000001 (1–3) — the EFFECTS lane " +
        "never overlaps. Pick a free span, shorten this one, or remove/move that region first (same batch is fine).",
    );
    // Touching blocks are fine.
    run("add_effect", p, { type: "tilt", start: 3, end: 4 }, ctx);
    expect(p.tiltRegions).toHaveLength(2);

    // `at` on the shared boundary: no block is strictly inside, so the first
    // hit of each lane wins — here the linked zoomtilt pair (both halves).
    expect(effectBlock(3, p)).toEqual({ zoom: 0, tilt: 0 });
    expect(effectBlock(3.5, p)).toEqual({ zoom: null, tilt: 1 });
    expect(effectBlock(2, p)).toEqual({ zoom: 0, tilt: 0 });

    const updated = run(
      "update_effect",
      p,
      { at: 2, zoomLevel: 2.5, roll: -99, animationStyle: null, followsCursor: 1 },
      ctx,
    );
    expect(updated.updated).toEqual([
      "zoom:AAAAAAAA-0000-4000-8000-000000000001",
      "tilt:AAAAAAAA-0000-4000-8000-000000000002",
    ]);
    expect(p.zoomRegions[0].animationStyle).toBeUndefined();
    expect(p.zoomRegions[0].followsCursor).toBeUndefined();
    expect(p.tiltRegions[0].roll).toBe(-30);
    expect(fails("update_effect", p, { at: 2, end: 3.5 })).toContain(
      "span 1–3.5 overlaps existing tilt region AAAAAAAA-0000-4000-8000-000000000003 (3–4)",
    );
    expect(fails("update_effect", p, { at: 9 })).toBe(
      "no zoom/tilt block spans SOURCE t=9 — describe_project lists effects.zoomRegions/tiltRegions with their start/end",
    );
    expect(run("remove_effect", p, { at: 1.5 })).toEqual({
      removed: 2,
      blocks: ["zoom:AAAAAAAA-0000-4000-8000-000000000001", "tilt:AAAAAAAA-0000-4000-8000-000000000002"],
    });
  });

  it("validates spans in SOURCE seconds against the recording", () => {
    const p = project();
    expect(fails("add_effect", p, { type: "zoom", start: 1 })).toBe(
      "add_effect needs start and end (SOURCE seconds, end > start)",
    );
    expect(fails("add_effect", p, { type: "zoom", start: 3, end: 2 })).toBe(
      "add_effect: invalid span 3–2 — need 0 <= start < end (SOURCE seconds)",
    );
    expect(fails("add_effect", p, { type: "zoom", start: 9, end: 10.5 })).toBe(
      "add_effect: span 9–10.5 runs past the recording's end (10s SOURCE). Times are SOURCE seconds — if you read " +
        "them off render_frames or get_transcript start/end, those are OUTPUT seconds; convert first.",
    );
    expect(fails("add_effect", p, { type: "zoom", start: 1, end: 2, animationStyle: 3 })).toBe(
      'invalid animationStyle: 3 (allowed: "Instant", "Snappy", "Smooth", "Slow Glide", "Cinematic", or null/omit ' +
        "for the project's animationSpeed)",
    );
    // duration 0 = unprobed → unbounded.
    const unprobed = project({ duration: 0 });
    run("add_effect", unprobed, { type: "zoom", start: 50, end: 60 });
    expect(outputDuration(unprobed)).toBeNull();
  });
});

describe("annotations", () => {
  it("applies the per-type new-annotation defaults then the field patch", () => {
    const p = project();
    run("add_annotation", p, { type: "rectangle", start: 1, end: 2, backdropOpacity: 3 });
    expect(p.annotations[0]).toMatchObject({
      x: 0.35,
      y: 0.375,
      arrowEndX: 0.65,
      arrowEndY: 0.625,
      showBackground: false,
      backgroundColor: { red: 1, green: 1, blue: 1, opacity: 0.25 },
      backdropOpacity: 0.9,
    });
    run("add_annotation", p, { type: "tap", start: 1, end: 2, fontSize: 5 });
    expect(p.annotations[1].fontSize).toBe(20);
    run("add_annotation", p, { type: "callout", start: 1, end: 2, text: "x".repeat(250) });
    expect(p.annotations[2].text).toHaveLength(200);
    expect(fails("add_annotation", p, { type: "drawing", start: 1, end: 2 })).toBe(
      "type must be one of: text, arrow, callout, rectangle, ellipse, tap (drawing/freehand strokes are editor-only — not scriptable)",
    );
    expect(fails("add_annotation", p, { type: "text", start: 1, end: 2, exitEffect: null })).toBe(
      'invalid exitEffect: <null> (allowed: "None", "Fade", "Pop", "Scale", "Slide Up", "Drop", "Explode", "Draw On")',
    );
    expect(fails("add_annotation", p, { type: "text", start: 1, end: 2, text: null })).toBe(
      "text must be a string (max 200 chars)",
    );
    expect(p.annotations).toHaveLength(3);
  });

  it("updates by (case-insensitive) id, never changing the type", () => {
    const p = project();
    const { created } = run("add_annotation", p, { type: "text", start: 1, end: 2 }) as { created: string };
    expect(fails("update_annotation", p, { annotationId: created.toLowerCase(), type: "arrow" })).toBe(
      "an annotation's type can't change (it is text) — remove_annotation and add_annotation instead",
    );
    expect(run("update_annotation", p, { annotationId: created.toLowerCase(), end: 4, color: "#00FF00" })).toEqual({
      updated: created,
      span: { start: 1, end: 4 },
    });
    expect(fails("update_annotation", p, { annotationId: "nope" })).toBe(
      "annotationId must be a UUID string (from add_annotation's 'created' or describe_project's annotations[].id)",
    );
    expect(run("remove_annotation", p, { annotationId: created })).toEqual({ removed: 1 });
    expect(fails("remove_annotation", p, { annotationId: created })).toBe(
      `no annotation with id ${created} — describe_project lists annotations with ids`,
    );
  });
});

describe("add_blur", () => {
  it("checks length, rect, strength, then the FOCUS lane", () => {
    const p = project();
    expect(fails("add_blur", p, { start: 0, end: 0.5 })).toContain("is shorter than 0.8s");
    expect(fails("add_blur", p, { start: 0, end: 1, x: 100, width: 200 })).toBe(
      "add_blur: rect x=100 y=0.3 width=200 height=0.15 is invalid — x/y/width/height are normalized 0–1 fractions " +
        "of the video frame (Y-down, not pixels), width/height >= 0.04, and the rect must stay inside the frame " +
        "(x+width <= 1, y+height <= 1)",
    );
    expect(run("add_blur", p, { start: 0, end: 1, style: "Pixelate", x: 0.5, width: 0.50005 })).toEqual({
      created: "AAAAAAAA-0000-4000-8000-000000000001",
      style: "Pixelate",
    });
    expect(p.blurRegions[0]).toMatchObject({ label: "Pixelate", rect: { x: 0.5, y: 0.3, width: 0.5, height: 0.15 } });
    expect(fails("add_blur", p, { start: 0.5, end: 2 })).toContain("overlaps the blur region");
  });
});

describe("speed / trim / cut", () => {
  it("creates, changes in place and refuses overlaps", () => {
    const p = project({ trimStart: 1, trimEnd: 9 });
    expect(fails("set_speed", p, { speed: 1.005, start: 1, end: 2 })).toBe(
      "speed 1.0 is normal playback — use remove_speed to clear a region instead",
    );
    const created = run("set_speed", p, { speed: 2, start: 0.5, end: 2 });
    expect(created).toMatchObject({
      created: { start: 0.5, end: 2, speed: 2 },
      outputDuration: { before: 8, after: 7.5 },
      note: "part of this span lies outside the trim window (1–9); only the part inside it plays",
    });
    expect(run("set_speed", p, { speed: 3, start: 0.505, end: 1.995 })).toMatchObject({ changed: { speed: 3 } });
    expect(fails("set_speed", p, { speed: 2, start: 1.5, end: 3 })).toContain("overlaps speed region(s)");
    expect(run("remove_speed", p, { at: 1 })).toMatchObject({ removed: ["AAAAAAAA-0000-4000-8000-000000000001"] });
  });

  it("trims with the 0.5 s minimum and refuses a window with no visible clip", () => {
    const p = project();
    expect(run("set_trim", p, { start: 2, end: 10.0005 })).toMatchObject({ trim: { start: 2, end: 10 } });
    expect(p.trimEnd).toBe(10);
    run("cut_video", p, { ranges: [{ start: 4, end: 6 }] });
    expect(p.splitPoints).toEqual([6]);
    expect(fails("set_trim", p, { start: 4.1, end: 5.9 })).toBe(
      "set_trim: the window 4.1–5.9 contains no visible video clip (cut_video removed that footage) — " +
        "describe_project lists clips; pick a window that overlaps one",
    );
    expect(p.trimStart).toBe(2);
    expect(fails("set_trim", project({ duration: 0 }), { start: 1 })).toBe(
      "this project has no probed duration yet — open it once in CaptureCat, then retry",
    );
  });

  it("cuts with sliver hygiene and never removes everything", () => {
    const p = project();
    // 9.97 is within the 0.05 s sliver guard of the clip's end: ignored.
    expect(fails("cut_video", p, { ranges: [{ start: 9.97, end: 12 }] })).toContain("ranges removed nothing");
    const result = run("cut_video", p, { ranges: [{ start: 2, end: 3 }, { start: 9.9, end: 12 }] });
    expect(result).toMatchObject({
      clips: [
        { start: 0, end: 2 },
        { start: 3, end: 9.9 },
      ],
      removedSeconds: 1.1,
    });
    expect(p.splitPoints).toEqual([3]);

    expect(fails("cut_video", p, { ranges: [{ start: 2.01, end: 2.99 }] })).toContain("ranges removed nothing");
    expect(fails("cut_video", p, { ranges: [{ start: 0, end: 10 }] })).toBe(
      "removing these ranges would leave no video at all — remove fewer ranges",
    );
    expect(fails("cut_video", p, { ranges: [{ start: 1, end: 2 }, 5] })).toContain(
      "ranges must be a non-empty array of {start, end}",
    );
  });
});

describe("apply_edits", () => {
  it("runs ops in order against one draft and reports each result", () => {
    const p = project();
    const result = applyEditsBatch(
      p,
      [
        { op: "add_effect", args: { type: "zoom", start: 1, end: 2, id: "ignored" } },
        { op: "set_style", patch: { backgroundPadding: 10 } },
        { op: "set_trim", args: 5, start: 1 },
      ],
      context(),
    );
    expect(result).toMatchObject({
      applied: 3,
      results: [
        { index: 0, op: "add_effect" },
        { index: 1, op: "set_style", result: { applied: { backgroundPadding: 10 } } },
        { index: 2, op: "set_trim" },
      ],
      outputDuration: { before: 10, after: 9 },
    });
    expect(editSummary("apply_edits", result)).toBe("apply_edits: add_effect, set_style, set_trim");
  });

  it("fails the whole batch with the Mac's wrapped message", () => {
    const p = project();
    const attempt = (ops: unknown) => {
      try {
        applyEditsBatch(p, ops, context());
      } catch (error) {
        return (error as Error).message;
      }
      return null;
    };
    expect(attempt([])).toBe(
      'ops must be a non-empty array of {op, args} — e.g. [{"op": "add_effect", "args": {"type": "zoom", "start": 2, "end": 5}}]',
    );
    expect(attempt(Array.from({ length: 201 }, () => ({ op: "set_trim", reset: true })))).toBe(
      "at most 200 ops per apply_edits call (got 201) — split the batch",
    );
    expect(attempt([{ op: "undo" }])).toBe(
      "apply_edits: ops[0] op 'undo' is not batchable (allowed: add_effect, update_effect, remove_effect, auto_zoom, " +
        "add_annotation, update_annotation, remove_annotation, add_blur, remove_blur, set_speed, remove_speed, " +
        "set_trim, cut_video, set_style). Nothing was written.",
    );
    expect(
      attempt([
        { op: "set_trim", args: { start: 1 } },
        { op: "set_speed", args: { speed: 9, start: 1, end: 2 } },
      ]),
    ).toBe(
      "apply_edits: ops[1] (set_speed) failed — speed 9 is outside 0.5...4 (the editor's range) Nothing was written " +
        "(the batch is all-or-nothing): fix that op and resend the whole batch.",
    );
  });

  it("routes auto_zoom through the host (still images → Motion)", () => {
    const calls: string[] = [];
    const ctx: OpContext = {
      newId: () => Z(99),
      autoZoom: (p, level) => {
        calls.push(`auto:${level}`);
        p.zoomRegions.push({ id: Z(98), startTime: 1, endTime: 2, zoomLevel: 2, focalPoint: { x: 0.25, y: 0.5 }, isAuto: true });
        return 1;
      },
      stillMotion: () => {
        calls.push("still");
        return 4;
      },
    };
    expect(fails("auto_zoom", project(), {})).toBe(
      "project has no recorded cursor data to generate zooms from — place zooms by hand with add_effect",
    );
    expect(run("auto_zoom", project({ isStillCapture: true }), {}, ctx)).toEqual({ created: 4, mode: "still-motion" });
    const withCursor = project({ cursorDataURL: "file:///tmp/cursor.json" });
    expect(run("auto_zoom", withCursor, { zoomLevel: 3 }, ctx)).toEqual({
      created: 1,
      zoomRegions: [{ id: Z(98), start: 1, end: 2, zoomLevel: 2, focalPoint: { x: 0.25, y: 0.5 } }],
    });
    expect(calls).toEqual(["still", "auto:3"]);
  });
});
