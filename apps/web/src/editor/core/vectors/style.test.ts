import { describe, expect, it } from "vitest";
import { checkUnit, loadVectors } from "./harness";
import * as RCL from "../math/reactiveCameraLayout";
import * as CLM from "../math/cameraLayoutMath";
import * as OK from "../math/oklabGradient";
import * as BGR from "../math/backgroundGradientRenderer";
import * as BL from "../math/backgroundLook";
import * as WC from "../math/wallpaperCatalog";
import {
  cgPathEllipse,
  cgPathRect,
  cgPathRoundedRect,
  rasterBackgroundEnvelope,
  rasterBackgroundReference,
} from "../math/styleSupport";
import * as CRR from "../math/continuousRoundedRect";
import * as SHADOW from "../math/swiftUIShadow";
import * as CLOCK from "../math/recordingClock";
import * as CSM from "../math/cameraStyleMath";

interface Measurement {
  text: string;
  fontName: string | null;
  fontSize: number;
  width: number;
  height: number;
}

/** Injects the Swift-measured NSAttributedString sizes recorded in the vectors. */
function measureFrom(list: Measurement[]): CSM.TagMeasure {
  return (text, fontName, fontSize) => {
    const m = list.find((e) => e.text === text && (e.fontName ?? null) === fontName && e.fontSize === fontSize);
    if (!m) throw new Error("no Swift measurement for " + JSON.stringify([text, fontName, fontSize]));
    return { width: m.width, height: m.height };
  };
}

describe("style golden vectors", () => {
  it("styleConstants", () => {
    checkUnit("styleConstants", () => ({
      reactiveCameraLayout: {
        minSizeFactor: RCL.minSizeFactor,
        squircleMaxAspect: RCL.squircleMaxAspect,
        verticalAspect: RCL.verticalAspect,
      },
      cameraLayoutMath: {
        transitionDuration: CLM.transitionDuration,
        sideBySideScreenFraction: CLM.sideBySideScreenFraction,
        sideBySideGapFraction: CLM.sideBySideGapFraction,
      },
      cameraStyleMath: {
        squircleExponent: CSM.squircleExponent,
        squircleSamples: CSM.squircleSamples,
        ringOutsideFraction: CSM.ringOutsideFraction,
        ringColor: CSM.ringColor,
        ringPeakAlpha: CSM.ringPeakAlpha,
        ringSigmaFraction: CSM.ringSigmaFraction,
        tagFontFraction: CSM.tagFontFraction,
        tagSubtextFontScale: CSM.tagSubtextFontScale,
        tagHPaddingFactor: CSM.tagHPaddingFactor,
        tagVPaddingFactor: CSM.tagVPaddingFactor,
        tagGapFactor: CSM.tagGapFactor,
      },
      oklabGradient: { resolution: OK.resolution },
      backgroundLook: { maxImageEdge: BL.maxImageEdge },
      continuousRoundedRect: { fullReach: CRR.fullReach },
      swiftUIShadow: { blurFactor: SHADOW.blurFactor },
    }));
  });

  it("reactiveCameraLayoutScalars", () => {
    checkUnit("reactiveCameraLayoutScalars", (i) => ({
      envelope: RCL.envelope(i.zoom),
      shapeAspect: RCL.shapeAspect(i.shape, i.videoAspect, i.orientation),
      bubbleSize: RCL.bubbleSize(i.baseSize, i.aspect),
      canvasFitScale: RCL.canvasFitScale(i.canvas),
      fraction: RCL.fraction(i.position),
    }));
  });

  it("reactiveCameraLayoutCameraRect", () => {
    checkUnit("reactiveCameraLayoutCameraRect", (i) => ({
      rect: RCL.cameraRect(
        i.contentRect,
        i.basePosition,
        i.customPosition,
        i.baseSize,
        i.zoom,
        i.padding,
        i.aspect,
        i.yAxisIsUp,
      ),
    }));
  });

  it("cameraLayoutMathBasics", () => {
    checkUnit("cameraLayoutMathBasics", (i) => ({
      ease: CLM.ease(i.t),
      bubbleApproxCornerRadius: CLM.bubbleApproxCornerRadius(i.shape, i.customRadius, i.size),
      columns: CLM.columns(i.videoRect),
    }));
  });

  it("cameraLayoutResolve", () => {
    checkUnit("cameraLayoutResolve", (i) => ({
      results: i.queries.map((t: number) => {
        const r = CLM.resolve(
          t,
          i.regions,
          i.videoRect,
          i.bubbleRect,
          i.bubbleCornerRadius,
          i.cardCornerRadius,
          i.hasCamera,
        );
        return {
          resolved: r,
          cardTransform: CLM.cardTransform(r, i.videoRect),
          regionID: CLM.region(t, i.regions)?.id ?? null,
          mode: CLM.mode(t, i.regions),
        };
      }),
    }));
  });

  it("cameraLayoutBoundaries", () => {
    checkUnit("cameraLayoutBoundaries", (i) => ({
      boundaries: CLM.boundaries(i.regions, i.duration),
    }));
  });

  it("oklabGradient", () => {
    checkUnit("oklabGradient", (i) => {
      const out: Record<string, unknown> = {
        linearize: OK.linearize(i.c),
        encode: OK.encode(i.c),
        oklab: OK.oklab(i.a),
        srgb: OK.srgb(i.lab),
        mix: OK.mix(i.a, i.b, i.t),
        sample: OK.sample(i.stops, i.sampleT),
      };
      if (i.wantTable) out.table = OK.gradientTable(i.stops);
      return out;
    });
  });

  it("backgroundGradientAxis", () => {
    checkUnit("backgroundGradientAxis", (i) => ({
      points: BGR.drawPoints(i.rect, i.axis),
      imageSize: BGR.imageSize(i.size, i.scale),
      specAxis: BL.gradientAxis({ gradientAngle: i.gradientAngle } as BL.BackgroundSpec),
    }));
  });

  it("backgroundLookSpec", () => {
    checkUnit("backgroundLookSpec", (i) => {
      const spec = BL.specFromSettings(i.settings);
      const px = BL.pixelSizeFor(i.size, i.scale);
      const path = BL.renderPath(spec, i.size, i.scale);
      return {
        spec,
        isPlainLook: BL.isPlainLook(spec),
        isPlainLookExceptNoise: BL.isPlainLookExceptNoise(spec),
        gradientAxis: BL.gradientAxis(spec),
        pixelSize: px,
        blurSigma: BL.blurSigma(spec.blur, px),
        pixelateScale: BL.pixelateScale(spec.pixelate, px),
        halftoneWidth: BL.halftoneWidth(spec.halftone, px),
        renderPath: path,
        styledSteps: px.width > 0 && px.height > 0 ? BL.styledSteps(spec, px) : [],
        // The harness only rendered the real cgImage for canvases ≤ 40k px.
        realIsNil: px.width * px.height <= 40_000 ? path === "nil" : null,
      };
    });
  });

  it("backgroundMeshPools", () => {
    checkUnit("backgroundMeshPools", (i) => ({ pools: BL.meshPools(i.start, i.end, i.pixelSize) }));
  });

  it("backgroundGrain", () => {
    checkUnit("backgroundGrain", (i) => {
      const rows = BL.noiseRows(i.width, i.height, i.cell);
      const amplitude = BL.grainAmplitude(i.amount);
      return {
        rows,
        amplitude,
        deltas: rows.map((r) => r.map((n) => BL.grainDelta(n, amplitude))),
      };
    });
  });

  it("backgroundLookPixels", () => {
    // Centre-sampled CPU reference vs REAL CoreGraphics bitmaps. CG dithers
    // gradients by jittering the sample position inside each pixel, so the
    // centre sample differs by up to 16/255 in the steepest ramps (observed
    // max: gradient 11, mesh 16; solid, image fallback and the grain
    // arithmetic are exact). That loose bound is only the first line: the
    // envelope check below is the strict gate — every real pixel inside the
    // ramp's range over the pixel square (±0.5 px) ±1/255 (mesh ±3/255: seven
    // separately quantised, independently dithered layers), sizes exact.
    checkUnit(
      "backgroundLookPixels",
      (i) => rasterBackgroundReference(BL.specFromSettings(i.settings), i.size, i.scale),
      { absTol: 16 },
    );
    const file = loadVectors("backgroundLookPixels");
    const failures: string[] = [];
    file.cases.forEach((c, n) => {
      const spec = BL.specFromSettings(c.input.settings);
      const ref = rasterBackgroundReference(spec, c.input.size, c.input.scale);
      if (!ref || !c.output) {
        if (!!ref !== !!c.output) failures.push(`case ${n}: nil mismatch`);
        return;
      }
      if (ref.width !== c.output.width || ref.height !== c.output.height) {
        failures.push(`case ${n}: size ${ref.width}x${ref.height} vs ${c.output.width}x${c.output.height}`);
        return;
      }
      const env = rasterBackgroundEnvelope(spec, c.input.size, c.input.scale, 0.5, spec.type === "Mesh" ? 3 : 1)!;
      for (let k = 0; k < c.output.rgba.length; k++) {
        const v = c.output.rgba[k];
        if (v < env.lo[k] || v > env.hi[k]) {
          failures.push(`case ${n} byte ${k}: ${v} outside [${env.lo[k]}, ${env.hi[k]}]`);
          break;
        }
      }
    });
    expect(failures, failures.slice(0, 5).join("\n")).toEqual([]);
  });

  it("backgroundLookStyledPixels", () => {
    // Asserts the CI step data; input.gpuTargets carries the REAL rendered
    // samples for the WebGPU render-parity gate (no CPU CoreImage here).
    checkUnit("backgroundLookStyledPixels", (i) => {
      const spec = BL.specFromSettings(i.settings);
      const px = BL.pixelSizeFor(i.size, i.scale);
      return { pixelSize: px, styledSteps: BL.styledSteps(spec, px) };
    });
  });

  it("backgroundAspectFill", () => {
    checkUnit("backgroundAspectFill", (i) => ({
      rect: BL.aspectFillRect(i.sourceWidth, i.sourceHeight, i.pixelSize),
    }));
  });

  // CG's rounded-rect corners use the Bézier constant 0.5522847498 OR the
  // exact 4(√2−1)/3 per corner (CG-internal arc construction; no pattern in
  // size/position; Δk = 3.08e-11) → up to 1.85e-8 px at the largest vectored
  // corner radius (600 px). Ellipses always use 0.5522847498 (exact match).
  const CG_ARC_TOL = 3e-8;

  it("cgPathPrimitives", () => {
    checkUnit(
      "cgPathPrimitives",
      (i) => ({
        rect: cgPathRect(i.rect),
        ellipse: cgPathEllipse(i.rect),
        roundedRect: cgPathRoundedRect(i.rect, i.cornerWidth, i.cornerHeight),
      }),
      { absTol: CG_ARC_TOL },
    );
  });

  it("continuousRoundedRectPath", () => {
    checkUnit(
      "continuousRoundedRectPath",
      (i) => {
        const p = CRR.path(i.rect, i.cornerRadius);
        return { path: p, circularPath: CRR.circularPath(i.rect, i.cornerRadius), deviceFramePath: p };
      },
      { absTol: CG_ARC_TOL },
    );
  });

  it("swiftUIShadow", () => {
    checkUnit("swiftUIShadow", (i) => SHADOW.shadowParameters(i.ctm, i.radius, i.dy, i.color));
  });

  it("recordingClockSequences", () => {
    checkUnit("recordingClockSequences", (i) => {
      const clock = new CLOCK.RecordingClock(i.origin);
      return {
        states: i.ops.map((op: { op: string; at: number }) => {
          let value: number | null = null;
          switch (op.op) {
            case "restart":
              clock.restart(op.at);
              break;
            case "pause":
              clock.pause(op.at);
              break;
            case "resume":
              clock.resume(op.at);
              break;
            case "timelineTime":
              value = clock.timelineTime(op.at);
              break;
            default:
              throw new Error(`unknown op ${op.op}`);
          }
          return {
            value,
            originHostTimeSeconds: clock.originHostTimeSeconds,
            isPaused: clock.isPaused,
            accumulatedPauseSeconds: clock.accumulatedPauseSeconds,
          };
        }),
      };
    });
  });

  it("recordingClockEventTimestamp", () => {
    checkUnit("recordingClockEventTimestamp", (i) => {
      const tb = { numer: i.timebaseNumer, denom: i.timebaseDenom };
      const raw = BigInt(i.raw);
      const cm = CLOCK.machUnitsCMTime(raw, tb);
      return {
        hostTimeSeconds: CLOCK.hostTimeSeconds(raw, i.now, tb),
        machUnitsCMTime: { value: cm.value.toString(), timescale: cm.timescale },
        machUnitsSeconds: CLOCK.machUnitsSeconds(raw, tb),
        eventTimestamp: CLOCK.eventTimestamp(i.hostTime, tb).toString(),
      };
    });
  });

  it("cameraStyleAdjustments", () => {
    checkUnit("cameraStyleAdjustments", (i) => {
      const a = CSM.adjustmentsFromSettings(i.settings);
      return { adjustments: a, isIdentity: CSM.isIdentity(a), steps: CSM.adjustedImageSteps(a) };
    });
  });

  it("cameraStyleShapes", () => {
    checkUnit(
      "cameraStyleShapes",
      (i) => ({
        cornerRadius: CSM.cornerRadius(i.shape, i.customRadius, i.scale),
        clipPath: CSM.clipPath(i.shape, i.customRadius, i.rect, i.scale),
        superellipse: i.withSuperellipse ? CSM.superellipsePath(i.rect) : null,
      }),
      { absTol: CG_ARC_TOL },
    );
  });

  it("cameraStyleBorderColor", () => {
    checkUnit("cameraStyleBorderColor", (i) => ({ srgb: CSM.borderColor(i) }));
  });

  it("cameraStyleRing", () => {
    checkUnit(
      "cameraStyleRing",
      (i) => ({
        ringPadding: CSM.ringPadding(i.size),
        recipe: CSM.ringRecipe(i.size, i.shape, i.customRadius, i.intensity, i.scale),
      }),
      { absTol: CG_ARC_TOL },
    );
  });

  it("cameraStyleTagRect", () => {
    checkUnit("cameraStyleTagRect", (i) => ({
      rect: CSM.tagRect(i.bubbleRect, i.pillSize, i.position, i.yAxisIsUp),
    }));
  });

  it("cameraStyleTagLayout", () => {
    checkUnit("cameraStyleTagLayout", (i) => ({
      layout: CSM.tagLayout(i.settings, i.bubbleWidth, measureFrom(i.measurements)),
    }));
  });

  it("cameraStyleTagBitmap", () => {
    checkUnit(
      "cameraStyleTagBitmap",
      (i) => ({ recipe: CSM.tagBitmapRecipe(i.settings, i.bubbleWidth, i.scale, measureFrom(i.measurements)) }),
      { absTol: CG_ARC_TOL },
    );
  });

  it("cameraStyleTagTextMetrics", () => {
    checkUnit("cameraStyleTagTextMetrics", (i) => ({
      ceilWidth: Math.ceil(i.width),
      ceilHeight: Math.ceil(i.height),
      systemLineHeight: i.isSystemFont ? CSM.systemTagLineHeight(i.fontSize) : null,
    }));
  });

  it("cameraStyleTagLineHeights", () => {
    checkUnit("cameraStyleTagLineHeights", (i) =>
      i.table
        ? { table: CSM.systemTagLineHeightTable.map(([size, height]) => ({ size, height })) }
        : { height: CSM.systemTagLineHeight(i.fontSize) },
    );
  });

  it("wallpaperCatalogNames", () => {
    checkUnit("wallpaperCatalogNames", (i) => ({
      baseNames: i.sortedNames.map(WC.baseName),
      listed: WC.listedNames(i.sortedNames),
      cacheFileNames: i.sortedNames.map(WC.cacheFileName),
    }));
  });
});
