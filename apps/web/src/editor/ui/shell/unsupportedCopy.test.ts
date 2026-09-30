import { describe, expect, it } from "vitest";
import { unsupportedFeatureName, unsupportedFeatures } from "../../engine/contract";
import { listPhrase, unsupportedNoticeCopy } from "./unsupportedCopy";

describe("unsupported-features notice", () => {
  it("stitched device segments are drawn now — no longer flagged", () => {
    const project = {
      duration: 5,
      recordingSourceKind: "display",
      settings: { showDeviceFrame: true },
      sourceSegments: [
        { startTime: 0, duration: 1.6, kind: "display", contentX: 0, contentY: 0, contentWidth: 1, contentHeight: 1 },
        { startTime: 1.6, duration: 1.8, kind: "device", contentX: 0.37, contentY: 0, contentWidth: 0.26, contentHeight: 1 },
      ],
    };
    expect(unsupportedFeatures(project)).toEqual([]);
    expect(unsupportedFeatures(null)).toEqual([]);
    expect(unsupportedFeatures({ settings: 3 })).toEqual([]);
  });

  it("names features in the Mac's words, de-camel-casing unknown ids", () => {
    expect(unsupportedFeatureName("sourceSegments")).toBe("Stitched iPhone segments");
    expect(unsupportedFeatureName("keystrokeOverlay")).toBe("Keystroke overlay");
  });

  it("lists like the Mac and says the way out", () => {
    expect(listPhrase([])).toBe("");
    expect(listPhrase(["A"])).toBe("A");
    expect(listPhrase(["A", "B"])).toBe("A and B");
    expect(listPhrase(["A", "B", "C"])).toBe("A, B and C");
    expect(unsupportedNoticeCopy([])).toBeNull();
    const one = unsupportedNoticeCopy(["sourceSegments"])!;
    expect(one.title).toBe("Some of this project can’t be shown on the web yet");
    expect(one.message).toBe(
      "Stitched iPhone segments won’t appear in the preview or in exports made here. Export from CaptureCat on your Mac to include it.",
    );
    const two = unsupportedNoticeCopy(["sourceSegments", "keystrokeOverlay"])!;
    expect(two.message.startsWith("Stitched iPhone segments and keystroke overlay won’t appear")).toBe(true);
    expect(two.message.endsWith("to include them.")).toBe(true);
  });
});
