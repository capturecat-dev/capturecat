/**
 * WGSL for the REGION + SUBTITLE passes (regionEffects.ts, highlight.ts,
 * subtitles.ts). Same conventions as shaders.ts: Y-down pixels, pixel centres
 * at +0.5, premultiplied colour gamma-encoded in the WORKING space (the Mac
 * export CIContext composites in the source's gamma space, so every CI blur /
 * blend below happens on encoded values — no linearisation).
 */
import { bilinearClear, cardCommon, common } from "./shaders";

/**
 * The exporter's video LAYER (compositeFrame): the fitted video cropped to
 * videoRect ∩ contentRect × window mask — the card shader WITHOUT the outer
 * frame clip — rendered into a texture covering the layer extent E. The
 * uniform is a CardU whose `inv` maps texture pixels to card pixels
 * (translate E.origin) and whose outer kind is 0.
 */
const layerFs = /* wgsl */ `
@fragment fn fs_layer(in: VSOut) -> @location(0) vec4f {
  let q = toCard(in.pos.xy);
  if (!inRect(q, u.video) || !inRect(q, u.content)) { return vec4f(0.0); }
  return sampleVideo(q) * cardCoverage(q);
}
`;

export const layerFittedWGSL = /* wgsl */ `
${cardCommon}
@group(0) @binding(3) var fitted: texture_2d<f32>;
fn sampleVideo(q: vec2f) -> vec4f {
  let local = q - u.video.xy;
  let dims = u.vid.xy;
  return textureSampleLevel(fitted, samp, local / dims, 0.0) * edgeFactor(local, dims);
}
${layerFs}
`;

export const layerDirectWGSL = /* wgsl */ `
${cardCommon}
@group(0) @binding(3) var frame: texture_external;
fn sampleVideo(q: vec2f) -> vec4f {
  let local = (q - u.video.xy) / u.vid.z;
  let dims = u.vid.xy;
  return textureSampleBaseClampToEdge(frame, samp, local / dims) * edgeFactor(local, dims);
}
${layerFs}
`;

/**
 * Card pass variant: the (region-processed) video layer → target through
 * `cardToTarget`, × the outer frame clip only (the window mask is already in
 * the layer), cropped to contentRect — the exporter's outer-clip
 * CIBlendWithMask. `u.bounds` is the layer extent E (its texture origin).
 */
export const cardFromLayerWGSL = /* wgsl */ `
${cardCommon}
${bilinearClear}
@group(0) @binding(3) var layer: texture_2d<f32>;
@fragment fn fs_main(in: CardOut) -> @location(0) vec4f {
  let q = toCard(in.pos.xy);
  if (!inRect(q, u.content)) { discard; }
  return bilinearClear(layer, q - u.bounds.xy) * cardCoverage(q);
}
`;

/** Clamp-to-edge padding by (M.x, M.y) px — CI `clampedToExtent()` at full res. */
export const padWGSL = /* wgsl */ `
${common}
struct PU { m: vec4f };
@group(0) @binding(0) var<uniform> u: PU;
@group(0) @binding(1) var src: texture_2d<f32>;
@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let last = vec2i(textureDimensions(src)) - vec2i(1);
  let p = vec2i(floor(in.pos.xy)) - vec2i(u.m.xy);
  return textureLoad(src, clamp(p, vec2i(0), last), 0);
}
`;

/** 2×2 box downsample with clamp (the mip chain for large-σ blurs). */
export const mipWGSL = /* wgsl */ `
${common}
@group(0) @binding(0) var src: texture_2d<f32>;
@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let last = vec2i(textureDimensions(src)) - vec2i(1);
  let p = vec2i(floor(in.pos.xy)) * 2;
  let a = textureLoad(src, min(p, last), 0);
  let b = textureLoad(src, min(p + vec2i(1, 0), last), 0);
  let c = textureLoad(src, min(p + vec2i(0, 1), last), 0);
  let d = textureLoad(src, min(p + vec2i(1, 1), last), 0);
  return (a + b + c + d) * 0.25;
}
`;

/**
 * One separable Gaussian pass (CIGaussianBlur twin: σ = inputRadius, ideal
 * kernel truncated at 3σ and renormalised), CLAMP-TO-EDGE addressing — CI's
 * `clampedToExtent()` — using the linear-sampling trick (two taps per
 * bilinear fetch; exact under clamp-to-edge since each texel index clamps).
 * Output pixel (i, j) centres at source texel position (i, j) + 0.5 + o.
 */
export const gaussianWGSL = /* wgsl */ `
${common}
struct GU {
  p: vec4f,   // dir.x, dir.y, sigma (source texels), taps each side
  o: vec4f,   // output → source texel offset (x, y), 0, 0
};
@group(0) @binding(0) var<uniform> u: GU;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var samp: sampler;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let dims = vec2f(textureDimensions(src));
  let c = in.pos.xy + u.o.xy;
  let dir = u.p.xy;
  let sigma = u.p.z;
  let r = i32(u.p.w);
  let k = -0.5 / (sigma * sigma);
  var acc = textureSampleLevel(src, samp, c / dims, 0.0);
  var wsum = 1.0;
  var i = 1;
  loop {
    if (i > r) { break; }
    let w1 = exp(f32(i * i) * k);
    var w2 = 0.0;
    if (i + 1 <= r) { w2 = exp(f32((i + 1) * (i + 1)) * k); }
    let w = w1 + w2;
    let off = dir * (f32(i) + w2 / w);
    acc += w * (textureSampleLevel(src, samp, (c + off) / dims, 0.0) + textureSampleLevel(src, samp, (c - off) / dims, 0.0));
    wsum += 2.0 * w;
    i += 2;
  }
  return acc / wsum;
}
`;

/**
 * applyRegionBlur's CIBlendWithMask: out = blurred·m + layer·(1 − m), with
 * the separable (hard or feathered) mask m = mx[x]·my[y]. Blurred is the
 * Gaussian level texture (style Blur) or CIPixellate evaluated in place:
 * the layer sampled bilinearly (clamped) at the centre of the pixel's block,
 * grid boundaries at g + n·block (CI anchors the grid at inputCenter).
 * Rendered over the whole extent E (a pass-through outside the support).
 */
export const blurRegionWGSL = /* wgsl */ `
${common}
struct BU {
  s: vec4f,     // support in layer px: x0, y0, x1, y1
  m: vec4f,     // style (0 gaussian, 1 pixelate), block, gx, gy (layer px)
  l: vec4f,     // gaussian level: origin (level texels) x, y; d (level factor); pad offset (layer px)
};
@group(0) @binding(0) var<uniform> u: BU;
@group(0) @binding(1) var cur: texture_2d<f32>;
@group(0) @binding(2) var blurred: texture_2d<f32>;
@group(0) @binding(3) var samp: sampler;
@group(0) @binding(4) var<storage, read> mx: array<f32>;
@group(0) @binding(5) var<storage, read> my: array<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let ip = vec2i(floor(in.pos.xy));
  let base = textureLoad(cur, ip, 0);
  let p = in.pos.xy;
  if (p.x < u.s.x || p.y < u.s.y || p.x > u.s.z || p.y > u.s.w) { return base; }
  let m = mx[ip.x] * my[ip.y];
  if (m <= 0.0) { return base; }
  var b: vec4f;
  if (u.m.x < 0.5) {
    let lc = (p + u.l.w) / u.l.z - u.l.xy;
    b = textureSampleLevel(blurred, samp, lc / vec2f(textureDimensions(blurred)), 0.0);
  } else {
    let s = u.m.y;
    let bx = u.m.z + (floor((p.x - u.m.z) / s) + 0.5) * s;
    // Y-down twin of CI's Y-up floor: ceil(t) − ½.
    let by = u.m.w + (ceil((p.y - u.m.w) / s) - 0.5) * s;
    b = textureSampleLevel(cur, samp, vec2f(bx, by) / vec2f(textureDimensions(cur)), 0.0);
  }
  return b * m + base * (1.0 - m);
}
`;

/**
 * Depth Focus — CIMaskedVariableBlur over the FocusMath mask, reproducing
 * CI's pyramid (measured, see regionEffects.ts): per-pixel radius
 * r = inputRadius × mask, levels at r = 0.75 (sharp), 1.5·2^k, and
 * lerp(L_k, L_k+1, log2(r / r_k)) between them. Implemented as a sum:
 * every level contributes w_i(p)·L_i(p) (additive blend), w = hats in
 * log2(r) with knots at the level radii (a partition of unity).
 *
 * Mask: the linearGray raster stretched over the video rect (bilinear,
 * clear outside its extent), colour-matched by CI into the gamma working
 * space before the filter reads it — hence `encode1`.
 */
export const focusAccumWGSL = /* wgsl */ `
${common}
${bilinearClear}
struct AU {
  vr: vec4f,    // video rect in layer px: x, y, w, h (mask placement)
  p: vec4f,     // inputRadius (EXPORT px), knots log2 r: lo, mid, hi (≤ −1e5 → open)
  l: vec4f,     // level origin (level texels) x, y; d; 1 = the unblurred layer
  o: vec4f,     // pad offset (layer px), 0, 0, 0
};
@group(0) @binding(0) var<uniform> u: AU;
@group(0) @binding(1) var mask: texture_2d<f32>;
@group(0) @binding(2) var level: texture_2d<f32>;
@group(0) @binding(3) var samp: sampler;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = in.pos.xy;
  let md = vec2f(textureDimensions(mask));
  let m = bilinearClear(mask, (p - u.vr.xy) * md / u.vr.zw).r;
  let r = u.p.x * encode1(m);
  let x = log2(max(r, 1e-6));
  var w = 0.0;
  if (x <= u.p.z) {
    if (u.p.y < -1e5) { w = 1.0; } else if (x > u.p.y) { w = (x - u.p.y) / (u.p.z - u.p.y); }
  } else {
    if (u.p.w < -1e5) { w = 1.0; } else if (x < u.p.w) { w = (u.p.w - x) / (u.p.w - u.p.z); }
  }
  if (w <= 0.0) { discard; }
  var c: vec4f;
  if (u.l.w > 0.5) {
    c = textureLoad(level, vec2i(floor(p)), 0);
  } else {
    let lc = (p + u.o.x) / u.l.z - u.l.xy;
    c = textureSampleLevel(level, samp, lc / vec2f(textureDimensions(level)), 0.0);
  }
  return c * w;
}
`;

/** Plain texel copy (layer ping-pong seed / cache). */
export const copyWGSL = /* wgsl */ `
${common}
@group(0) @binding(0) var src: texture_2d<f32>;
@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  return textureLoad(src, vec2i(floor(in.pos.xy)), 0);
}
`;

/** A quad in card space drawn through the card → target homography. */
const cardQuad = /* wgsl */ `
struct QU {
  fwd0: vec4f, fwd1: vec4f, fwd2: vec4f,
  inv0: vec4f, inv1: vec4f, inv2: vec4f,
  tgt: vec4f,      // target size.xy, card px per target px, 0
  bounds: vec4f,   // quad in card px: x, y, w, h
};
struct QOut { @builtin(position) pos: vec4f };
@vertex fn vs_quad(@builtin(vertex_index) i: u32) -> QOut {
  let b = q.bounds;
  var corners = array<vec2f, 6>(
    b.xy, b.xy + vec2f(b.z, 0.0), b.xy + vec2f(0.0, b.w),
    b.xy + vec2f(0.0, b.w), b.xy + vec2f(b.z, 0.0), b.xy + b.zw);
  let c = corners[i];
  let h = vec3f(dot(q.fwd0.xyz, vec3f(c, 1.0)), dot(q.fwd1.xyz, vec3f(c, 1.0)), dot(q.fwd2.xyz, vec3f(c, 1.0)));
  var o: QOut;
  o.pos = vec4f(h.x / q.tgt.x * 2.0 - h.z, h.z - h.y / q.tgt.y * 2.0, 0.0, h.z);
  return o;
}
fn toCardQ(p: vec2f) -> vec2f {
  let h = vec3f(dot(q.inv0.xyz, vec3f(p, 1.0)), dot(q.inv1.xyz, vec3f(p, 1.0)), dot(q.inv2.xyz, vec3f(p, 1.0)));
  return h.xy / h.z;
}
`;

/**
 * applyRegionHighlight: the CG mask raster (white dimRect, then a black
 * CGPath(roundedRect:) hole, 8-bit) → CIBlendWithMask of black·alpha →
 * source-over. In the gamma working space that is the premultiplied black
 * (0, 0, 0, alpha·m) composited OVER the frame.
 */
export const highlightWGSL = /* wgsl */ `
${common}
${cardQuad}
struct HU {
  dim: vec4f,    // dimRect card px: x, y, w, h
  hole: vec4f,   // holeRect card px
  p: vec4f,      // corner radius, overlay alpha, 0, 0
};
@group(0) @binding(0) var<uniform> q: QU;
@group(0) @binding(1) var<uniform> hl: HU;

fn boxCov(c: f32, lo: f32, hi: f32, hw: f32) -> f32 {
  return clamp(min(c + hw, hi) - max(c - hw, lo), 0.0, 2.0 * hw) / (2.0 * hw);
}

@fragment fn fs_main(in: QOut) -> @location(0) vec4f {
  let c = toCardQ(in.pos.xy);
  let px = q.tgt.z;
  let hw = 0.5 * px;
  let white = boxCov(c.x, hl.dim.x, hl.dim.x + hl.dim.z, hw) * boxCov(c.y, hl.dim.y, hl.dim.y + hl.dim.w, hw);
  let black = coverageFromSd(sdRoundRect(c, hl.hole, hl.p.x), px);
  // CG: white fill, then black source-over; 8-bit premultiplied raster.
  let m = round(white * (1.0 - black) * 255.0) / 255.0;
  let a = hl.p.y * m;
  if (a <= 0.0) { discard; }
  return vec4f(0.0, 0.0, 0.0, a);
}
`;

/** Subtitle silhouette seed: (a, a², 0, 0) of the text raster's alpha. */
export const silhouetteWGSL = /* wgsl */ `
${common}
@group(0) @binding(0) var src: texture_2d<f32>;
@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let a = textureLoad(src, vec2i(floor(in.pos.xy)), 0).a;
  return vec4f(a, a * a, 0.0, 0.0);
}
`;

/**
 * Subtitle composite (renderSubtitle): text raster OVER its blurred
 * silhouette (subtitleDropShadow), the result OVER the frame. CIColorMatrix
 * works on UNPREMULTIPLIED values (verified on the Mac): silhouette
 * alpha = c.a·a, premultiplied rgb = c.rgb·(c.a·a)² — hence the blurred
 * (a, a²) pair. The raster is sRGB (CGContext / Canvas2D); CI colour-matches
 * it into the working space → `srgbToP3` when that space is Display P3.
 */
export const subtitleWGSL = /* wgsl */ `
${common}
${bilinearClear}
${cardQuad}
struct SU {
  shadow: vec4f,  // straight silhouette colour rgb, alpha (0 → no effect)
  p: vec4f,       // toP3, 0, 0, 0
};
@group(0) @binding(0) var<uniform> q: QU;
@group(0) @binding(1) var<uniform> s: SU;
@group(0) @binding(2) var text: texture_2d<f32>;
@group(0) @binding(3) var blurred: texture_2d<f32>;

fn toWorking(c: vec4f) -> vec4f {
  if (s.p.x < 0.5 || c.a <= 0.0) { return c; }
  return vec4f(srgbToP3(c.rgb / c.a) * c.a, c.a);
}

@fragment fn fs_main(in: QOut) -> @location(0) vec4f {
  let local = toCardQ(in.pos.xy) - q.bounds.xy;
  let t = toWorking(bilinearClear(text, local));
  var sh = vec4f(0.0);
  if (s.shadow.a > 0.0) {
    let b = bilinearClear(blurred, local);
    let ca = s.shadow.a;
    let rgb = toWorking(vec4f(s.shadow.rgb, 1.0)).rgb;
    sh = vec4f(rgb * ca * ca * b.g, ca * b.r);
  }
  let o = t + sh * (1.0 - t.a);
  if (o.a <= 0.0) { discard; }
  return o;
}
`;
