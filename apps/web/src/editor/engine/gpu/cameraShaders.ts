/**
 * WGSL for the webcam (camera recording) passes — the web twin of the Mac
 * exporter's camera blocks (`compositeCamera`, `cameraShape*Image`,
 * `makeFrameShadow`, `fadeImage`, `applyPerspectiveTilt`).
 *
 * Every layer renders into the camera GROUP texture (target-sized, output
 * pixels, Y-down, premultiplied, gamma-encoded working space — the Mac's
 * "stack composed over TRANSPARENT first" so the whole bubble fades and tilts
 * as one group), which `cameraComposeWGSL` then resamples through the bubble
 * tilt homography × opacity onto the canvas (plain bubble) or the card layer
 * (camera-layout tile).
 *
 * "Clear outside": CoreImage treats everything beyond an image's extent (and
 * beyond a crop) as transparent; every bilinear fetch here does the same per
 * tap.
 */

const common = /* wgsl */ `
struct VSOut { @builtin(position) pos: vec4f };

@vertex fn vs_fullscreen(@builtin(vertex_index) i: u32) -> VSOut {
  var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var o: VSOut;
  o.pos = vec4f(p[i], 0.0, 1.0);
  return o;
}

fn inRect(q: vec2f, r: vec4f) -> bool {
  return q.x >= r.x && q.y >= r.y && q.x < r.x + r.z && q.y < r.y + r.w;
}

fn applyH(r0: vec4f, r1: vec4f, r2: vec4f, p: vec2f) -> vec3f {
  let v = vec3f(p, 1.0);
  return vec3f(dot(r0.xyz, v), dot(r1.xyz, v), dot(r2.xyz, v));
}

// VideoExporter.fadeImage: CIColorMatrix scaling R, G, B, A by a. CIColorMatrix
// works on UNPREMULTIPLIED colour, so in premultiplied terms RGB × a² and
// A × a — a fade DARKENS as well as fading (measured on parity fixture 13:
// the chrome-faded white stroke reads 188 over tan 198, not 202). Mac export
// quirk, ported on purpose.
fn fadeImage(c: vec4f, a: f32) -> vec4f {
  return vec4f(c.rgb * (a * a), c.a * a);
}

// IQ rounded-box SDF, Y-down pixels; r clamped like CGPath.
fn sdRoundRect(p: vec2f, rect: vec4f, radius: f32) -> f32 {
  let half = rect.zw * 0.5;
  let r = clamp(radius, 0.0, min(half.x, half.y));
  let q = abs(p - (rect.xy + half)) - half + vec2f(r);
  return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}
`;

/**
 * CoreImage `cropped(to:)` is AREA-COVERAGE anti-aliased (measured with the
 * real CIContext: a 0.787 pixel overlap renders 201/255) and nested crops
 * MULTIPLY (generator + crop → 0.62). `boxCov` is that coverage for the pixel
 * footprint `fp` (output pixel back-projected into the cropped image's space).
 */
const croppedBilinear = /* wgsl */ `
fn boxCov(q: vec2f, fp: vec2f, r: vec4f) -> f32 {
  let h = fp * 0.5;
  let x = clamp((min(q.x + h.x, r.x + r.z) - max(q.x - h.x, r.x)) / fp.x, 0.0, 1.0);
  let y = clamp((min(q.y + h.y, r.y + r.w) - max(q.y - h.y, r.y)) / fp.y, 0.0, 1.0);
  return x * y;
}
fn loadClearT(t: texture_2d<f32>, ip: vec2i, dims: vec2i) -> vec4f {
  if (ip.x < 0 || ip.y < 0 || ip.x >= dims.x || ip.y >= dims.y) { return vec4f(0.0); }
  return textureLoad(t, ip, 0);
}
// A bitmap placed at origin (asset px of texel (0,0)'s top-left), cropped to
// crop, sampled bilinearly at asset point q (clear outside the bitmap).
fn bilinearCropped(t: texture_2d<f32>, q: vec2f, origin: vec2f, crop: vec4f, fp: vec2f) -> vec4f {
  let cov = boxCov(q, fp, crop);
  if (cov <= 0.0) { return vec4f(0.0); }
  let dims = vec2i(textureDimensions(t));
  let s = q - origin - vec2f(0.5);
  let i0 = vec2i(floor(s));
  let f = s - floor(s);
  let a = loadClearT(t, i0, dims);
  let b = loadClearT(t, i0 + vec2i(1, 0), dims);
  let c = loadClearT(t, i0 + vec2i(0, 1), dims);
  let d = loadClearT(t, i0 + vec2i(1, 1), dims);
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) * cov;
}
`;

/**
 * A baked camera asset (mask / stroke / bubble shadow / ring / tag, or the
 * cached card shadow) re-targeted by its affine `assetXform` and faded.
 * alphaOnly: the texture's R channel is the alpha of BLACK (shadows).
 */
export const cameraAssetWGSL = /* wgsl */ `
${common}
${croppedBilinear}
struct AssetU {
  inv0: vec4f, inv1: vec4f, inv2: vec4f,  // output px → asset px
  tex: vec4f,    // texel (0,0) top-left in asset px, 0, 0
  crop: vec4f,   // crop rect in asset px (before the transform — CI crop then transform)
  p: vec4f,      // fade, alphaOnly, pixel footprint in asset px (x, y)
};
@group(0) @binding(0) var<uniform> u: AssetU;
@group(0) @binding(1) var tex: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let h = applyH(u.inv0, u.inv1, u.inv2, in.pos.xy);
  let q = h.xy / h.z;
  var c = bilinearCropped(tex, q, u.tex.xy, u.crop, u.p.zw);
  if (u.p.y > 0.5) { c = vec4f(0.0, 0.0, 0.0, c.r); }
  return fadeImage(c, u.p.x);
}
`;

/**
 * makeFrameShadow for a rounded rect (CIRoundedRect-shaped camera tile's card
 * shadow): black at alpha, CIGaussianBlur(σ), moved down by offsetY, cropped
 * to the extent before AND after the move — evaluated ANALYTICALLY (exact
 * erf product over the flat band, Gaussian-weighted quadrature over the two
 * corner bands), written as alpha into an r16float cache.
 */
export const cameraCardShadowWGSL = /* wgsl */ `
${common}
struct ShU {
  rect: vec4f,   // rounded rect, Y-down px
  p: vec4f,      // radius, sigma, alpha, offsetY (Y-down, + = down)
  ext: vec4f,    // extent (crop), Y-down px
};
@group(0) @binding(0) var<uniform> u: ShU;

// Abramowitz–Stegun 7.1.26 (|err| < 1.5e-7).
fn erf1(x: f32) -> f32 {
  let s = sign(x);
  let a = abs(x);
  let t = 1.0 / (1.0 + 0.3275911 * a);
  let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-a * a);
  return s * y;
}
fn phi(x: f32) -> f32 { return 0.5 * (1.0 + erf1(x * 0.70710678118)); }

// Horizontal coverage (Gaussian-blurred along x) of the row span [x0, x1].
fn spanCov(px: f32, x0: f32, x1: f32, sigma: f32) -> f32 {
  if (x1 <= x0) { return 0.0; }
  return phi((x1 - px) / sigma) - phi((x0 - px) / sigma);
}

const N: i32 = 16;

fn blurredRoundRect(p: vec2f) -> f32 {
  let r0 = u.rect;
  let sigma = max(u.p.y, 1e-4);
  let x0 = r0.x; let x1 = r0.x + r0.z;
  let y0 = r0.y; let y1 = r0.y + r0.w;
  let r = clamp(u.p.x, 0.0, min(r0.z, r0.w) * 0.5);
  // Flat band: exact, separable.
  var g = (phi((y1 - r - p.y) / sigma) - phi((y0 + r - p.y) / sigma)) * spanCov(p.x, x0, x1, sigma);
  if (r > 0.0) {
    let inv = 1.0 / (sigma * 2.50662827463);
    let h = r / f32(N);
    for (var i = 0; i < N; i++) {
      // Distance of the sample row from the corner-centre row (0 … r).
      let d = r - (f32(i) + 0.5) * h;
      let hc = sqrt(max(0.0, r * r - d * d));
      let cov = spanCov(p.x, x0 + r - hc, x1 - r + hc, sigma);
      let yt = y0 + r - d;   // top band row
      let yb = y1 - r + d;   // bottom band row
      let wt = exp(-0.5 * (yt - p.y) * (yt - p.y) / (sigma * sigma)) * inv * h;
      let wb = exp(-0.5 * (yb - p.y) * (yb - p.y) / (sigma * sigma)) * inv * h;
      g += (wt + wb) * cov;
    }
  }
  return clamp(g, 0.0, 1.0);
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = in.pos.xy;
  if (!inRect(p, u.ext)) { return vec4f(0.0); }
  let s = p - vec2f(0.0, u.p.w);
  if (!inRect(s, u.ext)) { return vec4f(0.0); }
  return vec4f(u.p.z * blurredRoundRect(s), 0.0, 0.0, 0.0);
}
`;

/**
 * CameraStyleMath.adjustedImage (preset first, then CIColorControls, then
 * CIHueAdjust) on gamma-encoded working-space colour, straight alpha —
 * each stage checked against the REAL CoreImage filters in the exporter's
 * non-linear sRGB working space (scratch oracle over a 33³ colour grid):
 *  - preset (Mono / Noir / Fade = CIPhotoEffect*, Warm / Cool =
 *    CITemperatureAndTint 6500→5100 / 8200 K): a 17³ colour cube sampled from
 *    CoreImage (cameraFilterLuts.ts), hardware-trilinear — mean ≈ 0.3/255,
 *    p99 ≤ 2.5/255;
 *  - CIColorControls: saturation (Rec.709 luma 0.2125/0.7154/0.0721) →
 *    contrast about 0.5 → brightness ADDED LAST — max 0.5/255;
 *  - CIHueAdjust: the SVG hueRotate matrix in gamma space — max 1.4/255.
 */
const adjustments = /* wgsl */ `
fn luma709(c: vec3f) -> f32 { return dot(c, vec3f(0.2125, 0.7154, 0.0721)); }

fn adjust(cIn: vec4f, a0: vec4f, a1: vec4f) -> vec4f {
  if (a1.w > 0.5) { return cIn; }            // identity: image untouched
  let a = cIn.a;
  if (a <= 0.0) { return cIn; }
  var rgb = clamp(cIn.rgb / a, vec3f(0.0), vec3f(1.0));
  if (a1.x > 0.5) {                            // preset colour cube (17³)
    let uvw = (rgb * 16.0 + vec3f(0.5)) / 17.0;
    rgb = textureSampleLevel(lut, samp, uvw, 0.0).rgb;
  }
  if (a1.y > 0.5) {                            // CIColorControls
    let g = luma709(rgb);
    rgb = mix(vec3f(g), rgb, a0.z);            // saturation
    rgb = (rgb - vec3f(0.5)) * a0.y + vec3f(0.5); // contrast
    rgb = rgb + vec3f(a0.x);                   // brightness
  }
  if (a1.z > 0.5) {                            // CIHueAdjust (SVG hueRotate matrix)
    let c = cos(a0.w);
    let s = sin(a0.w);
    let m = mat3x3f(
      vec3f(0.213 + c * 0.787 - s * 0.213, 0.213 - c * 0.213 + s * 0.143, 0.213 - c * 0.213 - s * 0.787),
      vec3f(0.715 - c * 0.715 - s * 0.715, 0.715 + c * 0.285 + s * 0.140, 0.715 - c * 0.715 + s * 0.715),
      vec3f(0.072 - c * 0.072 + s * 0.928, 0.072 - c * 0.072 - s * 0.283, 0.072 + c * 0.928 + s * 0.072));
    rgb = m * rgb;
  }
  rgb = clamp(rgb, vec3f(0.0), vec3f(1.0));
  return vec4f(rgb * a, a);
}
`;

const cameraCommon = /* wgsl */ `
${common}
${croppedBilinear}
struct CamU {
  inv0: vec4f, inv1: vec4f, inv2: vec4f,   // output px → camera source px (Y-down, before the mirror)
  src: vec4f,      // source size.xy, mirrored, 0
  rect: vec4f,     // the bubble / tile rect (crop), Y-down output px
  adj0: vec4f,     // brightness, contrast, saturation, hue (radians)
  adj1: vec4f,     // preset cube on, colour controls on, hue on, identity
  mInv0: vec4f, mInv1: vec4f, mInv2: vec4f, // output px → mask asset px
  mTex: vec4f,     // mask texel (0,0) top-left (asset px)
  mCrop: vec4f,    // mask crop (asset px)
  mode: vec4f,     // mask kind (0 baked shape mask, 1 CIRoundedRectangleGenerator), generator radius, mask footprint (x, y)
};
@group(0) @binding(0) var<uniform> u: CamU;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var maskTex: texture_2d<f32>;
@group(0) @binding(4) var lut: texture_3d<f32>;
${adjustments}

// CoreImage clear-outside weight of a clamped bilinear sample at source point s.
fn edgeFactor(s: vec2f, dims: vec2f) -> f32 {
  let t = s - vec2f(0.5);
  let i0 = floor(t);
  let f = t - i0;
  var wx = 1.0;
  if (i0.x < 0.0) { wx -= (1.0 - f.x); }
  if (i0.x + 1.0 > dims.x - 1.0) { wx -= f.x; }
  var wy = 1.0;
  if (i0.y < 0.0) { wy -= (1.0 - f.y); }
  if (i0.y + 1.0 > dims.y - 1.0) { wy -= f.y; }
  return clamp(wx, 0.0, 1.0) * clamp(wy, 0.0, 1.0);
}

fn maskAt(p: vec2f) -> f32 {
  if (u.mode.x > 0.5) {
    // CIRoundedRectangleGenerator(rect, radius) — AA coverage — .cropped(to: rect).
    return clamp(0.5 - sdRoundRect(p, u.rect, u.mode.y), 0.0, 1.0) * boxCov(p, vec2f(1.0), u.rect);
  }
  let h = applyH(u.mInv0, u.mInv1, u.mInv2, p);
  // CIBlendWithMask reads the mask's grey level (white-on-black coverage).
  return bilinearCropped(maskTex, h.xy / h.z, u.mTex.xy, u.mCrop, u.mode.zw).g;
}

// compositeCamera: scaledCamera.cropped(to: rect) and the CIBlendWithMask
// output .cropped(to: rect) — two area-coverage crops.
fn rectCrops(p: vec2f) -> f32 {
  let c = boxCov(p, vec2f(1.0), u.rect);
  return c * c;
}

fn camPoint(p: vec2f) -> vec2f {
  let h = applyH(u.inv0, u.inv1, u.inv2, p);
  var s = h.xy / h.z;
  if (u.src.z > 0.5) { s.x = u.src.x - s.x; }   // oriented(.upMirrored)
  return s;
}
`;

/** Camera layer from the live decoded frame (texture_external, zero copy). */
export const cameraLiveWGSL = /* wgsl */ `
${cameraCommon}
@group(0) @binding(3) var cam: texture_external;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = in.pos.xy;
  let crops = rectCrops(p);
  if (crops <= 0.0) { return vec4f(0.0); }
  let s = camPoint(p);
  let c = adjust(textureSampleBaseClampToEdge(cam, samp, s / u.src.xy), u.adj0, u.adj1) * edgeFactor(s, u.src.xy);
  return c * maskAt(p) * crops;
}
`;

/** Camera layer from the poster image (camera_poster.png, rgba8 premultiplied). */
export const cameraPosterWGSL = /* wgsl */ `
${cameraCommon}
@group(0) @binding(3) var cam: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = in.pos.xy;
  let crops = rectCrops(p);
  if (crops <= 0.0) { return vec4f(0.0); }
  let s = camPoint(p);
  let c = adjust(textureSampleLevel(cam, samp, s / u.src.xy, 0.0), u.adj0, u.adj1) * edgeFactor(s, u.src.xy);
  return c * maskAt(p) * crops;
}
`;

/**
 * Group → target through the bubble tilt (TiltMath homography about the rect
 * centre; identity when untilted) × opacity (fadeImage). The quad covers the
 * projected group bounds; the fragment resamples bilinearly with clear
 * outside (CIPerspectiveTransform / CIAffineTransform twin).
 */
export const cameraComposeWGSL = /* wgsl */ `
${common}
struct CompU {
  fwd0: vec4f, fwd1: vec4f, fwd2: vec4f,   // group px → target px
  inv0: vec4f, inv1: vec4f, inv2: vec4f,   // target px → group px
  bounds: vec4f,   // group-space bounds
  p: vec4f,        // target size.xy, opacity, 0
};
@group(0) @binding(0) var<uniform> u: CompU;
@group(0) @binding(1) var grp: texture_2d<f32>;

struct QOut { @builtin(position) pos: vec4f };

@vertex fn vs_quad(@builtin(vertex_index) i: u32) -> QOut {
  let b = u.bounds;
  var corners = array<vec2f, 6>(
    b.xy, b.xy + vec2f(b.z, 0.0), b.xy + vec2f(0.0, b.w),
    b.xy + vec2f(0.0, b.w), b.xy + vec2f(b.z, 0.0), b.xy + b.zw);
  let h = applyH(u.fwd0, u.fwd1, u.fwd2, corners[i]);
  let ndc = vec2f(h.x / u.p.x * 2.0 - h.z, h.z - h.y / u.p.y * 2.0);
  var o: QOut;
  o.pos = vec4f(ndc, 0.0, h.z);
  return o;
}

fn loadClear(ip: vec2i, dims: vec2i) -> vec4f {
  if (ip.x < 0 || ip.y < 0 || ip.x >= dims.x || ip.y >= dims.y) { return vec4f(0.0); }
  return textureLoad(grp, ip, 0);
}

@fragment fn fs_main(in: QOut) -> @location(0) vec4f {
  let h = applyH(u.inv0, u.inv1, u.inv2, in.pos.xy);
  if (h.z <= 0.0) { return vec4f(0.0); }
  let q = h.xy / h.z;
  let dims = vec2i(textureDimensions(grp));
  let s = q - vec2f(0.5);
  let i0 = vec2i(floor(s));
  let f = s - floor(s);
  let c = mix(mix(loadClear(i0, dims), loadClear(i0 + vec2i(1, 0), dims), f.x),
              mix(loadClear(i0 + vec2i(0, 1), dims), loadClear(i0 + vec2i(1, 1), dims), f.x), f.y);
  return fadeImage(c, u.p.z);
}
`;
