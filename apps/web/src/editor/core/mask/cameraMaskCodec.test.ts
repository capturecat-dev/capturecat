import { describe, expect, it } from "vitest";

import {
  CameraMaskDecoder,
  encodeCameraMask,
  frameIndexAt,
  parseCameraMask,
} from "./cameraMaskCodec";

const W = 16;
const H = 9;

/** A soft disc that drifts right: neighbouring frames differ only at edges,
 *  like a real person mask. */
function disc(frame: number, w = W, h = H): Uint8Array {
  const a = new Uint8Array(w * h);
  const scale = w / W;
  const cx = (4 + frame * 0.5) * scale;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const d = Math.hypot(x - cx, y - 4 * scale) / scale;
      a[y * w + x] = Math.max(0, Math.min(255, Math.round((3.5 - d) * 255)));
    }
  }
  return a;
}

async function track(n: number, keyframeInterval = 4, w = W, h = H) {
  const frames = Array.from({ length: n }, (_, i) => ({ time: i / 30, alpha: disc(i, w, h) }));
  const bytes = await encodeCameraMask({ width: w, height: h, keyframeInterval, sourceDuration: n / 30, sourceByteSize: 1234 }, frames);
  return { frames, bytes, parsed: parseCameraMask(bytes) };
}

describe("camera mask codec", () => {
  it("round-trips the header and index", async () => {
    const { parsed } = await track(10);
    expect(parsed.header).toEqual({ width: W, height: H, keyframeInterval: 4, frameCount: 10, sourceDuration: 10 / 30, sourceByteSize: 1234 });
    expect(parsed.index.map((e) => e.time)).toEqual(Array.from({ length: 10 }, (_, i) => i / 30));
  });

  it("decodes every frame exactly, sequentially and by random seeks", async () => {
    const { frames, parsed } = await track(13);
    const decoder = new CameraMaskDecoder(parsed);
    for (let i = 0; i < 13; i++) expect([...(await decoder.frame(i))]).toEqual([...frames[i]!.alpha]);
    for (const i of [12, 0, 7, 3, 3, 11, 5, 9, 1]) expect([...(await decoder.frame(i))]).toEqual([...frames[i]!.alpha]);
  });

  it("stores a delta only when it is smaller, and keys at least every keyframeInterval", async () => {
    // Fast motion: deltas lose, so every frame is a key.
    const fast = await track(8, 8, 160, 90);
    expect(fast.parsed.index.every((e) => !e.delta)).toBe(true);
    // A still mask with a flickering edge pixel: deltas win, capped by the interval.
    const still = disc(0, 160, 90);
    const frames = Array.from({ length: 10 }, (_, i) => {
      const alpha = still.slice();
      alpha[0] = i % 2 ? 255 : 0;
      return { time: i, alpha };
    });
    const bytes = await encodeCameraMask({ width: 160, height: 90, keyframeInterval: 4, sourceDuration: 10, sourceByteSize: 1 }, frames);
    const parsed = parseCameraMask(bytes);
    expect(parsed.index.map((e) => (e.delta ? "d" : "K")).join("")).toBe("KdddKdddKd");
    const decoder = new CameraMaskDecoder(parsed);
    for (const i of [9, 2, 5, 8, 0, 6]) expect([...(await decoder.frame(i))]).toEqual([...frames[i]!.alpha]);
  });

  it("picks the last frame at or before t, clamped to the first", () => {
    const index = [0, 0.1, 0.2].map((time) => ({ time, offset: 0, length: 0, delta: false }));
    expect(frameIndexAt(index, -1)).toBe(0);
    expect(frameIndexAt(index, 0)).toBe(0);
    expect(frameIndexAt(index, 0.0999)).toBe(0);
    expect(frameIndexAt(index, 0.1)).toBe(1);
    expect(frameIndexAt(index, 5)).toBe(2);
    expect(frameIndexAt([], 1)).toBe(-1);
  });

  it("rejects malformed files", async () => {
    const { bytes } = await track(3);
    const bad = bytes.slice();
    bad[0] = 0x58;
    expect(() => parseCameraMask(bad)).toThrow(/bad magic/);
    expect(() => parseCameraMask(bytes.subarray(0, 20))).toThrow(/truncated header/);
    expect(() => parseCameraMask(bytes.subarray(0, 40))).toThrow(/truncated index/);
    await expect(
      encodeCameraMask({ width: W, height: H, keyframeInterval: 4, sourceDuration: 1, sourceByteSize: 1 }, [
        { time: 1, alpha: disc(0) },
        { time: 1, alpha: disc(1) },
      ]),
    ).rejects.toThrow(/increase/);
  });
});
