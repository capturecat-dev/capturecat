import { describe, expect, it } from "vitest";
import { checkUnit, firstMismatch, loadVectors } from "./harness";
import * as DFL from "../math/deviceFrameLayout";
import * as Bezel from "../math/deviceBezel";
import * as Focus from "../math/focusMath";
import * as BlurStyle from "../math/blurStyleMath";
import * as Dip from "../math/deviceSegmentDip";
import * as Geo from "../math/regionGeometry";
import * as Exp from "../math/exportRegions";
import * as MenuBar from "../math/menuBarRenderer";
import { continuousFullReach, flipRectY } from "../math/regionsSupport";
import type { MenuBarReplacement } from "../model/enums";

// Golden vectors for the REGIONS cluster — produced by
// apps/macos/CaptureCat/Services/WebVectors/WebVectors+Regions.swift and
// WebVectors+RegionsOracle.swift (verbatim oracles of exporter-private code).

describe("regions golden vectors", () => {
  // ── DeviceFrameLayout ─────────────────────────────────────────────────────
  it("deviceFrameLayoutConstants", () => {
    checkUnit("deviceFrameLayoutConstants", () => ({
      bandTop: DFL.bandTop,
      bandMid: DFL.bandMid,
      bandBottom: DFL.bandBottom,
      sideTop: DFL.sideTop,
      sideBottom: DFL.sideBottom,
      glassColor: DFL.glassColor,
      rimHighlight: DFL.rimHighlight,
      rimMid: DFL.rimMid,
      rimShadowSide: DFL.rimShadowSide,
      innerShadow: DFL.innerShadow,
      buttonTop: DFL.buttonTop,
      buttonBottom: DFL.buttonBottom,
      buttonRim: DFL.buttonRim,
      sideButtons: DFL.sideButtons,
      borderFraction: DFL.borderFraction,
      glassMarginFraction: DFL.glassMarginFraction,
      screenCornerFraction: DFL.screenCornerFraction,
      islandWidthFraction: DFL.islandWidthFraction,
      islandHeightFraction: DFL.islandHeightFraction,
      islandTopFraction: DFL.islandTopFraction,
      cameraDotFraction: DFL.cameraDotFraction,
      cameraDotOffsetFraction: DFL.cameraDotOffsetFraction,
      padCornerFraction: DFL.padCornerFraction,
      continuousFullReach,
      shadowBlurFactor: Bezel.shadowBlurFactor,
    }));
  });

  it("deviceFrameLayoutRGB", () => {
    checkUnit("deviceFrameLayoutRGB", (i) => ({
      fromHex: DFL.rgbFromHex(i.hex, i.alpha),
      mix: DFL.rgbMix(i.x, i.y, i.t),
      mixDefault: DFL.rgbMix(i.x, i.y),
    }));
  });

  it("deviceFrameLayoutScalars", () => {
    checkUnit("deviceFrameLayoutScalars", (i) => ({
      rimWidth: DFL.rimWidth(i.width),
      seamWidth: DFL.seamWidth(i.width),
      bezelWidth: DFL.bezelWidth(i.width),
      islandSize: DFL.islandSize(i.width),
      islandTopInset: DFL.islandTopInset(i.width),
      isPhoneAspect: DFL.isPhoneAspect(i.size),
      screenCornerRadius: DFL.screenCornerRadius(i.size),
      bezelCornerRadius: DFL.bezelCornerRadius(i.size),
    }));
  });

  it("deviceFrameLayoutMetrics", () => {
    checkUnit("deviceFrameLayoutMetrics", (i) => {
      const m = DFL.metrics(i.videoRect);
      return { bezelRect: DFL.bezelRect(i.videoRect), metrics: m, value: DFL.metricsValue(m, i.fraction) };
    });
  });

  it("continuousRoundedPath", () => {
    checkUnit("continuousRoundedPath", (i) => ({
      elements: DFL.continuousRoundedPath(i.rect, i.cornerRadius),
    }));
  });

  // ── Region geometry ───────────────────────────────────────────────────────
  it("regionConstants", () => {
    checkUnit("regionConstants", () => ({
      blurRegion: {
        previewCornerRadius: Geo.blurRegionPreviewCornerRadius,
        blurFeatherFraction: Geo.blurFeatherFraction,
        blurFeatherMinimum: Geo.blurFeatherMinimum,
        blurFeatherMaxFraction: Geo.blurFeatherMaxFraction,
      },
      highlightRegion: {
        previewCornerRadius: Geo.highlightPreviewCornerRadius,
        cornerRadiusRatio: Geo.highlightCornerRadiusRatio,
      },
      focusMath: {
        defaultCornerRadius: Focus.defaultCornerRadius,
        minBandFraction: Focus.minBandFraction,
        maxBandFraction: Focus.maxBandFraction,
        maxBlurRadiusFraction: Focus.maxBlurRadiusFraction,
        maskResolution: Focus.maskResolution,
      },
      blurStyleMath: {
        animationStep: BlurStyle.animationStep,
        minBlockFraction: BlurStyle.minBlockFraction,
        maxBlockFraction: BlurStyle.maxBlockFraction,
        minBlockPoints: BlurStyle.minBlockPoints,
      },
      deviceSegmentDip: { sigma: Dip.sigma, scaleDrop: Dip.scaleDrop, opacityDrop: Dip.opacityDrop },
    }));
  });

  it("blurRegionGeometry", () => {
    checkUnit("blurRegionGeometry", (i) => ({
      rectInViewSpace: Geo.blurRegionRectInViewSpace(i.region, i.containerRect),
      rectInImageSpace: Geo.blurRegionRectInImageSpace(i.region, i.containerRect),
      blurRadius: Geo.blurRegionBlurRadius(i.region, i.containerSize),
      featherRadius: Geo.blurRegionFeatherRadius(i.region, i.containerSize),
      featherSigma: Geo.blurRegionFeatherSigma(i.region, i.containerSize),
      duration: Geo.blurRegionDuration(i.region),
    }));
  });

  it("highlightRegionGeometry", () => {
    checkUnit("highlightRegionGeometry", (i) => ({
      rectInViewSpace: Geo.highlightRegionRectInViewSpace(i.region, i.containerRect),
      rectInImageSpace: Geo.highlightRegionRectInImageSpace(i.region, i.containerRect),
      cornerRadius: Geo.highlightRegionCornerRadius(i.region, i.containerRect),
      cornerRadiusFor: Geo.highlightCornerRadiusFor(i.otherRect, i.containerRect),
      dimOpacity: Geo.highlightRegionDimOpacity(i.region),
      duration: Geo.highlightRegionDuration(i.region),
    }));
  });

  it("focusRegionGeometry", () => {
    checkUnit("focusRegionGeometry", (i) => ({
      rectInViewSpace: Geo.focusRegionRectInViewSpace(i.region, i.containerRect),
      duration: Geo.focusRegionDuration(i.region),
    }));
  });

  // ── FocusMath ─────────────────────────────────────────────────────────────
  it("focusMathScalars", () => {
    checkUnit("focusMathScalars", (i) => ({
      bandWidth: Focus.bandWidth(i.falloff, i.videoSize),
      blurRadius: Focus.blurRadius(i.intensity, i.videoSize),
      blurSigma: Focus.blurSigma(i.intensity, i.videoSize),
      blurAmount: i.points.map((p: { x: number; y: number }) =>
        Focus.blurAmount(p, i.regionRect, i.style, i.angle, i.falloff, i.cornerRadius, i.videoSize),
      ),
      blurAmountDefaultCorner: i.points.map((p: { x: number; y: number }) =>
        Focus.blurAmount(p, i.regionRect, i.style, i.angle, i.falloff, undefined, i.videoSize),
      ),
      roundedRectOutsideDistance: Focus.roundedRectOutsideDistance(i.distPoint, i.distRect, i.distCorner),
    }));
  });

  it("focusMathMask", { timeout: 120_000 }, () => {
    // Bytes / sums / hashes are integers (exact under any tolerance < 0.5).
    // `rendered` is the Swift CGImage pushed through a CIContext (linear sRGB
    // working + output space, RGBAf bitmap): Float32(byte / 255). The only
    // difference from byte/255 is Float32 quantization — observed max
    // 2.97e-8 over every sample — so this unit uses absTol 1e-7 (the Swift
    // harness self-checks every pixel of every raster to 1e-6).
    checkUnit(
      "focusMathMask",
      (i) => {
        const mask = Focus.maskImage({
          regionRect: i.regionRect,
          style: i.style,
          angleDegrees: i.angle,
          falloff: i.falloff,
          cornerRadius: i.cornerRadius,
          videoSize: i.videoSize,
        });
        if (!mask) return { mask: null };
        let sum = 0;
        let fnv = 0x811c9dc5;
        for (const b of mask.pixels) {
          sum += b;
          fnv = Math.imul(fnv ^ b, 0x01000193) >>> 0;
        }
        const samples = i.samples as { i: number; j: number }[];
        const bytes = samples.map((s) => mask.pixels[s.j * mask.width + s.i]);
        // Spot-check the per-pixel entry point against the raster.
        const params = {
          regionRect: i.regionRect,
          style: i.style,
          angleDegrees: i.angle,
          falloff: i.falloff,
          cornerRadius: i.cornerRadius,
          videoSize: i.videoSize,
        };
        const direct = samples.map((s) => Focus.maskValue(s.i, s.j, mask.width, mask.height, params));
        expect(direct).toEqual(bytes);
        return {
          mask: {
            width: mask.width,
            height: mask.height,
            bytes,
            rendered: bytes.map((b) => b / 255),
            byteSum: sum,
            fnv1a32: fnv,
          },
        };
      },
      { absTol: 1e-7 },
    );
  });

  // ── BlurStyleMath ─────────────────────────────────────────────────────────
  it("blurStyleMath", () => {
    checkUnit("blurStyleMath", (i) => ({
      pixelScale: BlurStyle.pixelScale(i.strength, i.regionSize),
      quantizedStep: BlurStyle.quantizedStep(i.time),
      gridJitter: BlurStyle.gridJitter(i.time, i.animated, i.blockSize),
      hash01: BlurStyle.hash01(BigInt(i.step), BigInt(i.salt)),
    }));
  });

  // ── DeviceSegmentDip ──────────────────────────────────────────────────────
  it("deviceSegmentDip", () => {
    checkUnit("deviceSegmentDip", (i) => {
      const phases = i.queries.map((q: number) => Dip.phase(q, i.boundaries));
      return {
        phase: phases,
        scale: phases.map(Dip.scale),
        opacity: phases.map(Dip.opacity),
        extraScale: i.extraPhases.map(Dip.scale),
        extraOpacity: i.extraPhases.map(Dip.opacity),
      };
    });
  });

  it("regionEnvelope", () => {
    checkUnit("regionEnvelope", (i) => ({
      envelope: i.queries.map((q: number) => Exp.regionEnvelope(q, i.startTime, i.endTime, i.transitionDuration)),
      smootherStep: i.smoothInputs.map(Exp.smootherStep),
    }));
  });

  // ── Exporter oracles ──────────────────────────────────────────────────────
  it("exportActiveRegions", () => {
    checkUnit("exportActiveRegions", (i) => ({
      active: i.times.map((t: number) => ({
        blur: Exp.activeRegionIndices(i.blurRegions, t),
        focus: Exp.activeRegionIndices(i.focusRegions, t),
        highlight: Exp.activeRegionIndices(i.highlightRegions, t),
      })),
    }));
  });

  it("exportRegionBlur", () => {
    checkUnit("exportRegionBlur", (i) => Exp.exportRegionBlurPlan(i.region, i.containerRect, i.time));
  });

  it("exportRegionHighlight", () => {
    checkUnit("exportRegionHighlight", (i) =>
      Exp.exportRegionHighlightPlan(i.region, i.imageExtent, i.containerRect, i.containerRect, i.time, i.transitionDuration),
    );
  });

  it("exportFocusPlan", () => {
    checkUnit("exportFocusPlan", (i) => Exp.exportFocusPlan(i.region, i.videoRect));
  });

  it("deviceSegmentExport", () => {
    checkUnit("deviceSegmentExport", (i) => {
      const frameActive = Dip.deviceFrameActive(i.recordingSourceKind, i.showDeviceFrame);
      const assets = Dip.segmentDeviceAssets(i.recordingSourceKind, i.showDeviceFrame, i.sourceSegments, i.videoRect);
      return {
        deviceFrameActive: frameActive,
        assets,
        hotSpans: Dip.deviceDipHotSpans(assets),
        perQuery: i.queries.map((t: number) => {
          const active = Dip.deviceSegmentActive(assets, t);
          const dipPhase = Dip.deviceBoundaryDip(assets, t);
          return {
            active,
            segmentFlag: assets !== null && active,
            menuBarVisible: !active,
            dipPhase,
            dip: Dip.deviceDipTransform(dipPhase, i.videoRect),
            curtainDeviceScreen: Dip.curtainDeviceScreen(assets, active, frameActive, i.videoRect),
          };
        }),
      };
    });
  });

  it("deviceBezelRecipe", () => {
    checkUnit("deviceBezelRecipe", (i) => {
      const videoRect = flipRectY(i.videoRectCI, i.extent.height);
      return {
        videoRect,
        sideButtons: Bezel.sideButtonsRecipe(videoRect),
        sideSlab: Bezel.sideSlabRecipe(videoRect, i.slabOffset),
        body: Bezel.bodyRecipe(videoRect, i.shadowRadius, i.shadowOpacity, i.deviceScale),
        island: Bezel.islandRecipe(videoRect),
      };
    });
  });

  // ── Menu bar ──────────────────────────────────────────────────────────────
  it("menuBarLayout", () => {
    checkUnit("menuBarLayout", (i) => {
      const spec = i.spec as MenuBar.MenuBarSpec;
      const renders = MenuBar.menuBarRenders(spec);
      if (!renders) return { renders, layout: null };
      const layout = MenuBar.menuBarLayout(spec, i.measured);
      const dark = (spec.style as MenuBarReplacement) === "Clean Dark";
      const text = MenuBar.textColorSRGB(spec.style);
      return {
        renders,
        layout: layout && {
          ...layout,
          barColor: {
            calibrated: dark ? MenuBar.barColorCalibrated.dark : MenuBar.barColorCalibrated.light,
            srgb: dark ? MenuBar.barColorSRGB.dark : MenuBar.barColorSRGB.light,
          },
          textColor: { calibrated: text, srgb: text },
        },
      };
    });
  });

  it("menuBarTextMetrics", () => {
    // Reference table of REAL AppKit measurements (calibration data for the
    // browser's text measurement). The port reproduces the font REQUESTS; the
    // measured boxes must be self-consistent with the layout unit's inputs.
    const file = loadVectors("menuBarTextMetrics");
    const failures: string[] = [];
    for (const c of file.cases) {
      const f = MenuBar.menuBarFonts(c.input.height);
      const actual = {
        clockFont: { pointSize: f.clock.size },
        titleFont: { pointSize: f.title.size },
        logoFont: { pointSize: f.logo.size },
        symbolPointSize: f.symbolPointSize,
      };
      const expected = {
        clockFont: { pointSize: c.output.clockFont.pointSize },
        titleFont: { pointSize: c.output.titleFont.pointSize },
        logoFont: { pointSize: c.output.logoFont.pointSize },
        symbolPointSize: c.output.symbolPointSize,
      };
      const m = firstMismatch(actual, expected);
      if (m) failures.push(`height ${c.input.height}: ${m}`);
      for (const font of [c.output.clockFont, c.output.titleFont, c.output.logoFont]) {
        if (font.familyName !== ".AppleSystemUIFont") failures.push(`height ${c.input.height}: font ${font.familyName}`);
      }
    }
    expect(failures, failures.join("\n")).toEqual([]);
    expect(file.cases.length).toBeGreaterThan(0);
  });

  it("menuBarExportPlacement", () => {
    checkUnit("menuBarExportPlacement", (i) => {
      const crop = MenuBar.menuBarCrop(i.settings, i.recordingSourceKind, i.sourceSegmentKinds);
      const placement = MenuBar.exportMenuBarPlacement(i.settings, i.recordingSourceKind, i.videoRect);
      let bar = null;
      if (placement && i.raster) {
        const scale = MenuBar.exportMenuBarRasterScale(i.videoRect, placement.barH, i.raster);
        bar = {
          barH: placement.barH,
          specWidth: placement.spec.width,
          specHeight: placement.spec.height,
          raster: i.raster,
          scale,
          rect: {
            x: placement.origin.x,
            y: placement.origin.y,
            width: i.raster.width * scale.width,
            height: i.raster.height * scale.height,
          },
        };
      }
      return {
        menuBarCrop: crop,
        effectiveNaturalSize: MenuBar.effectiveNaturalSize(i.naturalSize, crop),
        bar,
      };
    });
  });
});
