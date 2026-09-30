/**
 * Cursor-cluster golden vectors (apps/macos/CaptureCat/Services/WebVectors/
 * WebVectors+Cursor.swift + WebVectors+CursorOracle.swift). One `it` per unit;
 * a missing vector file FAILS (checkUnit throws) — it never skips.
 */
import { describe, it } from "vitest";
import { checkUnit } from "./harness";
import { chypot } from "../math/cursorSupport";
import { apply as applySpring } from "../math/cursorSpringMath";
import { apply as applyEndBehavior } from "../math/cursorEndBehaviorMath";
import {
  menuBarCrop,
  menuBarCroppedSize,
  processCursorEvents,
  recordingCoordinateSize,
  shiftForMenuBarCrop,
} from "../math/cursorChain";
import { affineTransform, isIdentity, pose, yFlipped } from "../math/cursorPhysicsMath";
import {
  center,
  imageSpaceRect,
  make as makeLayout,
  resolveCoordinateSize,
  viewRect,
} from "../math/cursorOverlayLayout";
import { progress as tapProgress } from "../math/tapRippleMath";
import {
  activeRipples,
  clickDragThreshold,
  discreteClicks,
  discreteClickTimes,
  dragHighlightRuns,
  dragHighlightStrength,
  renderForExport,
} from "../math/clickRippleOverlay";
import { artwork, asset as styleAsset, rasterPixelSize } from "../math/cursorStyleProvider";
import {
  cursorCGFallback,
  cursorSpriteComposite,
  exportCanvasScale,
  exportCursorFrame,
  exportCursorSetup,
  makeCursorAsset,
  renderClickRipple,
  shouldHideCursor,
} from "../math/exportCursor";
import { interpolateIfFresh } from "../math/cursorSmoother";
import { effectiveTrimEnd } from "../time/clips";

describe("cursor golden vectors", () => {
  it("cursorHypot", () => {
    // absTol 0: the drag-vs-click threshold is a `<=` on hypot, so the port
    // must be bit-exact with Darwin libm, not merely close.
    checkUnit(
      "cursorHypot",
      (i) => ({ hypot: i.x.map((x: number, k: number) => chypot(x, i.y[k])) }),
      { absTol: 0 },
    );
  });

  it("cursorSpringSimulate", () => {
    checkUnit("cursorSpringSimulate", (i) => ({ result: applySpring(i.events, i.settings) }));
  });

  it("cursorEndBehavior", () => {
    checkUnit("cursorEndBehavior", (i) => ({
      result: applyEndBehavior(i.events, i.trimEnd, i.loopToStart, i.stopAtEnd),
    }));
  });

  it("cursorChain", () => {
    checkUnit("cursorChain", (i) => {
      const trimEnd = effectiveTrimEnd(i.project);
      return { effectiveTrimEnd: trimEnd, result: processCursorEvents(i.events, i.settings, trimEnd) };
    });
  });

  it("cursorMenuBarCrop", () => {
    checkUnit("cursorMenuBarCrop", (i) => {
      const cursorCoordinateSize = recordingCoordinateSize(i.recording);
      const full = resolveCoordinateSize(cursorCoordinateSize, i.naturalSize);
      const crop = menuBarCrop(i.settings, i.project);
      return {
        cursorCoordinateSize,
        fullCursorCoordinateSize: full,
        menuBarCrop: crop,
        effectiveNaturalSize: menuBarCroppedSize(i.naturalSize, crop),
        resolvedCursorCoordinateSize: menuBarCroppedSize(full, crop),
        shiftedEvents: shiftForMenuBarCrop(i.events, full, crop),
      };
    });
  });

  it("cursorPhysicsPose", () => {
    checkUnit("cursorPhysicsPose", (i) => ({
      queries: i.queries.map((q: any) => {
        const p = pose(
          i.events,
          q.t,
          i.coordinateSize,
          i.videoRect,
          i.spriteHeight,
          i.tilt,
          i.stretch,
          i.drag,
          i.weight,
        );
        const f = yFlipped(p);
        return {
          pose: p,
          isIdentity: isIdentity(p),
          flipped: f,
          transform: affineTransform(p, q.tip, i.spriteHeight),
          flippedTransform: affineTransform(f, q.tipUp, i.spriteHeight),
        };
      }),
    }));
  });

  it("cursorPhysicsTransform", () => {
    checkUnit("cursorPhysicsTransform", (i) => ({
      isIdentity: isIdentity(i.pose),
      yFlipped: yFlipped(i.pose),
      transform: affineTransform(i.pose, i.tip, i.spriteHeight),
    }));
  });

  it("cursorOverlayLayout", () => {
    checkUnit("cursorOverlayLayout", (i) => {
      const layout = makeLayout(
        i.cursorPosition,
        i.coordinateSize,
        i.videoRect,
        i.cursorSize,
        i.hotSpot,
        i.cursorScale,
      );
      return {
        layout,
        center: layout ? center(layout) : null,
        imageSpaceRect: layout ? imageSpaceRect(layout, i.canvasHeight) : null,
        resolveCoordinateSize: resolveCoordinateSize(i.recordedSize, i.fallbackSourceSize),
        viewRect: viewRect(i.anyRect, i.canvasHeight),
      };
    });
  });

  it("tapRippleProgress", () => {
    checkUnit("tapRippleProgress", (i) => ({ progress: tapProgress(i.elapsed) }));
  });

  it("clickRippleDiscrete", () => {
    checkUnit("clickRippleDiscrete", (i) => ({
      clickDragThreshold: clickDragThreshold(i.coordinateSize),
      discreteClickTimes: discreteClickTimes(i.events, i.coordinateSize),
      discreteClicks: discreteClicks(i.events, i.coordinateSize),
      dragHighlightRuns: dragHighlightRuns(i.events, i.coordinateSize),
    }));
  });

  it("clickRippleActive", () => {
    checkUnit("clickRippleActive", (i) => {
      const runs = dragHighlightRuns(i.events, i.coordinateSize);
      return {
        queries: i.times.map((t: number) => ({
          activeRipples: activeRipples(i.events, t, i.coordinateSize, i.videoRect, i.rippleDuration ?? undefined),
          dragHighlightStrength: dragHighlightStrength(runs, t),
        })),
      };
    });
  });

  it("clickRippleExportDraw", () => {
    checkUnit("clickRippleExportDraw", (i) => ({
      queries: i.times.map((t: number) =>
        renderForExport(i.events, t, i.videoRect, i.sourceSize, i.rippleSize),
      ),
    }));
  });

  it("cursorStyleAssets", () => {
    checkUnit("cursorStyleAssets", (i) => {
      const a = styleAsset(i.style);
      return {
        imageSize: a.imageSize,
        hotSpot: a.hotSpot,
        artwork: artwork(i.style),
        rasterPixelSizes: i.pixelSizes.map(rasterPixelSize),
      };
    });
  });

  it("exportCursorShouldHide", () => {
    checkUnit("exportCursorShouldHide", (i) => ({
      hidden: i.times.map((t: number) => shouldHideCursor(t, i.events, i.settings)),
    }));
  });

  it("exportCursorSetup", () => {
    checkUnit("exportCursorSetup", (i) => {
      const setup = exportCursorSetup(i.cursorCoordinateSize, i.naturalSize, i.outputSize, i.settings, i.project);
      const a = makeCursorAsset(i.settings.cursorStyle, setup.cursorRasterScale);
      return {
        canvasScale: exportCanvasScale(i.outputSize, i.previewCanvasSize),
        ...setup,
        cursorAsset: a,
      };
    });
  });

  it("exportCursorComposite", () => {
    checkUnit("exportCursorComposite", (i) => ({
      frames: i.times.map((t: number) => {
        const frame = exportCursorFrame(t, i.events, i.settings, i.hasSourceFrame);
        const composite =
          frame.cursorPosition === null
            ? null
            : cursorSpriteComposite(
                t,
                frame.cursorPosition,
                i.events,
                { baseSize: i.baseSize, hotSpot: i.hotSpot, rasterPixelSize: i.rasterPixelSize },
                i.cursorCoordinateSize,
                i.layoutVideoRect,
                i.outputSize,
                i.settings,
                i.canvasScale,
              );
        return {
          frame,
          hidden: shouldHideCursor(t, i.events, i.settings),
          composite,
          ripple: renderClickRipple(t, i.events, i.cursorCoordinateSize, i.layoutVideoRect, i.settings),
        };
      }),
    }));
  });

  it("exportCursorCGFallback", () => {
    checkUnit("exportCursorCGFallback", (i) => ({
      frames: i.times.map((t: number) => {
        const pos = i.events.length > 0 ? interpolateIfFresh(i.events, t) : null;
        if (pos === null) return { cursorPosition: null, fallback: null };
        return {
          cursorPosition: pos,
          fallback: cursorCGFallback(
            t,
            pos,
            i.events,
            { baseSize: i.baseSize, hotSpot: i.hotSpot, hasRaster: i.hasRaster },
            i.cursorCoordinateSize,
            i.layoutVideoRect,
            i.outputSize,
            i.settings,
            i.canvasScale,
          ),
        };
      }),
    }));
  });
});
