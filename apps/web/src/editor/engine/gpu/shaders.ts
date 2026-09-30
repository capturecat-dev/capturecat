/**
 * WGSL modules for the engine passes.
 *
 * Conventions (all passes):
 *  - Pixel space is Y-DOWN; `@builtin(position).xy` is the pixel CENTRE
 *    (x + 0.5, y + 0.5), exactly where CoreGraphics / CoreImage sample.
 *  - Colour is PREMULTIPLIED and gamma-encoded in the working space (sRGB or
 *    Display P3), mirroring the Mac export CIContext (see `color.ts`).
 *  - "Clear outside": CoreImage treats everything beyond an image's extent as
 *    transparent, so every resample here that can straddle an edge fetches 0
 *    for out-of-bounds taps instead of clamping (`loadClear*`).
 *
 * Each function that has a CPU twin in `testing/cpuReference.ts` says so; the
 * lab parity check pins the two together within 2/255.
 */

export const common = /* wgsl */ `
struct VSOut { @builtin(position) pos: vec4f };

@vertex fn vs_fullscreen(@builtin(vertex_index) i: u32) -> VSOut {
  var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var o: VSOut;
  o.pos = vec4f(p[i], 0.0, 1.0);
  return o;
}

// sRGB transfer (OklabGradient.linearize / encode).
fn linearize1(c: f32) -> f32 {
  if (c <= 0.04045) { return c / 12.92; }
  return pow((c + 0.055) / 1.055, 2.4);
}
fn encode1(c: f32) -> f32 {
  let v = clamp(c, 0.0, 1.0);
  if (v <= 0.0031308) { return v * 12.92; }
  return 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}
fn linearize3(c: vec3f) -> vec3f { return vec3f(linearize1(c.x), linearize1(c.y), linearize1(c.z)); }
fn encode3(c: vec3f) -> vec3f { return vec3f(encode1(c.x), encode1(c.y), encode1(c.z)); }

// Straight-alpha encoded sRGB → encoded Display P3 (color.ts srgbToWorking).
fn srgbToP3(c: vec3f) -> vec3f {
  let l = linearize3(c);
  let m = mat3x3f(
    vec3f(0.8224621, 0.0331941, 0.0170827),
    vec3f(0.1775380, 0.9668058, 0.0723974),
    vec3f(0.0, 0.0, 0.9105199));
  return encode3(m * l);
}

// IQ rounded-box SDF, Y-down pixels. r is clamped like CGPath/SwiftUI clamp.
fn sdRoundRect(p: vec2f, rect: vec4f, radius: f32) -> f32 {
  let half = rect.zw * 0.5;
  let r = clamp(radius, 0.0, min(half.x, half.y));
  let q = abs(p - (rect.xy + half)) - half + vec2f(r);
  return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Area-coverage AA: exact for straight axis-aligned edges (cpuReference.coverage).
fn coverageFromSd(d: f32, px: f32) -> f32 {
  return clamp(0.5 - d / px, 0.0, 1.0);
}
`;

/** Background bake → rgba8unorm (working space, premultiplied). */
export const backgroundWGSL = /* wgsl */ `
${common}
struct BgU {
  a: vec4f,     // size.x, size.y, mode (0 clear, 1 solid, 2 gradient), angleDeg
  b: vec4f,     // diagonal (1 = legacy topLeading→bottomTrailing), toP3, 0, 0
  c0: vec4f,    // gradient start (straight sRGB)
  c1: vec4f,    // gradient end
  solid: vec4f,
};
@group(0) @binding(0) var<uniform> u: BgU;

fn cbrt1(x: f32) -> f32 {
  if (x == 0.0) { return 0.0; }
  return sign(x) * pow(abs(x), 1.0 / 3.0);
}
fn oklab(c: vec3f) -> vec3f {
  let r = linearize1(c.x); let g = linearize1(c.y); let b = linearize1(c.z);
  let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
  let l_ = cbrt1(l); let m_ = cbrt1(m); let s_ = cbrt1(s);
  return vec3f(
    0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_);
}
fn oklabToSrgb(lab: vec3f) -> vec3f {
  let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
  let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
  let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
  let l = l_ * l_ * l_; let m = m_ * m_ * m_; let s = s_ * s_ * s_;
  return encode3(vec3f(
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s));
}
// OklabGradient.mix (color.ts oklabMix)
fn oklabMix(a: vec4f, b: vec4f, t: f32) -> vec4f {
  let alpha = a.w + (b.w - a.w) * t;
  let wa = a.w * (1.0 - t);
  let wb = b.w * t;
  let sum = wa + wb;
  if (!(sum > 0.0)) { return vec4f(0.0); }
  let lab = (oklab(a.xyz) * wa + oklab(b.xyz) * wb) / sum;
  return vec4f(oklabToSrgb(lab), alpha);
}
// 256-stop CGGradient over the Oklab ramp (color.ts cgOklabRamp)
fn cgRamp(a: vec4f, b: vec4f, t: f32) -> vec4f {
  let n = 256.0;
  let tc = clamp(t, 0.0, 1.0);
  let i = min(n - 1.0, floor(tc * n));
  let f = tc * n - i;
  let c0 = oklabMix(a, b, i / n);
  let c1 = oklabMix(a, b, (i + 1.0) / n);
  return mix(c0, c1, f);
}
// BackgroundGradientRenderer axis (color.ts gradientT)
fn gradientT(p: vec2f, size: vec2f, angleDeg: f32, diagonal: bool) -> f32 {
  if (diagonal) { return dot(p, size) / dot(size, size); }
  let th = radians(angleDeg);
  let d = vec2f(sin(th), -cos(th));
  let len = abs(size.x * d.x) + abs(size.y * d.y);
  if (!(len > 0.0)) { return 0.0; }
  return dot(p - size * 0.5, d) / len + 0.5;
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let mode = u32(u.a.z);
  if (mode == 0u) { return vec4f(0.0); }
  var c: vec4f;
  if (mode == 1u) {
    c = u.solid;
  } else {
    c = cgRamp(u.c0, u.c1, gradientT(in.pos.xy, u.a.xy, u.a.w, u.b.x > 0.5));
  }
  // CoreGraphics stores premultiplied 8-bit: quantize like the CGImage.
  let qa = round(clamp(c.w, 0.0, 1.0) * 255.0) / 255.0;
  if (qa <= 0.0) { return vec4f(0.0); }
  let qpm = round(clamp(c.xyz, vec3f(0.0), vec3f(1.0)) * c.w * 255.0) / 255.0;
  var rgb = qpm / qa;
  // CoreImage colour-matches the sRGB CGImage into the working space.
  if (u.b.y > 0.5) { rgb = srgbToP3(rgb); }
  return vec4f(rgb * qa, qa);
}
`;

/** Shape mask × alpha → r16float (the `shapedShadow` of makeFrameShadow). */
export const shapeMaskWGSL = /* wgsl */ `
${common}
struct MaskU {
  rect: vec4f,    // Y-down px
  p: vec4f,       // radius, kind (0 rect, 1 rounded, 2 squircle), alpha, 0
  sq: vec4f,      // squircle mask origin.xy (integer px), size.xy
};
@group(0) @binding(0) var<uniform> u: MaskU;
@group(0) @binding(1) var sqMask: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let kind = u32(u.p.y);
  var cov: f32;
  if (kind == 2u) {
    let ip = vec2i(floor(in.pos.xy) - u.sq.xy);
    let dims = vec2i(u.sq.zw);
    if (ip.x < 0 || ip.y < 0 || ip.x >= dims.x || ip.y >= dims.y) {
      cov = 0.0;
    } else {
      cov = textureLoad(sqMask, ip, 0).r;
    }
  } else {
    let r = select(0.0, u.p.x, kind == 1u);
    cov = coverageFromSd(sdRoundRect(in.pos.xy, u.rect, r), 1.0);
  }
  return vec4f(cov * u.p.z, 0.0, 0.0, 0.0);
}
`;

/** Separable Gaussian (CIGaussianBlur twin, sigma in px), clear outside. */
export const blurWGSL = /* wgsl */ `
${common}
struct BlurU {
  p: vec4f,   // dir.x, dir.y, sigma, radius (taps each side)
};
@group(0) @binding(0) var<uniform> u: BlurU;
@group(0) @binding(1) var src: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = vec2i(floor(in.pos.xy));
  let dims = vec2i(textureDimensions(src));
  let dir = vec2i(u.p.xy);
  let sigma = u.p.z;
  let r = i32(u.p.w);
  let k = -0.5 / (sigma * sigma);
  var acc = 0.0;
  var wsum = 0.0;
  for (var i = -r; i <= r; i++) {
    let w = exp(f32(i * i) * k);
    wsum += w;
    let q = p + dir * i;
    if (q.x >= 0 && q.y >= 0 && q.x < dims.x && q.y < dims.y) {
      acc += w * textureLoad(src, q, 0).r;
    }
  }
  return vec4f(acc / wsum, 0.0, 0.0, 0.0);
}
`;

export const bilinearClear = /* wgsl */ `
// Bilinear fetch with CoreImage "clear outside the extent" semantics.
fn loadClear4(t: texture_2d<f32>, ip: vec2i, dims: vec2i) -> vec4f {
  if (ip.x < 0 || ip.y < 0 || ip.x >= dims.x || ip.y >= dims.y) { return vec4f(0.0); }
  return textureLoad(t, ip, 0);
}
fn bilinearClear(t: texture_2d<f32>, p: vec2f) -> vec4f {
  let dims = vec2i(textureDimensions(t));
  let s = p - vec2f(0.5);
  let i0 = vec2i(floor(s));
  let f = s - floor(s);
  let a = loadClear4(t, i0, dims);
  let b = loadClear4(t, i0 + vec2i(1, 0), dims);
  let c = loadClear4(t, i0 + vec2i(0, 1), dims);
  let d = loadClear4(t, i0 + vec2i(1, 1), dims);
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
`;

/**
 * Base bake: background with the blurred card shadow composited over it
 * (the Mac's `cachedBaseFrame`), or — mode 1 — the shadow alone over clear
 * (`cachedCardStatics`, drawn into the card layer).
 */
export const shadowComposeWGSL = /* wgsl */ `
${common}
${bilinearClear}
struct ShU {
  p: vec4f,   // offsetY (Y-down px), mode (0 base = bg×(1−a), 1 shadow only), 0, 0
};
@group(0) @binding(0) var<uniform> u: ShU;
@group(0) @binding(1) var shadow: texture_2d<f32>;
@group(0) @binding(2) var bg: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  // makeFrameShadow: translate the blurred shadow DOWN by radius / 3
  // (CI y −r/3), crop to the canvas → sample at p − (0, offset).
  let a = bilinearClear(shadow, in.pos.xy - vec2f(0.0, u.p.x)).r;
  if (u.p.y > 0.5) { return vec4f(0.0, 0.0, 0.0, a); }
  let c = textureLoad(bg, vec2i(floor(in.pos.xy)), 0);
  // Black shadow (0,0,0,a) source-over the background.
  return vec4f(c.rgb * (1.0 - a), a + c.a * (1.0 - a));
}
`;

/** Pixel-exact copy of a texture (base → target). */
export const blitWGSL = /* wgsl */ `
${common}
@group(0) @binding(0) var src: texture_2d<f32>;
@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  return textureLoad(src, vec2i(floor(in.pos.xy)), 0);
}
`;

/** Background through the zoom parallax (canvas → background map), bilinear like CI's affine resample. */
export const blitWarpWGSL = /* wgsl */ `
${common}
${bilinearClear}
struct WarpU { inv0: vec4f, inv1: vec4f, inv2: vec4f };
@group(0) @binding(0) var<uniform> u: WarpU;
@group(0) @binding(1) var src: texture_2d<f32>;
@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = vec3f(in.pos.xy, 1.0);
  let h = vec3f(dot(u.inv0.xyz, p), dot(u.inv1.xyz, p), dot(u.inv2.xyz, p));
  return bilinearClear(src, h.xy / h.z);
}
`;

const lanczos = /* wgsl */ `
struct FitU {
  p: vec4f,   // taps per output pixel, srcLen (along the filtered axis) − 1, 0, 0
};
@group(0) @binding(0) var<uniform> u: FitU;
// Per output column (H) / row (V): [firstTap, w0 … w(taps−1)], weights already
// normalised by the FULL kernel sum (out-of-extent taps weigh in as clear).
@group(0) @binding(2) var<storage, read> weights: array<f32>;
`;

/**
 * CILanczosScaleTransform twin, pass 1: horizontal, reads the decoded frame
 * (texture_external — zero copy) and writes rgba16float (dstW × srcH).
 * Tap positions + weights come from a CPU-built table (`lanczosTable`), so
 * the inner loop is loads and FMAs only — no per-tap sin().
 */
export const fitHorizontalWGSL = /* wgsl */ `
${common}
${lanczos}
@group(0) @binding(1) var src: texture_external;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let taps = u32(u.p.x);
  let last = i32(u.p.y);
  let y = i32(floor(in.pos.y));
  let base = u32(floor(in.pos.x)) * (taps + 1u);
  let first = i32(weights[base]);
  var acc = vec4f(0.0);
  for (var k = 0u; k < taps; k++) {
    let i = clamp(first + i32(k), 0, last);
    acc += weights[base + 1u + k] * textureLoad(src, vec2i(i, y));
  }
  return acc;
}
`;

/** Lanczos pass 2: vertical, rgba16float → rgba8unorm (dstW × dstH). */
export const fitVerticalWGSL = /* wgsl */ `
${common}
${lanczos}
@group(0) @binding(1) var src: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let taps = u32(u.p.x);
  let last = i32(u.p.y);
  let x = i32(floor(in.pos.x));
  let base = u32(floor(in.pos.y)) * (taps + 1u);
  let first = i32(weights[base]);
  var acc = vec4f(0.0);
  for (var k = 0u; k < taps; k++) {
    let i = clamp(first + i32(k), 0, last);
    acc += weights[base + 1u + k] * textureLoad(src, vec2i(x, i), 0);
  }
  return clamp(acc, vec4f(0.0), vec4f(1.0));
}
`;

export const cardCommon = /* wgsl */ `
${common}
struct CardU {
  fwd0: vec4f, fwd1: vec4f, fwd2: vec4f,   // card → target homography rows
  inv0: vec4f, inv1: vec4f, inv2: vec4f,   // target → card
  tgt: vec4f,      // target size.xy, pixel footprint (card px per target px), 0
  video: vec4f,    // videoRect (card space, Y-down px)
  content: vec4f,  // contentRect
  bounds: vec4f,   // quad = video ∩ content, expanded 1px
  inner: vec4f,    // radius, kind (0 none, 1 rounded), 0, 0
  outer: vec4f,    // radius, kind (0 none, 1 rounded, 2 squircle), 0, 0
  sq: vec4f,       // squircle mask origin.xy, size.xy
  vid: vec4f,      // sample-space size.xy, videoScale, source px cropped off the top (Hidden menu bar)
};
@group(0) @binding(0) var<uniform> u: CardU;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var sqMask: texture_2d<f32>;

struct CardOut { @builtin(position) pos: vec4f };

@vertex fn vs_card(@builtin(vertex_index) i: u32) -> CardOut {
  let b = u.bounds;
  var corners = array<vec2f, 6>(
    b.xy, b.xy + vec2f(b.z, 0.0), b.xy + vec2f(0.0, b.w),
    b.xy + vec2f(0.0, b.w), b.xy + vec2f(b.z, 0.0), b.xy + b.zw);
  let c = corners[i];
  let h = vec3f(dot(u.fwd0.xyz, vec3f(c, 1.0)), dot(u.fwd1.xyz, vec3f(c, 1.0)), dot(u.fwd2.xyz, vec3f(c, 1.0)));
  let ndc = vec2f(h.x / u.tgt.x * 2.0 - h.z, h.z - h.y / u.tgt.y * 2.0);
  var o: CardOut;
  o.pos = vec4f(ndc, 0.0, h.z);
  return o;
}

fn toCard(p: vec2f) -> vec2f {
  let h = vec3f(dot(u.inv0.xyz, vec3f(p, 1.0)), dot(u.inv1.xyz, vec3f(p, 1.0)), dot(u.inv2.xyz, vec3f(p, 1.0)));
  return h.xy / h.z;
}

fn inRect(q: vec2f, r: vec4f) -> bool {
  return q.x >= r.x && q.y >= r.y && q.x < r.x + r.z && q.y < r.y + r.w;
}

// Window-clip (inner) × frame-clip (outer) masks — cpuReference.cardCoverage.
fn cardCoverage(q: vec2f) -> f32 {
  let px = u.tgt.z;
  var cov = 1.0;
  if (u.inner.y > 0.5) {
    cov *= coverageFromSd(sdRoundRect(q, u.video, u.inner.x), px);
  }
  let ok = u32(u.outer.y);
  if (ok == 1u) {
    cov *= coverageFromSd(sdRoundRect(q, u.video, u.outer.x), px);
  } else if (ok == 2u) {
    let m = (q - u.sq.xy) / u.sq.zw;
    cov *= textureSampleLevel(sqMask, samp, m, 0.0).r;
  }
  return cov;
}

// Bilinear "clear outside" edge factor for a clamped sample at texel-space
// point s in a texture of size dims (1 inside; the weight of in-bounds taps
// at the border) — see the header note.
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
`;

/** Video card from the Lanczos-fitted texture (videoScale < 0.999). */
export const cardFittedWGSL = /* wgsl */ `
${cardCommon}
@group(0) @binding(3) var fitted: texture_2d<f32>;

@fragment fn fs_main(in: CardOut) -> @location(0) vec4f {
  let q = toCard(in.pos.xy);
  if (!inRect(q, u.video) || !inRect(q, u.content)) { discard; }
  // Bottom-aligned: a Hidden-menu-bar crop spills the top strip above the rect.
  let local = q - u.video.xy + vec2f(0.0, u.vid.w * u.vid.z);
  let dims = u.vid.xy;
  let c = textureSampleLevel(fitted, samp, local / dims, 0.0) * edgeFactor(local, dims);
  return c * cardCoverage(q);
}
`;

/** Video card sampled straight from the decoded frame (videoScale ≥ 0.999, affine upscale). */
export const cardDirectWGSL = /* wgsl */ `
${cardCommon}
@group(0) @binding(3) var frame: texture_external;

@fragment fn fs_main(in: CardOut) -> @location(0) vec4f {
  let q = toCard(in.pos.xy);
  if (!inRect(q, u.video) || !inRect(q, u.content)) { discard; }
  let local = (q - u.video.xy) / u.vid.z + vec2f(0.0, u.vid.w);     // source pixels
  let dims = u.vid.xy;
  let c = textureSampleBaseClampToEdge(frame, samp, local / dims) * edgeFactor(local, dims);
  return c * cardCoverage(q);
}
`;

/**
 * Card layer → target through the camera transform (zoom / tilt / slide).
 * Bilinear with clear outside, like CI's affine/perspective resample.
 *
 * Optional post-zoom crop (the exporter's `cropped(to: outputRect)` between
 * the zoom and the offset / intro transforms): `clip*` maps the target pixel
 * into that crop space; coverage is the bilinear weight of the in-rect
 * texels there — what CI's resample of the cropped image yields (measured:
 * a crop edge landing 0.4 px into a pixel gives 0.6).
 */
export const layerComposeWGSL = /* wgsl */ `
${common}
${bilinearClear}
struct LayerU { inv0: vec4f, inv1: vec4f, inv2: vec4f, clip0: vec4f, clip1: vec4f, clip2: vec4f, clipDims: vec4f };
@group(0) @binding(0) var<uniform> u: LayerU;
@group(0) @binding(1) var layer: texture_2d<f32>;

fn cropCoverage(s: vec2f, dims: vec2f) -> f32 {
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

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = vec3f(in.pos.xy, 1.0);
  let h = vec3f(dot(u.inv0.xyz, p), dot(u.inv1.xyz, p), dot(u.inv2.xyz, p));
  if (h.z <= 0.0) { return vec4f(0.0); }
  var c = bilinearClear(layer, h.xy / h.z);
  if (u.clipDims.z > 0.5) {
    let q = vec3f(dot(u.clip0.xyz, p), dot(u.clip1.xyz, p), dot(u.clip2.xyz, p));
    if (q.z <= 0.0) { return vec4f(0.0); }
    c *= cropCoverage(q.xy / q.z, u.clipDims.xy);
  }
  // clipDims.w: the keynote dip's VideoExporter.fadeImage (1 otherwise) —
  // CIColorMatrix works on UNPREMULTIPLIED colour, so premultiplied RGB × a²
  // and alpha × a (see cameraShaders.ts fadeImage).
  let a = u.clipDims.w;
  return vec4f(c.rgb * (a * a), c.a * a);
}
`;

/**
 * Card motion blur — the CIMotionBlur twin (measured on macOS by impulse
 * response): a 1D Gaussian along the motion with σ = inputRadius px, input
 * clamped to its extent, total weight scaled by CI's `gain` (1 / 0.9934 /
 * 0.99767 / 0.9891 by radius band).
 *
 * mode 0 — Gaussian taps k·step·dir, k ∈ [−n, n], σ = sigma (unit steps for
 *          small radii; sparse steps over a box-prefiltered input otherwise).
 * mode 1 — box prefilter of width `step` along dir (n taps), so the sparse
 *          Gaussian that follows integrates instead of aliasing.
 *
 * `clampedToExtent()`: taps are clamped to `ext` (pixel-centre bounds of the
 * card's extent, rounded OUT to whole pixels like CI), so past an offset
 * card's edge the blur repeats the partially covered edge row instead of
 * reading clear — measured: a 0.7-coverage edge row repeats as 0.7.
 */
export const motionBlurWGSL = /* wgsl */ `
${common}
struct BlurU { dir: vec2f, step: f32, n: f32, sigma: f32, gain: f32, mode: f32, pad: f32, ext: vec4f };
@group(0) @binding(0) var<uniform> u: BlurU;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var src: texture_2d<f32>;

fn tap(p: vec2f, dims: vec2f) -> vec4f {
  let q = clamp(p, u.ext.xy, u.ext.zw);
  return textureSampleLevel(src, samp, q / dims, 0.0);
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let dims = vec2f(textureDimensions(src));
  let p = in.pos.xy;
  var acc = vec4f(0.0);
  if (u.mode > 0.5) {
    let n = i32(u.n);
    for (var j = 0; j < n; j++) {
      let off = ((f32(j) + 0.5) / f32(n) - 0.5) * u.step;
      acc += tap(p + off * u.dir, dims);
    }
    return acc / f32(n);
  }
  let n = i32(u.n);
  var wsum = 0.0;
  let inv = 1.0 / (2.0 * u.sigma * u.sigma);
  for (var k = -n; k <= n; k++) {
    let x = f32(k) * u.step;
    let w = exp(-x * x * inv);
    acc += w * tap(p + x * u.dir, dims);
    wsum += w;
  }
  return acc * (u.gain / wsum);
}
`;
