/**
 * WGSL for the cursor layer (sprite + drop shadow, click ripples, shortcut
 * pill). Conventions match `gpu/shaders.ts`: Y-down pixels, fragment
 * positions are pixel CENTRES, colour premultiplied + gamma-encoded in the
 * working space, and every resample treats texels outside the image as clear
 * (CoreImage extent semantics).
 *
 * Card-stage draws take a card-space quad and the card → target homography
 * (`FrameEncoder.cardToTarget`), so they render identically into the canvas
 * (identity camera) or the card layer that the camera warps.
 */

const common = /* wgsl */ `
struct VSOut { @builtin(position) pos: vec4f };

@vertex fn vs_fullscreen(@builtin(vertex_index) i: u32) -> VSOut {
  var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var o: VSOut;
  o.pos = vec4f(p[i], 0.0, 1.0);
  return o;
}

fn linearize1(c: f32) -> f32 {
  if (c <= 0.04045) { return c / 12.92; }
  return pow((c + 0.055) / 1.055, 2.4);
}
fn encode1(c: f32) -> f32 {
  let v = clamp(c, 0.0, 1.0);
  if (v <= 0.0031308) { return v * 12.92; }
  return 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}
// Straight-alpha encoded sRGB → encoded Display P3 (color.ts srgbToWorking).
fn srgbToP3(c: vec3f) -> vec3f {
  let l = vec3f(linearize1(c.x), linearize1(c.y), linearize1(c.z));
  let m = mat3x3f(
    vec3f(0.8224621, 0.0331941, 0.0170827),
    vec3f(0.1775380, 0.9668058, 0.0723974),
    vec3f(0.0, 0.0, 0.9105199));
  let p = m * l;
  return vec3f(encode1(p.x), encode1(p.y), encode1(p.z));
}
// Premultiplied sRGB → premultiplied working space (toP3 > 0.5 → Display P3).
fn toWorking(c: vec4f, toP3: f32) -> vec4f {
  if (toP3 < 0.5 || c.a <= 0.0) { return c; }
  return vec4f(srgbToP3(c.rgb / c.a) * c.a, c.a);
}
// 8-bit unorm storage (CGBitmapContext rasters).
fn q8(c: vec4f) -> vec4f { return round(clamp(c, vec4f(0.0), vec4f(1.0)) * 255.0) / 255.0; }

fn loadClear(t: texture_2d<f32>, ip: vec2i, dims: vec2i) -> vec4f {
  if (ip.x < 0 || ip.y < 0 || ip.x >= dims.x || ip.y >= dims.y) { return vec4f(0.0); }
  return textureLoad(t, ip, 0);
}
// Bilinear at texel-space point p (texel centres at i + 0.5), clear outside
// the first dims texels (CoreImage's default linear sampler on an extent).
fn bilinearClearIn(t: texture_2d<f32>, p: vec2f, dims: vec2i) -> vec4f {
  let s = p - vec2f(0.5);
  let i0 = vec2i(floor(s));
  let f = s - floor(s);
  let a = loadClear(t, i0, dims);
  let b = loadClear(t, i0 + vec2i(1, 0), dims);
  let c = loadClear(t, i0 + vec2i(0, 1), dims);
  let d = loadClear(t, i0 + vec2i(1, 1), dims);
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
`;

/** Card-space quad through the card → target homography. */
const cardQuad = /* wgsl */ `
struct Quad {
  fwd0: vec4f, fwd1: vec4f, fwd2: vec4f,   // card → target rows
  inv0: vec4f, inv1: vec4f, inv2: vec4f,   // target → card
  tgt: vec4f,                               // target size.xy
  bounds: vec4f,                            // card-space quad x, y, w, h
};
struct CardOut { @builtin(position) pos: vec4f };
fn quadCorner(q: Quad, i: u32) -> vec4f {
  let b = q.bounds;
  var corners = array<vec2f, 6>(
    b.xy, b.xy + vec2f(b.z, 0.0), b.xy + vec2f(0.0, b.w),
    b.xy + vec2f(0.0, b.w), b.xy + vec2f(b.z, 0.0), b.xy + b.zw);
  let c = corners[i];
  let h = vec3f(dot(q.fwd0.xyz, vec3f(c, 1.0)), dot(q.fwd1.xyz, vec3f(c, 1.0)), dot(q.fwd2.xyz, vec3f(c, 1.0)));
  return vec4f(h.x / q.tgt.x * 2.0 - h.z, h.z - h.y / q.tgt.y * 2.0, 0.0, h.z);
}
fn quadToCard(q: Quad, p: vec2f) -> vec2f {
  let h = vec3f(dot(q.inv0.xyz, vec3f(p, 1.0)), dot(q.inv1.xyz, vec3f(p, 1.0)), dot(q.inv2.xyz, vec3f(p, 1.0)));
  return h.xy / h.z;
}
`;

/**
 * Pass A — the shadow silhouette: the placed sprite's alpha × opacity on the
 * card pixel grid of region R (renderCursorCI → manualDropShadow's
 * CIColorMatrix(alpha row w = shadowOpacity) of `positionedPadded`).
 */
export const cursorSilhouetteWGSL = /* wgsl */ `
${common}
struct SilU {
  inv0: vec4f, inv1: vec4f,   // output (Y-down px) → base sprite texel (u, v): rows of the 2×3 inverse
  region: vec4f,              // R origin.xy (card px), opacity, 0
  raster: vec4f,              // sampled level's size.xy, 0, 0
  level: vec4f,               // base texel → level texel: u·x, v·y + z (CI pre-downsample)
};
@group(0) @binding(0) var<uniform> u: SilU;
@group(0) @binding(1) var sprite: texture_2d<f32>;

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = u.region.xy + in.pos.xy;
  let uv = vec2f(dot(u.inv0.xyz, vec3f(p, 1.0)), dot(u.inv1.xyz, vec3f(p, 1.0)));
  let a = bilinearClearIn(sprite, vec2f(uv.x * u.level.x, uv.y * u.level.y + u.level.z), vec2i(u.raster.xy)).a;
  return vec4f(a * u.region.z, 0.0, 0.0, 0.0);
}
`;

/**
 * Passes B/C — CIGaussianBlur on the silhouette, one axis per pass. The
 * weights are CoreImage's (probed: the pixel-integrated Gaussian, radius
 * ceil(3σ)), precomputed on the CPU; `clampedToExtent` of a transparent-
 * bordered image == zero outside.
 */
export const cursorBlurWGSL = /* wgsl */ `
${common}
struct BlurU {
  p: vec4f,                 // dir.x, dir.y, radius, 0
  size: vec4f,              // valid region size.xy (texels), 0, 0
  w: array<vec4f, 16>,      // weights[|k|], k = 0…radius (4 per vec4)
};
@group(0) @binding(0) var<uniform> u: BlurU;
@group(0) @binding(1) var src: texture_2d<f32>;

fn weight(k: i32) -> f32 {
  let a = abs(k);
  return u.w[a / 4][a % 4];
}

@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  let p = vec2i(floor(in.pos.xy));
  let dims = vec2i(u.size.xy);
  let dir = vec2i(u.p.xy);
  let r = i32(u.p.z);
  var acc = 0.0;
  for (var k = -r; k <= r; k++) {
    acc += weight(k) * loadClear(src, p + dir * k, dims).r;
  }
  return vec4f(acc, 0.0, 0.0, 0.0);
}
`;

/**
 * Pass D (card stage) — sprite source-over its shadow, the pair source-over
 * the frame: `positioned.composited(over: blurred.translated(offset))`.
 */
export const cursorCompositeWGSL = /* wgsl */ `
${common}
${cardQuad}
struct CompU {
  q: Quad,
  inv0: vec4f, inv1: vec4f,   // card px → base sprite texel rows (2×3 inverse)
  raster: vec4f,              // sampled level's size.xy, 0, 0
  shadow: vec4f,              // R origin.xy (card px), offset.xy (Y-down px)
  shadowSize: vec4f,          // valid blurred region size.xy, hasShadow, 0
  level: vec4f,               // base texel → level texel: u·x, v·y + z (CI pre-downsample)
};
@group(0) @binding(0) var<uniform> u: CompU;
@group(0) @binding(1) var sprite: texture_2d<f32>;
@group(0) @binding(2) var blurred: texture_2d<f32>;

@vertex fn vs_quad(@builtin(vertex_index) i: u32) -> CardOut {
  var o: CardOut;
  o.pos = quadCorner(u.q, i);
  return o;
}

@fragment fn fs_main(in: CardOut) -> @location(0) vec4f {
  let p = quadToCard(u.q, in.pos.xy);
  let uv = vec2f(dot(u.inv0.xyz, vec3f(p, 1.0)), dot(u.inv1.xyz, vec3f(p, 1.0)));
  let s = bilinearClearIn(sprite, vec2f(uv.x * u.level.x, uv.y * u.level.y + u.level.z), vec2i(u.raster.xy));
  var sh = 0.0;
  if (u.shadowSize.z > 0.5) {
    sh = bilinearClearIn(blurred, p - u.shadow.xy - u.shadow.zw, vec2i(u.shadowSize.xy)).r;
  }
  // Black shadow (0,0,0,sh) under the premultiplied sprite.
  return vec4f(s.rgb, s.a + sh * (1.0 - s.a));
}
`;

/** Max draw ops per ripple draw call (3 per live ripple + 2 for the drag glow). */
export const RIPPLE_MAX_OPS = 48;

/**
 * Click ripples (card stage) — `ClickRippleOverlay.renderForExport` into a
 * transparent 8-bit sRGB CGContext, then over the frame. Each op is a circle
 * (stroked: centred band of `lineWidth`; filled: disk) with area-coverage AA,
 * painted source-over in order; the finished overlay is quantized to 8 bits
 * like the CGImage, converted to the working space, and composited.
 */
export const rippleWGSL = /* wgsl */ `
${common}
${cardQuad}
struct RippleU {
  q: Quad,
  color: vec4f,               // straight sRGB rgb (ripple colour after CG's Generic→sRGB match), op count
  flags: vec4f,               // toP3, 0, 0, 0
  ops: array<vec4f, ${RIPPLE_MAX_OPS * 2}>,   // [cx, cy (Y-down), radius, lineWidth (0 = fill)], [alpha, 0, 0, 0]
};
@group(0) @binding(0) var<uniform> u: RippleU;

@vertex fn vs_quad(@builtin(vertex_index) i: u32) -> CardOut {
  var o: CardOut;
  o.pos = quadCorner(u.q, i);
  return o;
}

fn disk(d: f32, r: f32) -> f32 { return clamp(r - d + 0.5, 0.0, 1.0); }

@fragment fn fs_main(in: CardOut) -> @location(0) vec4f {
  let p = quadToCard(u.q, in.pos.xy);
  let n = i32(u.color.w);
  var layer = vec4f(0.0);
  for (var i = 0; i < n; i++) {
    let g = u.ops[i * 2];
    let alpha = u.ops[i * 2 + 1].x;
    let d = distance(p, g.xy);
    var cov: f32;
    if (g.w > 0.0) {
      cov = clamp(disk(d, g.z + g.w * 0.5) - disk(d, g.z - g.w * 0.5), 0.0, 1.0);
    } else {
      cov = disk(d, g.z);
    }
    let a = alpha * cov;
    layer = vec4f(u.color.rgb * a, a) + layer * (1.0 - a);
  }
  return toWorking(q8(layer), u.flags.x);
}
`;

/**
 * Shortcut pill (card stage) — the Canvas2D-rasterized pill (sRGB,
 * premultiplied), placed texel-for-pixel, × the pill's alpha (the CG
 * transparency layer's composite alpha), quantized like the 8-bit CG raster,
 * then converted to the working space.
 */
export const keystrokeWGSL = /* wgsl */ `
${common}
${cardQuad}
struct PillU {
  q: Quad,
  p: vec4f,                   // raster origin.xy (card px, integers), alpha, toP3
  size: vec4f,                // raster size.xy, 0, 0
};
@group(0) @binding(0) var<uniform> u: PillU;
@group(0) @binding(1) var pill: texture_2d<f32>;

@vertex fn vs_quad(@builtin(vertex_index) i: u32) -> CardOut {
  var o: CardOut;
  o.pos = quadCorner(u.q, i);
  return o;
}

@fragment fn fs_main(in: CardOut) -> @location(0) vec4f {
  let p = quadToCard(u.q, in.pos.xy) - u.p.xy;
  let c = bilinearClearIn(pill, p, vec2i(u.size.xy));
  return toWorking(q8(c * u.p.z), u.p.w);
}
`;
