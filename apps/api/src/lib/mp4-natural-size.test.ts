import { describe, expect, it } from "vitest";
import { MAX_MOOV_BYTES, readNaturalSize, type RangeReader } from "./mp4-natural-size";
import { box, mp4File } from "../test-support/mp4-boxes";

/** A RangeReader over bytes that records every read (offset, length). */
function reader(bytes: Uint8Array) {
  const reads: Array<[number, number]> = [];
  const read: RangeReader = async (offset, length) => {
    reads.push([offset, length]);
    return bytes.slice(offset, offset + length);
  };
  return { read, reads };
}

async function sizeOf(bytes: Uint8Array) {
  const { read, reads } = reader(bytes);
  return { size: await readNaturalSize(read, bytes.byteLength), reads };
}

describe("readNaturalSize", () => {
  it("finds the moov after the mdat with header reads only (AVAssetWriter's layout)", async () => {
    const file = mp4File({ tracks: [{ kind: "video", width: 2940, height: 1912 }], mdatBytes: 50_000 });
    const { size, reads } = await sizeOf(file);
    expect(size).toEqual({ width: 2940, height: 1912 });
    // ftyp, wide, mdat headers (16 bytes each), then the moov header + the moov.
    expect(reads.slice(0, 3).every(([, length]) => length === 16)).toBe(true);
    expect(reads.reduce((n, [, length]) => n + length, 0)).toBeLessThan(2_000);
  });

  it("reads a fast-start file (moov first) and a 64-bit mdat header", async () => {
    expect((await sizeOf(mp4File({ tracks: [{ kind: "video", width: 1920, height: 1080 }], moovAtEnd: false }))).size).toEqual({
      width: 1920,
      height: 1080,
    });
    expect((await sizeOf(mp4File({ tracks: [{ kind: "video", width: 3024, height: 1964 }], largeMdat: true }))).size).toEqual({
      width: 3024,
      height: 1964,
    });
  });

  it("uses the FIRST video track, skipping audio (AutoZoomApplier's rule)", async () => {
    const file = mp4File({
      tracks: [{ kind: "audio" }, { kind: "video", width: 1280, height: 720 }, { kind: "video", width: 640, height: 360 }],
    });
    expect((await sizeOf(file)).size).toEqual({ width: 1280, height: 720 });
  });

  it("applies pasp like mediabunny: num > den widens, otherwise heightens (rounded)", async () => {
    const wide = mp4File({ tracks: [{ kind: "video", width: 1440, height: 1080, pasp: [4, 3] }] });
    expect((await sizeOf(wide)).size).toEqual({ width: 1920, height: 1080 });
    const tall = mp4File({ tracks: [{ kind: "video", width: 1440, height: 1080, pasp: [3, 4] }] });
    expect((await sizeOf(tall)).size).toEqual({ width: 1440, height: 1440 });
    const odd = mp4File({ tracks: [{ kind: "video", width: 1001, height: 1001, pasp: [3, 2] }] });
    expect((await sizeOf(odd)).size).toEqual({ width: Math.round((1001 * 3) / 2), height: 1001 });
    const square = mp4File({ tracks: [{ kind: "video", width: 800, height: 600, pasp: [1, 1] }] });
    expect((await sizeOf(square)).size).toEqual({ width: 800, height: 600 });
  });

  it("is null without a video track, a moov, or with a truncated / oversized box", async () => {
    expect((await sizeOf(mp4File({ tracks: [{ kind: "audio" }] }))).size).toBeNull();
    expect((await sizeOf(new Uint8Array(box("ftyp", [1, 2, 3, 4]).concat(box("mdat", [9, 9]))))).size).toBeNull();
    const file = mp4File({ tracks: [{ kind: "video", width: 100, height: 100 }] });
    expect((await sizeOf(file.slice(0, file.byteLength - 10))).size).toBeNull();
    // A moov header claiming more than the cap is refused before it is read.
    const huge = new Uint8Array([0, 0, 0, 8, ...[..."ftyp"].map((c) => c.charCodeAt(0)), 0x7f, 0xff, 0xff, 0xff, ...[..."moov"].map((c) => c.charCodeAt(0))]);
    const { read, reads } = reader(huge);
    expect(await readNaturalSize(read, MAX_MOOV_BYTES * 2)).toBeNull();
    expect(reads.every(([, length]) => length <= 16)).toBe(true);
    expect(await readNaturalSize(read, 4)).toBeNull();
  });
});
