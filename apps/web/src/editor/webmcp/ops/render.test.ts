import { describe, expect, it } from "vitest";

import {
  clampFrameTime,
  contactSheetLabel,
  contactSheetLayout,
  frameCaption,
  parseRenderFramesArgs,
  renderFrameTimes,
  renderFramesHeader,
} from "./render";

const error = (args: Record<string, unknown>) => {
  try {
    parseRenderFramesArgs(args);
  } catch (e) {
    return (e as Error).message;
  }
  return null;
};

describe("render_frames arguments", () => {
  it("applies the Mac defaults and clamps", () => {
    expect(parseRenderFramesArgs({ times: [1, 2] })).toEqual({
      layout: "individual",
      sheet: false,
      maxFrames: 8,
      jpeg: false,
      quality: 0.8,
      maxEdge: 800,
      times: [1, 2],
      span: null,
    });
    expect(parseRenderFramesArgs({ layout: "contact_sheet", format: "JPG", maxWidth: 99999, span: {} })).toMatchObject({
      sheet: true,
      jpeg: true,
      maxEdge: 2400,
      span: { start: 0, end: null, count: 12 },
    });
  });

  it("rejects bad arguments with the Mac's messages", () => {
    expect(error({ layout: "grid" })).toContain('layout must be "individual"');
    expect(error({ format: "gif" })).toBe('format must be "png" or "jpeg"');
    expect(error({ quality: null })).toBe("quality must be a number in 0.1...1 (jpeg only)");
    expect(error({ times: [1], span: {} })).toBe("pass either times or span, not both");
    expect(error({ times: [1, "2"] })).toBe("times must be a non-empty array of numbers (OUTPUT seconds)");
    expect(error({ times: [0, 1, 2, 3, 4, 5, 6, 7, 8] })).toBe(
      'max 8 times per call for layout individual — use layout "contact_sheet" for up to 16 in one image',
    );
    expect(error({ layout: "contact_sheet", span: { count: 0.5 } })).toBe("span.count must be 1...16 for layout contact_sheet");
    expect(error({ span: { start: 2, end: 2 } })).toBe(
      "span needs 0 <= start < end (OUTPUT seconds; end defaults to the video's end)",
    );
    expect(error({})).toBe("pass times: [OUTPUT seconds…] or span: {start?, end?, count?} to sample evenly");
  });

  it("samples a span evenly and refuses one past the end", () => {
    const request = parseRenderFramesArgs({ span: { start: 1, count: 3 } });
    expect(renderFrameTimes(request, 5)).toEqual([1, 3, 5]);
    expect(renderFrameTimes(parseRenderFramesArgs({ span: { start: 2, count: 1 } }), 5)).toEqual([2]);
    expect(() => renderFrameTimes(parseRenderFramesArgs({ span: { start: 6 } }), 5.25)).toThrow(
      "span start 6s is past the end of the output (5.25s)",
    );
    expect(clampFrameTime(9, 5)).toBe(4.999);
    expect(clampFrameTime(-1, 5)).toBe(0);
  });
});

describe("render_frames text", () => {
  it("formats captions, labels and the header like the Mac", () => {
    expect(frameCaption(0, 1.005, 2.5)).toBe("frame #1 at t=1.00s (source 2.50s):");
    expect(frameCaption(2, 3, null)).toBe("frame #3 at t=3.00s:");
    expect(contactSheetLabel(11, 12.345, 20)).toBe("#12  12.35s  src 20.00");
    const layout = contactSheetLayout(2, 16 / 9, 1568);
    expect(
      renderFramesHeader({
        freshlyRendered: true,
        duration: 12.3456,
        layout: "contact_sheet",
        frames: [
          { output: 0, source: 1.5 },
          { output: 1.23456, source: null },
        ],
        sheetLayout: layout,
      }),
    ).toMatchObject({
      render: "fresh export",
      durationSeconds: 12.35,
      frames: 2,
      grid: `${layout.columns}x${layout.rows}`,
      tiles: [
        { tile: 1, output: 0, source: 1.5 },
        { tile: 2, output: 1.235 },
      ],
    });
  });

  it("lays a contact sheet out closest to 3:2 within maxEdge", () => {
    expect(contactSheetLayout(12, 16 / 9, 1568)).toEqual({
      columns: 3,
      rows: 4,
      tile: { width: 514, height: 289 },
      captionHeight: 42,
      fontSize: 26,
      gap: 6,
      size: { width: 1566, height: 1354 },
    });
    for (const [count, aspect, edge] of [
      [1, 16 / 9, 400],
      [16, 9 / 16, 2400],
      [7, 1, 800],
      [5, 21 / 9, 1000],
    ]) {
      const l = contactSheetLayout(count, aspect, edge);
      expect(l.columns * l.rows).toBeGreaterThanOrEqual(count);
      expect(Math.max(l.size.width, l.size.height)).toBeLessThanOrEqual(edge);
    }
  });
});
