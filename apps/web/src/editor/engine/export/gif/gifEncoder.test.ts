/**
 * The GIF encoder, round-tripped through an independent decoder written here
 * from the GIF89a spec: header / NETSCAPE loop / per-frame delay + disposal,
 * frame-diff rectangles, local tables and LZW (incl. code-width growth, the
 * 4096-entry clear and the end-of-data width edge).
 */
import { describe, expect, it } from "vitest";
import { GifEncoder } from "./gifEncoder";
import { toSrgbOpaque } from "./srgb";

interface Decoded {
  width: number;
  height: number;
  loop: number | null;
  frames: { delay: number; disposal: number; transparent: number | null; rect: [number, number, number, number]; rgba: Uint8Array }[];
}

/** Minimal GIF89a decoder: composites every frame onto the canvas (disposal 1 only). */
function decodeGif(bytes: Uint8Array): Decoded {
  let p = 0;
  const u8 = () => bytes[p++];
  const u16 = () => {
    const v = bytes[p] | (bytes[p + 1] << 8);
    p += 2;
    return v;
  };
  const header = String.fromCharCode(...bytes.subarray(0, 6));
  if (header !== "GIF89a") throw new Error(`bad header ${header}`);
  p = 6;
  const width = u16();
  const height = u16();
  const flags = u8();
  u8();
  u8();
  let global: Uint8Array | null = null;
  if (flags & 0x80) {
    const n = 3 << ((flags & 7) + 1);
    global = bytes.slice(p, p + n);
    p += n;
  }
  const canvas = new Uint8Array(width * height * 4);
  const out: Decoded = { width, height, loop: null, frames: [] };
  let gce = { delay: 0, disposal: 0, transparent: null as number | null };
  for (;;) {
    const b = u8();
    if (b === 0x3b) break;
    if (b === 0x21) {
      const label = u8();
      if (label === 0xf9) {
        u8();
        const f = u8();
        const delay = u16();
        const ti = u8();
        u8();
        gce = { delay, disposal: (f >> 2) & 7, transparent: f & 1 ? ti : null };
      } else if (label === 0xff) {
        const n = u8();
        const app = String.fromCharCode(...bytes.subarray(p, p + n));
        p += n;
        for (let len = u8(); len !== 0; len = u8()) {
          if (app === "NETSCAPE2.0" && len === 3 && bytes[p] === 1) out.loop = bytes[p + 1] | (bytes[p + 2] << 8);
          p += len;
        }
      } else {
        for (let len = u8(); len !== 0; len = u8()) p += len;
      }
      continue;
    }
    if (b !== 0x2c) throw new Error(`unexpected block 0x${b.toString(16)} at ${p - 1}`);
    const x = u16();
    const y = u16();
    const w = u16();
    const h = u16();
    const f = u8();
    let table = global;
    if (f & 0x80) {
      const n = 3 << ((f & 7) + 1);
      table = bytes.slice(p, p + n);
      p += n;
    }
    if (!table) throw new Error("no colour table");
    const minCode = u8();
    const data: number[] = [];
    for (let len = u8(); len !== 0; len = u8()) {
      for (let i = 0; i < len; i++) data.push(bytes[p + i]);
      p += len;
    }
    const indices = lzwDecode(data, minCode, w * h);
    for (let j = 0; j < h; j++) {
      for (let i = 0; i < w; i++) {
        const idx = indices[j * w + i];
        if (gce.transparent !== null && idx === gce.transparent) continue;
        const o = ((y + j) * width + (x + i)) * 4;
        canvas[o] = table[idx * 3];
        canvas[o + 1] = table[idx * 3 + 1];
        canvas[o + 2] = table[idx * 3 + 2];
        canvas[o + 3] = 255;
      }
    }
    out.frames.push({ ...gce, rect: [x, y, w, h], rgba: canvas.slice() });
    gce = { delay: 0, disposal: 0, transparent: null };
  }
  return out;
}

function lzwDecode(data: number[], minCode: number, count: number): Uint8Array {
  const out = new Uint8Array(count);
  let o = 0;
  const clear = 1 << minCode;
  const eoi = clear + 1;
  let size = minCode + 1;
  let dict: number[][] = [];
  const reset = () => {
    dict = [];
    for (let i = 0; i < clear; i++) dict.push([i]);
    dict.push([], []);
    size = minCode + 1;
  };
  reset();
  let bit = 0;
  const read = () => {
    let v = 0;
    for (let i = 0; i < size; i++, bit++) v |= ((data[bit >> 3] >> (bit & 7)) & 1) << i;
    return v;
  };
  let prev: number[] | null = null;
  for (;;) {
    if (bit + size > data.length * 8) throw new Error("LZW ran out of data");
    const code = read();
    if (code === clear) {
      reset();
      prev = null;
      continue;
    }
    if (code === eoi) break;
    let entry: number[];
    if (code < dict.length && dict[code].length > 0) entry = dict[code];
    else if (code === dict.length && prev) entry = [...prev, prev[0]];
    else throw new Error(`bad code ${code} (dict ${dict.length})`);
    for (const v of entry) out[o++] = v;
    if (prev && dict.length < 4096) dict.push([...prev, entry[0]]);
    if (dict.length === 1 << size && size < 12) size++;
    prev = entry;
  }
  if (o !== count) throw new Error(`LZW produced ${o} of ${count} pixels`);
  return out;
}

function frame(w: number, h: number, f: (x: number, y: number) => [number, number, number]): Uint8Array {
  const rgba = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const [r, g, b] = f(x, y);
      const o = (y * w + x) * 4;
      rgba[o] = r;
      rgba[o + 1] = g;
      rgba[o + 2] = b;
      rgba[o + 3] = 255;
    }
  return rgba;
}

describe("GifEncoder", () => {
  it("loops forever, one frame per add, every frame at the policy delay", () => {
    const enc = new GifEncoder(40, 30, 5);
    const a = frame(40, 30, (x, y) => [(x % 16) * 16, (y % 16) * 16, 128]); // 256 colours
    enc.addFrame(a);
    enc.addFrame(a); // unchanged → 1×1 transparent frame, still a frame
    const b = a.slice();
    b.set([255, 0, 0, 255], (10 * 40 + 12) * 4);
    enc.addFrame(b);
    const gif = decodeGif(enc.finish());
    expect(gif.width).toBe(40);
    expect(gif.height).toBe(30);
    expect(gif.loop).toBe(0);
    expect(gif.frames.length).toBe(3);
    expect(gif.frames.map((f) => f.delay)).toEqual([5, 5, 5]);
    expect(gif.frames.every((f) => f.disposal === 1)).toBe(true);
    expect(gif.frames[1].rect).toEqual([0, 0, 1, 1]);
    expect(gif.frames[1].transparent).toBe(0);
    expect(gif.frames[2].rect).toEqual([12, 10, 1, 1]);
    // ≤ 256 distinct colours on the 6-bit grid → exact round trip.
    expect(Buffer.from(gif.frames[0].rgba).equals(Buffer.from(a))).toBe(true);
    expect(Buffer.from(gif.frames[1].rgba).equals(Buffer.from(a))).toBe(true);
    expect(Buffer.from(gif.frames[2].rgba).equals(Buffer.from(b))).toBe(true);
  });

  it("quantizes rich frames to ≤ 256 colours with small error, LZW past 4096 codes", () => {
    const w = 320;
    const h = 200;
    const enc = new GifEncoder(w, h, 10);
    // Smooth 2D gradient + noise: thousands of colours, long LZW streams.
    let s = 12345;
    const rnd = () => ((s = (s * 1103515245 + 12345) >>> 0) / 2 ** 32);
    const src = frame(w, h, (x, y) => [Math.round((x / w) * 255), Math.round((y / h) * 255), Math.round(rnd() * 255)]);
    enc.addFrame(src);
    const gif = decodeGif(enc.finish());
    expect(enc.stats[0].colors).toBeLessThanOrEqual(256);
    expect(enc.stats[0].colors).toBeGreaterThan(64);
    let err = 0;
    for (let i = 0; i < src.length; i += 4) {
      err += Math.abs(src[i] - gif.frames[0].rgba[i]) + Math.abs(src[i + 1] - gif.frames[0].rgba[i + 1]);
    }
    // Red / green are smooth ramps: median cut keeps them within a few levels.
    expect(err / (w * h * 2)).toBeLessThan(12);
  });

  it("code-width edge cases decode (every short length, 1–4 colours)", () => {
    for (let colors = 1; colors <= 4; colors++) {
      for (let n = 1; n <= 40; n++) {
        const enc = new GifEncoder(n, 1, 2);
        const px = frame(n, 1, (x) => {
          const c = ((x * 7) % colors) * 60;
          return [c, c, c];
        });
        enc.addFrame(px);
        const gif = decodeGif(enc.finish());
        expect(Buffer.from(gif.frames[0].rgba).equals(Buffer.from(px)), `${colors} colours × ${n}`).toBe(true);
      }
    }
  });
});

describe("toSrgbOpaque", () => {
  it("sRGB passes through; P3 primaries clip to the sRGB gamut; P3 grey stays grey", () => {
    const px = new Uint8Array([10, 20, 30, 255, 255, 0, 0, 255, 128, 128, 128, 255]);
    expect([...toSrgbOpaque(px.slice(), "srgb")]).toEqual([...px]);
    const p3 = toSrgbOpaque(px.slice(), "display-p3");
    expect([p3[4], p3[5], p3[6]]).toEqual([255, 0, 0]);
    expect(Math.abs(p3[8] - 128)).toBeLessThanOrEqual(1);
    expect(p3[8]).toBe(p3[9]);
    expect(p3[9]).toBe(p3[10]);
  });
});
