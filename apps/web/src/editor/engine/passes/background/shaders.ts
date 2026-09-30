/**
 * WGSL for the background bake (`BackgroundLook.cgImage` on the GPU).
 *
 * Every stage has a float64 twin in `testing/backgroundLookReference.ts`
 * (checked against real Mac bitmaps); the comments name the CoreImage /
 * CoreGraphics behaviour each one reproduces. Pixel space is Y-DOWN with
 * `@builtin(position).xy` = pixel centre; CI's Y-up coordinates are formed
 * explicitly as `H − y`.
 *
 * Texture conventions:
 *   *8   rgba8unorm  — gamma-encoded sRGB, PREMULTIPLIED, 8-bit (a CG bitmap)
 *   lin  rgba16float — LINEAR sRGB, premultiplied, unclamped (CI working space)
 */

const common = /* wgsl */ `
struct VSOut { @builtin(position) pos: vec4f };

@vertex fn vs_fullscreen(@builtin(vertex_index) i: u32) -> VSOut {
  var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var o: VSOut;
  o.pos = vec4f(p[i], 0.0, 1.0);
  return o;
}

fn lin1(c: f32) -> f32 {
  if (c <= 0.04045) { return c / 12.92; }
  return pow((c + 0.055) / 1.055, 2.4);
}
fn enc1(c: f32) -> f32 {
  let v = clamp(c, 0.0, 1.0);
  if (v <= 0.0031308) { return v * 12.92; }
  return 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}
fn lin3(c: vec3f) -> vec3f { return vec3f(lin1(c.x), lin1(c.y), lin1(c.z)); }
fn enc3(c: vec3f) -> vec3f { return vec3f(enc1(c.x), enc1(c.y), enc1(c.z)); }

// 8-bit gamma premultiplied texel → linear premultiplied.
fn toLinear(g: vec4f) -> vec4f {
  if (g.a <= 0.0) { return vec4f(0.0); }
  return vec4f(lin3(g.rgb / g.a) * g.a, g.a);
}

// Linear premultiplied → the bytes createCGImage(.BGRA8, sRGB) stores:
// alpha rounded to 8 bits, colour = round(encode(unpremul) · α8).
fn toBytes(c: vec4f) -> vec4f {
  let a = clamp(c.a, 0.0, 1.0);
  let qa = round(a * 255.0);
  if (qa <= 0.0) { return vec4f(0.0); }
  let un = c.rgb / max(c.a, 1e-9);
  let rgb = round(enc3(un) * qa) / 255.0;
  return vec4f(rgb, qa / 255.0);
}
`;

/**
 * Base fills (CG raster of `baseCGImage`): solid, linear Oklab ramp (the
 * 257-stop table, lerped in gamma sRGB like CGGradient), mesh (diagonal ramp
 * + six radial pools source-over, float composite, quantised once — measured
 * closest to CG). Output: rgba8unorm premultiplied (the 8-bit CGImage).
 */
export const fillWGSL = /* wgsl */ `
${common}
struct Pool { geo: vec4f, color: vec4f };   // centre.xy (Y-up), radius, peak alpha | rgb, 0
struct FillU {
  a: vec4f,        // W, H, mode (0 clear, 1 solid, 2 linear, 3 mesh), 0
  p: vec4f,        // gradient p0.xy, p1.xy (Y-up px)
  solid: vec4f,    // straight sRGB + alpha
  pools: array<Pool, 6>,
};
@group(0) @binding(0) var<uniform> u: FillU;
@group(0) @binding(1) var table: texture_2d<f32>;   // 257×1 rgba32float, straight sRGB + alpha

fn ramp(t: f32) -> vec4f {
  let tc = clamp(t, 0.0, 1.0);
  let x = tc * 256.0;
  let i = min(255.0, floor(x));
  let f = x - i;
  let c0 = textureLoad(table, vec2i(i32(i), 0), 0);
  let c1 = textureLoad(table, vec2i(i32(i) + 1, 0), 0);
  return mix(c0, c1, f);
}

fn linearT(q: vec2f) -> f32 {
  let d = u.p.zw - u.p.xy;
  let len2 = dot(d, d);
  if (!(len2 > 0.0)) { return 0.0; }
  return dot(q - u.p.xy, d) / len2;
}

fn poolAlpha(t: f32, peak: f32) -> f32 {
  // stops (0, 1) (0.4, 0.7) (0.75, 0.25) (1, 0), × peak
  var a = 0.0;
  if (t <= 0.4) { a = mix(1.0, 0.7, t / 0.4); }
  else if (t <= 0.75) { a = mix(0.7, 0.25, (t - 0.4) / 0.35); }
  else { a = mix(0.25, 0.0, (t - 0.75) / 0.25); }
  return a * peak;
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let mode = u32(u.a.z);
  let q = vec2f(in.pos.x, u.a.y - in.pos.y);   // Y-up pixel centre
  var c = vec4f(0.0);                          // premultiplied
  if (mode == 1u) {
    c = vec4f(u.solid.rgb * u.solid.a, u.solid.a);
  } else if (mode >= 2u) {
    let s = ramp(linearT(q));
    c = vec4f(s.rgb * s.a, s.a);
    if (mode == 3u) {
      for (var k = 0; k < 6; k++) {
        let pl = u.pools[k];
        if (!(pl.geo.z > 0.0)) { continue; }
        let t = distance(q, pl.geo.xy) / pl.geo.z;
        if (t > 1.0) { continue; }
        let a = poolAlpha(t, pl.geo.w);
        c = vec4f(pl.color.rgb * a, a) + c * (1.0 - a);
      }
    }
  }
  // CGBitmapContext: premultiplied 8-bit.
  return round(clamp(c, vec4f(0.0), vec4f(1.0)) * 255.0) / 255.0;
}
`;

/**
 * Aspect-fill image draw (`aspectFill` with interpolationQuality .high):
 * separable box-through-tent resample (weights computed in-shader),
 * clamp-to-edge. Pass H: image → rgba16float (W × rows); pass V → rgba8unorm.
 */
export const imageResampleWGSL = /* wgsl */ `
${common}
struct ResU {
  a: vec4f,   // dir (0 = horizontal, 1 = vertical), scale, rect origin along the axis, src length
  b: vec4f,   // source row/col offset of the input texture (H pass: first source row), 0, 0, 0
};
@group(0) @binding(0) var<uniform> u: ResU;
@group(0) @binding(1) var src: texture_2d<f32>;

// ∫ of the unit tent max(0, 1 − |t|) from −∞ to t.
fn tentCdf(t: f32) -> f32 {
  if (t <= -1.0) { return 0.0; }
  if (t <= 0.0) { return 0.5 * (t + 1.0) * (t + 1.0); }
  if (t <= 1.0) { return 1.0 - 0.5 * (1.0 - t) * (1.0 - t); }
  return 1.0;
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let horizontal = u.a.x < 0.5;
  let s = u.a.y;
  let origin = u.a.z;
  let srcLen = i32(u.a.w);
  let dims = vec2i(textureDimensions(src));
  let o = select(in.pos.y, in.pos.x, horizontal);         // dest coordinate along the axis (centre)
  let c = (o - origin) / s;                                // source-space centre
  // Each source texel is a box of width s (dest px) seen through a one-pixel
  // tent — measured against CG's .high interpolation on real wallpapers
  // (up- and downscale; no Lanczos ringing on grainy images).
  let support = 1.0 / s + 1.0;
  let i0 = i32(ceil(c - 0.5 - support));
  let i1 = i32(floor(c - 0.5 + support));
  var acc = vec4f(0.0);
  var wsum = 0.0;
  for (var i = i0; i <= i1; i++) {
    let b0 = origin + f32(i) * s - o;
    let w = tentCdf(b0 + s) - tentCdf(b0);
    let si = clamp(i, 0, srcLen - 1);
    var p: vec2i;
    if (horizontal) {
      p = vec2i(si, i32(in.pos.y) + i32(u.b.x));
    } else {
      p = vec2i(i32(in.pos.x), si - i32(u.b.x));
    }
    p = clamp(p, vec2i(0), dims - vec2i(1));
    acc += w * textureLoad(src, p, 0);
    wsum += w;
  }
  let v = acc / max(wsum, 1e-6);
  if (horizontal) { return v; }
  return round(clamp(v, vec4f(0.0), vec4f(1.0)) * 255.0) / 255.0;
}
`;

/**
 * Styled chain, stage 1 → linear: CIPixellate as a WARP over the 8-bit GAMMA
 * source (bilinear on the gamma texels at the block centre, clamp-to-edge,
 * block index round-half-even like Metal's rint), else a plain linearise.
 */
export const preWGSL = /* wgsl */ `
${common}
struct PreU { a: vec4f };   // W, H, block (0 = no pixellate), 0
@group(0) @binding(0) var<uniform> u: PreU;
@group(0) @binding(1) var base: texture_2d<f32>;

fn texelUp(x: i32, yUp: i32) -> vec4f {
  let W = i32(u.a.x);
  let H = i32(u.a.y);
  let xi = clamp(x, 0, W - 1);
  let yi = clamp(yUp, 0, H - 1);
  return textureLoad(base, vec2i(xi, H - 1 - yi), 0);
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let H = u.a.y;
  let s = u.a.z;
  if (s < 1.0) {
    return toLinear(textureLoad(base, vec2i(floor(in.pos.xy)), 0));
  }
  let q = vec2f(in.pos.x, H - in.pos.y);
  let b = (round(q / s - vec2f(0.5)) + vec2f(0.5)) * s;
  let t = b - vec2f(0.5);
  let i0 = vec2i(floor(t));
  let f = t - floor(t);
  let g = mix(
    mix(texelUp(i0.x, i0.y), texelUp(i0.x + 1, i0.y), f.x),
    mix(texelUp(i0.x, i0.y + 1), texelUp(i0.x + 1, i0.y + 1), f.x),
    f.y);
  return toLinear(g);
}
`;

/**
 * CIDotScreen (centre 0, angle 0, sharpness 0.7): luma of the PREMULTIPLIED
 * linear colour (CI weights), P = sin(2πx/w) + sin(2πy/w) at the Y-up pixel
 * centre, grey = clamp(½ + (L − ½)/(1 − s) − P·k) re-premultiplied by α.
 */
export const halftoneWGSL = /* wgsl */ `
${common}
struct HtU { a: vec4f };   // H, 2π / width, 1/(1 − s), k
@group(0) @binding(0) var<uniform> u: HtU;
@group(0) @binding(1) var src: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let c = textureLoad(src, vec2i(floor(in.pos.xy)), 0);
  let L = dot(c.rgb, vec3f(0.2125, 0.7154, 0.0721));
  let yUp = u.a.x - in.pos.y;
  let P = sin(u.a.y * in.pos.x) + sin(u.a.y * yUp);
  let v = clamp(0.5 + (L - 0.5) * u.a.z - P * u.a.w, 0.0, 1.0);
  return vec4f(vec3f(v * c.a), c.a);
}
`;

/**
 * Separable Gaussian on linear rgba16float with clamp-to-edge
 * (clampedToExtent → CIGaussianBlur → crop). Weights from a CPU table
 * (storage buffer: w[0…r]), symmetric.
 */
export const gaussWGSL = /* wgsl */ `
${common}
struct GU { a: vec4f };   // dir.x, dir.y, radius (taps each side), 0
@group(0) @binding(0) var<uniform> u: GU;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var<storage, read> weights: array<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = vec2i(floor(in.pos.xy));
  let dims = vec2i(textureDimensions(src));
  let dir = vec2i(u.a.xy);
  let r = i32(u.a.z);
  var acc = weights[0] * textureLoad(src, p, 0);
  for (var i = 1; i <= r; i++) {
    let w = weights[i];
    let a = clamp(p + dir * i, vec2i(0), dims - vec2i(1));
    let b = clamp(p - dir * i, vec2i(0), dims - vec2i(1));
    acc += w * (textureLoad(src, a, 0) + textureLoad(src, b, 0));
  }
  return acc;
}
`;

/**
 * Box downsample by an integer factor (large-σ blur speed-up) with
 * clamp-to-edge, and the bilinear upsample back (texel-centre aligned).
 */
export const downsampleWGSL = /* wgsl */ `
${common}
struct DU { a: vec4f };   // factor, 0, 0, 0
@group(0) @binding(0) var<uniform> u: DU;
@group(0) @binding(1) var src: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let f = i32(u.a.x);
  let dims = vec2i(textureDimensions(src));
  let o = vec2i(floor(in.pos.xy)) * f;
  var acc = vec4f(0.0);
  for (var j = 0; j < f; j++) {
    for (var i = 0; i < f; i++) {
      acc += textureLoad(src, clamp(o + vec2i(i, j), vec2i(0), dims - vec2i(1)), 0);
    }
  }
  return acc / f32(f * f);
}
`;

export const upsampleWGSL = /* wgsl */ `
${common}
struct UU { a: vec4f };   // factor, 0, 0, 0
@group(0) @binding(0) var<uniform> u: UU;
@group(0) @binding(1) var src: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let dims = vec2i(textureDimensions(src));
  let t = in.pos.xy / u.a.x - vec2f(0.5);
  let i0 = vec2i(floor(t));
  let f = t - floor(t);
  let m = dims - vec2i(1);
  let a = textureLoad(src, clamp(i0, vec2i(0), m), 0);
  let b = textureLoad(src, clamp(i0 + vec2i(1, 0), vec2i(0), m), 0);
  let c = textureLoad(src, clamp(i0 + vec2i(0, 1), vec2i(0), m), 0);
  let d = textureLoad(src, clamp(i0 + vec2i(1, 1), vec2i(0), m), 0);
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
`;

/**
 * Styled chain, final stage (per pixel, linear): CIColorControls (saturation
 * → contrast → brightness on the unpremultiplied colour) → CIHueAdjust (SVG
 * hueRotate matrix) → tint source-over → CIVignetteEffect (× lin(1 − I·
 * smootherstep)) → the 8-bit sRGB bytes createCGImage writes.
 */
export const postWGSL = /* wgsl */ `
${common}
struct PostU {
  a: vec4f,      // W, H, flags (1 colour, 2 hue, 4 tint, 8 vignette), 0
  cc: vec4f,     // saturation, contrast, brightness, 0
  h0: vec4f,     // hue matrix rows
  h1: vec4f,
  h2: vec4f,
  tint: vec4f,   // LINEAR premultiplied tint colour (rgb·a, a)
  vig: vec4f,    // intensity, radius, half-width (½ + falloff), 0
};
@group(0) @binding(0) var<uniform> u: PostU;
@group(0) @binding(1) var src: texture_2d<f32>;

fn smootherstep01(x: f32) -> f32 {
  let t = clamp(x, 0.0, 1.0);
  return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let flags = u32(u.a.z);
  var c = textureLoad(src, vec2i(floor(in.pos.xy)), 0);
  var a = c.a;
  var un = select(vec3f(0.0), c.rgb / a, a > 0.0);
  if ((flags & 1u) != 0u) {
    let l = dot(un, vec3f(0.2125, 0.7154, 0.0721));
    un = vec3f(l) + (un - vec3f(l)) * u.cc.x;
    un = (un - vec3f(0.5)) * u.cc.y + vec3f(0.5 + u.cc.z);
  }
  if ((flags & 2u) != 0u) {
    un = vec3f(dot(u.h0.xyz, un), dot(u.h1.xyz, un), dot(u.h2.xyz, un));
  }
  var pm = un * a;
  if ((flags & 4u) != 0u) {
    pm = u.tint.rgb + pm * (1.0 - u.tint.a);
    a = u.tint.a + a * (1.0 - u.tint.a);
  }
  if ((flags & 8u) != 0u) {
    let d = vec2f(in.pos.x - u.a.x * 0.5, (u.a.y - in.pos.y) - u.a.y * 0.5);
    let t = length(d) / u.vig.y;
    let hw = u.vig.z;
    let m = lin1(1.0 - u.vig.x * smootherstep01((t - (1.0 - hw)) / (2.0 * hw)));
    pm *= m;
  }
  return toBytes(vec4f(pm, a));
}
`;

/**
 * Grain (`grained`): exact integer SplitMix scramble of the 1×-grid cell
 * (x / s, y / s), y from the TOP row, → 16-bit index → Int delta from a CPU
 * table (the Float32 noise·amplitude truncation, computed exactly on the
 * CPU), added to the premultiplied R,G,B bytes with 0…255 clamping.
 */
export const grainWGSL = /* wgsl */ `
${common}
struct GrU { a: vec4f };   // cell, 0, 0, 0
@group(0) @binding(0) var<uniform> u: GrU;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var<storage, read> deltas: array<i32>;

fn mulWide(a: u32, b: u32) -> vec2u {
  let a0 = a & 0xffffu; let a1 = a >> 16u;
  let b0 = b & 0xffffu; let b1 = b >> 16u;
  let p00 = a0 * b0; let p01 = a0 * b1; let p10 = a1 * b0; let p11 = a1 * b1;
  let mid = (p00 >> 16u) + (p01 & 0xffffu) + (p10 & 0xffffu);
  let hi = p11 + (p01 >> 16u) + (p10 >> 16u) + (mid >> 16u);
  return vec2u(hi, a * b);
}
// (hi, lo) × (hi, lo) mod 2^64
fn mul64(a: vec2u, b: vec2u) -> vec2u {
  let w = mulWide(a.y, b.y);
  return vec2u(w.x + a.x * b.y + a.y * b.x, w.y);
}
fn xorShr(v: vec2u, k: u32) -> vec2u {
  let hi = v.x >> k;
  let lo = (v.y >> k) | (v.x << (32u - k));
  return vec2u(v.x ^ hi, v.y ^ lo);
}
fn noiseIndex(vx: u32, vy: u32) -> u32 {
  let a = mul64(vec2u(0u, vx), vec2u(0x9e3779b9u, 0x7f4a7c15u));
  let b = mul64(vec2u(0u, vy), vec2u(0xbf58476du, 0x1ce4e5b9u));
  var v = vec2u(a.x ^ b.x, a.y ^ b.y);
  v = xorShr(v, 30u);
  v = mul64(v, vec2u(0x94d049bbu, 0x133111ebu));
  v = xorShr(v, 27u);
  return v.y & 0xffffu;
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = vec2u(floor(in.pos.xy));
  let s = u32(u.a.x);
  let c = textureLoad(src, vec2i(p), 0);
  let d = f32(deltas[noiseIndex(p.x / s, p.y / s)]);
  let rgb = clamp(round(c.rgb * 255.0) + vec3f(d), vec3f(0.0), vec3f(255.0)) / 255.0;
  return vec4f(rgb, c.a);
}
`;

/**
 * 8-bit sRGB bitmap → the working space (CI colour-matches the sRGB CGImage
 * into the export context: Display P3 for P3 recordings).
 */
export const resolveWGSL = /* wgsl */ `
${common}
struct RsU { a: vec4f };   // toP3, 0, 0, 0
@group(0) @binding(0) var<uniform> u: RsU;
@group(0) @binding(1) var src: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let c = textureLoad(src, vec2i(floor(in.pos.xy)), 0);
  if (u.a.x < 0.5 || c.a <= 0.0) { return c; }
  let m = mat3x3f(
    vec3f(0.8224621, 0.0331941, 0.0170827),
    vec3f(0.1775380, 0.9668058, 0.0723974),
    vec3f(0.0, 0.0, 0.9105199));
  let rgb = enc3(m * lin3(c.rgb / c.a));
  return vec4f(rgb * c.a, c.a);
}
`;
