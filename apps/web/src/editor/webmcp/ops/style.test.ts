import { describe, expect, it } from "vitest";

import { defaultProjectSettings, newProject } from "../../core/model";
import { ToolError } from "./errors";
import { STYLE_GROUPS, STYLE_KEYS, applyStyle, hexString, levenshtein, parseHexColor, styleKeySummary, styleOptions } from "./style";

const message = (fn: () => void): string => {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(ToolError);
    return (error as Error).message;
  }
  throw new Error("expected a ToolError");
};

describe("CodableColor(hex:) / hexString", () => {
  it("parses #RRGGBB and #RRGGBBAA, '#' optional, whitespace trimmed", () => {
    expect(parseHexColor("#FF3B30")).toEqual({ red: 1, green: 59 / 255, blue: 48 / 255, opacity: 1 });
    expect(parseHexColor(" ff3b30cc\t")).toEqual({ red: 1, green: 59 / 255, blue: 48 / 255, opacity: 204 / 255 });
    expect(parseHexColor("#FFF")).toBeNull();
    expect(parseHexColor("#GGGGGG")).toBeNull();
    expect(parseHexColor("red")).toBeNull();
  });

  it("accepts UInt64(_:radix:)'s optional sign, like Swift", () => {
    expect(parseHexColor("+FFFFF")).toEqual({ red: 15 / 255, green: 1, blue: 1, opacity: 1 });
    expect(parseHexColor("-00000")).toEqual({ red: 0, green: 0, blue: 0, opacity: 1 });
    expect(parseHexColor("-00001")).toBeNull();
  });

  it("hexString rounds each channel and appends alpha only when not opaque", () => {
    expect(hexString({ red: 1, green: 0.5, blue: 0, opacity: 1 })).toBe("#FF8000");
    expect(hexString({ red: 0, green: 0, blue: 0, opacity: 0.55 })).toBe("#0000008C");
    expect(hexString({ red: 2, green: -1, blue: NaN, opacity: 0.9995 })).toBe("#FF0000");
  });
});

describe("set_style table", () => {
  it("has the Mac's 120 keys in 11 groups", () => {
    expect(STYLE_KEYS).toHaveLength(120);
    expect(new Set(STYLE_KEYS.map((k) => k.key)).size).toBe(120);
    expect(new Set(STYLE_KEYS.map((k) => k.group))).toEqual(new Set(STYLE_GROUPS));
    expect(styleKeySummary()).toContain("canvas: aspectRatio, backgroundPadding, videoPlacement, frameShape, cornerRadius… (+4)");
  });

  it("validates each kind with the Mac's messages", () => {
    const s = defaultProjectSettings();
    expect(message(() => applyStyle("aspectRatio", "16:10", s))).toBe(
      'invalid value for aspectRatio: 16:10 (allowed: "Auto", "16:9", "4:3", "1:1", "9:16", "21:9", "4:5" — exact, case-sensitive)',
    );
    expect(message(() => applyStyle("backgroundPadding", 301, s))).toBe(
      "invalid value for backgroundPadding: 301 (allowed: a number in 0...300)",
    );
    expect(message(() => applyStyle("backgroundPadding", true, s))).toBe(
      "invalid value for backgroundPadding: 1 (allowed: a number in 0...300)",
    );
    expect(message(() => applyStyle("smoothingFactor", 0.04, s))).toBe(
      "invalid value for smoothingFactor: 0.04 (allowed: a number in 0.05...0.5)",
    );
    expect(message(() => applyStyle("showCursor", 2, s))).toBe("showCursor must be a boolean (true/false), got 2");
    expect(message(() => applyStyle("cameraTagText", "x".repeat(61), s))).toBe(
      "cameraTagText must be a string of at most 60 characters",
    );
    expect(message(() => applyStyle("solidColor", "#12345", s))).toBe(
      'solidColor must be a hex color string, e.g. "#FF3B30" or "#FF3B30CC" (RRGGBB or RRGGBBAA)',
    );
  });

  it("suggests close keys (Foundation `contains`: an empty key matches nothing)", () => {
    const s = defaultProjectSettings();
    const tail = " Call style_options for every settable key with its type, range and current value.";
    expect(message(() => applyStyle("shadow", 1, s))).toBe(
      "key not whitelisted: shadow — did you mean 'shadowRadius' or 'shadowOpacity'?" + tail,
    );
    expect(message(() => applyStyle("backgroundPadingg", 1, s))).toBe(
      "key not whitelisted: backgroundPadingg — did you mean 'backgroundPadding'?" + tail,
    );
    expect(message(() => applyStyle("", 1, s))).toBe("key not whitelisted: " + tail);
    expect(levenshtein("kitten", "sitting")).toBe(3);
  });

  it("writes values and runs the `then` side effects", () => {
    const s = defaultProjectSettings();
    s.videoCustomX = 0.2;
    s.videoCustomY = 0.8;
    applyStyle("videoPlacement", "Top", s);
    expect(s.videoPlacement).toBe("Top");
    expect(s.videoCustomX).toBeUndefined();
    expect(s.videoCustomY).toBeUndefined();
    applyStyle("cursorLoopToStart", true, s);
    applyStyle("cursorStopAtEnd", 1, s);
    expect(s.cursorStopAtEnd).toBe(true);
    expect(s.cursorLoopToStart).toBe(false);
    applyStyle("gradientStartColor", "#00FF0080", s);
    expect(s.gradientStartColor).toEqual({ red: 0, green: 1, blue: 0, opacity: 128 / 255 });
  });
});

describe("style_options", () => {
  it("lists every group with types, ranges and (with a project) current values", () => {
    const project = newProject({ id: "00000000-0000-4000-8000-000000000001", duration: 3 });
    const all = styleOptions(project);
    expect(all.keyCount).toBe(120);
    const canvas = (all.groups as Record<string, Record<string, Record<string, unknown>>>).canvas;
    expect(canvas.backgroundPadding).toEqual({
      type: "number",
      min: 0,
      max: 300,
      note: "space around the video card, canvas points",
      current: 48,
    });
    const background = (all.groups as Record<string, Record<string, Record<string, unknown>>>).background;
    expect(background.gradientAngle.current).toBeNull();
    expect(background.gradientStartColor.current).toBe("#DB34F2");

    const noProject = styleOptions(null, "intro");
    expect(Object.keys(noProject.groups as object)).toEqual(["intro"]);
    expect(((noProject.groups as Record<string, Record<string, object>>).intro.curtainColor as object)).not.toHaveProperty("current");
    expect(Object.keys(styleOptions(null, 5).groups as object)).toHaveLength(11);
    expect(message(() => styleOptions(null, "nope"))).toBe(
      "unknown group 'nope' (groups: canvas, background, cursor, clicksAndKeys, camera, menuBar, motion, intro, audio, subtitles, watermark)",
    );
  });
});
