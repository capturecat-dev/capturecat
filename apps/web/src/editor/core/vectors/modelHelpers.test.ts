import { describe, it } from "vitest";
import { checkUnit } from "./harness";
import {
  applySubtitlePreset,
  groupWords,
  hasTimedEffects,
  hidesTimelinePlayhead,
  isImageCapture,
  normalizedContentRect,
  presentsTimelessTimeline,
  sourceSegmentEnd,
  subtitlePresetMatches,
  subtitlePresets,
} from "../model/helpers";

describe("model helper golden vectors", () => {
  it("modelHelpers", () => {
    checkUnit("modelHelpers", (i) => ({
      isImageCapture: isImageCapture(i.project),
      presentsTimelessTimeline: presentsTimelessTimeline(i.project),
      hidesTimelinePlayhead: hidesTimelinePlayhead(i.project),
      hasTimedEffects: hasTimedEffects(i.project),
      segmentEnd: sourceSegmentEnd(i.segment),
      segmentRect: normalizedContentRect(i.segment),
    }));
  });

  it("subtitleGroupWords", () => {
    checkUnit("subtitleGroupWords", (i) => ({
      groups: groupWords(i.words, i.maxDuration, i.maxWords),
    }));
  });

  it("subtitlePresets", () => {
    checkUnit("subtitlePresets", (i) => {
      if (i.kind === "all") return subtitlePresets;
      const preset = subtitlePresets.find((p) => p.id === i.presetID)!;
      const applied = applySubtitlePreset(preset, i.settings);
      return {
        matchesBefore: subtitlePresets.map((p) => subtitlePresetMatches(p, i.settings)),
        applied,
        matchesAfter: subtitlePresets.map((p) => subtitlePresetMatches(p, applied)),
      };
    });
  });
});
