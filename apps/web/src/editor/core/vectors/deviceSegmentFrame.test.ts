import { describe, expect, it } from "vitest";
import { checkUnit, firstMismatch, loadVectors } from "./harness";
import * as Dip from "../math/deviceSegmentDip";
import { applyTransform, concatTransform, flipRectY, type AffineTransform } from "../math/geometry";
import type { ProjectSourceSegment, Rect } from "../model/types";

// The Y-DOWN renderer's view of stitched device segments (web preview AND web
// export, via the FrameGraph) — locked to the SAME golden vectors as the
// exporter-space port: `deviceSegmentExport` (verbatim oracle of
// VideoExporter.export's device-segment rules). Every case is re-run through
// `segmentFramingYDown` / `deviceSegmentFrame` in a flipped canvas and mapped
// back into CI Y-UP space, where it must equal Swift within the parity
// tolerance.

/** CI Y-UP ↔ Y-DOWN in a canvas `H` tall, as a CG affine. */
const flip = (H: number): AffineTransform => ({ a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H });

/** A Y-DOWN transform expressed in CI Y-UP space: F ∘ T ∘ F. */
function toYUp(t: AffineTransform, H: number): AffineTransform {
  return concatTransform(concatTransform(flip(H), t), flip(H));
}

/** A canvas height the golden video rect sits in (any height works — the flip is an involution). */
const canvasHeight = (vr: Rect) => Math.ceil(vr.y + vr.height) + 211;

describe("device segments — Y-down renderer view", () => {
  it("deviceSegmentExport through segmentFramingYDown + deviceSegmentFrame", () => {
    checkUnit("deviceSegmentExport", (i) => {
      const H = canvasHeight(i.videoRect);
      const videoRectYDown = flipRectY(i.videoRect, H);
      const framing = Dip.segmentFramingYDown(i.recordingSourceKind, i.showDeviceFrame, i.sourceSegments, videoRectYDown, H);
      const frameActive = Dip.deviceFrameActive(i.recordingSourceKind, i.showDeviceFrame);
      if (framing) {
        // The Y-DOWN rects are the exporter's, flipped once (to the parity tolerance).
        expect(firstMismatch(flipRectY(framing.screenRect, H), framing.assets.subRect)).toBeNull();
        expect(firstMismatch(flipRectY(framing.bezelRect, H), framing.assets.bezelShadowRect)).toBeNull();
        expect(framing.isPhone).toBe(framing.assets.hasIsland);
      }
      return {
        deviceFrameActive: frameActive,
        assets: framing?.assets ?? null,
        hotSpans: Dip.deviceDipHotSpans(framing?.assets ?? null),
        perQuery: i.queries.map((t: number) => {
          const f = Dip.deviceSegmentFrame(framing, t, videoRectYDown);
          return {
            active: f.active,
            segmentFlag: framing !== null && f.active,
            menuBarVisible: !f.active,
            dipPhase: f.dipPhase,
            dip: f.dip ? { scale: f.dip.scale, transform: toYUp(f.dip.transform, H), alpha: f.dip.alpha } : null,
            curtainDeviceScreen: Dip.curtainDeviceScreen(framing?.assets ?? null, f.active, frameActive, i.videoRect),
          };
        }),
      };
    });
  });

  it("the dip scales about the Y-down video-rect centre (fixed point) and shrinks the card", () => {
    const file = loadVectors("deviceSegmentExport");
    let checked = 0;
    for (const c of file.cases) {
      const i = c.input;
      const H = canvasHeight(i.videoRect);
      const vr = flipRectY(i.videoRect, H);
      const framing = Dip.segmentFramingYDown(i.recordingSourceKind, i.showDeviceFrame, i.sourceSegments, vr, H);
      if (!framing) continue;
      for (const t of i.queries as number[]) {
        const f = Dip.deviceSegmentFrame(framing, t, vr);
        if (!f.dip) {
          expect(f.dipPhase).toBeLessThanOrEqual(0.01);
          continue;
        }
        const centre = { x: vr.x + vr.width / 2, y: vr.y + vr.height / 2 };
        const p = applyTransform(f.dip.transform, centre);
        expect(p.x).toBeCloseTo(centre.x, 9);
        expect(p.y).toBeCloseTo(centre.y, 9);
        const corner = applyTransform(f.dip.transform, { x: vr.x, y: vr.y });
        expect(corner.x - centre.x).toBeCloseTo((vr.x - centre.x) * f.dip.scale, 9);
        expect(f.dip.scale).toBeLessThan(1);
        expect(f.dip.alpha).toBeLessThan(1);
        checked++;
      }
    }
    expect(checked).toBeGreaterThan(0);
  });

  // Parity fixture 14's cut layout (display → iPhone → display, cuts at 1.6 s
  // and 3.4 s): the frames the gate taps land where this says they do.
  it("fixture-14 cuts: active span ±0.01 s, dip centred ON each cut", () => {
    const seg = (startTime: number, duration: number, kind: ProjectSourceSegment["kind"]): ProjectSourceSegment => ({
      startTime, duration, kind, contentX: 0.37, contentY: 0, contentWidth: 0.26, contentHeight: 1,
    });
    const vr = { x: 56, y: 56, width: 1168, height: 608 };
    const framing = Dip.segmentFramingYDown("display", true, [seg(0, 1.6, "display"), seg(1.6, 1.8, "device"), seg(3.4, 1.6, "display")], vr, 720);
    expect(framing).not.toBeNull();
    const at = (t: number) => Dip.deviceSegmentFrame(framing, t, vr);
    expect(at(1.5667).active).toBe(false);
    expect(at(1.59).active).toBe(true);
    expect(at(1.6).dipPhase).toBe(1);
    expect(at(1.6).dip!.scale).toBeCloseTo(1 - Dip.scaleDrop, 12);
    expect(at(1.6).dip!.alpha).toBeCloseTo(1 - Dip.opacityDrop, 12);
    expect(at(3.4).active).toBe(true);
    expect(at(3.4 + 1 / 30).active).toBe(false);
    expect(at(3.4 + 1 / 30).dip).not.toBeNull();
    expect(at(2.5).dip).toBeNull();
    // Symmetric about the cut (Gaussian): same phase either side.
    expect(at(1.6 - 0.1).dipPhase).toBeCloseTo(at(1.6 + 0.1).dipPhase, 12);
    // A framed DEVICE take never uses segment framing; showDeviceFrame off neither.
    expect(Dip.segmentFramingYDown("device", true, [seg(0, 1, "device")], vr, 720)).toBeNull();
    expect(Dip.segmentFramingYDown("display", false, [seg(0, 1, "device")], vr, 720)).toBeNull();
    expect(Dip.deviceSegmentFrame(null, 1.6, vr)).toEqual({ active: false, dipPhase: 0, dip: null });
  });
});
