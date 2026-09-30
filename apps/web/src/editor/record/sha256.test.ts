import { describe, expect, it } from "vitest";
import { createHash } from "node:crypto";

import { Sha256, sha256Blob } from "./sha256";

const node = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");

describe("Sha256", () => {
  it("matches node:crypto across block boundaries and split updates", () => {
    for (const len of [0, 1, 3, 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000, 70_001]) {
      const data = new Uint8Array(len);
      for (let i = 0; i < len; i++) data[i] = (i * 31 + 7) & 0xff;
      expect(new Sha256().update(data).hex()).toBe(node(data));
      // Same bytes fed in awkward pieces.
      const h = new Sha256();
      for (let i = 0; i < len; i += 37) h.update(data.subarray(i, Math.min(len, i + 37)));
      expect(h.hex()).toBe(node(data));
    }
  });

  it("hashes a Blob in slices", async () => {
    const data = new Uint8Array(9 * 1024 * 1024 + 123).map((_, i) => (i * 13) & 0xff);
    const seen: number[] = [];
    const hex = await sha256Blob(new Blob([data]), (done) => seen.push(done));
    expect(hex).toBe(node(data));
    expect(seen.at(-1)).toBe(data.length);
  });
});
