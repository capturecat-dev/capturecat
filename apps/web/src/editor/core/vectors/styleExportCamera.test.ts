import { describe, it } from "vitest";
import { checkUnit } from "./harness";
import * as ECB from "../math/exportCameraBubble";
import type { TagMeasure } from "../math/cameraStyleMath";

/** Swift-recorded tag text measurements (see WebVectors+StyleCamera.tagMeasurements). */
interface Measurement {
  text: string;
  fontName: string | null;
  fontSize: number;
  width: number;
  height: number;
}

function measureFrom(list: Measurement[]): TagMeasure {
  return (text, fontName, fontSize) => {
    const m = list.find((e) => e.text === text && (e.fontName ?? null) === fontName && e.fontSize === fontSize);
    if (!m) throw new Error("no Swift measurement for " + JSON.stringify([text, fontName, fontSize]));
    return { width: m.width, height: m.height };
  };
}

// CGPath(roundedRect:) / ellipse arcs use CG's κ — see style.test.ts CG_ARC_TOL.
const CG_ARC_TOL = 3e-8;

function staticsFor(i: any) {
  return ECB.exportCameraStatics(
    i.settings,
    i.outputSize,
    i.previewCanvasSize,
    i.cameraNaturalSize,
    i.hasCameraReader,
    measureFrom(i.measurements),
  );
}

describe("exporter camera-bubble golden vectors", () => {
  it("exportMaskGeometry", () => {
    checkUnit(
      "exportMaskGeometry",
      (i) => ({
        roundedRectangleMask: ECB.roundedRectangleMask(i.extent, i.rect, i.cornerRadius, i.inverted, i.frameShape),
        cameraShapeMask: ECB.cameraShapeMask(i.extent, i.rect, i.cameraShape, i.cameraCornerRadius, i.scale),
        cameraShapeStroke: ECB.cameraShapeStroke(
          i.extent,
          i.rect,
          i.cameraShape,
          i.cameraCornerRadius,
          i.scale,
          i.lineWidth,
          i.strokeColor,
        ),
        cameraShapeShadow: ECB.cameraShapeShadow(
          i.extent,
          i.rect,
          i.cameraShape,
          i.cameraCornerRadius,
          i.scale,
          i.shadowRadius,
        ),
        frameShadow: ECB.frameShadow(i.extent, i.rect, i.cornerRadius, i.shadowRadius, i.shadowOpacity, i.frameShape),
      }),
      { absTol: CG_ARC_TOL },
    );
  });

  it("exportCompositeCamera", () => {
    checkUnit("exportCompositeCamera", (i) => ({
      geometry: ECB.compositeCameraGeometry(i.camExtent, i.rect, i.opacity, i.tiltPitch, i.tiltYaw),
    }));
  });

  it("exportCameraStatics", () => {
    checkUnit("exportCameraStatics", (i) => staticsFor(i), { absTol: CG_ARC_TOL });
  });

  it("exportCameraFrame", () => {
    checkUnit("exportCameraFrame", (i) => {
      const statics = staticsFor(i);
      return {
        frames: i.frames.map((f: ECB.ExportFrameCameraInput) =>
          ECB.exportFrameCamera(statics, i.settings, i.regions, i.videoRect, i.outputSize, i.cameraTimeOffset, f),
        ),
      };
    });
  });

  it("exportCameraReader", () => {
    checkUnit("exportCameraReader", (i) => {
      const reader = new ECB.CameraReaderCursor(
        i.samples.map((s: { value: number; timescale: number }) => ({ value: BigInt(s.value), timescale: s.timescale })),
      );
      return {
        steps: i.times.map((t: number) => {
          const r = reader.advance(t, i.cameraTimeOffset);
          return {
            target: r.target,
            camValue: r.target >= 0 ? Number(ECB.cmTimeValue600(r.target)) : null,
            current: r.current,
            usesLive: r.usesLive,
          };
        }),
      };
    });
  });
});
