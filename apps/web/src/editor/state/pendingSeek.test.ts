import { describe, expect, it } from "vitest";

import { newProject, newSpeedRegion, serializeProjectText } from "../core/model";
import { EditorController } from "./controller";
import { parsePendingSeek, pendingSeekOutputTime } from "./pendingSeek";
import { EditorStore } from "./store";

describe("?t= pending seek (DeepLinkHandler: `Double(tString)`, t ≥ 0)", () => {
  it("parses what Swift's Double(String) parses", () => {
    expect(parsePendingSeek("12.5")).toBe(12.5);
    expect(parsePendingSeek("0")).toBe(0);
    expect(parsePendingSeek(".5")).toBe(0.5);
    expect(parsePendingSeek("3.")).toBe(3);
    expect(parsePendingSeek("1e2")).toBe(100);
    expect(parsePendingSeek("+4")).toBe(4);
    expect(parsePendingSeek("0x1p3")).toBe(8);
    expect(parsePendingSeek("inf")).toBe(Infinity);
    // A JSON-ish search parser may already have made a number.
    expect(parsePendingSeek(7)).toBe(7);
  });

  it("rejects negatives, NaN, junk and whitespace", () => {
    for (const bad of ["-1", "nan", "abc", " 5", "5s", "", "1,5", null, undefined, true, {}, -0.5, Number.NaN]) {
      expect(parsePendingSeek(bad)).toBeNull();
    }
  });

  it("clamps to the trimmed + retimed OUTPUT duration", () => {
    const p = newProject({ duration: 20 });
    p.trimEnd = 12;
    p.speedRegions.push({ ...newSpeedRegion(0, 4), speed: 2 });
    // output duration: 4 / 2 + 8 = 10
    expect(pendingSeekOutputTime(p, 7.25)).toBe(7.25);
    expect(pendingSeekOutputTime(p, 99)).toBe(10);
    expect(pendingSeekOutputTime(p, Infinity)).toBe(10);
  });

  it("lands the playhead (output) — the SOURCE frame follows the speed map", () => {
    const p = newProject({ duration: 20 });
    p.speedRegions.push({ ...newSpeedRegion(0, 4), speed: 2 });
    const store = new EditorStore();
    store.load({ text: serializeProjectText(p), origin: "local", revision: null });
    const controller = new EditorController(store);
    controller.seek(pendingSeekOutputTime(store.getState().project!, 5));
    expect(controller.playhead.get()).toBe(5);
    expect(store.playheadSource()).toBeCloseTo(7, 12);
  });
});
