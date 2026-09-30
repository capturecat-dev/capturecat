/**
 * Pointer ↔ card-space mapping for the stage's editing surface — the web twin
 * of `PreviewInteractionView.contentPoint(_:_:)` / `inverseCameraPoint`.
 *
 * The Mac inverts its card camera in two steps (zoom about the anchor +
 * cardOffset, then the TiltMath homography). The web engine folds the whole
 * card camera (zoom, offset, intro slide, tilt) into ONE card → canvas
 * homography (`FrameInfo.camera`, row-major, Y-down backing px), so the
 * inverse is a single `invert(camera)` — exact for any homography, including
 * the perspective terms the Mac's two-step inverse handles separately.
 *
 * Spaces (all Y-DOWN):
 *   client  — DOM pointer coordinates (CSS px, page).
 *   canvas  — the engine canvas' backing store (device px) = `FrameInfo.target`.
 *   card    — pre-camera canvas px; `FrameInfo.videoRect` lives here. The
 *             Mac's "content space" is card space minus contentRect.origin,
 *             in points (card px / canvasScale).
 *
 * Pure: no DOM, no engine imports beyond the Mat3 helpers.
 */
import { apply, invert, type Mat3 } from "../../engine/mat3";
import type { PathElements } from "../../core/math/overlaySupport";

export interface Pt {
  x: number;
  y: number;
}

export interface Box {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** A CanvasRenderingContext2D.setTransform(a, b, c, d, e, f) tuple. */
export type Affine = [number, number, number, number, number, number];

/** Client (CSS px) → canvas backing px, through the host's on-screen rect. */
export function canvasFromClient(clientX: number, clientY: number, host: { left: number; top: number; width: number; height: number }, target: { width: number; height: number }): Pt {
  const sx = host.width > 0 ? target.width / host.width : 1;
  const sy = host.height > 0 ? target.height / host.height : 1;
  return { x: (clientX - host.left) * sx, y: (clientY - host.top) * sy };
}

/** Canvas backing px → client CSS px (inverse of canvasFromClient). */
export function clientFromCanvas(p: Pt, host: { left: number; top: number; width: number; height: number }, target: { width: number; height: number }): Pt {
  const sx = target.width > 0 ? host.width / target.width : 1;
  const sy = target.height > 0 ? host.height / target.height : 1;
  return { x: host.left + p.x * sx, y: host.top + p.y * sy };
}

/** Card → canvas (the camera, forward). */
export function cardToCanvas(camera: Mat3, p: Pt): Pt {
  const [x, y] = apply(camera, p.x, p.y);
  return { x, y };
}

/** Canvas → card through a PRE-INVERTED camera (hot path: pointer moves). */
export function canvasToCard(inverse: Mat3, p: Pt): Pt {
  const [x, y] = apply(inverse, p.x, p.y);
  return { x, y };
}

/** Convenience: the camera's inverse (identity when singular, like mat3.invert). */
export function inverseCamera(camera: Mat3): Mat3 {
  return invert(camera);
}

/** Whether the homography has no perspective terms (maps paths exactly). */
export function isAffine(m: Mat3, eps = 1e-12): boolean {
  const w = m[8];
  if (Math.abs(w) < eps) return false;
  return Math.abs(m[6] / w) < eps && Math.abs(m[7] / w) < eps;
}

/**
 * The homography's first-order (local affine) approximation at card point
 * `p`: maps q ≈ H(p) + J(p)·(q − p). Exact everywhere when H is affine. Used
 * to draw small chrome (handles, pills, reticle) crisply in card units: the
 * Mac draws those INSIDE the warped card layer, so they ride the zoom
 * (and, approximately, the tilt) exactly like this.
 */
export function localAffine(H: Mat3, p: Pt): Affine {
  const u = H[0] * p.x + H[1] * p.y + H[2];
  const v = H[3] * p.x + H[4] * p.y + H[5];
  const w = H[6] * p.x + H[7] * p.y + H[8];
  const w2 = w * w;
  const X = u / w;
  const Y = v / w;
  const j00 = (H[0] * w - u * H[6]) / w2;
  const j01 = (H[1] * w - u * H[7]) / w2;
  const j10 = (H[3] * w - v * H[6]) / w2;
  const j11 = (H[4] * w - v * H[7]) / w2;
  return [j00, j10, j01, j11, X - j00 * p.x - j01 * p.y, Y - j10 * p.x - j11 * p.y];
}

/** Linear scale of the homography at card point `p` (√|det J|; the zoom). */
export function localScale(H: Mat3, p: Pt): number {
  const [a, b, c, d] = localAffine(H, p);
  const s = Math.sqrt(Math.abs(a * d - b * c));
  return Number.isFinite(s) && s > 0 ? s : 1;
}

/** Row-major Mat3 of an Affine tuple (for composing). */
export function affineToMat3(t: Affine): Mat3 {
  return [t[0], t[2], t[4], t[1], t[3], t[5], 0, 0, 1];
}

/** Pre-multiplies a uniform scale onto a homography (card → overlay px). */
export function scaled(m: Mat3, sx: number, sy: number): Mat3 {
  return [m[0] * sx, m[1] * sx, m[2] * sx, m[3] * sy, m[4] * sy, m[5] * sy, m[6], m[7], m[8]];
}

/**
 * Maps a card-space path into canvas px. Affine cameras map every control
 * point (Béziers are affine-invariant, so this is exact). Projective cameras
 * first flatten each curve into `segments` chords in card space, then map
 * the vertices — lines stay lines under a homography, so the polyline is
 * exact at its vertices.
 */
export function projectPath(els: PathElements, H: Mat3, segments = 12): PathElements {
  const affine = isAffine(H);
  const map = (x: number, y: number): [number, number] => apply(H, x, y);
  const out: PathElements = [];
  let cx = 0;
  let cy = 0;
  let sx = 0;
  let sy = 0;
  for (const el of els) {
    switch (el[0]) {
      case "M": {
        cx = sx = el[1];
        cy = sy = el[2];
        const [x, y] = map(cx, cy);
        out.push(["M", x, y]);
        break;
      }
      case "L": {
        cx = el[1];
        cy = el[2];
        const [x, y] = map(cx, cy);
        out.push(["L", x, y]);
        break;
      }
      case "Q": {
        if (affine) {
          const [x1, y1] = map(el[1], el[2]);
          const [x, y] = map(el[3], el[4]);
          out.push(["Q", x1, y1, x, y]);
        } else {
          for (let i = 1; i <= segments; i++) {
            const t = i / segments;
            const mt = 1 - t;
            const px = mt * mt * cx + 2 * mt * t * el[1] + t * t * el[3];
            const py = mt * mt * cy + 2 * mt * t * el[2] + t * t * el[4];
            const [x, y] = map(px, py);
            out.push(["L", x, y]);
          }
        }
        cx = el[3];
        cy = el[4];
        break;
      }
      case "C": {
        if (affine) {
          const [x1, y1] = map(el[1], el[2]);
          const [x2, y2] = map(el[3], el[4]);
          const [x, y] = map(el[5], el[6]);
          out.push(["C", x1, y1, x2, y2, x, y]);
        } else {
          for (let i = 1; i <= segments; i++) {
            const t = i / segments;
            const mt = 1 - t;
            const a = mt * mt * mt;
            const b = 3 * mt * mt * t;
            const c = 3 * mt * t * t;
            const d = t * t * t;
            const px = a * cx + b * el[1] + c * el[3] + d * el[5];
            const py = a * cy + b * el[2] + c * el[4] + d * el[6];
            const [x, y] = map(px, py);
            out.push(["L", x, y]);
          }
        }
        cx = el[5];
        cy = el[6];
        break;
      }
      case "Z":
        out.push(["Z"]);
        cx = sx;
        cy = sy;
        break;
    }
  }
  return out;
}

/** The four corners of a card rect, projected (TL, TR, BR, BL). */
export function projectRect(r: Box, H: Mat3): Pt[] {
  return [
    cardToCanvas(H, { x: r.x, y: r.y }),
    cardToCanvas(H, { x: r.x + r.width, y: r.y }),
    cardToCanvas(H, { x: r.x + r.width, y: r.y + r.height }),
    cardToCanvas(H, { x: r.x, y: r.y + r.height }),
  ];
}

/** Axis-aligned bounds of projected points. */
export function boundsOf(points: readonly Pt[]): Box {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const p of points) {
    minX = Math.min(minX, p.x);
    minY = Math.min(minY, p.y);
    maxX = Math.max(maxX, p.x);
    maxY = Math.max(maxY, p.y);
  }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}
