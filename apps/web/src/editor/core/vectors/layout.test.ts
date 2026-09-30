import { describe, it } from "vitest";
import { checkUnit } from "./harness";
import { interpolate, interpolateIfFresh, smooth } from "../math/cursorSmoother";
import { alignment, customOrigin, isCustom, magnetism, nearest, snap } from "../math/placementMath";
import {
  alignmentFractions,
  canvasScale,
  cardTransform,
  exportFrameTimes,
  frameLayout,
  menuBarCrop,
} from "../math/exportLayout";
import { applyTransform } from "../math/geometry";
import {
  aspectSize,
  canvasAspect,
  estimatedVideoBitRate,
  letterboxRect,
  normalizedQuality,
  outputWidth,
  qualityPresetName,
  resolutionFitting,
  resolvedOutputSize,
} from "../math/aspectRatio";

describe("layout golden vectors", () => {
  it("cursorSmoother", () => {
    checkUnit("cursorSmoother", (i) => ({
      smoothed: smooth(i.events, i.factor),
      interpolate: i.queries.map((q: number) => interpolate(i.events, q)),
      interpolateIfFresh: i.queries.map((q: number) =>
        interpolateIfFresh(i.events, q, i.freshnessThreshold ?? undefined),
      ),
    }));
  });

  it("placementMath", () => {
    checkUnit("placementMath", (i) => {
      const s = { ...i.settings, videoCustomX: i.settings.videoCustomX ?? undefined, videoCustomY: i.settings.videoCustomY ?? undefined };
      return {
        snapX: snap(i.fx),
        nearest: nearest(i.fx, i.fy),
        isCustom: isCustom(s),
        alignment: alignment(s),
        customOrigin: customOrigin(i.fraction, i.canvas, i.video),
        magnetism,
      };
    });
  });

  const settingsOf = (raw: Record<string, unknown>) => ({
    ...raw,
    videoCustomX: (raw.videoCustomX as number | null) ?? undefined,
    videoCustomY: (raw.videoCustomY as number | null) ?? undefined,
  }) as Parameters<typeof frameLayout>[2];

  it("exportFrameLayout", () => {
    checkUnit("exportFrameLayout", (i) => {
      const s = settingsOf(i.settings);
      return {
        ...frameLayout(i.sourceSize, i.outputSize, s, i.canvasScale),
        alignmentFractions: alignmentFractions(s),
      };
    });
  });

  it("exportCardTransform", () => {
    checkUnit("exportCardTransform", (i) => {
      const s = settingsOf(i.settings);
      const layout = frameLayout(i.sourceSize, i.outputSize, s);
      const t = cardTransform(layout, i.zoom, i.focalPoint);
      const probes = [
        { x: 0, y: 0 },
        { x: i.sourceSize.width, y: i.sourceSize.height },
        { x: i.sourceSize.width / 2, y: i.sourceSize.height / 3 },
      ].map((p) => applyTransform(t.sourceToOutput, p));
      return { layout, ...t, probes };
    });
  });

  it("exportFrameTimes", () => {
    checkUnit("exportFrameTimes", (i) => {
      const seconds = exportFrameTimes(i.duration, i.fps, i.startOffset);
      return { count: seconds.length, seconds, values: seconds.map((s) => Math.round(s * 600)) };
    });
  });

  it("exportOutputGeometry", () => {
    checkUnit("exportOutputGeometry", (i) => {
      const e = i.exportSettings;
      const out = resolvedOutputSize(e, i.aspectRatio, i.sourceSize);
      return {
        outputSize: out,
        outputWidth: outputWidth(e),
        normalizedQuality: normalizedQuality(e),
        qualityPresetName: qualityPresetName(e),
        estimatedVideoBitRate: estimatedVideoBitRate(e, i.aspectRatio, i.sourceSize),
        aspectSize: aspectSize(i.aspectRatio),
        canvasAspect: canvasAspect(i.aspectRatio, i.sourceSize),
        letterboxRect: letterboxRect(i.bounds, i.letterboxAspect),
        resolutionFitting: resolutionFitting(i.aspectRatio, i.fitWidth),
        canvasScale: canvasScale(out, i.previewCanvasSize),
        menuBarCrop: menuBarCrop(
          { menuBarReplacement: i.menuBarReplacement, menuBarHeight: i.menuBarHeight },
          i.recordingSourceKind,
          i.sourceSegmentKinds,
        ),
      };
    });
  });
});
