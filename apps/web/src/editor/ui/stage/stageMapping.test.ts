/**
 * Pointer ↔ card mapping through arbitrary card cameras (zoom about a focal
 * point + card offset + TiltMath perspective + roll), and its equivalence to
 * the Mac's two-step inverse (`PreviewInteractionView.inverseCameraPoint`
 * then the TiltMath homography inverse in content space).
 */
import { describe, expect, it } from "vitest";

import { Homography, projectionTransform } from "../../core/math/tiltMath";
import { apply, invert, multiply, scaleAbout, translate, type Mat3 } from "../../engine/mat3";
import type { PathElements } from "../../core/math/overlaySupport";
import {
  affineToMat3,
  canvasFromClient,
  canvasToCard,
  cardToCanvas,
  clientFromCanvas,
  isAffine,
  localAffine,
  localScale,
  projectPath,
  scaled,
} from "./stageMapping";

const rnd = (() => {
  let s = 0x2545f491;
  return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 2 ** 32);
})();
const range = (lo: number, hi: number) => lo + (hi - lo) * rnd();

/** TiltMath row-vector Homography → row-major column-vector Mat3. */
function toMat3(h: ReturnType<typeof projectionTransform>): Mat3 {
  return [h.m11, h.m21, h.m31, h.m12, h.m22, h.m32, h.m13, h.m23, h.m33];
}

/** The Mac card camera `T(anchor + cardOffset·canvas) · S(zoom) · T(−anchor)`
 * over a content-space tilt about `tiltCenter` (content = card − origin). */
function macCamera(o: { zoom: number; anchor: { x: number; y: number }; offset: { x: number; y: number }; canvas: { width: number; height: number }; origin: { x: number; y: number }; tilt: [number, number, number]; tiltCenter: { x: number; y: number }; distance: number }): Mat3 {
  const zoom = multiply(translate(o.anchor.x + o.offset.x * o.canvas.width, o.anchor.y + o.offset.y * o.canvas.height), multiply(scaleAbout(o.zoom, 0, 0), translate(-o.anchor.x, -o.anchor.y)));
  const tilt = toMat3(projectionTransform(o.tilt[0], o.tilt[1], o.tilt[2], o.tiltCenter, o.distance));
  const tiltInCard = multiply(translate(o.origin.x, o.origin.y), multiply(tilt, translate(-o.origin.x, -o.origin.y)));
  return multiply(zoom, tiltInCard);
}

/** The Mac's `contentPoint(_:_:)`, literally (returns CARD space = content + origin). */
function macContentPoint(p: { x: number; y: number }, o: Parameters<typeof macCamera>[0]): { x: number; y: number } {
  const z = Math.max(0.01, o.zoom);
  const unzoomed = {
    x: o.anchor.x + (p.x - o.offset.x * o.canvas.width - o.anchor.x) / z,
    y: o.anchor.y + (p.y - o.offset.y * o.canvas.height - o.anchor.y) / z,
  };
  const warped = { x: unzoomed.x - o.origin.x, y: unzoomed.y - o.origin.y };
  const h = projectionTransform(o.tilt[0], o.tilt[1], o.tilt[2], o.tiltCenter, o.distance);
  const inv = Homography.inverted(h);
  const content = Math.max(Math.abs(o.tilt[0]), Math.abs(o.tilt[1]), Math.abs(o.tilt[2])) > 0.01 && inv ? Homography.applied(inv, warped) : warped;
  return { x: content.x + o.origin.x, y: content.y + o.origin.y };
}

function randomCamera() {
  const canvas = { width: range(800, 3840), height: range(450, 2160) };
  const origin = { x: range(0, 120), y: range(0, 120) };
  const content = { width: canvas.width - 2 * origin.x, height: canvas.height - 2 * origin.y };
  return {
    zoom: range(0.4, 3.5),
    anchor: { x: range(0, canvas.width), y: range(0, canvas.height) },
    offset: { x: range(-0.3, 0.3), y: range(-0.3, 0.3) },
    canvas,
    origin,
    tilt: [range(-25, 25), range(-25, 25), range(-12, 12)] as [number, number, number],
    tiltCenter: { x: content.width / 2, y: content.height / 2 },
    distance: Math.max(content.width, content.height) * range(1.2, 3),
  };
}

describe("stage pointer ↔ card mapping", () => {
  it("round-trips card → canvas → card through 500 random homographies", () => {
    let worst = 0;
    for (let n = 0; n < 500; n++) {
      const o = randomCamera();
      const H = macCamera(o);
      const inv = invert(H);
      for (let k = 0; k < 20; k++) {
        // Points on/around the card (where the chrome lives).
        const p = { x: range(o.origin.x, o.canvas.width - o.origin.x), y: range(o.origin.y, o.canvas.height - o.origin.y) };
        const back = canvasToCard(inv, cardToCanvas(H, p));
        worst = Math.max(worst, Math.hypot(back.x - p.x, back.y - p.y));
      }
    }
    expect(worst).toBeLessThan(1e-6);
  });

  it("equals the Mac's two-step inverse (zoom inverse + cardOffset, then tilt inverse)", () => {
    let worst = 0;
    for (let n = 0; n < 300; n++) {
      const o = randomCamera();
      const inv = invert(macCamera(o));
      for (let k = 0; k < 10; k++) {
        const pointer = { x: range(0, o.canvas.width), y: range(0, o.canvas.height) };
        const mac = macContentPoint(pointer, o);
        const web = canvasToCard(inv, pointer);
        // Skip points past the perspective horizon (neither maps them).
        if (!Number.isFinite(mac.x) || Math.hypot(mac.x, mac.y) > 1e6) continue;
        worst = Math.max(worst, Math.hypot(web.x - mac.x, web.y - mac.y) / Math.max(1, Math.hypot(mac.x, mac.y)));
      }
    }
    expect(worst).toBeLessThan(1e-9);
  });

  it("matches the Mac inverseCameraPoint for pure zoom + card offset exactly", () => {
    const o = { ...randomCamera(), tilt: [0, 0, 0] as [number, number, number], zoom: 1.6, offset: { x: -0.18, y: 0.15 } };
    const inv = invert(macCamera(o));
    const pointer = { x: 700, y: 400 };
    const mac = macContentPoint(pointer, o);
    const web = canvasToCard(inv, pointer);
    expect(web.x).toBeCloseTo(mac.x, 9);
    expect(web.y).toBeCloseTo(mac.y, 9);
  });

  it("maps client px ↔ canvas backing px through the host rect", () => {
    const host = { left: 37.5, top: 112.25, width: 960.5, height: 540.25 };
    const target = { width: 1921, height: 1081 };
    for (let k = 0; k < 50; k++) {
      const c = { x: range(host.left, host.left + host.width), y: range(host.top, host.top + host.height) };
      const p = canvasFromClient(c.x, c.y, host, target);
      const back = clientFromCanvas(p, host, target);
      expect(back.x).toBeCloseTo(c.x, 9);
      expect(back.y).toBeCloseTo(c.y, 9);
    }
    const corner = canvasFromClient(host.left + host.width, host.top + host.height, host, target);
    expect(corner.x).toBeCloseTo(target.width, 9);
    expect(corner.y).toBeCloseTo(target.height, 9);
  });

  it("local affine is exact for affine cameras and first-order for projective ones", () => {
    const A = multiply(translate(40, -12), scaleAbout(2.25, 500, 300));
    expect(isAffine(A)).toBe(true);
    const t = localAffine(A, { x: 123, y: 456 });
    const back = affineToMat3(t);
    for (let i = 0; i < 9; i++) expect(back[i]).toBeCloseTo(A[i], 12);
    expect(localScale(A, { x: 0, y: 0 })).toBeCloseTo(2.25, 12);

    const o = randomCamera();
    const H = macCamera({ ...o, tilt: [18, -14, 6] });
    expect(isAffine(H)).toBe(false);
    const p = { x: o.canvas.width / 2 + 13, y: o.canvas.height / 2 - 7 };
    const L = affineToMat3(localAffine(H, p));
    const eps = 1e-3;
    for (const d of [
      { x: eps, y: 0 },
      { x: 0, y: eps },
      { x: -eps, y: eps },
    ]) {
      const [hx, hy] = apply(H, p.x + d.x, p.y + d.y);
      const [lx, ly] = apply(L, p.x + d.x, p.y + d.y);
      expect(Math.hypot(hx - lx, hy - ly)).toBeLessThan(1e-4);
    }
    const [hx, hy] = apply(H, p.x, p.y);
    const [lx, ly] = apply(L, p.x, p.y);
    expect(hx).toBeCloseTo(lx, 8);
    expect(hy).toBeCloseTo(ly, 8);
  });

  it("projects paths exactly (affine) and vertex-exactly (projective)", () => {
    const path: PathElements = [["M", 10, 10], ["L", 110, 10], ["C", 130, 10, 140, 20, 140, 40], ["Q", 140, 80, 100, 80], ["Z"]];
    const A = scaled(multiply(translate(5, 6), scaleAbout(1.5, 70, 40)), 2, 2);
    const pa = projectPath(path, A);
    expect(pa.map((e) => e[0]).join("")).toBe("MLCQZ");
    const [x, y] = apply(A, 140, 40);
    const c = pa[2] as ["C", number, number, number, number, number, number];
    expect(c[5]).toBeCloseTo(x, 12);
    expect(c[6]).toBeCloseTo(y, 12);

    const o = randomCamera();
    const H = macCamera({ ...o, tilt: [20, 10, 0] });
    const pp = projectPath(path, H, 8);
    // M, L, 8 chords for C, 8 for Q, Z.
    expect(pp.length).toBe(1 + 1 + 8 + 8 + 1);
    const last = pp[9] as ["L", number, number];
    const [ex, ey] = apply(H, 140, 40);
    expect(last[1]).toBeCloseTo(ex, 9);
    expect(last[2]).toBeCloseTo(ey, 9);
  });
});
