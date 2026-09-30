/**
 * Export frames → sRGB bytes for the GIF encoder (GIF has no colour profile;
 * the Mac's GIF writer draws each frame into an sRGB bitmap —
 * `GIFFrameSink.sRGBImage`). Display-P3 working space (P3 recordings) is
 * converted with the D65 P3→sRGB matrix on linear light and clipped to the
 * sRGB gamut; both spaces share the sRGB transfer curve. The readback is
 * premultiplied; export frames are opaque, so alpha is dropped (a partially
 * transparent pixel is un-premultiplied first).
 */
import type { WorkingSpace } from "../../color";

const P3_TO_SRGB = [
  1.2249401762805598, -0.22494017628055996, 0,
  -0.04205695470968816, 1.0420569547096882, 0,
  -0.019637554590334432, -0.07863604555063176, 1.0982736001409663,
];

let decode: Float32Array | null = null;
let encode: Uint8Array | null = null;
const ENCODE_STEPS = 4096;

function luts(): { decode: Float32Array; encode: Uint8Array } {
  if (!decode || !encode) {
    decode = new Float32Array(256);
    for (let i = 0; i < 256; i++) {
      const c = i / 255;
      decode[i] = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }
    encode = new Uint8Array(ENCODE_STEPS + 1);
    for (let i = 0; i <= ENCODE_STEPS; i++) {
      const l = i / ENCODE_STEPS;
      const c = l <= 0.0031308 ? l * 12.92 : 1.055 * Math.pow(l, 1 / 2.4) - 0.055;
      encode[i] = Math.round(Math.min(1, Math.max(0, c)) * 255);
    }
  }
  return { decode, encode };
}

/** In place: premultiplied RGBA in `space` → straight sRGB RGBA (alpha 255). */
export function toSrgbOpaque(rgba: Uint8Array, space: WorkingSpace): Uint8Array {
  const p3 = space === "display-p3";
  const { decode: dec, encode: enc } = luts();
  const m = P3_TO_SRGB;
  for (let i = 0; i < rgba.length; i += 4) {
    let r = rgba[i];
    let g = rgba[i + 1];
    let b = rgba[i + 2];
    const a = rgba[i + 3];
    if (a !== 255 && a !== 0) {
      const k = 255 / a;
      r = Math.min(255, Math.round(r * k));
      g = Math.min(255, Math.round(g * k));
      b = Math.min(255, Math.round(b * k));
    }
    if (p3) {
      const lr = dec[r];
      const lg = dec[g];
      const lb = dec[b];
      const sr = m[0] * lr + m[1] * lg + m[2] * lb;
      const sg = m[3] * lr + m[4] * lg + m[5] * lb;
      const sb = m[6] * lr + m[7] * lg + m[8] * lb;
      r = enc[Math.round(Math.min(1, Math.max(0, sr)) * ENCODE_STEPS)];
      g = enc[Math.round(Math.min(1, Math.max(0, sg)) * ENCODE_STEPS)];
      b = enc[Math.round(Math.min(1, Math.max(0, sb)) * ENCODE_STEPS)];
    }
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return rgba;
}
