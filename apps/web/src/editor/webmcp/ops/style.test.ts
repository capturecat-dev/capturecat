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

describe("cameraLook (Swift optionalEnumKey)", () => {
  it("lists none first, sets a look, and none clears it back to the plain bubble", () => {
    const entry = STYLE_KEYS.find((k) => k.key === "cameraLook")!;
    expect(entry.group).toBe("camera");
    expect(entry.kind).toEqual({ type: "enum", values: ["none", "cutout", "popOut"] });
    const s = defaultProjectSettings();
    applyStyle("cameraLook", "cutout", s);
    expect(s.cameraLook).toBe("cutout");
    applyStyle("cameraLook", "none", s);
    expect(s.cameraLook).toBeUndefined();
    expect(() => applyStyle("cameraLook", "Cutout", s)).toThrow(ToolError);
  });
});

describe("camera styles (docs/camera-cutout.md §12.8)", () => {
  it("sets every §12.1 key by name; none clears the enum keys; unset reads null / none / the default", () => {
    const s = defaultProjectSettings();
    const camera = (styleOptions({ ...newProject({ id: "00000000-0000-4000-8000-000000000001", duration: 3 }), settings: s }).groups as Record<
      string,
      Record<string, Record<string, unknown>>
    >).camera;
    expect(camera.cameraPopOutAmount).toMatchObject({ type: "number", min: 0, max: 1, current: null });
    expect(camera.cameraCardFill).toMatchObject({ type: "enum", values: ["none", "gradient", "camera", "color", "image"], current: "none" });
    expect(camera.cameraCardBorder).toMatchObject({ values: ["none", "solid", "aurora", "gold"], current: "none" });
    expect(camera.cameraShrinkOnZoom).toMatchObject({ type: "boolean", current: true });
    expect(camera.cameraCardBorderColor).toMatchObject({ type: "color", current: null });

    applyStyle("cameraPopOutAmount", 0.8, s);
    applyStyle("cameraCardFill", "camera", s);
    applyStyle("cameraBackgroundBlur", 0.6, s);
    applyStyle("cameraCardGradientStart", "#FF0000", s);
    applyStyle("cameraCardGradientEnd", "#0000FF", s);
    applyStyle("cameraCardColor", "#112233", s);
    applyStyle("cameraCardImagePath", "/CaptureCat/Projects/X/card.png", s);
    applyStyle("cameraEdgeSoftness", 0.4, s);
    applyStyle("cameraEdgeInset", 0.3, s);
    applyStyle("cameraCardBorder", "aurora", s);
    applyStyle("cameraCardBorderWidth", 1, s);
    applyStyle("cameraCardBorderColor", "#FFFFFF", s);
    applyStyle("cameraShrinkOnZoom", false, s);
    expect(s).toMatchObject({
      cameraPopOutAmount: 0.8,
      cameraCardFill: "camera",
      cameraBackgroundBlur: 0.6,
      cameraCardGradientStart: { red: 1, green: 0, blue: 0, opacity: 1 },
      cameraCardColor: { red: 0x11 / 255, green: 0x22 / 255, blue: 0x33 / 255, opacity: 1 },
      cameraCardImagePath: "/CaptureCat/Projects/X/card.png",
      cameraEdgeSoftness: 0.4,
      cameraEdgeInset: 0.3,
      cameraCardBorder: "aurora",
      cameraCardBorderWidth: 1,
      cameraShrinkOnZoom: false,
    });
    expect(message(() => applyStyle("cameraPopOutAmount", 1.5, s))).toBe("invalid value for cameraPopOutAmount: 1.5 (allowed: a number in 0...1)");
    expect(() => applyStyle("cameraCardFill", "wallpaper", s)).toThrow(ToolError);

    applyStyle("cameraCardFill", "none", s);
    applyStyle("cameraCardBorder", "none", s);
    expect(s.cameraCardFill).toBeUndefined();
    expect(s.cameraCardBorder).toBeUndefined();
    // optionalBoolKey: writing the default stores nil.
    applyStyle("cameraShrinkOnZoom", true, s);
    expect(s.cameraShrinkOnZoom).toBeUndefined();
    // The vertical stack (§12.12).
    applyStyle("cameraPortraitStack", true, s);
    applyStyle("cameraStackRatio", 0.5, s);
    expect(s).toMatchObject({ cameraPortraitStack: true, cameraStackRatio: 0.5 });
    applyStyle("cameraPortraitStack", false, s);
    expect(s.cameraPortraitStack).toBeUndefined();
    expect(message(() => applyStyle("cameraStackRatio", 0.8, s))).toBe("invalid value for cameraStackRatio: 0.8 (allowed: a number in 0.25...0.7)");
    applyStyle("cameraStackGap", 0, s);
    expect(s).toMatchObject({ cameraStackGap: 0 });
    expect(message(() => applyStyle("cameraStackGap", 0.1, s))).toBe("invalid value for cameraStackGap: 0.1 (allowed: a number in 0...0.08)");
  });
});

describe("set_style table", () => {
  it("has the Mac's 137 keys in 11 groups", () => {
    expect(STYLE_KEYS).toHaveLength(137);
    expect(new Set(STYLE_KEYS.map((k) => k.key)).size).toBe(137);
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
    expect(all.keyCount).toBe(137);
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
